package client

import log "../common/wlog"
import "core:crypto"
import "core:fmt"
import "core:strings"
import "core:time"

import "../proto"

/*
Sending files in DMs (see src/proto/files.odin for the protocol).

A file is offered in a DM, which shows up in the conversation on both
sides. Only an offer from this run of the client can go ahead: the file
behind it is open until the transfer ends, and after a restart an offer
that never went anywhere is Expired.

Sending paces chunks to the lower of our upload limit and the
recipient's download limit (the settings), and at most FILE_MAX_RATE.
Receiving writes each chunk where it goes as it comes (files_io_*.odin),
into the downloads folder under the name the sender gave it.
*/

// Even with no limit set, a transfer doesn't go faster than this, so it
// leaves room for voice.
FILE_MAX_RATE :: 16 * 1024 * 1024
FILE_BURST :: 256 * 1024
// How often the recipient says what it has.
FILE_ACK_INTERVAL :: 100 * time.Millisecond
// A chunk asked for again isn't resent sooner than this after it last
// went, as it may still be on its way.
FILE_RESEND_GAP :: 300 * time.Millisecond
// Giving up on a transfer that hears nothing from the other side.
FILE_TIMEOUT :: 30 * time.Second
// How long the acks may stand still before the sender resends the end.
FILE_TAIL_WAIT :: time.Second
// How many times the last ack, saying it's complete, is sent.
FILE_COMPLETE_ACKS :: 4
// How often progress is shown.
FILE_PUBLISH_INTERVAL :: 200 * time.Millisecond

File_State :: enum u8 {
	Offered      = 0, // ours, waiting for them to say yes
	Incoming     = 1, // theirs, waiting for us to say yes
	Starting     = 2, // accepted, nothing sent yet
	Transferring = 3,
	Done         = 4,
	Declined     = 5,
	Cancelled    = 6,
	Failed       = 7, // couldn't be read or written, or went quiet
	Interrupted  = 8, // the other side left
	Expired      = 9, // from a previous run of the client
}

// file_state_over is whether a transfer has ended, one way or another.
file_state_over :: proc(s: File_State) -> bool {
	return s >= .Done
}

File_Client :: struct {
	transfers:    map[u64]^File_Transfer,
	// Bytes per second; 0 for no limit (settings: Transfer_Limits_Command).
	upload_limit: u32,
	download_limit: u32,
	// Where received files go; empty for the downloads folder.
	download_dir: string,
}

File_Transfer :: struct {
	id:           u64,
	peer:         [proto.KEY_SIZE]u8,
	outgoing:     bool,
	key:          [proto.DM_KEY_SIZE]u8, // shared with the peer (dm.odin)
	prefix:       [proto.FILE_NONCE_PREFIX_SIZE]u8,
	name:         string, // owned
	size:         u64,
	chunks:       u32,
	state:        File_State,
	done:         u64, // bytes through
	last_heard:   time.Tick, // anything from the other side
	last_publish: time.Tick,
	rate:         f32, // bytes per second, lately
	rate_at:      time.Tick,
	rate_done:    u64,

	// Sending.
	src:          File_Source,
	next:         u32, // the first chunk never sent
	base:         u32, // everything below has arrived
	highest:      u32,
	peer_rate:    u32,
	acked:        bool, // an ack has come, so `highest` means something
	progress_at:  time.Tick, // when the acks last moved on
	resend:       [dynamic]u32,
	resent:       map[u32]time.Tick,
	tokens:       f32,
	last_pace:    time.Tick,

	// Receiving.
	sink:         File_Sink,
	path:         string, // where it's being saved; owned
	have:         []u64, // a bit per chunk
	received:     u32,
	rbase:        u32, // the first chunk not here
	rhighest:     u32,
	any:          bool, // a chunk has come
	last_ack:     time.Tick,
	complete_acks: int,
}

// Send_File_Command offers `to` a file: at `path` on a desktop, or the
// page's picked file `web_file` in a browser (files_io_web.odin).
Send_File_Command :: struct {
	to:       [proto.KEY_SIZE]u8,
	name:     string, // owned: `to`'s name, when `to` is zero (headless)
	path:     string, // owned
	web_file: i32,
	web_name: string, // owned
	web_size: u64,
}

File_Action :: enum u8 {
	Accept,
	Decline,
	Cancel,
}

File_Action_Command :: struct {
	id:     u64,
	action: File_Action,
}

// Transfer_Limits_Command sets the settings' limits, in bytes per second.
Transfer_Limits_Command :: struct {
	upload, download: u32,
}

files_destroy :: proc(c: ^Voice_Client) {
	for _, t in c.files.transfers {
		transfer_close(t, keep = false)
		transfer_free(t)
	}
	delete(c.files.transfers)
	delete(c.files.download_dir)
}

/*
Offering.
*/

// send_file offers a file. The file is opened now and stays open until
// the transfer ends.
send_file :: proc(c: ^Voice_Client, cmd: Send_File_Command) {
	to, found := dm_recipient(c, cmd.to, cmd.name)
	if !found {
		return
	}
	if !dm_online(c, to) {
		log.warnf("file: %s isn't online, and files only go to someone who is", fingerprint(to))
		return
	}
	src, raw_name, size, ok := file_source_open(cmd)
	if !ok {
		return
	}
	name_buf: [proto.MAX_FILE_NAME]u8
	name := proto.sanitize_file_name(raw_name, &name_buf)
	if !proto.file_type_allowed(name) {
		log.warnf("file: %q isn't a kind of file that can be sent (archives, pictures and videos)", raw_name)
		file_source_close(&src)
		return
	}
	if size == 0 || u64(proto.file_chunk_count(size)) * proto.FILE_CHUNK_DATA < size {
		log.warnf("file: %q is empty or too large to send", raw_name)
		file_source_close(&src)
		return
	}
	key, key_ok := dm_shared_key(c, to)
	if !key_ok {
		file_source_close(&src)
		return
	}

	t := new(File_Transfer)
	t^ = {
		id         = random_id(),
		peer       = to,
		outgoing   = true,
		key        = key,
		name       = strings.clone(name),
		size       = size,
		chunks     = proto.file_chunk_count(size),
		state      = .Offered,
		src        = src,
		last_heard = time.tick_now(),
	}
	crypto.rand_bytes(t.prefix[:])
	c.files.transfers[t.id] = t

	body_buf: [proto.MAX_DM_BODY]u8
	body := proto.encode_dm_file(&body_buf, {size = size, prefix = t.prefix, name = name})
	dm_queue(c, to, t.id, body, DM_Message{mine = true, text = strings.clone(name), file = true, file_size = size, file_state = .Offered})
	log.infof("[file] offering %s %q (%s)", fingerprint(to), name, format_bytes(size))
	publish_file(c, t, force = true)
}

// file_offer_received takes in an offer that came in a DM; `m` is the
// message it's going to be, which it fills in.
file_offer_received :: proc(c: ^Voice_Client, from: [proto.KEY_SIZE]u8, id: u64, offer: proto.DM_File, m: ^DM_Message) {
	name_buf: [proto.MAX_FILE_NAME]u8
	name := proto.sanitize_file_name(offer.name, &name_buf)
	m.file = true
	m.file_size = offer.size
	m.file_state = .Incoming
	delete(m.text)
	m.text = strings.clone(name if name != "" else "file")
	key, key_ok := dm_shared_key(c, from)
	if !key_ok || name == "" || !proto.file_type_allowed(name) {
		// Nothing we'd save: say no straight away.
		log.warnf("file: refusing %q from %s, not a kind of file that can be sent", offer.name, fingerprint(from))
		m.file_state = .Declined
		send_file_cancel(c, id, from, .Declined)
		return
	}
	t := new(File_Transfer)
	t^ = {
		id         = id,
		peer       = from,
		key        = key,
		prefix     = offer.prefix,
		name       = strings.clone(m.text),
		size       = offer.size,
		chunks     = proto.file_chunk_count(offer.size),
		state      = .Incoming,
		last_heard = time.tick_now(),
	}
	c.files.transfers[id] = t
	log.infof("[file] %s offers %q (%s)", fingerprint(from), t.name, format_bytes(t.size))
	publish_file(c, t, force = true)
}

// file_action is the person's answer to an offer, or stopping a
// transfer. An id of 0 means every one it applies to (headless mode).
file_action :: proc(c: ^Voice_Client, id: u64, action: File_Action) {
	if id == 0 {
		ids := make([dynamic]u64, context.temp_allocator)
		for other in c.files.transfers {
			append(&ids, other)
		}
		for other in ids {
			file_action(c, other, action)
		}
		return
	}
	t := c.files.transfers[id] or_else nil
	if t == nil || file_state_over(t.state) {
		return
	}
	switch action {
	case .Accept:
		if t.outgoing || t.state != .Incoming {
			return
		}
		dir := c.files.download_dir
		sink, path, ok := file_sink_create(dir, t.name, t.size)
		if !ok {
			end_transfer(c, t, .Failed, .Failed)
			return
		}
		t.sink, t.path = sink, path
		t.have = make([]u64, (int(t.chunks) + 63) / 64)
		t.state = .Starting
		t.last_heard = time.tick_now()
		t.last_ack = {}
		log.infof("[file] accepted %q, saving to %s", t.name, path)
		publish_file(c, t, force = true)
	case .Decline:
		if t.outgoing || t.state != .Incoming {
			return
		}
		end_transfer(c, t, .Declined, .Declined)
	case .Cancel:
		end_transfer(c, t, .Cancelled, .Cancelled)
	}
}

/*
Running transfers: files_step, from the client's loop.
*/
files_step :: proc(c: ^Voice_Client) {
	if !c.has_current {
		return
	}
	now := time.tick_now()
	for _, t in c.files.transfers {
		if file_state_over(t.state) {
			// The recipient repeats that it's complete, in case the
			// first didn't get there.
			if !t.outgoing && t.state == .Done && t.complete_acks < FILE_COMPLETE_ACKS && time.tick_diff(t.last_ack, now) >= FILE_ACK_INTERVAL * 3 {
				send_file_ack(c, t, now)
			}
			continue
		}
		if t.state == .Starting || t.state == .Transferring {
			if !dm_online(c, t.peer) {
				log.infof("[file] %q: the other side left", t.name)
				end_transfer(c, t, .Interrupted)
				continue
			}
			if time.tick_diff(t.last_heard, now) > FILE_TIMEOUT {
				log.warnf("[file] %q: the other side went quiet", t.name)
				end_transfer(c, t, .Failed, .Failed)
				continue
			}
		}
		if t.outgoing {
			if t.state == .Transferring {
				send_chunks(c, t, now)
			}
		} else {
			switch t.state {
			case .Starting:
				// Until chunks come, ask for them.
				if t.last_ack == {} || time.tick_diff(t.last_ack, now) >= proto.CONTROL_RESEND {
					t.last_ack = now
					buf: [proto.FILE_ACCEPT_SIZE]u8
					send_data(c, proto.encode_file_accept(&buf, t.id, t.peer, c.files.download_limit))
				}
			case .Transferring:
				if time.tick_diff(t.last_ack, now) >= FILE_ACK_INTERVAL {
					send_file_ack(c, t, now)
				}
			case .Offered, .Incoming, .Done, .Declined, .Cancelled, .Failed, .Interrupted, .Expired:
			}
		}
		update_rate(t, now)
		if time.tick_diff(t.last_publish, now) >= FILE_PUBLISH_INTERVAL {
			publish_file(c, t)
		}
	}
}

// send_chunks sends what the pace allows: chunks asked for again first,
// then new ones within the window.
@(private = "file")
send_chunks :: proc(c: ^Voice_Client, t: ^File_Transfer, now: time.Tick) {
	rate := f32(FILE_MAX_RATE)
	if c.files.upload_limit > 0 {
		rate = min(rate, f32(c.files.upload_limit))
	}
	if t.peer_rate > 0 {
		rate = min(rate, f32(t.peer_rate))
	}
	elapsed := f32(time.duration_seconds(time.tick_diff(t.last_pace, now)))
	t.last_pace = now
	t.tokens = min(t.tokens + elapsed * rate, max(FILE_BURST * rate / FILE_MAX_RATE, proto.FILE_CHUNK_DATA))

	// Everything sent once, but the acks have stopped moving: what's
	// after the highest chunk they have may have been lost too, and
	// they can't know to ask for it.
	if t.next == t.chunks && t.base < t.chunks && time.tick_diff(t.progress_at, now) > FILE_TAIL_WAIT {
		from := t.base
		if t.acked {
			from = max(from, t.highest + 1)
		}
		for i := from; i < t.chunks && len(t.resend) < 64; i += 1 {
			queue_resend(t, i, now)
		}
	}

	data: [proto.FILE_CHUNK_DATA]u8
	for t.tokens > 0 {
		index: u32
		first_pass := false
		switch {
		case len(t.resend) > 0:
			index = t.resend[0]
			if index < t.base {
				ordered_remove(&t.resend, 0)
				continue
			}
		case t.next < t.chunks && t.next < t.base + proto.FILE_WINDOW:
			index = t.next
			first_pass = true
		case:
			return
		}
		start, end := proto.file_chunk_range(t.size, index)
		ready, ok := file_source_read(&t.src, start, data[:end - start])
		if !ok {
			log.errorf("[file] could not read %q", t.name)
			end_transfer(c, t, .Failed, .Failed)
			return
		}
		if !ready {
			return // a browser is still reading it; next time
		}
		if first_pass {
			t.next += 1
		} else {
			ordered_remove(&t.resend, 0)
		}
		t.resent[index] = now
		sealed_buf: [proto.FILE_CHUNK_DATA + proto.TAG_SIZE]u8
		sealed := proto.dm_seal_with(
			&t.key,
			c.my_key,
			t.peer,
			t.id,
			.File,
			proto.file_chunk_nonce(t.prefix, index),
			data[:end - start],
			sealed_buf[:],
		)
		out: [proto.MAX_PAYLOAD_SIZE]u8
		send_data(c, proto.encode_file_chunk(out[:], t.id, index, sealed))
		t.tokens -= f32(end - start)
	}
}

// queue_resend asks for chunk `index` to go again, unless it went lately
// or is already waiting to.
@(private = "file")
queue_resend :: proc(t: ^File_Transfer, index: u32, now: time.Tick) {
	if index >= t.next {
		return // not sent yet in the first place
	}
	if last, ok := t.resent[index]; ok && time.tick_diff(last, now) < FILE_RESEND_GAP {
		return
	}
	for queued in t.resend {
		if queued == index {
			return
		}
	}
	append(&t.resend, index)
}

handle_file_accept :: proc(c: ^Voice_Client, pt: []u8) {
	id, from, rate := proto.decode_file_accept(pt)
	t := c.files.transfers[id] or_else nil
	if t == nil || !t.outgoing || t.peer != from {
		// An offer from before a restart: nothing to send it from.
		send_file_cancel(c, id, from, .Expired)
		return
	}
	t.peer_rate = rate
	t.last_heard = time.tick_now()
	if t.state != .Offered {
		return // a repeat
	}
	t.state = .Transferring
	t.last_pace = time.tick_now()
	t.rate_at = t.last_pace
	t.progress_at = t.last_pace
	log.infof("[file] %s accepted %q", fingerprint(from), t.name)
	publish_file(c, t, force = true)
}

handle_file_ack :: proc(c: ^Voice_Client, pt: []u8) {
	ack, count, missing, ok := proto.decode_file_ack(pt)
	t := c.files.transfers[ack.id] or_else nil
	if !ok || t == nil || !t.outgoing || file_state_over(t.state) {
		return
	}
	now := time.tick_now()
	t.last_heard = now
	t.peer_rate = ack.max_rate
	if ack.complete {
		t.base = t.chunks
		t.done = t.size
		log.infof("[file] sent %q", t.name)
		end_transfer(c, t, .Done)
		return
	}
	if ack.base > t.base || ack.highest > t.highest || !t.acked {
		t.progress_at = now
	}
	t.acked = true
	if ack.base > t.base && ack.base <= t.chunks {
		t.base = ack.base
		// What's below the base is theirs; no need to remember sending it.
		for index in t.resent {
			if index < t.base {
				delete_key(&t.resent, index)
			}
		}
	}
	t.highest = max(t.highest, min(ack.highest, t.chunks - 1))
	t.done = min(u64(t.base) * proto.FILE_CHUNK_DATA, t.size)
	for i in 0 ..< count {
		queue_resend(t, proto.file_ack_missing(missing, i), now)
	}
}

handle_file_chunk :: proc(c: ^Voice_Client, pt: []u8) {
	id, index, sealed := proto.decode_file_chunk(pt)
	t := c.files.transfers[id] or_else nil
	if t == nil || t.outgoing || (t.state != .Starting && t.state != .Transferring) {
		return
	}
	if index >= t.chunks {
		return
	}
	now := time.tick_now()
	if t.state == .Starting {
		t.state = .Transferring
		t.rate_at = now
		publish_file(c, t, force = true)
	}
	t.last_heard = now
	if t.have[index / 64] & (1 << (index % 64)) != 0 {
		return // a repeat
	}
	out: [proto.FILE_CHUNK_DATA]u8
	data, ok := proto.dm_open(&t.key, t.peer, c.my_key, t.id, .File, proto.file_chunk_nonce(t.prefix, index), sealed, out[:])
	start, end := proto.file_chunk_range(t.size, index)
	if !ok || u64(len(data)) != end - start {
		return // not from them, or broken; it'll be asked for again
	}
	if !file_sink_write(&t.sink, start, data) {
		log.errorf("[file] could not write %s", t.path)
		end_transfer(c, t, .Failed, .Failed)
		return
	}
	t.have[index / 64] |= 1 << (index % 64)
	t.received += 1
	t.done += u64(len(data))
	t.any = true
	t.rhighest = max(t.rhighest, index)
	for t.rbase < t.chunks && t.have[t.rbase / 64] & (1 << (t.rbase % 64)) != 0 {
		t.rbase += 1
	}
	if t.received == t.chunks {
		if !file_sink_finish(&t.sink, t.path) {
			log.errorf("[file] could not finish %s", t.path)
			end_transfer(c, t, .Failed, .Failed)
			return
		}
		log.infof("[file] received %q, saved to %s", t.name, t.path)
		end_transfer(c, t, .Done)
		send_file_ack(c, t, now)
		voice_notification_play(&c.voice, .Done)
	}
}

// send_file_ack says what we have, and what's missing up to the highest
// chunk that came.
@(private = "file")
send_file_ack :: proc(c: ^Voice_Client, t: ^File_Transfer, now: time.Tick) {
	t.last_ack = now
	complete := t.received == t.chunks
	if complete {
		t.complete_acks += 1
	}
	missing: [proto.FILE_ACK_MAX_MISSING]u32
	n := 0
	for i := t.rbase; i < t.rhighest && n < len(missing); i += 1 {
		if t.have[i / 64] & (1 << (i % 64)) == 0 {
			missing[n] = i
			n += 1
		}
	}
	out: [proto.MAX_PAYLOAD_SIZE]u8
	ack := proto.File_Ack {
		id       = t.id,
		max_rate = c.files.download_limit,
		base     = t.rbase,
		highest  = t.rhighest,
		complete = complete,
	}
	send_data(c, proto.encode_file_ack(out[:], ack, missing[:n]))
}

handle_file_cancel :: proc(c: ^Voice_Client, pt: []u8) {
	id, from, reason := proto.decode_file_cancel(pt)
	t := c.files.transfers[id] or_else nil
	if t == nil || t.peer != from || file_state_over(t.state) {
		return
	}
	state: File_State
	#partial switch reason {
	case .Declined:
		state = .Declined
	case .Cancelled:
		state = .Cancelled
	case .Gone:
		state = .Interrupted
	case .Expired:
		state = .Expired
	case:
		state = .Failed
	}
	log.infof("[file] %q: %v", t.name, state)
	end_transfer(c, t, state)
}

/*
end_transfer finishes a transfer in `state`, telling the other side why
if `tell` is set. The file behind it is closed; one being
received is kept if it's Done, else thrown away.
*/
@(private = "file")
end_transfer :: proc(
	c: ^Voice_Client,
	t: ^File_Transfer,
	state: File_State,
	tell := proto.File_Cancel_Reason(0),
) {
	if tell != proto.File_Cancel_Reason(0) {
		send_file_cancel(c, t.id, t.peer, tell)
	}
	t.state = state
	transfer_close(t, keep = state == .Done)
	dm_file_state(c, t.peer, t.id, state, t.path)
	publish_file(c, t, force = true)
}

@(private = "file")
transfer_close :: proc(t: ^File_Transfer, keep: bool) {
	if t.outgoing {
		file_source_close(&t.src)
	} else if !keep {
		file_sink_abort(&t.sink)
	}
	delete(t.resend)
	delete(t.resent)
	delete(t.have)
	t.resend, t.resent, t.have = nil, nil, nil
}

@(private = "file")
transfer_free :: proc(t: ^File_Transfer) {
	delete(t.name)
	delete(t.path)
	free(t)
}

@(private = "file")
send_file_cancel :: proc(c: ^Voice_Client, id: u64, to: [proto.KEY_SIZE]u8, reason: proto.File_Cancel_Reason) {
	buf: [proto.FILE_CANCEL_SIZE]u8
	send_data(c, proto.encode_file_cancel(&buf, id, to, reason))
}

// update_rate keeps a smoothed figure of how fast it's going.
@(private = "file")
update_rate :: proc(t: ^File_Transfer, now: time.Tick) {
	if t.state != .Transferring {
		return
	}
	elapsed := time.duration_seconds(time.tick_diff(t.rate_at, now))
	if elapsed < 0.5 {
		return
	}
	current := f32(f64(t.done - t.rate_done) / elapsed)
	t.rate = current if t.rate == 0 else t.rate * 0.6 + current * 0.4
	t.rate_at, t.rate_done = now, t.done
}

// format_bytes writes a size the way people read it (temp allocator).
format_bytes :: proc(n: u64) -> string {
	switch {
	case n >= 1 << 30:
		return fmt.tprintf("%.2f GB", f64(n) / (1 << 30))
	case n >= 1 << 20:
		return fmt.tprintf("%.1f MB", f64(n) / (1 << 20))
	case n >= 1 << 10:
		return fmt.tprintf("%.0f KB", f64(n) / (1 << 10))
	}
	return fmt.tprintf("%d bytes", n)
}

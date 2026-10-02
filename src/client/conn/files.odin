package conn

import log "common:wlog"
import "core:fmt"
import "core:strings"
import "core:time"

import "common:proto"
import "client:audio"
import "client:settings"

/*
Sending files in DMs (see src/common/proto/files.odin for the protocol).

A file is offered in a DM, as a message (messages.odin), which shows up
in the conversation on both sides. The transfer is known by that
message's id once it has one, and by its post's nonce until then. Only
an offer from this run of the client can go ahead, and only from the
device it was made on: the file behind it is open there until the
transfer ends. An offer is answered on the device it arrives at while
it's here (Msg_New); one found in the history, made earlier or answered
on another device, is shown as what's known of it (nothing much: the
server keeps no record of transfers).

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
	Unknown      = 0, // in the history: we can't tell what became of it
	Posting      = 1, // ours, the offer on its way to the server
	Offered      = 2, // ours, waiting for them to say yes
	Incoming     = 3, // theirs, waiting for us to say yes
	Starting     = 4, // accepted, nothing sent yet
	Transferring = 5,
	Done         = 6,
	Declined     = 7,
	Cancelled    = 8,
	Failed       = 9, // couldn't be read or written, or went quiet
	Interrupted  = 10, // the other side left
	Expired      = 11, // the offer isn't there to be taken up any more
	Elsewhere    = 12, // answered on another of our devices
}

// file_state_over is whether a transfer has ended, one way or another.
file_state_over :: proc(s: File_State) -> bool {
	return s >= .Done
}

File_Client :: struct {
	transfers:      map[proto.Msg_Id]^File_Transfer,
	// Offers of ours on their way to the server, by their post's nonce.
	posting:        map[u64]^File_Transfer,
	// Bytes per second; 0 for no limit (settings: Transfer_Limits_Command).
	upload_limit:   u32,
	download_limit: u32,
	// Where received files go; empty for the downloads folder.
	download_dir:   string,
}

File_Transfer :: struct {
	id:            proto.Msg_Id, // the offer's; 0 while it's being posted
	peer:          proto.Account_Id,
	outgoing:      bool,
	name:          string, // owned
	size:          u64,
	chunks:        u32,
	state:         File_State,
	done:          u64, // bytes through
	last_heard:    time.Tick, // anything from the other side
	last_publish:  time.Tick,
	rate:          f32, // bytes per second, lately
	rate_at:       time.Tick,
	rate_done:     u64,

	// Sending.
	src:           File_Source,
	next:          u32, // the first chunk never sent
	base:          u32, // everything below has arrived
	highest:       u32,
	peer_rate:     u32,
	acked:         bool, // an ack has come, so `highest` means something
	progress_at:   time.Tick, // when the acks last moved on
	resend:        [dynamic]u32,
	resent:        map[u32]time.Tick,
	tokens:        f32,
	last_pace:     time.Tick,

	// Receiving.
	sink:          File_Sink,
	path:          string, // where it's being saved; owned
	have:          []u64, // a bit per chunk
	received:      u32,
	rbase:         u32, // the first chunk not here
	rhighest:      u32,
	any:           bool, // a chunk has come
	last_ack:      time.Tick,
	complete_acks: int,
}

// Send_File_Command offers `to` a file: at `path` on a desktop, or the
// page's picked file `web_file` in a browser (files_io_web.odin).
Send_File_Command :: struct {
	to:       proto.Account_Id,
	name:     string, // owned: `to`'s name, when `to` is 0 (headless)
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
	id:     proto.Msg_Id,
	action: File_Action,
}

// Transfer_Limits_Command sets the settings' limits, in bytes per second.
Transfer_Limits_Command :: struct {
	upload, download: u32,
}

// transfer_limits_command is the transfer limits as configured in `s`,
// in bytes per second.
transfer_limits_command :: proc(s: ^settings.Settings) -> Transfer_Limits_Command {
	to_bytes :: proc(mb: f32) -> u32 {
		return u32(clamp(mb, 0, settings.MAX_TRANSFER_LIMIT) * 1024 * 1024)
	}
	return {upload = to_bytes(s.upload_limit), download = to_bytes(s.download_limit)}
}

files_destroy :: proc(c: ^Voice_Client) {
	for _, t in c.files.transfers {
		transfer_close(t, keep = false)
		transfer_free(t)
	}
	delete(c.files.transfers)
	for _, t in c.files.posting {
		transfer_close(t, keep = false)
		transfer_free(t)
	}
	delete(c.files.posting)
	delete(c.files.download_dir)
}

/*
Offering.
*/

// send_file offers a file. The file is opened now and stays open until
// the transfer ends. Files only go to someone who's here: the file is
// on this device, and they'd have to come and take it before it went.
send_file :: proc(c: ^Voice_Client, cmd: Send_File_Command) {
	to := cmd.to if cmd.to != 0 else account_named(c, cmd.name)
	if to == 0 || to == c.auth.me {
		log.warnf("file: there's nobody called %q to send it to", cmd.name)
		return
	}
	if !is_online(c, to) {
		log.warnf("file: %s isn't here, and files only go to someone who is", account_display(c, to))
		return
	}
	src, raw_name, size, ok := file_source_open(cmd)
	if !ok {
		return
	}
	name_buf: [proto.MAX_FILE_NAME]u8
	name := proto.sanitize_file_name(raw_name, &name_buf)
	if !proto.file_type_allowed(name) {
		log.warnf(
			"file: %q isn't a kind of file that can be sent (archives, pictures and videos)",
			raw_name,
		)
		file_source_close(&src)
		return
	}
	if size == 0 || u64(proto.file_chunk_count(size)) * proto.FILE_CHUNK_DATA < size {
		log.warnf("file: %q is empty or too large to send", raw_name)
		file_source_close(&src)
		return
	}

	t := new(File_Transfer)
	t^ = {
		peer       = to,
		outgoing   = true,
		name       = strings.clone(name),
		size       = size,
		chunks     = proto.file_chunk_count(size),
		state      = .Posting,
		src        = src,
		last_heard = time.tick_now(),
	}
	c.files.posting[file_post(c, to, name, size)] = t
	log.infof("[file] offering %s %q (%s)", account_display(c, to), name, format_bytes(size))
}

// file_posted is the offer with `nonce` posted, as message `id`: from
// here on the transfer goes by that.
file_posted :: proc(c: ^Voice_Client, nonce: u64, id: proto.Msg_Id) {
	t, ok := c.files.posting[nonce]
	if !ok {
		return
	}
	delete_key(&c.files.posting, nonce)
	t.id, t.state = id, .Offered
	t.last_heard = time.tick_now()
	c.files.transfers[id] = t
	publish_file(c, t, force = true)
}

// file_post_failed is the offer with `nonce` not posted: there's nothing
// to send it for.
file_post_failed :: proc(c: ^Voice_Client, nonce: u64) {
	t, ok := c.files.posting[nonce]
	if !ok {
		return
	}
	delete_key(&c.files.posting, nonce)
	transfer_close(t, keep = false)
	transfer_free(t)
}

// file_offer_received takes in an offer that has just been posted to us.
file_offer_received :: proc(c: ^Voice_Client, m: proto.Message) {
	if m.id in c.files.transfers {
		return
	}
	name_buf: [proto.MAX_FILE_NAME]u8
	name := proto.sanitize_file_name(m.file_name, &name_buf)
	t := new(File_Transfer)
	t^ = {
		id         = m.id,
		peer       = m.sender,
		name       = strings.clone(name if name != "" else "file"),
		size       = m.file_size,
		chunks     = proto.file_chunk_count(m.file_size),
		state      = .Incoming,
		last_heard = time.tick_now(),
	}
	c.files.transfers[m.id] = t
	if name == "" || !proto.file_type_allowed(name) || m.file_size == 0 {
		// Nothing we'd save: say no straight away.
		log.warnf("file: refusing %q, not a kind of file that can be sent", m.file_name)
		end_transfer(c, t, .Declined, .Declined)
		return
	}
	log.infof("[file] %s offers %q (%s)", account_display(c, t.peer), t.name, format_bytes(t.size))
	publish_file(c, t, force = true)
}

// file_offer_deleted is an offer whose message was deleted: one that
// hasn't been taken up can't be any more.
file_offer_deleted :: proc(c: ^Voice_Client, id: proto.Msg_Id) {
	t := c.files.transfers[id] or_else nil
	if t != nil && (t.state == .Incoming || t.state == .Offered) {
		end_transfer(c, t, .Expired)
	}
}

// file_action is the person's answer to an offer, or stopping a
// transfer. An id of 0 means every one it applies to (headless mode).
file_action :: proc(c: ^Voice_Client, id: proto.Msg_Id, action: File_Action) {
	if id == 0 {
		ids := make([dynamic]proto.Msg_Id, context.temp_allocator)
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
			if !t.outgoing &&
			   t.state == .Done &&
			   t.complete_acks < FILE_COMPLETE_ACKS &&
			   time.tick_diff(t.last_ack, now) >= FILE_ACK_INTERVAL * 3 {
				send_file_ack(c, t, now)
			}
			continue
		}
		if t.state == .Starting || t.state == .Transferring {
			if !is_online(c, t.peer) {
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
					send_data(
						c,
						proto.encode_file_accept(&buf, t.id, t.peer, c.files.download_limit),
					)
				}
			case .Transferring:
				if time.tick_diff(t.last_ack, now) >= FILE_ACK_INTERVAL {
					send_file_ack(c, t, now)
				}
			case .Unknown,
			     .Posting,
			     .Offered,
			     .Incoming,
			     .Done,
			     .Declined,
			     .Cancelled,
			     .Failed,
			     .Interrupted,
			     .Expired,
			     .Elsewhere:
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
	t.tokens = min(
		t.tokens + elapsed * rate,
		max(FILE_BURST * rate / FILE_MAX_RATE, proto.FILE_CHUNK_DATA),
	)

	// Everything sent once, but the acks have stopped moving: what's
	// after the highest chunk they have may have been lost too, and
	// they can't know to ask for it.
	if t.next == t.chunks &&
	   t.base < t.chunks &&
	   time.tick_diff(t.progress_at, now) > FILE_TAIL_WAIT {
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
		out: [proto.MAX_PAYLOAD_SIZE]u8
		send_data(c, proto.encode_file_chunk(out[:], t.id, index, data[:end - start]))
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
	log.infof("[file] %s accepted %q", account_display(c, from), t.name)
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
	id, index, data := proto.decode_file_chunk(pt)
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
	start, end := proto.file_chunk_range(t.size, index)
	if u64(len(data)) != end - start {
		return // broken; it'll be asked for again
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
		audio.voice_notification_play(&c.voice, .Done)
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
	case .Elsewhere:
		state = .Elsewhere
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
send_file_cancel :: proc(
	c: ^Voice_Client,
	id: proto.Msg_Id,
	to: proto.Account_Id,
	reason: proto.File_Cancel_Reason,
) {
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

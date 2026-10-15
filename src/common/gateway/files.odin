package gateway

import "core:crypto/sha2"
import "core:fmt"
import "core:sync"
import "core:time"

import "common:http"
import "common:lite"
import "common:proto"

// Files (docs/bot-api, phase 7):
//
//	POST   /uploads?name=      the file as the body  ->  201 {id, name, size}
//	GET    /attachments/{id}   a message's file (its attachment's id)
//	GET    /blobs/{id}         a picture: an avatar, the emoji, the icon
//	PUT    /me/avatar          a JPEG as the body  ->  /me
//	DELETE /me/avatar          ->  /me
//
// A finished upload can be attached to a message by naming it in
// `attachments` within an hour (proto/attachments.odin).
//
// Uploads and attachments travel between the gateway and the server in
// chunks, just like they do for a client (proto/transfer.odin), and they are
// streamed. The part of an upload's body that an HTTP thread has read goes
// into a Ring that the gateway sends from. The part of an attachment that the
// gateway has received goes into a Ring that the HTTP thread writes out from.
// Each Ring is one transfer window (FILE_WINDOW chunks) in size, regardless
// of the file's size. A download is only acked as far as the bot has read it,
// so a slow bot slows the server down instead of filling up the gateway's
// memory. Pictures (blobs) are at most a megabyte and are held in memory as a
// whole.
//
// A transfer fails (503) if the server is silent for TRANSFER_QUIET or if its
// connection starts over.

TRANSFER_QUIET :: 30 * time.Second
// Uploads are sent as fast as the server accepts them (according to its
// acks), but at most this fast. Pictures are sent at the client's pace.
UPLOAD_MAX_RATE :: 16 * 1024 * 1024
UPLOAD_BURST :: 256 * 1024
BLOB_UPLOAD_RATE :: 256 * 1024
BLOB_UPLOAD_BURST :: 32 * 1024
// If the server says nothing about a picture upload for this long, the
// picture is announced again, which makes the server report its progress.
BLOB_UPLOAD_QUIET :: 3 * time.Second
BLOB_UPLOAD_TRIES :: 3
RING_SIZE :: proto.FILE_WINDOW * proto.FILE_CHUNK_DATA

// Ring is the window of a streamed transfer, shared between an HTTP thread
// and the gateway thread. `in_` is how much has been put in and `out` is how
// much has been taken out. The bytes in between are in `buf`, at their offset
// modulo RING_SIZE. Whichever side releases it last frees it.
Ring :: struct {
	mutex:  sync.Mutex,
	cond:   sync.Cond,
	buf:    []u8,
	size:   u64, // the file's size
	in_:    u64,
	out:    u64,
	failed: bool, // set when either side has given up
	refs:   int,
}

// ring_make makes a Ring for a file of `size` that is referenced `refs` times.
@(private)
ring_make :: proc(size: u64, refs: int) -> ^Ring {
	r := new(Ring)
	r.buf = make([]u8, RING_SIZE)
	r.size = size
	r.refs = refs
	return r
}

@(private)
ring_release :: proc(r: ^Ring) {
	last: bool
	{
		sync.guard(&r.mutex)
		r.refs -= 1
		last = r.refs == 0
	}
	if last {
		delete(r.buf)
		free(r)
	}
}

@(private)
ring_fail :: proc(r: ^Ring) {
	sync.guard(&r.mutex)
	r.failed = true
	sync.cond_broadcast(&r.cond)
}

// An upload from the bot that is on its way to the server.
@(private)
Upload :: struct {
	job:        ^Job, // nil once the job has been replied to
	ring:       ^Ring,
	id:         u64, // assigned by the server
	send:       proto.Transfer_Sender,
	last_heard: time.Tick,
}

// An attachment that is on its way to the bot.
@(private)
Download :: struct {
	ring:       ^Ring,
	id:         u64, // assigned by the server
	recv:       proto.Transfer_Receiver,
	last_heard: time.Tick,
}

// A picture that is being fetched.
@(private)
Blob_Fetch :: struct {
	job:        ^Job,
	handle:     u64,
	recv:       proto.Blob_Receiver,
	asked:      time.Tick,
	last_chunk: time.Tick,
	started:    bool,
}

// An avatar that is being uploaded.
@(private)
Blob_Upload :: struct {
	job:        ^Job,
	put:        proto.Blob_Put,
	handle:     u64, // 0 until the server asks for the data
	send:       proto.Blob_Sender,
	tokens:     f32,
	last_pace:  time.Tick,
	last_heard: time.Tick,
	asking:     bool,
	tries:      int,
}

@(private)
Transfers :: struct {
	uploads:      [dynamic]^Upload,
	downloads:    [dynamic]^Download,
	fetches:      [dynamic]^Blob_Fetch,
	blob_uploads: [dynamic]^Blob_Upload,
}

// files_reset fails every transfer of a connection because the connection is
// starting over or going away. Whatever is in flight on the server's side is
// lost with it.
@(private)
files_reset :: proc(c: ^Conn) {
	t := &c.transfers
	for u in t.uploads {
		if u.job != nil {
			reply(u.job, status_reply(.Reset))
		}
		upload_free(u)
	}
	for d in t.downloads {
		download_free(d)
	}
	for f in t.fetches {
		reply(f.job, status_reply(.Reset))
		proto.blob_receiver_destroy(&f.recv)
		free(f)
	}
	for b in t.blob_uploads {
		reply(b.job, status_reply(.Reset))
		proto.blob_sender_destroy(&b.send)
		free(b)
	}
	clear(&t.uploads)
	clear(&t.downloads)
	clear(&t.fetches)
	clear(&t.blob_uploads)
}

@(private)
files_destroy :: proc(c: ^Conn) {
	files_reset(c)
	t := &c.transfers
	delete(t.uploads)
	delete(t.downloads)
	delete(t.fetches)
	delete(t.blob_uploads)
}

@(private)
upload_free :: proc(u: ^Upload) {
	ring_fail(u.ring)
	ring_release(u.ring)
	proto.transfer_sender_destroy(&u.send)
	free(u)
}

@(private)
download_free :: proc(d: ^Download) {
	ring_fail(d.ring)
	ring_release(d.ring)
	proto.transfer_receiver_destroy(&d.recv)
	free(d)
}

// files_step advances the transfers. It runs once per turn of the gateway
// thread.
@(private)
files_step :: proc(c: ^Conn, now: time.Tick) {
	if !lite.ready(&c.client) {
		return
	}
	t := &c.transfers
	for i := 0; i < len(t.uploads); {
		if upload_turn(c, t.uploads[i], now) {
			i += 1
		} else {
			upload_free(t.uploads[i])
			ordered_remove(&t.uploads, i)
		}
	}
	for i := 0; i < len(t.downloads); {
		if download_turn(c, t.downloads[i], now) {
			i += 1
		} else {
			download_free(t.downloads[i])
			ordered_remove(&t.downloads, i)
		}
	}
	for i := 0; i < len(t.fetches); {
		if fetch_turn(c, t.fetches[i], now) {
			i += 1
		} else {
			proto.blob_receiver_destroy(&t.fetches[i].recv)
			free(t.fetches[i])
			ordered_remove(&t.fetches, i)
		}
	}
	for b in t.blob_uploads {
		blob_upload_turn(c, b, now)
	}
}

// files_message handles a transfer message from the server.
@(private)
files_message :: proc(c: ^Conn, kind: proto.Message_Kind, pt: []u8) {
	t := &c.transfers
	now := time.tick_now()
	#partial switch kind {
	case .Upload_Ack:
		ack, count, missing, ok := proto.decode_transfer_ack(pt)
		if !ok {
			return
		}
		for u in t.uploads {
			if u.id != ack.id || u.job == nil {
				continue
			}
			u.last_heard = now
			done := proto.transfer_acked(&u.send, ack, count, missing, now)
			{
				sync.guard(&u.ring.mutex)
				u.ring.out = proto.transfer_sender_done(&u.send)
				sync.cond_broadcast(&u.ring.cond)
			}
			if done {
				reply(
					u.job,
					json_reply(201, Upload_JSON{id_string(u.id), u.job.params[0], u.ring.size}),
				)
				u.job = nil
			}
			return
		}
	case .Download_Chunk:
		id, index, data := proto.decode_transfer_chunk(pt)
		for d in t.downloads {
			if d.id == id {
				download_chunk(d, index, data, now)
				return
			}
		}
	case .Transfer_Cancel:
		id, reason := proto.decode_transfer_cancel(pt)
		for u, i in t.uploads {
			if u.id == id {
				if u.job != nil {
					reply(
						u.job,
						error_reply(
							502,
							"bad_gateway",
							fmt.tprintf("The server cancelled the upload (%v).", reason),
						),
					)
				}
				upload_free(u)
				ordered_remove(&t.uploads, i)
				return
			}
		}
		for d, i in t.downloads {
			if d.id == id {
				download_free(d)
				ordered_remove(&t.downloads, i)
				return
			}
		}
	case .Blob_Chunk:
		handle, index, data := proto.decode_blob_chunk(pt)
		for f in t.fetches {
			if f.handle == handle && f.handle != 0 {
				f.started = true
				f.last_chunk = now
				proto.blob_receive(&f.recv, index, data)
				return
			}
		}
	case .Blob_Need:
		handle, complete, count, indices, ok := proto.decode_blob_need(pt)
		if !ok {
			return
		}
		for b in t.blob_uploads {
			if b.handle != handle || b.handle == 0 {
				continue
			}
			b.last_heard = now
			switch {
			case proto.blob_need_failed(pt):
				b.tries += 1
				if b.tries >= BLOB_UPLOAD_TRIES {
					blob_upload_end(
						c,
						b,
						error_reply(400, "invalid", "The server rejected the picture."),
					)
					return
				}
				fallthrough
			case complete:
				// The server has everything. Announcing the picture again returns its id.
				proto.blob_sender_destroy(&b.send)
				b.handle = 0
				blob_put(c, b)
			case b.send.next >= proto.blob_chunk_count(len(b.send.data)):
				for i in 0 ..< count {
					proto.blob_sender_needs(&b.send, proto.blob_need_index(indices, i))
				}
			}
			return
		}
	}
}

// upload_turn sends as much of the received part of an upload as the pace
// allows. It returns false once the upload is finished or has been given up.
@(private)
upload_turn :: proc(c: ^Conn, u: ^Upload, now: time.Tick) -> bool {
	if u.job == nil {
		return false
	}
	avail: u64
	failed: bool
	{
		sync.guard(&u.ring.mutex)
		avail, failed = u.ring.in_, u.ring.failed
	}
	if failed {
		// The bot went away before the whole body arrived.
		cancel_buf: [proto.TRANSFER_CANCEL_SIZE]u8
		lite.send(&c.client, proto.encode_transfer_cancel(&cancel_buf, u.id, .Cancelled))
		reply(
			u.job,
			error_reply(
				400,
				"invalid",
				"The request body ended before the length given in Content-Length.",
			),
		)
		u.job = nil
		return false
	}
	if time.tick_diff(u.last_heard, now) > TRANSFER_QUIET {
		reply(
			u.job,
			error_reply(503, "unavailable", "The server stopped responding during the upload."),
		)
		u.job = nil
		return false
	}
	rate := f32(UPLOAD_MAX_RATE)
	if u.send.peer_rate > 0 {
		rate = min(rate, f32(u.send.peer_rate))
	}
	proto.transfer_refill(&u.send, now, rate, UPLOAD_BURST * rate / UPLOAD_MAX_RATE)
	out: [proto.MAX_PAYLOAD_SIZE]u8
	for {
		index, first, ok := proto.transfer_pick(&u.send, now)
		if !ok {
			break
		}
		start, end := proto.file_chunk_range(u.ring.size, index)
		if end > avail {
			break // the bot has not sent this part yet
		}
		at := start % RING_SIZE
		data := u.ring.buf[at:at + (end - start)]
		lite.send(&c.client, proto.encode_transfer_chunk(out[:], .Upload_Chunk, u.id, index, data))
		proto.transfer_sent(&u.send, index, first, int(end - start), now)
	}
	return true
}

// download_chunk stores a chunk of an attachment if the Ring has room for it,
// meaning the bot has already read the data that precedes it.
@(private)
download_chunk :: proc(d: ^Download, index: u32, data: []u8, now: time.Tick) {
	d.last_heard = now
	if !proto.transfer_wants(&d.recv, index, len(data)) {
		return
	}
	start, end := proto.file_chunk_range(d.recv.size, index)
	r := d.ring
	sync.guard(&r.mutex)
	if r.failed || end > r.out + RING_SIZE {
		return // the server sends it again once there is room
	}
	at := start % RING_SIZE
	copy(r.buf[at:], data)
	proto.transfer_got(&d.recv, index, len(data))
	r.in_ = min(u64(d.recv.base) * proto.FILE_CHUNK_DATA, r.size)
	sync.cond_broadcast(&r.cond)
}

// download_turn acks the received part of an attachment. It returns false
// once the download is finished or has been given up.
@(private)
download_turn :: proc(c: ^Conn, d: ^Download, now: time.Tick) -> bool {
	taken: u64
	failed: bool
	{
		sync.guard(&d.ring.mutex)
		taken, failed = d.ring.out, d.ring.failed
	}
	complete := proto.transfer_complete(&d.recv)
	switch {
	case failed && !complete:
		cancel_buf: [proto.TRANSFER_CANCEL_SIZE]u8
		lite.send(&c.client, proto.encode_transfer_cancel(&cancel_buf, d.id, .Cancelled))
		return false
	case complete && d.recv.complete_acks >= proto.TRANSFER_COMPLETE_ACKS:
		return false
	case !complete && time.tick_diff(d.last_heard, now) > TRANSFER_QUIET:
		return false
	case time.tick_diff(d.recv.last_ack, now) >= proto.TRANSFER_ACK_INTERVAL:
		download_ack(c, d, taken, now)
	}
	return true
}

// download_ack reports how much of an attachment has arrived, but no further
// than what the bot has read. The server sends at most one window past what
// has been acked, which is the amount the Ring has room for.
@(private)
download_ack :: proc(c: ^Conn, d: ^Download, taken: u64, now: time.Tick) {
	r := &d.recv
	r.last_ack = now
	complete := proto.transfer_complete(r)
	if complete {
		r.complete_acks += 1
	}
	missing: [proto.FILE_ACK_MAX_MISSING]u32
	n := 0
	for i := r.base; i < r.highest && n < len(missing); i += 1 {
		if r.have[i / 64] & (1 << (i % 64)) == 0 {
			missing[n] = i
			n += 1
		}
	}
	ack := proto.Transfer_Ack {
		id       = d.id,
		base     = min(r.base, u32(taken / proto.FILE_CHUNK_DATA)),
		highest  = r.highest,
		complete = complete,
	}
	out: [proto.MAX_PAYLOAD_SIZE]u8
	lite.send(&c.client, proto.encode_transfer_ack(out[:], .Download_Ack, ack, missing[:n]))
}

// fetch_turn asks again for the missing parts of a picture. It returns false
// once the fetch is finished.
@(private)
fetch_turn :: proc(c: ^Conn, f: ^Blob_Fetch, now: time.Tick) -> bool {
	if f.handle == 0 {
		return true // still waiting for the server to answer
	}
	if proto.blob_receiver_complete(&f.recv) {
		out: [proto.MAX_PAYLOAD_SIZE]u8
		msg, _ := proto.encode_blob_need(out[:], f.handle, true, nil)
		lite.send(&c.client, msg)
		r := Reply {
			status       = 200,
			body         = f.recv.data,
			content_type = sniff(f.recv.data),
		}
		f.recv.data = nil
		reply(f.job, r)
		return false
	}
	last := f.last_chunk if f.started else f.asked
	if time.tick_diff(last, now) > TRANSFER_QUIET {
		reply(
			f.job,
			error_reply(
				503,
				"unavailable",
				"The server stopped responding while the picture was being transferred.",
			),
		)
		return false
	}
	if time.tick_diff(f.asked, now) >= proto.CONTROL_RESEND &&
	   (!f.started || time.tick_diff(f.last_chunk, now) >= proto.CONTROL_RESEND) {
		f.asked = now
		missing_buf: [proto.BLOB_NEED_MAX_INDICES]u16
		missing := proto.blob_missing(&f.recv, missing_buf[:])
		out: [proto.MAX_PAYLOAD_SIZE]u8
		msg, _ := proto.encode_blob_need(out[:], f.handle, false, missing)
		lite.send(&c.client, msg)
	}
	return true
}

// blob_upload_turn sends an avatar's chunks at the configured pace and asks
// the server for its progress when the server has been quiet.
@(private)
blob_upload_turn :: proc(c: ^Conn, b: ^Blob_Upload, now: time.Tick) {
	if b.handle == 0 {
		return
	}
	elapsed := f32(time.duration_seconds(time.tick_diff(b.last_pace, now)))
	b.last_pace = now
	b.tokens = min(b.tokens + elapsed * BLOB_UPLOAD_RATE, BLOB_UPLOAD_BURST)
	buf: [proto.MAX_PAYLOAD_SIZE]u8
	for b.tokens > 0 {
		index, data, ok := proto.blob_next_chunk(&b.send)
		if !ok {
			break
		}
		lite.send(&c.client, proto.encode_blob_chunk(buf[:], b.handle, index, data))
		b.tokens -= f32(len(data))
	}
	if proto.blob_sender_idle(&b.send) &&
	   !b.asking &&
	   time.tick_diff(b.last_heard, now) > BLOB_UPLOAD_QUIET {
		if time.tick_diff(b.last_heard, now) > TRANSFER_QUIET {
			blob_upload_end(
				c,
				b,
				error_reply(
					503,
					"unavailable",
					"The server stopped responding while the picture was being transferred.",
				),
			)
			return
		}
		blob_put(c, b)
	}
}

Upload_JSON :: struct {
	id:   string, // to be listed in the `attachments` of a message
	name: string,
	size: u64,
}

// uploads_serve handles POST /uploads?name= on its HTTP thread. The body
// (Content-Length bytes) is streamed to the server as it is read, and the
// reply describes the upload once the server has all of it. The connection
// only stays open for another request if the whole body was read.
@(private)
uploads_serve :: proc(g: ^Gateway, c: ^http.Conn, req: ^http.Request) -> (keep_alive: bool) {
	if req.method != "POST" {
		r := error_reply(405, "method_not_allowed", "Uploads must be sent with POST.")
		r.allow = "POST"
		send(c, r, false)
		return false
	}
	j := Job {
		kind = .Call,
		run  = upload_run,
	}
	if r, refused := take_token(g, &j, req); refused {
		return refuse(c, req, r)
	}
	name, named := http.query_value(req.query, "name")
	switch {
	case !named || name == "":
		return refuse(
			c,
			req,
			error_reply(
				400,
				"invalid",
				"The name query parameter is required and gives the name of the file: ?name=<file name>.",
			),
		)
	case len(name) > proto.MAX_FILE_NAME:
		return refuse(
			c,
			req,
			error_reply(
				400,
				"invalid",
				fmt.tprintf(
					"The name query parameter can be at most %d bytes long.",
					proto.MAX_FILE_NAME,
				),
			),
		)
	case req.chunked || req.content_length <= 0:
		send(
			c,
			error_reply(
				411,
				"invalid",
				"An upload needs a Content-Length header and a body that is not empty.",
			),
			false,
		)
		return false
	}
	j.params[0] = name
	j.ring = ring_make(u64(req.content_length), 1)
	defer ring_release(j.ring)
	submit_start(g, &j)

	// Read the body into the ring as room becomes available.
	r := j.ring
	whole := true
	for {
		at, room: u64
		{
			sync.guard(&r.mutex)
			for !r.failed && r.in_ < r.size && r.in_ - r.out >= RING_SIZE {
				sync.cond_wait(&r.cond, &r.mutex)
			}
			if r.failed || r.in_ == r.size {
				whole = r.in_ == r.size
				break
			}
			at = r.in_ % RING_SIZE
			room = min(RING_SIZE - at, RING_SIZE - (r.in_ - r.out), r.size - r.in_)
		}
		n, ok := http.read_some(c, r.buf[at:at + room])
		sync.guard(&r.mutex)
		if !ok {
			r.failed = true
			whole = false
			break
		}
		r.in_ += u64(n)
	}
	send(c, submit_wait(&j), whole && req.keep_alive)
	return whole && req.keep_alive
}

// refuse replies to an upload that was rejected before its body was read.
// A small body is read and discarded so the connection can stay open for the
// next request. A body larger than MAX_BODY is not read, so the connection
// closes instead.
@(private)
refuse :: proc(c: ^http.Conn, req: ^http.Request, r: Reply) -> (keep_alive: bool) {
	keep_alive = req.keep_alive && !req.chunked && req.content_length <= MAX_BODY
	if keep_alive && req.content_length > 0 {
		body := make([]u8, req.content_length, context.temp_allocator)
		keep_alive = http.read_body(c, body)
	}
	send(c, r, keep_alive)
	return keep_alive
}

// upload_run announces the upload and starts it once the server accepts it.
@(private)
upload_run :: proc(c: ^Conn, j: ^Job) {
	j.answer = proc(c: ^Conn, j: ^Job, a: lite.Answer) {
		if a.status != .Ok {
			reply(j, status_reply(a.status))
			return
		}
		id, ok := proto.decode_attach_id(a.body)
		if !ok {
			reply(j, status_reply(.Internal))
			return
		}
		u := new(Upload)
		u.job, u.ring, u.id = j, j.ring, id
		u.last_heard = time.tick_now()
		sync.guard(&j.ring.mutex)
		j.ring.refs += 1
		proto.transfer_sender_init(&u.send, j.ring.size, u.last_heard)
		append(&c.transfers.uploads, u)
	}
	buf: [proto.ATTACH_PUT_MAX_SIZE]u8
	ask(
		c,
		j,
		.Attach_Put,
		proto.encode_attach_put(buf[:], {size = j.ring.size, name = j.params[0]}),
	)
}

// downloads_serve handles GET /attachments/{id} on its HTTP thread. Once the
// server reports the size, the bytes are written out as they arrive. It
// returns false if the connection has to close afterwards, which is the case
// when the download was cut short.
@(private)
downloads_serve :: proc(
	g: ^Gateway,
	c: ^http.Conn,
	req: ^http.Request,
	blob: string,
) -> (
	keep_alive: bool,
) {
	j := Job {
		kind = .Call,
		run  = download_run,
	}
	if r, refused := take_token(g, &j, req); refused {
		send(c, r, req.keep_alive)
		return req.keep_alive
	}
	id, ok := parse_u64(blob)
	if !ok || id == 0 {
		send(c, bad_id(blob), req.keep_alive)
		return req.keep_alive
	}
	j.scratch[0] = id
	r := submit(g, &j)
	if r.status != 200 {
		send(c, r, req.keep_alive)
		return req.keep_alive
	}
	ring := j.ring
	defer ring_release(ring)
	head := fmt.tprintf(
		"HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: %d\r\nCache-Control: no-cache\r\nConnection: %s\r\n\r\n",
		ring.size,
		"keep-alive" if req.keep_alive else "close",
	)
	if !http.send_all(c.sock, transmute([]u8)head) {
		ring_fail(ring)
		return false
	}
	for {
		at, n: u64
		{
			sync.guard(&ring.mutex)
			for !ring.failed && ring.in_ == ring.out && ring.out < ring.size {
				sync.cond_wait(&ring.cond, &ring.mutex)
			}
			if ring.out == ring.size {
				return req.keep_alive
			}
			if ring.failed {
				return false // cut short: closing the connection signals this
			}
			at = ring.out % RING_SIZE
			n = min(ring.in_ - ring.out, RING_SIZE - at)
		}
		if !http.send_all(c.sock, ring.buf[at:at + n]) {
			ring_fail(ring)
			return false
		}
		sync.guard(&ring.mutex)
		ring.out += n
		sync.cond_broadcast(&ring.cond)
	}
}

// download_run requests the attachment and starts receiving it.
@(private)
download_run :: proc(c: ^Conn, j: ^Job) {
	j.answer = proc(c: ^Conn, j: ^Job, a: lite.Answer) {
		if a.status != .Ok {
			reply(j, status_reply(a.status))
			return
		}
		size, id, ok := proto.decode_attach_get_answer(a.body)
		if !ok {
			reply(j, status_reply(.Internal))
			return
		}
		d := new(Download)
		d.ring, d.id = ring_make(size, 2), id // one reference for the Download, one for the HTTP thread
		d.last_heard = time.tick_now()
		proto.transfer_receiver_init(&d.recv, size)
		append(&c.transfers.downloads, d)
		download_ack(c, d, 0, d.last_heard)
		j.ring = d.ring
		reply(j, {status = 200})
	}
	buf: [8]u8
	ask(c, j, .Attach_Get, proto.encode_attach_id(&buf, j.scratch[0]))
}

// GET /blobs/{id}: a picture (an avatar, an emoji or the server's icon),
// returned whole, with the content type determined from its first bytes.
@(private)
blob_run :: proc(c: ^Conn, j: ^Job) {
	id, ok := param_id(j, 0)
	if !ok {
		reply(j, bad_id(j.params[0]))
		return
	}
	j.answer = proc(c: ^Conn, j: ^Job, a: lite.Answer) {
		if a.status != .Ok {
			reply(j, status_reply(a.status))
			return
		}
		size, handle, ok := proto.decode_blob_get_answer(a.body)
		f := new(Blob_Fetch)
		if !ok || !proto.blob_receiver_init(&f.recv, size) {
			free(f)
			reply(j, status_reply(.Internal))
			return
		}
		f.job, f.handle = j, handle
		f.asked = time.tick_now()
		append(&c.transfers.fetches, f)
	}
	buf: [proto.BLOB_GET_SIZE]u8
	ask(c, j, .Blob_Get, proto.encode_blob_id(&buf, proto.Blob_Id(id)))
}

// PUT /me/avatar takes a JPEG as the body (at most 64 KiB and 256 pixels per
// side, as a client creates them) and returns /me. DELETE /me/avatar removes
// the avatar and returns /me.
@(private)
avatar_run :: proc(c: ^Conn, j: ^Job) {
	data := j.body
	if len(data) == 0 || len(data) > proto.MAX_AVATAR_SIZE {
		reply(
			j,
			error_reply(
				400,
				"invalid",
				fmt.tprintf(
					"The avatar must be a JPEG of at most %d bytes.",
					proto.MAX_AVATAR_SIZE,
				),
			),
		)
		return
	}
	w, h, is_jpeg := jpeg_size(data)
	if !is_jpeg || w > proto.MAX_AVATAR_SIDE || h > proto.MAX_AVATAR_SIDE {
		reply(
			j,
			error_reply(
				400,
				"invalid",
				fmt.tprintf(
					"The avatar must be a JPEG of at most %d pixels per side.",
					proto.MAX_AVATAR_SIDE,
				),
			),
		)
		return
	}
	b := new(Blob_Upload)
	b.job = j
	b.put = {
		kind   = .Avatar,
		size   = len(data),
		width  = w,
		height = h,
	}
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, data)
	sha2.final(&ctx, b.put.hash[:])
	b.last_heard = time.tick_now()
	append(&c.transfers.blob_uploads, b)
	blob_put(c, b)
}

@(private)
avatar_delete_run :: proc(c: ^Conn, j: ^Job) {
	set_avatar(c, j, 0)
}

// blob_put announces an avatar. The server either already has it or tells us
// which handle to send it under.
@(private)
blob_put :: proc(c: ^Conn, b: ^Blob_Upload) {
	b.asking = true
	b.last_heard = time.tick_now()
	b.job.answer = proc(c: ^Conn, j: ^Job, a: lite.Answer) {
		b: ^Blob_Upload
		for x in c.transfers.blob_uploads {
			if x.job == j {
				b = x
			}
		}
		if b == nil {
			return
		}
		b.asking = false
		if a.status != .Ok {
			blob_upload_end(c, b, status_reply(a.status))
			return
		}
		blob, have, handle, ok := proto.decode_blob_put_answer(a.body)
		switch {
		case !ok:
			blob_upload_end(c, b, status_reply(.Internal))
		case have:
			blob_upload_end(c, b, {})
			set_avatar(c, j, blob)
		case handle != b.handle:
			// Start sending it, or start over.
			proto.blob_sender_destroy(&b.send)
			now := time.tick_now()
			b.handle = handle
			b.send = {
				data = j.body,
			}
			b.last_pace, b.last_heard = now, now
		}
	}
	buf: [proto.BLOB_PUT_SIZE]u8
	ask(c, b.job, .Blob_Put, proto.encode_blob_put(&buf, b.put))
}

// blob_upload_end removes an avatar's upload and replies with `r`, unless `r`
// is {} (then the caller continues with the Job).
@(private)
blob_upload_end :: proc(c: ^Conn, b: ^Blob_Upload, r: Reply) {
	for x, i in c.transfers.blob_uploads {
		if x == b {
			ordered_remove(&c.transfers.blob_uploads, i)
			break
		}
	}
	proto.blob_sender_destroy(&b.send)
	if r.status != 0 {
		reply(b.job, r)
	}
	free(b)
}

@(private)
set_avatar :: proc(c: ^Conn, j: ^Job, blob: proto.Blob_Id) {
	j.answer = answered_me
	buf: [64]u8
	ask(
		c,
		j,
		.Profile_Set,
		proto.encode_profile_set(buf[:], {mask = proto.PROFILE_AVATAR, avatar = blob}),
	)
}

// jpeg_size returns a JPEG's width and height from its frame header. It
// returns false if the data is not a JPEG.
jpeg_size :: proc(data: []u8) -> (width, height: int, ok: bool) {
	if len(data) < 4 || data[0] != 0xFF || data[1] != 0xD8 {
		return
	}
	i := 2
	for i + 4 <= len(data) {
		if data[i] != 0xFF {
			return
		}
		marker := data[i + 1]
		switch {
		case marker == 0xFF:
			i += 1 // fill byte
			continue
		case marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8):
			i += 2 // marker without a length
			continue
		case marker == 0xD9 || marker == 0xDA:
			return // end of image or start of scan, with no frame header before it
		}
		length := int(data[i + 2]) << 8 | int(data[i + 3])
		if length < 2 || i + 2 + length > len(data) {
			return
		}
		// Start of frame: any but DHT (C4), JPG (C8) and DAC (CC).
		if marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC {
			if length < 7 {
				return
			}
			height = int(data[i + 5]) << 8 | int(data[i + 6])
			width = int(data[i + 7]) << 8 | int(data[i + 8])
			return width, height, width > 0 && height > 0
		}
		i += 2 + length
	}
	return
}

// sniff returns the content type of a picture, based on its first bytes.
@(private)
sniff :: proc(data: []u8) -> string {
	switch {
	case len(data) >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF:
		return "image/jpeg"
	case len(data) >= 8 && string(data[:8]) == "\x89PNG\r\n\x1a\n":
		return "image/png"
	case len(data) >= 12 && string(data[:4]) == "RIFF" && string(data[8:12]) == "WEBP":
		return "image/webp"
	case len(data) >= 6 && (string(data[:6]) == "GIF87a" || string(data[:6]) == "GIF89a"):
		return "image/gif"
	}
	return "application/octet-stream"
}

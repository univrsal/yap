package server

import "core:crypto"
import "core:log"
import "core:time"

import "common:imagekind"
import "common:proto"

// Blobs are uploaded to and downloaded from the server in chunks. How blobs
// are requested is described in src/common/proto/messages.odin and how the
// chunks are transferred in src/common/proto/blob.odin.
//
// A client announces a picture with Blob_Put, which contains its kind (a
// message's Image or an Avatar, see profiles.odin), size, hash and
// dimensions. If the blob store already has that content, the answer
// contains the blob's id and nothing is uploaded. Otherwise the client
// gets a handle and sends the chunks under it. Once all chunks have
// arrived, the content is checked against what was announced (the hash and,
// for a picture, the size given by its JPEG header) and then stored (see
// blobs.odin). The client then sends Blob_Put again, which is answered with
// the blob's id.
//
// Blob_Get sends a blob to anyone who may see it (see blob_visible), under
// a handle of its own.
//
// Each connection can have one upload and one download at a time. They are
// rate limited so that a picture can't crowd out voice data.

// The rate limits per connection, in each direction.
TRANSFER_RATE :: 256 * 1024 // bytes per second
TRANSFER_BURST :: 32 * 1024 // bytes that may go out at once
// An upload that doesn't receive any data for this long is dropped.
UPLOAD_TIMEOUT :: 15 * time.Second

// Upload is a blob that is being received from one connection.
Upload :: struct {
	active:    bool,
	handle:    u64,
	put:       proto.Blob_Put, // the announcement the upload started with
	recv:      proto.Blob_Receiver,
	last_need: time.Tick,
	last_data: time.Tick,
}

// Download is a blob that is being sent to one connection.
Download :: struct {
	active: bool,
	blob:   Blob_Id,
	handle: u64, // the handle that the chunks are sent under
	data:   []u8, // owned
	send:   proto.Blob_Sender,
	pace:   proto.Bucket, // bytes that may be sent to this connection right now
}

// new_handle generates the handle of a transfer. It is random so that it
// can't be mistaken for the handle of another transfer, and never 0.
@(private = "file")
new_handle :: proc() -> (handle: u64) {
	for handle == 0 {
		crypto.rand_bytes(([^]u8)(&handle)[:size_of(handle)])
	}
	return
}

blob_put_request :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	p, ok := proto.decode_blob_put(body)
	switch {
	// Only profile pictures are uploaded this way. Files are handled in
	// attachments.odin.
	case !ok || p.kind != .Avatar || p.width == 0 || p.height == 0:
		respond(u, id, .Invalid)
		return
	case p.size <= 0 ||
	     p.size > proto.MAX_AVATAR_SIZE ||
	     p.width > proto.MAX_AVATAR_SIDE ||
	     p.height > proto.MAX_AVATAR_SIDE:
		respond(u, id, .Too_Large)
		return
	}
	answer: [proto.BLOB_PUT_ANSWER_SIZE]u8
	// Only a picture that is already stored as one is taken without being
	// uploaded. Otherwise anybody who knows a file's hash could find out
	// whether somebody has attached it somewhere. (Uploading it ends up with
	// the same blob, which is fine: whoever uploads it has it.)
	if blob, found := blob_find(&s.blobs, p.hash); found {
		if b, known := blob_get(&s.blobs, blob); known && b.kind == .Avatar {
			respond(u, id, .Ok, proto.encode_blob_put_answer(&answer, blob, true, 0))
			return
		}
	}

	up := &u.upload
	// If the client asks again for the upload that is already in progress,
	// it gets the same handle.
	if !up.active || up.put != p {
		upload_end(u)
		if !proto.blob_receiver_init(&up.recv, p.size) {
			respond(u, id, .Too_Large)
			return
		}
		up.active = true
		up.handle = new_handle()
		up.put = p
		up.last_data = time.tick_now()
		log.debugf(
			"%s is uploading a %dx%d picture, %d bytes",
			conn_label(u),
			p.width,
			p.height,
			p.size,
		)
	}
	respond(u, id, .Ok, proto.encode_blob_put_answer(&answer, 0, false, up.handle))
}

@(private = "file")
upload_end :: proc(u: ^Conn) {
	if u.upload.active {
		proto.blob_receiver_destroy(&u.upload.recv)
	}
	u.upload = {}
}

handle_blob_chunk :: proc(s: ^Server, c: ^Client, pt: []byte) {
	u := c.conn
	handle, index, data := proto.decode_blob_chunk(pt)
	if !u.upload.active || u.upload.handle != handle {
		return
	}
	if done, stored := upload_chunk(s, u, index, data); done {
		out: [proto.MAX_PAYLOAD_SIZE]u8
		msg, _ := proto.encode_blob_need(out[:], handle, stored, nil, failed = !stored)
		send_message(s, c, msg)
	}
}

// upload_chunk handles one chunk of a connection's upload. Once all chunks
// have arrived (`done`), the content is checked against the announcement
// and stored if it matches. The upload is over either way.
upload_chunk :: proc(s: ^Server, u: ^Conn, index: int, data: []u8) -> (done, stored: bool) {
	up := &u.upload
	proto.blob_receive(&up.recv, index, data)
	up.last_data = time.tick_now()
	if !proto.blob_receiver_complete(&up.recv) {
		return false, false
	}

	// All chunks have arrived. Check that the content is what was announced.
	content := up.recv.data
	put := up.put
	width, height, is_jpeg := imagekind.jpeg_size(content)
	switch {
	case blob_hash(content) != put.hash:
		log.warnf("%s uploaded a picture that doesn't match its announced hash", conn_label(u))
	case !is_jpeg || width != put.width || height != put.height:
		log.warnf(
			"%s uploaded a picture that isn't a %dx%d JPEG",
			conn_label(u),
			put.width,
			put.height,
		)
	case:
		blob, ok := blob_put(&s.blobs, put.kind, content, width, height, i64(u.account.id))
		if ok {
			stored = true
			log.debugf("%s uploaded blob %d (%d bytes)", conn_label(u), blob, len(content))
		}
	}
	upload_end(u)
	return true, stored
}

blob_get_request :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	blob, ok := proto.decode_blob_id(body)
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	b, found := blob_get(&s.blobs, blob)
	visible :=
		found &&
		(b.kind == .Emoji_Sheet && blob == s.emoji.blob ||
				b.kind == .Emoji_Frames && emoji_frames_known(s, blob) ||
				is_avatar(s, blob) ||
				persona_avatar_known(s, blob))
	if !visible {
		respond(u, id, .Not_Found)
		return
	}
	down := &u.download
	answer: [proto.BLOB_GET_ANSWER_SIZE]u8
	if down.active && down.blob == blob {
		// The client asked again for a download that is already in progress.
		respond(u, id, .Ok, proto.encode_blob_get_answer(&answer, b.size, down.handle))
		return
	}
	data, read_ok := blob_read(&s.blobs, blob)
	if !read_ok {
		respond(u, id, .Internal)
		return
	}
	download_end(down)
	down^ = {
		active = true,
		blob = blob,
		handle = new_handle(),
		data = data,
		send = {data = data},
		pace = {last = time.tick_now()}, // empty until the first refill
	}
	log.debugf("sending blob %d to %s", blob, conn_label(u))
	respond(u, id, .Ok, proto.encode_blob_get_answer(&answer, len(data), down.handle))
}

// download_end ends a download and frees the data that it was sending.
download_end :: proc(down: ^Download) {
	proto.blob_sender_destroy(&down.send)
	delete(down.data)
	down^ = {}
}

handle_blob_need :: proc(s: ^Server, u: ^Conn, pt: []byte) {
	handle, complete, count, indices, ok := proto.decode_blob_need(pt)
	if !ok {
		return
	}
	down := &u.download
	if !down.active || down.handle != handle {
		return
	}
	if complete {
		download_end(down)
		return
	}
	for i in 0 ..< count {
		proto.blob_sender_needs(&down.send, proto.blob_need_index(indices, i))
	}
}

// transfers_sync keeps transfers moving by sending chunks to every
// connection that is downloading and reminders to every connection that is
// uploading.
transfers_sync :: proc(s: ^Server) {
	now := time.tick_now()
	for _, u in s.conns {
		c := sending_session(s, u)
		if c == nil {
			continue
		}
		if up := &u.upload; up.active {
			if time.tick_since(up.last_data) > UPLOAD_TIMEOUT {
				log.debugf("%s stopped uploading", conn_label(u))
				upload_end(u)
			} else {
				send_blob_need(s, c, up)
			}
		}
		send_chunks(s, c, &u.download, now)
	}
}

// send_blob_need tells a client which chunks of its upload are missing, but
// only once chunks have stopped arriving. Otherwise chunks that are still
// on their way would be requested again and sent twice.
send_blob_need :: proc(s: ^Server, c: ^Client, up: ^Upload) {
	if time.tick_since(up.last_data) < proto.CONTROL_RESEND ||
	   time.tick_since(up.last_need) < proto.CONTROL_RESEND {
		return
	}
	up.last_need = time.tick_now()
	missing_buf: [proto.BLOB_NEED_MAX_INDICES]u16
	missing := proto.blob_missing(&up.recv, missing_buf[:])
	out: [proto.MAX_PAYLOAD_SIZE]u8
	msg, _ := proto.encode_blob_need(out[:], up.handle, false, missing)
	send_message(s, c, msg)
}

// send_chunks sends as much of a download as the connection's rate limit
// allows.
send_chunks :: proc(s: ^Server, c: ^Client, down: ^Download, now: time.Tick) {
	if !down.active {
		return
	}
	proto.bucket_refill(&down.pace, now, TRANSFER_RATE, TRANSFER_BURST)

	out: [proto.MAX_PAYLOAD_SIZE]u8
	for down.pace.tokens > 0 {
		index, data, ok := proto.blob_next_chunk(&down.send)
		if !ok {
			break
		}
		send_message(s, c, proto.encode_blob_chunk(out[:], down.handle, index, data))
		down.pace.tokens -= f64(len(data))
	}
}

// drop_conn_transfers ends the uploads and downloads of a connection that is leaving.
drop_conn_transfers :: proc(u: ^Conn) {
	upload_end(u)
	download_end(&u.download)
}

package server

import "core:crypto"
import "core:log"
import "core:time"

import "common:proto"

/*
Blobs on their way in and out (src/common/proto/msgs.odin says how
they're asked for, src/common/proto/blob.odin how the chunks move).

A client announces a picture with Blob_Put: its kind (a message's
Image, or an Avatar: profiles.odin), size, hash and dimensions. Content the store has already is answered with its id and
isn't sent again. Anything else gets a handle, and the chunks come
under it; once they're all there the content is checked against what
was announced (the hash, and for a picture the size its JPEG header
gives) and kept (blobs.odin). The client then asks Blob_Put again,
which answers with the id.

Blob_Get sends a blob to whoever may see it (blob_visible), under a
handle of its own.

Each connection has one upload and one download at a time, paced so a
picture can't crowd out voice.
*/

// Per connection, in each direction.
TRANSFER_RATE :: 256 * 1024 // bytes per second
TRANSFER_BURST :: 32 * 1024 // bytes that may go out at once
// An upload that goes quiet for this long is dropped.
UPLOAD_TIMEOUT :: 15 * time.Second

// Upload is a blob on its way in from one connection.
Upload :: struct {
	active:    bool,
	handle:    u64,
	put:       proto.Blob_Put, // what it was announced as
	recv:      proto.Blob_Receiver,
	last_need: time.Tick,
	last_data: time.Tick,
}

// Download is a blob on its way out to one connection.
Download :: struct {
	active: bool,
	blob:   Blob_Id,
	handle: u64, // what its chunks go under
	data:   []u8, // owned
	send:   proto.Blob_Sender,
	tokens: f32, // bytes this connection may be sent right now
	last:   time.Tick,
}

// new_handle is a transfer's handle: random, so it can't be taken for
// another's, and never 0.
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
	// Pictures, for messages and for profiles, are all that's uploaded.
	case !ok || (p.kind != .Image && p.kind != .Avatar) || p.width == 0 || p.height == 0:
		respond(u, id, .Invalid)
		return
	case p.size <= 0 || p.size > proto.MAX_IMAGE_SIZE:
		respond(u, id, .Too_Large)
		return
	case p.kind == .Avatar &&
	     (p.size > proto.MAX_AVATAR_SIZE || p.width > proto.MAX_AVATAR_SIDE || p.height > proto.MAX_AVATAR_SIDE):
		respond(u, id, .Too_Large)
		return
	}
	answer: [proto.BLOB_PUT_ANSWER_SIZE]u8
	if blob, found := blob_find(&s.blobs, p.hash); found {
		respond(u, id, .Ok, proto.encode_blob_put_answer(&answer, blob, true, 0))
		return
	}

	up := &u.upload
	// Asked again for the one on its way: the same handle.
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
		log.debugf("%s is uploading a %dx%d picture, %d bytes", conn_label(u), p.width, p.height, p.size)
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

/*
upload_chunk takes one chunk of a connection's upload. Once they're all
there (`done`) the content is checked against what was announced and,
if it's that, stored; the upload is over either way.
*/
upload_chunk :: proc(s: ^Server, u: ^Conn, index: int, data: []u8) -> (done, stored: bool) {
	up := &u.upload
	proto.blob_receive(&up.recv, index, data)
	up.last_data = time.tick_now()
	if !proto.blob_receiver_complete(&up.recv) {
		return false, false
	}

	// All there: is it what it said it would be?
	content := up.recv.data
	put := up.put
	width, height, is_jpeg := jpeg_size(content)
	switch {
	case blob_hash(content) != put.hash:
		log.warnf("%s uploaded a picture that isn't what it announced", conn_label(u))
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
		(b.kind == .Image && blob_visible(s, u.account.id, blob) ||
				b.kind == .Emoji_Sheet && blob == s.emoji.blob ||
				is_avatar(s, blob))
	if !visible {
		respond(u, id, .Not_Found)
		return
	}
	down := &u.download
	answer: [proto.BLOB_GET_ANSWER_SIZE]u8
	if down.active && down.blob == blob {
		// Asked again: it's on its way.
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
		last = time.tick_now(),
	}
	log.debugf("sending blob %d to %s", blob, conn_label(u))
	respond(u, id, .Ok, proto.encode_blob_get_answer(&answer, len(data), down.handle))
}

// download_end lets a download go, and what it was sending.
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

// transfers_sync keeps transfers moving: chunks out to whoever is waiting
// for one, and reminders to whoever is uploading.
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

// send_blob_need tells a client which chunks of its upload are missing,
// once they've stopped coming: whatever is still on its way would
// otherwise be asked for again and sent twice.
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

// send_chunks pushes as much of a download as the connection's allowance
// covers.
send_chunks :: proc(s: ^Server, c: ^Client, down: ^Download, now: time.Tick) {
	if !down.active {
		return
	}
	elapsed := f32(time.duration_seconds(time.tick_diff(down.last, now)))
	down.last = now
	down.tokens = min(down.tokens + elapsed * TRANSFER_RATE, TRANSFER_BURST)

	out: [proto.MAX_PAYLOAD_SIZE]u8
	for down.tokens > 0 {
		index, data, ok := proto.blob_next_chunk(&down.send)
		if !ok {
			break
		}
		send_message(s, c, proto.encode_blob_chunk(out[:], down.handle, index, data))
		down.tokens -= f32(len(data))
	}
}

// drop_conn_transfers ends whatever a leaving connection was transferring.
drop_conn_transfers :: proc(u: ^Conn) {
	upload_end(u)
	download_end(&u.download)
}

/*
jpeg_size is the width and height a JPEG's header gives, from its first
start-of-frame segment; false if `data` isn't a JPEG that has one.
*/
jpeg_size :: proc(data: []u8) -> (width, height: int, ok: bool) {
	if len(data) < 4 || data[0] != 0xFF || data[1] != 0xD8 {
		return
	}
	at := 2
	for at + 4 <= len(data) {
		if data[at] != 0xFF {
			return
		}
		marker := data[at + 1]
		switch marker {
		case 0xFF:
			at += 1 // fill byte
			continue
		case 0x01, 0xD0 ..= 0xD7:
			at += 2 // no length
			continue
		case 0xD9, 0xDA:
			return // the end, or the image data, before any frame
		}
		length := int(data[at + 2]) << 8 | int(data[at + 3])
		if length < 2 || at + 2 + length > len(data) {
			return
		}
		switch marker {
		// Start of frame, of every kind but the ones that aren't (C4 is a
		// Huffman table, C8 reserved, CC arithmetic coding conditioning).
		case 0xC0 ..= 0xC3, 0xC5 ..= 0xC7, 0xC9 ..= 0xCB, 0xCD ..= 0xCF:
			if length < 7 {
				return
			}
			height = int(data[at + 5]) << 8 | int(data[at + 6])
			width = int(data[at + 7]) << 8 | int(data[at + 8])
			return width, height, width > 0 && height > 0
		}
		at += 2 + length
	}
	return
}

package conn

import "core:crypto/hash"
import "core:time"

import "common:proto"
import log "common:wlog"

// Our own pictures, an avatar or the server's picture, are uploaded here, one
// at a time. A picture is announced with Blob_Put, which answers with the
// handle its chunks are sent under (or with the picture's id if the server
// has it already), the chunks are sent at UPLOAD_RATE, and the server's
// Blob_Need says what is missing or that it is all there. Announcing it again
// then gets us its id, which is set as the avatar (profiles.odin) or along
// with the server's name and description (server_info.odin).
//
// Messages have an outbox of their own (messages.odin), and the two don't wait
// for each other.

// How many times a picture is sent again after the server rejected it.
UPLOAD_TRIES :: 3
// How fast a picture is uploaded, and how many bytes may be sent at once.
UPLOAD_RATE :: 256 * 1024 // bytes per second
UPLOAD_BURST :: 32 * 1024
// If the server has said nothing about an upload for this long, the picture is
// announced again, and the answer tells us how far the upload got.
UPLOAD_QUIET :: 3 * time.Second

Picture_State :: enum {
	Put, // the picture has to be announced (Blob_Put)
	Upload, // ... and sent
	Set, // it has to be set as the avatar or the server's picture
}

// Upload is the bytes of a picture on their way to the server.
Upload :: struct {
	handle:     u64,
	send:       proto.Blob_Sender,
	pace:       proto.Bucket,
	last_heard: time.Tick, // when the server last said anything about the upload
}

// Picture_Up is a picture of ours that is on its way.
Picture_Up :: struct {
	tag:    u64, // names it in the answers to its requests
	// With `server`, it is the server's picture, which is set together with the
	// server's name and description (owned; see server_info.odin). Otherwise it
	// is our avatar.
	server: bool,
	name:   string,
	about:  string,
	// The JPEG (owned), how it is announced, and its id once the server has it.
	jpeg:   []u8,
	put:    proto.Blob_Put,
	blob:   proto.Blob_Id,
	state:  Picture_State,
	asking: bool, // a request for it is pending
	tries:  int,
	upload: Upload,
}

// What the UI is shown: whether a picture is on its way.
View_Uploading :: struct {
	avatar: bool,
	server: bool,
}

// picture_upload queues a picture to be uploaded and set. It takes over the
// image's JPEG and the strings (`name` and `about`, for the server's picture).
picture_upload :: proc(
	c: ^Server_Conn,
	image: Chat_Image,
	server := false,
	name := "",
	about := "",
) {
	p := Picture_Up {
		tag = new_nonce(),
		server = server,
		name = name,
		about = about,
		jpeg = image.jpeg,
		state = .Put,
		put = {kind = .Avatar, size = len(image.jpeg), width = image.width, height = image.height},
	}
	hash.hash_bytes_to_buffer(.SHA256, image.jpeg, p.put.hash[:])
	append(&c.blobs.pictures, p)
	publish_uploading(c)
}

// publish_uploading tells the UI whether a picture of ours is on its way.
publish_uploading :: proc(c: ^Server_Conn) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	v.uploading = {}
	for p in c.blobs.pictures {
		if p.server {
			v.uploading.server = true
		} else {
			v.uploading.avatar = true
		}
	}
}

picture_destroy :: proc(p: ^Picture_Up) {
	delete(p.name)
	delete(p.about)
	delete(p.jpeg)
	proto.blob_sender_destroy(&p.upload.send)
	p^ = {}
}

// pictures_restart is called when the connection starts over. The server
// forgot the uploads, which are begun again, and with `forget` they are
// dropped.
pictures_restart :: proc(c: ^Server_Conn, forget: bool) {
	if forget {
		for &p in c.blobs.pictures {
			picture_destroy(&p)
		}
		clear(&c.blobs.pictures)
	}
	for &p in c.blobs.pictures {
		p.asking = false
		if p.blob == 0 {
			p.state = .Put
			proto.blob_sender_destroy(&p.upload.send)
			p.upload = {}
		}
	}
	publish_uploading(c)
}

// picture_head returns the picture at the head of the queue if it is the one
// with `tag`, and nil otherwise.
picture_head :: proc(c: ^Server_Conn, tag: u64) -> ^Picture_Up {
	if len(c.blobs.pictures) == 0 || c.blobs.pictures[0].tag != tag {
		return nil
	}
	return &c.blobs.pictures[0]
}

// picture_done drops the picture at the head of the queue, which has been set.
picture_done :: proc(c: ^Server_Conn) {
	picture_destroy(&c.blobs.pictures[0])
	ordered_remove(&c.blobs.pictures, 0)
	publish_uploading(c)
}

// picture_give_up drops the picture at the head of the queue and says why.
picture_give_up :: proc(c: ^Server_Conn, why: string) {
	notify(c, false, why)
	picture_done(c)
}

// picture_retry sends the head picture again from the start, because the
// server no longer has it.
picture_retry :: proc(p: ^Picture_Up) {
	p.blob, p.state = 0, .Put
}

// drive_pictures advances the picture at the head of the queue.
drive_pictures :: proc(c: ^Server_Conn) {
	if len(c.blobs.pictures) == 0 || !c.has_current || !c.convs.synced {
		return
	}
	p := &c.blobs.pictures[0]
	switch p.state {
	case .Put:
		picture_announce(c, p)
	case .Upload:
		upload_step(c, p)
	case .Set:
		if !p.asking {
			p.asking = true
			if p.server {
				server_info_post(c, p)
			} else {
				avatar_post(c, p)
			}
		}
	}
}

@(private = "file")
picture_announce :: proc(c: ^Server_Conn, p: ^Picture_Up) {
	if p.asking {
		return
	}
	p.asking = true
	buf: [proto.BLOB_PUT_SIZE]u8
	request(c, .Blob_Put, proto.encode_blob_put(&buf, p.put), put_done, p.tag)
}

@(private = "file")
put_done :: proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
	p := picture_head(c, tag)
	if p == nil || p.state == .Set {
		return
	}
	p.asking = false
	#partial switch status {
	case .Ok:
	case .Reset:
		return // asked again on the new connection
	case:
		picture_give_up(c, "The server refused to accept the picture.")
		return
	}
	blob, have, handle, ok := proto.decode_blob_put_answer(body)
	switch {
	case !ok:
		return
	case have:
		p.blob = blob
		p.state = .Set
		proto.blob_sender_destroy(&p.upload.send)
		p.upload = {}
	case p.state == .Upload && p.upload.handle == handle:
	// The upload is still in progress.
	case:
		// Start (or start over) sending it.
		proto.blob_sender_destroy(&p.upload.send)
		now := time.tick_now()
		p.upload = {
			handle = handle,
			send = {data = p.jpeg},
			pace = {last = now}, // empty until the first refill
			last_heard = now,
		}
		p.state = .Upload
		log.debugf("uploading a %dx%d picture, %d bytes", p.put.width, p.put.height, p.put.size)
	}
}

@(private = "file")
upload_step :: proc(c: ^Server_Conn, p: ^Picture_Up) {
	up := &p.upload
	now := time.tick_now()
	proto.bucket_refill(&up.pace, now, UPLOAD_RATE, UPLOAD_BURST)
	buf: [proto.MAX_PAYLOAD_SIZE]u8
	for up.pace.tokens > 0 {
		index, data, ok := proto.blob_next_chunk(&up.send)
		if !ok {
			break
		}
		send_data(c, proto.encode_blob_chunk(buf[:], up.handle, index, data))
		up.pace.tokens -= f64(len(data))
	}
	if proto.blob_sender_idle(&up.send) &&
	   !p.asking &&
	   time.tick_since(up.last_heard) > UPLOAD_QUIET {
		up.last_heard = now
		picture_announce(c, p)
	}
}

// upload_need handles the server telling us how our upload is going. It returns
// false if the packet isn't about our upload.
upload_need :: proc(c: ^Server_Conn, pt: []u8) -> bool {
	handle, complete, count, indices, ok := proto.decode_blob_need(pt)
	if !ok || len(c.blobs.pictures) == 0 {
		return false
	}
	p := &c.blobs.pictures[0]
	if p.state != .Upload || p.upload.handle != handle {
		return false
	}
	p.upload.last_heard = time.tick_now()
	switch {
	case proto.blob_need_failed(pt):
		p.tries += 1
		if p.tries >= UPLOAD_TRIES {
			picture_give_up(
				c,
				"A picture couldn't be sent because the server rejected the upload.",
			)
			return true
		}
		log.warn("the server rejected an uploaded picture; sending it again")
		fallthrough
	case complete:
		// Everything has arrived: announcing the picture again gets us its id.
		proto.blob_sender_destroy(&p.upload.send)
		p.upload = {}
		p.state = .Put
		p.asking = false
	case p.upload.send.next >= proto.blob_chunk_count(len(p.jpeg)):
		// After the first pass, send the missing chunks again.
		for i in 0 ..< count {
			proto.blob_sender_needs(&p.upload.send, proto.blob_need_index(indices, i))
		}
	}
	return true
}

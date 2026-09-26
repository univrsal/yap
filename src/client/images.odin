package client

import log "../common/wlog"
import "core:time"

import "../proto"

/*
Chat images on the client: uploading the one being posted, and fetching
the ones other people posted (see src/proto/blob.odin for the transfer, and
src/proto/chat.odin for how a message names an image).

Both directions run one image at a time, paced so a transfer doesn't
crowd out voice. Fetching is newest first: those are the messages on
screen.

Images stay in memory as the JPEG they arrived as; the UI decodes them
(ui_images.odin). Once past IMAGE_CACHE_BYTES the oldest are dropped,
and fetched again if they're scrolled back to.
*/

// How fast an image is uploaded, and how much may go at once.
IMAGE_UPLOAD_RATE :: 256 * 1024 // bytes per second
IMAGE_UPLOAD_BURST :: 32 * 1024
// How much of other people's images to keep.
IMAGE_CACHE_BYTES :: 16 * 1024 * 1024

Image_State :: enum {
	Wanted, // queued to fetch
	Loading,
	Ready,
	Gone, // the server doesn't have it any more
}

Client_Image :: struct {
	info:      proto.Image_Info,
	state:     Image_State,
	data:      []u8, // the JPEG, once Ready
	recv:      proto.Blob_Receiver,
	requested:  time.Tick, // when we last asked for something
	last_chunk: time.Tick,
	started:    bool, // chunks have begun arriving
}

Image_Client :: struct {
	cache:  map[u32]^Client_Image,
	queue:  [dynamic]u32, // ids to fetch, newest first
	active: u32, // the one being fetched, 0 for none
	bytes:  int, // what the ready ones take up
	// Headless: where to save the images that arrive.
	dir:    string,
}

images_destroy :: proc(c: ^Voice_Client) {
	for _, img in c.images.cache {
		image_release(c, img)
		free(img)
	}
	delete(c.images.cache)
	delete(c.images.queue)
}

@(private = "file")
image_release :: proc(c: ^Voice_Client, img: ^Client_Image) {
	if img.state == .Ready {
		c.images.bytes -= len(img.data)
	}
	delete(img.data)
	img.data = nil
	proto.blob_receiver_destroy(&img.recv)
}

// image_want makes sure we have (or will fetch) the image a chat entry
// names. An id of 0 means the server dropped it.
image_want :: proc(c: ^Voice_Client, info: proto.Image_Info) {
	if info.id == 0 || int(info.size) > proto.MAX_BLOB_SIZE {
		return
	}
	if img, seen := c.images.cache[info.id]; seen {
		img.info = info
		// Coming back to a channel resets the View's chat, images and
		// all (publish_chat_reset), so one we already have has to be
		// published again, or the UI sees it as never fetched.
		publish_image(c, info.id)
		return
	}
	img := new(Client_Image)
	img.info = info
	img.state = .Wanted
	c.images.cache[info.id] = img
	// Newest first: the messages people are looking at.
	inject_at(&c.images.queue, 0, info.id)
	publish_image(c, info.id)
}

// images_step drives the fetch of one image at a time.
images_step :: proc(c: ^Voice_Client) {
	if !c.has_current || !in_settled_channel(c) {
		return
	}
	ic := &c.images
	if ic.active == 0 {
		for len(ic.queue) > 0 {
			id := ic.queue[0]
			ordered_remove(&ic.queue, 0)
			img := ic.cache[id] or_else nil
			if img == nil || img.state != .Wanted {
				continue
			}
			if !proto.blob_receiver_init(&img.recv, int(img.info.size)) {
				img.state = .Gone
				publish_image(c, id)
				continue
			}
			img.state = .Loading
			img.started = false
			img.requested = {}
			ic.active = id
			publish_image(c, id)
			break
		}
	}
	img := ic.cache[ic.active] or_else nil
	if img == nil {
		ic.active = 0
		return
	}
	if img.requested != {} && time.tick_since(img.requested) < proto.CONTROL_RESEND {
		return
	}
	// While chunks are still arriving there's nothing to ask for: what's
	// on its way would be sent twice.
	if img.started && time.tick_since(img.last_chunk) < proto.CONTROL_RESEND {
		return
	}
	img.requested = time.tick_now()
	if !img.started {
		// Nothing has arrived yet: (re)ask for the image itself.
		get_buf: [proto.IMAGE_GET_SIZE]u8
		send_data(c, proto.encode_image_get(&get_buf, ic.active))
		return
	}
	missing_buf: [proto.BLOB_NEED_MAX_INDICES]u16
	missing := proto.blob_missing(&img.recv, missing_buf[:])
	out: [proto.MAX_PAYLOAD_SIZE]u8
	msg, _ := proto.encode_blob_need(out[:], u64(ic.active), false, missing)
	send_data(c, msg)
}

handle_blob_chunk :: proc(c: ^Voice_Client, pt: []byte) {
	handle, index, data := proto.decode_blob_chunk(pt)
	ic := &c.images
	img := ic.cache[ic.active] or_else nil
	if img == nil || u64(ic.active) != handle || img.state != .Loading {
		return
	}
	img.started = true
	img.last_chunk = time.tick_now()
	proto.blob_receive(&img.recv, index, data)
	if !proto.blob_receiver_complete(&img.recv) {
		return
	}

	// Tell the server it can let go, and keep the bytes.
	out: [proto.MAX_PAYLOAD_SIZE]u8
	msg, _ := proto.encode_blob_need(out[:], handle, true, nil)
	send_data(c, msg)

	id := ic.active
	img.data = img.recv.data
	img.recv.data = nil
	proto.blob_receiver_destroy(&img.recv)
	img.state = .Ready
	ic.bytes += len(img.data)
	ic.active = 0
	log.debugf("image %d received (%d bytes)", id, len(img.data))
	save_image(c, id, img)
	publish_image(c, id)
	trim_images(c)
}

handle_image_gone :: proc(c: ^Voice_Client, pt: []byte) {
	id := proto.decode_image_id(pt)
	img := c.images.cache[id] or_else nil
	if img == nil {
		return
	}
	image_release(c, img)
	img.state = .Gone
	if c.images.active == id {
		c.images.active = 0
	}
	log.debugf("image %d is no longer on the server", id)
	publish_image(c, id)
}

// trim_images drops the oldest images once the cache is too big. They're
// fetched again if they're wanted later.
@(private = "file")
trim_images :: proc(c: ^Voice_Client) {
	ic := &c.images
	for ic.bytes > IMAGE_CACHE_BYTES {
		oldest: u32
		for id, img in ic.cache {
			if img.state == .Ready && (oldest == 0 || id < oldest) {
				oldest = id
			}
		}
		if oldest == 0 {
			return
		}
		img := ic.cache[oldest]
		image_release(c, img)
		delete_key(&ic.cache, oldest)
		free(img)
		unpublish_image(c, oldest)
		log.debugf("image %d dropped from the cache", oldest)
	}
}

// save_image writes an image to -image-dir, which headless mode uses to
// show what it received. A web build has no directories to write to and
// no headless mode either (see images_save_native.odin).

/*
Uploading: the image at the head of the chat outbox.
*/

// image_upload_step sends what it may of the image being posted.
image_upload_step :: proc(c: ^Voice_Client, out: ^Chat_Outgoing, now: time.Tick) {
	if !out.sending {
		// The server hasn't asked for anything yet; announce it again
		// until it does.
		if out.last_send == {} || time.tick_since(out.last_send) >= proto.CONTROL_RESEND {
			out.last_send = now
			buf: [proto.IMAGE_SEND_SIZE]u8
			send_data(c, proto.encode_image_send(&buf, out.nonce, out.image))
		}
		return
	}

	elapsed := f32(time.duration_seconds(time.tick_diff(out.last_chunk, now)))
	out.last_chunk = now
	out.tokens = min(out.tokens + elapsed * IMAGE_UPLOAD_RATE, IMAGE_UPLOAD_BURST)
	buf: [proto.MAX_PAYLOAD_SIZE]u8
	for out.tokens > 0 {
		index, data, ok := proto.blob_next_chunk(&out.send)
		if !ok {
			break
		}
		send_data(c, proto.encode_blob_chunk(buf[:], out.nonce, index, data))
		out.tokens -= f32(len(data))
	}
	if proto.blob_sender_idle(&out.send) && time.tick_since(out.last_send) >= proto.CONTROL_RESEND {
		// Everything has gone out once; nudge the server for a new list
		// of what's still missing.
		out.last_send = now
		buf2: [proto.IMAGE_SEND_SIZE]u8
		send_data(c, proto.encode_image_send(&buf2, out.nonce, out.image))
	}
}

// handle_blob_need is the server saying which chunks of our upload it
// still wants.
handle_blob_need :: proc(c: ^Voice_Client, pt: []byte) {
	handle, complete, count, indices, ok := proto.decode_blob_need(pt)
	if !ok || len(c.chat.outbox) == 0 {
		return
	}
	out := &c.chat.outbox[0]
	if out.kind != .Image || out.nonce != handle || complete {
		return
	}
	if !out.sending {
		// The first list is "everything", which is just the first pass.
		out.sending = true
		out.last_chunk = time.tick_now()
		out.send = {
			data = out.jpeg,
		}
		log.debugf("uploading a %dx%d image, %d bytes", out.image.width, out.image.height, out.image.size)
		return
	}
	if out.send.next < proto.blob_chunk_count(len(out.jpeg)) {
		return // still on the first pass; those chunks are on their way
	}
	for i in 0 ..< count {
		proto.blob_sender_needs(&out.send, proto.blob_need_index(indices, i))
	}
}

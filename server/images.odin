package server

import "core:log"
import "core:time"

import "../proto"

/*
Chat images. A client announces one with Image_Send and uploads the JPEG
in chunks (proto/blob.odin); once it's all there the image gets an id,
the message is posted like a text one, and anyone in the channel can ask
for the bytes with Image_Get.

Images are kept with the messages that carry them: a channel keeps the
last CHAT_HISTORY messages, and the images of those, up to
IMAGE_BYTES_PER_CHANNEL. Older ones are dropped, and their messages then
say so (image id 0).

Transfers are paced per user, so a large image can't crowd out voice.
*/

// How much of a channel's images the server holds on to.
IMAGE_BYTES_PER_CHANNEL :: #config(YAP_IMAGE_BYTES, 8 * 1024 * 1024)
// Per user, in each direction.
IMAGE_RATE :: 256 * 1024 // bytes per second
IMAGE_BURST :: 32 * 1024 // bytes that may go out at once
// An upload that goes quiet for this long is dropped.
UPLOAD_TIMEOUT :: 15 * time.Second

Stored_Image :: struct {
	id:      u32,
	channel: u16,
	info:    proto.Image_Info,
	data:    []u8,
}

// Upload is an image on its way in from one user.
Upload :: struct {
	active:    bool,
	nonce:     u64,
	info:      proto.Image_Info,
	recv:      proto.Blob_Receiver,
	last_need: time.Tick,
	last_data: time.Tick,
}

// Download is an image on its way out to one user.
Download :: struct {
	active: bool,
	image:  u32,
	send:   proto.Blob_Sender,
	tokens: f32, // bytes this user may send right now
	last:   time.Tick,
}

handle_image_send :: proc(s: ^Server, c: ^Client, pt: []byte) {
	u := c.user
	nonce, info := proto.decode_image_send(pt)

	// Already posted (the Chat_Sent must have been lost): say so again.
	for n in u.chat.nonces {
		if n == nonce {
			sent_buf: [proto.CHAT_SENT_SIZE]u8
			send_message(s, c, proto.encode_chat_sent(&sent_buf, nonce))
			return
		}
	}

	up := &u.upload
	if !up.active || up.nonce != nonce {
		if up.active {
			log.debugf("%s started another upload", user_label(u))
			proto.blob_receiver_destroy(&up.recv)
		}
		up^ = {}
		if info.width == 0 || info.height == 0 || !proto.blob_receiver_init(&up.recv, int(info.size)) {
			log.debugf("%s announced an image we won't take: %dx%d, %d bytes", user_label(u), info.width, info.height, info.size)
			return
		}
		up.active = true
		up.nonce = nonce
		up.info = info
		up.last_data = time.tick_now()
		log.debugf("%s is uploading a %dx%d image, %d bytes", user_label(u), info.width, info.height, info.size)
	}
	send_blob_need(s, c, up, force = true)
}

handle_blob_chunk :: proc(s: ^Server, c: ^Client, pt: []byte) {
	u := c.user
	handle, index, data := proto.decode_blob_chunk(pt)
	up := &u.upload
	if !up.active || up.nonce != handle {
		return
	}
	proto.blob_receive(&up.recv, index, data)
	up.last_data = time.tick_now()
	if !proto.blob_receiver_complete(&up.recv) {
		return
	}

	info := up.info
	nonce := up.nonce
	info.id = store_image(s, u.channel, info, up.recv.data)
	log.debugf("%s uploaded image %d (%d bytes)", user_label(u), info.id, len(up.recv.data))
	proto.blob_receiver_destroy(&up.recv)
	up^ = {}

	u.chat.nonces[u.chat.next_nonce] = nonce
	u.chat.next_nonce = (u.chat.next_nonce + 1) % CHAT_NONCES
	chat_append_image(&s.chats[u.channel], u.num, u.name, info)
	sent_buf: [proto.CHAT_SENT_SIZE]u8
	send_message(s, c, proto.encode_chat_sent(&sent_buf, nonce))
}

handle_image_get :: proc(s: ^Server, c: ^Client, pt: []byte) {
	u := c.user
	id := proto.decode_image_id(pt)
	img := s.images[id] or_else nil
	if img == nil {
		gone: [proto.IMAGE_GONE_SIZE]u8
		send_message(s, c, proto.encode_image_gone(&gone, id))
		return
	}
	down := &u.download
	if down.active && down.image == id {
		return // already on its way
	}
	if down.active {
		proto.blob_sender_destroy(&down.send)
	}
	down^ = {
		active = true,
		image  = id,
		send   = {data = img.data},
		last   = time.tick_now(),
	}
	log.debugf("sending image %d to %s", id, user_label(u))
}

handle_blob_need :: proc(u: ^User, pt: []byte) {
	handle, complete, count, indices, ok := proto.decode_blob_need(pt)
	down := &u.download
	if !ok || !down.active || u64(down.image) != handle {
		return
	}
	if complete {
		proto.blob_sender_destroy(&down.send)
		down.active = false
		return
	}
	for i in 0 ..< count {
		proto.blob_sender_needs(&down.send, proto.blob_need_index(indices, i))
	}
}

// images_sync keeps transfers moving: chunks out to whoever is waiting
// for one, and reminders to whoever is uploading.
images_sync :: proc(s: ^Server) {
	now := time.tick_now()
	for _, u in s.users {
		c := sending_session(s, u)
		if c == nil {
			continue
		}
		if up := &u.upload; up.active {
			if time.tick_since(up.last_data) > UPLOAD_TIMEOUT {
				log.debugf("%s stopped uploading", user_label(u))
				proto.blob_receiver_destroy(&up.recv)
				up^ = {}
			} else {
				send_blob_need(s, c, up)
			}
		}
		send_chunks(s, c, &u.download, now)
	}
}

// send_blob_need tells a client which chunks of its upload are missing,
// which is also what gets it started.
@(private = "file")
send_blob_need :: proc(s: ^Server, c: ^Client, up: ^Upload, force := false) {
	// Only once the chunks have stopped coming: whatever is still on its
	// way would otherwise be asked for again and sent twice.
	if !force &&
	   (time.tick_since(up.last_data) < proto.CONTROL_RESEND ||
			   time.tick_since(up.last_need) < proto.CONTROL_RESEND) {
		return
	}
	up.last_need = time.tick_now()
	missing_buf: [proto.BLOB_NEED_MAX_INDICES]u16
	missing := proto.blob_missing(&up.recv, missing_buf[:])
	out: [proto.MAX_PAYLOAD_SIZE]u8
	msg, _ := proto.encode_blob_need(out[:], up.nonce, false, missing)
	send_message(s, c, msg)
}

// send_chunks pushes as much of a download as the user's allowance
// covers.
@(private = "file")
send_chunks :: proc(s: ^Server, c: ^Client, down: ^Download, now: time.Tick) {
	if !down.active {
		return
	}
	elapsed := f32(time.duration_seconds(time.tick_diff(down.last, now)))
	down.last = now
	down.tokens = min(down.tokens + elapsed * IMAGE_RATE, IMAGE_BURST)

	out: [proto.MAX_PAYLOAD_SIZE]u8
	for down.tokens > 0 {
		index, data, ok := proto.blob_next_chunk(&down.send)
		if !ok {
			break
		}
		send_message(s, c, proto.encode_blob_chunk(out[:], u64(down.image), index, data))
		down.tokens -= f32(len(data))
	}
}

// store_image keeps an image with its channel, making room if needed.
@(private = "file")
store_image :: proc(s: ^Server, channel: u16, info: proto.Image_Info, data: []u8) -> u32 {
	s.last_image_id += 1
	if s.last_image_id == 0 {
		s.last_image_id = 1
	}
	img := new(Stored_Image)
	img.id = s.last_image_id
	img.channel = channel
	img.info = info
	img.info.id = img.id
	img.data = make([]u8, len(data))
	copy(img.data, data)
	s.images[img.id] = img

	// Drop the channel's oldest images until it's back within budget.
	for {
		total, oldest := 0, u32(0)
		for id, other in s.images {
			if other.channel != channel {
				continue
			}
			total += len(other.data)
			if oldest == 0 || id < oldest {
				oldest = id
			}
		}
		if total <= IMAGE_BYTES_PER_CHANNEL || oldest == img.id {
			break
		}
		forget_image(s, oldest)
	}
	return img.id
}

// forget_image drops an image and marks the message that carried it.
forget_image :: proc(s: ^Server, id: u32) {
	img := s.images[id] or_else nil
	if img == nil {
		return
	}
	log.debugf("dropping image %d (%d bytes)", id, len(img.data))
	chat_forget_image(&s.chats[img.channel], id)
	delete_key(&s.images, id)
	delete(img.data)
	free(img)

	// Anyone still sending it has nothing to send.
	for _, u in s.users {
		if u.download.active && u.download.image == id {
			proto.blob_sender_destroy(&u.download.send)
			u.download.active = false
		}
	}
}

// drop_user_transfers ends whatever a leaving user was transferring.
drop_user_transfers :: proc(u: ^User) {
	if u.upload.active {
		proto.blob_receiver_destroy(&u.upload.recv)
		u.upload = {}
	}
	if u.download.active {
		proto.blob_sender_destroy(&u.download.send)
		u.download = {}
	}
}

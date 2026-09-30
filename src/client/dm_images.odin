package client

import log "common:wlog"
import "core:time"

import "common:proto"

/*
Images in direct messages (see src/common/proto/dm.odin): sending one to
someone who's online, and fetching the ones sent to us.

Sending: the JPEG is sealed on its own, and the DM that describes it
goes through the DM outbox like any other, except that once the server
asks for the picture (Blob_Need) it's uploaded first, paced like a chat
image (images.odin). Fetching is one image at a time, oldest first,
under the DM's id; the picture is opened once it's all here.

Pictures are kept in memory only, so after a restart an image DM is a
gap with its size. They're told apart from chat images in the UI by ids
from DM_IMAGE_ID_BASE up, which the server's chat image ids don't reach.
*/

DM_IMAGE_ID_BASE :: u32(0x8000_0000)

// DM_Picture is an image DM's picture.
DM_Picture :: struct {
	width, height: u16,
	size:          u32, // sealed
	nonce:         [proto.DM_NONCE_SIZE]u8,
	id:            u32, // for the UI (View.dm_images)
	state:         Image_State,
	jpeg:          []u8, // once Ready; owned
}

// DM_Image_Command sends an image DM; `to` and `name` are as in
// DM_Command. The command owns the image until the client takes it.
DM_Image_Command :: struct {
	to:    [proto.KEY_SIZE]u8,
	name:  string, // owned by the command
	image: Chat_Image,
}

// DM_Fetch is the image being fetched, and those waiting their turn.
DM_Fetch :: struct {
	queue:      [dynamic]DM_Fetch_Want,
	active:     bool,
	from:       [proto.KEY_SIZE]u8,
	id:         u64,
	recv:       proto.Blob_Receiver,
	requested:  time.Tick, // when we last asked for something
	last_chunk: time.Tick,
	started:    bool, // chunks have begun arriving
}

DM_Fetch_Want :: struct {
	from: [proto.KEY_SIZE]u8,
	id:   u64,
}

// dm_picture starts a picture off, with an id for the UI.
dm_picture :: proc(c: ^Voice_Client, img: proto.DM_Image, state: Image_State) -> DM_Picture {
	c.dms.next_image_id += 1
	return {
		width = img.width,
		height = img.height,
		size = img.size,
		nonce = img.nonce,
		id = DM_IMAGE_ID_BASE + c.dms.next_image_id,
		state = state,
	}
}

dm_fetch_destroy :: proc(c: ^Voice_Client) {
	proto.blob_receiver_destroy(&c.dms.fetch.recv)
	delete(c.dms.fetch.queue)
}

// dm_send_image seals `jpeg` for `to` and queues it. It takes the JPEG
// over. Images only go to someone who's online.
dm_send_image :: proc(
	c: ^Voice_Client,
	to_or_zero: [proto.KEY_SIZE]u8,
	name: string,
	image: Chat_Image,
) {
	image := image
	to, found := dm_recipient(c, to_or_zero, name)
	if !found || !dm_online(c, to) {
		if found {
			log.warnf("dm: %s isn't online, and images only go to someone who is", fingerprint(to))
		}
		chat_image_destroy(&image)
		return
	}
	if len(image.jpeg) == 0 || len(image.jpeg) + proto.TAG_SIZE > proto.MAX_DM_IMAGE_SEALED {
		log.warnf("dm: not sending an image of %d bytes", len(image.jpeg))
		chat_image_destroy(&image)
		return
	}
	key, ok := dm_shared_key(c, to)
	if !ok {
		chat_image_destroy(&image)
		return
	}

	out := DM_Outgoing {
		to    = to,
		id    = random_id(),
		image = make([]u8, len(image.jpeg) + proto.TAG_SIZE),
	}
	image_nonce, _ := proto.dm_seal(&key, c.my_key, to, out.id, .Image, image.jpeg, out.image)
	picture := proto.DM_Image {
		width  = u16(image.width),
		height = u16(image.height),
		size   = u32(len(out.image)),
		nonce  = image_nonce,
	}
	body_buf: [proto.MAX_DM_BODY]u8
	nonce, sealed := proto.dm_seal(
		&key,
		c.my_key,
		to,
		out.id,
		.Body,
		proto.encode_dm_image(&body_buf, picture),
		out.sealed[:],
	)
	out.nonce, out.sealed_len = nonce, len(sealed)
	append(&c.dms.outbox, out)

	msg := DM_Message {
		id      = out.id,
		mine    = true,
		time    = unix_now(),
		state   = .Sending,
		image   = true,
		picture = dm_picture(c, picture, .Ready),
	}
	msg.picture.jpeg = image.jpeg // ours to show; the message has it now
	conv := dm_conversation(c, to)
	add_message(conv, msg)
	dm_save(c, conv)
	publish_dm_picture(c, msg.picture)
	publish_dm_conversation(c, conv, unread = false)
	log.debugf(
		"dm: sending %s a %dx%d image, %d bytes",
		fingerprint(to),
		image.width,
		image.height,
		len(image.jpeg),
	)
	if len(c.dms.outbox) == 1 {
		drive_dm(c)
	}
}

// dm_online is whether `key` is on the server right now.
dm_online :: proc(c: ^Voice_Client, key: [proto.KEY_SIZE]u8) -> bool {
	if !c.channels.have_state {
		return false
	}
	for u in c.channels.state.users {
		if u.key == key {
			return true
		}
	}
	return false
}

/*
dm_image_upload_step keeps an image DM going: announcing it until the
server asks for the picture, then uploading that as fast as the pace
allows, and asking again what's missing once it's all gone out once.
*/
dm_image_upload_step :: proc(c: ^Voice_Client, out: ^DM_Outgoing) {
	now := time.tick_now()
	announce :: proc(c: ^Voice_Client, out: ^DM_Outgoing, now: time.Tick) {
		out.last_send = now
		buf: [proto.MAX_DM_SIZE_ON_WIRE]u8
		send_data(
			c,
			proto.encode_dm_image_send(
				buf[:],
				out.id,
				out.to,
				out.nonce,
				len(out.image),
				out.sealed[:out.sealed_len],
			),
		)
	}
	if !out.uploading {
		if out.last_send == {} || time.tick_since(out.last_send) >= proto.CONTROL_RESEND {
			announce(c, out, now)
		}
		return
	}

	elapsed := f32(time.duration_seconds(time.tick_diff(out.last_chunk, now)))
	out.last_chunk = now
	out.tokens = min(out.tokens + elapsed * IMAGE_UPLOAD_RATE, IMAGE_UPLOAD_BURST)
	buf: [proto.MAX_PAYLOAD_SIZE]u8
	for out.tokens > 0 {
		index, data, ok := proto.blob_next_chunk(&out.upload)
		if !ok {
			break
		}
		send_data(c, proto.encode_blob_chunk(buf[:], out.id, index, data))
		out.tokens -= f32(len(data))
	}
	if proto.blob_sender_idle(&out.upload) &&
	   time.tick_since(out.last_send) >= proto.CONTROL_RESEND {
		announce(c, out, now)
	}
}

// dm_image_upload_need takes the server's Blob_Need for our image DM's
// picture (handle_blob_need passes on those that aren't the chat's).
dm_image_upload_need :: proc(
	c: ^Voice_Client,
	handle: u64,
	complete: bool,
	count: int,
	indices: []u8,
) {
	if len(c.dms.outbox) == 0 {
		return
	}
	out := &c.dms.outbox[0]
	if out.image == nil || out.id != handle || complete {
		return
	}
	if !out.uploading {
		// The first list is "everything", which is just the first pass.
		out.uploading = true
		out.last_chunk = time.tick_now()
		out.upload = {
			data = out.image,
		}
		return
	}
	if out.upload.next < proto.blob_chunk_count(len(out.image)) {
		return // still on the first pass; those chunks are on their way
	}
	for i in 0 ..< count {
		proto.blob_sender_needs(&out.upload, proto.blob_need_index(indices, i))
	}
}

// dm_fetch_want queues an image DM's picture to fetch.
dm_fetch_want :: proc(c: ^Voice_Client, from: [proto.KEY_SIZE]u8, id: u64) {
	append(&c.dms.fetch.queue, DM_Fetch_Want{from, id})
}

// dm_images_step drives the fetch of one picture at a time.
dm_images_step :: proc(c: ^Voice_Client) {
	f := &c.dms.fetch
	if !c.has_current {
		return
	}
	for !f.active && len(f.queue) > 0 {
		want := f.queue[0]
		ordered_remove(&f.queue, 0)
		m := dm_find_message(c, want.from, want.id)
		if m == nil || !m.image || m.picture.state != .Wanted {
			continue
		}
		if !proto.blob_receiver_init(&f.recv, int(m.picture.size)) {
			set_picture_state(c, m, .Gone)
			continue
		}
		f.active, f.from, f.id = true, want.from, want.id
		f.started, f.requested = false, {}
		set_picture_state(c, m, .Loading)
	}
	if !f.active {
		return
	}
	if f.requested != {} && time.tick_since(f.requested) < proto.CONTROL_RESEND {
		return
	}
	// While chunks are still arriving there's nothing to ask for: what's
	// on its way would be sent twice.
	if f.started && time.tick_since(f.last_chunk) < proto.CONTROL_RESEND {
		return
	}
	f.requested = time.tick_now()
	if !f.started {
		get_buf: [proto.DM_IMAGE_REF_SIZE]u8
		send_data(c, proto.encode_dm_key_message(&get_buf, .DM_Image_Get, f.id, f.from))
		return
	}
	missing_buf: [proto.BLOB_NEED_MAX_INDICES]u16
	missing := proto.blob_missing(&f.recv, missing_buf[:])
	out: [proto.MAX_PAYLOAD_SIZE]u8
	msg, _ := proto.encode_blob_need(out[:], f.id, false, missing)
	send_data(c, msg)
}

// dm_image_chunk takes a chunk of the picture being fetched
// (handle_blob_chunk passes on those that aren't the chat's).
dm_image_chunk :: proc(c: ^Voice_Client, handle: u64, index: int, data: []u8) {
	f := &c.dms.fetch
	if !f.active || f.id != handle {
		return
	}
	f.started = true
	f.last_chunk = time.tick_now()
	proto.blob_receive(&f.recv, index, data)
	if !proto.blob_receiver_complete(&f.recv) {
		return
	}

	// Tell the server it can let go.
	out: [proto.MAX_PAYLOAD_SIZE]u8
	msg, _ := proto.encode_blob_need(out[:], handle, true, nil)
	send_data(c, msg)

	from, id := f.from, f.id
	sealed := f.recv.data
	defer proto.blob_receiver_destroy(&f.recv)
	f.active = false
	m := dm_find_message(c, from, id)
	if m == nil {
		return
	}
	key, key_ok := dm_shared_key(c, from)
	jpeg := make([]u8, len(sealed) - proto.TAG_SIZE)
	opened, ok := proto.dm_open(&key, from, c.my_key, id, .Image, m.picture.nonce, sealed, jpeg)
	if !key_ok || !ok {
		log.warnf("dm: an image from %s doesn't open", fingerprint(from))
		delete(jpeg)
		set_picture_state(c, m, .Gone)
		return
	}
	m.picture.jpeg = opened
	log.debugf("dm: image from %s received (%d bytes)", fingerprint(from), len(opened))
	set_picture_state(c, m, .Ready)
	save_dm_image(c, id, m.picture)
}

handle_dm_image_gone :: proc(c: ^Voice_Client, pt: []u8) {
	id, from := proto.decode_dm_key_message(pt)
	f := &c.dms.fetch
	if f.active && f.id == id && f.from == from {
		proto.blob_receiver_destroy(&f.recv)
		f.active = false
	}
	if m := dm_find_message(c, from, id); m != nil && m.image {
		log.debugf("dm: an image from %s is no longer on the server", fingerprint(from))
		set_picture_state(c, m, .Gone)
	}
}

@(private = "file")
dm_find_message :: proc(c: ^Voice_Client, from: [proto.KEY_SIZE]u8, id: u64) -> ^DM_Message {
	conv := c.dms.conversations[from] or_else nil
	if conv == nil {
		return nil
	}
	for &m in conv.messages {
		if m.id == id && !m.mine {
			return &m
		}
	}
	return nil
}

@(private = "file")
set_picture_state :: proc(c: ^Voice_Client, m: ^DM_Message, state: Image_State) {
	m.picture.state = state
	publish_dm_picture(c, m.picture)
}

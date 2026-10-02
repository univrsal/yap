package conn

import log "common:wlog"
import "core:sync"
import "core:time"

import "common:proto"

/*
Pictures on our end: fetching those that messages show, by the id of
their blob (src/common/proto/msgs.odin asks for one, blob.odin moves the
chunks). Uploading ours is the outbox's business (messages.odin).

One is fetched at a time, the one wanted last first: that's the message
most likely on screen. It's asked for with Blob_Get, whose answer is
its size and the handle its chunks come under; what hasn't arrived is
asked for again with Blob_Need, and when nothing comes for a while the
picture is asked for again from the start (the server may have started
over).

Pictures stay in memory as the JPEG they arrived as; the UI decodes
them (ui_images.odin). Past BLOB_CACHE_BYTES the ones fetched first are
dropped, and fetched again if they're shown again.
*/

// How much of other people's pictures to keep.
BLOB_CACHE_BYTES :: 16 * 1024 * 1024
// A picture that's been silent this long is asked for again.
FETCH_QUIET :: 5 * time.Second

Image_State :: enum {
	Wanted, // queued to fetch
	Loading,
	Ready,
	Gone, // the server doesn't have it (any more), or won't give it to us
}

Blob_Fetch :: struct {
	state:      Image_State,
	image:      proto.Msg_Image, // what the message says about it
	data:       []u8, // the JPEG, once Ready; owned
	recv:       proto.Blob_Receiver,
	handle:     u64, // 0 until the server has said
	asking:     bool, // a Blob_Get is out
	asked:      time.Tick, // when it was last asked for, one way or the other
	last_chunk: time.Tick,
	started:    bool, // chunks have begun to arrive
	order:      int, // when it was fetched, to drop the oldest first
	keep:       bool, // not to be dropped: the server's sheet of emoji
}

Blob_Client :: struct {
	cache:  map[proto.Blob_Id]^Blob_Fetch,
	queue:  [dynamic]proto.Blob_Id, // to fetch, the one wanted last first
	active: proto.Blob_Id, // the one being fetched, 0 for none
	bytes:  int, // what the ready ones take up
	count:  int,
	// Headless: where to save the pictures that arrive.
	dir:    string,
}

blobs_destroy :: proc(c: ^Voice_Client) {
	for _, f in c.blobs.cache {
		fetch_release(c, f)
		free(f)
	}
	delete(c.blobs.cache)
	delete(c.blobs.queue)
}

@(private = "file")
fetch_release :: proc(c: ^Voice_Client, f: ^Blob_Fetch) {
	if f.state == .Ready {
		c.blobs.bytes -= len(f.data)
	}
	delete(f.data)
	f.data = nil
	proto.blob_receiver_destroy(&f.recv)
}

// blob_want makes sure we have, or will fetch, a message's picture; with
// `keep`, one that stays however many others there are. A size of 0 is
// one the server will tell us (somebody's picture).
blob_want :: proc(c: ^Voice_Client, image: proto.Msg_Image, keep := false) {
	if image.blob == 0 || int(image.size) > proto.MAX_BLOB_SIZE {
		return
	}
	bc := &c.blobs
	if f, seen := bc.cache[image.blob]; seen {
		f.keep ||= keep
		if f.state == .Wanted {
			// Wanted again: to the front.
			for id, i in bc.queue {
				if id == image.blob {
					ordered_remove(&bc.queue, i)
					break
				}
			}
			inject_at(&bc.queue, 0, image.blob)
		}
		return
	}
	f := new(Blob_Fetch)
	f.image = image
	f.state = .Wanted
	f.keep = keep
	bc.cache[image.blob] = f
	inject_at(&bc.queue, 0, image.blob)
	publish_blob(c, image.blob)
}

// blob_have is a picture of ours the server has just taken: nothing to
// fetch. Takes `jpeg` over.
blob_have :: proc(c: ^Voice_Client, blob: proto.Blob_Id, jpeg: []u8, width, height: int) {
	bc := &c.blobs
	if f, seen := bc.cache[blob]; seen {
		if f.state == .Ready {
			delete(jpeg)
			return
		}
		fetch_release(c, f)
		if bc.active == blob {
			bc.active = 0
		}
		free(f)
	}
	f := new(Blob_Fetch)
	f^ = {
		state = .Ready,
		image = {blob = blob, width = u16(width), height = u16(height), size = u32(len(jpeg))},
		data = jpeg,
	}
	bc.count += 1
	f.order = bc.count
	bc.cache[blob] = f
	bc.bytes += len(jpeg)
	publish_blob(c, blob)
	trim_blobs(c)
}

// blobs_restart: the fetch under way is asked for again on the new
// connection.
blobs_restart :: proc(c: ^Voice_Client) {
	bc := &c.blobs
	if f := bc.cache[bc.active] or_else nil; f != nil && f.state == .Loading {
		proto.blob_receiver_destroy(&f.recv)
		f.state = .Wanted
		f.handle, f.asking, f.started = 0, false, false
		inject_at(&bc.queue, 0, bc.active)
		publish_blob(c, bc.active)
	}
	bc.active = 0
}

// blobs_step drives the fetch of one picture at a time.
blobs_step :: proc(c: ^Voice_Client) {
	if !c.has_current || !c.convs.synced {
		return
	}
	bc := &c.blobs
	if bc.active == 0 {
		for len(bc.queue) > 0 {
			id := bc.queue[0]
			ordered_remove(&bc.queue, 0)
			f := bc.cache[id] or_else nil
			if f == nil || f.state != .Wanted {
				continue
			}
			if f.image.size != 0 && !proto.blob_receiver_init(&f.recv, int(f.image.size)) {
				f.state = .Gone
				publish_blob(c, id)
				continue
			}
			f.state = .Loading
			f.handle, f.started, f.asked = 0, false, {}
			bc.active = id
			publish_blob(c, id)
			break
		}
	}
	f := bc.cache[bc.active] or_else nil
	if f == nil {
		bc.active = 0
		return
	}
	switch {
	case f.asking:
	// Waiting for the answer.
	case f.handle == 0 || time.tick_since(f.asked) > FETCH_QUIET && time.tick_since(f.last_chunk) > FETCH_QUIET:
		// Not asked for yet, or gone quiet: ask for it (again).
		f.asking = true
		f.asked = time.tick_now()
		buf: [proto.BLOB_GET_SIZE]u8
		request(c, .Blob_Get, proto.encode_blob_id(&buf, bc.active), get_done, u64(bc.active))
	case time.tick_since(f.asked) >= proto.CONTROL_RESEND &&
	     (!f.started || time.tick_since(f.last_chunk) >= proto.CONTROL_RESEND):
		// Chunks have stopped coming: say which are missing.
		f.asked = time.tick_now()
		missing_buf: [proto.BLOB_NEED_MAX_INDICES]u16
		missing := proto.blob_missing(&f.recv, missing_buf[:])
		out: [proto.MAX_PAYLOAD_SIZE]u8
		msg, _ := proto.encode_blob_need(out[:], f.handle, false, missing)
		send_data(c, msg)
	}
}

@(private = "file")
get_done :: proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
	id := proto.Blob_Id(tag)
	bc := &c.blobs
	f := bc.cache[id] or_else nil
	if f == nil || bc.active != id || f.state != .Loading {
		return
	}
	f.asking = false
	#partial switch status {
	case .Ok:
		size, handle, ok := proto.decode_blob_get_answer(body)
		if ok && f.image.size == 0 && size <= proto.MAX_AVATAR_SIZE && proto.blob_receiver_init(&f.recv, size) {
			// Its size, now we know it.
			f.image.size = u32(size)
		}
		if ok && size == f.recv.size {
			if handle != f.handle {
				f.handle, f.started = handle, false
			}
			return
		}
		log.warnf("picture %d isn't the size its message says", id)
	case .Reset:
		return // blobs_restart has put it back in the queue
	case:
		log.debugf("picture %d: %v", id, status)
	}
	fetch_release(c, f)
	f.state = .Gone
	bc.active = 0
	publish_blob(c, id)
}

handle_blob_chunk :: proc(c: ^Voice_Client, pt: []byte) {
	handle, index, data := proto.decode_blob_chunk(pt)
	bc := &c.blobs
	f := bc.cache[bc.active] or_else nil
	if f == nil || f.state != .Loading || f.handle == 0 || f.handle != handle {
		return
	}
	f.started = true
	f.last_chunk = time.tick_now()
	proto.blob_receive(&f.recv, index, data)
	if !proto.blob_receiver_complete(&f.recv) {
		return
	}

	// Tell the server it can let go, and keep the bytes.
	out: [proto.MAX_PAYLOAD_SIZE]u8
	msg, _ := proto.encode_blob_need(out[:], handle, true, nil)
	send_data(c, msg)

	id := bc.active
	f.data = f.recv.data
	f.recv.data = nil
	proto.blob_receiver_destroy(&f.recv)
	f.state = .Ready
	bc.bytes += len(f.data)
	bc.count += 1
	f.order = bc.count
	bc.active = 0
	log.debugf("picture %d received (%d bytes)", id, len(f.data))
	save_image(c, id, f)
	publish_blob(c, id)
	trim_blobs(c)
}

// handle_blob_need is the server saying which chunks of an upload of
// ours it still wants (messages.odin).
handle_blob_need :: proc(c: ^Voice_Client, pt: []byte) {
	upload_need(c, pt)
}

// trim_blobs drops the pictures fetched longest ago once there are too
// many; they're fetched again if they're wanted later.
@(private = "file")
trim_blobs :: proc(c: ^Voice_Client) {
	bc := &c.blobs
	for bc.bytes > BLOB_CACHE_BYTES {
		oldest: proto.Blob_Id
		for id, f in bc.cache {
			if f.state == .Ready && !f.keep && (oldest == 0 || f.order < bc.cache[oldest].order) {
				oldest = id
			}
		}
		if oldest == 0 {
			return
		}
		f := bc.cache[oldest]
		fetch_release(c, f)
		delete_key(&bc.cache, oldest)
		free(f)
		publish_blob(c, oldest)
		log.debugf("picture %d dropped from the cache", oldest)
	}
}

// View_Image is a picture a message shows: what it looks like, how far
// along it is, and the JPEG itself once it's here.
View_Image :: struct {
	info:  proto.Msg_Image,
	state: Image_State,
	jpeg:  []u8, // owned; only when Ready
}

// publish_blob mirrors a picture's state (and its bytes once they're
// here) for the UI to draw; one we don't keep any more is taken away.
publish_blob :: proc(c: ^Voice_Client, id: proto.Blob_Id) {
	v := c.view
	if v == nil {
		return
	}
	f := c.blobs.cache[id] or_else nil
	sync.guard(&v.mutex)
	if old, ok := v.blobs[id]; ok {
		delete(old.jpeg)
	}
	if f == nil {
		delete_key(&v.blobs, id)
		return
	}
	jpeg: []u8
	if f.state == .Ready {
		jpeg = make([]u8, len(f.data))
		copy(jpeg, f.data)
	}
	v.blobs[id] = {
		info = f.image,
		state = f.state,
		jpeg = jpeg,
	}
}

// Call with the mutex held.
view_clear_blobs :: proc(v: ^View) {
	for _, img in v.blobs {
		delete(img.jpeg)
	}
	clear(&v.blobs)
}

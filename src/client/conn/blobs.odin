package conn

import log "common:wlog"
import "core:time"

import "common:proto"

// This file fetches the pictures shown by messages on our end, using the id of
// their blob (src/common/proto/msgs.odin requests a blob and blob.odin
// transfers its chunks). Uploading our own pictures is handled by the outbox
// (see messages.odin).
//
// Only one picture is fetched at a time, starting with the one that was
// wanted last, since that is the message most likely to be on screen. A
// picture is requested with Blob_Get, whose answer contains its size and the
// handle under which its chunks arrive. Chunks that haven't arrived are
// requested again with Blob_Need. If nothing arrives for a while, the whole
// picture is requested again from the start, because the server may have
// restarted the transfer.
//
// Pictures are kept in memory as the JPEG they arrived as, and the UI decodes
// them (see ui_images.odin). Once BLOB_CACHE_BYTES is exceeded, the pictures
// that were fetched first are dropped, and they are fetched again if they are
// shown again.
//
// Pictures fetched with `keep` (people's pictures and the server's emoji) are
// also stored on disk if the UI has given us a place to keep them (`disk`, see
// image_cache.odin). Next time they are read from there instead of being
// fetched. Reading from the cache can take a moment (in a browser), so the
// picture is in the Loading state meanwhile, as if it were being fetched. It
// is only fetched from the server if the cache turns out not to have it.

// The maximum number of bytes of other people's pictures to keep in memory.
BLOB_CACHE_BYTES :: 16 * 1024 * 1024
// A picture that has received no data for this long is requested again.
FETCH_QUIET :: 5 * time.Second

// Image_Info is what is known about a picture: its blob and, once it has
// arrived (or we sent it), its size in pixels and bytes.
Image_Info :: struct {
	blob:          proto.Blob_Id,
	width, height: u16, // pixels
	size:          u32, // bytes of JPEG
}

Image_State :: enum {
	Wanted, // queued to fetch
	Loading,
	Ready,
	Gone, // the server no longer has it, or won't give it to us
}

Blob_Fetch :: struct {
	state:      Image_State,
	image:      Image_Info,
	data:       []u8, // the JPEG, once Ready; owned
	recv:       proto.Blob_Receiver,
	handle:     u64, // 0 until the server has provided it
	asking:     bool, // a Blob_Get request is pending
	asked:      time.Tick, // when it was last requested, whether in full or only the missing chunks
	last_chunk: time.Tick,
	started:    bool, // chunks have started to arrive
	order:      int, // when it was fetched, used to drop the oldest first
	keep:       bool, // must not be dropped (for example the server's emoji sheet)
	disk:       Cache_Request, // is being read from the image cache instead
}

Blob_Client :: struct {
	cache:  map[proto.Blob_Id]^Blob_Fetch,
	queue:  [dynamic]proto.Blob_Id, // pictures to fetch, with the one wanted last first
	active: proto.Blob_Id, // the picture being fetched, 0 if there is none
	bytes:  int, // the number of bytes the ready pictures take up
	count:  int,
	// Owned by the UI: where pictures fetched with `keep` are stored between
	// sessions. nil means they are not stored.
	disk:   ^Image_Cache,
	// The pictures that are being read from the cache.
	loads:  [dynamic]proto.Blob_Id,
}

blobs_destroy :: proc(c: ^Voice_Client) {
	for _, f in c.blobs.cache {
		fetch_release(c, f)
		free(f)
	}
	delete(c.blobs.cache)
	delete(c.blobs.queue)
	delete(c.blobs.loads)
}

@(private = "file")
fetch_release :: proc(c: ^Voice_Client, f: ^Blob_Fetch) {
	if f.disk != 0 {
		image_cache_cancel(c.blobs.disk, f.disk)
		f.disk = 0
	}
	if f.state == .Ready {
		c.blobs.bytes -= len(f.data)
	}
	delete(f.data)
	f.data = nil
	proto.blob_receiver_destroy(&f.recv)
}

// blob_want makes sure we either have a picture or will fetch it. With `keep`,
// the picture stays cached regardless of how many other pictures there are. A
// size of 0 means the server will tell us the size (for example a person's
// picture).
blob_want :: proc(c: ^Voice_Client, image: Image_Info, keep := false) {
	if image.blob == 0 || int(image.size) > proto.MAX_BLOB_SIZE {
		return
	}
	bc := &c.blobs
	if f, seen := bc.cache[image.blob]; seen {
		if keep && !f.keep && f.state == .Ready {
			// It is only now wanted to be kept (for example a message's picture
			// that is also somebody's profile picture, or our own new one).
			disk_store(c, image.blob, f.data)
		}
		f.keep ||= keep
		if f.state == .Wanted {
			// It is wanted again, so move it to the front of the queue.
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
	if keep && bc.disk != nil && c.server_key != {} {
		f.disk = image_cache_request(bc.disk, c.server_key, image.blob)
	}
	if f.disk != 0 {
		f.state = .Loading
		append(&bc.loads, image.blob)
	} else {
		inject_at(&bc.queue, 0, image.blob)
	}
	publish_blob(c, image.blob)
}

// disk_poll checks on the pictures that are being read from the image cache. A
// picture that has arrived becomes Ready, as if it had just been fetched, and
// one that the cache could not provide is fetched from the server after all.
@(private = "file")
disk_poll :: proc(c: ^Voice_Client) {
	bc := &c.blobs
	for i := 0; i < len(bc.loads); {
		id := bc.loads[i]
		f := bc.cache[id] or_else nil
		if f == nil || f.disk == 0 {
			// It was removed in the meantime (see blob_have).
			unordered_remove(&bc.loads, i)
			continue
		}
		data, state := image_cache_poll(bc.disk, f.disk)
		if state == .Pending {
			i += 1
			continue
		}
		unordered_remove(&bc.loads, i)
		f.disk = 0
		if state == .Done && (f.image.size == 0 || int(f.image.size) == len(data)) {
			f.data = data
			f.image.size = u32(len(data))
			f.state = .Ready
			bc.bytes += len(data)
			bc.count += 1
			f.order = bc.count
			log.debugf("picture %d from the image cache (%d bytes)", id, len(data))
			publish_blob(c, id)
			trim_blobs(c)
			continue
		}
		// The cache doesn't have it after all, or it is not what we expected.
		delete(data)
		f.state = .Wanted
		inject_at(&bc.queue, 0, id)
		publish_blob(c, id)
	}
}

// disk_store stores a picture on disk for next time.
@(private = "file")
disk_store :: proc(c: ^Voice_Client, id: proto.Blob_Id, data: []u8) {
	if c.blobs.disk != nil && c.server_key != {} {
		image_cache_store(c.blobs.disk, c.server_key, id, data)
	}
}

// blob_have records a picture of ours that the server has just accepted, so
// there is nothing to fetch. It takes ownership of `jpeg`.
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

// blobs_restart requests the fetch that is in progress again on the new
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

// blobs_step drives the fetching of one picture at a time.
blobs_step :: proc(c: ^Voice_Client) {
	if len(c.blobs.loads) > 0 {
		disk_poll(c)
	}
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
	// Waiting for the server's answer.
	case f.handle == 0 ||
	     time.tick_since(f.asked) > FETCH_QUIET && time.tick_since(f.last_chunk) > FETCH_QUIET:
		// Not requested yet, or no data has arrived for a while, so request it (again).
		f.asking = true
		f.asked = time.tick_now()
		buf: [proto.BLOB_GET_SIZE]u8
		request(c, .Blob_Get, proto.encode_blob_id(&buf, bc.active), get_done, u64(bc.active))
	case time.tick_since(f.asked) >= proto.CONTROL_RESEND &&
	     (!f.started || time.tick_since(f.last_chunk) >= proto.CONTROL_RESEND):
		// Chunks have stopped arriving, so tell the server which ones are missing.
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
		if ok &&
		   f.image.size == 0 &&
		   size <= proto.MAX_AVATAR_SIZE &&
		   proto.blob_receiver_init(&f.recv, size) {
			// Now we know its size.
			f.image.size = u32(size)
		}
		if ok && size == f.recv.size {
			if handle != f.handle {
				f.handle, f.started = handle, false
			}
			return
		}
		log.warnf("picture %d does not have the size its message says", id)
	case .Reset:
		return // blobs_restart has already put it back in the queue
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

	// Tell the server it can release the blob, and keep the bytes.
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
	if f.keep {
		disk_store(c, id, f.data)
	}
	publish_blob(c, id)
	trim_blobs(c)
}

// handle_blob_need handles the server telling us which chunks of one of our
// uploads it still needs (see messages.odin).
handle_blob_need :: proc(c: ^Voice_Client, pt: []byte) {
	upload_need(c, pt)
}

// trim_blobs drops the pictures that were fetched longest ago once there are too
// many. They are fetched again if they are wanted later.
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

// View_Image is a picture to show. It has the picture's info, how far along the
// fetch is, and the JPEG itself once it has arrived.
View_Image :: struct {
	info:  Image_Info,
	state: Image_State,
	jpeg:  []u8, // owned; only set when Ready
}

// publish_blob copies a picture's state (and its bytes once they have arrived)
// for the UI to draw. A picture we no longer keep is removed from the view.
publish_blob :: proc(c: ^Voice_Client, id: proto.Blob_Id) {
	v := c.view
	if v == nil {
		return
	}
	f := c.blobs.cache[id] or_else nil
	view_write(v)
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
		info  = f.image,
		state = f.state,
		jpeg  = jpeg,
	}
}

// Call with the mutex held.
view_clear_blobs :: proc(v: ^View) {
	for _, img in v.blobs {
		delete(img.jpeg)
	}
	clear(&v.blobs)
}

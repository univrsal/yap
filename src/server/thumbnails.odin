package server

import "base:runtime"
import "core:log"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"
import stbi "vendor:stb/image"

import "common:gif"
import "common:imagekind"
import "common:proto"
import "common:stbtrack"
import "common:webp"
import "sqlite"

// Thumbnails of the pictures that are attached to messages (see
// docs/design/thumbnails.md). A client that shows a picture in the chat
// needs a few hundred pixels of it, not a 12-megapixel photo, so when an
// upload has been stored (attachments.odin) the server makes a small WebP
// of it and keeps it as a blob of kind Thumbnail.
//
// The blob of the picture says what became of it, in its `thumb` column:
//
// 	0   not looked at yet (a job may be waiting, or the server stopped first)
// 	-1  none: the picture needs none, or none could be made
// 	n   the blob that is its thumbnail
//
// A picture gets none if it isn't one of the kinds stb_image or libwebp reads,
// if it is smaller than `thumb_min_kb` and no longer than `thumb_side` on
// either side (a copy of it would save nothing), if it is an animation (its
// thumbnail would be a still, and a client shows the animation itself when
// it's meant to move), if it has more than `thumb_megapixels` (decoding it
// would need too much memory), or if the thumbnail turns out larger than the
// picture. A failure never fails the upload, it only means no thumbnail.
//
// Decoding and compressing take a moment, and the main loop also carries
// voice, so the work is done on one thread of its own. The loop hands it jobs
// (thumbnails_submit) and collects the finished ones on each turn
// (thumbnails_sync), because the database belongs to the loop. At most
// THUMB_QUEUE_MOST jobs wait, and a picture that doesn't fit keeps `thumb` 0
// to be made later. A thumbnail is made upright: a JPEG's EXIF orientation is
// applied, and the metadata isn't copied. The thumbnail blob's width and
// height are its own, which differ from the picture's for a turned one.

// Pictures that were stored before thumbnails (or while they were off, or that the
// queue had no room for) are given one in two ways. A picture that a message
// carries is queued when the server reads that message to send it to somebody
// (attach_files, attachments.odin), so the pictures that people look at come
// first, and the message is sent again once the thumbnail is there
// (thumbnail_announce). And a sweep (thumbnails_sweep) works through all the
// others, newest first, a few at a time and only while nothing else is
// queued, so it takes as long as it takes and leaves the thread free for
// uploads. It runs once after the server starts. Pictures that no message
// carries any more are left alone, since retention removes them.

// The defaults of the settings (Attach_Config).
THUMB_SIDE :: 512
THUMB_QUALITY :: 65
THUMB_MIN_KB :: 64
THUMB_MEGAPIXELS :: 64
// The WebP encoder's effort. 4 is libwebp's default; higher is smaller but
// slower.
THUMB_METHOD :: 4
// The most jobs that may wait for the thread.
THUMB_QUEUE_MOST :: 16
// How often the sweep looks for more pictures, and how many it queues at once.
THUMB_SWEEP_EVERY :: time.Second
THUMB_SWEEP_BATCH :: 4
// How much of a file is read first, to find its size and orientation. A JPEG's
// metadata is at most 64 KB.
THUMB_HEADER :: 80 * 1024

Thumb_Job :: struct {
	blob: Blob_Id,
	path: string, // owned
	size: int,
}

// Thumb_Result is the outcome of a job. `data` is empty if no thumbnail was
// made.
Thumb_Result :: struct {
	blob:          Blob_Id,
	data:          []u8, // owned
	width, height: int,
}

Thumbnails :: struct {
	enabled:      bool,
	side:         int,
	quality:      f32,
	min_bytes:    int,
	max_pixels:   int,
	thread:       ^thread.Thread,
	mutex:        sync.Mutex,
	wake:         sync.Sema,
	quit:         bool, // under the mutex
	queue:        [dynamic]Thumb_Job, // under the mutex
	done:         [dynamic]Thumb_Result, // under the mutex
	// Jobs submitted and not yet collected.
	pending:      int, // under the mutex
	// The pictures that have a job, so that none is queued twice.
	inflight:     map[Blob_Id]struct{}, // under the mutex
	// The sweep: it has looked at the blobs from `cursor` up (it goes down from the
	// newest), and when it last looked.
	sweep_every:  time.Duration,
	sweep_cursor: i64,
	sweep_at:     time.Tick,
	sweep_done:   bool,
	sweep_queued: int,
}

thumbnails_open :: proc(s: ^Server, config: Attach_Config) {
	t := &s.thumbs
	t.enabled = config.thumbnails
	t.side = config.thumb_side if config.thumb_side > 0 else THUMB_SIDE
	t.quality = f32(config.thumb_quality if config.thumb_quality > 0 else THUMB_QUALITY)
	t.min_bytes = 1024 * (config.thumb_min_kb if config.thumb_min_kb > 0 else THUMB_MIN_KB)
	t.max_pixels =
		1_000_000 * (config.thumb_megapixels if config.thumb_megapixels > 0 else THUMB_MEGAPIXELS)
	t.sweep_every = THUMB_SWEEP_EVERY
	t.sweep_cursor = max(i64)
	if !t.enabled {
		return
	}
	t.thread = thread.create_and_start_with_poly_data(t, thumbnail_thread, context)
	if t.thread == nil {
		log.error("could not start the thumbnail thread, there will be no thumbnails")
		t.enabled = false
	}
}

thumbnails_close :: proc(s: ^Server) {
	t := &s.thumbs
	if t.thread != nil {
		sync.mutex_lock(&t.mutex)
		t.quit = true
		sync.mutex_unlock(&t.mutex)
		sync.sema_post(&t.wake)
		thread.join(t.thread)
		thread.destroy(t.thread)
	}
	for j in t.queue {
		delete(j.path)
	}
	for r in t.done {
		delete(r.data)
	}
	delete(t.queue)
	delete(t.done)
	delete(t.inflight)
	t^ = {}
}

// thumbnails_submit asks for the thumbnail of a picture that has just been
// stored. It does nothing for a picture that was looked at before (a second
// upload of the same file) or when the queue is full.
thumbnails_submit :: proc(s: ^Server, id: Blob_Id) {
	t := &s.thumbs
	if !t.enabled {
		return
	}
	b, found := blob_get(&s.blobs, id)
	if !found || b.kind != .File || b.thumb != 0 {
		return
	}
	// Anything whose header isn't a picture's has no use for a job.
	if b.width <= 0 || b.height <= 0 {
		_ = db_write(&s.db, .Blob_Set_Thumb, i64(id), i64(-1))
		return
	}
	sync.mutex_lock(&t.mutex)
	defer sync.mutex_unlock(&t.mutex)
	if id in t.inflight {
		return
	}
	if len(t.queue) >= THUMB_QUEUE_MOST {
		log.debugf("thumbnail of blob %d: the queue is full, left for later", id)
		return
	}
	append(
		&t.queue,
		Thumb_Job{blob = id, path = blob_path(&s.blobs, b.hash, context.allocator), size = b.size},
	)
	t.pending += 1
	t.inflight[id] = {}
	sync.sema_post(&t.wake)
}

// thumbnails_sync stores the thumbnails that the thread has finished.
thumbnails_sync :: proc(s: ^Server) {
	t := &s.thumbs
	if t.thread == nil {
		return
	}
	sync.mutex_lock(&t.mutex)
	finished := t.done
	t.done = nil
	t.pending -= len(finished)
	for r in finished {
		delete_key(&t.inflight, r.blob)
	}
	sync.mutex_unlock(&t.mutex)
	defer delete(finished)
	for r in finished {
		thumbnail_store(s, r)
	}
	thumbnails_sweep(s)
}

// thumbnails_sweep queues the next few pictures that have no thumbnail yet,
// if the thread has nothing to do. It's called on each turn of the loop and
// only looks every `sweep_every`.
@(private = "file")
thumbnails_sweep :: proc(s: ^Server) {
	t := &s.thumbs
	if t.sweep_done || time.tick_since(t.sweep_at) < t.sweep_every {
		return
	}
	t.sweep_at = time.tick_now()
	if thumbnails_pending(s) > 0 {
		return
	}
	ids: [THUMB_SWEEP_BATCH]Blob_Id
	n := 0
	q := db_query(&s.db, .Blob_Unthumbed, t.sweep_cursor, i64(Blob_Kind.File), THUMB_SWEEP_BATCH)
	for n < len(ids) {
		row, ok := db_step(&s.db, q)
		if !ok || !row {
			break
		}
		ids[n] = Blob_Id(db_col_int(q, 0))
		n += 1
	}
	sqlite.reset(q)
	if n == 0 {
		t.sweep_done = true
		if t.sweep_queued > 0 {
			log.infof("thumbnails: the sweep queued %d older pictures", t.sweep_queued)
		}
		return
	}
	if t.sweep_queued == 0 {
		log.info("thumbnails: making thumbnails of older pictures, newest first")
	}
	for id in ids[:n] {
		thumbnails_submit(s, id)
		t.sweep_cursor = i64(id)
	}
	t.sweep_queued += n
}

// thumbnails_pending is how many jobs are waiting or running or finished but
// not yet collected.
thumbnails_pending :: proc(s: ^Server) -> int {
	t := &s.thumbs
	sync.mutex_lock(&t.mutex)
	defer sync.mutex_unlock(&t.mutex)
	return t.pending
}

@(private = "file")
thumbnail_store :: proc(s: ^Server, r: Thumb_Result) {
	defer delete(r.data)
	if len(r.data) == 0 {
		_ = db_write(&s.db, .Blob_Set_Thumb, i64(r.blob), i64(-1))
		return
	}
	id, ok := blob_put(&s.blobs, .Thumbnail, r.data, r.width, r.height)
	if !ok {
		log.errorf("could not store the thumbnail of blob %d", r.blob)
		return
	}
	if !db_write(&s.db, .Blob_Set_Thumb, i64(r.blob), i64(id)) {
		return
	}
	thumbnail_announce(s, r.blob)
	log.debugf(
		"blob %d has thumbnail %d (%dx%d, %d bytes)",
		r.blob,
		id,
		r.width,
		r.height,
		len(r.data),
	)
}

// thumbnail_announce sends the messages that carry a picture again, now that
// they can state its thumbnail. A message is often posted before the thumbnail
// is made (it takes a moment for a photo), and a client only asks for a
// thumbnail that its message states.
@(private = "file")
thumbnail_announce :: proc(s: ^Server, blob: Blob_Id) {
	ids := make([dynamic]proto.Msg_Id, context.temp_allocator)
	q := db_query(&s.db, .Attach_Blob_Msgs, i64(blob))
	for {
		row, ok := db_step(&s.db, q)
		if !ok || !row {
			break
		}
		append(&ids, proto.Msg_Id(db_col_int(q, 0)))
	}
	for id in ids {
		m, found := msg_by_id(s, id)
		if !found || .Deleted in m.flags {
			continue
		}
		if conv := conv_by_id(&s.convs, m.conv); conv != nil {
			msg_deliver(s, conv, m, .Msg_Changed)
		}
	}
}

@(private = "file")
thumbnail_thread :: proc(t: ^Thumbnails) {
	// This thread needs its own temp allocator because the main loop's is
	// emptied every iteration.
	scratch: runtime.Default_Temp_Allocator
	runtime.default_temp_allocator_init(&scratch, 1024 * 1024, context.allocator)
	defer runtime.default_temp_allocator_destroy(&scratch)
	context.temp_allocator = runtime.default_temp_allocator(&scratch)
	for {
		sync.sema_wait(&t.wake)
		sync.mutex_lock(&t.mutex)
		if t.quit {
			sync.mutex_unlock(&t.mutex)
			return
		}
		if len(t.queue) == 0 {
			sync.mutex_unlock(&t.mutex)
			continue
		}
		job := t.queue[0]
		ordered_remove(&t.queue, 0)
		side, quality, min_bytes, max_pixels := t.side, t.quality, t.min_bytes, t.max_pixels
		sync.mutex_unlock(&t.mutex)

		r := Thumb_Result {
			blob = job.blob,
		}
		r.data, r.width, r.height = make_thumbnail(
			job.path,
			job.size,
			side,
			quality,
			min_bytes,
			max_pixels,
		)
		delete(job.path)
		free_all(context.temp_allocator)

		sync.mutex_lock(&t.mutex)
		append(&t.done, r)
		sync.mutex_unlock(&t.mutex)
	}
}

// make_thumbnail makes the WebP of the picture in the file at `path`. It
// returns no data if the picture gets none (see the top of this file).
make_thumbnail :: proc(
	path: string,
	size, side: int,
	quality: f32,
	min_bytes, max_pixels: int,
) -> (
	data: []u8,
	width, height: int,
) {
	file, err := os.open(path)
	if err != nil {
		log.warnf("thumbnail: could not open %s: %v", path, err)
		return
	}
	head := make([]u8, min(size, THUMB_HEADER))
	defer delete(head)
	n, _ := os.read_at(file, head, 0)
	os.close(file)
	head = head[:max(n, 0)]

	w, h, ok := imagekind.dimensions(head)
	if !ok || w * h > max_pixels {
		return
	}
	if size < min_bytes && max(w, h) <= side {
		return
	}
	kind := imagekind.kind_of(head)
	// imagekind has no kind for a BMP, which stb_image reads.
	if kind == .Unknown && !imagekind.is_bmp(head) {
		return
	}
	if kind != .WebP && !imagekind.stbi_readable(head) {
		return
	}
	orientation := imagekind.jpeg_orientation(head) if kind == .JPEG else 1

	whole, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil || len(whole) != size {
		delete(whole)
		return
	}
	defer delete(whole)

	// The pixels are either made here or stb_image's own (`stb_pixels`), which are
	// not copied: for a big picture that would double the memory it takes.
	pixels: []u8
	stb_pixels: [^]u8
	defer if stb_pixels != nil {
		stbtrack.image_free(stb_pixels)
	} else {
		delete(pixels)
	}
	switch kind {
	case .WebP:
		if webp.is_animation(whole) {
			return
		}
		pixels = make([]u8, w * h * 4)
		if !webp.decode_into(whole, pixels, w) {
			return
		}
	case .GIF:
		if info, gif_ok := gif.info(whole); !gif_ok || info.frames > 1 {
			return
		}
		pixels, stb_pixels, ok = decode_stb(whole, &w, &h)
		if !ok {
			return
		}
	case .JPEG, .PNG, .Unknown:
		// Unknown is a BMP (see above).
		pixels, stb_pixels, ok = decode_stb(whole, &w, &h)
		if !ok {
			return
		}
	}
	return encode_thumbnail(pixels, w, h, side, quality, orientation, size)
}

// decode_stb decodes a picture to RGBA with stb_image. The pixels are stb_image's
// (`raw`), to be freed with stbtrack.image_free. `w` and `h` are replaced with
// what stb_image found.
@(private = "file")
decode_stb :: proc(data: []u8, w, h: ^int) -> (pixels: []u8, raw: [^]u8, ok: bool) {
	cw, ch, comp: i32
	p := stbtrack.load_from_memory(raw_data(data), i32(len(data)), &cw, &ch, &comp, 4)
	if p == nil {
		return nil, nil, false
	}
	w^, h^ = int(cw), int(ch)
	return p[:int(cw) * int(ch) * 4], p, true
}

// encode_thumbnail scales RGBA pixels to fit `side` by `side` (never larger
// than they are), turns them upright and compresses them. It returns no data
// if that isn't smaller than the original (`original` bytes).
@(private = "file")
encode_thumbnail :: proc(
	pixels: []u8,
	w, h, side: int,
	quality: f32,
	orientation, original: int,
) -> (
	data: []u8,
	width, height: int,
) {
	tw, th := w, h
	if max(w, h) > side {
		tw, th = max(w * side / max(w, h), 1), max(h * side / max(w, h), 1)
	}
	scaled := pixels
	if tw != w || th != h {
		scaled = make([]u8, tw * th * 4)
		if stbi.resize_uint8_srgb(
			   raw_data(pixels),
			   i32(w),
			   i32(h),
			   0,
			   raw_data(scaled),
			   i32(tw),
			   i32(th),
			   0,
			   4,
			   3,
			   0,
		   ) ==
		   0 {
			delete(scaled)
			return
		}
	}
	defer if raw_data(scaled) != raw_data(pixels) {
		delete(scaled)
	}
	upright, uw, uh := imagekind.orient_rgba(scaled, tw, th, orientation)
	defer if raw_data(upright) != raw_data(scaled) {
		delete(upright)
	}

	opaque := true
	for i := 3; i < uw * uh * 4; i += 4 {
		if upright[i] != 255 {
			opaque = false
			break
		}
	}
	encoded: []u8
	ok: bool
	if opaque {
		rgb := make([]u8, uw * uh * 3)
		defer delete(rgb)
		for i in 0 ..< uw * uh {
			copy(rgb[i * 3:i * 3 + 3], upright[i * 4:i * 4 + 3])
		}
		encoded, ok = webp.encode(rgb, uw, uh, quality, THUMB_METHOD)
	} else {
		encoded, ok = webp.encode_rgba(upright, uw, uh, quality, THUMB_METHOD)
	}
	if !ok {
		return
	}
	if len(encoded) >= original {
		delete(encoded)
		return
	}
	return encoded, uw, uh
}

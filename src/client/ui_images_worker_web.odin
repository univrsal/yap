#+build wasi
package client

import "core:sync"
import "core:time"

import "client:clipboard"

// A browser build has no thread to decode pictures on, so the browser decodes
// them (web/decode.js), off the page's thread. Each queued picture is handed
// over at the start of the next frame (decode_queued, called from
// ui_images_frame). Once it is decoded, the page asks for another frame
// (web_image_decoded), whose decode_queued collects it. The browser can read
// WebP, which stb_image can't.
//
// An animation that the browser can play (with WebCodecs' ImageDecoder) keeps
// its handle after its first frame: Next_Frame asks the page for the next frame
// on that handle, and Drop releases it. In other browsers it is shown as a
// still picture.
//
// Only a server's emoji sheet, which is a QOI that browsers can't read, is
// decoded here, synchronously.
Decode_Worker :: struct {
	// The pictures the browser is decoding.
	pending: [dynamic]Pending_Decode,
	// The handles of the animations being played, by picture.
	anims:   map[u64]Web_Anim,
}

@(private = "file")
Pending_Decode :: struct {
	req:        i32,
	id:         u64,
	generation: u64,
	frame:      bool, // an animation's next frame, rather than a picture
}

@(private = "file")
Web_Anim :: struct {
	req:        i32,
	generation: u64,
}

@(default_calling_convention = "c")
foreign _ {
	// The bytes are copied, so they can be freed right away. Returns a handle
	// to poll, or 0.
	yap_image_decode_start :: proc(data: [^]u8, len: i32, max_pixels: f64) -> i32 ---
	// Returns -1 while the picture is being decoded, -2 if it couldn't be
	// decoded (the handle is released), 1 when it is ready to be taken, and 2
	// for an animation that has no more frames.
	yap_image_decode_poll :: proc(req: i32) -> i32 ---
	yap_image_decode_width :: proc(req: i32) -> i32 ---
	yap_image_decode_height :: proc(req: i32) -> i32 ---
	// Copies out the width * height * 4 bytes of RGBA and releases the
	// handle, unless it belongs to an animation.
	yap_image_decode_take :: proc(req: i32, buf: [^]u8) ---
	// 0 for a still picture, 1 for an animated WebP, 2 for a GIF.
	yap_image_decode_kind :: proc(req: i32) -> i32 ---
	// How long the frame that was taken is shown, in milliseconds.
	yap_image_decode_shown :: proc(req: i32) -> i32 ---
	// Starts decoding an animation's next frame, which is polled for like the
	// first one.
	yap_image_decode_next :: proc(req: i32) -> i32 ---
	yap_image_decode_close :: proc(req: i32) ---
}

decode_worker_start :: proc(ui: ^UI) {}

decode_worker_stop :: proc(ui: ^UI) {
	w := &ui.images.worker
	for _, a in w.anims {
		yap_image_decode_close(a.req)
	}
	delete(w.anims)
	delete(w.pending)
	w^ = {}
}

// There is no thread to wake: without threads, a semaphore can't be used at all
// (Odin's futex panics on wasm without atomics). Just request a frame, in which
// decode_queued runs.
decode_wake :: proc(im: ^UI_Images) {
	ui_wake()
}

// Called when the page has finished decoding a picture, or when the page's
// focus has changed. It requests a frame, in which the picture is collected or
// the animations carry on.
@(export)
web_image_decoded :: proc "c" () {
	ui_wake()
}

// decode_queued hands the queued pictures to the browser and collects the ones
// it has finished.
decode_queued :: proc(im: ^UI_Images) {
	w := &im.worker
	for {
		job: Decode_Job
		{
			sync.guard(&im.mutex)
			if len(im.queue) == 0 {
				break
			}
			job = pop_front(&im.queue)
		}
		switch job.kind {
		case .Decode:
		case .Next_Frame:
			a, playing := w.anims[job.id]
			if !playing || a.generation != job.generation || yap_image_decode_next(a.req) == 0 {
				finish(im, {id = job.id, generation = job.generation, anim = true, frame = true})
				continue
			}
			append(
				&w.pending,
				Pending_Decode {
					req = a.req,
					id = job.id,
					generation = job.generation,
					frame = true,
				},
			)
			continue
		case .Drop:
			anim_close(w, job.id, job.generation)
			continue
		}
		if clipboard.is_qoi(job.jpeg) {
			image, err := clipboard.decode(job.jpeg)
			delete(job.jpeg)
			finish(
				im,
				{id = job.id, generation = job.generation, image = image, ok = err == .None},
			)
			continue
		}
		req: i32
		if len(job.jpeg) > 0 && len(job.jpeg) <= clipboard.MAX_DATA_SIZE {
			req = yap_image_decode_start(
				raw_data(job.jpeg),
				i32(len(job.jpeg)),
				f64(clipboard.MAX_PIXELS),
			)
		}
		delete(job.jpeg)
		if req <= 0 {
			finish(im, {id = job.id, generation = job.generation})
			continue
		}
		append(&w.pending, Pending_Decode{req = req, id = job.id, generation = job.generation})
	}

	for i := 0; i < len(w.pending); {
		p := w.pending[i]
		result := Decode_Result {
			id         = p.id,
			generation = p.generation,
			anim       = p.frame,
			frame      = p.frame,
		}
		switch yap_image_decode_poll(p.req) {
		case -1:
			i += 1
			continue
		case 1:
			width := int(yap_image_decode_width(p.req))
			height := int(yap_image_decode_height(p.req))
			kind := yap_image_decode_kind(p.req)
			result.anim = kind != 0
			result.gif = kind == 2
			result.shown = time.Duration(yap_image_decode_shown(p.req)) * time.Millisecond
			result.image = {
				width  = width,
				height = height,
				pixels = make([]u8, width * height * 4),
			}
			yap_image_decode_take(p.req, raw_data(result.image.pixels))
			result.ok = width > 0 && height > 0
			if result.anim && !p.frame {
				anim_close(w, p.id, p.generation) // requested again after a Drop
				w.anims[p.id] = {
					req        = p.req,
					generation = p.generation,
				}
			}
		case 2:
			// No more frames, which a result without pixels signals.
			anim_close(w, p.id, p.generation)
		case:
			// Decoding failed, and the page has released the handle.
			if a, playing := w.anims[p.id]; playing && a.req == p.req {
				delete_key(&w.anims, p.id)
			}
		}
		finish(im, result)
		unordered_remove(&w.pending, i)
	}
}

// anim_close releases the animation playing as `id`, if it is the one of
// `generation`.
@(private = "file")
anim_close :: proc(w: ^Decode_Worker, id, generation: u64) {
	if a, playing := w.anims[id]; playing && a.generation == generation {
		yap_image_decode_close(a.req)
		delete_key(&w.anims, id)
	}
}

@(private = "file")
finish :: proc(im: ^UI_Images, result: Decode_Result) {
	sync.guard(&im.mutex)
	append(&im.results, result)
}

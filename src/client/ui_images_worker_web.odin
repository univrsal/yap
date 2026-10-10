#+build wasi
package client

import "core:sync"
import "core:time"

import "client:clipboard"

/*
A browser build has no thread to decode pictures on, so the browser
decodes them (web/decode.js), off the page's thread: each one queued is
handed over at the start of the next frame (decode_queued, from
ui_images_frame), and once it's done the page asks for another frame
(web_image_decoded), whose decode_queued collects it. The browser reads
WebP, which stb_image doesn't.

An animation the browser can play (with WebCodecs' ImageDecoder) keeps
its handle after its first frame: Next_Frame asks the page for the next
on it, and Drop lets go of it. Elsewhere it's a still picture.

Only a server's sheet of emoji, a QOI, which browsers don't read, is
decoded here and now.
*/
Decode_Worker :: struct {
	// What the browser is decoding.
	pending: [dynamic]Pending_Decode,
	// The animations being played, by picture: their handles.
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
	// The bytes are copied, so they can be freed straight away. A handle
	// to poll, or 0.
	yap_image_decode_start :: proc(data: [^]u8, len: i32, max_pixels: f64) -> i32 ---
	// -1 while it's being decoded, -2 if it couldn't be (the handle is
	// done with), 1 when it's there to take; 2 for an animation that has
	// no more frames.
	yap_image_decode_poll :: proc(req: i32) -> i32 ---
	yap_image_decode_width :: proc(req: i32) -> i32 ---
	yap_image_decode_height :: proc(req: i32) -> i32 ---
	// Copies the width * height * 4 bytes of RGBA out, and is done with
	// the handle, unless it's an animation's.
	yap_image_decode_take :: proc(req: i32, buf: [^]u8) ---
	// 0 for a still picture, 1 for an animated WebP, 2 for a GIF.
	yap_image_decode_kind :: proc(req: i32) -> i32 ---
	// How long the frame taken is shown, in milliseconds.
	yap_image_decode_shown :: proc(req: i32) -> i32 ---
	// Starts on an animation's next frame, polled for as the first.
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

// No thread to wake: without threads, a semaphore can't be used at all
// (Odin's futex panics on wasm without atomics). Only a frame, for
// decode_queued to run in.
decode_wake :: proc(im: ^UI_Images) {
	ui_wake()
}

// The page has finished a picture, or the page's focus has changed: a
// frame, to collect it in or carry on.
@(export)
web_image_decoded :: proc "c" () {
	ui_wake()
}

// decode_queued hands what's waiting to the browser and collects what
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
			finish(im, {id = job.id, generation = job.generation, image = image, ok = err == .None})
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
				anim_close(w, p.id, p.generation) // asked for again, after a Drop
				w.anims[p.id] = {
					req        = p.req,
					generation = p.generation,
				}
			}
		case 2:
			// No more frames: a result without pixels says so.
			anim_close(w, p.id, p.generation)
		case:
			// The page is done with the handle.
			if a, playing := w.anims[p.id]; playing && a.req == p.req {
				delete_key(&w.anims, p.id)
			}
		}
		finish(im, result)
		unordered_remove(&w.pending, i)
	}
}

// anim_close lets go of the animation playing as `id`, if it's the one
// of `generation`.
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

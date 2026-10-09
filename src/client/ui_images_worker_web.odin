#+build wasi
package client

import "core:sync"

import "client:clipboard"

/*
A browser build has no thread to decode pictures on, so the browser
decodes them (web/decode.js), off the page's thread: each one queued is
handed over at the start of the next frame (decode_queued, from
ui_images_frame), and once it's done the page asks for another frame
(web_image_decoded), whose decode_queued collects it. The browser reads
WebP, which stb_image doesn't.

Only a server's sheet of emoji, a QOI, which browsers don't read, is
decoded here and now.
*/
Decode_Worker :: struct {
	// What the browser is decoding.
	pending: [dynamic]Pending_Decode,
}

@(private = "file")
Pending_Decode :: struct {
	req:        i32,
	id:         u64,
	generation: u64,
}

@(default_calling_convention = "c")
foreign _ {
	// The bytes are copied, so they can be freed straight away. A handle
	// to poll, or 0.
	yap_image_decode_start :: proc(data: [^]u8, len: i32, max_pixels: f64) -> i32 ---
	// -1 while it's being decoded, -2 if it couldn't be (the handle is
	// done with), 1 when it's there to take.
	yap_image_decode_poll :: proc(req: i32) -> i32 ---
	yap_image_decode_width :: proc(req: i32) -> i32 ---
	yap_image_decode_height :: proc(req: i32) -> i32 ---
	// Copies the width * height * 4 bytes of RGBA out, and is done with
	// the handle.
	yap_image_decode_take :: proc(req: i32, buf: [^]u8) ---
}

decode_worker_start :: proc(ui: ^UI) {}

decode_worker_stop :: proc(ui: ^UI) {
	delete(ui.images.worker.pending)
	ui.images.worker.pending = nil
}

// No thread to wake: without threads, a semaphore can't be used at all
// (Odin's futex panics on wasm without atomics). Only a frame, for
// decode_queued to run in.
decode_wake :: proc(im: ^UI_Images) {
	ui_wake()
}

// The page has finished a picture: a frame, to collect it in.
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
		if clipboard.is_qoi(job.jpeg) {
			image, err := clipboard.decode(job.jpeg)
			delete(job.jpeg)
			finish(im, job.id, job.generation, image, err == .None)
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
			finish(im, job.id, job.generation, {}, false)
			continue
		}
		append(&w.pending, Pending_Decode{req = req, id = job.id, generation = job.generation})
	}

	for i := 0; i < len(w.pending); {
		p := w.pending[i]
		switch yap_image_decode_poll(p.req) {
		case -1:
			i += 1
			continue
		case 1:
			width := int(yap_image_decode_width(p.req))
			height := int(yap_image_decode_height(p.req))
			image := clipboard.Image {
				width  = width,
				height = height,
				pixels = make([]u8, width * height * 4),
			}
			yap_image_decode_take(p.req, raw_data(image.pixels))
			finish(im, p.id, p.generation, image, width > 0 && height > 0)
		case:
			finish(im, p.id, p.generation, {}, false)
		}
		unordered_remove(&w.pending, i)
	}
}

@(private = "file")
finish :: proc(im: ^UI_Images, id, generation: u64, image: clipboard.Image, ok: bool) {
	sync.guard(&im.mutex)
	append(&im.results, Decode_Result{id = id, image = image, ok = ok, generation = generation})
}

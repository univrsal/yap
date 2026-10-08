#+build wasi
package client

import "core:sync"

import "client:clipboard"

/*
A browser build has no thread to decode pictures on, so each one is
decoded at the start of the frame after it was queued (decode_queued,
from ui_images_frame). A chat image is a few hundred kilobytes at most
(see src/common/proto/blob.odin), and the alternative - handing the work to a web
worker - is a job for the day pictures are worth it.
*/
Decode_Worker :: struct {}

decode_worker_start :: proc(ui: ^UI) {}
decode_worker_stop :: proc(ui: ^UI) {}

// No thread to wake: without threads, a semaphore can't be used at all
// (Odin's futex panics on wasm without atomics). Only a frame, for
// decode_queued to run in.
decode_wake :: proc(im: ^UI_Images) {
	ui_wake()
}

// decode_queued takes whatever is waiting and decodes it here and now.
decode_queued :: proc(im: ^UI_Images) {
	for {
		job: Decode_Job
		{
			sync.guard(&im.mutex)
			if len(im.queue) == 0 {
				return
			}
			job = pop_front(&im.queue)
		}
		image, err := clipboard.decode(job.jpeg)
		delete(job.jpeg)
		sync.guard(&im.mutex)
		append(&im.results, Decode_Result {
					id = job.id,
					image = image,
					ok = err == .None,
					generation = job.generation,
				})
	}
}

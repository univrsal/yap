#+build wasi
package client

import "core:sync"

import "clipboard"

/*
A browser build has no thread to decode pictures on, so each one is
decoded where it was queued, between frames. A chat image is a few
hundred kilobytes at most (see proto/blob.odin), and the alternative -
handing the work to a web worker - is a job for the day pictures are
worth it.
*/
Decode_Worker :: struct {}

decode_worker_start :: proc(ui: ^UI) {}
decode_worker_stop :: proc(ui: ^UI) {}

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
        append(&im.results, Decode_Result{id = job.id, image = image, ok = err == .None})
	}
}

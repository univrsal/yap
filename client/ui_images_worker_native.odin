#+build !wasi
package client

import log "../common/wlog"
import "core:sync"
import "core:thread"

import "clipboard"

// Pictures are decoded on a thread of their own, so a big one doesn't
// hold up a frame. The queue and the results are the only things the
// two sides share (see UI_Images).
Decode_Worker :: ^thread.Thread

decode_worker_start :: proc(ui: ^UI) {
	ui.images.worker = thread.create_and_start_with_poly_data(
		&ui.images,
		decode_worker,
		init_context = context,
	)
}

decode_worker_stop :: proc(ui: ^UI) {
	im := &ui.images
	sync.sema_post(&im.wake)
	if im.worker != nil {
		thread.join(im.worker)
		thread.destroy(im.worker)
	}
}

@(private = "file")
decode_worker :: proc(im: ^UI_Images) {
	for {
		sync.sema_wait(&im.wake)
		for {
			job: Decode_Job
			{
				sync.guard(&im.mutex)
				if im.stopping {
					return
				}
				if len(im.queue) == 0 {
					break
				}
				job = im.queue[0]
				ordered_remove(&im.queue, 0)
			}
			defer delete(job.jpeg)
			image, err := clipboard.decode(job.jpeg)
			if err != .None {
				log.debugf("image %d could not be decoded: %v", job.id, err)
			}
			sync.guard(&im.mutex)
			append(&im.results, Decode_Result{id = job.id, image = image, ok = err == .None})
		}
	}
}

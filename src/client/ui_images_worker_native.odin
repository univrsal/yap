#+build !wasi
package client

import "common:memtrack"
import log "common:wlog"
import "core:sync"
import "core:thread"

import "client:clipboard"

// Pictures are decoded on a thread of their own, so a big one doesn't
// hold up a frame. The queue and the results are the only things the
// two sides share (see UI_Images); the animations being played
// (ui_images_anim_native.odin) are the thread's alone.
Decode_Worker :: struct {
	thread: ^thread.Thread,
	anims:  map[u64]Anim_Source,
}

decode_worker_start :: proc(ui: ^UI) {
	ui.images.worker.thread = thread.create_and_start_with_poly_data(
		&ui.images,
		decode_worker,
		init_context = context,
	)
}

decode_wake :: proc(im: ^UI_Images) {
	sync.sema_post(&im.wake)
}

decode_worker_stop :: proc(ui: ^UI) {
	im := &ui.images
	sync.sema_post(&im.wake)
	if im.worker.thread != nil {
		thread.join(im.worker.thread)
		thread.destroy(im.worker.thread)
		im.worker.thread = nil
	}
	anims_destroy(&im.worker)
}

@(private = "file")
decode_worker :: proc(im: ^UI_Images) {
	memtrack.thread_init()
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
			result: Decode_Result
			switch job.kind {
			case .Decode:
				result = decode_job(&im.worker, job)
			case .Next_Frame:
				result = anim_next_frame(&im.worker, job.id, job.generation)
			case .Drop:
				anim_drop(&im.worker, job.id, job.generation)
				continue
			}
			{
				sync.guard(&im.mutex)
				append(&im.results, result)
			}
			// To take it (ui_images_frame); an animation's next frame is
			// taken when it's due instead (anim_drawn).
			if !result.frame {
				ui_wake()
			}
		}
	}
}

// decode_job decodes a picture, or the first frame of an animation, which
// is then kept to be played. Takes the job's bytes over.
@(private = "file")
decode_job :: proc(w: ^Decode_Worker, job: Decode_Job) -> Decode_Result {
	if result, is_anim := anim_start(w, job); is_anim {
		return result
	}
	defer delete(job.jpeg)
	image, err := clipboard.decode(job.jpeg)
	if err != .None {
		log.debugf("image %d could not be decoded: %v", job.id, err)
	}
	return {id = job.id, image = image, ok = err == .None, generation = job.generation}
}

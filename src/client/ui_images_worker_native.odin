#+build !wasi
package client

import "common:memtrack"
import log "common:wlog"
import "core:sync"
import "core:thread"

import stbi "vendor:stb/image"

import "client:clipboard"
import "client:conn"

// Pictures are decoded on a thread of their own, so that a big one doesn't hold
// up a frame. The queue and the results are the only things that the UI and the
// thread share (see UI_Images); the animations being played
// (ui_images_anim_native.odin) belong to the thread alone.
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
			// Wake the UI so it picks up the result (ui_images_frame). An
			// animation's next frame is picked up when it is due instead
			// (anim_drawn).
			if !result.frame {
				ui_wake()
			}
		}
	}
}

// decode_job decodes a picture, or the first frame of an animation, which is
// then kept to be played. It takes ownership of the job's bytes.
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
	result := Decode_Result {
		id         = job.id,
		image      = image,
		ok         = err == .None,
		generation = job.generation,
	}
	side := job.max_side
	if !is_emoji_atlas(job.id) && (side <= 0 || side > MAX_SHOWN_SIDE) {
		side = MAX_SHOWN_SIDE
	}
	if result.ok && side > 0 && max(image.width, image.height) > side {
		shrink(&result, side)
	}
	return result
}

// shrink scales a decoded picture down to at most `max_side` pixels on its
// longer side, keeping its own size in the result.
@(private = "file")
shrink :: proc(result: ^Decode_Result, max_side: int) {
	src := result.image
	w, h := conn.fit_box(src.width, src.height, max_side, max_side)
	small := make([]u8, w * h * 4)
	if stbi.resize_uint8_srgb(
		   raw_data(src.pixels),
		   i32(src.width),
		   i32(src.height),
		   0,
		   raw_data(small),
		   i32(w),
		   i32(h),
		   0,
		   4,
		   3, // straight alpha
		   0,
	   ) ==
	   0 {
		log.debugf("image %d could not be scaled down", result.id)
		delete(small)
		return
	}
	result.full_w, result.full_h = src.width, src.height
	delete(src.pixels)
	result.image = {
		width  = w,
		height = h,
		pixels = small,
	}
}

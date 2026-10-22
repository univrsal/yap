#+build !wasi
package client

import log "common:wlog"
import "core:time"

import "client:clipboard"
import stbi "client:wstbi"
import "common:gif"
import "common:webp"

// Animated pictures, on the decoding thread. An animated WebP isn't
// decoded up front (200 frames of 1080p are 1.6 GB) but one frame at a
// time: the thread keeps a decoder for each animation that is being played,
// hands over its first frame as the picture, and another frame each time the UI
// asks (see Next_Frame), which it does while the picture is drawn
// (see ui_images_frame). The decoder is dropped together with its texture (see Drop).
//
// A GIF can't be decoded one frame at a time (stb_image reads all of them at
// once), so a GIF only plays if all its frames fit in GIF_BUDGET. A bigger one
// shows its first frame, as a still picture. Its frames are counted from
// its blocks (see common:gif) before anything is decoded.
//
// Frames are shown for at least ANIM_MIN_SHOWN. Shorter ones are skipped
// and their time is added to the frame that is shown, so an animation keeps
// its speed without asking for more than 30 frames a second.

// The minimum time a frame is shown for, and the time that a frame which says 10 ms or
// less is shown for. This is what browsers do, because an animation that says 0 means
// "as fast as you like" and was made for browsers.
@(private = "file")
ANIM_SHORTEST :: 20
@(private = "file")
ANIM_UNSET :: 100
// What a GIF's frames may take up when decoded, for it to play.
GIF_BUDGET :: 32 * 1024 * 1024

Anim_Source :: struct {
	generation: u64,
	// The size, frames and loops, for either kind.
	info:       webp.Anim_Info,
	// A WebP's decoder, and the bytes it reads from (owned).
	dec:        webp.Anim,
	data:       []u8,
	// A GIF's frames, all of them, and each one's time in milliseconds
	// (from stb_image, freed with stbi.image_free), and the next frame to show.
	gif:        [^]u8,
	delays:     [^]i32,
	gif_next:   int,
	gif_ends:   int,
	// When the last decoded frame ended, in this round, and how
	// many rounds it has played.
	ended:      int,
	rounds:     int,
}

// anim_frame_ms is how long a frame that says `ms` is shown.
anim_frame_ms :: proc(ms: int) -> int {
	if ms <= 10 {
		return ANIM_UNSET
	}
	return max(ms, ANIM_SHORTEST)
}

// anim_start starts playing `job`'s picture if it is an animation, handing
// over its first frame, and returns whether it was one. If it wasn't, the job's
// bytes still belong to the caller.
anim_start :: proc(w: ^Decode_Worker, job: Decode_Job) -> (result: Decode_Result, is_anim: bool) {
	result = {
		id         = job.id,
		generation = job.generation,
	}
	src := Anim_Source {
		generation = job.generation,
	}
	switch {
	case webp.is_webp(job.jpeg) && webp.is_animation(job.jpeg):
		src.data = job.jpeg
		// libwebp allocates the canvas (twice) as it opens the animation, so
		// its size is checked before that.
		if w, h, sized := webp.size(job.jpeg); !sized || i64(w) * i64(h) > clipboard.MAX_PIXELS {
			log.debugf("image %v: the animation is too big, or not one", job.id)
			anim_source_close(&src)
			return result, true
		}
		ok: bool
		src.dec, src.info, ok = webp.anim_open(src.data)
		if !ok || src.info.width <= 0 || src.info.height <= 0 {
			log.debugf("image %v: can't decode the animation", job.id)
			anim_source_close(&src)
			return result, true
		}
	case gif.is_gif(job.jpeg):
		g, ok := gif.info(job.jpeg)
		info := webp.Anim_Info{g.width, g.height, g.frames, g.loops}
		if !ok || info.frames <= 1 || !gif_fits(info) {
			if ok && info.frames > 1 {
				log.debugf(
					"image %v: a GIF of %d frames of %dx%d is too big to play; showing its first",
					job.id,
					info.frames,
					info.width,
					info.height,
				)
			}
			return // a still picture, as far as playing it goes
		}
		x, y, z, comp: i32
		src.gif = stbi.load_gif_from_memory(
			raw_data(job.jpeg),
			i32(len(job.jpeg)),
			&src.delays,
			&x,
			&y,
			&z,
			&comp,
			4,
		)
		delete(job.jpeg)
		src.info = {int(x), int(y), int(z), info.loops}
		if src.gif == nil || x <= 0 || y <= 0 || z <= 0 || !gif_fits(src.info) {
			log.debugf("image %v: can't decode the GIF: %s", job.id, stbi.failure_reason())
			anim_source_close(&src)
			return result, true
		}
	case:
		return
	}
	if i64(src.info.width) * i64(src.info.height) > clipboard.MAX_PIXELS {
		log.debugf(
			"image %v: animation is %dx%d, over the limit",
			job.id,
			src.info.width,
			src.info.height,
		)
		anim_source_close(&src)
		return result, true
	}
	frame, shown, got := anim_take(&src)
	if !got {
		log.debugf("image %v: can't decode the animation's first frame", job.id)
		anim_source_close(&src)
		return result, true
	}
	result.image = {
		width  = src.info.width,
		height = src.info.height,
		pixels = frame,
	}
	result.ok = true
	if src.info.frames <= 1 {
		anim_source_close(&src) // it is a still picture after all
		return result, true
	}
	result.anim = true
	result.gif = src.gif != nil
	result.shown = shown
	anim_drop(w, job.id, job.generation) // asked for again after a Drop
	w.anims[job.id] = src
	return result, true
}

// anim_next_frame hands over the next frame of animation `id`, in a result
// of its own (see Decode_Result.frame). A result without pixels says there are no
// more frames: it has played as often as it says, or it can't be decoded.
anim_next_frame :: proc(w: ^Decode_Worker, id: Image_Key, generation: u64) -> Decode_Result {
	result := Decode_Result {
		id         = id,
		generation = generation,
		anim       = true,
		frame      = true,
	}
	src, playing := &w.anims[id]
	if !playing || src.generation != generation {
		return result
	}
	frame, shown, got := anim_take(src)
	if !got {
		anim_drop(w, id, generation)
		return result
	}
	result.image = {
		width  = src.info.width,
		height = src.info.height,
		pixels = frame,
	}
	result.ok = true
	result.shown = shown
	return result
}

// anim_drop stops playing `id`, if it is the animation of `generation`.
anim_drop :: proc(w: ^Decode_Worker, id: Image_Key, generation: u64) {
	if src, playing := &w.anims[id]; playing && src.generation == generation {
		anim_source_close(src)
		delete_key(&w.anims, id)
	}
}

anims_destroy :: proc(w: ^Decode_Worker) {
	for _, &src in w.anims {
		anim_source_close(&src)
	}
	delete(w.anims)
	w.anims = nil
}

@(private = "file")
anim_source_close :: proc(src: ^Anim_Source) {
	webp.anim_close(src.dec)
	delete(src.data)
	if src.gif != nil {
		stbi.image_free(src.gif)
	}
	if src.delays != nil {
		stbi.image_free(src.delays)
	}
	src^ = {}
}

// source_next is webp.anim_next for either kind of animation.
@(private = "file")
source_next :: proc(src: ^Anim_Source) -> (pixels: []u8, ends: int, next: webp.Anim_Next) {
	if src.gif == nil {
		return webp.anim_next(src.dec, src.info)
	}
	if src.gif_next >= src.info.frames {
		return nil, 0, .End
	}
	n := src.info.width * src.info.height * 4
	pixels = src.gif[src.gif_next * n:][:n]
	src.gif_ends += int(src.delays[src.gif_next])
	src.gif_next += 1
	return pixels, src.gif_ends, .Frame
}

// source_reset starts either kind of animation again from its first frame.
@(private = "file")
source_reset :: proc(src: ^Anim_Source) {
	if src.gif == nil {
		webp.anim_reset(src.dec)
	}
	src.gif_next, src.gif_ends = 0, 0
}

// anim_take decodes the next frame to show (a copy, owned) and for how
// long. Frames are taken until they add up to ANIM_MIN_SHOWN, or the
// round ends. Past the last frame it starts again, unless it has
// been round as often as the animation says. Then, and for broken data,
// there is no frame.
@(private = "file")
anim_take :: proc(src: ^Anim_Source) -> (frame: []u8, shown: time.Duration, ok: bool) {
	pixels: []u8
	ms := 0
	resets := 0
	taking: for ms < ANIM_MIN_SHOWN {
		p, ends, next := source_next(src)
		switch next {
		case .Frame:
			ms += anim_frame_ms(ends - src.ended)
			src.ended = ends
			pixels = p
		case .End:
			if pixels != nil {
				break taking // what has been taken is shown before going round again
			}
			src.rounds += 1
			// Twice here without a frame is a round without any frames, which
			// would go round forever.
			resets += 1
			if (src.info.loops != 0 && src.rounds >= src.info.loops) || resets > 1 {
				return
			}
			source_reset(src)
			src.ended = 0
		case .Broken:
			return
		}
	}
	frame = make([]u8, len(pixels))
	copy(frame, pixels)
	return frame, time.Duration(ms) * time.Millisecond, true
}

// gif_fits is whether all of a GIF's frames, decoded, fit in GIF_BUDGET.
@(private = "file")
gif_fits :: proc(info: webp.Anim_Info) -> bool {
	return i64(info.width) * i64(info.height) * 4 * i64(info.frames) <= GIF_BUDGET
}

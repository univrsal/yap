#+build !wasi
package client

import log "common:wlog"
import "core:time"

import "client:clipboard"
import "common:gif"
import "common:webp"
import stbi "client:wstbi"

/*
Animated pictures, on the decoding thread. An animated WebP isn't
decoded up front - 200 frames of 1080p are 1.6 GB - but a frame at a
time: the thread keeps a decoder for each one being played, hands over
its first frame as the picture, and another each time the UI asks
(Next_Frame), which it does while the picture is drawn
(ui_images_frame). Dropped with its texture (Drop).

A GIF can't be decoded a frame at a time (stb_image reads all of them at
once), so one plays only if all its frames fit GIF_BUDGET; a bigger one
shows its first frame, as a still picture. Its frames are counted from
its blocks (common:gif) before anything is decoded.

Frames are shown for at least ANIM_MIN_SHOWN: shorter ones are passed
over, their time going to the frame that's shown, so an animation keeps
its speed without asking for more than 30 frames a second.
*/

// What a frame is shown for at least, and what one that says 10 ms or
// less is shown for: what browsers do, as an animation that says 0 means
// "as fast as you like" and was made for them.
@(private = "file")
ANIM_SHORTEST :: 20
@(private = "file")
ANIM_UNSET :: 100
// What a GIF's frames may take up, decoded, for it to play.
GIF_BUDGET :: 32 * 1024 * 1024

Anim_Source :: struct {
	generation: u64,
	// The size, frames and loops, of either kind.
	info:       webp.Anim_Info,
	// A WebP's decoder, and the bytes it reads from (owned).
	dec:        webp.Anim,
	data:       []u8,
	// A GIF's frames, all of them, and each one's time in milliseconds
	// (stb_image's; freed with stbi.image_free), and the next to show.
	gif:        [^]u8,
	delays:     [^]i32,
	gif_next:   int,
	gif_ends:   int,
	// When the last frame decoded ended, in this time round, and how
	// often it has been round.
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

/*
anim_start starts playing `job`'s picture if it's an animation, handing
over its first frame, and says whether it was one; if not, the job's
bytes are still the caller's.
*/
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
		ok: bool
		src.dec, src.info, ok = webp.anim_open(src.data)
		if !ok || src.info.width <= 0 || src.info.height <= 0 {
			log.debugf("image %d: can't decode the animation", job.id)
			anim_source_close(&src)
			return result, true
		}
	case gif.is_gif(job.jpeg):
		g, ok := gif.info(job.jpeg)
		info := webp.Anim_Info{g.width, g.height, g.frames, g.loops}
		if !ok || info.frames <= 1 || !gif_fits(info) {
			if ok && info.frames > 1 {
				log.debugf(
					"image %d: a GIF of %d frames of %dx%d is too big to play; showing its first",
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
			log.debugf("image %d: can't decode the GIF: %s", job.id, stbi.failure_reason())
			anim_source_close(&src)
			return result, true
		}
	case:
		return
	}
	if i64(src.info.width) * i64(src.info.height) > clipboard.MAX_PIXELS {
		log.debugf(
			"image %d: animation is %dx%d, over the limit",
			job.id,
			src.info.width,
			src.info.height,
		)
		anim_source_close(&src)
		return result, true
	}
	frame, shown, got := anim_take(&src)
	if !got {
		log.debugf("image %d: can't decode the animation's first frame", job.id)
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
		anim_source_close(&src) // a still picture after all
		return result, true
	}
	result.anim = true
	result.gif = src.gif != nil
	result.shown = shown
	anim_drop(w, job.id, job.generation) // asked for again, after a Drop
	w.anims[job.id] = src
	return result, true
}

/*
anim_next_frame hands over the next frame of animation `id`, in a result
of its own (Decode_Result.frame). One without pixels says there are no
more: it has played as often as it says, or it can't be decoded.
*/
anim_next_frame :: proc(w: ^Decode_Worker, id, generation: u64) -> Decode_Result {
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

// anim_drop stops playing `id`, if it's the one of `generation`.
anim_drop :: proc(w: ^Decode_Worker, id, generation: u64) {
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

// source_reset starts either kind again from its first frame.
@(private = "file")
source_reset :: proc(src: ^Anim_Source) {
	if src.gif == nil {
		webp.anim_reset(src.dec)
	}
	src.gif_next, src.gif_ends = 0, 0
}

/*
anim_take decodes the next frame to show (a copy, owned) and for how
long: frames are taken until they've added up to ANIM_MIN_SHOWN, or the
time round ends. Past the last frame it starts again, unless it has
been round as often as the animation says; then, and for broken data,
there's no frame.
*/
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
				break taking // what's taken is shown before going round again
			}
			src.rounds += 1
			// Twice here without a frame is a round without any, which
			// would go round for ever.
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

// gif_fits is whether all of a GIF's frames, decoded, fit GIF_BUDGET.
@(private = "file")
gif_fits :: proc(info: webp.Anim_Info) -> bool {
	return i64(info.width) * i64(info.height) * 4 * i64(info.frames) <= GIF_BUDGET
}

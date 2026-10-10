#+build !wasi
package client

import "core:slice"
import "core:testing"
import "core:time"

// 6x4: red for 50 ms, green for 100, half-transparent blue for 5 (shown
// for 100, as browsers do); for ever.
@(private = "file")
ANIM := #load("../common/webp/testdata/anim.webp")
// 4x4: red, green, blue, yellow, 20 ms each; played once.
@(private = "file")
ANIM_ONCE := #load("../common/webp/testdata/anim_once.webp")
@(private = "file")
STILL := #load("../common/webp/testdata/still.webp")

@(private = "file")
first_pixel :: proc(r: Decode_Result) -> [4]u8 {
	p := r.image.pixels
	if len(p) < 4 {
		return {}
	}
	return {p[0], p[1], p[2], p[3]}
}

@(private = "file")
job_of :: proc(data: []u8, id: u64) -> Decode_Job {
	return {kind = .Decode, id = id, jpeg = slice.clone(data), generation = 1}
}

@(test)
test_anim_frame_ms :: proc(t: ^testing.T) {
	testing.expect_value(t, anim_frame_ms(0), 100)
	testing.expect_value(t, anim_frame_ms(10), 100)
	testing.expect_value(t, anim_frame_ms(11), 20)
	testing.expect_value(t, anim_frame_ms(40), 40)
}

@(test)
test_anim_plays :: proc(t: ^testing.T) {
	w: Decode_Worker
	defer anims_destroy(&w)

	first, is_anim := anim_start(&w, job_of(ANIM, 7))
	defer clipboard_image_free(&first)
	testing.expect(t, is_anim)
	testing.expect(t, first.ok && first.anim && !first.frame)
	testing.expect_value(t, first.image.width, 6)
	testing.expect_value(t, first.shown, 50 * time.Millisecond)
	testing.expect_value(t, first_pixel(first), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, len(w.anims), 1)

	// Round and round: green, blue, then red again.
	want := [?]struct {
		rgba:  [4]u8,
		shown: time.Duration,
	} {
		{{0, 255, 0, 255}, 100 * time.Millisecond},
		{{0, 0, 255, 128}, 100 * time.Millisecond},
		{{255, 0, 0, 255}, 50 * time.Millisecond},
		{{0, 255, 0, 255}, 100 * time.Millisecond},
	}
	for f in want {
		r := anim_next_frame(&w, 7, 1)
		defer clipboard_image_free(&r)
		testing.expect(t, r.ok && r.anim && r.frame)
		testing.expect_value(t, first_pixel(r), f.rgba)
		testing.expect_value(t, r.shown, f.shown)
	}

	// Another generation's (another server's) is let alone.
	anim_drop(&w, 7, 2)
	testing.expect_value(t, len(w.anims), 1)
	stale := anim_next_frame(&w, 7, 2)
	testing.expect(t, !stale.ok && stale.image.pixels == nil)
	anim_drop(&w, 7, 1)
	testing.expect_value(t, len(w.anims), 0)
	gone := anim_next_frame(&w, 7, 1)
	testing.expect(t, !gone.ok && gone.frame)
}

@(test)
test_anim_merges_and_ends :: proc(t: ^testing.T) {
	w: Decode_Worker
	defer anims_destroy(&w)

	// 20 ms frames are shown two at a time, for 40: never more than 30
	// frames a second, at the animation's own speed.
	first, _ := anim_start(&w, job_of(ANIM_ONCE, 3))
	defer clipboard_image_free(&first)
	testing.expect_value(t, first.shown, 40 * time.Millisecond)
	testing.expect_value(t, first_pixel(first), [4]u8{0, 255, 0, 255})

	second := anim_next_frame(&w, 3, 1)
	defer clipboard_image_free(&second)
	testing.expect_value(t, second.shown, 40 * time.Millisecond)
	testing.expect_value(t, first_pixel(second), [4]u8{255, 255, 0, 255})

	// Played once: no more, and the decoder is let go of.
	end := anim_next_frame(&w, 3, 1)
	testing.expect(t, end.frame && !end.ok && end.image.pixels == nil)
	testing.expect_value(t, len(w.anims), 0)
}

@(test)
test_anim_not_for_stills :: proc(t: ^testing.T) {
	w: Decode_Worker
	defer anims_destroy(&w)
	job := job_of(STILL, 1)
	_, is_anim := anim_start(&w, job)
	testing.expect(t, !is_anim) // the caller decodes it, with the bytes still its own
	delete(job.jpeg)
	bad := job_of([]u8{'R', 'I', 'F', 'F', 0, 0, 0, 0, 'W', 'E', 'B', 'P'}, 2)
	_, is_anim = anim_start(&w, bad)
	testing.expect(t, !is_anim)
	delete(bad.jpeg)
	testing.expect_value(t, len(w.anims), 0)
}

// 6x4: red for 50 ms, green for 100, blue for 0 (shown for 100); for ever.
@(private = "file")
GIF := #load("../common/gif/testdata/anim.gif")
// 4x4: red, green, blue, yellow, 20 ms each; no NETSCAPE2.0 block (once).
@(private = "file")
GIF_ONCE := #load("../common/gif/testdata/anim_once.gif")
// 4x4: red and green, 100 ms each; looped 2 more times.
@(private = "file")
GIF_LOOP2 := #load("../common/gif/testdata/anim_loop2.gif")
// 9 frames of 1000x1000: 36 MB decoded, over GIF_BUDGET.
@(private = "file")
GIF_BIG := #load("../common/gif/testdata/anim_big.gif")
@(private = "file")
GIF_STILL := #load("../common/gif/testdata/still.gif")

@(test)
test_gif_plays :: proc(t: ^testing.T) {
	w: Decode_Worker
	defer anims_destroy(&w)

	first, is_anim := anim_start(&w, job_of(GIF, 9))
	defer clipboard_image_free(&first)
	testing.expect(t, is_anim && first.ok && first.anim)
	testing.expect_value(t, first.image.width, 6)
	testing.expect_value(t, first.shown, 50 * time.Millisecond)
	testing.expect_value(t, first_pixel(first), [4]u8{255, 0, 0, 255})
	want := [?]struct {
		rgba:  [4]u8,
		shown: time.Duration,
	} {
		{{0, 255, 0, 255}, 100 * time.Millisecond},
		{{0, 0, 255, 255}, 100 * time.Millisecond},
		{{255, 0, 0, 255}, 50 * time.Millisecond},
	}
	for f in want {
		r := anim_next_frame(&w, 9, 1)
		defer clipboard_image_free(&r)
		testing.expect(t, r.ok)
		testing.expect_value(t, first_pixel(r), f.rgba)
		testing.expect_value(t, r.shown, f.shown)
	}
}

@(test)
test_gif_merges_and_loops :: proc(t: ^testing.T) {
	w: Decode_Worker
	defer anims_destroy(&w)

	// 20 ms frames two at a time; played once.
	first, _ := anim_start(&w, job_of(GIF_ONCE, 1))
	defer clipboard_image_free(&first)
	testing.expect_value(t, first.shown, 40 * time.Millisecond)
	testing.expect_value(t, first_pixel(first), [4]u8{0, 255, 0, 255})
	second := anim_next_frame(&w, 1, 1)
	defer clipboard_image_free(&second)
	testing.expect_value(t, first_pixel(second), [4]u8{255, 255, 0, 255})
	end := anim_next_frame(&w, 1, 1)
	testing.expect(t, !end.ok && end.image.pixels == nil)

	// Three times through two frames: five frames after the first.
	start, _ := anim_start(&w, job_of(GIF_LOOP2, 2))
	defer clipboard_image_free(&start)
	for _ in 0 ..< 5 {
		r := anim_next_frame(&w, 2, 1)
		defer clipboard_image_free(&r)
		testing.expect(t, r.ok)
	}
	end = anim_next_frame(&w, 2, 1)
	testing.expect(t, !end.ok)
	testing.expect_value(t, len(w.anims), 0)
}

@(test)
test_gif_stills :: proc(t: ^testing.T) {
	w: Decode_Worker
	defer anims_destroy(&w)
	// Too big to play, and a single frame: both left to the still decoder,
	// with the bytes still the caller's.
	for data in ([][]u8{GIF_BIG, GIF_STILL}) {
		job := job_of(data, 1)
		_, is_anim := anim_start(&w, job)
		testing.expect(t, !is_anim)
		delete(job.jpeg)
	}
	testing.expect_value(t, len(w.anims), 0)
}

@(test)
test_paste_animation_ext :: proc(t: ^testing.T) {
	// What a paste keeps as it is: animations, of either kind, however
	// big (the server's limit is the paste's to check).
	ext, ok := animation_ext(ANIM)
	testing.expect(t, ok && ext == "webp")
	ext, ok = animation_ext(GIF)
	testing.expect(t, ok && ext == "gif")
	ext, ok = animation_ext(GIF_BIG)
	testing.expect(t, ok && ext == "gif")
	// Still ones are compressed like any picture.
	for data in ([][]u8{STILL, GIF_STILL, nil, {1, 2, 3}}) {
		_, ok = animation_ext(data)
		testing.expect(t, !ok)
	}
}

@(private = "file")
clipboard_image_free :: proc(r: ^Decode_Result) {
	delete(r.image.pixels)
	r.image = {}
}

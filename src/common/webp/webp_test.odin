#+build !wasi
package webp

import "core:testing"

// Three frames of 6x4: red for 50 ms, green for 100, half-transparent
// blue for 5; lossless, played for ever.
@(private = "file")
ANIM := #load("testdata/anim.webp")
// One still frame of 6x4.
@(private = "file")
STILL := #load("testdata/still.webp")

@(test)
test_is_animation :: proc(t: ^testing.T) {
	testing.expect(t, is_animation(ANIM))
	testing.expect(t, !is_animation(STILL))
	testing.expect(t, !is_animation(nil))
	testing.expect(t, !is_animation([]u8{1, 2, 3, 4}))
}

@(test)
test_anim_frames :: proc(t: ^testing.T) {
	dec, info, ok := anim_open(ANIM)
	testing.expect(t, ok)
	defer anim_close(dec)
	testing.expect_value(t, info, Anim_Info{width = 6, height = 4, frames = 3, loops = 0})

	want := [3]struct {
		rgba: [4]u8,
		ends: int,
	}{{{255, 0, 0, 255}, 50}, {{0, 255, 0, 255}, 150}, {{0, 0, 255, 128}, 155}}
	// Twice through: the second time after a reset.
	for round in 0 ..< 2 {
		for w in want {
			pixels, ends, next := anim_next(dec, info)
			testing.expect_value(t, next, Anim_Next.Frame)
			testing.expect_value(t, len(pixels), 6 * 4 * 4)
			testing.expect_value(t, ends, w.ends)
			if len(pixels) == 6 * 4 * 4 {
				testing.expect_value(t, [4]u8{pixels[20], pixels[21], pixels[22], pixels[23]}, w.rgba)
			}
		}
		_, _, next := anim_next(dec, info)
		testing.expect_value(t, next, Anim_Next.End)
		if round == 0 {
			anim_reset(dec)
		}
	}
}

@(test)
test_encode_rgba :: proc(t: ^testing.T) {
	// Half transparent and half not: the alpha comes back as it was.
	pixels: [8 * 8 * 4]u8
	for i in 0 ..< 64 {
		pixels[i * 4 + 0] = 200
		pixels[i * 4 + 3] = 0 if i < 32 else 255
	}
	data, ok := encode_rgba(pixels[:], 8, 8, 90)
	defer delete(data)
	testing.expect(t, ok && is_webp(data))
	back: [8 * 8 * 4]u8
	testing.expect(t, decode_into(data, back[:], 8))
	testing.expect_value(t, back[3], 0)
	testing.expect_value(t, back[63 * 4 + 3], 255)
}

@(test)
test_anim_still :: proc(t: ^testing.T) {
	// A still picture opens as an animation of one frame.
	dec, info, ok := anim_open(STILL)
	testing.expect(t, ok)
	testing.expect_value(t, info.frames, 1)
	anim_close(dec)
	_, _, ok = anim_open([]u8{'R', 'I', 'F', 'F'})
	testing.expect(t, !ok)
	// A still WebP still decodes as one; an animation doesn't.
	pixels: [6 * 4 * 4]u8
	testing.expect(t, decode_into(STILL, pixels[:], 6))
	testing.expect_value(t, [4]u8{pixels[0], pixels[1], pixels[2], pixels[3]}, [4]u8{10, 20, 30, 255})
	testing.expect(t, !decode_into(ANIM, pixels[:], 6))
}

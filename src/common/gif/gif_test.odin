#+build !wasi
package gif

import "core:testing"

// 6x4, three frames: red for 50 ms, green for 100 ms, blue for 0 ms; loops forever.
@(private = "file")
ANIM := #load("testdata/anim.gif")
// 4x4, four frames; no NETSCAPE2.0 block, so it plays once.
@(private = "file")
ONCE := #load("testdata/anim_once.gif")
// 4x4, two frames; repeats 2 more times after the first play.
@(private = "file")
LOOP2 := #load("testdata/anim_loop2.gif")
// 9 frames of 1000x1000 pixels.
@(private = "file")
BIG := #load("testdata/anim_big.gif")
@(private = "file")
STILL := #load("testdata/still.gif")

@(test)
test_info :: proc(t: ^testing.T) {
	i, ok := info(ANIM)
	testing.expect(t, ok)
	testing.expect_value(t, i, Info{width = 6, height = 4, frames = 3, loops = 0})
	i, ok = info(ONCE)
	testing.expect_value(t, i, Info{width = 4, height = 4, frames = 4, loops = 1})
	i, ok = info(LOOP2)
	testing.expect_value(t, i.loops, 3)
	i, ok = info(BIG)
	testing.expect_value(t, i, Info{width = 1000, height = 1000, frames = 9, loops = 0})
	i, ok = info(STILL)
	testing.expect(t, ok)
	testing.expect_value(t, i.frames, 1)

	// A file missing only its trailer is still read, but one that is cut off
	// inside a block is rejected.
	_, ok = info(ANIM[:len(ANIM) - 1])
	testing.expect(t, ok)
	_, ok = info(ANIM[:len(ANIM) - 6])
	testing.expect(t, !ok)
	_, ok = info([]u8{'R', 'I', 'F', 'F'})
	testing.expect(t, !ok)
	testing.expect(t, is_gif(ANIM))
	testing.expect(t, !is_gif([]u8{'G', 'I', 'F'}))
}

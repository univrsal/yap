package client

import "core:fmt"
import "core:os"
import "core:testing"
import mu "vendor:microui"

/*
The icons are drawn from shapes rather than loaded, so what comes out is
worth checking: that each one is there, that it keeps to its own square,
and that the ones which stand for opposite states don't look alike.

To look at them, run the tests with YAP_ICON_DUMP set to a directory and
open the PGMs it leaves there.
*/

@(private = "file")
// ink is how much of an icon's square is covered, 0 to 1.
ink :: proc(a: ^Icon_Atlas, icon: Icon) -> f32 {
	sum: f32
	for y in 0 ..< int(a.side) {
		row := y * int(a.width) + int(icon) * int(a.side)
		for x in 0 ..< int(a.side) {
			sum += f32(a.pixels[row + x]) / 255
		}
	}
	return sum / f32(a.side * a.side)
}

@(private = "file")
// column reports the ink in one column of an icon's square.
column :: proc(a: ^Icon_Atlas, icon: Icon, x: int) -> int {
	sum: int
	for y in 0 ..< int(a.side) {
		sum += int(a.pixels[y * int(a.width) + int(icon) * int(a.side) + x])
	}
	return sum
}

@(test)
test_icons_are_drawn :: proc(t: ^testing.T) {
	for scale in ([]f32{1, 1.5, 2}) {
		a: Icon_Atlas
		defer icon_atlas_destroy(&a)
		testing.expect(t, icon_atlas_build(&a, scale))
		testing.expect_value(t, a.width, a.side * i32(len(Icon)))
		testing.expect_value(t, a.height, a.side)

		for icon in Icon {
			covered := ink(&a, icon)
			// Enough to see, not so much that it's a blob.
			testing.expectf(
				t,
				covered > 0.1 && covered < 0.6,
				"%v at %.1fx covers %.0f%% of its square",
				icon,
				scale,
				covered * 100,
			)
			// Nothing may run into the icon beside it.
			testing.expectf(t, column(&a, icon, 0) == 0, "%v touches its left edge", icon)
			testing.expectf(
				t,
				column(&a, icon, int(a.side) - 1) == 0,
				"%v touches its right edge",
				icon,
			)
		}
	}
}

@(test)
test_icons_tell_states_apart :: proc(t: ^testing.T) {
	a: Icon_Atlas
	defer icon_atlas_destroy(&a)
	testing.expect(t, icon_atlas_build(&a, 1))

	same :: proc(a: ^Icon_Atlas, x, y: Icon) -> bool {
		for i in 0 ..< int(a.side) * int(a.side) {
			row, col := i / int(a.side), i % int(a.side)
			at :: proc(a: ^Icon_Atlas, icon: Icon, row, col: int) -> u8 {
				return a.pixels[row * int(a.width) + int(icon) * int(a.side) + col]
			}
			if at(a, x, row, col) != at(a, y, row, col) {
				return false
			}
		}
		return true
	}
	testing.expect(t, !same(&a, .Mic, .Mic_Off), "muted looks like unmuted")
	testing.expect(t, !same(&a, .Sound, .Sound_Off), "deafened looks like undeafened")
	testing.expect(t, !same(&a, .Mic, .Sound), "the microphone looks like the speaker")
	// A line through an icon covers more of the square than the icon did.
	testing.expect(t, ink(&a, .Mic_Off) > ink(&a, .Mic), "the line through the microphone is missing")
}

@(test)
test_icon_ids_stay_in_their_range :: proc(t: ^testing.T) {
	// Above microui's own icons, below the chat images' (ui_images.odin).
	for icon in Icon {
		id := int(icon_id(icon))
		testing.expectf(t, id > int(max(mu.Icon)), "%v collides with microui's icons", icon)
		testing.expectf(t, id < IMAGE_ICON_BASE, "%v collides with the chat images", icon)
	}
}

@(test)
test_dump_icons_when_asked :: proc(t: ^testing.T) {
	dir := os.get_env("YAP_ICON_DUMP", context.temp_allocator)
	if dir == "" {
		return
	}
	for scale in ([]f32{1, 2, 4}) {
		a: Icon_Atlas
		defer icon_atlas_destroy(&a)
		testing.expect(t, icon_atlas_build(&a, scale))
		out := make([dynamic]u8, context.temp_allocator)
		append(&out, ..transmute([]u8)fmt.tprintf("P5\n%d %d\n255\n", a.width, a.height))
		append(&out, ..a.pixels)
		err := os.write_entire_file(fmt.tprintf("%s/icons-%.0fx.pgm", dir, scale), out[:])
		testing.expect_value(t, err, nil)
	}
}

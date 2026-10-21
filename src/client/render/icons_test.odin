#+build !wasi
package render

import "core:fmt"
import "core:os"
import "core:testing"
import mu "vendor:microui"

// The icons are drawn from shapes instead of being loaded, so the result is
// worth checking. These tests verify that each icon is present, that it stays
// within its own square, and that icons for opposite states do not look alike.
//
// To look at the icons, run the tests with YAP_ICON_DUMP set to a directory
// and open the PGM files that are written there.

@(private = "file")
// ink returns how much of an icon's square is covered, from 0 to 1.
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
// column returns the ink in one column of an icon's square.
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
		testing.expect_value(t, a.width, a.side * i32(ICON_SLOTS))
		testing.expect_value(t, a.height, a.side)

		for icon in Icon {
			covered := ink(&a, icon)
			// Enough to see but not so much that it is a blob. The window's
			// controls are lines one pixel wide, which cover less.
			least: f32 = 0.02 if icon >= .Minimize && icon <= .Close else 0.1
			testing.expectf(
				t,
				covered > least && covered < 0.6,
				"%v at %.1fx covers %.0f%% of its square",
				icon,
				scale,
				covered * 100,
			)
			// Nothing may run into the neighboring icon.
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
	testing.expect(t, !same(&a, .Screen, .Screen_Off), "stop watching looks like the screen")
	testing.expect(
		t,
		!same(&a, .Fullscreen, .Exit_Fullscreen),
		"leaving fullscreen looks like going fullscreen",
	)
	testing.expect(t, !same(&a, .Pop_Out, .Pop_In), "popping in looks like popping out")
	// A line through an icon covers more of the square than the icon alone.
	testing.expect(
		t,
		ink(&a, .Mic_Off) > ink(&a, .Mic),
		"the line through the microphone is missing",
	)
}

@(test)
test_icon_ids_stay_in_their_range :: proc(t: ^testing.T) {
	// Above microui's own icons and below the chat images (ui_images.odin).
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

@(test)
test_icon_rgba :: proc(t: ^testing.T) {
	SIDE :: 32
	green := mu.Color{60, 190, 90, 255}
	pixels := icon_rgba(.Mic, SIDE, green)
	defer delete(pixels)
	testing.expect_value(t, len(pixels), SIDE * SIDE * 4)

	solid, clear: int
	for i := 0; i < len(pixels); i += 4 {
		// One flat color throughout. Only the transparency is shaped.
		testing.expect_value(t, pixels[i], green.r)
		testing.expect_value(t, pixels[i + 1], green.g)
		testing.expect_value(t, pixels[i + 2], green.b)
		switch pixels[i + 3] {
		case 255:
			solid += 1
		case 0:
			clear += 1
		}
	}
	testing.expectf(t, solid > 50, "the icon is barely there (%d solid pixels)", solid)
	testing.expectf(t, clear > 200, "the icon has no space around it (%d clear pixels)", clear)

	// A different state has to look different. Otherwise the tray icon
	// would look the same whatever is going on.
	muted := icon_rgba(.Mic_Off, SIDE, green)
	defer delete(muted)
	same := true
	for b, i in muted {
		if b != pixels[i] {
			same = false
			break
		}
	}
	testing.expect(t, !same, "muted and unmuted draw the same tray icon")
}

@(test)
test_dump_tray_icons_when_asked :: proc(t: ^testing.T) {
	dir := os.get_env("YAP_ICON_DUMP", context.temp_allocator)
	if dir == "" {
		return
	}
	// The three icons that the tray uses, in the colors it uses, written as
	// PPM files on a mid-gray panel so the transparency shows.
	SIDE :: 32
	states := [?]struct {
		name:  string,
		icon:  Icon,
		color: mu.Color,
	} {
		{"quiet", .Mic, {140, 148, 160, 255}},
		{"talking", .Mic, {60, 190, 90, 255}},
		{"muted", .Mic_Off, {225, 80, 80, 255}},
		{"deafened", .Sound_Off, {225, 80, 80, 255}},
	}
	for state in states {
		pixels := icon_rgba(state.icon, SIDE, state.color, context.temp_allocator)
		out := make([dynamic]u8, context.temp_allocator)
		append(&out, ..transmute([]u8)fmt.tprintf("P6\n%d %d\n255\n", SIDE, SIDE))
		for i := 0; i < len(pixels); i += 4 {
			a := f32(pixels[i + 3]) / 255
			for c in 0 ..< 3 {
				// Over a mid gray, as a panel would show it.
				append(&out, u8(f32(pixels[i + c]) * a + 128 * (1 - a)))
			}
		}
		err := os.write_entire_file(fmt.tprintf("%s/tray-%s.ppm", dir, state.name), out[:])
		testing.expect_value(t, err, nil)
	}
}

// The window's controls are lines about a pixel thick, which only look the
// same at every scale if they cover whole texels. None may be half covered,
// except for the cross's diagonals, which cannot avoid it.
@(test)
test_window_controls_are_sharp :: proc(t: ^testing.T) {
	for scale in ([]f32{1, 1.25, 1.5, 1.75, 2, 3}) {
		a: Icon_Atlas
		defer icon_atlas_destroy(&a)
		testing.expect(t, icon_atlas_build(&a, scale))
		for icon in ([]Icon{.Minimize, .Maximize, .Restore}) {
			blurred := 0
			for y in 0 ..< int(a.side) {
				for x in 0 ..< int(a.side) {
					v := a.pixels[y * int(a.width) + int(icon) * int(a.side) + x]
					if v != 0 && v != 255 {
						blurred += 1
					}
				}
			}
			testing.expectf(
				t,
				blurred == 0,
				"%v at %.2fx has %d texels half covered",
				icon,
				scale,
				blurred,
			)
		}
	}
}

// Each of a spinner's steps is drawn, about as much as the others (it is the
// same ring, turned), inside its square, and differs from the step before.
@(test)
test_spinner_steps :: proc(t: ^testing.T) {
	for scale in ([]f32{1, 1.5, 2}) {
		a: Icon_Atlas
		defer icon_atlas_destroy(&a)
		testing.expect(t, icon_atlas_build(&a, scale))
		first := ink(&a, .Spinner)
		for step in 0 ..< SPINNER_STEPS {
			icon := Icon(int(Icon.Spinner) + step)
			covered := ink(&a, icon)
			testing.expectf(
				t,
				covered > 0.1 && abs(covered - first) < first * 0.15,
				"spinner step %d at %.1fx covers %.0f%% (step 0: %.0f%%)",
				step,
				scale,
				covered * 100,
				first * 100,
			)
			testing.expectf(t, column(&a, icon, 0) == 0, "spinner step %d touches its left edge", step)
			testing.expectf(
				t,
				column(&a, icon, int(a.side) - 1) == 0,
				"spinner step %d touches its right edge",
				step,
			)
			prev := Icon(int(Icon.Spinner) + (step + SPINNER_STEPS - 1) % SPINNER_STEPS)
			differs := false
			for y in 0 ..< int(a.side) {
				row := y * int(a.width)
				for x in 0 ..< int(a.side) {
					differs ||=
						a.pixels[row + int(icon) * int(a.side) + x] !=
						a.pixels[row + int(prev) * int(a.side) + x]
				}
			}
			testing.expectf(t, differs, "spinner step %d looks like the one before", step)
		}
	}
	testing.expect_value(t, spinner_id(SPINNER_STEPS + 1), spinner_id(1))
}

#+build !wasi
package client

import "core:testing"
import mu "vendor:microui"

// The preview of a composer chip goes above the chip, or below it if there is no
// room above, and never over it: it would take the pointer's hover from the chip,
// and a click on it would open the viewer instead of inserting the picture.
@(test)
test_chip_preview_place :: proc(t: ^testing.T) {
	chrome :: i32(40)
	over :: proc(a_y, a_h, b_y, b_h: i32) -> bool {
		return a_y < b_y + b_h && b_y < a_y + a_h
	}

	// Room above: the window ends just above the chip.
	chip := mu.Rect{10, 600, 100, 20}
	y, w, h, ok := chip_preview_place(chip, 700, 320, 240, chrome)
	testing.expect(t, ok)
	testing.expect_value(t, y, i32(600 - 2 - 280))
	testing.expect_value(t, w, i32(320))
	testing.expect_value(t, h, i32(240))

	// The chip is near the top: it goes below.
	chip = mu.Rect{10, 40, 100, 20}
	y, w, h, ok = chip_preview_place(chip, 700, 320, 240, chrome)
	testing.expect(t, ok)
	testing.expect_value(t, y, i32(40 + 20 + 2))
	testing.expect_value(t, h, i32(240))

	// A short window: not room for all of it on either side, so the picture is
	// made smaller, on the side with more room, and still off the chip.
	for window_h in ([]i32{350, 300, 260, 200}) {
		for chip_y in ([]i32{40, 100, 150, window_h - 80}) {
			chip = mu.Rect{10, chip_y, 100, 20}
			y, w, h, ok = chip_preview_place(chip, window_h, 320, 240, chrome)
			if !ok {
				continue
			}
			testing.expectf(
				t,
				y >= 0 && y + h + chrome <= window_h,
				"%d, %d: %d to %d",
				window_h,
				chip_y,
				y,
				y + h + chrome,
			)
			testing.expectf(
				t,
				!over(y, h + chrome, chip.y, chip.h),
				"%d, %d: over the chip",
				window_h,
				chip_y,
			)
			testing.expect(t, h >= CHIP_PREVIEW_MIN && h <= 240)
			// The shape is kept.
			testing.expect(t, abs(w * 240 - h * 320) <= 240)
		}
	}

	// Not even room for the least: no preview.
	chip = mu.Rect{10, 60, 100, 20}
	_, _, _, ok = chip_preview_place(chip, 140, 320, 240, chrome)
	testing.expect(t, !ok)
}

#+build !wasi
package render

import "core:math"
import "core:testing"

// At any scale, the line stays inside its band, is at least a line thick in
// every column, and goes up and down by more than its own thickness.
@(test)
test_squiggle_column :: proc(t: ^testing.T) {
	for s in ([]f32{1, 1.25, 1.5, 2, 2.5, 3}) {
		y1 := f32(100)
		y0 := y1 - math.round(SQUIGGLE_HEIGHT * s)
		thick := line_thickness(s)
		highest, lowest := y1, y0
		for i in 0 ..< int(40 * s) {
			top, bottom := squiggle_column(i, y0, y1, s)
			testing.expectf(t, y0 <= top && bottom <= y1, "%v: column %d out of the band", s, i)
			testing.expectf(
				t,
				bottom - top >= thick - 0.001,
				"%v: column %d is %v thick, not %v",
				s,
				i,
				bottom - top,
				thick,
			)
			highest, lowest = min(highest, top), max(lowest, bottom)
		}
		testing.expectf(t, lowest - highest > thick + 0.5, "%v: flat (%v..%v)", s, highest, lowest)
	}
}

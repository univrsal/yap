#+build !wasi
package render

import "core:math"
import "core:testing"

// A line one logical pixel thick has to be as thick wherever it falls,
// whatever the scale: it used to be one physical pixel here and two there.
@(test)
test_thin_lines_keep_their_thickness :: proc(t: ^testing.T) {
	for scale in ([]f32{1, 1.25, 1.5, 1.75, 2, 2.5, 3}) {
		want := math.floor(scale + 0.001)
		for start in i32(0) ..< 40 {
			a, b := snap_span(start, 1, scale)
			got := math.round((b - a) * scale)
			testing.expectf(
				t,
				got == want,
				"1px line at %d, scale %.2f: %.0f physical pixels, want %.0f",
				start,
				scale,
				got,
				want,
			)
			// And on a physical pixel.
			testing.expect_value(t, a * scale, math.round(a * scale))
		}
	}
}

// Bigger rects still meet their neighbours edge to edge.
@(test)
test_rects_tile :: proc(t: ^testing.T) {
	for scale in ([]f32{1.25, 1.5, 2}) {
		_, end := snap_span(7, 20, scale)
		start, _ := snap_span(27, 20, scale)
		testing.expect_value(t, end, start)
	}
}

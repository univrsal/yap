#+build !wasi
package client

import "core:testing"

import "client:render"

// "ab" then two right-to-left letters "CD" (one byte each here), as a line
// in a left-to-right paragraph draws them: a b D C, 10 pixels each.
@(private = "file")
mixed_spans :: proc() -> []render.Char_Span {
	spans := make([]render.Char_Span, 4, context.temp_allocator)
	spans[0] = {at = 0, x0 = 0, x1 = 10}
	spans[1] = {at = 1, x0 = 10, x1 = 20}
	spans[2] = {at = 2, x0 = 30, x1 = 40, rtl = true}
	spans[3] = {at = 3, x0 = 20, x1 = 30, rtl = true}
	return spans
}

@(test)
test_bidi_caret :: proc(t: ^testing.T) {
	spans := mixed_spans()
	// The start at the left edge, the end at the right edge (a left-to-right
	// line); in between, the trailing edge of the character before: right
	// for "a" and "b", left for "C".
	testing.expect_value(t, bidi_caret_x(spans, 0, 4, 0), 0)
	testing.expect_value(t, bidi_caret_x(spans, 0, 4, 1), 10)
	testing.expect_value(t, bidi_caret_x(spans, 0, 4, 2), 20)
	testing.expect_value(t, bidi_caret_x(spans, 0, 4, 3), 30)
	testing.expect_value(t, bidi_caret_x(spans, 0, 4, 4), 40)
	// In a right-to-left line, the start is on the right and the end on the
	// left.
	for &s in spans {
		s.line_rtl = true
	}
	testing.expect_value(t, bidi_caret_x(spans, 0, 4, 0), 40)
	testing.expect_value(t, bidi_caret_x(spans, 0, 4, 4), 0)
}

@(test)
test_bidi_offset_at :: proc(t: ^testing.T) {
	spans := mixed_spans()
	// The place whose caret is nearest: 0 at 0, 1 at 10, 2 at 20, 3 at 30,
	// the end at 40.
	testing.expect_value(t, bidi_offset_at(spans, 0, 4, 2), 0)
	testing.expect_value(t, bidi_offset_at(spans, 0, 4, 8), 1)
	testing.expect_value(t, bidi_offset_at(spans, 0, 4, 22), 2)
	testing.expect_value(t, bidi_offset_at(spans, 0, 4, 28), 3)
	testing.expect_value(t, bidi_offset_at(spans, 0, 4, 38), 4)
	// Past the ends: where the line starts and ends.
	testing.expect_value(t, bidi_offset_at(spans, 0, 4, -5), 0)
	testing.expect_value(t, bidi_offset_at(spans, 0, 4, 50), 4)
}

@(test)
test_bidi_ranges :: proc(t: ^testing.T) {
	spans := mixed_spans()
	// "b" and "C": two stretches, as they aren't side by side.
	got := bidi_ranges(spans, 1, 3)
	testing.expect_value(t, len(got), 2)
	testing.expect_value(t, got[0], [2]f32{10, 20})
	testing.expect_value(t, got[1], [2]f32{30, 40})
	// "b", "C" and "D": one stretch.
	got = bidi_ranges(spans, 1, 4)
	testing.expect_value(t, len(got), 1)
	testing.expect_value(t, got[0], [2]f32{10, 40})
}

@(test)
test_bidi_step :: proc(t: ^testing.T) {
	spans := mixed_spans()
	// Right goes along the screen, 10 pixels at a time, to the end.
	want := [?]int{1, 2, 3, 4}
	at := 0
	for w in want {
		to, ok := bidi_step(spans, 0, 4, at, true)
		testing.expect(t, ok)
		testing.expect_value(t, to, w)
		at = to
	}
	_, ok := bidi_step(spans, 0, 4, at, true)
	testing.expect(t, !ok)
	// And back to the left.
	to, _ := bidi_step(spans, 0, 4, 4, false)
	testing.expect_value(t, to, 3)
	to, _ = bidi_step(spans, 0, 4, 1, false)
	testing.expect_value(t, to, 0)
	_, ok = bidi_step(spans, 0, 4, 0, false)
	testing.expect(t, !ok)
}

// "abc שלום 123" as a left-to-right line draws it, 10 pixels a character:
// "abc " (0..3), then "123" (9..11), the space after the Hebrew (8), and the
// Hebrew word from its last letter (7) to its first (4).
@(private = "file")
hebrew_line :: proc() -> []render.Char_Span {
	spans := make([]render.Char_Span, 12, context.temp_allocator)
	for i in 0 ..< 4 {
		spans[i] = {at = i, x0 = f32(i * 10), x1 = f32(i * 10 + 10)}
	}
	for i in 9 ..< 12 {
		x := f32(40 + (i - 9) * 10)
		spans[i] = {at = i, x0 = x, x1 = x + 10}
	}
	spans[8] = {at = 8, x0 = 70, x1 = 80, rtl = true}
	for i in 4 ..< 8 {
		x := f32(80 + (7 - i) * 10)
		spans[i] = {at = i, x0 = x, x1 = x + 10, rtl = true}
	}
	return spans
}

@(test)
test_bidi_mixed_line :: proc(t: ^testing.T) {
	spans := hebrew_line()
	// Right of the line's end: the end of the text, so dragging from its
	// start to there selects all of it.
	testing.expect_value(t, bidi_offset_at(spans, 0, 12, 200), 12)
	testing.expect_value(t, bidi_offset_at(spans, 0, 12, -10), 0)

	// Right, over and over, goes along the whole line to its right end and
	// stays there; nothing is visited twice.
	at := 0
	seen := make(map[int]bool)
	seen[0] = true
	defer delete(seen)
	last_x := bidi_caret_x(spans, 0, 12, at)
	for _ in 0 ..< 20 {
		to, ok := bidi_step(spans, 0, 12, at, true)
		if !ok {
			break
		}
		x := bidi_caret_x(spans, 0, 12, to)
		testing.expectf(t, x > last_x, "from %d to %d: %v is not right of %v", at, to, x, last_x)
		testing.expectf(t, !seen[to], "%d again", to)
		seen[to] = true
		at, last_x = to, x
	}
	// The rightmost place: the end of the text, at the line's right edge.
	testing.expect_value(t, last_x, 120)
	testing.expect_value(t, at, 12)
}

// "a" then a three-character cluster (a conjunct, say) then "b", 10 pixels a
// character, the cluster's characters sharing its 30 pixels.
@(test)
test_bidi_cluster :: proc(t: ^testing.T) {
	spans := make([]render.Char_Span, 5, context.temp_allocator)
	spans[0] = {at = 0, x0 = 0, x1 = 10}
	spans[1] = {at = 1, x0 = 10, x1 = 20}
	spans[2] = {at = 2, x0 = 20, x1 = 30, joined = true}
	spans[3] = {at = 3, x0 = 30, x1 = 40, joined = true}
	spans[4] = {at = 4, x0 = 40, x1 = 50}
	// Right steps over the whole cluster in one press.
	to, ok := bidi_step(spans, 0, 5, 1, true)
	testing.expect(t, ok)
	testing.expect_value(t, to, 4)
	to, _ = bidi_step(spans, 0, 5, 4, false)
	testing.expect_value(t, to, 1)
	// A click inside it lands before or after it.
	testing.expect_value(t, bidi_offset_at(spans, 0, 5, 24), 1)
	testing.expect_value(t, bidi_offset_at(spans, 0, 5, 36), 4)
}

package text

import mu "vendor:microui"

// The state and the layout of a text area, the box that messages are written
// in (ui/widgets/text_area.odin draws it and handles its keys): how its text wraps into
// lines, how tall it is, and what it keeps between frames. None of it needs the
// UI, only a microui context for measuring text.

// The most lines a text area grows to. Beyond that it scrolls.
AREA_MAX_LINES :: 10

// What a text area keeps between frames.
Area :: struct {
	width:        i32, // the text's width in the last frame, for working out the height
	scroll:       i32, // pixels of the text above the box's top
	// Up and Down keep to the column they started in: where they left the
	// caret, and the x position they were aiming for.
	vert_at:      int,
	vert_x:       i32,
	// The selection and length in the last frame. When either changes, the
	// box scrolls to the caret.
	last_sel:     [2]int,
	last_len:     int,
	// Its scrollbar, when there is more text than it shows: where it was in
	// the last frame (zero: none), and while its thumb is dragged, how far
	// down the thumb it was grabbed.
	bar:          mu.Rect,
	dragging:     bool,
	drag_at:      i32,
	// Whether the message is shown as it will look instead (the composer's
	// eye, preview_button).
	preview:      bool,
	had_focus:    bool, // in the last frame
	// Set by its owner before it is measured and laid out: how many lines tall
	// it is at least (0 or 1 for one), and how tall the strip at its bottom is.
	min_lines:    int,
	footer:       i32,
	// A press in the footer, which the caret ignores until it is released.
	footer_press: bool,
	// In a web build, the page's own text field that stands in for it.
	field:        Field_Sync,
	// What Ctrl+Z and Ctrl+Y go through (ui/text/history.odin). Not in a web
	// build, where the page's field has its own.
	history:      History,
}

// What a text area keeps about the page's text field that stands in for it in
// a web build (ui/widgets/field_web.odin): whether it does in this frame, how many
// lines the page wraps the text into (0 while it hasn't said), whether the
// field changed the text since the text area last said so, and the text (as a
// hash and its length) and selection that the two last agreed on.
Field_Sync :: struct {
	live:    bool,
	lines:   int,
	changed: bool,
	synced:  bool,
	hash:    u64,
	len:     int,
	sel:     [2]int,
}

// One line of a text area's text: text[start:end] is drawn, and the caret is
// on it from `start` up to `stop` (where the next line starts, or before the
// newline that ends it, or the end of the text).
Area_Line :: struct {
	start, end, stop: int,
}

// area_lines lays `text` out in lines `width` wide. Every place in the text is
// on exactly one line: a place where a wrap broke the text is on the line that
// starts there. There is always at least one line, and a text ending in a
// newline ends in an empty line for the caret to go to.
area_lines :: proc(
	ctx: ^mu.Context,
	font: mu.Font,
	text: string,
	width: i32,
	allocator := context.temp_allocator,
) -> []Area_Line {
	lines := make([dynamic]Area_Line, allocator)
	at := 0
	for at < len(text) {
		end, next := wrap_line(ctx, font, text[at:], width)
		stop := at + next - 1
		if at + next == len(text) && text[len(text) - 1] != '\n' {
			stop = len(text)
		}
		append(&lines, Area_Line{at, at + end, stop})
		at += next
	}
	if len(text) == 0 || text[len(text) - 1] == '\n' {
		append(&lines, Area_Line{len(text), len(text), len(text)})
	}
	return lines[:]
}

// area_line_of is the line that the place `at` is on.
area_line_of :: proc(lines: []Area_Line, at: int) -> int {
	for l, i in lines {
		if at <= l.stop {
			return i
		}
	}
	return len(lines) - 1
}

// area_x is how far along its line the place `at` is, in pixels.
area_x :: proc(ctx: ^mu.Context, font: mu.Font, text: string, l: Area_Line, at: int) -> i32 {
	return ctx.text_width(font, text[l.start:clamp(at, l.start, l.stop)])
}

// area_single is how tall a text area of one line is: a control's
// height, or more for a bigger font. Each additional line adds a line's height.
area_single :: proc(ctx: ^mu.Context, font: mu.Font) -> i32 {
	return max(ctx.style.size.y + 2 * ctx.style.padding, ctx.text_height(font) + 4)
}

// area_height is how tall the text area for `text` is, in `font` (which
// ctx.style.font has to be when it is laid out).
area_height :: proc(ctx: ^mu.Context, font: mu.Font, text: string, area: ^Area) -> i32 {
	n := 1
	if area.field.live && area.field.lines > 0 {
		n = area.field.lines // as the page wraps it
	} else if area.width > 0 {
		n = len(area_lines(ctx, font, text, area.width))
	}
	return(
		area_single(ctx, font) +
		i32(area_rows(area, n) - 1) * ctx.text_height(font) +
		area.footer \
	)
}

// area_rows is how many lines tall a text area with `n` lines of text is.
area_rows :: proc(area: ^Area, n: int) -> int {
	return max(min(n, AREA_MAX_LINES), area.min_lines, 1)
}

// area_text_rect is the part of a text area's rect that the text is in:
// all of it except the footer.
area_text_rect :: proc(r: mu.Rect, area: ^Area) -> mu.Rect {
	return {r.x, r.y, r.w, max(r.h - area.footer, 1)}
}

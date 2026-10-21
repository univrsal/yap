package client

import "core:fmt"
import "core:strings"
import mu "vendor:microui"

// Long lists in the settings and the Join a channel window (the accounts, who
// has a role, the channels) are shown a page at a time, with a box above them
// to narrow them down:
//
//	[ Search by name...              ]
//	  row
//	  row
//	[ < ]   21-40 of 134   [ > ]
//
// A list that the client has in full is narrowed down here (pager_matches) and
// cut into pages with pager_window. A list that the server pages (the channels
// to join) knows only where its page starts and whether there are more, which
// pager_footer_open shows.

// How many rows a page has.
PAGE_ROWS :: 20

Pager :: struct {
	find_buf: [64]u8,
	find_len: int,
	page:     int,
}

@(private = "file")
PAGE_BUTTON :: 40

// pager_search is the box the list is narrowed down with, a row of its own, with
// `hint` in it while it's empty. Changing what is typed goes back to the first
// page, and returns true.
pager_search :: proc(ui: ^UI, p: ^Pager, hint: string) -> (changed: bool) {
	ctx := &ui.ctx
	mu.layout_row(ctx, {-1})
	res := text_box(ui, p.find_buf[:], &p.find_len)
	if p.find_len == 0 && ctx.focus_id != ctx.last_id {
		r := ctx.last_rect
		font := ctx.style.font
		mu.push_clip_rect(ctx, r)
		mu.draw_text(
			ctx,
			font,
			hint,
			{r.x + ctx.style.padding, r.y + (r.h - ctx.text_height(font)) / 2},
			theme.dim,
		)
		mu.pop_clip_rect(ctx)
	}
	if .CHANGE in res {
		p.page = 0
		return true
	}
	return false
}

// pager_query is what was typed to narrow the list down, without the spaces
// around it.
pager_query :: proc(p: ^Pager) -> string {
	return strings.trim_space(string(p.find_buf[:p.find_len]))
}

// pager_matches says whether any of `fields` contains `query`, ignoring case. An
// empty query matches everything.
pager_matches :: proc(query: string, fields: ..string) -> bool {
	if query == "" {
		return true
	}
	q := strings.to_lower(query, context.temp_allocator)
	for f in fields {
		if strings.contains(strings.to_lower(f, context.temp_allocator), q) {
			return true
		}
	}
	return false
}

// pager_window is the part of a list of `n` rows that the current page shows,
// from `lo` up to `hi`. A page past the end (after the list got shorter) becomes
// the last one.
pager_window :: proc(p: ^Pager, n: int) -> (lo, hi: int) {
	pages := max((n + PAGE_ROWS - 1) / PAGE_ROWS, 1)
	p.page = clamp(p.page, 0, pages - 1)
	lo = p.page * PAGE_ROWS
	return lo, min(lo + PAGE_ROWS, n)
}

// pager_page_of turns to the page that has the `i`th row on it.
pager_page_of :: proc(p: ^Pager, i: int) {
	p.page = max(i, 0) / PAGE_ROWS
}

// pager_footer is the row under a list of `n` rows that turns its pages. There is
// none when it all fits on one page.
pager_footer :: proc(ui: ^UI, p: ^Pager, n: int) {
	if n <= PAGE_ROWS {
		return
	}
	lo, hi := pager_window(p, n)
	pages := (n + PAGE_ROWS - 1) / PAGE_ROWS
	if back, next := footer(ui, fmt.tprintf("%d-%d of %d", lo + 1, hi, n), p.page > 0, p.page < pages - 1);
	   back {
		p.page -= 1
	} else if next {
		p.page += 1
	}
}

// pager_footer_open is pager_footer for a list that the server pages, where
// only the page's start, its length and whether more follow are known. It
// returns the start of the page to ask for when a button was pressed.
pager_footer_open :: proc(
	ui: ^UI,
	offset, count: int,
	more: bool,
) -> (
	ask: int,
	turned: bool,
) {
	if offset == 0 && !more {
		return
	}
	text := fmt.tprintf("%d-%d%s", offset + 1, offset + count, " of more" if more else "")
	if count == 0 {
		text = ""
	}
	back, next := footer(ui, text, offset > 0, more)
	switch {
	case back:
		return max(offset - PAGE_ROWS, 0), true
	case next:
		return offset + count, true
	}
	return
}

// footer draws the buttons for the page before and after, with `text` between
// them, and says which was pressed.
@(private = "file")
footer :: proc(ui: ^UI, text: string, has_back, has_next: bool) -> (back, next: bool) {
	ctx := &ui.ctx
	mu.layout_row(ctx, {PAGE_BUTTON, -(PAGE_BUTTON + ctx.style.spacing + 1), PAGE_BUTTON})
	if has_back {
		back = .SUBMIT in icon_button(ui, "page back", .Back, "Page before")
	} else {
		mu.label(ctx, "")
	}
	with_text_color(ctx, theme.dim, text, proc(ctx: ^mu.Context, text: string) {
		r := mu.layout_next(ctx)
		mu.draw_control_text(ctx, text, r, .TEXT, {.ALIGN_CENTER})
	})
	if has_next {
		next = .SUBMIT in icon_button(ui, "page next", .Next, "Page after")
	} else {
		mu.label(ctx, "")
	}
	return
}

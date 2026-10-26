package client

import "core:slice"
import "core:sync"
import mu "vendor:microui"

import "client:conn"
import "client:settings"

// The command palette (docs/design/keyboard.md): Ctrl+Space or Ctrl+K (Cmd+K
// on macOS) opens a box near the top of the window that lists what can be
// done right now, best match for what is typed first. Up and Down pick,
// Enter runs, Escape (or a click elsewhere) closes it. Tab moves among its
// rows like in any popup.
//
// Matching is by subsequence: the typed letters must come in the command's
// name in that order, not next to each other. Letters at the start of a word
// and letters in a row count for more. Among equal matches, the commands run
// last come first.

UI_Palette :: struct {
	open:      bool,
	focus_box: bool, // just opened: the query box takes the focus
	query:     Text_Field(128),
	selected:  int, // among the matches
	// The text box that had the focus when it opened, and its cursor, to
	// get them back when it closes.
	back:      mu.Id,
	back_sel:  [2]int,
	// The names of the commands run last, newest first, at most
	// PALETTE_RECENT. They are the static names in COMMANDS.
	recent:    [dynamic]string,
}

Command :: struct {
	name:    string,
	// Whether it makes sense now. Called with the View locked; nil: always.
	enabled: proc(ui: ^UI, v: ^conn.View) -> bool,
	run:     proc(ui: ^UI),
	// Shown dimmed at the right end of its row (a hotkey); nil: nothing.
	detail:  proc(ui: ^UI) -> string,
}

@(private = "file")
PALETTE_WINDOW :: "Commands"
@(private = "file")
PALETTE_WIDTH :: 480
@(private = "file")
PALETTE_ROWS :: 10
@(private = "file")
PALETTE_RECENT :: 20

COMMANDS := [?]Command {
	{
		name = "Mute microphone",
		enabled = proc(ui: ^UI, v: ^conn.View) -> bool {return !ui.muted},
		run = proc(ui: ^UI) {set_muted(ui, true)},
		detail = proc(ui: ^UI) -> string {return hotkey_text(ui, false)},
	},
	{
		name = "Unmute microphone",
		enabled = proc(ui: ^UI, v: ^conn.View) -> bool {return ui.muted},
		run = proc(ui: ^UI) {set_muted(ui, false)},
		detail = proc(ui: ^UI) -> string {return hotkey_text(ui, false)},
	},
	{
		name = "Deafen (hear nobody)",
		enabled = proc(ui: ^UI, v: ^conn.View) -> bool {return !ui.deafened},
		run = proc(ui: ^UI) {set_deafened(ui, true)},
		detail = proc(ui: ^UI) -> string {return hotkey_text(ui, true)},
	},
	{
		name = "Undeafen",
		enabled = proc(ui: ^UI, v: ^conn.View) -> bool {return ui.deafened},
		run = proc(ui: ^UI) {set_deafened(ui, false)},
		detail = proc(ui: ^UI) -> string {return hotkey_text(ui, true)},
	},
	{
		name = "Leave voice",
		enabled = proc(ui: ^UI, v: ^conn.View) -> bool {
			return palette_connected(ui, v) && panel_state(v) == .Voice
		},
		run = proc(ui: ^UI) {command(ui, conn.Voice_Command{})},
	},
	{
		name = "Hang up",
		enabled = proc(ui: ^UI, v: ^conn.View) -> bool {
			return palette_connected(ui, v) && panel_state(v) == .Call
		},
		run = proc(ui: ^UI) {command(ui, conn.Call_Hangup_Command{})},
	},
	{
		name = "Search messages",
		enabled = proc(ui: ^UI, v: ^conn.View) -> bool {
			return palette_connected(ui, v) && !ui.search.open
		},
		run = proc(ui: ^UI) {
			ui.search.open = true
			ui.search.placed = false
		},
	},
	{
		name = "Open the inbox",
		enabled = proc(ui: ^UI, v: ^conn.View) -> bool {
			return ui.page != .Buddies && ui.session != nil && !ui.session.joining && !ui.join.open
		},
		run = proc(ui: ^UI) {toggle_inbox(ui)},
	},
	{
		name = "Open the settings",
		enabled = proc(ui: ^UI, v: ^conn.View) -> bool {return ui.page != .Settings},
		run = proc(ui: ^UI) {
			if ui.join.open || ui.join.ns != nil {
				ui.join.close = true // joining a server is abandoned (ui_join.odin)
			}
			open_settings(ui)
		},
	},
	{
		name = "Back to the chat",
		enabled = proc(ui: ^UI, v: ^conn.View) -> bool {return ui.page != .Main},
		run = proc(ui: ^UI) {ui.page = .Main},
	},
	{
		name = "Use the dark theme",
		enabled = proc(ui: ^UI, v: ^conn.View) -> bool {return theme_choice(&ui.settings) != .Dark},
		run = proc(ui: ^UI) {palette_set_theme(ui, .Dark)},
	},
	{
		name = "Use the light theme",
		enabled = proc(ui: ^UI, v: ^conn.View) -> bool {return theme_choice(&ui.settings) != .Light},
		run = proc(ui: ^UI) {palette_set_theme(ui, .Light)},
	},
	{
		name = "Use the system's theme",
		enabled = proc(ui: ^UI, v: ^conn.View) -> bool {return theme_choice(&ui.settings) != .System},
		run = proc(ui: ^UI) {palette_set_theme(ui, .System)},
	},
}

ui_palette_destroy :: proc(ui: ^UI) {
	delete(ui.palette.recent)
}

@(private = "file")
palette_connected :: proc(ui: ^UI, v: ^conn.View) -> bool {
	return ui.session != nil && v.status == .Connected
}

@(private = "file")
palette_set_theme :: proc(ui: ^UI, choice: Theme_Choice) {
	settings.set_setting(&ui.settings.theme, THEME_CHOICE_NAMES[choice])
	save_settings(ui)
	ui_redraw(ui)
}

// palette_window opens and closes the palette with its key, and draws it
// while it is open. Call it after the windows it floats over.
palette_window :: proc(ui: ^UI, w, h: i32) {
	ctx := &ui.ctx
	p := &ui.palette
	if key_take(ui, .Palette) {
		if p.open {
			palette_close(ui)
		} else {
			p.open, p.focus_box = true, true
			p.query.len, p.selected = 0, 0
			p.back, p.back_sel = 0, {}
			if ctx.focus_id != 0 && ctx.textbox_state.id == u64(ctx.focus_id) {
				p.back, p.back_sel = ctx.focus_id, ctx.textbox_state.selection
			}
			mu.open_popup(ctx, PALETTE_WINDOW)
		}
	}
	if !p.open {
		return
	}
	v := ui.view
	sync.guard(&v.mutex)
	matches := palette_matches(ui, v, field_text(&p.query))

	// As tall as its rows, as microui lays them out.
	row := ctx.style.size.y + 2 * ctx.style.padding + ctx.style.spacing
	rows := i32(1 + max(min(len(matches), PALETTE_ROWS), 1))
	pw := min(PALETTE_WIDTH, w - 32)
	if cnt := mu.get_container(ctx, PALETTE_WINDOW); cnt != nil {
		cnt.rect = {(w - pw) / 2, min(80, h / 6), pw, rows * row - ctx.style.spacing + 2 * ctx.style.padding}
	}
	if !mu.begin_window(ctx, PALETTE_WINDOW, {}, {.POPUP, .NO_RESIZE, .NO_TITLE, .NO_SCROLL}) {
		p.open = false // closed by a click elsewhere
		return
	}
	defer mu.end_window(ctx)
	nav_trap(ui)

	// The keys, before the box sees them.
	box := mu.get_id(ctx, uintptr(&p.query.buf[0]))
	if p.focus_box {
		p.focus_box = false
		focus_at(ctx, box, p.query.len)
	}
	if key_take(ui, .Escape) {
		palette_close(ui)
		return
	}
	if n := len(matches); n > 0 && ctx.focus_id == box {
		if key_take(ui, .Up) {
			p.selected = (p.selected + n - 1) % n
		}
		if key_take(ui, .Down) {
			p.selected = (p.selected + 1) % n
		}
	}

	mu.layout_row(ctx, {-1})
	res := text_box(ui, p.query.buf[:], &p.query.len)
	if .CHANGE in res {
		p.selected = 0
		matches = palette_matches(ui, v, field_text(&p.query))
	}
	p.selected = clamp(p.selected, 0, max(len(matches) - 1, 0))
	run := -1
	if .SUBMIT in res {
		if len(matches) > 0 {
			run = p.selected
		} else {
			// Nothing to run: keep typing (microui's box lets go on Enter).
			focus_at(ctx, box, p.query.len)
		}
	}

	if len(matches) == 0 {
		mu.layout_row(ctx, {-1})
		dim_label(ctx, "No command matches.")
	}
	// The rows around the selected one.
	first := clamp(p.selected - PALETTE_ROWS + 1, 0, max(len(matches) - PALETTE_ROWS, 0))
	for i in first ..< min(first + PALETTE_ROWS, len(matches)) {
		c := &COMMANDS[matches[i]]
		mu.layout_row(ctx, {-1})
		if .SUBMIT in list_row(ctx, c.name, c.name, i == p.selected) {
			run = i
		}
		if c.detail != nil {
			if detail := c.detail(ui); detail != "" {
				r := ctx.last_rect
				tw := ctx.text_width(ctx.style.font, detail)
				x := r.x + r.w - tw - ctx.style.padding
				y := r.y + (r.h - ctx.text_height(ctx.style.font)) / 2
				mu.draw_text(ctx, ctx.style.font, detail, {x, y}, theme.dim)
			}
		}
	}

	if run >= 0 {
		c := &COMMANDS[matches[run]]
		palette_close(ui)
		palette_remember(p, c.name)
		c.run(ui)
		ui_redraw(ui)
	}
}

// palette_close closes the palette, and gives the text box it was opened
// from the focus back, with the cursor where it was.
@(private = "file")
palette_close :: proc(ui: ^UI) {
	ctx := &ui.ctx
	p := &ui.palette
	p.open = false
	if cnt := mu.get_container(ctx, PALETTE_WINDOW, {.CLOSED}); cnt != nil {
		cnt.open = false
	}
	if p.back != 0 {
		mu.set_focus(ctx, p.back)
		ctx.textbox_state.id = u64(p.back)
		ctx.textbox_state.selection = p.back_sel
		p.back = 0
	}
}

// palette_remember puts `name` first among the commands run last.
@(private = "file")
palette_remember :: proc(p: ^UI_Palette, name: string) {
	if i, found := slice.linear_search(p.recent[:], name); found {
		ordered_remove(&p.recent, i)
	}
	inject_at(&p.recent, 0, name)
	if len(p.recent) > PALETTE_RECENT {
		resize(&p.recent, PALETTE_RECENT)
	}
}

// palette_matches lists the commands that may be run now and match `query`,
// as indexes into COMMANDS, best first. Allocated in the temp allocator.
@(private = "file")
palette_matches :: proc(ui: ^UI, v: ^conn.View, query: string) -> []int {
	Match :: struct {
		index:  int,
		score:  int,
		recent: int, // where among the recent ones; len(recent) if not
	}
	found := make([dynamic]Match, 0, len(COMMANDS), context.temp_allocator)
	for c, i in COMMANDS {
		if c.enabled != nil && !c.enabled(ui, v) {
			continue
		}
		score, ok := palette_score(query, c.name)
		if !ok {
			continue
		}
		recent := len(ui.palette.recent)
		if at, was := slice.linear_search(ui.palette.recent[:], c.name); was {
			recent = at
		}
		append(&found, Match{i, score, recent})
	}
	slice.stable_sort_by(found[:], proc(a, b: Match) -> bool {
		if a.score != b.score {
			return a.score > b.score
		}
		return a.recent < b.recent
	})
	out := make([]int, len(found), context.temp_allocator)
	for m, i in found {
		out[i] = m.index
	}
	return out
}

// palette_score says whether `query`'s letters come in `name` in that order
// (ignoring case and the query's spaces), and how well: a point for each,
// more for one that starts a word or follows the one before. The letters are
// taken where they come first.
palette_score :: proc(query, name: string) -> (score: int, ok: bool) {
	q := 0
	last := -2
	for i in 0 ..< len(name) {
		for q < len(query) && query[q] == ' ' {
			q += 1
		}
		if q == len(query) {
			break
		}
		if lower_ascii(name[i]) != lower_ascii(query[q]) {
			continue
		}
		score += 1
		if i == 0 || name[i - 1] == ' ' || name[i - 1] == '(' {
			score += 8
		}
		if last == i - 1 {
			score += 4
		}
		last = i
		q += 1
	}
	for q < len(query) && query[q] == ' ' {
		q += 1
	}
	return score, q == len(query)
}

@(private = "file")
lower_ascii :: proc(c: u8) -> u8 {
	return c + 32 if c >= 'A' && c <= 'Z' else c
}

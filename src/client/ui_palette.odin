package client

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"
import mu "vendor:microui"

import "client:conn"
import "client:settings"
import "common:proto"

// The command palette (docs/design/keyboard.md): Ctrl+Space or Ctrl+K (Cmd+K
// on macOS) opens a box near the top of the window that lists what can be
// done right now, best match for what is typed first. Up and Down pick,
// Enter runs, Escape (or a click elsewhere) closes it. Tab moves among its
// rows like in any popup.
//
// Besides the commands, it lists the shown server's channels (to go to, and
// to join the voice room of), the people there to write to, and the other
// servers to switch to.
//
// Matching is by subsequence: the typed letters must come in the entry's
// name in that order, not next to each other. Letters at the start of a word
// (or after # or @) and letters in a row count for more. Among equal matches,
// the entries run last come first.

UI_Palette :: struct {
	open:      bool,
	focus_box: bool, // just opened: the query box takes the focus
	query:     Text_Field(128),
	selected:  int, // among the matches
	// The text box that had the focus when it opened, and its cursor, to
	// get them back when it closes.
	back:      mu.Id,
	back_sel:  [2]int,
	// The names of the entries run last, newest first, at most
	// PALETTE_RECENT. Owned.
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
	{name = "Leave voice", enabled = proc(ui: ^UI, v: ^conn.View) -> bool {
			return palette_connected(ui, v) && panel_state(v) == .Voice
		}, run = proc(ui: ^UI) {command(ui, conn.Voice_Command{})}},
	{name = "Hang up", enabled = proc(ui: ^UI, v: ^conn.View) -> bool {
			return palette_connected(ui, v) && panel_state(v) == .Call
		}, run = proc(ui: ^UI) {command(ui, conn.Call_Hangup_Command{})}},
	{name = "Search messages", enabled = proc(ui: ^UI, v: ^conn.View) -> bool {
			return palette_connected(ui, v) && !ui.search.open
		}, run = proc(ui: ^UI) {
			ui.search.open = true
			ui.search.placed = false
		}},
	{name = "Open the inbox", enabled = proc(ui: ^UI, v: ^conn.View) -> bool {
			return ui.page != .Buddies && ui.session != nil && !ui.session.joining && !ui.join.open
		}, run = proc(ui: ^UI) {toggle_inbox(ui)}},
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
		enabled = proc(ui: ^UI, v: ^conn.View) -> bool {return(
				theme_choice(&ui.settings) !=
				.Dark \
			)},
		run = proc(ui: ^UI) {palette_set_theme(ui, .Dark)},
	},
	{
		name = "Use the light theme",
		enabled = proc(ui: ^UI, v: ^conn.View) -> bool {return(
				theme_choice(&ui.settings) !=
				.Light \
			)},
		run = proc(ui: ^UI) {palette_set_theme(ui, .Light)},
	},
	{
		name = "Use the system's theme",
		enabled = proc(ui: ^UI, v: ^conn.View) -> bool {return(
				theme_choice(&ui.settings) !=
				.System \
			)},
		run = proc(ui: ^UI) {palette_set_theme(ui, .System)},
	},
}

ui_palette_destroy :: proc(ui: ^UI) {
	for name in ui.palette.recent {
		delete(name)
	}
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

// Palette_Entry is a row the palette may show: a command from COMMANDS, or
// one made for what is there now (a channel, a server, someone to write to).
Palette_Entry :: struct {
	kind:    Palette_Kind,
	name:    string, // a COMMANDS name, or in the temp allocator
	detail:  string, // dimmed at the right end of its row; in the temp allocator
	command: int, // .Command: which, in COMMANDS
	conv:    proto.Conv_Id, // .Channel, .Voice: the channel; .Message: a group; on the shown server
	account: proto.Account_Id, // .Message: whom, on the shown server (0 for a group)
	ns:      ^Net_Session, // .Server
}

Palette_Kind :: enum {
	Command,
	Channel, // show the channel
	Voice, // join its voice room
	Server, // show the server
	Message, // open the DM or the group
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
	entries := palette_entries(ui, v)
	matches := palette_matches(ui, entries, field_text(&p.query))

	// As tall as its rows, as microui lays them out.
	row := ctx.style.size.y + 2 * ctx.style.padding + ctx.style.spacing
	rows := i32(1 + max(min(len(matches), PALETTE_ROWS), 1))
	pw := min(PALETTE_WIDTH, w - 32)
	if cnt := mu.get_container(ctx, PALETTE_WINDOW); cnt != nil {
		cnt.rect = {
			(w - pw) / 2,
			min(80, h / 6),
			pw,
			rows * row - ctx.style.spacing + 2 * ctx.style.padding,
		}
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
		matches = palette_matches(ui, entries, field_text(&p.query))
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
		e := &entries[matches[i]]
		mu.layout_row(ctx, {-1})
		if .SUBMIT in list_row(ctx, fmt.tprintf("row %d", i), e.name, i == p.selected) {
			run = i
		}
		if e.detail != "" {
			r := ctx.last_rect
			tw := ctx.text_width(ctx.style.font, e.detail)
			x := r.x + r.w - tw - ctx.style.padding
			y := r.y + (r.h - ctx.text_height(ctx.style.font)) / 2
			mu.draw_text(ctx, ctx.style.font, e.detail, {x, y}, theme.dim)
		}
	}

	if run >= 0 {
		e := entries[matches[run]]
		palette_close(ui)
		palette_remember(p, e.name)
		palette_run(ui, v, e)
		ui_redraw(ui)
	}
}

// palette_entries lists what the palette may show now, commands first.
// Allocated in the temp allocator. Call with the View locked.
@(private = "file")
palette_entries :: proc(ui: ^UI, v: ^conn.View) -> []Palette_Entry {
	list := make(
		[dynamic]Palette_Entry,
		0,
		len(COMMANDS) + 2 * len(v.channels),
		context.temp_allocator,
	)
	for c, i in COMMANDS {
		if c.enabled != nil && !c.enabled(ui, v) {
			continue
		}
		detail := c.detail(ui) if c.detail != nil else ""
		append(&list, Palette_Entry{kind = .Command, name = c.name, detail = detail, command = i})
	}
	if palette_connected(ui, v) {
		for ch in v.channels {
			if ch.id == v.viewing && ui.page == .Main {
				continue // already there
			}
			detail := fmt.tprintf("%d unread", ch.unread) if ch.unread > 0 else ""
			append(
				&list,
				Palette_Entry {
					kind = .Channel,
					name = fmt.tprintf("Go to #%s", ch.name),
					detail = detail,
					conv = ch.id,
				},
			)
		}
		if !v.voice_pending {
			for ch in v.channels {
				if .Voice in ch.rights && ch.id != v.my_room {
					append(
						&list,
						Palette_Entry {
							kind = .Voice,
							name = fmt.tprintf("Join voice in #%s", ch.name),
							conv = ch.id,
						},
					)
				}
			}
		}
		for b in buddy_list(&ui.settings, v) {
			detail := ""
			switch {
			case b.unread > 0:
				detail = fmt.tprintf("%d unread", b.unread)
			case b.self:
			case b.online:
				detail = "online"
			}
			append(
				&list,
				Palette_Entry {
					kind = .Message,
					name = fmt.tprintf("Message %s", b.name),
					detail = detail,
					account = b.account,
					conv = b.conv if b.group else 0,
				},
			)
		}
	}
	for ns in ui.sessions {
		// The shown server's View is locked already.
		if ns.joining || ns == ui.session || &ns.view == v {
			continue
		}
		name := ns.server
		{
			sv := &ns.view
			sync.guard(&sv.mutex)
			if sv.server_name != "" {
				name = fmt.tprintf("%s", sv.server_name)
			}
		}
		append(
			&list,
			Palette_Entry{kind = .Server, name = fmt.tprintf("Switch to %s", name), ns = ns},
		)
	}
	return list[:]
}

// palette_run does what the entry `e` stands for. Call with the View locked.
@(private = "file")
palette_run :: proc(ui: ^UI, v: ^conn.View, e: Palette_Entry) {
	switch e.kind {
	case .Command:
		COMMANDS[e.command].run(ui)
	case .Channel, .Voice:
		for ch in v.channels {
			if ch.id != e.conv {
				continue
			}
			if e.kind == .Channel {
				ui.page = .Main
				view_channel(ui, v, ch)
			} else {
				join_voice(ui, ch)
			}
			return
		}
	case .Message:
		if e.account == 0 && e.conv != 0 {
			open_group(ui, e.conv)
		} else {
			open_conversation(ui, e.account)
		}
	case .Server:
		if on_rail(ui, e.ns) {
			ui.switch_to, ui.switching = e.ns, true
		}
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

// palette_remember puts `name` first among the entries run last.
palette_remember :: proc(p: ^UI_Palette, name: string) {
	if i, found := slice.linear_search(p.recent[:], name); found {
		delete(p.recent[i])
		ordered_remove(&p.recent, i)
	}
	inject_at(&p.recent, 0, strings.clone(name))
	for len(p.recent) > PALETTE_RECENT {
		delete(pop(&p.recent))
	}
}

// palette_matches lists the entries that match `query`, as indexes into
// `entries`, best first, and among equally good ones those run last first.
// Allocated in the temp allocator.
palette_matches :: proc(ui: ^UI, entries: []Palette_Entry, query: string) -> []int {
	Match :: struct {
		index:  int,
		score:  int,
		recent: int, // where among the recent ones; len(recent) if not
	}
	found := make([dynamic]Match, 0, len(entries), context.temp_allocator)
	for e, i in entries {
		score, ok := palette_score(query, e.name)
		if !ok {
			continue
		}
		recent := len(ui.palette.recent)
		if at, was := slice.linear_search(ui.palette.recent[:], e.name); was {
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
// (ignoring case and the query's spaces), and how well, where they fit best:
// a point for each letter, more for one that starts a word or follows the one
// before, less for the letters skipped between two of them.
palette_score :: proc(query, name: string) -> (score: int, ok: bool) {
	NONE :: min(int) / 2 // the query's letters so far don't fit up to here
	q := make([dynamic]u8, 0, len(query), context.temp_allocator)
	for c in transmute([]u8)query {
		if c != ' ' {
			append(&q, lower_ascii(c))
		}
	}
	if len(q) == 0 {
		return 0, true
	}
	n := len(name)
	// best[j]: the best score for the letters so far with the last one at
	// name[j]. One row per letter of the query.
	best := make([]int, n, context.temp_allocator)
	next := make([]int, n, context.temp_allocator)
	for c, i in q {
		before := NONE // the best of best[k] for k < j - 1, less its gap
		for j in 0 ..< n {
			if j >= 2 && i > 0 {
				// Every letter skipped costs a point.
				if before != NONE {
					before -= 1
				}
				if best[j - 2] != NONE {
					before = max(before, best[j - 2] - 1)
				}
			}
			next[j] = NONE
			if lower_ascii(name[j]) != c {
				continue
			}
			points := 1
			if j == 0 || strings.index_byte(" (#@", name[j - 1]) >= 0 {
				points += 8
			}
			switch {
			case i == 0:
				next[j] = points
			case j >= 1 && best[j - 1] != NONE:
				next[j] = max(
					best[j - 1] + points + 4,
					before + points if before != NONE else NONE,
				)
			case before != NONE:
				next[j] = before + points
			}
		}
		best, next = next, best
	}
	score = NONE
	for s in best {
		score = max(score, s)
	}
	return score, score != NONE
}

@(private = "file")
lower_ascii :: proc(c: u8) -> u8 {
	return c + 32 if c >= 'A' && c <= 'Z' else c
}

package client

import log "common:wlog"
import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import "core:time/datetime"
import mu "vendor:microui"

import "client:conn"
import "client:idle"
import "client:platform"
import "client:render"
import "client:settings"
import "common:proto"

/*
Profiles on screen: our status and picture, everyone else's in the lists,
a conversation's members, and the settings our account keeps on the
server.

  - The status editor, a small window: the text, and when it clears
    itself (30 minutes, an hour, four hours, the end of today, never).
    It's opened from our own row in a list, or from the settings.
  - The members window, opened by the people button in a conversation's
    header: everyone in it with their picture and status, those here
    first, the rest with when they were last here. Clicking one opens
    the same menu as anywhere else; clicking ourselves, the status
    editor.
  - Our picture is set in the settings, from a file or (on a desktop)
    the clipboard (ui_avatar_pick_native.odin, ui_avatar_pick_web.odin):
    made square and small (avatar_prepare, web/avatar.js) and uploaded.
  - Settings kept on the server (conn/profiles.odin): how loud each
    person is, and which DMs are off the buddy list. settings.json keeps
    a copy for each server, so they apply before the sync; what the
    server says wins, and what only this device has (changed while
    away, or from before there was a server copy) goes up after the
    sync. One removed on the server afterwards is removed here too.
*/

UI_Profiles :: struct {
	// The status editor.
	editing:        bool,
	edit_placed:    bool,
	buf:            [proto.MAX_STATUS_SIZE]u8,
	len:            int,
	clear_after:    Clear_After,
	days_buf:       [3]u8, // Clear_After.Days: how many
	days_len:       int,
	// The members window, and the conversation it last asked about.
	members_open:   bool,
	members_placed: bool,
	members_asked:  proto.Conv_Id,
	members_seen:   int, // View_Members.count when last seen to (last seen asked)
	// The server's settings as last applied: View.shared_count, and the
	// sync they came with (View.shared_syncs).
	shared_seen:    int,
	syncs_seen:     int,
	// The keys the server had then: one of ours that's gone from it was
	// removed (from another device); one it never had is ours to send.
	shared_known:   map[string]bool,
	// Choosing a picture (ui_avatar_pick_*.odin).
	pick:           ^Avatar_Pick,
	pick_notice:    string, // static
}

Clear_After :: enum {
	Never,
	Half_Hour,
	Hour,
	Four_Hours,
	Today,
	Days, // so many days from now (UI_Profiles.days_buf)
}

@(private = "file")
CLEAR_AFTER_LABELS := [Clear_After]string {
	.Never      = "Never",
	.Half_Hour  = "30 min",
	.Hour       = "1 hour",
	.Four_Hours = "4 hours",
	.Today      = "Today",
	.Days       = "Days",
}

// The most days a status can be set to last from the dialog.
@(private = "file")
MAX_STATUS_DAYS :: 365
@(private = "file")
STATUS_WINDOW_W :: 440

@(private = "file")
STATUS_WINDOW :: "Status"
@(private = "file")
MEMBERS_WINDOW :: "Members"

ui_profiles_destroy :: proc(ui: ^UI) {
	known_clear(&ui.profiles)
	delete(ui.profiles.shared_known)
	ui.profiles.shared_known = nil
}

@(private = "file")
known_clear :: proc(p: ^UI_Profiles) {
	for k in p.shared_known {
		delete(k)
	}
	clear(&p.shared_known)
}

// open_status_editor opens the editor with our status as it is.
open_status_editor :: proc(ui: ^UI) {
	p := &ui.profiles
	v := ui.view
	me := v.accounts[v.me] or_else {}
	p.len = copy(p.buf[:], me.status)
	p.clear_after = .Never
	p.days_len = copy(p.days_buf[:], "1")
	p.editing, p.edit_placed = true, false
}

/*
profile_windows draws the status editor and the members window while
they're open, and applies the server's settings when they've changed.
*/
profile_windows :: proc(ui: ^UI, window_w, window_h: i32) {
	v := ui.view
	sync.guard(&v.mutex)
	if ui.session == nil || v.status != .Connected || v.login.state != .Done {
		ui.profiles.editing, ui.profiles.members_open = false, false
		return
	}
	shared_apply(ui)
	status_editor(ui, window_w, window_h)
	members_window(ui, window_w, window_h)
}

@(private = "file")
status_editor :: proc(ui: ^UI, window_w, window_h: i32) {
	p := &ui.profiles
	if !p.editing {
		return
	}
	ctx := &ui.ctx
	if !p.edit_placed {
		p.edit_placed = true
		w, h: i32 = STATUS_WINDOW_W, 192
		if idle.can_ask() {
			h += 28
		}
		if cnt := mu.get_container(ctx, STATUS_WINDOW); cnt != nil {
			cnt.rect = {(window_w - w) / 2, max((window_h - h) / 3, 0), w, h}
			cnt.open = true
			mu.bring_to_front(ctx, cnt)
			ctx.hover_root, ctx.next_hover_root = cnt, cnt
		}
		ui.focus_composer = false
	}
	if !mu.begin_window(ctx, STATUS_WINDOW, {}, {.NO_RESIZE}) {
		p.editing = false
		return
	}
	defer mu.end_window(ctx)

	// Online, away, busy or invisible: taken at once, apart from the
	// status (ui_activity.odin).
	choice_w := (STATUS_WINDOW_W - 2 * ctx.style.padding - 3 * ctx.style.spacing - 8) / 4
	mu.layout_row(ctx, {choice_w, choice_w, choice_w, choice_w})
	for a in proto.Activity {
		saved, saved_text := ctx.style.colors[.BUTTON], ctx.style.colors[.TEXT]
		if ui.view.my_activity == a {
			ctx.style.colors[.BUTTON] = ctx.style.colors[.BUTTON_FOCUS]
		}
		// The dot's colour, but for grey, which wouldn't read on a button.
		if a != .Offline {
			ctx.style.colors[.TEXT] = ACTIVITY_COLORS[a]
		}
		if .SUBMIT in
			   stable_button_hint(
				   ui,
				   fmt.tprint(a),
				   ACTIVITY_LABELS[a],
				   ACTIVITY_HINTS[a],
				   {.ALIGN_CENTER},
			   ) &&
		   ui.view.my_activity != a {
			conn.push_command(&ui.session.client.commands, conn.Activity_Command{activity = a})
		}
		ctx.style.colors[.BUTTON], ctx.style.colors[.TEXT] = saved, saved_text
	}
	// A page only sees its own input unless the browser lets it ask
	// about the rest (client:idle), which takes a click to ask for.
	if idle.can_ask() {
		mu.layout_row(ctx, {-1})
		if .SUBMIT in
		   stable_button_hint(
			   ui,
			   "idle-ask",
			   "Away when not at this computer",
			   "Let the browser say when there's no input anywhere on this computer, not only on this page",
			   {.ALIGN_CENTER},
		   ) {
			idle.ask()
		}
	}

	mu.layout_row(ctx, {-1})
	res := text_box(ui, p.buf[:], &p.len)
	mu.layout_row(ctx, {-1})
	with_text_color(ctx, DIM_COLOR, "Clear it after:", label_proc)
	widths: [len(Clear_After)]i32
	for &w in widths {
		w =
			(STATUS_WINDOW_W -
				2 * ctx.style.padding -
				(len(Clear_After) - 1) * ctx.style.spacing -
				8) /
			len(Clear_After)
	}
	mu.layout_row(ctx, widths[:])
	for c in Clear_After {
		saved := ctx.style.colors[.BUTTON]
		if p.clear_after == c {
			ctx.style.colors[.BUTTON] = ctx.style.colors[.BUTTON_FOCUS]
		}
		if .SUBMIT in stable_button(ctx, fmt.tprint(c), CLEAR_AFTER_LABELS[c], {.ALIGN_CENTER}) {
			p.clear_after = c
		}
		ctx.style.colors[.BUTTON] = saved
	}
	// How many days, and when that is, which is said for every choice
	// but Never.
	until := status_until(ui, p.clear_after, status_days(p))
	if p.clear_after == .Days {
		mu.layout_row(ctx, {60, 50, -1})
		mu.label(ctx, "Days")
		text_box(ui, p.days_buf[:], &p.days_len)
	} else {
		mu.layout_row(ctx, {-1})
	}
	when_text := "It stays until you change it."
	if p.clear_after == .Days && status_days(p) == 0 {
		when_text = fmt.tprintf("A number of days, 1 to %d.", MAX_STATUS_DAYS)
	} else if until != 0 {
		when_text = fmt.tprintf("It clears %s.", until_text(ui, until))
	}
	with_text_color(ctx, DIM_COLOR, when_text, label_proc)
	mu.layout_row(ctx, {120, -1})
	cleared := .SUBMIT in stable_button(ctx, "status clear", "Clear status", {.ALIGN_CENTER})
	saved :=
		.SUBMIT in stable_button(ctx, "status save", "Save", {.ALIGN_CENTER}) || .SUBMIT in res
	if p.clear_after == .Days && status_days(p) == 0 {
		saved = false
	}
	switch {
	case cleared:
		conn.push_command(&ui.session.client.commands, conn.Status_Command{})
		p.editing = false
	case saved:
		text := strings.trim_space(string(p.buf[:p.len]))
		conn.push_command(
			&ui.session.client.commands,
			conn.Status_Command{text = strings.clone(text), until = until},
		)
		log.debug("ui: set a status")
		p.editing = false
	}
	if !p.editing {
		mu.get_current_container(ctx).open = false
	}
}

// status_days is how many days the dialog's box says, 0 if it isn't a
// number of them it takes.
@(private = "file")
status_days :: proc(p: ^UI_Profiles) -> int {
	days, ok := strconv.parse_int(strings.trim_space(string(p.days_buf[:p.days_len])), 10)
	return days if ok && days >= 1 && days <= MAX_STATUS_DAYS else 0
}

// until_text says when a time is, in local time: "at 14:30" today,
// "on Sunday, 2026-10-04 at 14:30" another day.
@(private = "file")
until_text :: proc(ui: ^UI, at: proto.Unix_Ms) -> string {
	dt, _ := time.time_to_datetime(time.unix(i64(at) / 1000, 0))
	local := chat_local_time(ui, dt)
	now, _ := time.time_to_datetime(time.now())
	today := chat_local_time(ui, now)
	clock := fmt.tprintf("%02d:%02d", local.hour, local.minute)
	if local.date == today.date {
		return fmt.tprintf("today at %s", clock)
	}
	ordinal, _ := datetime.date_to_ordinal(local.date)
	return fmt.tprintf(
		"on %v, %d-%02d-%02d at %s",
		datetime.day_of_week(ordinal),
		local.year,
		local.month,
		local.day,
		clock,
	)
}

// status_until is when a status set now clears itself; 0 for never.
@(private = "file")
status_until :: proc(ui: ^UI, c: Clear_After, days: int) -> proto.Unix_Ms {
	now := time.now()
	now_ms := proto.Unix_Ms(time.time_to_unix_nano(now) / 1e6)
	switch c {
	case .Never:
		return 0
	case .Half_Hour:
		return now_ms + 30 * 60 * 1000
	case .Hour:
		return now_ms + 60 * 60 * 1000
	case .Four_Hours:
		return now_ms + 4 * 60 * 60 * 1000
	case .Today:
		dt, _ := time.time_to_datetime(now)
		local := chat_local_time(ui, dt)
		into := i64(local.hour) * 3600 + i64(local.minute) * 60 + i64(local.second)
		return now_ms + proto.Unix_Ms((86400 - into) * 1000)
	case .Days:
		if days == 0 {
			return 0
		}
		return now_ms + proto.Unix_Ms(i64(days) * 24 * 60 * 60 * 1000)
	}
	return 0
}

// members_button is the header's button for the members window.
members_button :: proc(ui: ^UI) {
	p := &ui.profiles
	if .SUBMIT in
	   icon_button(
		   ui,
		   "members",
		   .Buddies,
		   "Hide the members" if p.members_open else "Members",
		   CHAT_NAME_COLOR if p.members_open else {},
	   ) {
		p.members_open = !p.members_open
		p.members_placed = false
		p.members_asked = 0
	}
}

/*
members_window lists the members of the conversation looked at: those
here first, then the rest, each by name.
*/
@(private = "file")
members_window :: proc(ui: ^UI, window_w, window_h: i32) {
	p := &ui.profiles
	if !p.members_open {
		return
	}
	ctx := &ui.ctx
	v := ui.view
	if v.viewing == 0 {
		p.members_open = false
		return
	}
	if ui.page == .Settings {
		return
	}
	cmds := &ui.session.client.commands
	if p.members_asked != v.viewing {
		p.members_asked = v.viewing
		conn.push_command(cmds, conn.Members_Command{conv = v.viewing})
	}
	if !p.members_placed {
		p.members_placed = true
		w := clamp(window_w / 4, 240, 340)
		h := clamp(window_h - 120, 200, 600)
		if cnt := mu.get_container(ctx, MEMBERS_WINDOW); cnt != nil {
			cnt.rect = {window_w - w - 20, 60, w, h}
			cnt.open = true
			cnt.scroll = {}
			mu.bring_to_front(ctx, cnt)
			ctx.hover_root, ctx.next_hover_root = cnt, cnt
		}
	}
	if !mu.begin_window(ctx, MEMBERS_WINDOW, {}) {
		p.members_open = false
		return
	}
	defer mu.end_window(ctx)

	m := &v.members
	if m.conv != v.viewing || (m.loading && len(m.accounts) == 0) {
		mu.layout_row(ctx, {-1})
		with_text_color(ctx, CHAT_DIM_COLOR, "Loading...", label_proc)
		return
	}
	Member :: struct {
		account: proto.Account_Id,
		name:    string,
		online:  bool,
	}
	list := make([dynamic]Member, 0, len(m.accounts), context.temp_allocator)
	for a in m.accounts {
		e := buddy_entry(v, a, false)
		append(&list, Member{a, e.name, e.online || a == v.me})
	}
	slice.sort_by(list[:], proc(a, b: Member) -> bool {
		if a.online != b.online {
			return a.online
		}
		an := strings.to_lower(a.name, context.temp_allocator)
		bn := strings.to_lower(b.name, context.temp_allocator)
		return an < bn if an != bn else a.account < b.account
	})
	// When those who aren't here were last, once per list.
	if p.members_seen != m.count {
		p.members_seen = m.count
		cmd: conn.Last_Seen_Command
		for e in list {
			if !e.online && cmd.count < len(cmd.accounts) {
				cmd.accounts[cmd.count] = e.account
				cmd.count += 1
			}
		}
		if cmd.count > 0 {
			conn.push_command(cmds, cmd)
		}
	}

	here := 0
	for e in list {
		if e.online {
			here += 1
		}
	}
	mu.layout_row(ctx, {-1})
	with_text_color(
		ctx,
		DIM_COLOR,
		fmt.tprintf("%d members, %d here", len(list), here),
		label_proc,
	)
	add_people(ui, m.accounts[:])
	for e in list {
		extra := "" if e.online else last_seen_text(ui, e.account)
		if person_row(ui, e.account, e.name, e.online, extra) {
			if e.account == v.me {
				open_status_editor(ui)
			} else {
				open_user_menu(ui, 0, e.account)
			}
		}
	}
}

/*
person_row is a person in a list: their picture, their name (dimmed if
they aren't here), and dimmed after it their status and `extra`. A flat
control the width of the list; true when it's clicked.
*/
person_row :: proc(
	ui: ^UI,
	account: proto.Account_Id,
	name: string,
	online: bool,
	extra := "",
) -> bool {
	ctx := &ui.ctx
	v := ui.view
	if acc, known := ui.view.accounts[account]; !known || .Deleted in acc.flags {
		return false // Deleted accounts aren't in lists.
	}

	size := ctx.text_height(ctx.style.font) + 4
	mu.layout_row(ctx, {size + 4, -1})
	cell := mu.layout_next(ctx)
	avatar(ui, account, {cell.x, cell.y + (cell.h - size) / 2, size, size})

	mu.push_id(ctx, uintptr(account))
	defer mu.pop_id(ctx)
	id := mu.get_id(ctx, "person")
	r := mu.layout_next(ctx)
	mu.update_control(ctx, id, r)
	if ctx.hover_id == id {
		mu.draw_rect(ctx, r, ctx.style.colors[.BUTTON_HOVER])
	}
	acc := v.accounts[account] or_else {}
	// In the colour of their roles, if they have one; fainter when they
	// aren't here.
	color := ctx.style.colors[.TEXT] if online else DIM_COLOR
	if c, ok := name_color(v, account); ok {
		color = c if online else {c.r, c.g, c.b, 140}
	}
	name_and_status(ctx, r, name, color, status_line(acc), extra)
	return ctx.hover_id == id && ctx.mouse_pressed_bits & {.LEFT, .RIGHT} != {}
}

/*
name_and_status draws a name in `r`, and dimmed after it a status and
whatever else there is to say, cut where the row ends.
*/
name_and_status :: proc(
	ctx: ^mu.Context,
	r: mu.Rect,
	name: string,
	color: mu.Color,
	status: string,
	extra := "",
) {
	font := ctx.style.font
	y := r.y + (r.h - ctx.text_height(font)) / 2
	x := r.x + ctx.style.padding
	mu.push_clip_rect(ctx, r)
	defer mu.pop_clip_rect(ctx)
	mu.draw_text(ctx, font, name, {x, y}, color)
	x += ctx.text_width(font, name) + 10
	more := status
	if extra != "" {
		more = extra if more == "" else fmt.tprintf("%s  ·  %s", more, extra)
	}
	if more != "" {
		mu.draw_text(ctx, font, more, {x, y}, DIM_COLOR)
	}
}

/*
The account's own section of the settings: our picture and our status.
Call with the View locked, inside the Account section.
*/
profile_settings :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := ui.view
	p := &ui.profiles
	me := v.accounts[v.me] or_else {}

	size: i32 = 48
	mu.layout_row(ctx, {FORM_LABEL, size + 8, -1}, size)
	mu.label(ctx, "Picture")
	cell := mu.layout_next(ctx)
	avatar(ui, v.me, {cell.x, cell.y, size, size})
	// The buttons, of the usual height, in the middle of the row.
	mu.layout_begin_column(ctx)
	defer mu.layout_end_column(ctx)
	mu.layout_row(
		ctx,
		{-1},
		max((size - ctx.style.size.y - 2 * ctx.style.padding) / 2 - ctx.style.spacing, 1),
	)
	mu.layout_next(ctx)
	mu.layout_row(ctx, {110, 110, 110})
	uploading := false
	for o in v.outbox {
		uploading ||= o.avatar
	}
	if .SUBMIT in stable_button(ctx, "avatar file", "Choose...", {.ALIGN_CENTER}) {
		avatar_pick_start(ui, false)
	}
	// A page can only read the clipboard inside a paste event.
	when !platform.WEB {
		if .SUBMIT in stable_button(ctx, "avatar paste", "Paste", {.ALIGN_CENTER}) {
			avatar_pick_start(ui, true)
		}
	}
	switch {
	case uploading:
		with_text_color(ctx, DIM_COLOR, "uploading...", label_proc)
	case p.pick != nil:
		with_text_color(ctx, DIM_COLOR, "reading the picture...", label_proc)
	case p.pick_notice != "":
		with_text_color(ctx, OFF_COLOR, p.pick_notice, label_proc)
	case me.avatar != 0:
		if .SUBMIT in stable_button(ctx, "avatar remove", "Remove", {.ALIGN_CENTER}) {
			conn.push_command(&ui.session.client.commands, conn.Avatar_Command{remove = true})
		}
	case:
		mu.label(ctx, "")
	}
}

// status_settings is the settings' line for our status. Call with the
// View locked, inside the Account section.
status_settings :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := ui.view
	me := v.accounts[v.me] or_else {}
	mu.layout_row(ctx, {FORM_LABEL, 140, -1})
	mu.label(ctx, "Status")
	if .SUBMIT in stable_button(ctx, "status edit", "Set status...", {.ALIGN_CENTER}) {
		open_status_editor(ui)
	}
	text := me.status if me.status != "" else "none"
	if me.status != "" && me.status_until != 0 {
		text = fmt.tprintf(
			"%s  (until %s)",
			me.status,
			chat_time(ui, proto.Unix_Time(me.status_until / 1000)),
		)
	}
	with_text_color(ctx, DIM_COLOR, text, label_proc)
}

/*
Settings on the server. Each is kept as text:

	user/<account>        volume=<0..3>,muted=<0|1>  (settings.User_Settings)
	dm/hidden/<conv>      <message id>              (settings.hide_dm)
*/

@(private = "file")
user_key :: proc(account: proto.Account_Id) -> string {
	return fmt.tprintf("user/%d", account)
}

@(private = "file")
hidden_key :: proc(conv: proto.Conv_Id) -> string {
	return fmt.tprintf("dm/hidden/%d", conv)
}

@(private = "file")
user_value :: proc(u: settings.User_Settings) -> string {
	if u == settings.DEFAULT_USER {
		return ""
	}
	return fmt.tprintf("volume=%.2f,muted=%d", u.volume, 1 if u.muted else 0)
}

@(private = "file")
parse_user_value :: proc(s: string) -> (u: settings.User_Settings, ok: bool) {
	u = settings.DEFAULT_USER
	rest := s
	for part in strings.split_iterator(&rest, ",") {
		name, _, value := strings.partition(part, "=")
		switch name {
		case "volume":
			u.volume = f32(strconv.parse_f64(value) or_return)
		case "muted":
			u.muted = value == "1"
		}
	}
	u.volume = clamp(u.volume, 0, settings.MAX_USER_VOLUME)
	return u, true
}

// shared_user_changed tells the server how we play somebody now.
shared_user_changed :: proc(ui: ^UI, account: proto.Account_Id, u: settings.User_Settings) {
	if ui.session != nil {
		conn.push_command(
			&ui.session.client.commands,
			conn.Setting_Command {
				key = strings.clone(user_key(account)),
				value = strings.clone(user_value(u)),
			},
		)
	}
}

// shared_hidden_changed tells the server a DM is off the buddy list up
// to `last` (0: back on it).
shared_hidden_changed :: proc(ui: ^UI, conv: proto.Conv_Id, last: proto.Msg_Id) {
	if ui.session != nil {
		value := fmt.tprint(u64(last)) if last != 0 else ""
		conn.push_command(
			&ui.session.client.commands,
			conn.Setting_Command {
				key = strings.clone(hidden_key(conv)),
				value = strings.clone(value),
			},
		)
	}
}

/*
shared_apply brings settings.json's copy for this server in line with the
server's, when that has changed. Call with the View locked.
*/
@(private = "file")
shared_apply :: proc(ui: ^UI) {
	v := ui.view
	p := &ui.profiles
	if !v.shared_synced || v.shared_count == p.shared_seen || v.server_key == {} {
		return
	}
	p.shared_seen = v.shared_count
	first := v.shared_syncs != p.syncs_seen
	p.syncs_seen = v.shared_syncs
	known := make(map[string]bool, context.temp_allocator)
	for k, value in p.shared_known {
		known[strings.clone(k, context.temp_allocator)] = value
	}
	known_clear(p)
	for k in v.shared {
		p.shared_known[strings.clone(k)] = true
	}
	server := v.server_key
	s := &ui.settings
	cmds := &ui.session.client.commands

	// What the server has.
	for key, value in v.shared {
		switch {
		case strings.has_prefix(key, "user/"):
			id, id_ok := strconv.parse_u64(key[len("user/"):])
			u, ok := parse_user_value(value)
			if !id_ok || !ok {
				continue
			}
			account := proto.Account_Id(id)
			if settings.user_settings(s, server, account) != u {
				settings.set_user_settings(s, server, account, u)
				conn.push_command(cmds, conn.Gain_Command{account, settings.user_gain(u)})
				ui.settings_dirty = true
			}
		case strings.has_prefix(key, "dm/hidden/"):
			id, id_ok := strconv.parse_u64(key[len("dm/hidden/"):])
			last, ok := strconv.parse_u64(value)
			if !id_ok || !ok {
				continue
			}
			if (s.hidden_dms[settings.server_key(server, id)] or_else 0) != last {
				settings.hide_dm(s, server, proto.Conv_Id(id), proto.Msg_Id(last))
				ui.settings_dirty = true
			}
		}
	}

	// What only we have: up it goes after a sync, else it was removed.
	users := make([dynamic]proto.Account_Id, context.temp_allocator)
	for k in s.users {
		if srv, id, ok := settings.parse_server_key(k); ok && srv == server {
			append(&users, proto.Account_Id(id))
		}
	}
	for account in users {
		if user_key(account) in v.shared || (!first && user_key(account) not_in known) {
			continue
		}
		u := settings.user_settings(s, server, account)
		if first {
			conn.push_command(
				cmds,
				conn.Setting_Command {
					key = strings.clone(user_key(account)),
					value = strings.clone(user_value(u)),
				},
			)
		} else {
			settings.set_user_settings(s, server, account, settings.DEFAULT_USER)
			conn.push_command(
				cmds,
				conn.Gain_Command{account, settings.user_gain(settings.DEFAULT_USER)},
			)
			ui.settings_dirty = true
		}
	}
	hidden := make([dynamic][2]u64, context.temp_allocator)
	for k, last in s.hidden_dms {
		if srv, id, ok := settings.parse_server_key(k); ok && srv == server {
			append(&hidden, [2]u64{id, last})
		}
	}
	for h in hidden {
		if hidden_key(proto.Conv_Id(h[0])) in v.shared ||
		   (!first && hidden_key(proto.Conv_Id(h[0])) not_in known) {
			continue
		}
		if first {
			conn.push_command(
				cmds,
				conn.Setting_Command {
					key = strings.clone(hidden_key(proto.Conv_Id(h[0]))),
					value = strings.clone(fmt.tprint(h[1])),
				},
			)
		} else {
			settings.hide_dm(s, server, proto.Conv_Id(h[0]), 0)
			ui.settings_dirty = true
		}
	}
}

_ :: render

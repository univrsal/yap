package client

import "client:conn"
import "client:render"
import "client:settings"
import glfw "client:wglfw"
import "common:proto"
import log "common:wlog"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import "core:unicode"
import "core:unicode/utf8"
import mu "vendor:microui"

/*
Many servers at once (docs/next, item 9): every server joined is
connected, each its own Net_Session with its own View and network loop,
and one of them is shown. UI.session is that one, UI.view its View.

What the UI keeps of a server - the channel list, the timeline and its
scroll, open threads, drafts, the forms of the login and the settings,
search, calls... - is a Server_UI. The UI has the shown server's
embedded (`using srv`, so it reads ui.channels as ever); every other
session keeps its own in Net_Session.stash, and switching swaps them,
so a server comes back as it was left.

What isn't one server's stays on the UI: the window, the settings,
audio devices' list, mute and deafen, the chat pictures' decoder (whose
textures are dropped on switching, as they're known by the server's
blob ids), and the log.
*/

Server_UI :: struct {
	// Room for more than MAX_NAME_SIZE while typing; sanitize_name trims it.
	// What our account is called, as it's being edited in the settings.
	name_buf:       [2 * proto.MAX_NAME_SIZE]u8,
	name_len:       int,
	account:        UI_Account, // logging in, and the account's settings (ui_account.odin)
	invites:        UI_Invites, // invite codes in the settings (ui_invites.odin)
	// When the code accounts registered with was last asked for
	// (invited_by_line).
	invites_asked:  map[proto.Account_Id]time.Tick,
	channels:       UI_Channels, // the channel list and the Channels window (ui_channels.odin)
	timeline:       UI_Timeline, // the messages on screen (ui_timeline.odin)
	chat:           UI_Chat, // the chat tab (ui_chat.odin)
	reactors_asked: Reactors_Asked, // who reacted, last asked for (ui_timeline.odin)
	forward:        UI_Forward, // forwarding, and links to messages (ui_forward.odin)
	search:         UI_Search, // searching messages (ui_search.odin)
	// The user whose menu is open, and its volume slider's value (the
	// slider needs a stable address). See user_menu.
	menu_user:      proto.User_Num, // the connection clicked, if one was
	menu_account:   proto.Account_Id,
	menu_volume:    mu.Real,
	menu_requested: bool,
	// The buddy screen (ui_buddies.odin), and the menu's poke message
	// (ui_users.odin).
	buddies:        UI_Buddies,
	poke_buf:       [proto.MAX_POKE_SIZE]u8,
	poke_len:       int,
	// The thread windows (ui_threads.odin), by slot, and how many
	// threads have been opened, for which was opened first.
	threads:        [conn.MAX_THREADS]UI_Thread,
	threads_opened: u64,
	// Statuses, members and settings on the server (ui_profiles.odin).
	profiles:       UI_Profiles,
	// Managing the server, for who may (ui_manage.odin), and the voice
	// panel (ui_voice_panel.odin).
	manage:         UI_Manage,
	roles:          UI_Roles, // the settings' Roles (ui_roles.odin)
	server_info:    UI_Server_Info, // and its Server (ui_server_info.odin)
	voice_panel:    UI_Voice_Panel,
	// Completing a mention in a composer (ui_completion.odin).
	completion:     UI_Completion,
	// The emoji picker (ui_picker.odin).
	picker:         UI_Picker,
	// The pinned messages' window (ui_pins.odin), and the menu of a
	// message (ui_message_menu.odin).
	pins:           UI_Pins,
	msg_menu:       UI_Message_Menu,
	// The server whose per-user volumes the session has been given
	// (apply_gains).
	gains_for:      [proto.KEY_SIZE]u8,
	// Pictures messages carry, asked for to be shown, and when.
	previews_asked: map[proto.Blob_Id]time.Tick,
}

// in_voice is whether a session is in a voice room or a call, or on its
// way into one.
in_voice :: proc(ns: ^Net_Session) -> bool {
	v := &ns.view
	sync.guard(&v.mutex)
	return v.my_room != 0 || v.voice_pending || v.call.status != .None
}

// sound_session is whose sounds go with what we do (mute, deafen): the
// session in voice, or with none the one shown. As of this frame, so it
// takes no View's lock.
sound_session :: proc(ui: ^UI) -> ^Net_Session {
	if ui.voice_at != nil {
		return ui.voice_at
	}
	return ui.session
}

/*
leave_voice_elsewhere is a server's voice about to be joined (a
channel's, or a call; `here` is that server, the one shown if nil):
there's one microphone, so voice is in one server at a time, and
wherever else it is, it's left.
*/
leave_voice_elsewhere :: proc(ui: ^UI, here: ^Net_Session = nil) {
	here := here if here != nil else ui.session
	for ns in ui.sessions {
		if ns == here || !in_voice(ns) {
			continue
		}
		in_call: bool
		{
			sync.guard(&ns.view.mutex)
			in_call = ns.view.call.status != .None
		}
		log.infof("ui: leaving the voice of %s for the one here", ns.server)
		if in_call {
			conn.push_command(&ns.client.commands, conn.Call_Hangup_Command{})
		} else {
			conn.push_command(&ns.client.commands, conn.Voice_Command{})
		}
	}
}

/*
command_all gives a command to every session: one about this client
rather than a server (a setting, mute, deafen), which holds nothing
that would be freed with it.
*/
command_all :: proc(ui: ^UI, cmd: conn.Command) {
	for ns in ui.sessions {
		conn.push_command(&ns.client.commands, cmd)
	}
}

/*
server_ui_destroy frees what the UI's Server_UI holds; a stash's is freed
by swapping it in first (stash_destroy).
*/
server_ui_destroy :: proc(ui: ^UI) {
	avatar_pick_wait(ui)
	timeline_destroy(&ui.timeline)
	ui_threads_destroy(ui)
	ui_message_menu_destroy(ui)
	ui_completion_destroy(ui)
	ui_forward_destroy(ui)
	delete(ui.chat.open)
	ui_profiles_destroy(ui)
	ui_manage_destroy(ui)
	ui_roles_destroy(ui)
	delete(ui.invites_asked)
	delete(ui.account.verify_loaded)
	delete(ui.previews_asked)
	picked_files_destroy(&ui.chat.files)
	picked_files_destroy(&ui.buddies.files)
	for &t in ui.threads {
		picked_files_destroy(&t.files)
	}
	delete(ui.reactors_asked.emoji)
	delete(ui.channels.find_asked)
	ui.srv = {}
}

// stash_destroy frees a session's stashed Server_UI.
stash_destroy :: proc(ui: ^UI, ns: ^Net_Session) {
	shown := ui.srv
	ui.srv = ns.stash
	server_ui_destroy(ui)
	ui.srv = shown
	ns.stash = {}
}

/*
show_session shows another session (nil: none), keeping what the UI
had of the one shown till now in its stash. What the shown server was
watching of somebody's screen stops: there's one picture to show it in.
*/
show_session :: proc(ui: ^UI, ns: ^Net_Session) {
	if ns == ui.session {
		return
	}
	if old := ui.session; old != nil {
		// Nothing there is being read or watched while it isn't shown;
		// shown again, it's told what is.
		conn.push_command(&old.client.commands, conn.Watch_Command{user = 0})
		conn.push_command(&old.client.commands, conn.Reading_Command{conv = 0})
		old.stash = ui.srv
		old.stash.timeline.reading = 0
		ui.srv = {}
	}
	ui.session = ns
	if ns != nil {
		ui.srv = ns.stash
		ns.stash = {}
		ui.view = &ns.view
		// What the connect screen says, should it be shown for this one
		// (it failed): connecting again is one click.
		ui.server_len = copy(ui.server_buf[:], ns.server)
		ui.password_len = copy(ui.password_buf[:], ns.password)
	} else {
		ui.view = &ui.no_view
	}
	ui_images_switch(ui)
	ui.select.panel, ui.select.dragging = .None, false
	ui.msg_bar = {} // its messages are the old server's
	ui.focus_composer = false
	ui.page = .Main
	ui.redraw_frames = max(ui.redraw_frames, 2)
	ui.redraw_at = time.tick_now()
}

/*
servers_frame counts what's unread on every server: in its channels for
its icon on the rail, in its DMs for the inbox's, and all of it together
for the window's title and the tray; and tells the desktop what each
has for us (session_notices). Between frames, with no View locked.
*/
servers_frame :: proc(ui: ^UI) {
	named := rail_count(ui) > 1
	total, mentions, dms := 0, 0, 0
	for ns in ui.sessions {
		if ns.joining {
			continue
		}
		v := &ns.view
		{
			sync.guard(&v.mutex)
			ns.unread, ns.mentions, ns.dm_unread = 0, 0, 0
			if v.status == .Connected {
				ns.dm_unread = dm_unread(&ui.settings, v)
				ns.unread = unread_total(&ui.settings, v) - ns.dm_unread
				// A mention counts in a muted channel too.
				for ch in v.channels {
					ns.mentions += ch.mentions
				}
			}
		}
		// A DM is for us as much as a mention.
		total += ns.unread + ns.dm_unread
		mentions += ns.mentions + ns.dm_unread
		dms += ns.dm_unread
		session_notices(ui, ns, named)
	}
	ui.unread, ui.mentions, ui.dm_unread = total, mentions, dms
	if key := title_key(ui.unread, ui.mentions); ui.window != nil && key != ui.title_unread {
		ui.title_unread = key
		title: string
		switch {
		case key > 0:
			title = fmt.tprintf("(%s) Yap", conn.unread_count(key))
		case key < 0:
			title = "(*) Yap"
		case:
			title = "Yap"
		}
		glfw.SetWindowTitle(ui.window, strings.clone_to_cstring(title, context.temp_allocator))
	}
}

/*
title_key is what the window's title says: the number of mentions when
there are any, -1 for "(*)" when only other messages are unread, 0 when
nothing is.
*/
title_key :: proc(unread, mentions: int) -> int {
	if mentions > 0 {
		return mentions
	}
	return -1 if unread > 0 else 0
}

// rail_count is how many servers are on the rail.
rail_count :: proc(ui: ^UI) -> (n: int) {
	for ns in ui.sessions {
		if !ns.joining {
			n += 1
		}
	}
	return
}

// on_rail is whether `ns` is still one of the rail's (it may have been
// left since it was noted).
on_rail :: proc(ui: ^UI, ns: ^Net_Session) -> bool {
	for other in ui.sessions {
		if other == ns {
			return !ns.joining
		}
	}
	return false
}

/*
The server rail: down the left edge, one round icon per session in the
order joined, with the server's initials on its colour; the one shown
has a bar beside it, one connecting is dimmed and one that failed is
grey with red letters (a server's own colour may be red). A server with
something unread has a short bar beside it, and one with mentions or
DMs for us their count in red.

Clicking one shows it; dragging it moves it (the joined servers in the
settings follow the rail's order); right-clicking it (a long press on a
touch screen) opens its menu: its settings, logging out of it, leaving
it, and leaving it and forgetting its key. + opens the dialog that joins
another (ui_join.odin), which has its session to itself until it's
logged in.
*/

UI_Rail :: struct {
	// The icon whose menu is open, and what the menu is asking to be
	// sure of.
	menu_ns:        ^Net_Session,
	menu_requested: bool,
	confirm:        Rail_Confirm,
	// Picked in the menu, done after the frame (rail_frame, switch_now):
	// leaving a server, perhaps forgetting its key too; its settings,
	// once it's shown.
	leave:          ^Net_Session,
	forget_key:     bool,
	settings:       bool,
	// The icon pressed, and where; it's dragged once the pointer has gone
	// far enough.
	drag:           ^Net_Session,
	drag_y:         i32,
	dragging:       bool,
}

Rail_Confirm :: enum {
	None,
	Leave,
	Forget, // and its key
}

RAIL_WIDTH :: 56
@(private = "file")
RAIL_ICON :: 40
@(private = "file")
RAIL_SLOT :: RAIL_ICON + 6
@(private = "file")
RAIL_WINDOW :: "rail"
@(private = "file")
RAIL_MENU :: "server menu"
@(private = "file")
RAIL_MENU_WIDTH :: 220
// How far an icon goes with the pointer before it's being dragged.
@(private = "file")
DRAG_START :: 6

// rail_width is how much of the window's left the rail takes.
rail_width :: proc(ui: ^UI) -> i32 {
	return RAIL_WIDTH
}

server_rail :: proc(ui: ^UI, h: i32) {
	ctx := &ui.ctx
	rl := &ui.rail
	if cnt := mu.get_container(ctx, RAIL_WINDOW); cnt != nil {
		cnt.rect = {0, 0, RAIL_WIDTH, h}
		cnt.zindex = -1 // under what floats, like the main window
	}
	opts := mu.Options{.NO_TITLE, .NO_RESIZE, .NO_CLOSE, .NO_SCROLL}
	if !mu.begin_window(ctx, RAIL_WINDOW, {0, 0, RAIL_WIDTH, h}, opts) {
		return
	}
	defer mu.end_window(ctx)
	inbox_icon(ui)
	// The rail's servers, and the middle of each one's row, for dragging.
	order := make([dynamic]^Net_Session, context.temp_allocator)
	middles := make([dynamic]i32, context.temp_allocator)
	for ns in ui.sessions {
		if ns.joining {
			continue
		}
		label, initials: string
		status: conn.Status
		// Its picture, if it has one and it's here (ui_server_info.odin).
		picture: Maybe(mu.Icon)
		{
			v := &ns.view
			sync.guard(&v.mutex)
			status = v.status
			if icon, ok := server_icon(ui, ns.server, v); ok {
				picture = icon
			}
			name := v.server_name if v.server_name != "" else ns.server
			initials = server_initials(name)
			label =
				fmt.tprintf("%s\n%s", v.server_name, ns.server) if v.server_name != "" else ns.server
		}
		color := server_color(ns.server)
		text := mu.Color{255, 255, 255, 255}
		switch status {
		case .Failed, .Disconnected:
			color, text = theme.failed_disc, theme.failed_text
			label = fmt.tprintf("%s\nnot connected", label)
		case .Connecting:
			color = dimmed(color)
			label = fmt.tprintf("%s\nconnecting...", label)
		case .Connected:
			switch {
			case ns.mentions > 0:
				label = fmt.tprintf("%s\n%d unread, %d for you", label, ns.unread, ns.mentions)
			case ns.unread > 0:
				label = fmt.tprintf("%s\n%d unread", label, ns.unread)
			}
		}
		if rl.dragging && rl.drag == ns {
			color, text = dimmed(color), dimmed(text)
		}
		shown := ns == ui.session && !ui.join.open && ui.page != .Buddies
		r, id := rail_icon(ui, uintptr(rawptr(ns)), initials, color, text, label, shown, picture)
		if !shown && ns.unread > 0 {
			mu.draw_rect(ctx, {r.x - ctx.style.padding, r.y + r.h / 2 - 4, 4, 8}, theme.mark)
		}
		if ns.mentions > 0 {
			mentions_badge(ui, r, ns.mentions)
		}
		append(&order, ns)
		append(&middles, r.y + r.h / 2)
		if ctx.hover_id == id && ctx.mouse_pressed_bits == {.LEFT} {
			ui.switch_to, ui.switching = ns, true
			rl.drag, rl.drag_y, rl.dragging = ns, ctx.mouse_pos.y, false
		}
		if ctx.hover_id == id && .RIGHT in ctx.mouse_pressed_bits {
			rl.menu_ns, rl.menu_requested = ns, true
		}
	}
	white := mu.Color{255, 255, 255, 255}
	_, plus := rail_icon(ui, RAIL_PLUS, "+", theme.plus_disc, white, "Join a server", ui.join.open)
	if ctx.hover_id == plus && ctx.mouse_pressed_bits == {.LEFT} {
		join_open(ui)
	}
	rail_drag(ui, order[:], middles[:])
	rail_bottom(ui, h)
}

// The ids of the rail's icons that aren't a server's (rail_icon).
@(private = "file")
RAIL_PLUS :: 1
@(private = "file")
RAIL_INBOX :: 2

/*
inbox_icon is the rail's first icon: the inbox, the DMs of every server
(ui_buddies.odin), with how many of them are unread on it, as a server's
mentions are on its own.
*/
@(private = "file")
inbox_icon :: proc(ui: ^UI) {
	ctx := &ui.ctx
	open := ui.page == .Buddies && !ui.join.open
	hint := "Direct messages"
	if ui.dm_unread > 0 {
		hint = fmt.tprintf("Direct messages\n%s unread", conn.unread_count(ui.dm_unread))
	}
	white := mu.Color{255, 255, 255, 255}
	r, id := rail_icon(ui, RAIL_INBOX, "", theme.plus_disc, white, hint, open)
	icon := mu.Rect{r.x + (r.w - RAIL_ICON) / 2, r.y + 3, RAIL_ICON, RAIL_ICON}
	mu.draw_icon(ctx, render.icon_id(.Mail), icon, white)
	if ui.dm_unread > 0 {
		mentions_badge(ui, r, ui.dm_unread)
	}
	// Under it, a line between it and the servers.
	mu.layout_row(ctx, {-1}, 2)
	line := mu.layout_next(ctx)
	mu.draw_rect(ctx, {line.x + (line.w - RAIL_ICON) / 2 + 6, line.y, RAIL_ICON - 12, 2}, theme.unlit)
	if ctx.hover_id == id && ctx.mouse_pressed_bits == {.LEFT} {
		// Logged in nowhere, there's nothing to show in it.
		if ui.session != nil && !ui.join.open {
			toggle_inbox(ui)
		}
	}
}

/*
rail_bottom is the bottom of the rail: how the shown server's connection
is doing (ui_connection.odin), and the settings. Neither is one
conversation's, nor scrolls away with the rail's servers.
*/
@(private = "file")
rail_bottom :: proc(ui: ^UI, h: i32) {
	ctx := &ui.ctx
	x := i32((RAIL_WIDTH - ICON_BUTTON) / 2)
	settings_y := h - ICON_BUTTON - ctx.style.padding
	if ui.session != nil && !ui.session.joining {
		v := ui.view
		sync.guard(&v.mutex)
		mu.layout_set_next(ctx, {x, settings_y - ICON_BUTTON - ctx.style.spacing, ICON_BUTTON, ICON_BUTTON}, false)
		connection_indicator(ui)
	}
	mu.layout_set_next(ctx, {x, settings_y, ICON_BUTTON, ICON_BUTTON}, false)
	if .SUBMIT in icon_button(ui, "settings", .Settings, "Settings") {
		open_settings(ui)
	}
}

/*
server_tag draws a server's initials (from its `name`) on its colour (from
its `address`) at the right end of `r`, as a row in the inbox ends; it
says how much of the row it took.
*/
server_tag :: proc(ui: ^UI, r: mu.Rect, name, address: string) -> i32 {
	ctx := &ui.ctx
	font := ctx.style.font
	text := server_initials(name)
	w := ctx.text_width(font, text) + 10
	h := ctx.text_height(font) + 2
	b := mu.Rect{r.x + r.w - w - 4, r.y + (r.h - h) / 2, w, h}
	pill(ui, b, server_color(address))
	mu.draw_text(ctx, font, text, {b.x + 5, b.y + 1}, {255, 255, 255, 255})
	return w + 8
}

@(private = "file")
dimmed :: proc(c: mu.Color) -> mu.Color {
	return {c.r / 2, c.g / 2, c.b / 2, c.a}
}

/*
rail_drag follows an icon being dragged: while the button is down, a
line where it would go; let go, it goes there, and the joined servers
in the settings are put in the rail's new order. `order` is the rail's
servers, `middles` the middle of each one's row.
*/
@(private = "file")
rail_drag :: proc(ui: ^UI, order: []^Net_Session, middles: []i32) {
	ctx := &ui.ctx
	rl := &ui.rail
	if rl.drag == nil {
		return
	}
	from := -1
	for ns, i in order {
		if ns == rl.drag {
			from = i
		}
	}
	if from < 0 {
		rl.drag, rl.dragging = nil, false
		return
	}
	y := ctx.mouse_pos.y
	if !rl.dragging && abs(y - rl.drag_y) >= DRAG_START {
		rl.dragging = true
	}
	// Where it would go: before the first whose middle is below the
	// pointer.
	to := 0
	for m in middles {
		if m < y {
			to += 1
		}
	}
	if .LEFT in ctx.mouse_down_bits {
		if rl.dragging && to != from && to != from + 1 {
			line_y :=
				middles[to] - RAIL_SLOT / 2 if to < len(middles) else middles[len(middles) - 1] + RAIL_SLOT / 2
			x := i32((RAIL_WIDTH - RAIL_ICON) / 2)
			mu.draw_rect(ctx, {x, line_y - 1, RAIL_ICON, 3}, theme.mark)
		}
		return
	}
	// Let go.
	dragging := rl.dragging
	rl.drag, rl.dragging = nil, false
	if !dragging || to == from || to == from + 1 {
		return
	}
	if to > from {
		to -= 1
	}
	moved := make([dynamic]^Net_Session, 0, len(ui.sessions), context.temp_allocator)
	append(&moved, ..order)
	ns := moved[from]
	ordered_remove(&moved, from)
	inject_at(&moved, to, ns)
	addresses := make([]string, len(moved), context.temp_allocator)
	for other, i in moved {
		addresses[i] = other.server
	}
	// One being joined isn't on the rail; it stays after those that are.
	for other in ui.sessions {
		if other.joining {
			append(&moved, other)
		}
	}
	copy(ui.sessions[:], moved[:])
	settings.order_joined_servers(&ui.settings, addresses)
	save_settings(ui)
	log.infof("ui: moved %s on the rail", ns.server)
}

// mentions_badge is how many mentions and DMs a server has for us: a
// red pill on the bottom right of its icon in the row `r`, cut into the
// icon by a ring of the rail's own colour.
@(private = "file")
mentions_badge :: proc(ui: ^UI, r: mu.Rect, count: int) {
	ctx := &ui.ctx
	font := render.font_with_style(ctx.style.font, .Bold)
	text := conn.unread_count(count)
	h := ctx.text_height(font)
	tw := ctx.text_width(font, text)
	w := max(h, tw + 6)
	// Its bottom right a little past the icon's, on the icon's edge.
	icon_right := r.x + (r.w + RAIL_ICON) / 2
	icon_bottom := r.y + 3 + RAIL_ICON
	b := mu.Rect{icon_right + 2 - w, icon_bottom + 2 - h, w, h}
	pill(ui, {b.x - 2, b.y - 2, b.w + 4, b.h + 4}, ctx.style.colors[.WINDOW_BG])
	pill(ui, b, theme.mentions)
	mu.draw_text(ctx, font, text, {b.x + (w - tw) / 2, b.y}, {255, 255, 255, 255})
}

// pill fills `r` with its ends rounded: a disc if it's as wide as it's
// tall.
@(private = "file")
pill :: proc(ui: ^UI, r: mu.Rect, color: mu.Color) {
	if r.w <= r.h {
		disc(ui, r, color)
		return
	}
	disc(ui, {r.x, r.y, r.h, r.h}, color)
	disc(ui, {r.x + r.w - r.h, r.y, r.h, r.h}, color)
	mu.draw_rect(&ui.ctx, {r.x + r.h / 2, r.y, r.w - r.h, r.h}, color)
}

/*
rail_menu is a server's menu, opened by right-clicking its icon. Leaving
asks first: it forgets the server's password, and with its key, the
next connection trusts whatever key it shows. Drawn after the rail.
*/
rail_menu :: proc(ui: ^UI) {
	ctx := &ui.ctx
	rl := &ui.rail
	if rl.menu_requested {
		rl.menu_requested = false
		rl.confirm = .None
		mu.open_popup(ctx, RAIL_MENU)
	}
	if cnt := mu.get_container(ctx, RAIL_MENU, {.CLOSED}); cnt != nil && cnt.open {
		w, h := i32(ui.metrics.logical_w), i32(ui.metrics.logical_h)
		cnt.rect.x = clamp(cnt.rect.x, 0, max(w - cnt.rect.w, 0))
		cnt.rect.y = clamp(cnt.rect.y, 0, max(h - cnt.rect.h, 0))
	}
	if !mu.begin_popup(ctx, RAIL_MENU) {
		rl.confirm = .None
		return
	}
	defer mu.end_popup(ctx)
	close :: proc(ctx: ^mu.Context) {
		mu.get_current_container(ctx).open = false
	}
	ns := rl.menu_ns
	// Gone from the rail under the menu.
	if !on_rail(ui, ns) {
		close(ctx)
		return
	}
	name: string
	logged_in: bool
	{
		v := &ns.view
		sync.guard(&v.mutex)
		name = strings.clone(
			v.server_name if v.server_name != "" else ns.server,
			context.temp_allocator,
		)
		logged_in = v.status == .Connected && v.login.state == .Done
	}

	mu.layout_row(ctx, {RAIL_MENU_WIDTH})
	with_text_color(ctx, theme.dim, name, label_proc)
	if rl.confirm != .None {
		mu.text(
			ctx,
			"Leave it? Its key is forgotten too: the next time, whatever key it shows is trusted." if rl.confirm == .Forget else "Leave it? It comes off the rail, with its password.",
		)
		half := (RAIL_MENU_WIDTH - ctx.style.spacing) / 2
		mu.layout_row(ctx, {half, half})
		if .SUBMIT in stable_button(ctx, "cancel", "Cancel") {
			rl.confirm = .None
			close(ctx)
		}
		if .SUBMIT in stable_button(ctx, "leave", "Leave") {
			rl.leave, rl.forget_key = ns, rl.confirm == .Forget
			rl.confirm = .None
			close(ctx)
		}
		return
	}
	if .SUBMIT in stable_button(ctx, "settings", "Settings") {
		ui.switch_to, ui.switching = ns, true
		rl.settings = true
		close(ctx)
	}
	if logged_in && .SUBMIT in stable_button(ctx, "log out", "Log out") {
		log.infof("ui: logging out of %s", ns.server)
		conn.push_command(&ns.client.commands, conn.Logout_Command{})
		close(ctx)
	}
	if .SUBMIT in stable_button(ctx, "leave", "Leave the server") {
		rl.confirm = .Leave
	}
	if .SUBMIT in stable_button(ctx, "forget", "Leave and forget its key") {
		rl.confirm = .Forget
	}
}

// rail_frame does what the rail's menu asked for in the last frame.
// Between frames.
rail_frame :: proc(ui: ^UI) {
	rl := &ui.rail
	ns := rl.leave
	if ns == nil {
		return
	}
	rl.leave = nil
	if !on_rail(ui, ns) {
		return
	}
	server := strings.clone(ns.server, context.temp_allocator)
	log.infof("ui: leaving %s", server)
	disconnect(ui, ns, play_goodbye = true)
	if rl.forget_key && conn.forget_server_key(ui.opts.known_servers, server) {
		log.infof("forgot the key of %s", server)
		ui.known.loaded = false
	}
}

/*
switch_now acts on a click on the rail, after the frame that had it: a
server's icon shows its channels, even the shown one's from the inbox.
Or on one in the inbox (ui_buddies.odin) of a DM on another server,
which is shown behind the inbox with the DM open. The + dialog is given
up for it.
*/
switch_now :: proc(ui: ^UI) {
	if !ui.switching {
		return
	}
	ui.switching = false
	join_close(ui)
	settings_after := ui.rail.settings
	ui.rail.settings = false
	dm := ui.inbox_open
	ui.inbox_open = 0
	for ns in ui.sessions {
		if ns == ui.switch_to {
			show_session(ui, ns)
			if dm != 0 {
				open_conversation(ui, dm)
			} else if ui.page == .Buddies {
				ui.page = .Main
			}
			if settings_after {
				open_settings(ui)
			}
			return
		}
	}
}

// rail_icon draws one of the rail's icons, and says where its row is and
// its control's id. `key` tells it from the others: its session's
// pointer, or RAIL_PLUS or RAIL_INBOX. With a `picture`, that's drawn
// instead of the disc and its text, as dim as the text would be.
@(private = "file")
rail_icon :: proc(
	ui: ^UI,
	key: uintptr,
	text: string,
	color: mu.Color,
	text_color: mu.Color,
	hint: string,
	shown: bool,
	picture: Maybe(mu.Icon) = nil,
) -> (
	r: mu.Rect,
	id: mu.Id,
) {
	ctx := &ui.ctx
	mu.layout_row(ctx, {-1}, RAIL_SLOT)
	r = mu.layout_next(ctx)
	id = mu.get_id(ctx, key)
	mu.update_control(ctx, id, r)
	icon := mu.Rect{r.x + (r.w - RAIL_ICON) / 2, r.y + 3, RAIL_ICON, RAIL_ICON}
	if shown {
		mu.draw_rect(ctx, {r.x - ctx.style.padding, icon.y + 6, 4, RAIL_ICON - 12}, theme.mark)
	}
	if pic, ok := picture.?; ok {
		mu.draw_icon(ctx, pic, icon, text_color)
		if ctx.hover_id == id {
			ui.hint, ui.hint_of = hint, icon
		}
		return
	}
	disc(ui, icon, color)
	font := ctx.style.font
	w := ctx.text_width(font, text)
	mu.draw_text(
		ctx,
		font,
		text,
		{icon.x + (icon.w - w) / 2, icon.y + (icon.h - ctx.text_height(font)) / 2},
		text_color,
	)
	if ctx.hover_id == id {
		ui.hint, ui.hint_of = hint, icon
	}
	return
}

// server_initials is what a server's icon says: the first letters of
// the first two words of its name (or address), or the first two
// letters of its only word.
server_initials :: proc(name: string) -> string {
	words := make([dynamic]string, context.temp_allocator)
	start := -1
	for r, i in name {
		alnum := unicode.is_letter(r) || unicode.is_digit(r)
		switch {
		case alnum && start < 0:
			start = i
		case !alnum && start >= 0:
			append(&words, name[start:i])
			start = -1
		}
	}
	if start >= 0 {
		append(&words, name[start:])
	}
	letters := make([dynamic]rune, context.temp_allocator)
	switch len(words) {
	case 0:
		return "?"
	case 1:
		for r in words[0] {
			append(&letters, unicode.to_upper(r))
			if len(letters) == 2 {
				break
			}
		}
	case:
		for w in words[:2] {
			first, _ := utf8.decode_rune_in_string(w)
			append(&letters, unicode.to_upper(first))
		}
	}
	return utf8.runes_to_string(letters[:], context.temp_allocator)
}

// server_color is a server's own colour, from its address, as people's
// are from their ids (avatar_color).
server_color :: proc(server: string) -> mu.Color {
	h: u32 = 2166136261
	for i in 0 ..< len(server) {
		h = (h ~ u32(server[i])) * 16777619
	}
	return avatar_color(proto.Account_Id(h % 4096))
}

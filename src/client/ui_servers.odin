package client

import "client:conn"
import "common:proto"
import log "common:wlog"
import "core:fmt"
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
	// Messages unread in channels that aren't muted.
	unread:         int,
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
	// Managing the server, for who may (ui_manage.odin), calls
	// (ui_calls.odin), and the voice panel (ui_voice_panel.odin).
	manage:         UI_Manage,
	roles:          UI_Roles, // the Roles window (ui_roles.odin)
	calls:          UI_Calls,
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
leave_voice_elsewhere is the shown server's voice about to be joined (a
channel's, or a call): there's one microphone, so voice is in one server
at a time, and wherever else it is, it's left.
*/
leave_voice_elsewhere :: proc(ui: ^UI) {
	for ns in ui.sessions {
		if ns == ui.session || !in_voice(ns) {
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
		conn.push_command(&old.client.commands, conn.Watch_Command{user = 0})
		old.stash = ui.srv
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
	ui.focus_composer = false
	ui.page = .Main
	ui.redraw_frames = max(ui.redraw_frames, 2)
	ui.redraw_at = time.tick_now()
}

/*
The server rail: down the left edge, one round icon per session in the
order joined, with the server's initials on its colour; the one shown
has a bar beside it, one connecting is dimmed and one that failed is
grey with red letters (a server's own colour may be red). Clicking one shows it; + shows the connect screen, to join another
(its dialog is docs/next 9b). It's there as soon as there's a session.
*/

RAIL_WIDTH :: 56
@(private = "file")
RAIL_ICON :: 40
@(private = "file")
RAIL_WINDOW :: "rail"
@(private = "file")
FAILED_COLOR :: mu.Color{70, 70, 70, 255}
@(private = "file")
FAILED_TEXT :: mu.Color{235, 110, 110, 255}

// rail_width is how much of the window's left the rail takes.
rail_width :: proc(ui: ^UI) -> i32 {
	return RAIL_WIDTH if len(ui.sessions) > 0 else 0
}

server_rail :: proc(ui: ^UI, h: i32) {
	if len(ui.sessions) == 0 {
		return
	}
	ctx := &ui.ctx
	if cnt := mu.get_container(ctx, RAIL_WINDOW); cnt != nil {
		cnt.rect = {0, 0, RAIL_WIDTH, h}
		cnt.zindex = -1 // under what floats, like the main window
	}
	opts := mu.Options{.NO_TITLE, .NO_RESIZE, .NO_CLOSE, .NO_SCROLL}
	if !mu.begin_window(ctx, RAIL_WINDOW, {0, 0, RAIL_WIDTH, h}, opts) {
		return
	}
	defer mu.end_window(ctx)
	for ns in ui.sessions {
		label, initials: string
		status: conn.Status
		{
			v := &ns.view
			sync.guard(&v.mutex)
			status = v.status
			name := v.server_name if v.server_name != "" else ns.server
			initials = server_initials(name)
			label = fmt.tprintf("%s\n%s", v.server_name, ns.server) if v.server_name != "" else ns.server
		}
		color := server_color(ns.server)
		text := mu.Color{255, 255, 255, 255}
		switch status {
		case .Failed, .Disconnected:
			color, text = FAILED_COLOR, FAILED_TEXT
			label = fmt.tprintf("%s\nnot connected", label)
		case .Connecting:
			color = {color.r / 2, color.g / 2, color.b / 2, 255}
			label = fmt.tprintf("%s\nconnecting...", label)
		case .Connected:
		}
		if rail_icon(ui, ns, initials, color, text, label, ns == ui.session) {
			ui.switch_to, ui.switching = ns, true
		}
	}
	white := mu.Color{255, 255, 255, 255}
	if rail_icon(ui, nil, "+", {70, 70, 70, 255}, white, "Join another server", ui.session == nil) {
		ui.switch_to, ui.switching = nil, true
	}
}

// switch_now acts on a click on the rail, after the frame that had it.
switch_now :: proc(ui: ^UI) {
	if !ui.switching {
		return
	}
	ui.switching = false
	for ns in ui.sessions {
		if ns == ui.switch_to {
			show_session(ui, ns)
			return
		}
	}
	if ui.switch_to == nil {
		show_session(ui, nil)
	}
}

// rail_icon draws one of the rail's icons and says whether it was
// clicked. `key` tells it from the others: its session, or nil for +.
@(private = "file")
rail_icon :: proc(
	ui: ^UI,
	key: ^Net_Session,
	text: string,
	color: mu.Color,
	text_color: mu.Color,
	hint: string,
	shown: bool,
) -> bool {
	ctx := &ui.ctx
	mu.layout_row(ctx, {-1}, RAIL_ICON + 6)
	r := mu.layout_next(ctx)
	id := mu.get_id(ctx, uintptr(rawptr(key)) if key != nil else 1)
	mu.update_control(ctx, id, r)
	icon := mu.Rect{r.x + (r.w - RAIL_ICON) / 2, r.y + 3, RAIL_ICON, RAIL_ICON}
	if shown {
		mu.draw_rect(ctx, {r.x - ctx.style.padding, icon.y + 6, 4, RAIL_ICON - 12}, {230, 230, 230, 255})
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
	return ctx.mouse_pressed_bits == {.LEFT} && ctx.focus_id == id
}

// server_initials is what a server's icon says: the first letters of
// the first two words of its name (or address), or the first two
// letters of its only word.
@(private = "file")
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
@(private = "file")
server_color :: proc(server: string) -> mu.Color {
	h: u32 = 2166136261
	for i in 0 ..< len(server) {
		h = (h ~ u32(server[i])) * 16777619
	}
	return avatar_color(proto.Account_Id(h % 4096))
}

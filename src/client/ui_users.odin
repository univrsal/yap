package client

import log "common:wlog"
import "core:fmt"
import "core:slice"
import mu "vendor:microui"

import "client:conn"
import "client:render"
import "client:settings"
import "common:proto"

// Per-user playback settings: clicking (left or right) on another user in the
// channel list opens a small menu to mute them or change their volume, for you
// only. The settings are kept in settings.json by the server's key and the
// account (names can be copied and are the same on many servers, so they can't
// be used as a key) and applied to every connection of the account (see
// user_settings / Gain_Command). The same menu adds or removes a buddy and
// opens a DM with them, and for moderators mutes them for everyone, moves them
// to another voice room or disconnects them (conn/moderation.odin).

@(private = "file")
MENU :: "user menu"
// Every row of the menu is laid out to this width, never -1. The popup sizes
// itself to its content, and microui lays a frame out in the size from two
// frames before, so a row that fills the body would keep alternating between
// two widths forever (a wider one left over from the last menu opened).
@(private = "file")
MENU_WIDTH :: 240

// status_icon fills the column in front of a name (here and in the buddy
// list).
status_icon :: proc(ctx: ^mu.Context, icon: render.Icon, color: mu.Color) {
	mu.draw_icon(ctx, render.icon_id(icon), mu.layout_next(ctx), color)
}

// What the icon in front of your own name says, from most to least telling:
// muted by a moderator means nobody here hears you whatever you do, deafened
// means hearing nobody, muted means saying nothing to anybody. Our own mute is
// the one state that we don't wait for the server to tell us about.
@(private = "file")
my_status :: proc(ui: ^UI, speaking: bool) -> (render.Icon, mu.Color) {
	return sound_status(ui.muted, ui.deafened, speaking, server_muted(ui.view, ui.view.me))
}

// The same for someone else, from what the server passed on.
// (Also used by the voice panel for the other side of a call.)
their_status :: proc(
	user: conn.View_User,
	speaking: bool,
	server_muted := false,
) -> (
	render.Icon,
	mu.Color,
) {
	return sound_status(user.muted, user.deafened, speaking, server_muted)
}

// server_muted returns whether a moderator has muted an account on this
// server. Call with the View locked.
server_muted :: proc(v: ^conn.View, account: proto.Account_Id) -> bool {
	acc, ok := v.accounts[account]
	return ok && .Server_Muted in acc.flags
}

@(private = "file")
sound_status :: proc(muted, deafened, speaking, server_muted: bool) -> (render.Icon, mu.Color) {
	switch {
	case server_muted:
		// Not their own doing, so in a colour of its own.
		return .Mic_Off, theme.warning
	case deafened:
		// Someone who isn't listening is usually muted as well, and of the
		// two, that is the one worth showing.
		return .Sound_Off, theme.off
	case muted:
		return .Mic_Off, theme.off
	case speaking:
		return .Mic, theme.speaking
	}
	return .Mic, theme.dim
}

// The mark at the end of a row for someone muted by ourselves. It sits at the
// opposite end from the icon in front on purpose: that icon is what the user
// has switched off, while this one is what we have done to them, and the two
// would otherwise be easy to mix up.
@(private = "file")
local_mute_mark :: proc(ctx: ^mu.Context, row: mu.Rect) {
	mu.draw_icon(ctx, render.icon_id(.Sound_Off), end_of_row(row, 0), theme.dim)
}

// end_of_row is the icon-sized square `slot` places in from a row's end.
@(private = "file")
end_of_row :: proc(row: mu.Rect, slot: i32) -> mu.Rect {
	x := row.x + row.w - render.ICON_SIZE - slot * (render.ICON_SIZE + 4)
	return {x, row.y + (row.h - render.ICON_SIZE) / 2, render.ICON_SIZE, render.ICON_SIZE}
}

// The mark for someone sharing their screen, at the end of the row (in front
// of a local mute mark). It is lit while we are watching them. Where the
// browser can, it is also a button for watching.
@(private = "file")
sharing_mark :: proc(ui: ^UI, row: mu.Rect, slot: i32, id: proto.User_Num) -> mu.Rect {
	ctx := &ui.ctx
	r := end_of_row(row, slot)
	color := ctx.style.colors[.TEXT]
	switch {
	case ui.view.watching == id:
		color = theme.speaking
	case !can_watch_screens(ui) || id == ui.view.my_num:
		color = theme.dim
	}
	mu.draw_icon(ctx, render.icon_id(.Screen), r, color)
	return r
}

// The mark for someone whose audio still comes through while they are muted,
// at the end of the row (in front of the others). That can only be an
// application that they are sharing (ui_app_audio_native.odin), since muting
// stops the microphone. Without this mark, all there is to see is a
// crossed-out microphone, however much is being heard. It is dim for someone
// we have muted ourselves, whom we don't hear either way.
@(private = "file")
app_audio_mark :: proc(ctx: ^mu.Context, row: mu.Rect, slot: i32, heard: bool) {
	mu.draw_icon(
		ctx,
		render.icon_id(.App_Audio),
		end_of_row(row, slot),
		theme.speaking if heard else theme.dim,
	)
}

inside :: proc(r: mu.Rect, p: mu.Vec2) -> bool {
	return p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h
}

// member_row draws one user in the channel list: an icon in front saying what
// they are up to, their picture and, dimmed after their name, their status
// (clicking our own row sets ours). It also shows a microphone, lit while they
// are speaking, and the mute and deafen you have set for them. Marks at the
// end of the row say who is sharing their screen, or an application's audio
// while muted (app_audio_mark). Other users are clickable.
//
// The icon in front is the user's own doing: a crossed-out microphone where
// they have muted themselves, a crossed-out speaker where they have stopped
// listening. Muting someone ourselves is a different thing entirely, so it is
// marked at the other end of the row instead.
member_row :: proc(ui: ^UI, id: proto.User_Num) {
	ctx := &ui.ctx
	v := ui.view

	pic := ctx.text_height(ctx.style.font) + 2
	mu.layout_row(ctx, {render.ICON_SIZE + 4, pic + 4, -1})

	user, known := v.users[id]
	if !known {
		status_icon(ctx, .Mic, theme.dim)
		mu.label(ctx, "")
		mu.label(ctx, fmt.tprintf("user #%d", id))
		return
	}
	acc := v.accounts[user.account] or_else {}
	if id == v.my_num {
		speaking := conn.is_speaking(v, id)
		icon, color := my_status(ui, speaking)
		status_icon(ctx, icon, color)
		cell := mu.layout_next(ctx)
		avatar(ui, user.account, {cell.x, cell.y + (cell.h - pic) / 2, pic, pic})
		text := fmt.tprintf("%s (you)", user.name)
		mu.push_id(ctx, uintptr(id))
		cid := mu.get_id(ctx, "me")
		mu.pop_id(ctx)
		r := mu.layout_next(ctx)
		mu.update_control(ctx, cid, r)
		if ctx.hover_id == cid {
			mu.draw_rect(ctx, r, ctx.style.colors[.BUTTON_HOVER])
			if ctx.mouse_pressed_bits & {.LEFT, .RIGHT} != {} {
				open_status_editor(ui)
			}
		}
		// Green while we are heard, muted or not, as for everybody else.
		name_and_status(
			ctx,
			r,
			text,
			theme.speaking if speaking else ctx.style.colors[.TEXT],
			status_line(acc),
		)
		slot: i32 = 0
		if user.sharing {
			sharing_mark(ui, ctx.last_rect, slot, id)
			slot += 1
		}
		if user.camera {
			mu.draw_icon(
				ctx,
				render.icon_id(.Camera),
				end_of_row(ctx.last_rect, slot),
				ctx.style.colors[.TEXT],
			)
			slot += 1
		}
		if speaking && ui.muted && !ui.settings.mute_app_audio_with_mic {
			app_audio_mark(ctx, ctx.last_rect, slot, true)
		}
		return
	}

	u := settings.user_settings(&ui.settings, v.server_key, user.account)
	text := user.name
	if u.volume != 1 && !u.muted {
		text = fmt.tprintf("%s  (%.0f%%)", text, u.volume * 100)
	}
	speaking := conn.is_speaking(v, id)
	icon, icon_color := their_status(user, speaking, .Server_Muted in acc.flags)
	status_icon(ctx, icon, icon_color)
	cell := mu.layout_next(ctx)
	avatar(ui, user.account, {cell.x, cell.y + (cell.h - pic) / 2, pic, pic})
	color := ctx.style.colors[.TEXT]
	switch {
	case u.muted:
		color = theme.dim // nothing of theirs reaches us
	case speaking:
		color = theme.speaking
	}

	// A flat, full-width control: highlighted on hover, and any click opens
	// the menu.
	mu.push_id(ctx, uintptr(id))
	defer mu.pop_id(ctx)
	cid := mu.get_id(ctx, "member")
	r := mu.layout_next(ctx)
	mu.update_control(ctx, cid, r)
	if ctx.hover_id == cid {
		mu.draw_rect(ctx, r, ctx.style.colors[.BUTTON_HOVER])
	}
	name_and_status(ctx, r, text, color, status_line(acc))
	slot: i32 = 0
	if u.muted {
		local_mute_mark(ctx, r)
		slot += 1
	}
	share_r: mu.Rect
	if user.sharing {
		share_r = sharing_mark(ui, r, slot, id)
		slot += 1
	}
	camera_r: mu.Rect
	if user.camera {
		camera_r = end_of_row(r, slot)
		mu.draw_icon(ctx, render.icon_id(.Camera), camera_r, ctx.style.colors[.TEXT])
		slot += 1
	}
	if speaking && user.muted {
		app_audio_mark(ctx, r, slot, !u.muted)
	}

	if ctx.hover_id == cid && ctx.mouse_pressed_bits & {.LEFT, .RIGHT} != {} {
		// A click on the screen mark starts or stops watching them.
		if user.sharing &&
		   ctx.mouse_pressed_bits == {.LEFT} &&
		   (can_watch_screens(ui) || v.watching == id) &&
		   inside(share_r, ctx.mouse_pos) {
			watch(ui, 0 if v.watching == id else id)
			return
		}
		// A click on the camera mark shows the cameras, where they can be seen.
		if user.camera &&
		   ctx.mouse_pressed_bits == {.LEFT} &&
		   inside(camera_r, ctx.mouse_pos) &&
		   video_docked(ui) {
			ui.chat.tab = .Video
			return
		}
		// A moderator's left press may become a drag to another room, and the
		// menu then opens on the release (ui_voice_drag.odin).
		if ctx.mouse_pressed_bits == {.LEFT} && can_drag(ui, user) {
			voice_drag_begin(ui, id, user)
			return
		}
		open_user_menu(ui, id, user.account)
	}
}

// open_user_menu opens the menu for an account, and for the connection `num`
// of it that was clicked (0 for one from the buddy list, who may not be
// here). Call with the View locked.
open_user_menu :: proc(ui: ^UI, num: proto.User_Num, account: proto.Account_Id) {
	u := settings.user_settings(&ui.settings, ui.view.server_key, account)
	ui.menu_user = num
	ui.menu_account = account
	ui.menu_volume = u.volume * 100
	ui.menu_moving = false
	ui.bans.banning, ui.bans.removing = false, false
	// Opened by user_menu: microui scopes container names by the id stack,
	// and the row it is opened from is nested in ids that the menu isn't.
	ui.menu_requested = true
}

// What someone else is doing, shown in their card.
@(private = "file")
SEEN_AS := [proto.Activity]string {
	.Online  = "online",
	.Away    = "away",
	.Busy    = "busy",
	.Offline = "offline",
}

// user_card is the top of the user menu: who the account is. Call with the
// View locked, inside the menu.
@(private = "file")
user_card :: proc(ui: ^UI, account: proto.Account_Id, acc: conn.View_Account) {
	ctx := &ui.ctx
	v := ui.view
	PICTURE :: 44
	line := ctx.text_height(ctx.style.font)
	mu.layout_row(ctx, {PICTURE, MENU_WIDTH - PICTURE - ctx.style.spacing}, PICTURE)
	avatar(ui, account, mu.layout_next(ctx))
	r := mu.layout_next(ctx)
	color, colored := name_color(v, account)
	if !colored {
		color = ctx.style.colors[.TEXT]
	}
	font := ctx.style.font
	top := r.y + (r.h - 2 * line - 2) / 2
	mu.draw_text(ctx, font, acc.display, {r.x, top}, color)
	if .Bot in acc.flags {
		bot_tag(ctx, r.x + ctx.text_width(font, acc.display), top)
	}
	mu.draw_text(
		ctx,
		font,
		fmt.tprintf("@%s, %s", acc.username, SEEN_AS[acc.activity]),
		{r.x, top + line + 2},
		theme.dim,
	)
	if talking := talking_of(v, account); talking != "" {
		mu.layout_row(ctx, {MENU_WIDTH})
		row := mu.layout_next(ctx)
		h := ctx.text_height(font)
		y := row.y + (row.h - h) / 2
		mu.draw_icon(ctx, render.icon_id(.Phone), {row.x, y, h, h}, ctx.style.colors[.TEXT])
		mu.draw_text(ctx, font, talking, {row.x + h + 6, y}, ctx.style.colors[.TEXT])
	}
	if status := status_line(acc); status != "" {
		mu.layout_row(ctx, {MENU_WIDTH})
		with_text_color(ctx, ctx.style.colors[.TEXT], status, label_proc)
		if acc.status_until != 0 {
			mu.layout_row(ctx, {MENU_WIDTH})
			until := chat_time(ui, proto.Unix_Time(acc.status_until / 1000))
			dim_label(ctx, fmt.tprintf("Until %s", until))
		}
	}
	if .Server_Muted in acc.flags {
		mu.layout_row(ctx, {MENU_WIDTH})
		with_text_color(ctx, theme.warning, "Muted by a moderator", label_proc)
	}
	if len(acc.roles) > 0 {
		role_chips(ui, acc.roles, MENU_WIDTH)
	}
	if invited := invited_by_line(ui, v, account); invited != "" {
		mu.layout_row(ctx, {MENU_WIDTH})
		dim_label(ctx, invited)
	}
}

// user_menu shows the menu for ui.menu_account while it is open.
user_menu :: proc(ui: ^UI) {
	ctx := &ui.ctx
	if ui.menu_account == 0 || ui.menu_account == ui.view.me {
		ui.menu_requested = false
		return
	}
	if ui.menu_requested {
		ui.menu_requested = false
		mu.open_popup(ctx, MENU)
	}

	// Keep the menu inside the window when it is opened near an edge. (.CLOSED:
	// only look it up, since get_container would otherwise create it, open.)
	if cnt := mu.get_container(ctx, MENU, {.CLOSED}); cnt != nil && cnt.open {
		w, h := i32(ui.metrics.logical_w), i32(ui.metrics.logical_h)
		cnt.rect.x = clamp(cnt.rect.x, 0, max(w - cnt.rect.w, 0))
		cnt.rect.y = clamp(cnt.rect.y, 0, max(h - cnt.rect.h, 0))
	}
	if !mu.begin_popup(ctx, MENU) {
		return
	}
	defer mu.end_popup(ctx)

	v := ui.view
	account := ui.menu_account
	u := settings.user_settings(&ui.settings, v.server_key, account)
	changed := false

	// What the account is called, whether one of its connections is here
	// (the one that was clicked, if it was one), and whether it is a buddy.
	name := fmt.tprintf("account #%d", account)
	if acc, ok := v.accounts[account]; ok {
		name = acc.display
		// There is nothing to do with what is left of a deleted account.
		if .Deleted in acc.flags {
			mu.layout_row(ctx, {MENU_WIDTH})
			mu.label(ctx, name)
			dim_label(ctx, "This account was deleted.")
			return
		}
	}
	here := false
	clicked, clicked_here := v.users[ui.menu_user]
	clicked_here = clicked_here && clicked.account == account
	talking_to := (v.call.status == .Active && v.call.peer == account) || clicked_here
	for _, user in v.users {
		here ||= user.account == account
	}
	buddy := slice.contains(v.buddies[:], account)
	user_is_screen_sharing := clicked_here && clicked.sharing

	// Who they are: their picture, their name in their roles' colour, their
	// username and how they are, their status, and their roles.
	if acc, ok := v.accounts[account]; ok {
		user_card(ui, account, acc)
	}

	widths := make([dynamic]i32, context.temp_allocator)
	append(&widths, 0, icon_button_w(ctx), icon_button_w(ctx))
	if user_is_screen_sharing {
		append(&widths, icon_button_w(ctx))
	}
	can_call := may_call(v, account)
	if can_call {
		append(&widths, icon_button_w(ctx))
	}
	can_video_call := can_call && camera_available(v)
	if can_video_call {
		append(&widths, icon_button_w(ctx))
	}
	if talking_to {
		append(&widths, icon_button_w(ctx))
	}
	// At the menu's right end, narrower if they don't all fit (on a phone,
	// where buttons are wider).
	n := i32(len(widths) - 1)
	bw := min(icon_button_w(ctx), (MENU_WIDTH + ctx.style.spacing) / n - ctx.style.spacing)
	for &w in widths[1:] {
		w = bw
	}
	widths[0] = i32(MENU_WIDTH) - (bw + ctx.style.spacing) * n
	mu.layout_row(ctx, widths[:])

	mu.label(ctx, "")
	if talking_to &&
	   .SUBMIT in
		   icon_button(
			   ui,
			   "mute",
			   .Mic_Off if u.muted else .Mic,
			   "Unmute" if u.muted else "Mute for me",
		   ) {
		u.muted = !u.muted
		changed = true
	}

	// Watch their screen, if they are sharing it (the connection that was clicked).
	if user_is_screen_sharing {
		if can_watch_screens(ui) || ui.view.watching == ui.menu_user {
			watching := ui.view.watching == ui.menu_user
			if .SUBMIT in
			   icon_button(
				   ui,
				   "watch",
				   .Screen,
				   "Stop watching" if watching else "Watch their screen",
			   ) {
				watch(ui, 0 if watching else ui.menu_user)
			}
		} else {
			icon_button(
				ui,
				"watch",
				.Screen,
				"Sharing their screen (watch in a browser)",
				theme.dim,
			)
		}
	}
	// Anyone can be messaged.
	if .SUBMIT in icon_button(ui, "message", .Send, "Write to them") {
		open_conversation(ui, account)
		mu.get_current_container(ctx).open = false
	}
	if can_call && .SUBMIT in icon_button(ui, "call", .Phone, "Call") {
		call_account(ui, account)
		mu.get_current_container(ctx).open = false
	}
	if can_video_call && .SUBMIT in icon_button(ui, "video call", .Camera, "Video call") {
		call_account(ui, account, video = true)
		mu.get_current_container(ctx).open = false
	}
	if .SUBMIT in
	   icon_button(
		   ui,
		   "buddy",
		   .Remove_Buddy if buddy else .Buddies,
		   "Remove buddy" if buddy else "Add as buddy",
	   ) {
		if ui.session != nil {
			conn.push_command(
				&ui.session.client.commands,
				conn.Buddy_Command{account = account, on = !buddy},
			)
		}
		log.debugf("ui: %s %s", name, "is no longer a buddy" if buddy else "is a buddy now")
	}

	if talking_to {
		mu.layout_row(ctx, {60, MENU_WIDTH - 60 - ctx.style.spacing})
		mu.label(ctx, "Volume")
		if .CHANGE in
		   slider(ctx, &ui.menu_volume, 0, settings.MAX_USER_VOLUME * 100, 5, "%.0f%%") {
			u.volume = ui.menu_volume / 100
			changed = true
		}
	}

	moderation_items(ui, account, clicked if clicked_here else {})

	if changed {
		settings.set_user_settings(&ui.settings, v.server_key, account, u)
		shared_user_changed(ui, account, u)
		ui.settings_dirty = true
		log.debugf("ui: %s volume %.0f%%%s", name, u.volume * 100, " (muted)" if u.muted else "")
		if ui.session != nil {
			conn.push_command(
				&ui.session.client.commands,
				conn.Gain_Command{account, settings.user_gain(u)},
			)
		}
	}
}

// moderation_items is the part of the user menu for moderators, apart from
// the rest so that muting for everyone isn't mistaken for muting for
// ourselves: mute or unmute them for everyone (Mute_Members), and, for the
// connection that was clicked while it is in a channel's voice room here,
// move it to another room or out of voice (Move_Members). The rooms to move
// to are the ones we may talk in ourselves (D5). The server checks all of it
// again, including that we outrank them. Call with the View locked, inside
// the menu.
@(private = "file")
moderation_items :: proc(ui: ^UI, account: proto.Account_Id, clicked: conn.View_User) {
	ctx := &ui.ctx
	v := ui.view
	acc, known := v.accounts[account]
	if !known || acc.flags & {.Owner, .Bot} != {} {
		return
	}
	can_mute := .Mute_Members in v.permissions
	room := clicked.room
	can_move := .Move_Members in v.permissions && room != 0 && proto.room_call(room) == 0
	can_ban := .Ban_Members in v.permissions
	can_purge := .Purge in v.permissions
	if !can_mute && !can_move && !can_ban && !can_purge {
		return
	}
	close :: proc(ctx: ^mu.Context) {
		mu.get_current_container(ctx).open = false
	}
	mu.layout_row(ctx, {MENU_WIDTH})
	dim_label(ctx, "Moderation")
	if can_mute {
		muted := .Server_Muted in acc.flags
		label := "Unmute for everyone" if muted else "Mute for everyone"
		if .SUBMIT in stable_button(ctx, "server mute", label) {
			command(ui, conn.Voice_Mute_Command{account = account, on = !muted})
		}
	}
	if can_move {
		move_items(ui, account, room)
	}
	if can_ban {
		bans_ask(ui, v) // to know whether they are banned
	}
	if can_ban && ban_items(ui, account, MENU_WIDTH) {
		close(ctx)
	}
	if can_purge && remove_items(ui, account, MENU_WIDTH) {
		close(ctx)
	}
}

// move_items is the moving part of moderation_items: Move to..., which opens
// the list of rooms, and Disconnect from voice. Call with the View locked,
// inside the menu.
@(private = "file")
move_items :: proc(ui: ^UI, account: proto.Account_Id, room: proto.Room) {
	ctx := &ui.ctx
	v := ui.view
	close :: proc(ctx: ^mu.Context) {
		mu.get_current_container(ctx).open = false
	}
	if .SUBMIT in stable_button(ctx, "move", "Move to..." if !ui.menu_moving else "Move to:") {
		ui.menu_moving = !ui.menu_moving
	}
	if ui.menu_moving {
		listed := false
		for ch in v.channels {
			if ch.id == proto.Conv_Id(room) || .Voice not_in ch.rights {
				continue
			}
			listed = true
			mu.push_id(ctx, uintptr(ch.id))
			pressed := .SUBMIT in stable_button(ctx, "room", fmt.tprintf("  # %s", ch.name))
			mu.pop_id(ctx)
			if pressed {
				command(ui, conn.Voice_Move_Command{account = account, room = proto.Room(ch.id)})
				close(ctx)
			}
		}
		if !listed {
			dim_label(ctx, "  No other room you can talk in")
		}
	}
	if .SUBMIT in stable_button(ctx, "disconnect", "Disconnect from voice") {
		command(ui, conn.Voice_Move_Command{account = account, room = 0})
		close(ctx)
	}
}

// apply_gains gives the session the per-user volumes that are kept for its
// server, once the handshake has said which server that is. Call with the View
// locked.
apply_gains :: proc(ui: ^UI) {
	v := ui.view
	if ui.session == nil || v.server_key == {} || ui.gains_for == v.server_key {
		return
	}
	ui.gains_for = v.server_key
	for k, u in ui.settings.users {
		if server, account, ok := settings.parse_server_key(k); ok && server == v.server_key {
			conn.push_command(
				&ui.session.client.commands,
				conn.Gain_Command{proto.Account_Id(account), settings.user_gain(u)},
			)
		}
	}
}

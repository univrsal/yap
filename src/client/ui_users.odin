package client

import log "common:wlog"
import "core:fmt"
import "core:slice"
import "core:strings"
import mu "vendor:microui"

import "client:conn"
import "client:render"
import "client:settings"
import "common:proto"

/*
Per-user playback settings: clicking (left or right) on another user in
the channel list opens a small menu to mute them or change their volume,
for you only. Settings are kept by the server's key and the account in
settings.json (names can be copied, and are the same on many servers;
that can't be) and applied to every connection of the account (see
user_settings / Gain_Command). The same menu adds or removes a buddy and
opens a DM with them.
*/

@(private = "file")
MENU :: "user menu"
@(private = "file")
MENU_WIDTH :: 240

// status_icon fills the column in front of a name (here and in the
// buddy list).
status_icon :: proc(ctx: ^mu.Context, icon: render.Icon, color: mu.Color) {
	mu.draw_icon(ctx, render.icon_id(icon), mu.layout_next(ctx), color)
}

// What the icon in front of your own name says, most to least telling:
// deafened hears nobody, muted says nothing to anybody. This is the one
// state we don't wait for the server to tell us about.
@(private = "file")
my_status :: proc(ui: ^UI, speaking: bool) -> (render.Icon, mu.Color) {
	return sound_status(ui.muted, ui.deafened, speaking)
}

// And the same for somebody else, from what the server passed on.
// (Used by the voice panel for the other side of a call, too.)
their_status :: proc(user: conn.View_User, speaking: bool) -> (render.Icon, mu.Color) {
	return sound_status(user.muted, user.deafened, speaking)
}

@(private = "file")
sound_status :: proc(muted, deafened, speaking: bool) -> (render.Icon, mu.Color) {
	switch {
	case deafened:
		// Somebody who isn't listening is usually muted as well, and of
		// the two that's the one worth showing.
		return .Sound_Off, OFF_COLOR
	case muted:
		return .Mic_Off, OFF_COLOR
	case speaking:
		return .Mic, SPEAKING_COLOR
	}
	return .Mic, DIM_COLOR
}

/*
The mark at the end of a row for somebody muted for ourselves. It sits
at the other end from the icon in front on purpose: that one is what the
user has switched off, this one is what we've done to them, and the two
would otherwise be easy to mix up.
*/
@(private = "file")
local_mute_mark :: proc(ctx: ^mu.Context, row: mu.Rect) {
	mu.draw_icon(ctx, render.icon_id(.Sound_Off), end_of_row(row, 0), DIM_COLOR)
}

// end_of_row is the icon-sized square `slot` places in from a row's end.
@(private = "file")
end_of_row :: proc(row: mu.Rect, slot: i32) -> mu.Rect {
	x := row.x + row.w - render.ICON_SIZE - slot * (render.ICON_SIZE + 4)
	return {x, row.y + (row.h - render.ICON_SIZE) / 2, render.ICON_SIZE, render.ICON_SIZE}
}

/*
The mark for somebody sharing their screen, at the end of the row (in
front of a local mute mark): lit while we're watching them. It's also a
button for watching, where the browser can.
*/
@(private = "file")
sharing_mark :: proc(ui: ^UI, row: mu.Rect, slot: i32, id: proto.User_Num) -> mu.Rect {
	ctx := &ui.ctx
	r := end_of_row(row, slot)
	color := ctx.style.colors[.TEXT]
	switch {
	case ui.view.watching == id:
		color = SPEAKING_COLOR
	case !conn.video_can_watch() || id == ui.view.my_num:
		color = DIM_COLOR
	}
	mu.draw_icon(ctx, render.icon_id(.Screen), r, color)
	return r
}

/*
The mark for somebody whose audio still comes through while they're
muted, at the end of the row (in front of the others): that can only be
an application they're sharing (ui_app_audio_native.odin), since muting
stops the microphone. Without it, all there is to see is a crossed-out
microphone, however much is being heard. Dim for somebody we've muted
for ourselves, whom we don't hear either way.
*/
@(private = "file")
app_audio_mark :: proc(ctx: ^mu.Context, row: mu.Rect, slot: i32, heard: bool) {
	mu.draw_icon(
		ctx,
		render.icon_id(.App_Audio),
		end_of_row(row, slot),
		SPEAKING_COLOR if heard else DIM_COLOR,
	)
}

@(private = "file")
inside :: proc(r: mu.Rect, p: mu.Vec2) -> bool {
	return p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h
}

/*
member_row draws one user in the channel list, with an icon in front
saying what they're up to, their picture, and dimmed after their name
their status (clicking our own row sets ours): a microphone, lit while they're speaking, and
for you the mute and deafen you've set. Marks at the end of the row say
who's sharing their screen, or an application's audio while muted
(app_audio_mark). Other users are clickable.

The icon in front is the user's own doing: a crossed-out microphone
where they've muted themselves, a crossed-out speaker where they've
stopped listening. Muting somebody for ourselves is a different thing
entirely, so it's marked at the other end of the row instead.
*/
member_row :: proc(ui: ^UI, id: proto.User_Num) {
	ctx := &ui.ctx
	v := &ui.view

	pic := ctx.text_height(ctx.style.font) + 2
	mu.layout_row(ctx, {render.ICON_SIZE + 4, pic + 4, -1})

	user, known := v.users[id]
	if !known {
		status_icon(ctx, .Mic, DIM_COLOR)
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
		// Green while we're heard, muted or not, as for everybody else.
		name_and_status(
			ctx,
			r,
			text,
			SPEAKING_COLOR if speaking else ctx.style.colors[.TEXT],
			status_line(acc),
		)
		slot: i32 = 0
		if user.sharing {
			sharing_mark(ui, ctx.last_rect, slot, id)
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
	icon, icon_color := their_status(user, speaking)
	status_icon(ctx, icon, icon_color)
	cell := mu.layout_next(ctx)
	avatar(ui, user.account, {cell.x, cell.y + (cell.h - pic) / 2, pic, pic})
	color := ctx.style.colors[.TEXT]
	switch {
	case u.muted:
		color = DIM_COLOR // nothing of theirs is reaching us
	case speaking:
		color = SPEAKING_COLOR
	}

	// A flat, full-width control: highlighted on hover, any click opens
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
	if speaking && user.muted {
		app_audio_mark(ctx, r, slot, !u.muted)
	}

	if ctx.hover_id == cid && ctx.mouse_pressed_bits & {.LEFT, .RIGHT} != {} {
		// A click on the screen mark watches them, or stops watching.
		if user.sharing &&
		   ctx.mouse_pressed_bits == {.LEFT} &&
		   conn.video_can_watch() &&
		   inside(share_r, ctx.mouse_pos) {
			watch(ui, 0 if v.watching == id else id)
			return
		}
		open_user_menu(ui, id, user.account)
	}
}

// open_user_menu opens the menu for an account, and the connection `num`
// of it that was clicked (0 for one from the buddy list, who may not be
// here). Call with the View locked.
open_user_menu :: proc(ui: ^UI, num: proto.User_Num, account: proto.Account_Id) {
	u := settings.user_settings(&ui.settings, ui.view.server_key, account)
	ui.menu_user = num
	ui.menu_account = account
	ui.menu_volume = u.volume * 100
	// Opened by user_menu: microui scopes container names by the id
	// stack, and the row it's opened from is nested in ids the menu isn't.
	ui.menu_requested = true
}

// How someone else is, in their card.
@(private = "file")
SEEN_AS := [proto.Activity]string {
	.Online  = "online",
	.Away    = "away",
	.Busy    = "busy",
	.Offline = "offline",
}

/*
user_card is the top of the user menu: who the account is. Call with
the View locked, inside the menu.
*/
@(private = "file")
user_card :: proc(ui: ^UI, account: proto.Account_Id, acc: conn.View_Account) {
	ctx := &ui.ctx
	v := &ui.view
	PICTURE :: 44
	line := ctx.text_height(ctx.style.font)
	mu.layout_row(ctx, {PICTURE, -1}, PICTURE)
	avatar(ui, account, mu.layout_next(ctx))
	r := mu.layout_next(ctx)
	color, colored := name_color(v, account)
	if !colored {
		color = ctx.style.colors[.TEXT]
	}
	font := ctx.style.font
	top := r.y + (r.h - 2 * line - 2) / 2
	mu.draw_text(ctx, font, acc.display, {r.x, top}, color)
	mu.draw_text(
		ctx,
		font,
		fmt.tprintf("@%s, %s", acc.username, SEEN_AS[acc.activity]),
		{r.x, top + line + 2},
		DIM_COLOR,
	)
	if status := status_line(acc); status != "" {
		mu.layout_row(ctx, {-1})
		with_text_color(ctx, ctx.style.colors[.TEXT], status, label_proc)
	}
	if len(acc.roles) > 0 {
		role_chips(ui, acc.roles, MENU_WIDTH)
	}
	if invited := invited_by_line(ui, v, account); invited != "" {
		mu.layout_row(ctx, {-1})
		with_text_color(ctx, DIM_COLOR, invited, label_proc)
	}
}

// user_menu shows the menu for ui.menu_account while it's open.
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

	// Keep the menu inside the window when opened near an edge. (.CLOSED:
	// only look it up; get_container would otherwise create it, open.)
	if cnt := mu.get_container(ctx, MENU, {.CLOSED}); cnt != nil && cnt.open {
		w, h := i32(ui.metrics.logical_w), i32(ui.metrics.logical_h)
		cnt.rect.x = clamp(cnt.rect.x, 0, max(w - cnt.rect.w, 0))
		cnt.rect.y = clamp(cnt.rect.y, 0, max(h - cnt.rect.h, 0))
	}
	if !mu.begin_popup(ctx, MENU) {
		return
	}
	defer mu.end_popup(ctx)

	v := &ui.view
	account := ui.menu_account
	u := settings.user_settings(&ui.settings, v.server_key, account)
	changed := false

	// What the account is called; whether one of its connections is here
	// (the one clicked, if it was one); and whether it's a buddy.
	name := fmt.tprintf("account #%d", account)
	if acc, ok := v.accounts[account]; ok {
		name = acc.display
		// Nothing to do with what's left of a deleted account.
		if .Deleted in acc.flags {
			mu.layout_row(ctx, {MENU_WIDTH})
			mu.label(ctx, name)
			with_text_color(ctx, DIM_COLOR, "This account was deleted.", label_proc)
			return
		}
	}
	here := false
	clicked, clicked_here := v.users[ui.menu_user]
	clicked_here = clicked_here && clicked.account == account
	for _, user in v.users {
		here ||= user.account == account
	}
	buddy := slice.contains(v.buddies[:], account)
	user_is_screen_sharing := clicked_here && clicked.sharing

	// Who they are: their picture, their name in their roles' colour,
	// their username and how they are; their status; their roles.
	if acc, ok := v.accounts[account]; ok {
		user_card(ui, account, acc)
	}

	widths := make([dynamic]i32, context.temp_allocator)
	append(&widths, 0, ICON_BUTTON, ICON_BUTTON, ICON_BUTTON)
	if user_is_screen_sharing {
		append(&widths, ICON_BUTTON)
	}
	widths[0] = i32(MENU_WIDTH) - ICON_BUTTON * i32(len(widths) - 1)
	mu.layout_row(ctx, widths[:])

	mu.label(ctx, "")
	if .SUBMIT in
	   icon_button(
		   ui,
		   "mute",
		   .Mic_Off if u.muted else .Mic,
		   "Unmute" if u.muted else "Mute for me",
	   ) {
		u.muted = !u.muted
		changed = true
	}

	// Watch their screen, if they're sharing it (the connection clicked).
	if user_is_screen_sharing {
		if conn.video_can_watch() {
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
				DIM_COLOR,
			)
		}
	}
	// Anyone can be written to.
	if .SUBMIT in icon_button(ui, "message", .Send, "Write to them") {
		open_conversation(ui, account)
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

	if may_call(v, account) {
		mu.layout_row(ctx, {MENU_WIDTH})
		if .SUBMIT in stable_button(ctx, "call", "Call", {.ALIGN_CENTER}) {
			call_account(ui, account)
			mu.get_current_container(ctx).open = false
		}
	}

	mu.layout_row(ctx, {60, MENU_WIDTH - 60 - ctx.style.spacing})
	mu.label(ctx, "Volume")
	if .CHANGE in mu.slider(ctx, &ui.menu_volume, 0, settings.MAX_USER_VOLUME * 100, 5, "%.0f%%") {
		u.volume = ui.menu_volume / 100
		changed = true
	}

	// Poke them, with a message if there's one in the box. Not ourselves,
	// and only a connection that's here.
	if clicked_here {
		mu.layout_row(ctx, {MENU_WIDTH - 60 - ctx.style.spacing, 60})
		poke := .SUBMIT in text_box(ui, ui.poke_buf[:], &ui.poke_len)
		if .SUBMIT in stable_button(ctx, "poke", "Poke") {
			poke = true
		}
		if poke && ui.session != nil {
			text := strings.trim_space(string(ui.poke_buf[:ui.poke_len]))
			conn.push_command(
				&ui.session.client.commands,
				conn.Poke_Command{target_uid = ui.menu_user, message = strings.clone(text)},
			)
			ui.poke_len = 0
		}
	}

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

// apply_gains gives the session the per-user volumes kept for its
// server, once the handshake has said which server that is. Call with
// the View locked.
apply_gains :: proc(ui: ^UI) {
	v := &ui.view
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

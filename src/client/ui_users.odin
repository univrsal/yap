package client

import log "../common/wlog"
import "core:fmt"
import "core:strings"
import mu "vendor:microui"

import "../proto"

/*
Per-user playback settings: clicking (left or right) on another user in
the channel list opens a small menu to mute them or change their volume,
for you only. Settings are kept by public key in settings.json (names
can be copied, keys can't) and applied to every connection (see
user_settings / Gain_Command).
*/

@(private = "file")
MENU :: "user menu"
@(private = "file")
MENU_WIDTH :: 240

// status_icon fills the column in front of a name (here and in the
// buddy list).
status_icon :: proc(ctx: ^mu.Context, icon: Icon, color: mu.Color) {
	mu.draw_icon(ctx, icon_id(icon), mu.layout_next(ctx), color)
}

// What the icon in front of your own name says, most to least telling:
// deafened hears nobody, muted says nothing to anybody. This is the one
// state we don't wait for the server to tell us about.
@(private = "file")
my_status :: proc(ui: ^UI, speaking: bool) -> (Icon, mu.Color) {
	return sound_status(ui.muted, ui.deafened, speaking)
}

// And the same for somebody else, from what the server passed on.
@(private = "file")
their_status :: proc(user: View_User, speaking: bool) -> (Icon, mu.Color) {
	return sound_status(user.muted, user.deafened, speaking)
}

@(private = "file")
sound_status :: proc(muted, deafened, speaking: bool) -> (Icon, mu.Color) {
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
	mu.draw_icon(ctx, icon_id(.Sound_Off), end_of_row(row, 0), DIM_COLOR)
}

// end_of_row is the icon-sized square `slot` places in from a row's end.
@(private = "file")
end_of_row :: proc(row: mu.Rect, slot: i32) -> mu.Rect {
	x := row.x + row.w - ICON_SIZE - slot * (ICON_SIZE + 4)
	return {x, row.y + (row.h - ICON_SIZE) / 2, ICON_SIZE, ICON_SIZE}
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
	case !video_can_watch() || id == ui.view.my_num:
		color = DIM_COLOR
	}
	mu.draw_icon(ctx, icon_id(.Screen), r, color)
	return r
}

/*
The mark for somebody whose audio still comes through while they're
muted, at the end of the row (in front of the others): that can only be
an application they're sharing (app_audio_native.odin), since muting
stops the microphone. Without it, all there is to see is a crossed-out
microphone, however much is being heard. Dim for somebody we've muted
for ourselves, whom we don't hear either way.
*/
@(private = "file")
app_audio_mark :: proc(ctx: ^mu.Context, row: mu.Rect, slot: i32, heard: bool) {
	mu.draw_icon(
		ctx,
		icon_id(.App_Audio),
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
saying what they're up to: a microphone, lit while they're speaking, and
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

	mu.layout_row(ctx, {ICON_SIZE + 4, -1})

	user, known := v.users[id]
	if !known {
		status_icon(ctx, .Mic, DIM_COLOR)
		mu.label(ctx, fmt.tprintf("user #%d", id))
		return
	}
	if id == v.my_num {
		speaking := is_speaking(v, id)
		icon, color := my_status(ui, speaking)
		status_icon(ctx, icon, color)
		text := fmt.tprintf("%s (you)", user.name)
		// Green while we're heard, muted or not, as for everybody else.
		if speaking {
			with_text_color(ctx, SPEAKING_COLOR, text, label_proc)
		} else {
			mu.label(ctx, text)
		}
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

	u := user_settings(&ui.settings, user.key)
	text := user.name
	if u.volume != 1 && !u.muted {
		text = fmt.tprintf("%s  (%.0f%%)", text, u.volume * 100)
	}
	speaking := is_speaking(v, id)
	icon, icon_color := their_status(user, speaking)
	status_icon(ctx, icon, icon_color)
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
	saved := ctx.style.colors[.TEXT]
	ctx.style.colors[.TEXT] = color
	mu.draw_control_text(ctx, text, r, .TEXT)
	ctx.style.colors[.TEXT] = saved
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
		   video_can_watch() &&
		   inside(share_r, ctx.mouse_pos) {
			watch(ui, 0 if v.watching == id else id)
			return
		}
		ui.menu_user = id
		ui.menu_key = user.key
		ui.menu_volume = u.volume * 100
		// Opened by user_menu: microui scopes container names by the id
		// stack, and this row is nested in ids the menu isn't.
		ui.menu_requested = true
	}
}

// user_menu shows the menu for ui.menu_user while it's open.
user_menu :: proc(ui: ^UI) {
	ctx := &ui.ctx
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

	key := ui.menu_key
	u := user_settings(&ui.settings, key)
	changed := false

	// The name as currently shown, or as saved for a buddy who isn't
	// here, or else the key. (Opened from the buddy list, menu_user is 0
	// for someone who isn't on the server.)
	name := fingerprint(key)
	here := false
	if user, ok := ui.view.users[ui.menu_user]; ok && user.key == key {
		name, here = user.name, true
	} else if b, is := ui.settings.buddies[user_key(key)]; is && b.name != "" {
		name = b.name
	}
	myself := here && ui.menu_user == ui.view.my_num
	mu.layout_row(ctx, {MENU_WIDTH})
	mu.label(ctx, name)
	mu.layout_row(ctx, {MENU_WIDTH})
	with_text_color(ctx, DIM_COLOR, fmt.tprintf("key %s...", user_key(key)[:16]), label_proc)

	mu.layout_row(ctx, {MENU_WIDTH})
	if .SUBMIT in stable_button(ctx, "mute", "Unmute" if u.muted else "Mute for me") {
		u.muted = !u.muted
		changed = true
	}

	mu.layout_row(ctx, {60, MENU_WIDTH - 60 - ctx.style.spacing})
	mu.label(ctx, "Volume")
	if .CHANGE in mu.slider(ctx, &ui.menu_volume, 0, MAX_USER_VOLUME * 100, 5, "%.0f%%") {
		u.volume = ui.menu_volume / 100
		changed = true
	}

	mu.layout_row(ctx, {MENU_WIDTH})
	if .SUBMIT in stable_button(ctx, "reset", "Reset") {
		u = DEFAULT_USER
		ui.menu_volume = 100
		changed = true
	}

	// Watch their screen, if they're sharing it.
	if user, ok := ui.view.users[ui.menu_user];
	   ok && user.key == key && user.sharing && ui.menu_user != ui.view.my_num {
		mu.layout_row(ctx, {MENU_WIDTH})
		if video_can_watch() {
			watching := ui.view.watching == ui.menu_user
			if .SUBMIT in
			   stable_button(ctx, "watch", "Stop watching" if watching else "Watch their screen") {
				watch(ui, 0 if watching else ui.menu_user)
			}
		} else {
			with_text_color(
				ctx,
				DIM_COLOR,
				"Sharing their screen (watch in a browser)",
				label_proc,
			)
		}
	}

	// Keep them as a buddy, or stop. Not ourselves.
	if !myself {
		mu.layout_row(ctx, {MENU_WIDTH})
		if is_buddy(&ui.settings, key) {
			if .SUBMIT in stable_button(ctx, "message", "Open conversation") {
				open_conversation(ui, key)
				mu.get_current_container(ctx).open = false
			}
			mu.layout_row(ctx, {MENU_WIDTH})
			if .SUBMIT in stable_button(ctx, "buddy", "Remove buddy") {
				remove_buddy(&ui.settings, key)
				ui.settings_dirty = true
				log.debugf("ui: %s is no longer a buddy", name)
			}
		} else if .SUBMIT in stable_button(ctx, "buddy", "Add as buddy") {
			add_buddy(&ui.settings, key, name if here else "")
			ui.settings_dirty = true
			log.debugf("ui: %s is a buddy now", name)
		}
	}

	// Poke them, with a message if there's one in the box. Not ourselves,
	// and only someone who's here.
	if here && !myself {
		mu.layout_row(ctx, {MENU_WIDTH - 60 - ctx.style.spacing, 60})
		poke := .SUBMIT in text_box(ui, ui.poke_buf[:], &ui.poke_len)
		if .SUBMIT in stable_button(ctx, "poke", "Poke") {
			poke = true
		}
		if poke && ui.session != nil {
			text := strings.trim_space(string(ui.poke_buf[:ui.poke_len]))
			push_command(
				&ui.session.client.commands,
				Poke_Command{target_uid = ui.menu_user, message = strings.clone(text)},
			)
			ui.poke_len = 0
		}
	}

	if changed {
		set_user_settings(&ui.settings, key, u)
		ui.settings_dirty = true
		log.debugf("ui: %s volume %.0f%%%s", name, u.volume * 100, " (muted)" if u.muted else "")
		if ui.session != nil {
			push_command(&ui.session.client.commands, Gain_Command{key, user_gain(u)})
		}
	}
}

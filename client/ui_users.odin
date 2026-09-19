package client

import "core:fmt"
import "core:log"
import mu "vendor:microui"

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

@(private = "file")
SPEAKING_COLOR :: mu.Color{110, 220, 110, 255}
@(private = "file")
DIM_COLOR :: mu.Color{140, 140, 140, 255}

// member_row draws one user in the channel list; other users are clickable.
member_row :: proc(ui: ^UI, id: u32) {
	ctx := &ui.ctx
	v := &ui.view

	mu.layout_row(ctx, {20, -1})
	mu.label(ctx, "")

	user, known := v.users[id]
	if !known {
		mu.label(ctx, fmt.tprintf("user #%d", id))
		return
	}
	if id == v.my_num {
		text := fmt.tprintf("%s (you)", user.name)
		if is_speaking(v, id) {
			with_text_color(ctx, SPEAKING_COLOR, fmt.tprintf("%s  speaking", text), label_proc)
		} else {
			mu.label(ctx, text)
		}
		return
	}

	u := user_settings(&ui.settings, user.key)
	text := user.name
	switch {
	case u.muted:
		text = fmt.tprintf("%s  (muted)", text)
	case u.volume != 1:
		text = fmt.tprintf("%s  (%.0f%%)", text, u.volume * 100)
	}
	color := ctx.style.colors[.TEXT]
	switch {
	case u.muted:
		color = DIM_COLOR
	case is_speaking(v, id):
		text = fmt.tprintf("%s  speaking", text)
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

	if ctx.hover_id == cid && ctx.mouse_pressed_bits & {.LEFT, .RIGHT} != {} {
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

	// The name as currently shown, or the key if they've left meanwhile.
	name := fingerprint(key)
	if user, ok := ui.view.users[ui.menu_user]; ok && user.key == key {
		name = user.name
	}
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

	if changed {
		set_user_settings(&ui.settings, key, u)
		ui.settings_dirty = true
		log.debugf("ui: %s volume %.0f%%%s", name, u.volume * 100, " (muted)" if u.muted else "")
		if ui.session != nil {
			push_command(&ui.session.client.commands, Gain_Command{key, user_gain(u)})
		}
	}
}

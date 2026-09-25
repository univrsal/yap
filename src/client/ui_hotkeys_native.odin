#+build !wasi
package client

import log "../common/wlog"
import "core:fmt"
import mu "vendor:microui"

import "hotkeys"
import glfw "wglfw"

/*
Global hotkeys for mute and deafen (see the hotkeys package), and their
section of the settings page, where a hotkey is set by pressing it.

The keyboard is only watched while there's a hotkey to watch for (or one
being set): nobody who doesn't use them has yap looking at every key,
or reading /dev/input on Linux. The watcher wakes the UI when a hotkey
fires, so it's acted on at once even with the window hidden in the tray.
*/

Hotkey_Action :: enum {
	Mute,
	Deafen,
}

UI_Hotkeys :: struct {
	watcher:   hotkeys.Watcher,
	running:   bool,
	// The action whose hotkey the next key pressed becomes.
	capturing: Maybe(Hotkey_Action),
}

@(private = "file")
HOTKEY_LABELS := [Hotkey_Action]string {
	.Mute   = "Mute",
	.Deafen = "Deafen",
}

@(private = "file")
hotkey_setting :: proc(ui: ^UI, action: Hotkey_Action) -> ^string {
	switch action {
	case .Mute:
		return &ui.settings.mute_hotkey
	case .Deafen:
		return &ui.settings.deafen_hotkey
	}
	return nil
}

// bound is an action's hotkey, as the settings have it.
@(private = "file")
bound :: proc(ui: ^UI, action: Hotkey_Action) -> hotkeys.Hotkey {
	h, _ := hotkeys.parse(hotkey_setting(ui, action)^)
	return h
}

/*
hotkeys_frame acts on the hotkeys pressed since the last frame, takes a
hotkey being set, and starts or stops watching the keyboard as there
are hotkeys to watch for. Call it every frame, window or no window.
*/
hotkeys_frame :: proc(ui: ^UI) {
	hk := &ui.hotkeys
	w := &hk.watcher

	wanted := hk.capturing != nil
	for action in Hotkey_Action {
		wanted ||= bound(ui, action).key != .None
	}
	switch {
	case wanted && !hk.running:
		for action in Hotkey_Action {
			hotkeys.set_bind(w, int(action), bound(ui, action))
		}
		hotkeys.start(w, glfw.PostEmptyEvent)
		hk.running = true
		log.debug("hotkeys: watching the keyboard")
	case !wanted && hk.running:
		hotkeys_stop(ui)
		log.debug("hotkeys: stopped watching the keyboard")
	}
	if !hk.running {
		return
	}

	fired := hotkeys.take_fired(w)
	if fired & (1 << uint(Hotkey_Action.Mute)) != 0 {
		set_muted(ui, !ui.muted)
		log.infof("hotkey: %s", "muted" if ui.muted else "unmuted")
	}
	if fired & (1 << uint(Hotkey_Action.Deafen)) != 0 {
		set_deafened(ui, !ui.deafened)
		log.infof("hotkey: %s", "deafened" if ui.deafened else "undeafened")
	}

	if action, capturing := hk.capturing.?; capturing {
		if h, ok := hotkeys.take_captured(w); ok {
			set_hotkey(ui, action, h)
			hk.capturing = nil
		}
	}
}

hotkeys_stop :: proc(ui: ^UI) {
	hk := &ui.hotkeys
	if hk.running {
		hotkeys.stop(&hk.watcher)
		// A fresh one next time, without what the last one saw.
		hk.watcher = {}
		hk.running = false
	}
}

// set_hotkey binds `h` to `action`, taking it from the other action if
// it had it, and saves it.
@(private = "file")
set_hotkey :: proc(ui: ^UI, action: Hotkey_Action, h: hotkeys.Hotkey) {
	text := hotkeys.format(h, context.temp_allocator)
	for other in Hotkey_Action {
		if other != action && h.key != .None && bound(ui, other) == h {
			set_setting(hotkey_setting(ui, other), "")
			hotkeys.set_bind(&ui.hotkeys.watcher, int(other), {})
		}
	}
	set_setting(hotkey_setting(ui, action), text)
	settings_save(ui.opts.settings_path, ui.settings)
	hotkeys.set_bind(&ui.hotkeys.watcher, int(action), h)
	log.infof("%s hotkey: %s", HOTKEY_LABELS[action], text if text != "" else "none")
}

// hotkey_settings is the settings page's section for them.
hotkey_settings :: proc(ui: ^UI) {
	ctx := &ui.ctx
	hk := &ui.hotkeys
	if !header(ctx, "Global hotkeys", {.EXPANDED}) {
		return
	}

	for action in Hotkey_Action {
		mu.push_id(ctx, uintptr(action))
		defer mu.pop_id(ctx)

		mu.layout_row(ctx, {60, 200, 80, 60})
		mu.label(ctx, HOTKEY_LABELS[action])
		capturing := hk.capturing == action
		text := hotkey_setting(ui, action)^
		switch {
		case capturing:
			with_text_color(ctx, {230, 200, 90, 255}, "Press the keys...", label_proc)
		case text == "":
			with_text_color(ctx, DIM_COLOR, "None", label_proc)
		case:
			mu.label(ctx, text)
		}
		if .SUBMIT in stable_button(ctx, "change", "Cancel" if capturing else "Change") {
			if capturing {
				hk.capturing = nil
				hotkeys.capture(&hk.watcher, false)
			} else {
				hk.capturing = action
				// Picked up by the watcher, which hotkeys_frame starts for
				// it if need be; setting the flag before it runs is fine.
				hotkeys.capture(&hk.watcher, true)
			}
		}
		if .SUBMIT in stable_button(ctx, "clear", "Clear") && text != "" {
			set_hotkey(ui, action, {})
		}
	}

	mu.layout_row(ctx, {-1})
	if !hk.running {
		with_text_color(
			ctx,
			DIM_COLOR,
			"  These work in any window, and with yap minimized. Change one and press the keys for it.",
			label_proc,
		)
		return
	}
	st, message := hotkeys.status(&hk.watcher)
	note := fmt.tprintf("  %s", message)
	switch st {
	case .Starting, .Ok:
		with_text_color(ctx, DIM_COLOR, note, label_proc)
	case .Limited:
		with_text_color(ctx, {230, 200, 90, 255}, note, label_proc)
	case .Unavailable:
		with_text_color(ctx, {230, 90, 90, 255}, note, label_proc)
	}
}

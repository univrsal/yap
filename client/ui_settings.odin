package client

import log "../common/wlog"
import "core:fmt"
import mu "vendor:microui"

/*
The settings page: name, noise suppression, the voice gate (ui_gate.odin),
and choosing the microphone and the speakers/headphones. Changes are saved
right away (see settings.odin) and apply to a running connection.

Everything below the name row sits in one scrolling panel, grouped into
headers a person can collapse, so a short window (or one that isn't
interested in, say, the tray) still reaches every setting without
wading through all of them.
*/
settings_page :: proc(ui: ^UI) {
	ctx := &ui.ctx
	a := &ui.audio

	mu.layout_row(ctx, {-200, 90, -1})
	if a.ctx != nil {
		mu.label(ctx, fmt.tprintf("Audio devices (via %s)", a.backend))
	} else {
		mu.label(ctx, "Audio devices")
	}
	if .SUBMIT in mu.button(ctx, "Refresh") {
		log.debug("ui: refresh audio devices")
		audio_refresh(a)
	}
	if .SUBMIT in mu.button(ctx, "Back") {
		ui.page = .Main
	}

	mu.layout_row(ctx, {60, 200, 70, -1})
	mu.label(ctx, "Name")
	submitted := .SUBMIT in text_box(ui, ui.name_buf[:], &ui.name_len)
	if .SUBMIT in mu.button(ctx, "Apply") || submitted {
		apply_name(ui)
	}
	mu.label(ctx, "  what others see you as")

	if a.ctx == nil {
		mu.layout_row(ctx, {-1})
		with_text_color(ctx, {230, 90, 90, 255}, a.error, label_proc)
		return
	}

	mu.layout_row(ctx, {-1}, -1)
	mu.begin_panel(ctx, "settings_body")
	defer mu.end_panel(ctx)

	audio_settings(ui)
	ui_settings(ui)
}

// header opens a collapsible group of settings, expanded the first time
// it's shown; the result says whether the caller should draw the body.
// Package-private rather than file-private, so ui_gate.odin can use it
// for its own group.
@(private)
header :: proc(ctx: ^mu.Context, title: string, opts: mu.Options = {}) -> bool {
	return .ACTIVE in mu.header(ctx, title, opts)
}

// audio_settings picks the send quality preset (see quality.odin) and,
// outside the web build, whether the microphone gets denoised.
@(private = "file")
audio_settings :: proc(ui: ^UI) {
	ctx := &ui.ctx
	if !header(ctx, "Audio", {.EXPANDED}) {
		return
	}
	current := settings_quality(&ui.settings)

	mu.layout_row(ctx, {60, 90, 90, 90, -1})
	mu.label(ctx, "Quality")
	for preset, q in QUALITY_PRESETS {
		mark := "> " if q == current else "  "
		if .SUBMIT in stable_button(ctx, preset.name, fmt.tprintf("%s%s", mark, preset.label)) &&
		   q != current {
			set_setting(&ui.settings.quality, preset.name)
			settings_save(ui.opts.settings_path, ui.settings)
			if ui.session != nil {
				push_command(&ui.session.client.commands, Quality_Command{q})
			}
			current = q
		}
	}
	mu.label(ctx, fmt.tprintf("  %s", QUALITY_PRESETS[current].description))

	mu.layout_row(ctx, {-1})
	if !WEB && current != .Voice && ui.settings.noise_suppression {
		with_text_color(
			ctx,
			{230, 200, 90, 255},
			"  Noise suppression is made for speech and removes music; turn it off to send music.",
			label_proc,
		)
	} else {
		mu.label(ctx, "  Higher quality uses more bandwidth, not more latency.")
	}

	// The web build has no RNNoise yet (see web/audio_stub.c), so there's
	// nothing for the setting to turn on.
	when !WEB {
		mu.layout_row(ctx, {-1})
		if .CHANGE in
		   mu.checkbox(
			   ctx,
			   "Noise suppression (removes background noise from your microphone)",
			   &ui.settings.noise_suppression,
		   ) {
			settings_save(ui.opts.settings_path, ui.settings)
			if ui.session != nil {
				push_command(
					&ui.session.client.commands,
					Noise_Command{ui.settings.noise_suppression},
				)
			}
		}
	}
	gate_settings(ui)
	device_settings(ui)
}

@(private = "file")
ui_settings :: proc(ui: ^UI) {
	ctx := &ui.ctx
	if !header(ctx, "User interface", {.EXPANDED}) {
		return
	}
	volume := notification_gain(&ui.settings) * 100
	mu.layout_row(ctx, {120, -1})
	mu.label(ctx, "Notifications volume")
	if .CHANGE in mu.slider(ctx, &volume, 0, MAX_USER_VOLUME * 100, 5, "%.0f%%") {
		ui.settings.notification_volume = volume / 100
		settings_save(ui.opts.settings_path, ui.settings)
		if ui.session != nil {
			push_command(
				&ui.session.client.commands,
				Notification_Volume_Command{ui.settings.notification_volume},
			)
		}
	}

	when !WEB {
		mu.layout_row(ctx, {-1})
		if .CHANGE in
		   mu.checkbox(
			   ctx,
			   "Tray icon (shows whether you're talking, muted or deafened)",
			   &ui.settings.tray,
		   ) {
			settings_save(ui.opts.settings_path, ui.settings)
			tray_update(ui)
		}

		// What the window's own buttons do is only a question while there's
		// a tray to put it in.
		if !ui.settings.tray {
			return
		}

		mu.layout_row(ctx, {230, -1})
		if .CHANGE in mu.checkbox(ctx, "Close hides in tray", &ui.settings.close_to_tray) {
			settings_save(ui.opts.settings_path, ui.settings)
		}
		if .CHANGE in mu.checkbox(ctx, "Minimize hides in tray", &ui.settings.minimize_to_tray) {
			settings_save(ui.opts.settings_path, ui.settings)
		}
		// Only the desktop can tell us a window has been minimized, and
		// Wayland has no message for it, so say so rather than leave the
		// setting looking broken.
		if ui.settings.minimize_to_tray && on_wayland() {
			mu.layout_row(ctx, {-1})
			with_text_color(
				ctx,
				{230, 200, 90, 255},
				"  Wayland doesn't tell a window it has been minimized, so here it will just minimize.",
				label_proc,
			)
		}
	}
}

// device_settings shows the input and output pickers side by side, each
// filling the rest of the settings panel's height, so neither has to
// share the other's vertical space; either still scrolls on its own if
// its device list doesn't fit.
@(private = "file")
device_settings :: proc(ui: ^UI) {
	ctx := &ui.ctx
	a := &ui.audio
	if !header(ctx, "Devices") {
		return
	}

	half := (mu.get_current_container(ctx).body.w - ctx.style.spacing) / 2
	mu.layout_row(ctx, {half, -1}, -1)

	if mu.layout_column(ctx) {
		if choice, changed := device_list(
			ctx,
			"Input (microphone)",
			"inputs",
			a.inputs[:],
			ui.settings.input_device,
			-1,
		); changed {
			set_setting(&ui.settings.input_device, choice)
			settings_save(ui.opts.settings_path, ui.settings)
			log.infof("input device: %s", choice if choice != "" else "system default")
			reopen_audio(ui, true)
		}
	}
	if mu.layout_column(ctx) {
		if choice, changed := device_list(
			ctx,
			"Output (speakers / headphones)",
			"outputs",
			a.outputs[:],
			ui.settings.output_device,
			-1,
		); changed {
			set_setting(&ui.settings.output_device, choice)
			settings_save(ui.opts.settings_path, ui.settings)
			log.infof("output device: %s", choice if choice != "" else "system default")
			reopen_audio(ui, false)
		}
	}
}

// device_list shows "System default" plus every device, with `selected`
// (a device name, "" for the default) marked. It returns the new choice
// when one is clicked.
@(private = "file")
device_list :: proc(
	ctx: ^mu.Context,
	title, id: string,
	devices: []Audio_Device,
	selected: string,
	height: i32,
) -> (
	choice: string,
	changed: bool,
) {
	mu.layout_row(ctx, {-1})
	mu.label(ctx, title)

	mu.layout_row(ctx, {-1}, height)
	mu.begin_panel(ctx, id)
	defer mu.end_panel(ctx)

	// A saved device that isn't plugged in falls back to the default, so
	// the default is what's in effect; say so rather than hiding it.
	missing := selected != "" && find_device(devices, selected) == nil

	mu.layout_row(ctx, {-1})
	mark := "> " if selected == "" || missing else "  "
	if .SUBMIT in stable_button(ctx, "default", fmt.tprintf("%sSystem default", mark)) &&
	   selected != "" {
		choice, changed = "", true
	}
	if missing {
		mu.layout_row(ctx, {-1})
		with_text_color(
			ctx,
			{230, 200, 90, 255},
			fmt.tprintf("  %s is not available, using the default", selected),
			label_proc,
		)
	}

	for d, i in devices {
		mu.push_id(ctx, uintptr(i))
		defer mu.pop_id(ctx)
		mu.layout_row(ctx, {-1})
		mark = "> " if d.name == selected else "  "
		suffix := "  (current default)" if d.is_default else ""
		if .SUBMIT in stable_button(ctx, "device", fmt.tprintf("%s%s%s", mark, d.name, suffix)) &&
		   d.name != selected {
			choice, changed = d.name, true
		}
	}
	return
}

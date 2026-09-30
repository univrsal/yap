package client

import log "common:wlog"
import "core:fmt"
import mu "vendor:microui"
import "client:audio"
import "client:platform"
import "client:settings"
import "client:conn"

/*
The settings page: name, noise suppression, the voice gate (ui_gate.odin),
and choosing the microphone and the speakers/headphones. Changes are saved
right away (see settings/settings.odin) and apply to a running connection.

Everything below the name row sits in one scrolling panel, grouped into
tree nodes a person can collapse, so a short window (or one that isn't
interested in, say, the tray) still reaches every setting without
wading through all of them. The voice gate and the devices are nodes
inside Audio, and indented under it.
*/
settings_page :: proc(ui: ^UI) {
	ctx := &ui.ctx
	a := &ui.audio

	title_row(ui, {60, -230, 70, 70, 70})

	mu.label(ctx, "Name")
	submitted := .SUBMIT in text_box(ui, ui.name_buf[:], &ui.name_len)
	if .SUBMIT in mu.button(ctx, "Apply") || submitted {
		apply_name(ui)
	}

	if .SUBMIT in mu.button(ctx, "About") {
		open_about(ui)
	}
	if .SUBMIT in mu.button(ctx, "Back") {
		ui.page = .Main
	}

	mu.layout_row(ctx, {-1}, -1)
	mu.begin_panel(ctx, "settings_body")
	defer mu.end_panel(ctx)

	if a.ctx == nil {
		mu.layout_row(ctx, {-1})
		with_text_color(ctx, {230, 90, 90, 255}, a.error, label_proc)
	} else {
		audio_settings(ui)
	}

	ui_settings(ui)
	hotkey_settings(ui)
	transfer_settings(ui)
	trusted_servers_settings(ui)
	install_settings(ui)
}

// audio_settings picks the send quality preset (see audio/quality.odin),
// whether the microphone gets denoised, and whether muting it mutes a
// shared application too (ui_app_audio_native.odin).
@(private = "file")
audio_settings :: proc(ui: ^UI) {
	ctx := &ui.ctx
	if .ACTIVE not_in mu.begin_treenode(ctx, "Audio", {.EXPANDED}) {
		return
	}
	defer mu.end_treenode(ctx)
	current := settings.settings_quality(&ui.settings)
	mu.layout_row(ctx, {60, 90, 90, 90})
	mu.label(ctx, "Quality")
	for preset, q in audio.QUALITY_PRESETS {
		mark := "> " if q == current else "  "
		if .SUBMIT in
			   stable_button_hint(
				   ui,
				   preset.name,
				   fmt.tprintf("%s%s", mark, preset.label),
				   preset.description,
			   ) &&
		   q != current {
			settings.set_setting(&ui.settings.quality, preset.name)
			settings.settings_save(ui.opts.settings_path, ui.settings)
			if ui.session != nil {
				conn.push_command(&ui.session.client.commands, conn.Quality_Command{q})
			}
			current = q
		}
	}

	mu.layout_row(ctx, {-1})
	if .CHANGE in mu.checkbox(ctx, "Use RNN noise suppression", &ui.settings.noise_suppression) {
		settings.settings_save(ui.opts.settings_path, ui.settings)
		if ui.session != nil {
			conn.push_command(&ui.session.client.commands, conn.Noise_Command{ui.settings.noise_suppression})
		}
	}
	if app_audio_available(ui) {
		mu.layout_row(ctx, {-1})
		if .CHANGE in
		   mu.checkbox(
			   ctx,
			   "Mute audio sharing when microphone is muted",
			   &ui.settings.mute_app_audio_with_mic,
		   ) {
			settings.settings_save(ui.opts.settings_path, ui.settings)
			if ui.session != nil {
				conn.push_command(&ui.session.client.commands, conn.app_audio_command(&ui.settings))
			}
		}
	}
	gate_settings(ui)
	device_settings(ui)
}

@(private = "file")
ui_settings :: proc(ui: ^UI) {
	ctx := &ui.ctx
	if .ACTIVE not_in mu.begin_treenode(ctx, "User interface", {.EXPANDED}) {
		return
	}
	defer mu.end_treenode(ctx)
	mu.layout_row(ctx, {120, -1})
	mu.label(ctx, "UI scale")
	// Applying every change live would resize the window mid-drag, which
	// moves the slider out from under the pointer that's dragging it,
	// so ui.ui_scale_draft only reaches settings.ui_scale (and with it
	// window_metrics) once the drag lets go.
	id := mu.get_id(ctx, uintptr(&ui.ui_scale_draft))
	was_dragging := ctx.focus_id == id
	mu.slider(ctx, &ui.ui_scale_draft, settings.MIN_UI_SCALE * 100, settings.MAX_UI_SCALE * 100, 10, "%.0f%%")
	if was_dragging && ctx.focus_id != id {
		ui.settings.ui_scale = ui.ui_scale_draft / 100
		settings.settings_save(ui.opts.settings_path, ui.settings)
	}

	volume := settings.notification_gain(&ui.settings) * 100
	mu.layout_row(ctx, {120, -1})
	mu.label(ctx, "Notifications volume")
	if .CHANGE in mu.slider(ctx, &volume, 0, settings.MAX_USER_VOLUME * 100, 5, "%.0f%%") {
		ui.settings.notification_volume = volume / 100
		settings.settings_save(ui.opts.settings_path, ui.settings)
		if ui.session != nil {
			conn.push_command(
				&ui.session.client.commands,
				conn.Notification_Volume_Command{ui.settings.notification_volume},
			)
		}
	}

	when !platform.WEB {
		mu.layout_row(ctx, {-1})
		if .CHANGE in mu.checkbox(ctx, "Enable tray icon", &ui.settings.tray) {
			settings.settings_save(ui.opts.settings_path, ui.settings)
			tray_update(ui)
		}

		// What the window's own buttons do is only a question while there's
		// a tray to put it in.
		if !ui.settings.tray {
			return
		}

		mu.layout_row(ctx, {230, -1})
		if .CHANGE in mu.checkbox(ctx, "Close hides in tray", &ui.settings.close_to_tray) {
			settings.settings_save(ui.opts.settings_path, ui.settings)
		}
		if .CHANGE in mu.checkbox(ctx, "Minimize hides in tray", &ui.settings.minimize_to_tray) {
			settings.settings_save(ui.opts.settings_path, ui.settings)
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

// transfer_settings limits how fast files sent in DMs go out and come in.
@(private = "file")
transfer_settings :: proc(ui: ^UI) {
	ctx := &ui.ctx
	if .ACTIVE not_in mu.begin_treenode(ctx, "File transfers") {
		return
	}
	defer mu.end_treenode(ctx)

	changed := false
	mu.layout_row(ctx, {120, -1})
	mu.label(ctx, "Upload limit")
	changed |=
		.CHANGE in
		mu.slider(ctx, &ui.settings.upload_limit, 0, settings.MAX_TRANSFER_LIMIT, 0.5, "%.1f MB/s")
	mu.label(ctx, "Download limit")
	changed |=
		.CHANGE in
		mu.slider(ctx, &ui.settings.download_limit, 0, settings.MAX_TRANSFER_LIMIT, 0.5, "%.1f MB/s")
	mu.layout_row(ctx, {-1})
	with_text_color(
		ctx,
		DIM_COLOR,
		"  0 is no limit. A download limit also slows down whoever is sending.",
		label_proc,
	)
	if changed {
		// Sliders change every frame while dragged; saved within a second.
		ui.settings_dirty = true
		if ui.session != nil {
			conn.push_command(&ui.session.client.commands, conn.transfer_limits_command(&ui.settings))
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
	if .ACTIVE not_in mu.begin_treenode(ctx, fmt.tprintf("Audio devices (via %s)", a.backend)) {
		return
	}
	defer mu.end_treenode(ctx)
	mu.layout_row(ctx, {120})

	if .SUBMIT in mu.button(ctx, "Refresh device list") {
		log.debug("ui: refresh audio devices")
		audio.audio_refresh(a)
	}

	// The width left of the panel once the tree nodes have indented it.
	layout := mu.get_layout(ctx)
	half := (layout.body.w - layout.indent - ctx.style.spacing) / 2
	mu.layout_row(ctx, {half, -1}, 210)

	if mu.layout_column(ctx) {
		if choice, changed := device_list(
			ctx,
			"Input (microphone)",
			"inputs",
			a.inputs[:],
			ui.settings.input_device,
			200,
		); changed {
			settings.set_setting(&ui.settings.input_device, choice)
			settings.settings_save(ui.opts.settings_path, ui.settings)
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
			200,
		); changed {
			settings.set_setting(&ui.settings.output_device, choice)
			settings.settings_save(ui.opts.settings_path, ui.settings)
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
	devices: []audio.Audio_Device,
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
	missing := selected != "" && audio.find_device(devices, selected) == nil

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

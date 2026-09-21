package client

import "core:fmt"
import log "../common/wlog"
import mu "vendor:microui"

/*
The settings page: name, noise suppression, the voice gate (ui_gate.odin),
and choosing the microphone and the speakers/headphones. Changes are saved
right away (see settings.odin) and apply to a running connection.
*/
settings_page :: proc(ui: ^UI, height: i32) {
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

	quality_row(ui)

	// The web build has no RNNoise yet (see web/audio_stub.c), so there's
	// nothing for the setting to turn on.
	when !WEB {
		mu.layout_row(ctx, {-1})
		state := "on" if ui.settings.noise_suppression else "off"
		if .SUBMIT in
		   stable_button(
			   ctx,
			   "noise",
			   fmt.tprintf(
				   "Noise suppression: %s  (removes background noise from your microphone)",
				   state,
			   ),
		   ) {
			ui.settings.noise_suppression = !ui.settings.noise_suppression
			settings_save(ui.opts.settings_path, ui.settings)
			if ui.session != nil {
				push_command(&ui.session.client.commands, Noise_Command{ui.settings.noise_suppression})
			}
		}
	}

	// A page has no system tray, and its window is a browser tab.
	when !WEB {
		mu.layout_row(ctx, {-1})
		tray_state := "on" if ui.settings.tray else "off"
		if .SUBMIT in
		   stable_button(
			   ctx,
			   "tray",
			   fmt.tprintf(
				   "Tray icon: %s  (shows whether you're talking, muted or deafened)",
				   tray_state,
			   ),
		   ) {
			ui.settings.tray = !ui.settings.tray
			settings_save(ui.opts.settings_path, ui.settings)
			tray_update(ui)
		}
		// What the window's own buttons do is only a question while there's
		// a tray to put it in.
		if ui.settings.tray {
			mu.layout_row(ctx, {-1})
			closes := "hides the client in the tray" if ui.settings.close_to_tray else "quits"
			if .SUBMIT in
			   stable_button(ctx, "close_to_tray", fmt.tprintf("    Closing the window %s", closes)) {
				ui.settings.close_to_tray = !ui.settings.close_to_tray
				settings_save(ui.opts.settings_path, ui.settings)
			}

			mu.layout_row(ctx, {-1})
			minimizes :=
				"hides the client in the tray" if ui.settings.minimize_to_tray else "just minimizes it"
			if .SUBMIT in
			   stable_button(
				   ctx,
				   "minimize_to_tray",
				   fmt.tprintf("    Minimizing the window %s", minimizes),
			   ) {
				ui.settings.minimize_to_tray = !ui.settings.minimize_to_tray
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
					"    Wayland doesn't tell a window it has been minimized, so here it will just minimize.",
					label_proc,
				)
			}
		}
	}

	gate_settings(ui)

	// The input list gets half of what's left; the output list the rest.
	style := ctx.style
	row := LINE_HEIGHT + style.padding * 2 + style.spacing
	input_height := max((height - 12 * row) / 2, row * 2)

	if choice, changed := device_list(
		ctx,
		"Input (microphone)",
		"inputs",
		a.inputs[:],
		ui.settings.input_device,
		input_height,
	); changed {
		set_setting(&ui.settings.input_device, choice)
		settings_save(ui.opts.settings_path, ui.settings)
		log.infof("input device: %s", choice if choice != "" else "system default")
		reopen_audio(ui, true)
	}
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

// quality_row picks the send quality preset (see quality.odin).
@(private = "file")
quality_row :: proc(ui: ^UI) {
	ctx := &ui.ctx
	current := settings_quality(&ui.settings)

	mu.layout_row(ctx, {60, 90, 90, 90, -1})
	mu.label(ctx, "Quality")
	for preset, q in QUALITY_PRESETS {
		mark := "> " if q == current else "  "
		if .SUBMIT in stable_button(ctx, preset.name, fmt.tprintf("%s%s", mark, preset.label)) && q != current {
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
}

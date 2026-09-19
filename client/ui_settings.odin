package client

import "core:fmt"
import "core:log"
import mu "vendor:microui"

/*
The settings page: choosing the microphone and the speakers/headphones.
Selections are saved right away (see settings.odin). They take effect
once audio is actually recorded and played, which is a later step.
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
	submitted := .SUBMIT in mu.textbox(ctx, ui.name_buf[:], &ui.name_len)
	if .SUBMIT in mu.button(ctx, "Apply") || submitted {
		apply_name(ui)
	}
	mu.label(ctx, "  what others see you as")

	if a.ctx == nil {
		mu.layout_row(ctx, {-1})
		with_text_color(ctx, {230, 90, 90, 255}, a.error, label_proc)
		return
	}

	mu.layout_row(ctx, {-1})
	state := "on" if ui.settings.noise_suppression else "off"
	if .SUBMIT in
	   stable_button(
		   ctx,
		   "noise",
		   fmt.tprintf(
			   "Noise suppression: %s  (removes background noise; only sends while you talk)",
			   state,
		   ),
	   ) {
		ui.settings.noise_suppression = !ui.settings.noise_suppression
		settings_save(ui.opts.settings_path, ui.settings)
		if ui.session != nil {
			push_command(&ui.session.client.commands, Noise_Command{ui.settings.noise_suppression})
		}
	}

	// The input list gets half of what's left; the output list the rest.
	style := ctx.style
	row := LINE_HEIGHT + style.padding * 2 + style.spacing
	input_height := max((height - 6 * row) / 2, row * 2)

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

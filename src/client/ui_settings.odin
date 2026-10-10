package client

import "client:audio"
import "client:conn"
import "client:platform"
import "client:settings"
import log "common:wlog"
import "core:fmt"
import "core:sync"
import mu "vendor:microui"

/*
The settings page, in two tabs. This client's: noise suppression, the
voice gate (ui_gate.odin), choosing the microphone and the
speakers/headphones, the UI, hotkeys and the rest. This server's, while
we're logged in to one: the account and, for who may, managing the
server (ui_account.odin, ui_manage.odin). Changes are saved right away
(see settings/settings.odin) and apply to a running connection.

Each tab is split in two: its categories down the left, and the one
picked on the right, in a panel that scrolls. The voice gate and the
devices are nodes inside Audio, and smaller parts of a category (the
account's password, its devices) are nodes a person can open too. About
is the last of the client's categories.
*/
Settings_Tab :: enum {
	Client,
	Server,
}

// The client's tab's categories, in the order they're listed.
Client_Category :: enum {
	Audio,
	Interface,
	Hotkeys,
	Transfers,
	Image_Cache,
	Trusted_Servers,
	Install,
	Memory,
	Log,
	About,
}

@(private = "file")
CLIENT_CATEGORY_NAMES := [Client_Category]string {
	.Audio           = "Audio",
	.Interface       = "User interface",
	.Hotkeys         = "Global hotkeys",
	.Transfers       = "File transfers",
	.Image_Cache     = "Image cache",
	.Trusted_Servers = "Trusted servers",
	.Install         = "Install",
	.Memory          = "Memory",
	.Log             = "Log",
	.About           = "About",
}

// The ones a web build has: a page has neither global hotkeys nor
// anything to install (ui_hotkeys_web.odin, ui_install_web.odin).
@(private = "file")
CLIENT_CATEGORIES ::
	~bit_set[Client_Category] {
		.Hotkeys,
		.Install,
	} when platform.WEB else ~bit_set[Client_Category]{}

// How wide the list of categories is.
@(private = "file")
CATEGORY_WIDTH :: 160

settings_page :: proc(ui: ^UI) {
	ctx := &ui.ctx

	// The rail's settings button, the inbox or a server closes it.
	title_row(ui, {-1})
	mu.label(ctx, "Settings")

	// The server's tab is there while we're logged in to one, with what
	// we may do there.
	server := ""
	server_categories: bit_set[Server_Category]
	{
		v := ui.view
		sync.guard(&v.mutex)
		if v.status == .Connected && v.login.state == .Done {
			server = v.server_name if v.server_name != "" else v.server
			server_categories = server_settings_categories(v)
		}
	}
	if server == "" {
		ui.settings_tab = .Client
	} else {
		mu.layout_row(ctx, {140, 260})
		if .SUBMIT in tab_button(ctx, "client tab", "This client", ui.settings_tab == .Client) {
			ui.settings_tab = .Client
		}
		if .SUBMIT in
		   tab_button(
			   ctx,
			   "server tab",
			   fmt.tprintf("Server: %s", server),
			   ui.settings_tab == .Server,
		   ) {
			ui.settings_tab = .Server
		}
	}

	// One that isn't there (any more): the first that is.
	if ui.settings_client not_in CLIENT_CATEGORIES {
		ui.settings_client = .Audio
	}
	if ui.settings_server not_in server_categories {
		ui.settings_server = .Account
	}

	mu.layout_row(ctx, {CATEGORY_WIDTH, -1}, -1)
	mu.layout_begin_column(ctx)
	if ui.settings_tab == .Client {
		mu.layout_row(ctx, {-1}, -1)
		mu.begin_panel(ctx, "settings categories")
		for c in CLIENT_CATEGORIES {
			if category_row(ctx, CLIENT_CATEGORY_NAMES[c], ui.settings_client == c) {
				ui.settings_client = c
			}
		}
		mu.end_panel(ctx)
	} else {
		mu.layout_row(ctx, {-1}, -1)
		mu.begin_panel(ctx, "settings categories")
		for c in server_categories {
			if category_row(ctx, SERVER_CATEGORY_NAMES[c], ui.settings_server == c) &&
			   ui.settings_server != c {
				ui.settings_server = c
				server_category_opened(ui, c)
			}
		}
		mu.end_panel(ctx)
	}
	mu.layout_end_column(ctx)

	// The log scrolls on its own, and keeps to the bottom as lines come
	// in, so it's the whole of the right rather than in a panel that
	// scrolls too.
	if ui.settings_tab == .Client && ui.settings_client == .Log {
		log_panel(ui)
		return
	}
	mu.begin_panel(ctx, "settings_body")
	defer mu.end_panel(ctx)
	if ui.settings_tab == .Server {
		server_settings(ui, ui.settings_server)
		return
	}
	switch ui.settings_client {
	case .Audio:
		if a := &ui.audio; a.ctx == nil {
			mu.layout_row(ctx, {-1})
			with_text_color(ctx, theme.error, a.error, label_proc)
		} else {
			audio_settings(ui)
		}
	case .Interface:
		ui_settings(ui)
	case .Hotkeys:
		hotkey_settings(ui)
	case .Transfers:
		transfer_settings(ui)
	case .Image_Cache:
		image_cache_settings(ui)
	case .Trusted_Servers:
		trusted_servers_settings(ui)
	case .Install:
		install_settings(ui)
	case .Memory:
		memory_settings(ui) // ui_memory.odin
	case .Log:
	case .About:
		about_settings(ui)
	}
}

/*
category_row is one line of a settings tab's list of categories (or the
Roles list, ui_roles.odin): highlighted while it's the one picked, true
when it's clicked.
*/
category_row :: proc(ctx: ^mu.Context, label: string, selected: bool) -> bool {
	mu.layout_row(ctx, {-1})
	id := mu.get_id(ctx, label)
	rect := mu.layout_next(ctx)
	mu.update_control(ctx, id, rect)
	switch {
	case selected:
		mu.draw_rect(ctx, rect, ctx.style.colors[.BUTTON_FOCUS])
	case ctx.hover_id == id:
		mu.draw_rect(ctx, rect, ctx.style.colors[.BUTTON_HOVER])
	}
	mu.draw_control_text(ctx, label, rect, .TEXT, {})
	return ctx.hover_id == id && ctx.mouse_pressed_bits == {.LEFT}
}

// audio_settings picks the send quality preset (see audio/quality.odin),
// whether the microphone gets denoised, and whether muting it mutes a
// shared application too (ui_app_audio_native.odin).
@(private = "file")
audio_settings :: proc(ui: ^UI) {
	ctx := &ui.ctx
	current := settings.settings_quality(&ui.settings)
	mu.layout_row(ctx, {60, 90, 90, 90})
	mu.label(ctx, "Quality")
	for preset, q in audio.QUALITY_PRESETS {
		mark := "⏵ " if q == current else "  "
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
			command_all(ui, conn.Quality_Command{q})
			current = q
		}
	}

	mu.layout_row(ctx, {-1})
	if .CHANGE in mu.checkbox(ctx, "Use RNN noise suppression", &ui.settings.noise_suppression) {
		settings.settings_save(ui.opts.settings_path, ui.settings)
		command_all(ui, conn.Noise_Command{ui.settings.noise_suppression})
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
				conn.push_command(
					&ui.session.client.commands,
					conn.app_audio_command(&ui.settings),
				)
			}
		}
	}
	gate_settings(ui)
	device_settings(ui)
}

@(private = "file")
ANIMATE_CHOICE_LABELS := [settings.Animate_Pictures]string {
	.Hover  = "On hover",
	.Always = "Always",
	.Never  = "Never",
}

@(private = "file")
ui_settings :: proc(ui: ^UI) {
	ctx := &ui.ctx
	// Dark, light, or whichever the system is (theme.odin).
	mu.layout_row(ctx, {120, 130, 130, 130})
	mu.label(ctx, "Theme")
	current := theme_choice(&ui.settings)
	for label, choice in THEME_CHOICE_LABELS {
		if choice_button(ui, THEME_CHOICE_NAMES[choice], label, choice == current) &&
		   choice != current {
			settings.set_setting(&ui.settings.theme, THEME_CHOICE_NAMES[choice])
			settings.settings_save(ui.opts.settings_path, ui.settings)
			ui_redraw(ui)
		}
	}

	// When animated pictures in the chat play (ui_images.odin).
	mu.layout_row(ctx, {120, 130, 130, 130})
	mu.label(ctx, "Animate pictures")
	animate := settings.animate_pictures(&ui.settings)
	for label, choice in ANIMATE_CHOICE_LABELS {
		name := settings.ANIMATE_PICTURES_NAMES[choice]
		id := fmt.tprintf("animate %s", name)
		if choice_button(ui, id, label, choice == animate) && choice != animate {
			settings.set_setting(&ui.settings.animate_pictures, name)
			settings.settings_save(ui.opts.settings_path, ui.settings)
			ui_redraw(ui)
		}
	}

	mu.layout_row(ctx, {120, -1})
	mu.label(ctx, "UI scale")
	// Applying every change live would resize the window mid-drag, which
	// moves the slider out from under the pointer that's dragging it,
	// so ui.ui_scale_draft only reaches settings.ui_scale (and with it
	// window_metrics) once the drag lets go.
	id := mu.get_id(ctx, uintptr(&ui.ui_scale_draft))
	was_dragging := ctx.focus_id == id
	mu.slider(
		ctx,
		&ui.ui_scale_draft,
		settings.MIN_UI_SCALE * 100,
		settings.MAX_UI_SCALE * 100,
		10,
		"%.0f%%",
	)
	if was_dragging && ctx.focus_id != id {
		ui.settings.ui_scale = ui.ui_scale_draft / 100
		settings.settings_save(ui.opts.settings_path, ui.settings)
	}

	// As the UI scale: taken when the slider is let go, as the glyphs
	// are rasterized again for it.
	mu.layout_row(ctx, {120, -1})
	mu.label(ctx, "Chat text size")
	chat_id := mu.get_id(ctx, uintptr(&ui.chat_scale_draft))
	chat_dragging := ctx.focus_id == chat_id
	mu.slider(
		ctx,
		&ui.chat_scale_draft,
		settings.MIN_CHAT_SCALE * 100,
		settings.MAX_CHAT_SCALE * 100,
		10,
		"%.0f%%",
	)
	if chat_dragging && ctx.focus_id != chat_id {
		ui.settings.chat_scale = ui.chat_scale_draft / 100
		settings.settings_save(ui.opts.settings_path, ui.settings)
	}

	mu.layout_row(ctx, {-1})
	if .CHANGE in mu.checkbox(ctx, "Show pictures beside messages", &ui.settings.chat_pictures) {
		settings.settings_save(ui.opts.settings_path, ui.settings)
	}

	volume := settings.notification_gain(&ui.settings) * 100
	mu.layout_row(ctx, {120, -1})
	mu.label(ctx, "Notifications volume")
	if .CHANGE in mu.slider(ctx, &volume, 0, settings.MAX_USER_VOLUME * 100, 5, "%.0f%%") {
		ui.settings.notification_volume = volume / 100
		settings.settings_save(ui.opts.settings_path, ui.settings)
		command_all(ui, conn.Notification_Volume_Command{ui.settings.notification_volume})
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
				theme.warning,
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
	changed := false
	mu.layout_row(ctx, {120, -1})
	mu.label(ctx, "Upload limit")
	changed |=
		.CHANGE in
		mu.slider(ctx, &ui.settings.upload_limit, 0, settings.MAX_TRANSFER_LIMIT, 0.5, "%.1f MB/s")
	mu.label(ctx, "Download limit")
	changed |=
		.CHANGE in
		mu.slider(
			ctx,
			&ui.settings.download_limit,
			0,
			settings.MAX_TRANSFER_LIMIT,
			0.5,
			"%.1f MB/s",
		)
	mu.layout_row(ctx, {-1})
	with_text_color(
		ctx,
		theme.dim,
		"  0 is no limit. A download limit also slows down whoever is sending.",
		label_proc,
	)
	if changed {
		// Sliders change every frame while dragged; saved within a second.
		ui.settings_dirty = true
		command_all(ui, conn.transfer_limits_command(&ui.settings))
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
	mark := "⏵ " if selected == "" || missing else "  "
	if .SUBMIT in stable_button(ctx, "default", fmt.tprintf("%sSystem default", mark)) &&
	   selected != "" {
		choice, changed = "", true
	}
	if missing {
		mu.layout_row(ctx, {-1})
		with_text_color(
			ctx,
			theme.warning,
			fmt.tprintf("  %s is not available, using the default", selected),
			label_proc,
		)
	}

	for d, i in devices {
		mu.push_id(ctx, uintptr(i))
		defer mu.pop_id(ctx)
		mu.layout_row(ctx, {-1})
		mark = "⏵ " if d.name == selected else "  "
		suffix := "  (current default)" if d.is_default else ""
		if .SUBMIT in stable_button(ctx, "device", fmt.tprintf("%s%s%s", mark, d.name, suffix)) &&
		   d.name != selected {
			choice, changed = d.name, true
		}
	}
	return
}

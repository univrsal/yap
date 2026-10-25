package client

import "client:audio"
import "client:conn"
import "client:platform"
import "client:settings"
import log "common:wlog"
import "core:fmt"
import "core:sync"
import mu "vendor:microui"


// The settings page has two tabs. This client's tab has noise suppression,
// the voice gate (ui_gate.odin), the choice of microphone and
// speakers/headphones, the UI, hotkeys and the rest. This server's tab is
// available while we are logged in to a server: the account and, for users who
// may, managing the server (ui_account.odin, ui_manage.odin). Changes are
// saved right away (see settings/settings.odin) and apply to a running
// connection.
//
// Each tab is split in two: its categories down the left, and the picked one
// on the right, in a panel that scrolls. In a narrow window (a phone) the two
// take turns: first the list, then the picked category with a way back to the
// list. The voice gate and the devices are nodes inside Audio, and smaller
// parts of a category (the account's password, its devices) are nodes that
// can be opened too. About is the last of the client's categories.
Settings_Tab :: enum {
	Client,
	Server,
}

// The categories of the client's tab, in the order they are listed.
Client_Category :: enum {
	Audio,
	Sounds,
	Interface,
	Hotkeys,
	Screen_Sharing,
	Camera,
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
	.Sounds          = "Sounds",
	.Interface       = "User interface",
	.Hotkeys         = "Global hotkeys",
	.Screen_Sharing  = "Screen sharing",
	.Camera          = "Camera",
	.Transfers       = "File transfers",
	.Image_Cache     = "Image cache",
	.Trusted_Servers = "Trusted servers",
	.Install         = "Install",
	.Memory          = "Memory",
	.Log             = "Log",
	.About           = "About",
}

// The categories a web build excludes: a page has neither global hotkeys nor
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
	narrow := mu.get_current_container(ctx).body.w < NARROW_LAYOUT

	// The server's tab is available while we are logged in to a server, with
	// what we may do there.
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
	}
	// A category that isn't available (any more) is replaced by the first one that is.
	if ui.settings_client not_in CLIENT_CATEGORIES {
		ui.settings_client = .Audio
	}
	if ui.settings_server not_in server_categories {
		ui.settings_server = .Account
	}

	// In a narrow window the list and the picked category take turns, as a
	// server's channels and chat do: the category is shown under its name
	// with a way back to the list.
	if narrow && !ui.settings_list {
		title_row(ui, {40, -1})
		if .SUBMIT in icon_button(ui, "to settings list", .Back, "Settings") {
			ui.settings_list = true
		}
		if ui.settings_tab == .Server {
			mu.label(ctx, SERVER_CATEGORY_NAMES[ui.settings_server])
		} else {
			mu.label(ctx, CLIENT_CATEGORY_NAMES[ui.settings_client])
		}
		mu.layout_row(ctx, {-1}, -1)
		settings_body(ui)
		return
	}

	// The rail's settings button, the inbox or a server closes the settings.
	title_row(ui, {-1})
	mu.label(ctx, "Settings")
	if server != "" {
		mu.layout_row(ctx, {110, -1} if narrow else {140, 260})
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

	if narrow {
		mu.layout_row(ctx, {-1}, -1)
		if category_list(ui, server_categories, narrow = true) {
			ui.settings_list = false
		}
		return
	}
	mu.layout_row(ctx, {CATEGORY_WIDTH, -1}, -1)
	mu.layout_begin_column(ctx)
	mu.layout_row(ctx, {-1}, -1)
	category_list(ui, server_categories)
	mu.layout_end_column(ctx)
	settings_body(ui)
}

// category_list is the shown tab's categories, in a panel that fills the next
// cell. It returns true when one is clicked. When narrow, none is marked as
// picked: the list is all there is on screen, so no category is open.
@(private = "file")
category_list :: proc(
	ui: ^UI,
	server_categories: bit_set[Server_Category],
	narrow := false,
) -> (
	picked: bool,
) {
	ctx := &ui.ctx
	mu.begin_panel(ctx, "settings categories")
	defer mu.end_panel(ctx)
	if ui.settings_tab == .Client {
		for c in CLIENT_CATEGORIES {
			if category_row(ctx, CLIENT_CATEGORY_NAMES[c], ui.settings_client == c && !narrow) {
				ui.settings_client = c
				picked = true
			}
		}
		return
	}
	for c in server_categories {
		if category_row(ctx, SERVER_CATEGORY_NAMES[c], ui.settings_server == c && !narrow) {
			if ui.settings_server != c {
				ui.settings_server = c
				server_category_opened(ui, c)
			}
			picked = true
		}
	}
	return
}

// settings_body is the picked category, in the next cell.
@(private = "file")
settings_body :: proc(ui: ^UI) {
	ctx := &ui.ctx
	// The log is a panel that scrolls on its own, so it fills the whole cell
	// instead of being in a panel that scrolls too.
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
			error_label(ctx, a.error)
		} else {
			audio_settings(ui)
		}
	case .Sounds:
		sound_settings(ui) // ui_sounds.odin
	case .Interface:
		ui_settings(ui)
	case .Hotkeys:
		hotkey_settings(ui)
	case .Screen_Sharing:
		share_settings(ui)
	case .Camera:
		camera_settings(ui) // ui_camera_settings.odin
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

// checkbox_noted is a checkbox with a note: the note follows the label in
// brackets where that fits, otherwise it goes under it, in text that wraps.
checkbox_noted :: proc(ui: ^UI, label, note: string, state: ^bool) -> mu.Result_Set {
	ctx := &ui.ctx
	mu.layout_row(ctx, {-1})
	full := fmt.tprintf("%s (%s)", label, note)
	box := ctx.style.size.y + 2 * ctx.style.padding
	if ctx.text_width(ctx.style.font, full) + box + ctx.style.padding <= row_room(ctx) {
		return checkbox(ctx, full, state)
	}
	res := checkbox(ctx, label, state)
	mu.layout_row(ctx, {-1})
	dim_note(ctx, fmt.tprintf("  %s", note))
	return res
}

// category_row is one line of a settings tab's list of categories (or the
// Roles list, ui_roles.odin), a list_row. It returns true when clicked.
category_row :: proc(ctx: ^mu.Context, label: string, selected: bool) -> bool {
	mu.layout_row(ctx, {-1})
	return .SUBMIT in list_row(ctx, label, label, selected, accent = true)
}

// audio_settings picks the send quality preset (see audio/quality.odin),
// whether the microphone is denoised, and whether muting it also mutes a
// shared application (ui_app_audio_native.odin).
@(private = "file")
audio_settings :: proc(ui: ^UI) {
	ctx := &ui.ctx
	current := settings.settings_quality(&ui.settings)
	field_row(ui, 60, "Quality", {CHOICE_WIDTH})
	labels: [audio.Quality]string
	for preset, q in audio.QUALITY_PRESETS {
		labels[q] = preset.label
	}
	hint := audio.QUALITY_PRESETS[current].description
	if q, ok := enum_dropdown(ui, "quality", labels, current, hint); ok {
		settings.set_setting(&ui.settings.quality, audio.QUALITY_PRESETS[q].name)
		save_settings(ui)
		command_all(ui, conn.Quality_Command{q})
	}

	mu.layout_row(ctx, {-1})
	if .CHANGE in checkbox(ctx, "Use RNN noise suppression", &ui.settings.noise_suppression) {
		save_settings(ui)
		command_all(ui, conn.Noise_Command{ui.settings.noise_suppression})
	}
	if app_audio_setting(ui) {
		mu.layout_row(ctx, {-1})
		if .CHANGE in
		   checkbox(
			   ctx,
			   "Mute audio sharing when microphone is muted",
			   &ui.settings.mute_app_audio_with_mic,
		   ) {
			save_settings(ui)
			// To all, like the volume: the audio may go out through any of them.
			command_all(ui, conn.app_audio_command(&ui.settings))
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
	// Dark, light, or whichever the system uses (theme.odin).
	field_row(ui, 120, "Theme", {CHOICE_WIDTH})
	if choice, ok := enum_dropdown(ui, "theme", THEME_CHOICE_LABELS, theme_choice(&ui.settings));
	   ok {
		settings.set_setting(&ui.settings.theme, THEME_CHOICE_NAMES[choice])
		save_settings(ui)
		ui_redraw(ui)
	}

	// When animated pictures in the chat play (ui_images.odin).
	field_row(ui, 120, "Animate pictures", {CHOICE_WIDTH})
	animate := settings.animate_pictures(&ui.settings)
	if choice, ok := enum_dropdown(ui, "animate", ANIMATE_CHOICE_LABELS, animate); ok {
		settings.set_setting(
			&ui.settings.animate_pictures,
			settings.ANIMATE_PICTURES_NAMES[choice],
		)
		save_settings(ui)
		ui_redraw(ui)
	}

	mu.layout_row(ctx, {120, -1})
	mu.label(ctx, "UI scale")
	// ui.ui_scale_draft reaches settings.ui_scale (and with it window_metrics)
	// once the slider is released, as resizing the window while dragging would
	// move the slider out from under the pointer.
	if release_slider(
		ctx,
		&ui.ui_scale_draft,
		settings.MIN_UI_SCALE * 100,
		settings.MAX_UI_SCALE * 100,
		10,
		"%.0f%%",
	) {
		ui.settings.ui_scale = ui.ui_scale_draft / 100
		save_settings(ui)
	}

	// Also applied when released, because the glyphs are rasterized again.
	mu.layout_row(ctx, {120, -1})
	mu.label(ctx, "Chat text size")
	if release_slider(
		ctx,
		&ui.chat_scale_draft,
		settings.MIN_CHAT_SCALE * 100,
		settings.MAX_CHAT_SCALE * 100,
		10,
		"%.0f%%",
	) {
		ui.settings.chat_scale = ui.chat_scale_draft / 100
		save_settings(ui)
	}

	mu.layout_row(ctx, {-1})
	if .CHANGE in checkbox(ctx, "Show avatars beside messages", &ui.settings.chat_pictures) {
		save_settings(ui)
	}

	when !platform.WEB {
		// The window's buttons are in the first row, instead of in a title bar
		// of the desktop's (ui_titlebar.odin).
		mu.layout_row(ctx, {-1})
		if .CHANGE in
		   checkbox(ctx, "Merge the title bar into the window", &ui.settings.merge_title_bar) {
			save_settings(ui)
			titlebar_merge(ui.window, ui.settings.merge_title_bar)
			ui_redraw(ui)
		}
		if note := titlebar_restart_note(ui.settings.merge_title_bar); note != "" {
			mu.layout_row(ctx, {-1})
			with_text_color(ctx, theme.warning, fmt.tprintf("  %s", note), wrap_text)
		}

		mu.layout_row(ctx, {-1})
		if .CHANGE in checkbox(ctx, "Enable tray icon", &ui.settings.tray) {
			save_settings(ui)
			tray_update(ui)
		}

		// What the window's own buttons do only matters while there is a tray
		// to hide the window in.
		if !ui.settings.tray {
			return
		}

		// One under the other where they don't fit side by side.
		mu.layout_row(ctx, {230, -1} if row_fits(ctx, {230, 200}) else {-1})
		if .CHANGE in checkbox(ctx, "Close hides in tray", &ui.settings.close_to_tray) {
			save_settings(ui)
		}
		if .CHANGE in checkbox(ctx, "Minimize hides in tray", &ui.settings.minimize_to_tray) {
			save_settings(ui)
		}
		// Only the desktop can tell us that a window has been minimized, and
		// Wayland has no message for it, so say so instead of leaving the
		// setting looking broken.
		if ui.settings.minimize_to_tray && on_wayland() {
			mu.layout_row(ctx, {-1})
			with_text_color(
				ctx,
				theme.warning,
				"  Wayland doesn't tell a window that it has been minimized, so here it will just minimize.",
				wrap_text,
			)
		}
	}
}

// transfer_settings limits how fast files sent in DMs are uploaded and downloaded.
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
	dim_note(ctx, "  0 means no limit. A download limit also slows down whoever is sending.")
	if changed {
		// Sliders change every frame while dragged, so save within a second.
		ui.settings_dirty = true
		command_all(ui, conn.transfer_limits_command(&ui.settings))
	}
}

// device_settings shows the input and output devices, each a dropdown
// (device_choice).
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

	if choice, changed := device_choice(
		ui,
		"Input",
		"input device",
		a.inputs[:],
		ui.settings.input_device,
	); changed {
		settings.set_setting(&ui.settings.input_device, choice)
		save_settings(ui)
		log.infof("input device: %s", choice if choice != "" else "system default")
		reopen_audio(ui, true)
	}
	if choice, changed := device_choice(
		ui,
		"Output",
		"output device",
		a.outputs[:],
		ui.settings.output_device,
	); changed {
		settings.set_setting(&ui.settings.output_device, choice)
		save_settings(ui)
		log.infof("output device: %s", choice if choice != "" else "system default")
		reopen_audio(ui, false)
	}
}

// device_choice is a dropdown of "System default" and every device, with
// `selected` (a device name, "" for the default) shown. It returns the new
// choice when one is picked.
@(private = "file")
device_choice :: proc(
	ui: ^UI,
	title, id: string,
	devices: []audio.Audio_Device,
	selected: string,
) -> (
	choice: string,
	changed: bool,
) {
	ctx := &ui.ctx
	// A saved device that isn't plugged in falls back to the default, so the
	// default is what is in effect. Say so instead of hiding it.
	missing := selected != "" && audio.find_device(devices, selected) == nil

	labels := make([]string, len(devices) + 1, context.temp_allocator)
	labels[0] = "System default"
	current := 0
	for d, i in devices {
		suffix := "  (current default)" if d.is_default else ""
		labels[i + 1] = fmt.tprintf("%s%s", d.name, suffix)
		if d.name == selected {
			current = i + 1
		}
	}
	field_row(ui, 60, title, {-1})
	if picked, ok := choice_dropdown(ui, id, labels, current); ok {
		choice = "" if picked == 0 else devices[picked - 1].name
		changed = choice != selected
	}
	if missing {
		mu.layout_row(ctx, {60, -1})
		mu.label(ctx, "")
		with_text_color(
			ctx,
			theme.warning,
			fmt.tprintf("%s is not available, using the default", selected),
			wrap_text,
		)
	}
	return
}

// The server tab's categories, in the order they are listed.
Server_Category :: enum {
	Server_Info,
	Account,
	Channels,
	Roles,
	Accounts,
	Invites,
	Purge,
	Memory,
}

// server_settings_categories returns which of the server tab's categories
// we may see: our account, and what we may manage (the server's name and
// picture only if it's ours). Call with the View locked.
server_settings_categories :: proc(v: ^conn.View) -> (c: bit_set[Server_Category]) {
	c += {.Account}
	if me, known := v.accounts[v.me]; known && .Owner in me.flags {
		c += {.Server_Info, .Memory}
	}
	if v.permissions & {.Create_Channels, .Manage_Channels} != {} {
		c += {.Channels}
	}
	if .Manage_Roles in v.permissions {
		c += {.Roles}
	}
	if v.permissions & {.Manage_Accounts, .Manage_Roles} != {} {
		c += {.Accounts}
	}
	if v.permissions & {.Create_Invites, .Manage_Accounts} != {} {
		c += {.Invites}
	}
	if .Purge in v.permissions {
		c += {.Purge}
	}
	return
}

// server_category_opened is called when a category of the server tab
// has just been picked.
server_category_opened :: proc(ui: ^UI, c: Server_Category) {
	#partial switch c {
	case .Roles:
		notice_mark_reset(&ui.roles.notice)
	case .Channels:
		channels_category_opened(ui) // ui_channel_settings.odin
	case:
		// The others share the account screen's mark, so a notice about
		// something done in another category doesn't show up here.
		notice_mark_reset(&ui.account.notice)
	}
}

// server_settings is the settings page's server tab, with the category `c`
// selected: our account and, for those who manage accounts, the roles, everybody's
// accounts, invite codes and purging. The settings page doesn't hold the
// View's lock, so it is taken here.
server_settings :: proc(ui: ^UI, c: Server_Category) {
	v := ui.view
	a := &ui.account
	sync.guard(&v.mutex)
	notice_mark_update(&a.notice, v)
	if v.status != .Connected || v.login.state != .Done {
		return
	}
	switch c {
	case .Server_Info:
		server_info_settings(ui, v) // ui_server_info.odin
	case .Account:
		account_settings(ui, v)
	case .Channels:
		channels_settings(ui) // ui_channel_settings.odin
	case .Roles:
		roles_settings(ui)
	case .Accounts:
		accounts_admin(ui, v)
	case .Invites:
		invites_settings(ui, v)
	case .Purge:
		purge_settings(ui)
	case .Memory:
		server_memory_settings(ui, v) // ui_memory.odin
	}
}

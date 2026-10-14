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
picked on the right, in a panel that scrolls. In a narrow window (a
phone) the two take turns: the list, then the category picked with a
way back to the list. The voice gate and the
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
	Screen_Sharing,
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
	.Screen_Sharing  = "Screen sharing",
	.Transfers       = "File transfers",
	.Image_Cache     = "Image cache",
	.Trusted_Servers = "Trusted servers",
	.Install         = "Install",
	.Memory          = "Memory",
	.Log             = "Log",
	.About           = "About",
}

// The ones a web build has: a page has neither global hotkeys nor
// anything to install (ui_hotkeys_web.odin, ui_install_web.odin), and
// shares what the browser's picker says (ui_share_settings.odin).
@(private = "file")
CLIENT_CATEGORIES ::
	~bit_set[Client_Category] {
		.Hotkeys,
		.Screen_Sharing,
		.Install,
	} when platform.WEB else ~bit_set[Client_Category]{}

// How wide the list of categories is.
@(private = "file")
CATEGORY_WIDTH :: 160

settings_page :: proc(ui: ^UI) {
	ctx := &ui.ctx
	narrow := mu.get_current_container(ctx).body.w < NARROW_LAYOUT

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
	}
	// One that isn't there (any more): the first that is.
	if ui.settings_client not_in CLIENT_CATEGORIES {
		ui.settings_client = .Audio
	}
	if ui.settings_server not_in server_categories {
		ui.settings_server = .Account
	}

	// In a narrow window the list and the category picked take turns,
	// as a server's channels and chat do: the category under its name
	// and a way back to the list.
	if narrow && !ui.settings_list {
		title_row(ui, {40, -1})
		if .SUBMIT in stable_button_hint(ui, "to settings list", "<", "Settings", {.ALIGN_CENTER}) {
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

	// The rail's settings button, the inbox or a server closes it.
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

// category_list is the shown tab's categories, in a panel that fills the
// next cell; true when one is clicked. Narrow, none is marked as picked:
// the list is all there is on screen, so none is open.
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

// settings_body is the category picked, in the next cell.
@(private = "file")
settings_body :: proc(ui: ^UI) {
	ctx := &ui.ctx
	// The log scrolls on its own, and keeps to the bottom as lines come
	// in, so it's the whole of the cell rather than in a panel that
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
	case .Screen_Sharing:
		share_settings(ui)
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
In a narrow window (a phone) a row of settings that wouldn't fit across
goes down instead: field_row puts its label on a line of its own, over
the controls, and fit_widths shrinks fixed widths that still don't fit.
Wide, everything is laid out as asked.
*/

// How wide a fill (a width of 0 or less) is counted when working out
// whether a row fits.
FILL_MIN :: 100

// row_room is the width a row laid out now gets.
row_room :: proc(ctx: ^mu.Context) -> i32 {
	layout := mu.get_layout(ctx)
	return layout.body.w - layout.indent
}

// row_fits says whether `widths` fit across a row laid out now, a fill
// counted `fill_min` wide.
row_fits :: proc(ctx: ^mu.Context, widths: []i32, fill_min: i32 = FILL_MIN) -> bool {
	need := i32(max(len(widths) - 1, 0)) * ctx.style.spacing
	for w in widths {
		need += w if w > 0 else fill_min
	}
	return need <= row_room(ctx)
}

// fit_widths is `widths`, with the fixed ones shrunk in proportion if
// they don't fit across a row laid out now.
fit_widths :: proc(ctx: ^mu.Context, widths: []i32) -> []i32 {
	if row_fits(ctx, widths) {
		return widths
	}
	fixed, fills: i32
	for w in widths {
		if w > 0 {
			fixed += w
		} else {
			fills += 1
		}
	}
	room := row_room(ctx) - i32(len(widths) - 1) * ctx.style.spacing - fills * FILL_MIN
	out := make([]i32, len(widths), context.temp_allocator)
	copy(out, widths)
	if fixed > 0 && room > 0 {
		for &w in out {
			if w > 0 {
				w = max(w * room / fixed, 1)
			}
		}
	}
	return out
}

/*
field_row lays out a row of a label `label_w` wide and controls of
`widths` after it, and draws the label; the controls are the caller's.
Where that doesn't fit (a fill counted `fill_min` wide), the label has a
line of its own (none if it's empty) and the controls go under it.
*/
field_row :: proc(
	ui: ^UI,
	label_w: i32,
	label: string,
	widths: []i32,
	height: i32 = 0,
	fill_min: i32 = FILL_MIN,
) {
	ctx := &ui.ctx
	row := make([]i32, len(widths) + 1, context.temp_allocator)
	row[0] = label_w
	copy(row[1:], widths)
	if row_fits(ctx, row, fill_min) {
		mu.layout_row(ctx, row, height)
		mu.label(ctx, label)
		return
	}
	if label != "" {
		mu.layout_row(ctx, {-1})
		mu.label(ctx, label)
	}
	mu.layout_row(ctx, fit_widths(ctx, widths), height)
}

/*
wrap_text is mu.text as the settings' notes want it: the last word of
it wraps too (mu.text only measures a word with a space after it), and
so does a word longer than a line, a path say, as the chat's does
(wrap_line). In the text colour, for with_text_color.
*/
wrap_text :: proc(ctx: ^mu.Context, text: string) {
	font := ctx.style.font
	mu.layout_begin_column(ctx)
	defer mu.layout_end_column(ctx)
	mu.layout_row(ctx, {-1}, ctx.text_height(font))
	rest := text
	for len(rest) > 0 {
		r := mu.layout_next(ctx)
		end, next := wrap_line(ctx, font, rest, r.w)
		mu.draw_text(ctx, font, rest[:end], {r.x, r.y}, ctx.style.colors[.TEXT])
		rest = rest[next:]
	}
}

// checkbox_noted is a checkbox with a note: after its label in brackets
// where that fits, or else under it, in text that wraps.
checkbox_noted :: proc(ui: ^UI, label, note: string, state: ^bool) -> mu.Result_Set {
	ctx := &ui.ctx
	mu.layout_row(ctx, {-1})
	full := fmt.tprintf("%s (%s)", label, note)
	box := ctx.style.size.y + 2 * ctx.style.padding
	if ctx.text_width(ctx.style.font, full) + box + ctx.style.padding <= row_room(ctx) {
		return mu.checkbox(ctx, full, state)
	}
	res := mu.checkbox(ctx, label, state)
	mu.layout_row(ctx, {-1})
	with_text_color(ctx, theme.dim, fmt.tprintf("  %s", note), wrap_text)
	return res
}

/*
category_row is one line of a settings tab's list of categories (or the
Roles list, ui_roles.odin), a list_row: true when it's clicked.
*/
category_row :: proc(ctx: ^mu.Context, label: string, selected: bool) -> bool {
	mu.layout_row(ctx, {-1})
	return .SUBMIT in list_row(ctx, label, label, selected)
}

// audio_settings picks the send quality preset (see audio/quality.odin),
// whether the microphone gets denoised, and whether muting it mutes a
// shared application too (ui_app_audio_native.odin).
@(private = "file")
audio_settings :: proc(ui: ^UI) {
	ctx := &ui.ctx
	current := settings.settings_quality(&ui.settings)
	field_row(ui, 60, "Quality", {90, 90, 90})
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
	field_row(ui, 120, "Theme", {130, 130, 130})
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
	field_row(ui, 120, "Animate pictures", {130, 130, 130})
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
		// The window's buttons in the first row rather than a title bar
		// of the desktop's (ui_titlebar.odin).
		mu.layout_row(ctx, {-1})
		if .CHANGE in
		   mu.checkbox(ctx, "Merge the title bar into the window", &ui.settings.merge_title_bar) {
			settings.settings_save(ui.opts.settings_path, ui.settings)
			titlebar_merge(ui.window, ui.settings.merge_title_bar)
			ui_redraw(ui)
		}
		if note := titlebar_restart_note(ui.settings.merge_title_bar); note != "" {
			mu.layout_row(ctx, {-1})
			with_text_color(ctx, theme.warning, fmt.tprintf("  %s", note), wrap_text)
		}

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

		// One under the other where they don't fit side by side.
		mu.layout_row(ctx, {230, -1} if row_fits(ctx, {230, 200}) else {-1})
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
				wrap_text,
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
		wrap_text,
	)
	if changed {
		// Sliders change every frame while dragged; saved within a second.
		ui.settings_dirty = true
		command_all(ui, conn.transfer_limits_command(&ui.settings))
	}
}

// device_settings shows the input and output pickers side by side (one
// over the other in a narrow window), each in a box of its own height,
// so neither has to share the other's space; either scrolls on its own
// if its device list doesn't fit.
// Narrower than this, the device lists go one over the other.
@(private = "file")
DEVICE_LIST_MIN :: 220

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
	mu.layout_row(ctx, {half, -1} if half >= DEVICE_LIST_MIN else {-1}, 210)

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

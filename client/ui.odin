package client

import "base:runtime"
import "core:crypto/ecdh"
import "core:fmt"
import "core:log"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "core:unicode/utf8"
import gl "vendor:OpenGL"
import "vendor:glfw"
import mu "vendor:microui"

import "../common"
import "../proto"
import "clipboard"

/*
The windowed client: GLFW for the window and input, microui for widgets,
OpenGL 3.3 to draw them (see ui_render.odin).

The UI owns the main thread (GLFW requires it). Each connection runs the
same network loop as headless mode on its own thread; the two sides meet
only in the View (network -> UI) and the command queue (UI -> network).
*/

UI_Options :: struct {
	key_path:      string,
	known_servers: string,
	server:        string, // prefilled, and connected to right away
	channel:       string, // joined on connect
	logs:          ^Log_Lines,
	settings_path: string,
}

@(private = "file")
Net_Session :: struct {
	client:        ^Voice_Client,
	thread:        ^thread.Thread,
	stop:          bool, // set atomically to end the network loop

	// Owned copies; the UI's buffers may change while the thread runs.
	key_path:      string,
	server:        string,
	known_servers: string,
	channel:       string,
	name:          string,

	// Audio devices, opened and closed on the UI thread (which owns the
	// miniaudio context); they feed the client's Voice rings.
	streams:       Audio_Streams,
}

Page :: enum {
	Main,
	Settings,
}

@(private = "file")
Action :: enum {
	None,
	Connect,
	Disconnect,
}

UI :: struct {
	window:         glfw.WindowHandle,
	ctx:            mu.Context,
	renderer:       Renderer,
	opts:           UI_Options,
	my_key:         [proto.KEY_SIZE]u8,
	server_buf:     [256]u8,
	server_len:     int,
	// Room for more than MAX_NAME_SIZE while typing; sanitize_name trims it.
	name_buf:       [2 * proto.MAX_NAME_SIZE]u8,
	name_len:       int,
	view:           View,
	session:        ^Net_Session,
	// Connecting/disconnecting waits on the network thread, which may be
	// waiting on the View lock, so it happens after layout, not during.
	action:         Action,
	log_seen:       int, // Log_Lines.total when the log panel was last scrolled
	chat:           UI_Chat, // the chat tab (ui_chat.odin)
	muted:          bool,
	deafened:       bool,

	// The user whose menu is open, and its volume slider's value (the
	// slider needs a stable address). See user_menu.
	menu_user:      u32, // user number
	menu_key:       [proto.KEY_SIZE]u8,
	menu_volume:    mu.Real,
	menu_requested: bool,
	// The settings page's microphone monitor and level meter (ui_gate.odin).
	monitor:        Mic_Monitor,
	listen_back:    bool,
	meter_level:    f32,
	meter_time:     time.Tick,
	// Slider drags change the settings every frame; save at most once a
	// second, and on exit.
	settings_dirty: bool,
	settings_saved: time.Tick,
	page:           Page,
	settings:       Settings,
	audio:          Audio,

	// Logical pixels per window coordinate, for mouse input. See
	// window_metrics.
	input_scale:    f32,
	metrics:        Window_Metrics,
	// The pointing hand shown over links; created on first use, freed by
	// glfw.Terminate.
	hand_cursor:    glfw.CursorHandle,
	hand_shown:     bool,
	// The image paste being read, if any (ui_paste.odin).
	paste:          ^Paste_Job,
	// What the icon button under the pointer does, and where it is, for
	// the hint drawn under it (see icon_button and icon_hint).
	hint:           string,
	hint_of:        mu.Rect,
	// Chat images: decoded pictures and their textures (ui_images.odin).
	images:         UI_Images,
}

// For GLFW's callbacks, which have no user data we can use cheaply.
@(private = "file")
g_ui: ^UI
@(private = "file")
g_logger: log.Logger

BACKGROUND :: mu.Color{30, 30, 30, 255}

run_ui :: proc(opts: UI_Options) -> bool {
	ui := new(UI)
	defer free(ui)
	g_ui = ui
	g_logger = context.logger
	ui.opts = opts
	view_init(&ui.view)
	defer view_destroy(&ui.view)
	ui_chat_init(ui)
	defer ui_chat_destroy(ui)

	// Load (or create) the key now, to show our id before connecting.
	{
		key: ecdh.Private_Key
		if common.load_or_create_private_key(opts.key_path, &key) {
			ecdh.private_key_public_bytes(&key, ui.my_key[:])
			ecdh.private_key_clear(&key)
		}
	}
	ui.settings = settings_load(opts.settings_path)
	defer settings_destroy(&ui.settings)
	initial := opts.server if opts.server != "" else ui.settings.server
	ui.server_len = copy(ui.server_buf[:], initial)
	name := ui.settings.name if ui.settings.name != "" else default_name()
	ui.name_len = copy(ui.name_buf[:], name)

	// Audio problems shouldn't keep the rest of the client from working;
	// the settings page shows what went wrong.
	audio_init(&ui.audio)
	defer audio_destroy(&ui.audio)

	glfw.SetErrorCallback(glfw_error_callback)
	if !glfw.Init() {
		log.error("failed to initialize GLFW")
		return false
	}
	defer glfw.Terminate()

	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 3)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 3)
	glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
	// Where window coordinates are physical pixels (Windows, X11), size
	// the window for the monitor's scale so it isn't tiny on high DPI.
	glfw.WindowHint(glfw.SCALE_TO_MONITOR, true)
	when ODIN_OS == .Darwin {
		glfw.WindowHint(glfw.OPENGL_FORWARD_COMPAT, true)
	}
	ui.window = glfw.CreateWindow(760, 480, "yap", nil, nil)
	if ui.window == nil {
		log.error("failed to create a window (OpenGL 3.3 is required)")
		return false
	}
	defer glfw.DestroyWindow(ui.window)
	clipboard_init()
	defer clipboard.destroy()
	// Whatever the paste thread is doing, it uses the clipboard, so it
	// has to be done before that (defers run in reverse).
	defer paste_wait(ui)
	glfw.SetWindowSizeLimits(ui.window, 480, 300, glfw.DONT_CARE, glfw.DONT_CARE)
	glfw.MakeContextCurrent(ui.window)
	glfw.SwapInterval(1)
	gl.load_up_to(3, 3, glfw.gl_set_proc_address)

	if !renderer_init(&ui.renderer) {
		log.error("failed to set up OpenGL rendering")
		return false
	}
	defer renderer_destroy(&ui.renderer)
	ui.renderer.images = &ui.images
	ui_images_init(ui)
	defer ui_images_destroy(ui)

	mu.init(&ui.ctx, set_clipboard, get_clipboard)
	ui.ctx.text_width = ui_text_width
	ui.ctx.text_height = ui_text_height
	ui.input_scale = 1

	glfw.SetCursorPosCallback(ui.window, cursor_pos_callback)
	glfw.SetMouseButtonCallback(ui.window, mouse_button_callback)
	glfw.SetScrollCallback(ui.window, scroll_callback)
	glfw.SetKeyCallback(ui.window, key_callback)
	glfw.SetCharCallback(ui.window, char_callback)

	if opts.server != "" {
		ui.action = .Connect
	}

	for !glfw.WindowShouldClose(ui.window) {
		free_all(context.temp_allocator)

		switch ui.action {
		case .None:
		case .Connect:
			connect(ui)
		case .Disconnect:
			disconnect(ui)
		}
		ui.action = .None

		// Wake up for input, or often enough to animate the speaking
		// indicators. Listen back without a connection is fed from this
		// loop (monitor_update), so it needs to run at the display's rate.
		glfw.WaitEventsTimeout(1.0 / 240 if ui.monitor.streams.playback != nil else 1.0 / 30)

		// microui turns a press into focus for whatever `hover_id` names,
		// without re-checking the pointer, and only a control itself clears
		// its hover. If a hovered control vanishes (a screen change, a
		// relabeled button), the stale id could fire on a click anywhere
		// once the id reappears. Recomputing hover on every frame without a
		// press keeps it tied to what's actually under the pointer.
		if ui.ctx.mouse_pressed_bits == {} && ui.ctx.mouse_down_bits == {} {
			ui.ctx.hover_id = 0
		}

		if ui.settings_dirty && time.tick_since(ui.settings_saved) > time.Second {
			save_settings(ui)
		}

		// Listen back is a settings-page test; don't leave it running.
		if ui.page != .Settings {
			set_listen_back(ui, false)
		}
		monitor_update(ui)

		m := window_metrics(ui.window)
		if m != ui.metrics {
			ww, wh := glfw.GetWindowSize(ui.window)
			log.debugf(
				"ui: window %dx%d, framebuffer %dx%d, scale %.2f, layout %.0fx%.0f",
				ww,
				wh,
				m.fb_w,
				m.fb_h,
				m.scale,
				m.logical_w,
				m.logical_h,
			)
			ui.metrics = m
		}
		ui.input_scale = m.input_scale
		ui_images_frame(ui)
		mu.begin(&ui.ctx)
		layout(ui, i32(m.logical_w), i32(m.logical_h))
		mu.end(&ui.ctx)
		set_hand_cursor(ui, ui.chat.hovering)
		ui_chat_after_frame(ui)
		ui_images_after_frame(ui)
		render(
			&ui.renderer,
			&ui.ctx,
			m.logical_w,
			m.logical_h,
			m.fb_w,
			m.fb_h,
			m.scale,
			BACKGROUND,
		)
		glfw.SwapBuffers(ui.window)
	}

	disconnect(ui)
	monitor_stop(ui)
	if ui.settings_dirty {
		save_settings(ui)
	}
	return true
}

// clipboard_init sets up reading images from the clipboard. On Wayland it
// needs GLFW's connection, since only the focused window may read.
@(private = "file")
clipboard_init :: proc() {
	wayland: rawptr
	when ODIN_OS == .Linux {
		if glfw.GetPlatform() == glfw.PLATFORM_WAYLAND {
			wayland = glfw.GetWaylandDisplay()
		}
	}
	clipboard.init(wayland)
}

// set_hand_cursor switches between the pointing hand and the normal
// arrow.
set_hand_cursor :: proc(ui: ^UI, hand: bool) {
	if hand == ui.hand_shown {
		return
	}
	ui.hand_shown = hand
	if hand && ui.hand_cursor == nil {
		ui.hand_cursor = glfw.CreateStandardCursor(glfw.HAND_CURSOR)
	}
	glfw.SetCursor(ui.window, ui.hand_cursor if hand else nil)
}

// typed_name is the name field's contents, sanitized as the server would.
typed_name :: proc(ui: ^UI) -> string {
	buf := new([proto.MAX_NAME_SIZE]u8, context.temp_allocator)
	return proto.sanitize_name(string(ui.name_buf[:ui.name_len]), buf)
}

// apply_name saves the name field and, when connected, renames us.
apply_name :: proc(ui: ^UI) {
	name := typed_name(ui)
	if name == ui.settings.name {
		return
	}
	set_setting(&ui.settings.name, name)
	ui.settings_dirty = true
	if ui.session != nil {
		push_command(&ui.session.client.commands, Name_Command{strings.clone(name)})
	}
}

save_settings :: proc(ui: ^UI) {
	settings_save(ui.opts.settings_path, ui.settings)
	ui.settings_dirty = false
	ui.settings_saved = time.tick_now()
}

Window_Metrics :: struct {
	logical_w, logical_h: f32, // what the UI is laid out for
	fb_w, fb_h:           i32,
	scale:                f32, // physical pixels per logical pixel
	input_scale:          f32, // logical pixels per window coordinate
}

/*
Platforms disagree on what window coordinates are. On Wayland and macOS
they're logical and the framebuffer is bigger on high-DPI screens; on
Windows and X11 they're physical pixels, and the monitor's scale is only
known from the content scale. Either way we lay out in logical pixels
and render at `scale`.
*/
@(private = "file")
window_metrics :: proc(window: glfw.WindowHandle) -> (m: Window_Metrics) {
	w, h := glfw.GetWindowSize(window)
	m.fb_w, m.fb_h = glfw.GetFramebufferSize(window)
	if w <= 0 || h <= 0 || m.fb_w <= 0 {
		return {logical_w = 1, logical_h = 1, scale = 1, input_scale = 1}
	}

	ratio := f32(m.fb_w) / f32(w)
	if ratio > 1.01 {
		m.scale = ratio
		m.logical_w, m.logical_h = f32(w), f32(h)
	} else {
		content, _ := glfw.GetWindowContentScale(window)
		m.scale = max(content, 1)
		m.logical_w, m.logical_h = f32(m.fb_w) / m.scale, f32(m.fb_h) / m.scale
	}
	m.input_scale = m.logical_w / f32(w)
	return
}

@(private = "file")
connect :: proc(ui: ^UI) {
	disconnect(ui)
	monitor_stop(ui) // the connection opens the microphone itself
	server := strings.trim_space(string(ui.server_buf[:ui.server_len]))
	if server == "" {
		return
	}
	set_setting(&ui.settings.server, server)
	set_setting(&ui.settings.name, typed_name(ui))
	settings_save(ui.opts.settings_path, ui.settings)

	ns := new(Net_Session)
	ns.key_path = strings.clone(ui.opts.key_path)
	ns.server = strings.clone(server)
	ns.known_servers = strings.clone(ui.opts.known_servers)
	ns.channel = strings.clone(ui.opts.channel)
	ns.name = strings.clone(ui.settings.name)
	ns.client = new(Voice_Client)
	ns.client.view = &ui.view
	if voice_init(&ns.client.voice) {
		// Devices may have come or gone since the list was made.
		audio_refresh(&ui.audio)
		open_capture(&ui.audio, &ns.streams, &ns.client.voice, ui.settings.input_device)
		open_playback(&ui.audio, &ns.streams, &ns.client.voice, ui.settings.output_device)
	}
	ns.client.voice.muted = ui.muted
	ns.client.voice.deafened = ui.deafened
	// Told to the others as soon as we're in a channel (drive_sound).
	ns.client.channels.sound = sound_flags(ui.muted, ui.deafened)
	ns.client.voice.denoise = ui.settings.noise_suppression
	ns.client.voice.listen = ui.listen_back
	push_command(&ns.client.commands, Quality_Command{settings_quality(&ui.settings)})
	push_command(&ns.client.commands, gate_command(&ui.settings))
	for hex_key, u in ui.settings.users {
		if key, ok := parse_user_key(hex_key); ok {
			push_command(&ns.client.commands, Gain_Command{key, user_gain(u)})
		}
	}

	view_reset(&ui.view)
	{
		sync.guard(&ui.view.mutex)
		ui.view.status = .Connecting
		ui.view.server = strings.clone(server)
	}
	ns.thread = thread.create_and_start_with_poly_data(ns, net_thread, init_context = context)
	ui.session = ns
}

@(private = "file")
disconnect :: proc(ui: ^UI) {
	ns := ui.session
	if ns == nil {
		return
	}
	ui.session = nil
	// Devices first, so nothing touches the rings once the voice goes away.
	close_streams(&ns.streams, &ns.client.voice)
	sync.atomic_store(&ns.stop, true)
	thread.join(ns.thread)
	thread.destroy(ns.thread)

	voice_destroy(&ns.client.voice)
	free(ns.client)
	delete(ns.key_path)
	delete(ns.server)
	delete(ns.known_servers)
	delete(ns.channel)
	delete(ns.name)
	free(ns)

	// A failure message stays up until the next attempt.
	if ui.view.status != .Failed {
		view_reset(&ui.view)
	}
}

set_muted :: proc(ui: ^UI, muted: bool) {
	ui.muted = muted
	if ui.session != nil {
		push_command(&ui.session.client.commands, Mute_Command{muted})
	}
}

// Deafen silences everyone else. Like mute, it lives on the UI so it
// survives reconnecting, and is pushed to the network thread.
set_deafened :: proc(ui: ^UI, deafened: bool) {
	ui.deafened = deafened
	if ui.session != nil {
		push_command(&ui.session.client.commands, Deafen_Command{deafened})
	}
}

// reopen_audio switches a running connection to the devices now selected
// in the settings.
reopen_audio :: proc(ui: ^UI, input: bool) {
	if m := &ui.monitor; m.active {
		if input {
			open_capture(&ui.audio, &m.streams, &m.voice, ui.settings.input_device)
		} else if m.streams.playback != nil {
			open_playback(&ui.audio, &m.streams, &m.voice, ui.settings.output_device)
		}
	}
	ns := ui.session
	if ns == nil || ns.client.voice.encoder == nil {
		return
	}
	if input {
		open_capture(&ui.audio, &ns.streams, &ns.client.voice, ui.settings.input_device)
	} else {
		open_playback(&ui.audio, &ns.streams, &ns.client.voice, ui.settings.output_device)
	}
}

@(private = "file")
net_thread :: proc(ns: ^Net_Session) {
	c := ns.client
	defer client_close(c)
	if !client_open(c, ns.key_path, ns.server, ns.known_servers, ns.name) {
		return
	}
	if ns.channel != "" {
		request_join(c, ns.channel)
	}
	for !sync.atomic_load(&ns.stop) {
		if !client_step(c) {
			return
		}
	}
}

@(private = "file")
layout :: proc(ui: ^UI, w, h: i32) {
	ctx := &ui.ctx
	// One window that always fills the OS window.
	if cnt := mu.get_container(ctx, "yap"); cnt != nil {
		cnt.rect = {0, 0, w, h}
	}
	if mu.begin_window(ctx, "yap", {0, 0, w, h}, {.NO_TITLE, .NO_RESIZE, .NO_CLOSE}) {
		main_window(ui, h)
		// After the panels, so it sits on top of them, and inside the
		// window, which is where microui can draw at all.
		icon_hint(ui, w, h)
		mu.end_window(ctx)
	}
	// An enlarged image floats above it all (ui_images.odin).
	image_viewer(ui, w, h)
}

@(private = "file")
main_window :: proc(ui: ^UI, h: i32) {
	if ui.page == .Settings {
		settings_page(ui, h)
		return
	}

	v := &ui.view
	sync.guard(&v.mutex)
	switch v.status {
	case .Disconnected, .Failed:
		connect_screen(ui)
	case .Connecting, .Connected:
		session_screen(ui)
	}
}

@(private = "file")
connect_screen :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := &ui.view

	mu.layout_row(ctx, {60, -74, ICON_BUTTON, ICON_BUTTON})
	mu.label(ctx, "Server")
	if .SUBMIT in mu.textbox(ctx, ui.server_buf[:], &ui.server_len) {
		ui.action = .Connect
	}
	if .SUBMIT in icon_button(ui, "send", .Send, "Connect") {
		ui.action = .Connect
	}
	if .SUBMIT in icon_button(ui, "settings", .Settings, "Settings") {
		ui.page = .Settings
	}

	mu.layout_row(ctx, {60, 200, -1})
	mu.label(ctx, "Name")
	if .SUBMIT in mu.textbox(ctx, ui.name_buf[:], &ui.name_len) {
		ui.action = .Connect
	}

	mu.layout_row(ctx, {-1})
	mu.label(
		ctx,
		fmt.tprintf(
			"Your key: %s   (server as host:port, e.g. localhost:7777)",
			fingerprint(ui.my_key),
		),
	)
	if v.status == .Failed && v.error != "" {
		with_text_color(ctx, {230, 90, 90, 255}, v.error, label_proc)
	}

	mu.layout_row(ctx, {-1}, -1)
	log_panel(ui)
}

@(private = "file")
session_screen :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := &ui.view

	mu.layout_row(ctx, {-140, ICON_BUTTON, ICON_BUTTON, ICON_BUTTON, ICON_BUTTON})
	switch v.status {
	case .Connected:
		me := v.my_name if v.my_name != "" else fingerprint(v.my_key)
		mu.label(ctx, fmt.tprintf("Connected to %s as %s", v.server, me))
	case .Connecting, .Disconnected, .Failed:
		mu.label(ctx, fmt.tprintf("Connecting to %s...", v.server))
	}
	if .SUBMIT in
	   icon_button(
		   ui,
		   "mute",
		   .Mic_Off if ui.muted else .Mic,
		   "Unmute" if ui.muted else "Mute",
		   OFF_COLOR if ui.muted else mu.Color{},
	   ) {
		set_muted(ui, !ui.muted)
	}
	if .SUBMIT in
	   icon_button(
		   ui,
		   "deafen",
		   .Sound_Off if ui.deafened else .Sound,
		   "Undeafen" if ui.deafened else "Deafen (hear nobody)",
		   OFF_COLOR if ui.deafened else mu.Color{},
	   ) {
		set_deafened(ui, !ui.deafened)
	}
	if .SUBMIT in icon_button(ui, "settings", .Settings, "Settings") {
		ui.page = .Settings
	}
	if .SUBMIT in icon_button(ui, "disconnect", .Leave, "Disconnect", OFF_COLOR) {
		log.debug("ui: disconnect")
		ui.action = .Disconnect
	}

	mu.layout_row(ctx, {280, -1}, -1)
	mu.begin_panel(ctx, "channels")
	if len(v.channels) == 0 {
		mu.layout_row(ctx, {-1})
		mu.label(ctx, "Waiting for the channel list...")
	}
	for ch, i in v.channels {
		mu.push_id(ctx, uintptr(i))
		defer mu.pop_id(ctx)

		marker := "  "
		switch i {
		case v.my_channel:
			marker = "> "
		case v.joining:
			marker = "~ "
		}
		mu.layout_row(ctx, {-1})
		label := fmt.tprintf("%s%s (%d)", marker, ch.name, len(ch.members))
		if .SUBMIT in stable_button(ctx, "join", label) && i != v.my_channel && ui.session != nil {
			log.debugf("ui: join %q", ch.name)
			push_command(&ui.session.client.commands, Join_Command{strings.clone(ch.name)})
		}

		for m in ch.members {
			member_row(ui, m)
		}
	}
	mu.end_panel(ctx)
	user_menu(ui)

	side_panel(ui)
}

log_panel :: proc(ui: ^UI) {
	ctx := &ui.ctx
	logs := ui.opts.logs

	mu.begin_panel(ctx, "log")
	cnt := mu.get_current_container(ctx)
	total: int
	{
		// No logging in here: the log sink takes this same lock.
		sync.guard(&logs.mutex)
		total = logs.total
		for line in logs.lines {
			mu.layout_row(ctx, {-1})
			// Drop the date; the time is enough on screen.
			text := line.text[11:] if len(line.text) > 11 else line.text
			switch {
			case line.level >= .Error:
				with_text_color(ctx, {230, 90, 90, 255}, text, label_proc)
			case line.level >= .Warning:
				with_text_color(ctx, {230, 200, 90, 255}, text, label_proc)
			case line.level < .Info:
				with_text_color(ctx, {140, 140, 140, 255}, text, label_proc)
			case:
				mu.label(ctx, text)
			}
		}
	}
	mu.end_panel(ctx)

	// Follow new lines.
	if total != ui.log_seen {
		ui.log_seen = total
		cnt.scroll.y = cnt.content_size.y
	}
}

// stable_button is mu.button, except its id comes from `id_name` (under
// the current id stack) rather than from the label, so the label can
// change from frame to frame without the button becoming a new control.
/*
icon_button is a button with an icon on it instead of a label, and the
words it saves shown under it while the pointer is on it. Like
stable_button its id comes from `id_name`, so a button that changes
what it shows (mute to unmute) keeps the same one.
*/
icon_button :: proc(
	ui: ^UI,
	id_name: string,
	icon: Icon,
	hint: string,
	color := mu.Color{},
) -> (
	res: mu.Result_Set,
) {
	ctx := &ui.ctx
	id := mu.get_id(ctx, id_name)
	r := mu.layout_next(ctx)
	mu.update_control(ctx, id, r)
	if ctx.mouse_pressed_bits == {.LEFT} && ctx.focus_id == id {
		res += {.SUBMIT}
	}
	mu.draw_control_frame(ctx, id, r, .BUTTON)
	mu.draw_icon(ctx, icon_id(icon), r, color if color.a != 0 else ctx.style.colors[.TEXT])
	if ctx.hover_id == id {
		ui.hint, ui.hint_of = hint, r
	}
	return
}

/*
icon_hint draws what the icon button under the pointer does, just below
it. It comes after the panels it may overlap, so it's drawn over them
rather than under.
*/
@(private = "file")
icon_hint :: proc(ui: ^UI, window_w, window_h: i32) {
	ctx := &ui.ctx
	if ui.hint == "" {
		return
	}
	defer ui.hint = ""

	pad := ctx.style.padding
	w := ctx.text_width(ctx.style.font, ui.hint) + 2 * pad
	h := ctx.text_height(ctx.style.font) + 2 * pad
	// Under the button, pushed left if it would go off the side, and
	// above it if there's no room below (the chat box's Send button).
	x := min(ui.hint_of.x, max(window_w - w, 0))
	y := ui.hint_of.y + ui.hint_of.h + 2
	if y + h > window_h {
		y = max(ui.hint_of.y - h - 2, 0)
	}
	r := mu.Rect{x, y, w, h}
	mu.draw_rect(ctx, r, ctx.style.colors[.BASE])
	mu.draw_box(ctx, r, ctx.style.colors[.BORDER])
	mu.draw_text(ctx, ctx.style.font, ui.hint, {x + pad, y + pad}, ctx.style.colors[.TEXT])
}

stable_button :: proc(ctx: ^mu.Context, id_name: string, label: string) -> (res: mu.Result_Set) {
	id := mu.get_id(ctx, id_name)
	r := mu.layout_next(ctx)
	mu.update_control(ctx, id, r)
	if ctx.mouse_pressed_bits == {.LEFT} && ctx.focus_id == id {
		res += {.SUBMIT}
	}
	mu.draw_control_frame(ctx, id, r, .BUTTON)
	mu.draw_control_text(ctx, label, r, .TEXT)
	return
}

label_proc :: proc(ctx: ^mu.Context, text: string) {
	mu.label(ctx, text)
}

with_text_color :: proc(
	ctx: ^mu.Context,
	color: mu.Color,
	text: string,
	widget: proc(ctx: ^mu.Context, text: string),
) {
	saved := ctx.style.colors[.TEXT]
	ctx.style.colors[.TEXT] = color
	widget(ctx, text)
	ctx.style.colors[.TEXT] = saved
}

@(private = "file")
glfw_error_callback :: proc "c" (code: i32, description: cstring) {
	context = runtime.default_context()
	context.logger = g_logger
	log.errorf("GLFW: %s (0x%x)", description, code)
}

// GLFW input -> microui. Callbacks run on the main thread, inside
// glfw.WaitEventsTimeout.

@(private = "file")
to_logical :: proc "contextless" (v: f64) -> i32 {
	return i32(v * f64(g_ui.input_scale))
}

@(private = "file")
cursor_pos_callback :: proc "c" (window: glfw.WindowHandle, x, y: f64) {
	context = runtime.default_context()
	mu.input_mouse_move(&g_ui.ctx, to_logical(x), to_logical(y))
}

@(private = "file")
mouse_button_callback :: proc "c" (window: glfw.WindowHandle, button, action, mods: i32) {
	context = runtime.default_context()
	context.logger = g_logger
	btn: mu.Mouse
	switch button {
	case glfw.MOUSE_BUTTON_LEFT:
		btn = .LEFT
	case glfw.MOUSE_BUTTON_RIGHT:
		btn = .RIGHT
	case glfw.MOUSE_BUTTON_MIDDLE:
		btn = .MIDDLE
	case:
		return
	}
	wx, wy := glfw.GetCursorPos(window)
	x, y := to_logical(wx), to_logical(wy)
	log.debugf("ui: mouse %v %s at %d,%d", btn, action == glfw.PRESS ? "down" : "up", x, y)
	// Hover was worked out at the last known pointer position. If the
	// press is somewhere else (motion events were missed), it would click
	// whatever was under the old position, so drop the hover instead.
	if action == glfw.PRESS && g_ui.ctx.mouse_pos != {x, y} {
		g_ui.ctx.hover_id = 0
	}
	switch action {
	case glfw.PRESS:
		mu.input_mouse_down(&g_ui.ctx, x, y, btn)
	case glfw.RELEASE:
		mu.input_mouse_up(&g_ui.ctx, x, y, btn)
	}
}

@(private = "file")
scroll_callback :: proc "c" (window: glfw.WindowHandle, x, y: f64) {
	context = runtime.default_context()
	mu.input_scroll(&g_ui.ctx, i32(-x * 30), i32(-y * 30))
}

@(private = "file")
char_callback :: proc "c" (window: glfw.WindowHandle, codepoint: rune) {
	context = runtime.default_context()
	buf, n := utf8.encode_rune(codepoint)
	mu.input_text(&g_ui.ctx, string(buf[:n]))
}

@(private = "file")
key_callback :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
	context = runtime.default_context()
	k: mu.Key
	switch key {
	case glfw.KEY_LEFT_SHIFT, glfw.KEY_RIGHT_SHIFT:
		k = .SHIFT
	case glfw.KEY_LEFT_CONTROL, glfw.KEY_RIGHT_CONTROL:
		k = .CTRL
	case glfw.KEY_LEFT_ALT, glfw.KEY_RIGHT_ALT:
		k = .ALT
	case glfw.KEY_BACKSPACE:
		k = .BACKSPACE
	case glfw.KEY_DELETE:
		k = .DELETE
	case glfw.KEY_ESCAPE:
		// Close the enlarged image, if one is open.
		if action == glfw.PRESS {
			g_ui.images.viewer = 0
		}
		return
	case glfw.KEY_ENTER, glfw.KEY_KP_ENTER:
		k = .RETURN
	case glfw.KEY_LEFT:
		k = .LEFT
	case glfw.KEY_RIGHT:
		k = .RIGHT
	case glfw.KEY_HOME:
		k = .HOME
	case glfw.KEY_END:
		k = .END
	case glfw.KEY_A:
		k = .A
	case glfw.KEY_X:
		k = .X
	case glfw.KEY_C:
		k = .C
	case glfw.KEY_V:
		k = .V
	case:
		return
	}
	switch action {
	case glfw.PRESS, glfw.REPEAT:
		mu.input_key_down(&g_ui.ctx, k)
	case glfw.RELEASE:
		mu.input_key_up(&g_ui.ctx, k)
	}
}

@(private = "file")
set_clipboard :: proc(user_data: rawptr, text: string) -> bool {
	glfw.SetClipboardString(g_ui.window, strings.clone_to_cstring(text, context.temp_allocator))
	return true
}

@(private = "file")
get_clipboard :: proc(user_data: rawptr) -> (string, bool) {
	text := glfw.GetClipboardString(g_ui.window)
	return text, text != ""
}

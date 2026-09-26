package client

import log "../common/wlog"
import "core:crypto/ecdh"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import "core:unicode/utf8"
import mu "vendor:microui"
import gl "wgl"
import glfw "wglfw"

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
	password:      string, // for `server`
	channel:       string, // joined on connect
	logs:          ^Log_Lines,
	settings_path: string,
}

// The connection and the thread (or the frame loop) running it; see
// net_native.odin and net_web.odin.
Net_Session :: struct {
	client:        ^Voice_Client,
	thread:        Net_Thread,
	stop:          bool, // set atomically to end the network loop
	// Without threads there is nobody to notice `stop`, so the frame
	// loop notes here that the connection is done with (net_web.odin).
	stopped:       bool,

	// Owned copies; the UI's buffers may change while the thread runs.
	key_path:      string,
	server:        string,
	password:      string,
	known_servers: string,
	channel:       string,
	name:          string,

	// Audio devices, opened and closed on the UI thread (which owns the
	// miniaudio context); they feed the client's Voice rings.
	streams:       Audio_Streams,
	// An explicit disconnect keeps playback open while this local effect
	// drains. Application shutdown and reconnects skip it.
	goodbye_tail:  bool,
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
	Trust_Key, // the connect screen's "trust the new key" (ui_known_servers.odin)
}

UI :: struct {
	window:              glfw.WindowHandle,
	ctx:                 mu.Context,
	renderer:            Renderer,
	opts:                UI_Options,
	my_key:              [proto.KEY_SIZE]u8,
	server_buf:          [256]u8,
	server_len:          int,
	password_buf:        [proto.MAX_PASSWORD_SIZE]u8,
	password_len:        int,
	// Room for more than MAX_NAME_SIZE while typing; sanitize_name trims it.
	name_buf:            [2 * proto.MAX_NAME_SIZE]u8,
	name_len:            int,
	view:                View,
	session:             ^Net_Session,
	// Connecting/disconnecting waits on the network thread, which may be
	// waiting on the View lock, so it happens after layout, not during.
	action:              Action,
	log_seen:            int, // Log_Lines.total when the log panel was last scrolled
	chat:                UI_Chat, // the chat tab (ui_chat.odin)
	video:               UI_Video, // screen sharing (ui_video.odin)
	muted:               bool,
	deafened:            bool,
	// Mute as it was before deafening turned it on, so undeafening can
	// put it back rather than always unmuting (see set_deafened).
	muted_before_deafen: bool,

	// The user whose menu is open, and its volume slider's value (the
	// slider needs a stable address). See user_menu.
	menu_user:           proto.User_Num,
	menu_key:            [proto.KEY_SIZE]u8,
	menu_volume:         mu.Real,
	menu_requested:      bool,
	// The menu's poke message (ui_users.odin).
	poke_buf:            [proto.MAX_POKE_SIZE]u8,
	poke_len:            int,
	// The settings page's microphone monitor and level meter (ui_gate.odin).
	monitor:             Mic_Monitor,
	listen_back:         bool,
	meter_level:         f32,
	meter_time:          time.Tick,
	// Slider drags change the settings every frame; save at most once a
	// second, and on exit.
	settings_dirty:      bool,
	settings_saved:      time.Tick,
	page:                Page,
	settings:            Settings,
	about:               UI_About, // the About dialog (ui_about.odin)
	known:               UI_Known_Servers, // saved server keys (ui_known_servers.odin)
	hotkeys:             UI_Hotkeys, // global hotkeys (ui_hotkeys_native.odin)
	install:             UI_Install, // installing for the user (ui_install_native.odin)
	// The UI scale slider's own value, percent, live while it's being
	// dragged; only copied into settings.ui_scale on release, since
	// applying it while dragging resizes the very slider being dragged
	// (see ui_settings.odin).
	ui_scale_draft:      f32,
	audio:               Audio,

	// Logical pixels per window coordinate, for mouse input. See
	// window_metrics.
	input_scale:         f32,
	// Where this frame's text boxes are, and whether one has the focus:
	// for a phone's keyboard, in a web build (see ui_text_box.odin).
	text_boxes:          [dynamic]Text_Box,
	text_focused:        bool,
	metrics:             Window_Metrics,
	// The pointing hand shown over links; created on first use, freed by
	// glfw.Terminate.
	hand_cursor:         glfw.CursorHandle,
	hand_shown:          bool,
	// The image paste being read, if any (ui_paste.odin).
	paste:               ^Paste_Job,
	// What the icon button under the pointer does, and where it is, for
	// the hint drawn under it (see icon_button and icon_hint).
	hint:                string,
	hint_of:             mu.Rect,
	// Chat images: decoded pictures and their textures (ui_images.odin).
	images:              UI_Images,
	// The system tray icon, if it's switched on (ui_tray.odin).
	tray:                Tray,
	// The window is away in the tray, and nothing is drawn until it
	// comes back. Quitting is the one thing that gets past it.
	hidden:              bool,
	quitting:            bool,
	// The desktop has just minimized us (iconify_callback).
	minimized:           bool,
	// What size to come back at, remembered when the window goes away.
	window_size:         [2]i32,
	// Where the swap doesn't wait for the display (see window_open), the
	// shortest time between frames, and when the last one went out.
	frame_pace:          time.Duration,
	last_swap:           time.Tick,
}

// For GLFW's callbacks, which have no user data we can use cheaply, and
// the page's touch input in a web build (ui_touch_web.odin).
g_ui: ^UI
@(private = "file")
g_logger: log.Logger

BACKGROUND :: mu.Color{30, 30, 30, 255}

/*
run_ui drives the client from a loop of its own, which is what a desktop
gives us. A web build has no loop to call its own - the browser hands
out a frame at a time - so the work is split into starting up, one turn
round the loop, and shutting down, and main_web.odin drives those.
*/
run_ui :: proc(opts: UI_Options) -> bool {
	ui := new(UI)
	defer free(ui)
	if !ui_startup(ui, opts) {
		ui_shutdown(ui)
		return false
	}
	for ui_frame(ui) {}
	ui_shutdown(ui)
	return true
}

ui_startup :: proc(ui: ^UI, opts: UI_Options) -> bool {
	g_ui = ui
	g_logger = context.logger
	ui.opts = opts
	view_init(&ui.view)
	ui_chat_init(ui)

	// Load (or create) the key now, to show our id before connecting.
	{
		key: ecdh.Private_Key
		if common.load_or_create_private_key(opts.key_path, &key) {
			ecdh.private_key_public_bytes(&key, ui.my_key[:])
			ecdh.private_key_clear(&key)
		}
	}
	ui.settings = settings_load(opts.settings_path)
	ui.ui_scale_draft = ui_scale_factor(&ui.settings) * 100
	initial := opts.server if opts.server != "" else ui.settings.server
	ui.server_len = copy(ui.server_buf[:], initial)
	password := opts.password
	if password == "" {
		password = recent_password(&ui.settings, initial)
	}
	ui.password_len = copy(ui.password_buf[:], password)
	name := ui.settings.name if ui.settings.name != "" else default_name()
	ui.name_len = copy(ui.name_buf[:], name)

	// Audio problems shouldn't keep the rest of the client from working;
	// the settings page shows what went wrong.
	audio_init(&ui.audio)

	glfw.SetErrorCallback(glfw_error_callback)
	if !glfw.Init() {
		log.error("failed to initialize GLFW")
		return false
	}

	ui.window_size = {760, 480}
	if !window_open(ui) {
		return false
	}
	clipboard_init()
	ui_images_init(ui)

	mu.init(&ui.ctx, set_clipboard, get_clipboard)
	ui.ctx.text_width = ui_text_width
	ui.ctx.text_height = ui_text_height
	ui.input_scale = 1

	if opts.server != "" {
		ui.action = .Connect
	}
	return true
}

// ui_frame is one turn round the loop. It returns false when the client
// is done and should shut down.
ui_frame :: proc(ui: ^UI) -> bool {
	if ui.quitting {
		return false
	}

	// Closing the window puts the client in the tray instead of
	// ending it, where there's a tray icon and that's what the
	// settings ask for (see ui_tray.odin). Quit in the tray menu
	// sets `quitting` instead, and there may be no window at all.
	if ui.window != nil && glfw.WindowShouldClose(ui.window) {
		if !tray_takes_window(ui, ui.settings.close_to_tray) {
			return false
		}
		glfw.SetWindowShouldClose(ui.window, false)
		hide_to_tray(ui)
	}

	// Minimizing can go to the tray as well. Only some desktops say
	// when it happens (see iconify_callback).
	if ui.minimized {
		ui.minimized = false
		if tray_takes_window(ui, ui.settings.minimize_to_tray) {
			// Out of the minimized state first, so the window comes
			// back up as a window rather than minimized again.
			glfw.RestoreWindow(ui.window)
			hide_to_tray(ui)
		}
	}

	free_all(context.temp_allocator)

	switch ui.action {
	case .None:
	case .Connect:
		connect(ui)
	case .Disconnect:
		disconnect(ui, true)
	case .Trust_Key:
		trust_new_key(ui)
	}
	ui.action = .None
	disconnect_tail_step(ui)

	// Wake up for input, or often enough to animate the speaking
	// indicators. Listen back without a connection is fed from this
	// loop (monitor_update), so it needs to run at the display's rate.
	// In a web build the browser has already decided when this frame
	// happens, and there is nothing to wait for.
	glfw.WaitEventsTimeout(1.0 / 240 if ui.monitor.streams.playback != nil else 1.0 / 30)

	// Without threads there is nobody else to run the connection, so it
	// gets its turn here, between frames (see net_thread).
	// Touch comes in as a queue, one event per frame (ui_touch_web.odin).
	when WEB {
		net_step(ui)
		touch_step(ui)
	}

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
	show_pokes(ui)
	// Before the tray, so it shows what a hotkey just did, and before
	// giving up for a hidden window, since they work without one.
	hotkeys_frame(ui)
	tray_update(ui)
	if ui.hidden {
		return true // no window to draw in
	}

	m := window_metrics(ui.window, ui_scale_factor(&ui.settings))
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
	clear(&ui.text_boxes)
	mu.begin(&ui.ctx)
	layout(ui, i32(m.logical_w), i32(m.logical_h))
	mu.end(&ui.ctx)
	when WEB {
		touch_after_frame(ui)
	}
	set_hand_cursor(ui, ui.chat.hovering)
	ui_chat_after_frame(ui)
	ui_images_after_frame(ui)
	render(&ui.renderer, &ui.ctx, m.fb_w, m.fb_h, m.scale, BACKGROUND)
	glfw.SwapBuffers(ui.window)
	// A browser paces frames itself, and a page can't sleep.
	when !WEB {
		if ui.frame_pace > 0 {
			if left := ui.frame_pace - time.tick_since(ui.last_swap); left > 0 {
				time.sleep(left)
			}
			ui.last_swap = time.tick_now()
		}
	}
	return true
}

// ui_shutdown takes everything down in the order it went up.
ui_shutdown :: proc(ui: ^UI) {
	disconnect(ui)
	hotkeys_stop(ui)
	tray_hide(ui)
	monitor_stop(ui)
	if ui.settings_dirty {
		save_settings(ui)
	}
	ui_images_destroy(ui)
	ui_video_destroy(ui)
	delete(ui.text_boxes)
	// Whatever the paste thread is doing, it uses the clipboard, so it
	// has to be done before that.
	paste_wait(ui)
	clipboard.destroy()
	window_close(ui)
	glfw.Terminate()
	audio_destroy(&ui.audio)
	settings_destroy(&ui.settings)
	known_servers_destroy(ui)
	install_destroy(ui)
	ui_chat_destroy(ui)
	view_destroy(&ui.view)
}

/*
The window and everything that lives in its OpenGL context. They come
and go together, because hiding the client in the tray takes the window
down altogether (see hide_to_tray): a Wayland surface that has been
unmapped can't be brought back - the EGL buffers behind it are never
released, and the next swap waits for them for ever.

Nothing above the context survives in here: microui's state, the view,
the connection and the tray icon all carry on across a window.
*/
/*
set_swap_pace decides what keeps frames to the display's rate.

Usually that's the swap: it waits for the display (vsync). On Wayland
that wait is for the compositor's go-ahead, which it only gives a window
it's showing - minimized, or on another virtual desktop, the swap would
wait until the window is looked at again, and everything else on this
thread with it: pokes, the tray icon, listen back. So there the swap
doesn't wait, and the loop keeps to the monitor's refresh rate itself
(frame_pace, at the end of ui_frame). Wayland never tears, so nothing is
lost.
*/
@(private = "file")
set_swap_pace :: proc(ui: ^UI) {
	ui.frame_pace = 0
	when !WEB {
		if on_wayland() {
			glfw.SwapInterval(0)
			refresh: i32 = 60
			if monitor := glfw.GetPrimaryMonitor(); monitor != nil {
				if mode := glfw.GetVideoMode(monitor); mode != nil && mode.refresh_rate > 0 {
					refresh = mode.refresh_rate
				}
			}
			ui.frame_pace = time.Second / time.Duration(refresh)
			log.debugf("ui: Wayland, so frames are paced here, at %d Hz", refresh)
			return
		}
	}
	glfw.SwapInterval(1)
}

window_open :: proc(ui: ^UI) -> bool {
	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 3)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 3)
	glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
	// Where window coordinates are physical pixels (Windows, X11), size
	// the window for the monitor's scale so it isn't tiny on high DPI.
	glfw.WindowHint(glfw.SCALE_TO_MONITOR, true)
	when ODIN_OS == .Darwin {
		glfw.WindowHint(glfw.OPENGL_FORWARD_COMPAT, true)
	}
	when !WEB {
		// The name of the installed .desktop entry (install_unix.odin),
		// which is how Wayland finds the window's icon and how the
		// desktop groups the window under the entry.
		glfw.WindowHintString(glfw.WAYLAND_APP_ID, "yap")
		glfw.WindowHintString(glfw.X11_CLASS_NAME, "yap")
		glfw.WindowHintString(glfw.X11_INSTANCE_NAME, "yap")
	}
	ui.window = glfw.CreateWindow(ui.window_size.x, ui.window_size.y, "Yap", nil, nil)
	if ui.window == nil {
		log.error("failed to create a window (OpenGL 3.3 is required)")
		return false
	}
	glfw.SetWindowSizeLimits(ui.window, 480, 300, glfw.DONT_CARE, glfw.DONT_CARE)
	when !WEB {
		set_window_icon(ui.window)
	}
	glfw.MakeContextCurrent(ui.window)
	set_swap_pace(ui)
	gl.load_up_to(3, 3, glfw.gl_set_proc_address)

	if !renderer_init(&ui.renderer) {
		log.error("failed to set up OpenGL rendering")
		glfw.DestroyWindow(ui.window)
		ui.window = nil
		return false
	}
	ui.renderer.images = &ui.images

	glfw.SetWindowIconifyCallback(ui.window, iconify_callback)
	glfw.SetCursorPosCallback(ui.window, cursor_pos_callback)
	glfw.SetMouseButtonCallback(ui.window, mouse_button_callback)
	glfw.SetScrollCallback(ui.window, scroll_callback)
	glfw.SetKeyCallback(ui.window, key_callback)
	glfw.SetCharCallback(ui.window, char_callback)
	// The cursor outlives the window, but which one the window shows
	// doesn't (see set_hand_cursor).
	ui.hand_shown = false
	ui.metrics = {}
	return true
}

window_close :: proc(ui: ^UI) {
	if ui.window == nil {
		return
	}
	// Come back the same size as we went away.
	w, h := glfw.GetWindowSize(ui.window)
	ui.window_size = {w, h}
	renderer_destroy(&ui.renderer)
	// The pictures' textures belong to the context that's about to go;
	// they are decoded again when they're next on screen.
	ui_images_forget_textures(ui)
	ui_video_forget_texture(ui)
	glfw.DestroyWindow(ui.window)
	ui.window = nil
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
window_metrics :: proc(window: glfw.WindowHandle, ui_scale: f32) -> (m: Window_Metrics) {
	w, h := glfw.GetWindowSize(window)
	m.fb_w, m.fb_h = glfw.GetFramebufferSize(window)
	if w <= 0 || h <= 0 || m.fb_w <= 0 {
		return {logical_w = 1, logical_h = 1, scale = 1, input_scale = 1}
	}

	// A browser says what its ratio is (wglfw_web.odin); the framebuffer's
	// whole pixels would only give an approximation that changes with the
	// window's size, and with it the font's rasterization.
	ratio := f32(m.fb_w) / f32(w)
	if ratio > 1.01 && !WEB {
		m.scale = ratio
		m.logical_w, m.logical_h = f32(w), f32(h)
	} else {
		content, _ := glfw.GetWindowContentScale(window)
		m.scale = max(content, 1)
		m.logical_w, m.logical_h = f32(m.fb_w) / m.scale, f32(m.fb_h) / m.scale
	}

	// The UI's own zoom stacks with the display's DPI scale above:
	// shrinking the logical canvas the layout runs in, while rendering it
	// at a proportionally higher `scale`, makes every logical-pixel-sized
	// widget cover more of the screen without the layout code (or the
	// font/icon atlases, which already rebuild when `scale` changes)
	// knowing the difference.
	m.scale *= ui_scale
	m.logical_w /= ui_scale
	m.logical_h /= ui_scale
	m.input_scale = m.logical_w / f32(w)
	return
}

connect :: proc(ui: ^UI) {
	disconnect(ui)
	monitor_stop(ui) // the connection opens the microphone itself
	server := with_default_port(string(ui.server_buf[:ui.server_len]))
	if server == "" {
		return
	}
	// Show the port that was assumed; it's what gets saved, too.
	ui.server_len = copy(ui.server_buf[:], server)
	// Taken as typed: spaces may well be part of a password.
	password := string(ui.password_buf[:ui.password_len])
	set_setting(&ui.settings.server, server)
	remember_recent_server(&ui.settings, server, password)
	set_setting(&ui.settings.name, typed_name(ui))
	save_settings(ui)

	ns := new(Net_Session)
	ns.key_path = strings.clone(ui.opts.key_path)
	ns.server = strings.clone(server)
	ns.password = strings.clone(password)
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
	ns.client.voice.notifications.volume = notification_gain(&ui.settings)
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
	net_start(ns)
	ui.session = ns
}

@(private = "file")
disconnect :: proc(ui: ^UI, play_goodbye := false) {
	ns := ui.session
	if ns == nil {
		return
	}
	// Nobody to share with any more.
	video_share_stop()
	if ns.goodbye_tail {
		disconnect_finish(ui)
		return
	}
	if play_goodbye && sync.atomic_load(&ns.client.voice.output) {
		// Stop the network producer, but leave the playback callback running.
		// The UI then owns the playback ring until the goodbye clip drains.
		close_capture(&ns.streams, &ns.client.voice)
		sync.atomic_store(&ns.stop, true)
		net_stop(ns)
		ns.goodbye_tail = true
		voice_notification_play(&ns.client.voice, .Goodbye)
		if notifications_pending(&ns.client.voice.notifications) {
			return
		}
	}
	disconnect_finish(ui)
}

// disconnect_tail_step runs after an explicit disconnect. No network thread is
// writing playback now, so the UI can fill it until the clip has drained.
@(private = "file")
disconnect_tail_step :: proc(ui: ^UI) {
	ns := ui.session
	if ns == nil || !ns.goodbye_tail {
		return
	}
	notification_tail_step(&ns.client.voice)
	if !notifications_pending(&ns.client.voice.notifications) &&
	   ring_available(&ns.client.voice.playback) == 0 {
		disconnect_finish(ui)
	}
}

@(private = "file")
disconnect_finish :: proc(ui: ^UI) {
	ns := ui.session
	if ns == nil {
		return
	}
	ui.session = nil
	// Devices first, so nothing touches the rings once the voice goes away.
	close_streams(&ns.streams, &ns.client.voice)
	if !ns.goodbye_tail {
		sync.atomic_store(&ns.stop, true)
		net_stop(ns)
	}

	voice_destroy(&ns.client.voice)
	free(ns.client)
	delete(ns.key_path)
	delete(ns.server)
	delete(ns.password)
	delete(ns.known_servers)
	delete(ns.channel)
	delete(ns.name)
	free(ns)

	// A failure message stays up until the next attempt.
	if ui.view.status != .Failed {
		view_reset(&ui.view)
	}
}

// set_muted plays the muted/unmuted sound, unless it's part of a
// deafen (`feedback` false), which plays its own.
set_muted :: proc(ui: ^UI, muted: bool, feedback := true) {
	if muted == ui.muted {
		return
	}
	ui.muted = muted
	if ui.session != nil {
		push_command(&ui.session.client.commands, Mute_Command{muted = muted, feedback = feedback})
	}
}

// Deafen silences everyone else. Like mute, it lives on the UI so it
// survives reconnecting, and is pushed to the network thread.
//
// Deafening also mutes, since not being able to hear anyone while still
// sending to them is a strange place to be in. It remembers what mute
// was set to beforehand, so undeafening restores that instead of always
// unmuting.
set_deafened :: proc(ui: ^UI, deafened: bool) {
	if deafened == ui.deafened {
		return
	}
	ui.deafened = deafened
	if deafened {
		ui.muted_before_deafen = ui.muted
		set_muted(ui, true, feedback = false)
	} else {
		set_muted(ui, ui.muted_before_deafen, feedback = false)
	}
	if ui.session != nil {
		push_command(&ui.session.client.commands, Deafen_Command{deafened = deafened, feedback = true})
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
	if ns == nil || !ns.client.voice.ready {
		return
	}
	if input {
		open_capture(&ui.audio, &ns.streams, &ns.client.voice, ui.settings.input_device)
	} else {
		open_playback(&ui.audio, &ns.streams, &ns.client.voice, ui.settings.output_device)
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
		main_window(ui)
		// After the panels, so it sits on top of them, and inside the
		// window, which is where microui can draw at all.
		icon_hint(ui, w, h)
		mu.end_window(ctx)
	}
	// An enlarged image floats above it all (ui_images.odin), and so
	// does the About dialog (ui_about.odin).
	image_viewer(ui, w, h)
	about_dialog(ui, w, h)
}

@(private = "file")
main_window :: proc(ui: ^UI) {
	if ui.page == .Settings {
		settings_page(ui)
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

	mu.layout_row(ctx, {70, -74, ICON_BUTTON, ICON_BUTTON})
	mu.label(ctx, "Server")
	if .SUBMIT in text_box(ui, ui.server_buf[:], &ui.server_len) {
		ui.action = .Connect
	}
	if .SUBMIT in icon_button(ui, "send", .Send, "Connect") {
		ui.action = .Connect
	}
	if .SUBMIT in icon_button(ui, "settings", .Settings, "Settings") {
		open_settings(ui)
	}

	mu.layout_row(ctx, {70, 200, -1})
	mu.label(ctx, "Password")
	if .SUBMIT in password_box(ui, ui.password_buf[:], &ui.password_len) {
		ui.action = .Connect
	}
	mu.label(ctx, "(if the server has one)")

	mu.layout_row(ctx, {70, 200, -1})
	mu.label(ctx, "Name")
	if .SUBMIT in text_box(ui, ui.name_buf[:], &ui.name_len) {
		ui.action = .Connect
	}

	mu.layout_row(ctx, {-1})
	mu.label(
		ctx,
		fmt.tprintf(
			"Your key: %s   (server as host or host:port; the port is 7777 if left out)",
			fingerprint(ui.my_key),
		),
	)
	if v.status == .Failed && v.error != "" {
		with_text_color(ctx, ERROR_COLOR, v.error, label_proc)
	}
	if v.status == .Failed && v.key_change.changed {
		key_change_panel(ui)
	}

	// Recent servers beside the log, or above it where there's no room.
	body := mu.get_current_container(ctx).body
	if len(ui.settings.recent_servers) == 0 {
		mu.layout_row(ctx, {-1}, -1)
	} else if body.w < NARROW_LAYOUT {
		mu.layout_row(ctx, {-1}, max(body.h / 3, 120))
		recent_servers_panel(ui)
		mu.layout_row(ctx, {-1}, -1)
	} else {
		mu.layout_row(ctx, {280, -1}, -1)
		recent_servers_panel(ui)
	}
	log_panel(ui)
}

// recent_servers_panel lists the servers connected to lately: one click
// connects again, with the password used last time.
@(private = "file")
recent_servers_panel :: proc(ui: ^UI) {
	ctx := &ui.ctx
	s := &ui.settings

	mu.begin_panel(ctx, "recent")
	defer mu.end_panel(ctx)
	mu.layout_row(ctx, {-1})
	mu.label(ctx, "Recent servers")

	forget := -1
	for r, i in s.recent_servers {
		mu.push_id(ctx, uintptr(i))
		defer mu.pop_id(ctx)

		mu.layout_row(ctx, {-(ICON_BUTTON + ctx.style.spacing), -1})
		label := r.address
		if r.password != "" {
			label = fmt.tprintf("%s  (password)", r.address)
		}
		if .SUBMIT in stable_button(ctx, "connect", label) {
			ui.server_len = copy(ui.server_buf[:], r.address)
			ui.password_len = copy(ui.password_buf[:], r.password)
			ui.action = .Connect
		}
		if .SUBMIT in stable_button(ctx, "forget", "x") {
			forget = i
		}
	}
	// Not while going through the list, which this changes.
	if forget >= 0 {
		forget_recent_server(s, s.recent_servers[forget].address)
		ui.settings_dirty = true
	}
}

// Narrower than this (a phone, a window squeezed aside), the channels
// go above the chat instead of beside it.
NARROW_LAYOUT :: 600

@(private = "file")
session_screen :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := &ui.view
	body := mu.get_current_container(ctx).body
	narrow := body.w < NARROW_LAYOUT

	screen_tab_follow(ui)
	if v.watching != 0 && video_is_fullscreen() {
		fullscreen_screen(ui)
		return
	}

	can_share := video_can_share()
	if can_share {
		mu.layout_row(ctx, {-174, ICON_BUTTON, ICON_BUTTON, ICON_BUTTON, ICON_BUTTON, ICON_BUTTON})
	} else {
		mu.layout_row(ctx, {-140, ICON_BUTTON, ICON_BUTTON, ICON_BUTTON, ICON_BUTTON})
	}
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
	if can_share {
		share_button(ui)
	}
	if .SUBMIT in icon_button(ui, "settings", .Settings, "Settings") {
		open_settings(ui)
	}
	if .SUBMIT in icon_button(ui, "disconnect", .Leave, "Disconnect", OFF_COLOR) {
		log.debug("ui: disconnect")
		ui.action = .Disconnect
	}

	if narrow {
		mu.layout_row(ctx, {-1}, max(body.h / 3, 120))
	} else {
		mu.layout_row(ctx, {280, -1}, -1)
	}
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

	if narrow {
		mu.layout_row(ctx, {-1}, -1)
	}
	side_panel(ui)
}

// How tightly log lines are packed: exactly LINE_HEIGHT tall, rather
// than the default control size's couple of pixels of unneeded slack,
// and a tighter gap than the rest of the UI uses between rows - so more
// of the log fits on screen at once.
@(private = "file")
LOG_LINE_SPACING :: 1

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

		saved_spacing := ctx.style.spacing
		ctx.style.spacing = LOG_LINE_SPACING
		defer ctx.style.spacing = saved_spacing

		for line in logs.lines {
			mu.layout_row(ctx, {-1}, LINE_HEIGHT)
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
	context = callback_context()
	context.logger = g_logger
	log.errorf("GLFW: %s (0x%x)", description, code)
}

// GLFW input -> microui. Callbacks run on the main thread, inside
// glfw.WaitEventsTimeout.

@(private = "file")
to_logical :: proc "contextless" (v: f64) -> i32 {
	return i32(v * f64(g_ui.input_scale))
}

/*
iconify_callback notes that the desktop has minimized us, for the loop
to put the client in the tray if that's what the settings say.

Not every desktop tells us. X11 does. Wayland has no message for it, so
there the window simply minimizes and the setting does nothing; the
settings page says as much when it would matter.
*/
@(private = "file")
iconify_callback :: proc "c" (window: glfw.WindowHandle, iconified: i32) {
	if iconified != 0 {
		g_ui.minimized = true
	}
}

@(private = "file")
cursor_pos_callback :: proc "c" (window: glfw.WindowHandle, x, y: f64) {
	context = callback_context()
	mu.input_mouse_move(&g_ui.ctx, to_logical(x), to_logical(y))
}

@(private = "file")
mouse_button_callback :: proc "c" (window: glfw.WindowHandle, button, action, mods: i32) {
	context = callback_context()
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
	context = callback_context()
	mu.input_scroll(&g_ui.ctx, i32(-x * 30), i32(-y * 30))
}

@(private = "file")
char_callback :: proc "c" (window: glfw.WindowHandle, codepoint: rune) {
	context = callback_context()
	buf, n := utf8.encode_rune(codepoint)
	mu.input_text(&g_ui.ctx, string(buf[:n]))
}

@(private = "file")
key_callback :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
	context = callback_context()
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
	// Emscripten's GLFW has no clipboard: a browser's comes from the page
	// (ui_paste_web.odin).
	when WEB {
		return web_copy_text(text)
	} else {
		glfw.SetClipboardString(g_ui.window, strings.clone_to_cstring(text, context.temp_allocator))
		return true
	}
}

@(private = "file")
get_clipboard :: proc(user_data: rawptr) -> (string, bool) {
	when WEB {
		text := web_pasted_text()
	} else {
		text := glfw.GetClipboardString(g_ui.window)
	}
	return text, text != ""
}

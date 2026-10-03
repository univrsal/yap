package client

import glfw "client:wglfw"
import log "common:wlog"
import "core:crypto/ecdh"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:sync"
import "core:time"
import "core:unicode/utf8"
import mu "vendor:microui"

import "client:audio"
import "client:clipboard"
import "client:conn"
import "client:platform"
import "client:render"
import "client:settings"
import "common:."
import "common:proto"

/*
The windowed client: GLFW for the window and input, microui for widgets,
Direct3D 11 on Windows and OpenGL 3.3 elsewhere to draw them (see
render/render.odin).

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
	logs:          ^conn.Log_Lines,
	settings_path: string,
}

// The connection and the thread (or the frame loop) running it; see
// net_native.odin and net_web.odin.
Net_Session :: struct {
	client:        ^conn.Voice_Client,
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
	channel:       string, // to look at and talk in from the start, if any
	view:          string, // or else the channel to look at

	// Audio devices, opened and closed on the UI thread (which owns the
	// miniaudio context); they feed the client's Voice rings.
	streams:       audio.Audio_Streams,
	// The microphone is wanted, and has been opened, or tried to be
	// (session_capture_update).
	capture_on:    bool,
	// An explicit disconnect keeps playback open while this local effect
	// drains. Application shutdown and reconnects skip it.
	goodbye_tail:  bool,
}

Extra_Key :: enum {
	Up,
	Down,
	Tab,
	Escape,
}

Page :: enum {
	Main,
	Settings,
	Buddies, // only while connected (ui_buddies.odin)
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
	renderer:            render.Renderer,
	opts:                UI_Options,
	my_key:              [proto.KEY_SIZE]u8,
	server_buf:          [256]u8,
	server_len:          int,
	password_buf:        [proto.MAX_PASSWORD_SIZE]u8,
	password_len:        int,
	// Room for more than MAX_NAME_SIZE while typing; sanitize_name trims it.
	// What our account is called, as it's being edited in the settings.
	name_buf:            [2 * proto.MAX_NAME_SIZE]u8,
	name_len:            int,
	view:                conn.View,
	session:             ^Net_Session,
	// Connecting/disconnecting waits on the network thread, which may be
	// waiting on the View lock, so it happens after layout, not during.
	action:              Action,
	log_seen:            int, // Log_Lines.total when the log panel was last scrolled
	account:             UI_Account, // logging in, and the account's settings (ui_account.odin)
	channels:            UI_Channels, // the channel list and the Channels window (ui_channels.odin)
	timeline:            UI_Timeline, // the messages on screen (ui_timeline.odin)
	// Messages unread in channels that aren't muted, and what the window's
	// title says (-1: not set on this window yet).
	unread:              int,
	title_unread:        int,
	chat:                UI_Chat, // the chat tab (ui_chat.odin)
	settings_tab:        Settings_Tab, // which the settings page shows (ui_settings.odin)
	reactors_asked:      Reactors_Asked, // who reacted, last asked for (ui_timeline.odin)
	activity:            UI_Activity, // whether whoever uses this is idle (ui_activity.odin)
	forward:             UI_Forward, // forwarding, and links to messages (ui_forward.odin)
	search:              UI_Search, // searching messages (ui_search.odin)
	video:               UI_Video, // screen sharing (ui_video.odin)
	app_audio:           UI_App_Audio, // sharing an application's audio (ui_app_audio_native.odin)
	muted:               bool,
	deafened:            bool,
	// Mute as it was before deafening turned it on, so undeafening can
	// put it back rather than always unmuting (see set_deafened).
	muted_before_deafen: bool,

	// The user whose menu is open, and its volume slider's value (the
	// slider needs a stable address). See user_menu.
	menu_user:           proto.User_Num, // the connection clicked, if one was
	menu_account:        proto.Account_Id,
	menu_volume:         mu.Real,
	menu_requested:      bool,
	// The menu's poke message (ui_users.odin).
	// The buddy screen (ui_buddies.odin).
	buddies:             UI_Buddies,
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
	// Keys microui has no name for, pressed since the last frame.
	keys:                bit_set[Extra_Key],
	// A message was picked to edit, or a mention completed: its composer
	// takes the focus, with the cursor at `focus_composer_at` (-1: the
	// end).
	focus_composer:      bool,
	focus_composer_at:   int,
	focus_thread:        int, // which composer: Composer.thread
	// The thread windows (ui_threads.odin), by slot, and how many
	// threads have been opened, for which was opened first; and whether
	// the last frame was laid out narrow, when an open thread takes the
	// conversation's place instead of floating.
	threads:             [conn.MAX_THREADS]UI_Thread,
	// People's pictures (ui_avatars.odin), and statuses, members and
	// settings on the server (ui_profiles.odin).
	avatars:             UI_Avatars,
	profiles:            UI_Profiles,
	// Managing the server, for who may (ui_manage.odin), calls
	// (ui_calls.odin), and the voice panel (ui_voice_panel.odin).
	manage:              UI_Manage,
	calls:               UI_Calls,
	voice_panel:         UI_Voice_Panel,
	threads_opened:      u64,
	narrow:              bool,
	// Completing a mention in a composer (ui_completion.odin).
	completion:          UI_Completion,
	// The emoji picker (ui_picker.odin).
	picker:              UI_Picker,
	// The pinned messages' window (ui_pins.odin), and the menu of a
	// message (ui_message_menu.odin).
	pins:                UI_Pins,
	msg_menu:            UI_Message_Menu,
	// The server whose per-user volumes the session has been given
	// (apply_gains).
	gains_for:           [proto.KEY_SIZE]u8,
	settings_saved:      time.Tick,
	page:                Page,
	settings:            settings.Settings,
	about:               UI_About, // the About dialog (ui_about.odin)
	known:               UI_Known_Servers, // saved server keys (ui_known_servers.odin)
	hotkeys:             UI_Hotkeys, // global hotkeys (ui_hotkeys_native.odin)
	install:             UI_Install, // installing for the user (ui_install_native.odin)
	// The UI scale slider's own value, percent, live while it's being
	// dragged; only copied into settings.ui_scale on release, since
	// applying it while dragging resizes the very slider being dragged
	// (see ui_settings.odin).
	ui_scale_draft:      f32,
	chat_scale_draft:    f32, // the same, for the chat's text size
	audio:               audio.Audio,

	// Logical pixels per window coordinate, for mouse input. See
	// window_metrics.
	input_scale:         f32,
	// The strip along the top where macOS draws the window's buttons
	// over the UI, in logical pixels: where the first row starts, and
	// how tall the strip is. Zero elsewhere (see ui_titlebar_darwin.odin).
	titlebar_left:       i32,
	titlebar_height:     i32,
	// Where this frame's text boxes are, and whether one has the focus:
	// for a phone's keyboard, in a web build (see ui_text_box.odin).
	text_boxes:          [dynamic]Text_Box,
	text_focused:        bool,
	metrics:             Window_Metrics,
	// The pointing hand shown over links and the I-beam over text that
	// can be selected; created on first use, freed by glfw.Terminate.
	cursors:             [Cursor]glfw.CursorHandle,
	cursor_shown:        Cursor,
	// Text selected in the chat or the log (ui_select.odin).
	select:              Selection,
	// The image paste being read, if any (ui_paste.odin), and where the
	// next one goes.
	paste:               ^Paste_Job,
	paste_to:            Paste_Target,
	// The file dialog, while it's open (ui_files_native.odin).
	file_pick:           ^File_Pick_Job,
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
	// When the GPU device last had to be set up again (reset_gpu).
	gpu_reset_at:        time.Tick,
	// A frame is being drawn (draw_frame), which a refresh mustn't
	// start another one in the middle of.
	drawing:             bool,
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
	conn.view_init(&ui.view)
	ui_chat_init(ui)

	// Load (or create) the key now, to show our id before connecting.
	{
		key: ecdh.Private_Key
		if common.load_or_create_private_key(opts.key_path, &key) {
			ecdh.private_key_public_bytes(&key, ui.my_key[:])
			ecdh.private_key_clear(&key)
		}
	}
	ui.settings = settings.settings_load(opts.settings_path)
	ui.ui_scale_draft = settings.ui_scale_factor(&ui.settings) * 100
	ui.chat_scale_draft = settings.chat_scale_factor(&ui.settings) * 100
	initial := opts.server if opts.server != "" else ui.settings.server
	ui.server_len = copy(ui.server_buf[:], initial)
	password := opts.password
	if password == "" {
		password = settings.recent_password(&ui.settings, initial)
	}
	ui.password_len = copy(ui.password_buf[:], password)
	ui.account.username_len = copy(ui.account.username_buf[:], ui.settings.username)

	// Audio problems shouldn't keep the rest of the client from working;
	// the settings page shows what went wrong.
	audio.audio_init(&ui.audio)
	app_audio_init(ui)

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
	ui.ctx.text_width = render.ui_text_width
	ui.ctx.text_height = render.ui_text_height
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
	when platform.WEB {
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
	session_capture_update(ui)
	app_audio_frame(ui)
	show_pokes(ui)
	// Before the tray, so it shows what a hotkey just did, and before
	// giving up for a hidden window, since they work without one.
	hotkeys_frame(ui)
	tray_update(ui)
	if ui.hidden {
		return true // no window to draw in
	}
	draw_frame(ui)
	// A browser paces frames itself, and a page can't sleep.
	when !platform.WEB {
		if ui.frame_pace > 0 {
			if left := ui.frame_pace - time.tick_since(ui.last_swap); left > 0 {
				time.sleep(left)
			}
			ui.last_swap = time.tick_now()
		}
	}
	return true
}

/*
draw_frame lays the UI out and draws it: the second half of ui_frame,
and all of what refresh_callback does while the window is being resized.
*/
@(private = "file")
draw_frame :: proc(ui: ^UI) {
	if ui.drawing {
		return
	}
	ui.drawing = true
	defer ui.drawing = false
	if render.gpu_lost(&ui.renderer.gpu) {
		reset_gpu(ui)
	}

	m := window_metrics(ui.window, settings.ui_scale_factor(&ui.settings))
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
	left, height := titlebar_area(ui.window)
	ui.titlebar_left = i32(left * m.input_scale)
	ui.titlebar_height = i32(height * m.input_scale)
	ui_images_frame(ui)
	clear(&ui.text_boxes)
	// The chat's text size, for measuring this frame and drawing it.
	render.set_chat_zoom(&ui.renderer, settings.chat_scale_factor(&ui.settings))
	activity_input(ui)
	mu.begin(&ui.ctx)
	layout(ui, i32(m.logical_w), i32(m.logical_h))
	mu.end(&ui.ctx)
	when platform.WEB {
		touch_after_frame(ui)
	}
	switch {
	case ui.chat.hovering:
		set_cursor(ui, .Hand)
	case ui.select.over_text || ui.select.dragging:
		set_cursor(ui, .IBeam)
	case:
		set_cursor(ui, .Arrow)
	}
	ui.select.over_text = false
	ui_chat_after_frame(ui)
	ui.keys = {}
	ui_images_after_frame(ui)
	render.render(&ui.renderer, &ui.ctx, m.fb_w, m.fb_h, m.scale, BACKGROUND)
	render.gpu_present(&ui.renderer.gpu)
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
	ui_avatars_destroy(ui)
	ui_video_destroy(ui)
	app_audio_destroy(ui)
	delete(ui.text_boxes)
	// Whatever the paste thread is doing, it uses the clipboard, so it
	// has to be done before that.
	paste_wait(ui)
	file_pick_wait(ui)
	avatar_pick_wait(ui)
	ui_profiles_destroy(ui)
	ui_manage_destroy(ui)
	delete(ui.reactors_asked.emoji)
	delete(ui.channels.find_asked)
	clipboard.destroy()
	window_close(ui)
	glfw.Terminate()
	audio.audio_destroy(&ui.audio)
	settings.settings_destroy(&ui.settings)
	known_servers_destroy(ui)
	install_destroy(ui)
	ui_chat_destroy(ui)
	ui_select_destroy(ui)
	conn.view_destroy(&ui.view)
}

/*
The window and everything that lives on its GPU device (an OpenGL
context, or a Direct3D 11 device on Windows). They come and go
together, because hiding the client in the tray takes the window down
altogether (see hide_to_tray): a Wayland surface that has been
unmapped can't be brought back - the EGL buffers behind it are never
released, and the next swap waits for them for ever.

Nothing above the device survives in here: microui's state, the view,
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
	when !platform.WEB {
		if on_wayland() {
			render.gpu_swap_interval(&ui.renderer.gpu, 0)
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
	render.gpu_swap_interval(&ui.renderer.gpu, 1)
}

window_open :: proc(ui: ^UI) -> bool {
	render.gpu_window_hints()
	// Where window coordinates are physical pixels (Windows, X11), size
	// the window for the monitor's scale so it isn't tiny on high DPI.
	glfw.WindowHint(glfw.SCALE_TO_MONITOR, true)
	when !platform.WEB {
		// The name of the installed .desktop entry (settings/install_unix.odin),
		// which is how Wayland finds the window's icon and how the
		// desktop groups the window under the entry.
		glfw.WindowHintString(glfw.WAYLAND_APP_ID, "yap")
		glfw.WindowHintString(glfw.X11_CLASS_NAME, "yap")
		glfw.WindowHintString(glfw.X11_INSTANCE_NAME, "yap")
	}
	ui.window = glfw.CreateWindow(ui.window_size.x, ui.window_size.y, "Yap", nil, nil)
	ui.title_unread = 0 // what "Yap" says
	if ui.window == nil {
		log.errorf("failed to create a window (%s is required)", render.GPU_REQUIREMENT)
		return false
	}
	glfw.SetWindowSizeLimits(ui.window, 480, 300, glfw.DONT_CARE, glfw.DONT_CARE)
	when !platform.WEB {
		set_window_icon(ui.window)
	}
	if !render.renderer_init(&ui.renderer, ui.window) {
		log.errorf("failed to set up %s rendering", render.GPU_REQUIREMENT)
		glfw.DestroyWindow(ui.window)
		ui.window = nil
		return false
	}
	titlebar_merge(ui.window)
	set_swap_pace(ui)
	ui.renderer.images = &ui.images.draws

	glfw.SetWindowIconifyCallback(ui.window, iconify_callback)
	when ODIN_OS == .Windows {
		glfw.SetWindowRefreshCallback(ui.window, refresh_callback)
	}
	glfw.SetCursorPosCallback(ui.window, cursor_pos_callback)
	glfw.SetMouseButtonCallback(ui.window, mouse_button_callback)
	glfw.SetScrollCallback(ui.window, scroll_callback)
	glfw.SetKeyCallback(ui.window, key_callback)
	glfw.SetCharCallback(ui.window, char_callback)
	// The cursor outlives the window, but which one the window shows
	// doesn't (see set_cursor).
	ui.cursor_shown = .Arrow
	ui.metrics = {}
	return true
}

/*
reset_gpu makes everything on the GPU again for the same window, once
the device has gone (a graphics driver update or reset). Should the new
one not come up either, it's tried again a second later; nothing is
drawn until then.
*/
@(private = "file")
reset_gpu :: proc(ui: ^UI) {
	if ui.gpu_reset_at != {} && time.tick_since(ui.gpu_reset_at) < time.Second {
		return
	}
	ui.gpu_reset_at = time.tick_now()
	log.warn("ui: lost the GPU device, setting it up again")
	ui_images_forget_textures(ui)
	ui_avatars_forget_textures(ui)
	ui_video_forget_texture(ui)
	if !render.renderer_reset(&ui.renderer, ui.window) {
		log.error("ui: could not set the GPU device up again")
		return
	}
	set_swap_pace(ui)
}

window_close :: proc(ui: ^UI) {
	if ui.window == nil {
		return
	}
	// Come back the same size as we went away. Where window coordinates
	// are physical pixels (see window_metrics), CreateWindow scales the
	// size it's given for the monitor (SCALE_TO_MONITOR), so it has to
	// be given the size before that, or the window grows every time.
	if w, h := glfw.GetWindowSize(ui.window); w > 0 && h > 0 {
		fb_w, _ := glfw.GetFramebufferSize(ui.window)
		if f32(fb_w) / f32(w) <= 1.01 {
			sx, sy := glfw.GetWindowContentScale(ui.window)
			w = i32(math.round(f32(w) / max(sx, 1)))
			h = i32(math.round(f32(h) / max(sy, 1)))
		}
		ui.window_size = {w, h}
	}
	render.renderer_destroy(&ui.renderer)
	// The pictures' textures belong to the device that's about to go;
	// they are decoded again when they're next on screen.
	ui_images_forget_textures(ui)
	ui_avatars_forget_textures(ui)
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

Cursor :: enum {
	Arrow, // the window's own, which is no cursor of ours
	Hand,
	IBeam,
}

// set_cursor switches the mouse cursor, if it isn't that one already.
set_cursor :: proc(ui: ^UI, cursor: Cursor) {
	if cursor == ui.cursor_shown {
		return
	}
	ui.cursor_shown = cursor
	if cursor != .Arrow && ui.cursors[cursor] == nil {
		ui.cursors[cursor] = glfw.CreateStandardCursor(
			glfw.HAND_CURSOR if cursor == .Hand else glfw.IBEAM_CURSOR,
		)
	}
	glfw.SetCursor(ui.window, ui.cursors[cursor])
}

save_settings :: proc(ui: ^UI) {
	settings.settings_save(ui.opts.settings_path, ui.settings)
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
	if ratio > 1.01 && !platform.WEB {
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
	server := conn.with_default_port(string(ui.server_buf[:ui.server_len]))
	if server == "" {
		return
	}
	// Show the port that was assumed; it's what gets saved, too.
	ui.server_len = copy(ui.server_buf[:], server)
	// Taken as typed: spaces may well be part of a password.
	password := string(ui.password_buf[:ui.password_len])
	settings.set_setting(&ui.settings.server, server)
	settings.remember_recent_server(&ui.settings, server, password)
	save_settings(ui)

	ns := new(Net_Session)
	ns.key_path = strings.clone(ui.opts.key_path)
	ns.server = strings.clone(server)
	ns.password = strings.clone(password)
	ns.known_servers = strings.clone(ui.opts.known_servers)
	ns.channel = strings.clone(ui.opts.channel)
	// Without one asked for, the channel that was on screen the last
	// time is looked at again (and only looked at).
	ns.view = strings.clone(settings.recent_channel(&ui.settings, server))
	ui.channels = {}
	ns.client = new(conn.Voice_Client)
	ns.client.view = &ui.view
	if audio.voice_init(&ns.client.voice) {
		// Devices may have come or gone since the list was made. The
		// microphone waits until it's needed (session_capture_update).
		audio.audio_refresh(&ui.audio)
		audio.open_playback(&ui.audio, &ns.streams, &ns.client.voice, ui.settings.output_device)
	}
	ns.client.voice.muted = ui.muted
	ns.client.voice.deafened = ui.deafened
	// Told to the others as soon as we're in a channel (drive_sound).
	ns.client.channels.sound = conn.sound_flags(ui.muted, ui.deafened)
	ns.client.voice.denoise = ui.settings.noise_suppression
	ns.client.voice.listen = ui.listen_back
	ns.client.voice.notifications.volume = settings.notification_gain(&ui.settings)
	conn.push_command(
		&ns.client.commands,
		conn.Quality_Command{settings.settings_quality(&ui.settings)},
	)
	conn.push_command(&ns.client.commands, conn.gate_command(&ui.settings))
	conn.push_command(&ns.client.commands, conn.transfer_limits_command(&ui.settings))
	// The per-user volumes go once the server's key says which are
	// this server's (apply_gains).
	ui.gains_for = {}

	conn.view_reset(&ui.view)
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
	conn.video_share_stop()
	app_audio_stop(ui)
	if ns.goodbye_tail {
		disconnect_finish(ui)
		return
	}
	if play_goodbye && sync.atomic_load(&ns.client.voice.output) {
		// Stop the network producer, but leave the playback callback running.
		// The UI then owns the playback ring until the goodbye clip drains.
		audio.close_capture(&ns.streams, &ns.client.voice)
		sync.atomic_store(&ns.stop, true)
		net_stop(ns)
		ns.goodbye_tail = true
		audio.voice_notification_play(&ns.client.voice, .Goodbye)
		if audio.notifications_pending(&ns.client.voice.notifications) {
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
	audio.notification_tail_step(&ns.client.voice)
	if !audio.notifications_pending(&ns.client.voice.notifications) &&
	   audio.ring_available(&ns.client.voice.playback) == 0 {
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
	audio.close_streams(&ns.streams, &ns.client.voice)
	if !ns.goodbye_tail {
		sync.atomic_store(&ns.stop, true)
		net_stop(ns)
	}

	audio.voice_destroy(&ns.client.voice)
	free(ns.client)
	delete(ns.key_path)
	delete(ns.server)
	delete(ns.password)
	delete(ns.known_servers)
	delete(ns.channel)
	delete(ns.view)
	free(ns)

	// A failure message stays up until the next attempt.
	if ui.view.status != .Failed {
		conn.view_reset(&ui.view)
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
		conn.push_command(
			&ui.session.client.commands,
			conn.Mute_Command{muted = muted, feedback = feedback},
		)
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
		conn.push_command(
			&ui.session.client.commands,
			conn.Deafen_Command{deafened = deafened, feedback = true},
		)
	}
}

// reopen_audio switches a running connection to the devices now selected
// in the settings.
reopen_audio :: proc(ui: ^UI, input: bool) {
	if m := &ui.monitor; m.active {
		if input {
			audio.open_capture(&ui.audio, &m.streams, &m.voice, ui.settings.input_device)
		} else if m.streams.playback != nil {
			audio.open_playback(&ui.audio, &m.streams, &m.voice, ui.settings.output_device)
		}
	}
	ns := ui.session
	if ns == nil || !ns.client.voice.ready {
		return
	}
	if input {
		// Not wanted is left closed (session_capture_update).
		if ns.capture_on {
			audio.open_capture(&ui.audio, &ns.streams, &ns.client.voice, ui.settings.input_device)
		}
	} else {
		audio.open_playback(&ui.audio, &ns.streams, &ns.client.voice, ui.settings.output_device)
	}
}

/*
session_capture_update runs every frame: it keeps the connection's
microphone open only while it's wanted, which is while we're in a voice
room (a channel's voice or a call) or on our way into one, and while the
settings page is shown (its meter and listen back come from the
connection). Joining a server alone doesn't open it.
*/
@(private = "file")
session_capture_update :: proc(ui: ^UI) {
	ns := ui.session
	if ns == nil || ns.goodbye_tail || !ns.client.voice.ready {
		return
	}
	want := ui.page == .Settings
	if !want {
		sync.guard(&ui.view.mutex)
		want = ui.view.my_room != 0 || ui.view.voice_pending
	}
	if want == ns.capture_on {
		return
	}
	ns.capture_on = want
	if want {
		// Devices may have come or gone since the list was made.
		audio.audio_refresh(&ui.audio)
		audio.open_capture(&ui.audio, &ns.streams, &ns.client.voice, ui.settings.input_device)
	} else {
		audio.close_capture(&ns.streams, &ns.client.voice)
	}
}

@(private = "file")
layout :: proc(ui: ^UI, w, h: i32) {
	ctx := &ui.ctx
	// One window that always fills the OS window.
	if cnt := mu.get_container(ctx, "yap"); cnt != nil {
		cnt.rect = {0, 0, w, h}
		// Always under the windows that float over it (pins, threads,
		// the picker...): microui raises a clicked window unless its
		// zindex is below 0, and sorts the lowest first.
		cnt.zindex = -1
	}
	if mu.begin_window(ctx, "yap", {0, 0, w, h}, {.NO_TITLE, .NO_RESIZE, .NO_CLOSE}) {
		main_window(ui)
		mu.end_window(ctx)
	}
	// An enlarged image floats above it all (ui_images.odin), and so
	// does the About dialog (ui_about.odin).
	image_viewer(ui, w, h)
	about_dialog(ui, w, h)
	pins_window(ui, w, h)
	thread_windows(ui, w, h)
	profile_windows(ui, w, h)
	completion_window(ui)
	picker_window(ui, w, h)
	channels_window(ui, w, h)
	forward_window(ui, w, h)
	search_window(ui, w, h)
	// Last, and in a window of its own, so it's over the popups too.
	icon_hint(ui, w, h)
}

@(private = "file")
main_window :: proc(ui: ^UI) {
	if ui.page == .Settings {
		settings_page(ui)
		return
	}

	v := &ui.view
	sync.guard(&v.mutex)
	apply_gains(ui)
	switch v.status {
	case .Disconnected, .Failed:
		// The buddy screen goes with the connection.
		if ui.page == .Buddies {
			ui.page = .Main
		}
		connect_screen(ui)
	case .Connecting, .Connected:
		// A server that doesn't know this device shows nothing until it's
		// logged in (ui_account.odin), nor one whose password was chosen
		// by somebody else until it has been replaced.
		switch {
		case v.status == .Connected && v.login.state != .Done:
			ui.page = .Main
			login_screen(ui)
		case v.status == .Connected && v.login.must_change:
			ui.page = .Main
			password_screen(ui)
		case ui.page == .Buddies:
			buddies_screen(ui)
		case:
			session_screen(ui)
		}
	}
}

@(private = "file")
connect_screen :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := &ui.view

	title_row(ui, {70, -74, ICON_BUTTON, ICON_BUTTON})
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

	mu.layout_row(ctx, {70, 200})
	mu.label(ctx, "Password")
	if .SUBMIT in password_box(ui, ui.password_buf[:], &ui.password_len) {
		ui.action = .Connect
	}

	if v.status == .Failed && v.error != "" {
		mu.layout_row(ctx, {-1})
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
		settings.forget_recent_server(s, s.recent_servers[forget].address)
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
	ui.narrow = narrow

	screen_tab_follow(ui)
	back_from_dms(ui)
	if v.watching != 0 && conn.video_is_fullscreen() {
		fullscreen_screen(ui)
		return
	}

	session_header(ui)

	// Side by side where there's room; in a narrow window the list and
	// the chat take turns (ui_channels.odin), over the voice panel.
	if narrow {
		mu.layout_row(ctx, {-1}, -(voice_panel_height(ui) + 1))
		if ui.channels.show_list {
			channel_list(ui)
		} else {
			side_panel(ui, narrow)
		}
		voice_panel(ui)
	} else {
		mu.layout_row(ctx, {280, -1}, -1)
		channel_list(ui)
		side_panel(ui, narrow)
	}
	user_menu(ui)
	message_menu(ui)
	app_audio_menu(ui)
}

/*
title_row is mu.layout_row for a screen's first row. On macOS that row
shares the top of the window with the close, minimize and zoom buttons
(see ui_titlebar_darwin.odin), so it starts to the right of them; the
widths counted from the right-hand edge stay where they are.
*/
title_row :: proc(ui: ^UI, widths: []i32, height: i32 = 0) {
	layout := mu.get_layout(&ui.ctx)
	indent := layout.indent
	layout.indent += max(ui.titlebar_left - layout.body.x, 0)
	mu.layout_row(&ui.ctx, widths, height)
	layout.indent = indent
}

/*
session_header is the row along the top while connected: who we are
where, how the connection is doing, and the buttons. The session screen
and the buddy screen share it.
*/
session_header :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := &ui.view
	// The status, then the connection indicator and the buttons, each
	// ICON_BUTTON wide plus the spacing between them. Mute, deafen and
	// what's shared are in the voice panel (ui_voice_panel.odin).
	icons := 5
	widths: [6]i32
	widths[0] = -i32(4 + (ICON_BUTTON + 4) * icons)
	for &w in widths[1:][:icons] {
		w = ICON_BUTTON
	}
	title_row(ui, widths[:1 + icons])
	switch v.status {
	case .Connected:
		me := v.my_name if v.my_name != "" else v.login.username
		server := v.server_name if v.server_name != "" else v.server
		mu.label(ctx, fmt.tprintf("Connected to %s as %s", server, me))
	case .Connecting, .Disconnected, .Failed:
		mu.label(ctx, fmt.tprintf("Connecting to %s...", v.server))
	}
	connection_indicator(ui)
	buddies_button(ui)
	log_button(ui)
	if .SUBMIT in icon_button(ui, "settings", .Settings, "Settings") {
		open_settings(ui)
	}
	if .SUBMIT in icon_button(ui, "disconnect", .Leave, "Disconnect", OFF_COLOR) {
		log.debug("ui: disconnect")
		ui.action = .Disconnect
	}
}

// log_button shows the log in place of the chat, from the channels or
// the buddies, and pressed again goes back to the chat.
@(private = "file")
log_button :: proc(ui: ^UI) {
	open := ui.page == .Main && ui.chat.tab == .Log
	if .SUBMIT in icon_button(ui, "log", .Log, "Back to the chat" if open else "Log", CHAT_NAME_COLOR if open else mu.Color{}) {
		if open {
			ui.chat.tab = .Chat
		} else {
			ui.page = .Main
			ui.chat.tab = .Log
			ui.log_seen = -1
		}
	}
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
	select_begin(ui, .Log)
	total: int
	{
		// No logging in here: the log sink takes this same lock.
		sync.guard(&logs.mutex)
		total = logs.total

		saved_spacing := ctx.style.spacing
		ctx.style.spacing = LOG_LINE_SPACING
		defer ctx.style.spacing = saved_spacing

		font := ctx.style.font
		// Lines are numbered by the running total, so a selection stays
		// on the same ones as new lines come in (ui_select.odin).
		first := i64(logs.total - len(logs.lines))
		for line, i in logs.lines {
			mu.layout_row(ctx, {-1}, render.LINE_HEIGHT)
			// Drop the date; the time is enough on screen.
			text := line.text[11:] if len(line.text) > 11 else line.text
			color := ctx.style.colors[.TEXT]
			switch {
			case line.level >= .Error:
				color = {230, 90, 90, 255}
			case line.level >= .Warning:
				color = {230, 200, 90, 255}
			case line.level < .Info:
				color = {140, 140, 140, 255}
			}
			// Where mu.label would put it.
			r := mu.layout_next(ctx)
			pos := mu.Vec2{r.x + ctx.style.padding, r.y + (r.h - ctx.text_height(font)) / 2}
			item := first + i64(i)
			select_item(ui, item, text)
			select_line(ui, item, text, 0, len(text), pos)
			mu.draw_text(ctx, font, text, pos, color)
		}
	}
	select_end(ui)
	mu.end_panel(ctx)

	// Follow new lines, unless that would pull them out from under a
	// selection being dragged.
	dragging := ui.select.dragging && ui.select.panel == .Log
	if total != ui.log_seen && !dragging {
		ui.log_seen = total
		cnt.scroll.y = cnt.content_size.y
	}
}

// A button with nothing but an icon on it is this wide.
ICON_BUTTON :: 30

// What the state icons are coloured with: green for a voice coming
// through, red for something switched off, grey for a quiet channel.
SPEAKING_COLOR :: mu.Color{110, 220, 110, 255}
OFF_COLOR :: mu.Color{225, 115, 115, 255}
DIM_COLOR :: mu.Color{140, 140, 140, 255}

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
	icon: render.Icon,
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
	mu.draw_icon(ctx, render.icon_id(icon), r, color if color.a != 0 else ctx.style.colors[.TEXT])
	if ctx.hover_id == id {
		ui.hint, ui.hint_of = hint, r
	}
	return
}

/*
icon_hint draws what the icon button under the pointer does, just below
it: or the tooltip of whatever else set `ui.hint`, which may run over
several lines. microui paints each window and popup as a whole, in
z-order, so the hint gets a frameless window of its own raised above
the rest; drawn inside the main window, a popup (the user menu) would
cover it.
*/
@(private = "file")
HINT_WINDOW :: "hint"

@(private = "file")
icon_hint :: proc(ui: ^UI, window_w, window_h: i32) {
	ctx := &ui.ctx
	if ui.hint == "" {
		return
	}
	defer ui.hint = ""

	pad := ctx.style.padding
	line_h := ctx.text_height(ctx.style.font)
	w, lines: i32
	rest := ui.hint
	for line in strings.split_lines_iterator(&rest) {
		w = max(w, ctx.text_width(ctx.style.font, line))
		lines += 1
	}
	w += 2 * pad
	h := lines * line_h + 2 * pad
	// Under the button, pushed left if it would go off the side, and
	// above it if there's no room below (the chat box's Send button).
	x := min(ui.hint_of.x, max(window_w - w, 0))
	y := ui.hint_of.y + ui.hint_of.h + 2
	if y + h > window_h {
		y = max(ui.hint_of.y - h - 2, 0)
	}
	r := mu.Rect{x, y, w, h}
	// The pointer is on the button, never on the hint, so the window
	// doesn't take the hover away from what it describes.
	cnt := mu.get_container(ctx, HINT_WINDOW)
	if cnt == nil {
		return
	}
	cnt.rect = r
	if cnt.zindex != ctx.last_zindex {
		mu.bring_to_front(ctx, cnt)
	}
	if !mu.begin_window(
		ctx,
		HINT_WINDOW,
		r,
		{.NO_TITLE, .NO_FRAME, .NO_RESIZE, .NO_SCROLL, .NO_CLOSE, .NO_INTERACT},
	) {
		return
	}
	defer mu.end_window(ctx)
	mu.draw_rect(ctx, r, ctx.style.colors[.BASE])
	mu.draw_box(ctx, r, ctx.style.colors[.BORDER])
	line_y := y + pad
	rest = ui.hint
	for line in strings.split_lines_iterator(&rest) {
		mu.draw_text(ctx, ctx.style.font, line, {x + pad, line_y}, ctx.style.colors[.TEXT])
		line_y += line_h
	}
}

stable_button_hint :: proc(
	ui: ^UI,
	id_name: string,
	label: string,
	hint: string,
	opt: mu.Options = {},
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
	mu.draw_control_text(ctx, label, r, .TEXT, opt)
	if ctx.hover_id == id {
		ui.hint, ui.hint_of = hint, r
	}

	return
}

stable_button :: proc(
	ctx: ^mu.Context,
	id_name: string,
	label: string,
	opt: mu.Options = {},
) -> (
	res: mu.Result_Set,
) {
	id := mu.get_id(ctx, id_name)
	r := mu.layout_next(ctx)
	mu.update_control(ctx, id, r)
	if ctx.mouse_pressed_bits == {.LEFT} && ctx.focus_id == id {
		res += {.SUBMIT}
	}
	mu.draw_control_frame(ctx, id, r, .BUTTON)
	mu.draw_control_text(ctx, label, r, .TEXT, opt)

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
	context = platform.callback_context()
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

/*
refresh_callback draws a frame while the window is being resized. On
Windows, dragging its edge runs a loop of the system's own until the
mouse is let go, and glfw.WaitEventsTimeout doesn't come back before
then, so without this the window would stand still for as long as the
drag lasts. Only resizing needs it: nothing else stops the loop.
*/
@(private = "file")
refresh_callback :: proc "c" (window: glfw.WindowHandle) {
	context = platform.callback_context()
	context.logger = g_logger
	if g_ui.window == window && !g_ui.hidden {
		draw_frame(g_ui)
	}
}

@(private = "file")
cursor_pos_callback :: proc "c" (window: glfw.WindowHandle, x, y: f64) {
	context = platform.callback_context()
	mu.input_mouse_move(&g_ui.ctx, to_logical(x), to_logical(y))
}

@(private = "file")
mouse_button_callback :: proc "c" (window: glfw.WindowHandle, button, action, mods: i32) {
	context = platform.callback_context()
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
	// The strip where a title bar would be moves the window instead,
	// where it isn't a control in the main window (macOS only, see
	// ui_titlebar_darwin.odin).
	if btn == .LEFT &&
	   action == glfw.PRESS &&
	   y < g_ui.titlebar_height &&
	   g_ui.ctx.hover_id == 0 &&
	   g_ui.ctx.hover_root == mu.get_container(&g_ui.ctx, "yap") {
		titlebar_press(window)
		return
	}
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
	context = platform.callback_context()
	mu.input_scroll(&g_ui.ctx, i32(-x * 30), i32(-y * 30))
}

@(private = "file")
char_callback :: proc "c" (window: glfw.WindowHandle, codepoint: rune) {
	context = platform.callback_context()
	buf, n := utf8.encode_rune(codepoint)
	mu.input_text(&g_ui.ctx, string(buf[:n]))
}

@(private = "file")
key_callback :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
	context = platform.callback_context()
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
		// Close the enlarged image, if one is open; and for the rest of
		// the frame, a key like microui's (UI.keys).
		if action == glfw.PRESS {
			g_ui.images.viewer = 0
			g_ui.keys += {.Escape}
		}
		return
	case glfw.KEY_UP, glfw.KEY_DOWN, glfw.KEY_TAB:
		if action == glfw.PRESS || action == glfw.REPEAT {
			switch key {
			case glfw.KEY_UP:
				g_ui.keys += {.Up}
			case glfw.KEY_DOWN:
				g_ui.keys += {.Down}
			case:
				g_ui.keys += {.Tab}
			}
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

set_clipboard :: proc(user_data: rawptr, text: string) -> bool {
	// Emscripten's GLFW has no clipboard: a browser's comes from the page
	// (ui_paste_web.odin).
	when platform.WEB {
		return web_copy_text(text)
	} else {
		glfw.SetClipboardString(
			g_ui.window,
			strings.clone_to_cstring(text, context.temp_allocator),
		)
		return true
	}
}

@(private = "file")
get_clipboard :: proc(user_data: rawptr) -> (string, bool) {
	when platform.WEB {
		text := web_pasted_text()
	} else {
		text := glfw.GetClipboardString(g_ui.window)
	}
	return text, text != ""
}

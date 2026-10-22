package client

import "base:intrinsics"
import glfw "client:wglfw"
import log "common:wlog"
import "core:crypto/ecdh"
import "core:fmt"
import "core:hash"
import "core:math"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import "core:time/datetime"
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

// The windowed client: GLFW for the window and input, microui for widgets, and
// Direct3D 11 on Windows, Metal on macOS or OpenGL 3.3 elsewhere to draw them
// (see render/render.odin).
//
// The UI owns the main thread (GLFW requires it). Each connection runs the
// same network loop as headless mode on its own thread. The two sides meet
// only in the View (network -> UI) and the command queue (UI -> network).

UI_Options :: struct {
	key_path:      string,
	known_servers: string,
	server:        string, // prefilled in the connect form and connected to right away
	password:      string, // for `server`
	channel:       string, // joined on connect
	logs:          ^conn.Log_Lines,
	settings_path: string,
}

// The connection and the thread (or the frame loop) that runs it. See
// net_native.odin and net_web.odin.
Net_Session :: struct {
	client:          ^conn.Voice_Client,
	thread:          Net_Thread,
	stop:            bool, // set atomically to end the network loop
	// Without threads nobody would notice `stop`, so the frame loop
	// records here that the connection is finished (see net_web.odin).
	stopped:         bool,

	// Owned copies, because the UI's buffers may change while the thread runs.
	key_path:        string,
	server:          string,
	password:        string,
	known_servers:   string,
	channel:         string, // the channel to show and talk in from the start, if any
	look_at:         string, // otherwise the channel to only look at
	// What the connection reports to the UI (the client's View), and what
	// the UI keeps of this server while another one is shown (see ui_servers.odin).
	view:            conn.View,
	stash:           Server_UI,
	// Which WebSockets belong to this session in a web build: slot and
	// slot + 1 (see conn/transport_web.odin).
	slot:            i32,
	// Whether the server was last told that the user is idle, and that the
	// page is out of sight (see ui_activity.odin).
	idle_told:       bool,
	hidden_told:     bool,
	// Web Push (see ui_push_web.odin): whether the browser has been asked
	// about its subscription for this server's key, and the key it was asked for.
	push_checked:    bool,
	push_key:        [proto.PUSH_KEY_SIZE]u8,
	// Set while the server is being joined from the + page (see ui_join.odin). It
	// is kept off the rail and out of the settings until the login succeeds.
	joining:         bool,
	// Messages unread in its channels, and how many of them mention us,
	// as of this frame. Used by the rail (see servers_frame).
	unread:          int,
	mentions:        int,
	// The incoming call that was last announced on the desktop, so that each
	// call is only announced once (see session_notices).
	call_announced:  proto.Call_Id,
	// DMs unread on this server. These count towards the inbox's icon rather
	// than the server's (see servers_frame).
	dm_unread:       int,
	// Whether our voice is in a room or a call here, and whether it is on
	// another server as the session was last told (see sounds_frame). The
	// same for talking in a room or a call (proto.TALKING), which the server
	// is told so that it can show it.
	voice_busy:      bool,
	voice_elsewhere: bool,
	// Whether the server can be told our activity and status as of this
	// frame (it is connected and we are logged in), whether they are shared
	// with our other servers (see status_shared), and what status_sync last
	// copied to it, and when.
	status_ready:    bool,
	status_shared:   bool,
	status_copied:   Status_Copied,
	talking:         proto.User_Flags,
	talking_told:    proto.User_Flags,
	// When the server was last asked when the people in the inbox were
	// last online, and how many of them were online then. If fewer are online
	// now, someone just left and it is worth asking again (see ask_last_seen).
	seen_asked:      time.Tick,
	seen_online:     int,

	// Audio devices, opened and closed on the UI thread (which owns the
	// miniaudio context). They feed the client's Voice rings.
	streams:         audio.Audio_Streams,
	// Whether the microphone is wanted, and whether it has been opened or an
	// attempt to open it was made (see session_capture_update).
	capture_on:      bool,
}

Extra_Key :: enum {
	Up,
	Down,
	Tab,
	Escape,
	Newline, // Shift+Enter, or Enter on a phone's keyboard: a new line in a text area
	// Markdown shortcuts in a composer (see composer_keys): Ctrl+B, Ctrl+I, Ctrl+U,
	// Ctrl+Shift+X, Ctrl+E.
	Bold,
	Italic,
	Underline,
	Strike,
	Code,
}

Page :: enum {
	Main,
	Settings,
	Buddies, // only while connected (ui_buddies.odin)
}

@(private = "file")
Action :: enum {
	None,
	Start, // connect to every joined server, on the first frame
	Disconnect,
	Reconnect, // the connect screen's "Reconnect"
	Trust_Key, // the connect screen's "Trust the new key" (ui_known_servers.odin)
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
	// The height of the connect screen's card in the last frame (see card_end).
	connect_card_h:      i32,
	// What the shown server's connection reports (its session's View), or
	// `no_view` when nothing is connected.
	view:                ^conn.View,
	no_view:             conn.View,
	session:             ^Net_Session,
	// Every connection, in the rail's order (see ui_servers.odin). `session`
	// is one of them, or nil if there are none. The one being joined from the +
	// dialog is included here too, although it is not on the rail (see ui_join.odin).
	sessions:            [dynamic]^Net_Session,
	join:                UI_Join,
	// In a web build, the joined server that this page's relay reaches: the
	// only one with a plain address that is connected (see relay_blocked).
	// Owned; "" if none has been chosen.
	relay_server:        string,
	rail:                UI_Rail, // its menu, and dragging (ui_servers.odin)
	// Messages unread on every server, in channels and DMs that aren't
	// muted. Used for the window's title and the tray (see servers_frame).
	unread:              int,
	// Mentions unread on every server, including muted channels and DMs. The
	// title and the tray show this before `unread`.
	mentions:            int,
	// DMs unread on every server, for the inbox's icon on the rail.
	dm_unread:           int,
	// The inbox (see ui_buddies.odin): everyone in it, across all servers, as of
	// this frame, and the DM to open once the rail has switched to
	// that person's server (see switch_now).
	inbox:               []Buddy_Entry,
	inbox_open:          proto.Account_Id,
	// Voice, or a ringing call, in a server that isn't shown, as of this
	// frame (see ui_voice_panel.odin).
	voice_other:         Voice_Elsewhere,
	// What the UI keeps of the shown server. Each session keeps its own copy
	// while it isn't shown (see Net_Session.stash and ui_servers.odin).
	using srv:           Server_UI,
	// The session that is in voice, as of this frame (see session_capture_update).
	voice_at:            ^Net_Session,
	// The rail was clicked: the session to show after the frame. See
	// switch_now.
	switch_to:           ^Net_Session,
	switching:           bool,
	// Connecting and disconnecting wait on the network thread, which may be
	// waiting on the View lock, so they happen after the layout, not during it.
	action:              Action,
	log_seen:            int, // Log_Lines.total when the log panel was last scrolled
	// What the window's title says (owned; see servers_frame).
	window_title:        string,
	settings_tab:        Settings_Tab, // which the settings page shows (ui_settings.odin)
	// The category selected in each of the settings tabs.
	settings_client:     Client_Category,
	settings_server:     Server_Category,
	// In a narrow window: the list of categories is showing instead of the
	// selected one (see settings_page).
	settings_list:       bool,
	// Which palette is in use, and what the desktop reported (see theme.odin).
	theme_state:         UI_Theme,
	// For the chat's local timestamps, for every server. nil means UTC
	// (see ui_chat_time_native.odin).
	chat_tz:             ^datetime.TZ_Region,
	activity:            UI_Activity, // whether whoever uses this is idle (ui_activity.odin)
	video:               UI_Video, // screen sharing (ui_video.odin)
	camera:              UI_Camera, // our camera and calls' video (ui_camera.odin)
	app_audio:           UI_App_Audio, // sharing an application's audio (ui_app_audio_native.odin)
	muted:               bool,
	deafened:            bool,
	// The mute state from before deafening turned it on, so that undeafening
	// restores it instead of always unmuting (see set_deafened).
	muted_before_deafen: bool,

	// Whose message header is being drawn, and the byte range of their name in
	// it, so that a click on the name opens their menu. 0: none.
	header_sender:       proto.Account_Id,
	header_name:         [2]int,
	// Where a bot's tag goes in the header (a byte offset after its name, where the
	// header leaves room for it, see ui_bots.odin). 0 for none.
	header_bot:          int,
	// The settings page's microphone monitor and level meter (ui_gate.odin).
	monitor:             Mic_Monitor,
	listen_back:         bool,
	// The welcome and goodbye sounds (ui_app_sounds.odin).
	app_sound:           App_Sound,
	// The Sounds page (ui_sounds.odin), and the open dropdown (ui_dropdown.odin).
	sounds:              Sounds_UI,
	dropdown:            Dropdown_State,
	// Whether the voice gate section, with the meter, was on screen in the last
	// frame (see gate_settings). The microphone is only opened for it in that case.
	meter_shown:         bool,
	meter_level:         f32,
	meter_time:          time.Tick,
	// Slider drags change the settings every frame, so save at most once a
	// second, and on exit.
	settings_dirty:      bool,
	// People's pictures and servers' emoji that are kept on disk between
	// sessions (see ui_image_cache.odin), and the settings page's box for
	// the folder.
	image_cache:         conn.Image_Cache,
	image_cache_dir_buf: [512]u8,
	image_cache_dir_len: int,
	// Memory usage: the settings page and the line in the log
	// (see ui_memory.odin).
	memory:              UI_Memory,
	// Keys that microui has no name for, pressed since the last frame.
	keys:                bit_set[Extra_Key],
	// A message was picked to be edited, or a mention was completed: its composer
	// takes the focus, with the cursor at `focus_composer_at` (-1: at the
	// end).
	focus_composer:      bool,
	focus_composer_at:   int,
	focus_thread:        int, // which composer: Composer.thread
	// People's pictures (ui_avatars.odin).
	avatars:             UI_Avatars,
	// Whether the last frame was laid out narrow. In that case an open thread takes
	// the place of the conversation instead of floating over it (see ui_threads.odin).
	narrow:              bool,
	// Whether controls are sized for a finger (see style_apply): in a narrow
	// window, or once a touch screen has been used (web, ui_touch_web.odin).
	compact:             bool,
	touched:             bool,
	// The bar over the message under the pointer (see ui_message_bar.odin),
	// and whether this frame is a tap on a touch screen (see ui_touch_web.odin),
	// which shows the message's bar.
	msg_bar:             UI_Message_Bar,
	touch_tap:           bool,
	settings_saved:      time.Tick,
	page:                Page,
	settings:            settings.Settings,
	known:               UI_Known_Servers, // saved server keys (ui_known_servers.odin)
	hotkeys:             UI_Hotkeys, // global hotkeys (ui_hotkeys_native.odin)
	install:             UI_Install, // installing for the user (ui_install_native.odin)
	// The UI scale slider's own value in percent, updated live while it is being
	// dragged. It is only copied into settings.ui_scale on release, because
	// applying it while dragging would resize the very slider being dragged
	// (see ui_settings.odin).
	ui_scale_draft:      f32,
	chat_scale_draft:    f32, // the same for the chat's text size
	audio:               audio.Audio,

	// Logical pixels per window coordinate, for mouse input (see
	// window_metrics).
	input_scale:         f32,
	// The strip along the top where the window's buttons are drawn over
	// the UI, merged with the title bar, in logical pixels: where
	// the first row starts, how far in from the right it ends, and how
	// tall the strip is. Zero where the title bar belongs to the desktop (see
	// ui_titlebar.odin).
	titlebar_left:       i32,
	titlebar_right:      i32,
	titlebar_height:     i32,
	// Where this frame's text boxes are, and whether one has the focus,
	// for a phone's keyboard in a web build (see ui_text_box.odin).
	text_boxes:          [dynamic]Text_Box,
	text_focused:        bool,
	metrics:             Window_Metrics,
	// The pointing hand shown over links and the I-beam shown over text that
	// can be selected. They are created on first use and freed by glfw.Terminate.
	cursors:             [Cursor]glfw.CursorHandle,
	cursor_shown:        Cursor,
	// Text selected in the chat or the log (ui_select.odin).
	select:              Selection,
	// The image paste that is being read, if any (see ui_paste.odin), and where the
	// next one goes.
	paste:               ^Paste_Job,
	paste_to:            Attach_Target,
	// The file dialog, while it's open (ui_files_native.odin).
	file_pick:           ^File_Pick_Job,
	// The paperclip was pressed: after the frame, the dialog opens to pick
	// files for `attach_to`'s next message (see ui_attachments.odin).
	attach_pick:         bool,
	attach_to:           Attach_Target,
	// Files dropped on the window since the last frame, to be attached
	// (see ui_files_*.odin). Owned.
	dropped:             [dynamic]string,
	// Files being dragged over the window (see drop_hint).
	drag:                Drag,
	// What the icon button under the pointer does, and where it is, for
	// the hint drawn under it (see icon_button and icon_hint).
	hint:                string,
	hint_of:             mu.Rect,
	// Icon buttons are drawn flat, with a background only while the pointer
	// is on them (the composer's, inside its box, see composer_buttons).
	flat_buttons:        bool,
	// The emoji the hint is about, drawn large above it (icon_hint).
	hint_emoji:          Hint_Emoji,
	// The picture chip under the pointer, which is shown over it
	// (see chip_preview_popup).
	chip_preview:        Chip_Preview,
	// Chat images: decoded pictures and their textures (ui_images.odin).
	images:              UI_Images,
	// The system tray icon, if it's switched on (ui_tray.odin).
	tray:                Tray,
	// The window is hidden in the tray and nothing is drawn until it
	// comes back. Quitting is the only thing that works while it is hidden.
	hidden:              bool,
	quitting:            bool,
	// The desktop has just minimized the window (see iconify_callback).
	minimized:           bool,
	// The size to restore the window to, remembered when it is hidden.
	window_size:         [2]i32,
	// Used where the buffer swap doesn't wait for the display (see window_open):
	// the shortest time between frames, and when the last one was presented.
	frame_pace:          time.Duration,
	last_swap:           time.Tick,
	// When the GPU device was last set up again (see reset_gpu).
	gpu_reset_at:        time.Tick,
	// A frame is being drawn (see draw_frame). A refresh mustn't
	// start another one in the middle of it.
	drawing:             bool,
	// A frame is only drawn when there is something new to show (see
	// frame_due). This holds how many more frames to draw regardless, when the
	// clock will next change something on screen (zero: nothing will), the
	// hash of the last frame's draw commands, and how many log lines
	// the log panel showed in it (-1: it wasn't on screen).
	redraw_frames:       int,
	redraw_at:           time.Tick,
	// The mouse wheel's scrolling not handed to microui yet, in pixels, and
	// when some was last handed over (see scroll_step).
	scroll_left:         [2]f32,
	// Each panel's and window's scrollbar (ui_scrollbars.odin).
	scrollbar_fades:     map[^mu.Container]Scrollbar_Fade,
	scroll_at:           time.Tick,
	drawn_hash:          u64,
	log_drawn:           int,
}

// For GLFW's callbacks, which have no user data we can use cheaply, and for
// the page's touch input in a web build (see ui_touch_web.odin).
g_ui: ^UI
@(private = "file")
g_logger: log.Logger

// run_ui drives the client from a loop of its own, which is what a desktop
// provides. A web build has no loop of its own because the browser hands
// out one frame at a time, so the work is split into starting up, one turn
// of the loop and shutting down, and main_web.odin drives those.
run_ui :: proc(opts: UI_Options) -> bool {
	ui := new(UI)
	defer free(ui)
	if !ui_startup(ui, opts) {
		ui_shutdown(ui)
		return false
	}
	for ui_frame(ui) {}
	app_sound_goodbye(ui)
	ui_shutdown(ui)
	return true
}

ui_startup :: proc(ui: ^UI, opts: UI_Options) -> bool {
	g_ui = ui
	g_logger = context.logger
	ui.opts = opts
	ui.log_drawn = -1
	ui.view = &ui.no_view
	conn.view_init(ui.view)
	ui.view.wake = ui_wake
	conn.video_set_wake(ui_wake)
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
	image_cache_start(ui)

	// Audio problems shouldn't stop the rest of the client from working.
	// The settings page shows what went wrong.
	audio.audio_init(&ui.audio)
	app_audio_init(ui)
	sounds_load(ui)
	app_sound_play(ui, .Welcome)

	glfw.SetErrorCallback(glfw_error_callback)
	titlebar_init(ui.settings.merge_title_bar)
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
	ui.ctx.draw_frame = draw_frame_themed
	ui.input_scale = 1

	ui.action = .Start
	return true
}

// ui_frame is one turn of the loop. It returns false when the client
// is done and should shut down.
ui_frame :: proc(ui: ^UI) -> bool {
	if ui.quitting {
		return false
	}

	// Closing the window moves the client to the tray instead of
	// ending it, if there is a tray icon and the settings ask for that
	// (see ui_tray.odin). Quit in the tray menu sets `quitting` instead,
	// and there may be no window at all.
	if ui.window != nil && glfw.WindowShouldClose(ui.window) {
		if !tray_takes_window(ui, ui.settings.close_to_tray) {
			return false
		}
		glfw.SetWindowShouldClose(ui.window, false)
		hide_to_tray(ui)
	}

	// Minimizing can also move the client to the tray. Only some desktops report
	// when the window is minimized (see iconify_callback).
	if ui.minimized {
		ui.minimized = false
		if tray_takes_window(ui, ui.settings.minimize_to_tray) {
			// Leave the minimized state first, so the window comes back
			// as a normal window instead of being minimized again.
			glfw.RestoreWindow(ui.window)
			hide_to_tray(ui)
		}
	}

	free_all(context.temp_allocator)

	if ui.action != .None {
		ui_redraw(ui)
	}
	switch ui.action {
	case .None:
	case .Start:
		connect_joined(ui)
	case .Disconnect:
		disconnect(ui, ui.session)
	case .Reconnect:
		reconnect(ui, ui.session)
	case .Trust_Key:
		trust_new_key(ui)
	}
	ui.action = .None
	join_frame(ui)
	rail_frame(ui)
	switch_now(ui)
	memory_frame(ui)

	// Wake up for input, or often enough for the work below that isn't
	// drawing. A frame is only drawn when there is something new to show
	// (see frame_due). Listen back without a connection is fed from this
	// loop (see monitor_update), so the loop needs to run at the display's rate.
	// In a web build the browser has already decided when this frame
	// happens, so there is nothing to wait for.
	// A frame asked for by a time (ui_redraw_at) wakes it sooner, so that what
	// moves faster than that (scrolling, see scroll_step) does.
	wait := 1.0 / 240 if ui.monitor.streams.playback != nil else 1.0 / 30
	if ui.redraw_at != {} {
		due := time.duration_seconds(time.tick_diff(time.tick_now(), ui.redraw_at))
		wait = clamp(due, 0.001, wait)
	}
	glfw.WaitEventsTimeout(wait)

	// Without threads nobody else can run the connection, so it
	// gets its turn here, between frames (see net_thread).
	// Touch input arrives as a queue, with one event handled per frame (see ui_touch_web.odin).
	when platform.WEB {
		net_step(ui)
		touch_step(ui)
	}

	if ui.settings_dirty && time.tick_since(ui.settings_saved) > time.Second {
		save_settings(ui)
	}

	// Listen back is only a test on the settings page, so don't leave it running.
	if ui.page != .Settings {
		set_listen_back(ui, false)
	}
	monitor_update(ui)
	app_sound_step(ui)
	sounds_frame(ui)
	session_capture_update(ui)
	app_audio_frame(ui)
	servers_frame(ui)
	// Run before the tray and the taskbar update, so they show what a hotkey just
	// did, and before returning early for a hidden window, since hotkeys work
	// without a window.
	hotkeys_frame(ui)
	tray_update(ui)
	thumbbar_update(ui)
	activity_step(ui)
	status_sync(ui)
	push_frame(ui)
	if ui.hidden {
		ui.meter_shown = false
		return true // there is no window to draw in
	}
	drag_frame(ui)
	if !frame_due(ui) {
		return true
	}
	draw_frame(ui)
	// A browser paces frames itself and a page can't sleep.
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

// draw_frame lays out the UI and draws it. It is the second half of ui_frame
// and everything that refresh_callback does while the window is being resized.
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
	left, right, height := titlebar_area(ui)
	ui.titlebar_left = i32(left * m.input_scale)
	ui.titlebar_right = i32(right * m.input_scale)
	ui.titlebar_height = i32(height * m.input_scale)
	// Whatever asked for this frame has been served now. The layout asks again
	// for whatever still needs more frames (see frame_due).
	ui.redraw_frames = max(ui.redraw_frames - 1, 0)
	ui.redraw_at = {}
	ui.log_drawn = -1
	// microui turns a press into focus for whatever `hover_id` names without
	// checking the pointer again, and only a control itself clears its hover. If
	// a hovered control disappears (because of a screen change or a relabeled
	// button), the stale id could fire on a click anywhere once the id reappears.
	// Recomputing the hover in every frame without a press keeps it tied to what
	// is actually under the pointer.
	if ui.ctx.mouse_pressed_bits == {} && ui.ctx.mouse_down_bits == {} {
		ui.ctx.hover_id = 0
	}
	ui_images_frame(ui)
	clear(&ui.text_boxes)
	// The chat's text size, used for measuring and drawing this frame.
	render.set_chat_zoom(&ui.renderer, settings.chat_scale_factor(&ui.settings))
	activity_input(ui)
	voice_elsewhere_update(ui)
	theme_update(ui) // the palette for this frame (theme.odin)
	style_apply(ui, i32(m.logical_w))
	scroll_step(ui)
	mu.begin(&ui.ctx)
	ui.meter_shown = false // until gate_settings draws it again (it sets this when it draws the meter)
	layout(ui, i32(m.logical_w), i32(m.logical_h))
	mu.end(&ui.ctx)
	clock_redraws(ui)
	settle(ui)
	when platform.WEB {
		touch_after_frame(ui)
	}
	edge := Window_Edge.None
	if ui.ctx.mouse_down_bits == {} {
		edge = window_edge(ui, ui.ctx.mouse_pos.x, ui.ctx.mouse_pos.y)
	}
	switch {
	case edge != .None:
		set_cursor(ui, EDGE_CURSORS[edge])
	case ui.chat.hovering:
		set_cursor(ui, .Hand)
	case ui.select.over_text || ui.select.dragging:
		set_cursor(ui, .IBeam)
	case:
		set_cursor(ui, .Arrow)
	}
	ui.select.over_text = false
	ui_chat_after_frame(ui)
	camera_after_frame(ui)
	ui.keys = {}
	// The window's buttons keep their size at 100%. Only the display's
	// density scales them, not the UI's zoom.
	ui.renderer.control_scale = m.scale / settings.ui_scale_factor(&ui.settings)
	render.render(&ui.renderer, &ui.ctx, m.fb_w, m.fb_h, m.scale, theme.background)
	render.gpu_present(&ui.renderer.gpu)
	// A camera turned off in this frame no longer has its preview drawn.
	conn.video_frame_done()
}

// Drawing a frame lays out the whole UI, which costs the same whether
// anything has changed or not, so the loop only draws a frame when something
// asks for one:
//
// - input, and the window changing size or needing its contents drawn again
//   (ui_redraw, called from GLFW's callbacks);
// - another thread changing something that is shown, such as the network side
//   through the View (conn.view_write), decoded pictures, or a finished dialog
//   or paste (ui_wake);
// - the clock: anything that fades, counts or disappears after a while asks for
//   a frame at the time it next changes, in every frame it is on screen
//   (ui_redraw_at).
//
// A frame whose draw commands differ from the previous frame's is followed
// by another one (see settle). Much of the layout only catches up a frame
// later (scrolling to the end, a focus change, a menu opened by a click), and a
// frame that changed nothing is the sign that this is done.

// After input, draw at least this many frames, because microui answers some
// input (a click) in the frame after the one that saw it.
@(private = "file")
SETTLE_FRAMES :: 2

// How often things that move smoothly (a fade, the level meter) are redrawn.
ANIMATION_FRAME :: time.Second / 30

// Set by ui_wake, which can be called from any thread.
@(private = "file")
g_wake: bool

// ui_wake asks for a frame from any thread, for a change that no input
// event reports: from the network side (View.wake) and from threads that
// have finished their work. It wakes the loop if it is waiting.
ui_wake :: proc "c" () {
	if !intrinsics.atomic_exchange(&g_wake, true) {
		glfw.PostEmptyEvent()
	}
}

// ui_redraw asks for frames right now, from the UI's own thread.
ui_redraw :: proc "contextless" (ui: ^UI) {
	ui.redraw_frames = max(ui.redraw_frames, SETTLE_FRAMES)
}

// ui_redraw_at asks for a frame by `at`, for things that change with the clock
// alone. The layout asks again in every frame that still needs it.
ui_redraw_at :: proc(ui: ^UI, at: time.Tick) {
	if ui.redraw_at == {} || time.tick_diff(at, ui.redraw_at) > 0 {
		ui.redraw_at = at
	}
}

ui_redraw_in :: proc(ui: ^UI, after: time.Duration) {
	ui_redraw_at(ui, time.tick_add(time.tick_now(), max(after, 0)))
}

// frame_due says whether the loop should draw a frame in this turn.
@(private = "file")
frame_due :: proc(ui: ^UI) -> bool {
	if intrinsics.atomic_exchange(&g_wake, false) {
		ui_redraw(ui)
	}
	if ui.redraw_frames > 0 {
		return true
	}
	if ui.redraw_at != {} && time.tick_diff(ui.redraw_at, time.tick_now()) >= 0 {
		return true
	}
	// A new size or scale. No callback is needed for this.
	if window_metrics(ui.window, settings.ui_scale_factor(&ui.settings)) != ui.metrics {
		return true
	}
	// Lines are logged from everywhere, far too often to wake for each
	// one, so they are only checked for while the log is on screen.
	if ui.log_drawn >= 0 && ui.opts.logs != nil {
		sync.guard(&ui.opts.logs.mutex)
		return ui.opts.logs.total != ui.log_drawn
	}
	return false
}

// clock_redraws asks for frames for things that change with the clock and are
// shown in too many places to ask from each of them: who is speaking and who is
// typing (which stop by themselves), the network side's notices (which
// disappear after a while), and times shown to the minute.
@(private = "file")
clock_redraws :: proc(ui: ^UI) {
	{
		v := ui.view
		sync.guard(&v.mutex)
		if t := conn.speaking_until(v); t != {} {
			ui_redraw_at(ui, t)
		}
		if t := conn.typing_until(v); t != {} {
			ui_redraw_at(ui, t)
		}
		if t := notice_until(v); t != {} {
			ui_redraw_at(ui, t)
		}
	}
	// Message times, "Today" and "last seen 5 minutes ago" all
	// change on the minute.
	MINUTE :: i64(time.Minute)
	into := time.time_to_unix_nano(time.now()) % MINUTE
	ui_redraw_in(ui, time.Duration(MINUTE - into))
}

// settle asks for another frame when this frame's draw commands differ
// from the previous frame's.
@(private = "file")
settle :: proc(ui: ^UI) {
	list := &ui.ctx.command_list
	h := hash.fnv64a(list.items[:list.idx])
	h = hash.fnv64a(slice.to_bytes(ui.images.draws[:]), h)
	if h != ui.drawn_hash {
		ui.drawn_hash = h
		ui.redraw_frames = max(ui.redraw_frames, 1)
	}
}

// ui_shutdown tears everything down in the reverse order of the startup.
ui_shutdown :: proc(ui: ^UI) {
	disconnect_all(ui)
	delete(ui.sessions)
	delete(ui.relay_server)
	delete(ui.window_title)
	hotkeys_stop(ui)
	tray_hide(ui)
	monitor_stop(ui)
	app_sound_stop(ui)
	sounds_destroy(ui)
	if ui.settings_dirty {
		save_settings(ui)
	}
	ui_images_destroy(ui)
	ui_avatars_destroy(ui)
	conn.image_cache_destroy(&ui.image_cache)
	ui_video_destroy(ui)
	app_audio_destroy(ui)
	ui_memory_destroy(ui)
	delete(ui.text_boxes)
	delete(ui.scrollbar_fades)
	// The paste thread uses the clipboard, so it has to be
	// finished before the clipboard is torn down.
	paste_wait(ui)
	file_pick_wait(ui)
	// What the UI kept for each server went away with its session
	// (see disconnect_all).
	for path in ui.dropped {
		delete(path)
	}
	delete(ui.dropped)
	clipboard.destroy()
	activity_close(ui)
	window_close(ui)
	glfw.Terminate()
	audio.audio_destroy(&ui.audio)
	settings.settings_destroy(&ui.settings)
	known_servers_destroy(ui)
	install_destroy(ui)
	ui_chat_destroy(ui)
	ui_select_destroy(ui)
	conn.view_destroy(ui.view)
}

// The window and everything that lives on its GPU device (an OpenGL
// context, or a Direct3D 11 device on Windows). They come and go
// together, because hiding the client in the tray destroys the window
// entirely (see hide_to_tray). A Wayland surface that has been
// unmapped can't be brought back: the EGL buffers behind it are never
// released, and the next swap waits for them forever.
//
// Nothing above the device lives in here: microui's state, the view,
// the connection and the tray icon all survive across windows.
// set_swap_pace decides what keeps frames at the display's rate.
//
// Usually that is the buffer swap, which waits for the display (vsync). On
// Wayland that wait is for the compositor's go-ahead, which it only gives to a
// window it is showing. If the window is minimized or on another virtual
// desktop, the swap would wait until the window is looked at again, and
// everything else on this thread would wait with it: notifications, the tray
// icon and listen back. So there the swap doesn't wait, and the loop keeps to
// the monitor's refresh rate itself (see frame_pace, at the end of ui_frame).
// Wayland never tears, so nothing is lost.
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
		// The name of the installed .desktop entry (see settings/install_unix.odin).
		// Wayland uses it to find the window's icon, and the desktop uses it
		// to group the window under that entry.
		glfw.WindowHintString(glfw.WAYLAND_APP_ID, "yap")
		glfw.WindowHintString(glfw.X11_CLASS_NAME, "yap")
		glfw.WindowHintString(glfw.X11_INSTANCE_NAME, "yap")
	}
	titlebar_window_hints(ui.settings.merge_title_bar)
	ui.window = glfw.CreateWindow(ui.window_size.x, ui.window_size.y, "Yap", nil, nil)
	delete(ui.window_title)
	ui.window_title = strings.clone("Yap") // what the window title says
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
	// Before the title bar, whose window procedure goes in front of this one.
	thumbbar_attach(ui.window)
	titlebar_merge(ui.window, ui.settings.merge_title_bar)
	set_swap_pace(ui)
	ui.renderer.images = &ui.images.draws

	glfw.SetWindowIconifyCallback(ui.window, iconify_callback)
	when !platform.WEB {
		glfw.SetWindowRefreshCallback(ui.window, refresh_callback)
		glfw.SetWindowFocusCallback(ui.window, focus_callback)
		glfw.SetCursorEnterCallback(ui.window, cursor_enter_callback)
	}
	when ODIN_OS == .Darwin {
		glfw.SetFramebufferSizeCallback(ui.window, resize_callback)
	}
	glfw.SetCursorPosCallback(ui.window, cursor_pos_callback)
	glfw.SetMouseButtonCallback(ui.window, mouse_button_callback)
	glfw.SetScrollCallback(ui.window, scroll_callback)
	glfw.SetKeyCallback(ui.window, key_callback)
	glfw.SetCharCallback(ui.window, char_callback)
	when !platform.WEB {
		glfw.SetDropCallback(ui.window, drop_callback)
	}
	// The cursor outlives the window, but the cursor that the window shows
	// doesn't (see set_cursor).
	ui.cursor_shown = .Arrow
	ui.metrics = {}
	ui_redraw(ui)
	return true
}

// reset_gpu recreates everything on the GPU for the same window after the
// device has been lost (for example by a graphics driver update or reset). If the
// new device doesn't come up either, it is tried again a second later.
// Nothing is drawn until then.
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
	// Come back at the same size as before. Where window coordinates
	// are physical pixels (see window_metrics), CreateWindow scales the
	// size it is given for the monitor (SCALE_TO_MONITOR), so it has to
	// be given the unscaled size, or the window grows every time.
	if w, h := glfw.GetWindowSize(ui.window); w > 0 && h > 0 {
		fb_w, _ := glfw.GetFramebufferSize(ui.window)
		if f32(fb_w) / f32(w) <= 1.01 {
			sx, sy := glfw.GetWindowContentScale(ui.window)
			w = i32(math.round(f32(w) / max(sx, 1)))
			h = i32(math.round(f32(h) / max(sy, 1)))
		}
		ui.window_size = {w, h}
	}
	// The video library releases what it created on the device while the device
	// still exists (an OpenGL context can only be cleaned up while current).
	ui_video_forget_texture(ui)
	render.renderer_destroy(&ui.renderer)
	// The pictures' textures belong to the device that is about to go away.
	// They are decoded again when they are next on screen.
	ui_images_forget_textures(ui)
	ui_avatars_forget_textures(ui)
	thumbbar_detach()
	glfw.DestroyWindow(ui.window)
	ui.window = nil
}

// clipboard_init sets up reading images from the clipboard. On Wayland it
// needs GLFW's connection, because only the focused window may read.
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
	Arrow, // the window's own cursor, not one of ours
	Hand,
	IBeam,
	// Over the edges of a window that we resize ourselves (see window_edge).
	Resize_EW,
	Resize_NS,
	Resize_NWSE,
	Resize_NESW,
}

@(private = "file")
CURSOR_SHAPES := [Cursor]i32 {
	.Arrow       = 0,
	.Hand        = glfw.HAND_CURSOR,
	.IBeam       = glfw.IBEAM_CURSOR,
	.Resize_EW   = glfw.RESIZE_EW_CURSOR,
	.Resize_NS   = glfw.RESIZE_NS_CURSOR,
	.Resize_NWSE = glfw.RESIZE_NWSE_CURSOR,
	.Resize_NESW = glfw.RESIZE_NESW_CURSOR,
}

// set_cursor switches the mouse cursor, unless it is already that one.
set_cursor :: proc(ui: ^UI, cursor: Cursor) {
	if cursor == ui.cursor_shown {
		return
	}
	ui.cursor_shown = cursor
	if cursor != .Arrow && ui.cursors[cursor] == nil {
		ui.cursors[cursor] = glfw.CreateStandardCursor(CURSOR_SHAPES[cursor])
	}
	glfw.SetCursor(ui.window, ui.cursors[cursor])
}

save_settings :: proc(ui: ^UI) {
	settings.settings_save(ui.opts.settings_path, ui.settings)
	ui.settings_dirty = false
	ui.settings_saved = time.tick_now()
}

Window_Metrics :: struct {
	logical_w, logical_h: f32, // the size the UI is laid out for
	fb_w, fb_h:           i32,
	scale:                f32, // physical pixels per logical pixel
	input_scale:          f32, // logical pixels per window coordinate
}

// Platforms disagree on what window coordinates are. On Wayland and macOS
// they are logical and the framebuffer is bigger on high-DPI screens. On
// Windows and X11 they are physical pixels, and the monitor's scale is only
// known from the content scale. Either way we lay out in logical pixels
// and render at `scale`.
@(private = "file")
window_metrics :: proc(window: glfw.WindowHandle, ui_scale: f32) -> (m: Window_Metrics) {
	w, h := glfw.GetWindowSize(window)
	m.fb_w, m.fb_h = glfw.GetFramebufferSize(window)
	if w <= 0 || h <= 0 || m.fb_w <= 0 {
		return {logical_w = 1, logical_h = 1, scale = 1, input_scale = 1}
	}

	// A browser reports its ratio itself (see wglfw_web.odin). The framebuffer's
	// whole pixels would only give an approximation that changes with the
	// window's size, and with it the font's rasterization.
	ratio := f32(m.fb_w) / f32(w)
	if ratio > 1.01 && !platform.WEB {
		// The framebuffer's whole pixels make the ratio wobble as the
		// window is resized (1.5, then 1.4995). Then everything snapped
		// to physical pixels would shift by one, and the fonts would be
		// rasterized again at every step. Scales are whole 120ths
		// (Wayland's fractional scaling), which the wobble never
		// reaches.
		m.scale = math.round(ratio * 120) / 120
		m.logical_w, m.logical_h = f32(w), f32(h)
	} else {
		content, _ := glfw.GetWindowContentScale(window)
		m.scale = max(content, 1)
		m.logical_w, m.logical_h = f32(m.fb_w) / m.scale, f32(m.fb_h) / m.scale
	}

	// The UI's own zoom stacks with the display's DPI scale above.
	// It shrinks the logical canvas the layout runs in while rendering it
	// at a proportionally higher `scale`. That makes every widget sized in
	// logical pixels cover more of the screen without the layout code (or the
	// font and icon atlases, which already rebuild when `scale` changes)
	// knowing the difference.
	m.scale *= ui_scale
	m.logical_w /= ui_scale
	m.logical_h /= ui_scale
	m.input_scale = m.logical_w / f32(w)
	return
}

// connect_joined connects to every joined server at startup, in the rail's
// order, and shows the first one. If a server was given when the client was
// started, it instead joins that server (if it isn't joined yet), shows it and
// looks at the channel given with it.
@(private = "file")
connect_joined :: proc(ui: ^UI) {
	first := conn.with_default_port(ui.opts.server)
	if first != "" {
		password := ui.opts.password
		if password == "" {
			password = settings.joined_password(&ui.settings, first)
		}
		settings.join_server(&ui.settings, first, password)
		save_settings(ui)
	} else if len(ui.settings.joined_servers) > 0 {
		first = ui.settings.joined_servers[0].address
	}
	when platform.WEB {
		relay_claim(ui, first)
		for r in ui.settings.joined_servers {
			relay_claim(ui, r.address)
		}
	}
	for r in ui.settings.joined_servers {
		this := r.address == first
		connect_to(ui, r.address, r.password, ui.opts.channel if this else "", show = this)
	}
}

// connect connects again to the server on the connect screen, which is a
// server on the rail that isn't connected, possibly with a different
// password now. The new connection takes the old one's place.
connect :: proc(ui: ^UI) {
	server := conn.with_default_port(string(ui.server_buf[:ui.server_len]))
	if server == "" {
		return
	}
	// Show the port that was assumed, because that is also what gets saved.
	ui.server_len = copy(ui.server_buf[:], server)
	// Taken as typed, because spaces may well be part of a password.
	password := string(ui.password_buf[:ui.password_len])
	settings.join_server(&ui.settings, server, password)
	save_settings(ui)
	connect_to(ui, server, password)
}

// connect_to connects to a server. This creates a new session at the end of the
// rail. If a session for that server already exists (for example one that
// failed, or one whose key was just trusted), a new one replaces it and
// carries on with what the UI had kept for it. With `show`, the server is shown.
connect_to :: proc(
	ui: ^UI,
	server, password: string,
	channel := "",
	show := true,
) -> ^Net_Session {
	monitor_stop(ui) // the connection opens the microphone itself
	ns := session_new(ui, server, password, channel)
	old_index := -1
	for other, i in ui.sessions {
		if other.server == server && !other.joining {
			old_index = i
		}
	}
	if old_index >= 0 {
		old := ui.sessions[old_index]
		ui.sessions[old_index] = ns
		if old == ui.session {
			ui.session, ui.view = ns, &ns.view
		} else {
			ns.stash, old.stash = old.stash, {}
			if show {
				show_session(ui, ns)
			}
		}
		session_free(ui, old)
	} else {
		append(&ui.sessions, ns)
		if show {
			show_session(ui, ns)
		}
	}
	// The per-user volumes are applied once the server's key tells which
	// ones belong to this server (see apply_gains).
	if ns == ui.session {
		ui.gains_for = {}
	} else {
		ns.stash.gains_for = {}
	}
	if !relay_blocked(ui, ns) {
		net_start(ns)
	}
	return ns
}

// session_new creates a session for `server`, ready to start, which joins
// `channel` if there is one.
session_new :: proc(ui: ^UI, server, password: string, channel := "") -> ^Net_Session {
	ns := new(Net_Session)
	ns.key_path = strings.clone(ui.opts.key_path)
	ns.server = strings.clone(server)
	ns.password = strings.clone(password)
	ns.known_servers = strings.clone(ui.opts.known_servers)
	ns.channel = strings.clone(channel)
	// If no channel was asked for, the channel that was on screen the last
	// time is shown again (but not joined).
	ns.look_at = strings.clone(settings.joined_channel(&ui.settings, server))
	ns.slot = session_slot(ui)
	// Its login form, if it needs one, starts with the account that was last
	// logged in to on any server.
	ns.stash.account.username_len = copy(ns.stash.account.username_buf[:], ui.settings.username)
	conn.view_init(&ns.view)
	ns.view.wake = ui_wake
	ns.view.status = .Connecting
	ns.view.server = strings.clone(server)
	ns.client = new(conn.Voice_Client)
	ns.client.view = &ns.view
	ns.client.slot = ns.slot
	ns.client.blobs.disk = &ui.image_cache
	if audio.voice_init(&ns.client.voice) {
		// Devices may have come or gone since the list was made. The
		// microphone waits until it is needed (see session_capture_update).
		audio.audio_refresh(&ui.audio)
		audio.open_playback(&ui.audio, &ns.streams, &ns.client.voice, ui.settings.output_device)
	}
	ns.client.voice.muted = ui.muted
	ns.client.voice.deafened = ui.deafened
	// Told to the others as soon as we're in a channel (see drive_sound).
	ns.client.channels.sound = conn.sound_flags(ui.muted, ui.deafened)
	ns.client.voice.denoise = ui.settings.noise_suppression
	ns.client.voice.listen = ui.listen_back
	ns.client.voice.notifications.volume = settings.notification_gain(&ui.settings)
	sounds_session_init(ui, ns)
	conn.push_command(
		&ns.client.commands,
		conn.Quality_Command{settings.settings_quality(&ui.settings)},
	)
	conn.push_command(&ns.client.commands, conn.gate_command(&ui.settings))
	conn.push_command(&ns.client.commands, conn.transfer_limits_command(&ui.settings))
	return ns
}

// session_slot returns the first three consecutive WebSocket slots that no
// session uses, for a web build (see conn/transport_web.odin): 0 to 2 for the
// first session, 3 to 5 for the next. A desktop build has no use for it.
@(private = "file")
session_slot :: proc(ui: ^UI) -> i32 {
	for slot := i32(0);; slot += 3 {
		taken := false
		for other in ui.sessions {
			taken ||= other.slot == slot
		}
		if !taken {
			return slot
		}
	}
}

// reconnect tries a server that isn't connected again right now. A connection
// that is still trying (see conn.connection_lost) is told to retry, and one
// that has stopped (for example after being refused) is started again in its
// place. Called between frames.
reconnect :: proc(ui: ^UI, ns: ^Net_Session) {
	if ns == nil || ns.joining {
		return
	}
	retrying: bool
	{
		sync.guard(&ns.view.mutex)
		retrying = ns.view.retrying
	}
	if retrying {
		conn.push_command(&ns.client.commands, conn.Reconnect_Command{})
		return
	}
	log.infof("ui: connecting to %s again", ns.server)
	connect_to(ui, ns.server, ns.password)
}

// disconnect leaves a server: its session ends and it is no longer joined.
// If it was the one shown, the next one in the rail is shown instead. A server
// that is being joined from the + page is given up instead. Called between
// frames.
disconnect :: proc(ui: ^UI, ns: ^Net_Session) {
	if ns == nil {
		return
	}
	if ns.joining {
		join_close(ui)
		return
	}
	settings.leave_server(&ui.settings, ns.server)
	save_settings(ui)
	relay_release(ui, ns.server)
	in_voice: bool
	{
		sync.guard(&ns.view.mutex)
		in_voice = ns.view.my_room != 0 || ns.view.voice_pending
	}
	if in_voice {
		// What was shared there has nobody to go to any more.
		conn.video_share_stop()
		conn.video_camera_stop()
		app_audio_stop(ui)
	}
	session_remove(ui, ns)
	session_free(ui, ns)
}

// session_remove takes a session off the rail together with what the UI kept
// for it. If it was the one shown, the one after it is shown, or else the
// one before it, or none.
session_remove :: proc(ui: ^UI, ns: ^Net_Session) {
	index := -1
	for other, i in ui.sessions {
		if other == ns {
			index = i
		}
	}
	if index < 0 {
		return
	}
	ordered_remove(&ui.sessions, index)
	if ui.voice_at == ns {
		ui.voice_at = nil
	}
	if ns != ui.session {
		stash_destroy(ui, ns)
		return
	}
	server_ui_destroy(ui)
	ui.session, ui.view = nil, &ui.no_view
	// Not one that is being joined, which isn't on the rail.
	next: ^Net_Session
	for i := min(index, len(ui.sessions) - 1); i >= 0; i -= 1 {
		if !ui.sessions[i].joining {
			next = ui.sessions[i]
			break
		}
	}
	show_session(ui, next)
}

// session_free stops a session that is off the rail and frees it.
session_free :: proc(ui: ^UI, ns: ^Net_Session) {
	app_audio_session_gone(ui, ns)
	// Close the devices first, so nothing touches the rings after the voice goes away.
	audio.close_streams(&ns.streams, &ns.client.voice)
	sync.atomic_store(&ns.stop, true)
	net_stop(ns)
	audio.voice_destroy(&ns.client.voice)
	free(ns.client)
	conn.view_destroy(&ns.view)
	delete(ns.key_path)
	delete(ns.server)
	delete(ns.password)
	delete(ns.known_servers)
	delete(ns.channel)
	delete(ns.look_at)
	free(ns)
}

// disconnect_all ends every session at once.
disconnect_all :: proc(ui: ^UI) {
	for len(ui.sessions) > 0 {
		ns := ui.sessions[len(ui.sessions) - 1]
		session_remove(ui, ns)
		session_free(ui, ns)
	}
}

// set_muted plays the muted or unmuted sound, unless it is part of
// deafening (`feedback` false), which plays its own sound.
set_muted :: proc(ui: ^UI, muted: bool, feedback := true) {
	if muted == ui.muted {
		return
	}
	if !muted && ui.deafened {
		// Being heard by everyone while hearing nobody isn't somewhere anyone
		// means to be, so unmuting also undeafens, and stays unmuted.
		ui.muted_before_deafen = false
		set_deafened(ui, false)
		return
	}
	ui.muted = muted
	// Every server's: the feedback sound only from the one in voice, or
	// with none, the one shown.
	for ns in ui.sessions {
		heard := feedback && ns == sound_session(ui)
		conn.push_command(&ns.client.commands, conn.Mute_Command{muted = muted, feedback = heard})
	}
}

// Deafen silences everyone else. Like mute, it lives on the UI so it
// survives reconnecting, and it is pushed to the network thread.
//
// Deafening also mutes, because not being able to hear anyone while still
// sending to them is an odd state to be in. It remembers what mute
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
	for ns in ui.sessions {
		conn.push_command(
			&ns.client.commands,
			conn.Deafen_Command{deafened = deafened, feedback = ns == sound_session(ui)},
		)
	}
}

// reopen_audio switches the running connections to the devices that are now
// selected in the settings.
reopen_audio :: proc(ui: ^UI, input: bool) {
	if m := &ui.monitor; m.active {
		if input {
			audio.open_capture(&ui.audio, &m.streams, &m.voice, ui.settings.input_device)
		} else if m.streams.playback != nil {
			audio.open_playback(&ui.audio, &m.streams, &m.voice, ui.settings.output_device)
		}
	}
	for ns in ui.sessions {
		if !ns.client.voice.ready {
			continue
		}
		if input {
			// A microphone that isn't wanted is left closed (see session_capture_update).
			if ns.capture_on {
				audio.open_capture(
					&ui.audio,
					&ns.streams,
					&ns.client.voice,
					ui.settings.input_device,
				)
			}
		} else {
			audio.open_playback(
				&ui.audio,
				&ns.streams,
				&ns.client.voice,
				ui.settings.output_device,
			)
		}
	}
}

// session_capture_update runs every frame, before the layout and with no
// View locked. It records which session is in voice (see UI.voice_at; there is
// at most one), and keeps a connection's microphone open only while it is
// wanted: while it is in a voice room (a channel's voice or a call) or on its
// way into one, and, for the shown session or the one in voice, while the
// settings page tests it (see mic_test_wanted; its meter and listen back
// come from the connection). Joining a server alone doesn't open the microphone.
@(private = "file")
session_capture_update :: proc(ui: ^UI) {
	ui.voice_at = nil
	for ns in ui.sessions {
		if in_voice(ns) {
			ui.voice_at = ns
			break
		}
	}
	// When not in voice, what was shared has nobody to go to, so the capture
	// ends with it (otherwise the OS keeps showing it with the yellow border and
	// the menu bar icon).
	if ui.voice_at == nil {
		conn.video_share_stop()
		app_audio_stop(ui)
	}
	// The camera, likewise, and when we move elsewhere (ui_camera.odin).
	camera_follow(ui)
	// The screen, if it is being shared, goes to the voice too.
	for ns in ui.sessions {
		sync.atomic_store(&ns.client.video.share_here, ns == ui.voice_at)
	}
	test := mic_test_wanted(ui)
	tester := ui.voice_at if ui.voice_at != nil else ui.session
	for ns in ui.sessions {
		if !ns.client.voice.ready {
			continue
		}
		want := ns == ui.voice_at || (test && ns == tester)
		if want == ns.capture_on {
			continue
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
}

@(private = "file")
layout :: proc(ui: ^UI, w, h: i32) {
	ctx := &ui.ctx
	// The server rail down the left (see ui_servers.odin), and one window
	// that always fills the rest of the OS window.
	rail := rail_width(ui)
	server_rail(ui, h)
	rail_menu(ui)
	if cnt := mu.get_container(ctx, "yap"); cnt != nil {
		cnt.rect = {rail, 0, w - rail, h}
		// Always under the windows that float over it (pins, threads,
		// the picker...). microui raises a clicked window unless its
		// zindex is below 0, and sorts the lowest first.
		cnt.zindex = -1
	}
	if mu.begin_window(ctx, "yap", {rail, 0, w - rail, h}, {.NO_TITLE, .NO_RESIZE, .NO_CLOSE}) {
		titlebar_buttons(ui, w)
		main_window(ui)
		mu.end_window(ctx)
	}
	rail_divider_gap(ui, rail)
	// An enlarged image floats above everything else (see ui_images.odin).
	image_viewer(ui, w, h)
	// A screen that is being watched, popped out of its tab (see ui_video.odin).
	screen_window(ui, w, h)
	// The cameras, popped out of the Video tab (see ui_camera.odin).
	camera_window(ui, w, h)
	pins_window(ui, w, h)
	thread_windows(ui, w, h)
	profile_windows(ui, w, h)
	completion_window(ui)
	picker_window(ui, w, h)
	channels_window(ui, w, h)
	forward_window(ui, w, h)
	search_window(ui, w, h)
	// After every timeline, the thread windows' timelines too.
	message_bar(ui)
	dropdown_popup(ui, w, h)
	// Last, and in windows of their own, so they are over the popups too.
	chip_preview_popup(ui, w, h)
	icon_hint(ui, w, h)
	drop_hint(ui)
}

// rail_divider_gap hides the line between the rail and the main window
// (their two borders) along the strip of the merged macOS title bar, where
// the window's buttons are (see ui_titlebar_darwin.odin). The borders belong
// to the windows, which can't draw outside themselves, so this is a window of
// its own, in the windows' color, drawn over them.
@(private = "file")
rail_divider_gap :: proc(ui: ^UI, rail: i32) {
	if ui.titlebar_left <= 0 || ui.titlebar_height <= 0 {
		return
	}
	ctx := &ui.ctx
	r := mu.Rect{rail - 1, 0, 3, ui.titlebar_height}
	cnt := mu.get_container(ctx, "title gap")
	if cnt == nil {
		return
	}
	cnt.rect = r
	opts := mu.Options{.NO_TITLE, .NO_FRAME, .NO_RESIZE, .NO_SCROLL, .NO_CLOSE, .NO_INTERACT}
	if !mu.begin_window(ctx, "title gap", r, opts) {
		return
	}
	defer mu.end_window(ctx)
	mu.draw_rect(ctx, r, ctx.style.colors[.WINDOW_BG])
}

@(private = "file")
main_window :: proc(ui: ^UI) {
	// Joining a server from the + page (see ui_join.odin), which is all there is
	// when there is no server to show.
	if ui.join.open || (ui.session != nil && ui.session.joining) {
		join_page(ui)
		return
	}
	if ui.page == .Settings {
		settings_page(ui)
		return
	}
	if ui.session == nil {
		join_page(ui)
		return
	}

	// Every server's part of the inbox, with each View locked in turn, before
	// the shown server's part for the frame.
	ui.inbox = inbox_list(ui) if ui.page == .Buddies else nil
	v := ui.view
	sync.guard(&v.mutex)
	apply_gains(ui)
	switch v.status {
	case .Disconnected, .Failed:
		// The buddy screen goes away with the connection.
		if ui.page == .Buddies {
			ui.page = .Main
		}
		connect_screen(ui)
	case .Connecting, .Connected:
		// A server that doesn't know this device shows nothing until the device is
		// logged in (see ui_account.odin), and neither does a server whose password was
		// chosen by somebody else, until it has been replaced.
		switch {
		case v.status == .Connected && v.login.state != .Done:
			ui.page = .Main
			login_screen(ui)
		case v.status == .Connected && v.login.must_change:
			ui.page = .Main
			password_screen(ui)
		case v.status == .Connected && v.login.unverified:
			ui.page = .Main
			verify_screen(ui)
		case ui.page == .Buddies:
			buddies_screen(ui)
		case:
			session_screen(ui)
		}
	}
}

// connect_screen shows a server on the rail that isn't connected, in a card:
// what went wrong, when it will be tried again, the trust prompt if its key has
// changed, and buttons to try again now or to leave it.
@(private = "file")
connect_screen :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := ui.view
	card_begin(ui, "connect card", ui.connect_card_h)
	defer card_end(ui, &ui.connect_card_h)

	server := ui.session.server
	card_heading(ui, v.server_name if v.server_name != "" else server)
	mu.layout_row(ctx, {-1})
	switch {
	case v.status == .Failed && v.error != "":
		with_text_color(ctx, theme.error, v.error, wrap_text)
	case v.status == .Failed:
		with_text_color(ctx, theme.error, "Could not connect.", mu.text)
	case:
		with_text_color(ctx, theme.dim, "Not connected.", mu.text)
	}
	if v.retrying {
		mu.layout_row(ctx, {-1})
		if v.retry_at == {} {
			with_text_color(ctx, theme.dim, "Connecting...", mu.text)
		} else {
			// Counted down one second at a time.
			left := time.tick_diff(time.tick_now(), v.retry_at)
			secs := max(int(math.ceil(time.duration_seconds(left))), 1)
			with_text_color(ctx, theme.dim, fmt.tprintf("Trying again in %ds.", secs), mu.text)
			ui_redraw_in(ui, left - time.Duration(secs - 1) * time.Second)
		}
	}
	key_change := v.status == .Failed && v.key_change.changed
	if key_change {
		key_change_panel(ui)
	}
	mu.layout_row(ctx, {-1}, ctx.style.spacing)
	mu.layout_next(ctx)
	mu.layout_row(ctx, {-1})
	// With a changed key, trusting the new key is what connects again.
	if !key_change && .SUBMIT in mu.button(ctx, "Reconnect") {
		ui.action = .Reconnect
	}
	if .SUBMIT in mu.button(ctx, "Leave this server") {
		ui.action = .Disconnect
	}
}

// In a window narrower than this (a phone, or a window squeezed to the side),
// the channels go above the chat instead of beside it.
NARROW_LAYOUT :: 600

// How roomy controls are: microui's padding inside them and spacing between
// them, and the size of its controls (a row is size.y + 2 * padding tall).
// microui's own are 5, 4 and 68x10. On a phone, rows are 40 px tall, as big as
// a fingertip, and closer together, to leave room for the messages.
STYLE_PADDING :: 6
STYLE_SPACING :: 6
STYLE_SIZE :: mu.Vec2{80, 14}
COMPACT_PADDING :: 6
COMPACT_SPACING :: 4
COMPACT_SIZE :: mu.Vec2{80, 28}

// On a phone, the messages (the timeline) are spaced as microui's own
// controls are, closer than elsewhere: there is little room for them.
COMPACT_MESSAGE_PADDING :: 5
COMPACT_MESSAGE_SPACING :: 4

// style_apply sets microui's sizes for this frame, a window `width` wide: for
// a finger where the window is as narrow as a phone's (as session_screen
// tells it, beside the rail) or a touch screen has been used.
style_apply :: proc(ui: ^UI, width: i32) {
	ui.compact = width - RAIL_WIDTH < NARROW_LAYOUT || ui.touched
	style := ui.ctx.style
	if ui.compact {
		style.padding, style.spacing, style.size = COMPACT_PADDING, COMPACT_SPACING, COMPACT_SIZE
	} else {
		style.padding, style.spacing, style.size = STYLE_PADDING, STYLE_SPACING, STYLE_SIZE
	}
}

@(private = "file")
session_screen :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := ui.view
	body := mu.get_current_container(ctx).body
	narrow := body.w < NARROW_LAYOUT
	ui.narrow = narrow

	screen_tab_follow(ui)
	camera_tab_follow(ui)
	back_from_dms(ui)
	if camera_fullscreen(ui) {
		camera_full_screen(ui)
		return
	}
	if v.watching != 0 && conn.video_is_fullscreen() {
		fullscreen_screen(ui)
		return
	}

	if !narrow {
		session_header(ui)
	}

	// Side by side where there is room. In a narrow window the list and
	// the chat take turns (see ui_channels.odin), over the voice panel.
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
	channel_menu(ui)
	message_menu(ui)
	app_audio_menu(ui)
	share_menu(ui)
}

// titlebar_merged says whether the window's buttons are drawn in the top row
// of our own layout (ui_titlebar.odin) rather than in a title bar of the
// system's, which shows the window's title.
titlebar_merged :: proc(ui: ^UI) -> bool {
	return ui.titlebar_left > 0 || ui.titlebar_right > 0
}

// title_row is mu.layout_row for a screen's first row. With the title bar
// merged, that row shares the top of the window with the window's buttons
// (see ui_titlebar.odin), so it keeps clear of them. On macOS the buttons are on
// the left, so the row starts to the right of them. On Windows and X11 they are
// on the right, so widths counted from the right-hand edge are counted
// from the buttons instead.
title_row :: proc(ui: ^UI, widths: []i32, height: i32 = 0) {
	layout := mu.get_layout(&ui.ctx)
	indent := layout.indent
	layout.indent += max(ui.titlebar_left - layout.body.x, 0)
	if ui.titlebar_right == 0 {
		mu.layout_row(&ui.ctx, widths, height)
	} else {
		kept_clear := make([]i32, len(widths), context.temp_allocator)
		for w, i in widths {
			kept_clear[i] = w <= 0 ? w - ui.titlebar_right : w
		}
		mu.layout_row(&ui.ctx, kept_clear, height)
	}
	layout.indent = indent
}

// session_header is the row along the top while connected, showing the server
// or the inbox. The session screen and the inbox share it. The connection's
// status and the settings are at the bottom of the rail
// (see rail_bottom). Mute, deafen and what is shared are in the voice panel
// (see ui_voice_panel.odin).
//
// It is only there with the title bar merged (titlebar_merged), where the row
// is taken anyway by the window's buttons. Otherwise the window's own title
// says the same (servers_frame), and the row is left to the chat, unless there
// is something to say about connecting.
session_header :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := ui.view
	if !titlebar_merged(ui) && (ui.page == .Buddies || v.status == .Connected) {
		return
	}
	title_row(ui, {-1})
	switch {
	case ui.page == .Buddies:
		opts := mu.Options{.ALIGN_CENTER}
		mu.draw_control_text(ctx, "Direct messages", mu.layout_next(ctx), .TEXT, opts)
	case v.status == .Connected:
		server := v.server_name if v.server_name != "" else v.server
		opts := mu.Options{.ALIGN_CENTER}
		mu.draw_control_text(ctx, fmt.tprintf("%s", server), mu.layout_next(ctx), .TEXT, opts)
	case:
		mu.label(ctx, fmt.tprintf("Connecting to %s...", v.server))
	}
}

// How tightly log lines are packed: exactly LINE_HEIGHT tall, instead of the
// couple of pixels of slack the default control size has, and with a tighter
// gap between rows than the rest of the UI uses, so more of the log
// fits on screen at once.
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
		// No logging in here, because the log sink takes this same lock.
		sync.guard(&logs.mutex)
		total = logs.total
		ui.log_drawn = total // for frame_due to look out for more

		saved_spacing := ctx.style.spacing
		ctx.style.spacing = LOG_LINE_SPACING
		defer ctx.style.spacing = saved_spacing

		font := render.font_with_style(ctx.style.font, .Mono)
		// A line longer than the panel makes every row as wide as that line,
		// which is what makes microui add a horizontal scrollbar.
		widest: i32
		for line in logs.lines {
			text := line.text[11:] if len(line.text) > 11 else line.text
			widest = max(widest, ctx.text_width(font, text))
		}
		row_w := widest + ctx.style.padding * 2
		if row_w <= cnt.body.w - ctx.style.padding * 2 {
			row_w = -1
		}
		// Lines are numbered by the running total, so a selection stays
		// on the same lines as new lines come in (see ui_select.odin).
		first := i64(logs.total - len(logs.lines))
		for line, i in logs.lines {
			mu.layout_row(ctx, {row_w}, render.LINE_HEIGHT)
			// Drop the date, because the time is enough on screen.
			text := line.text[11:] if len(line.text) > 11 else line.text
			color := ctx.style.colors[.TEXT]
			switch {
			case line.level >= .Error:
				color = theme.error
			case line.level >= .Warning:
				color = theme.warning
			case line.level < .Info:
				color = theme.dim
			}
			// Where mu.label would put it.
			r := mu.layout_next(ctx)
			pos := mu.Vec2{r.x + ctx.style.padding, r.y + (r.h - ctx.text_height(font)) / 2}
			item := first + i64(i)
			select_item(ui, item, text)
			select_line(ui, item, text, 0, len(text), pos, font = font)
			mu.draw_text(ctx, font, text, pos, color)
		}
	}
	select_end(ui)
	mu.end_panel(ctx)
}

// A button with nothing but an icon on it is this wide, or as wide as it is
// tall where rows are taller (icon_button_w).
ICON_BUTTON :: 30

// icon_button_w is how wide a button with only an icon on it is: square on a
// phone, where rows are a fingertip tall (style_apply).
icon_button_w :: proc(ctx: ^mu.Context) -> i32 {
	return max(ICON_BUTTON, ctx.style.size.y + 2 * ctx.style.padding)
}

// draw_frame_themed is microui's draw_frame (render.draw_frame), except that a
// focused text box has a ring in the theme's accent color (its border and one
// more line inside it), and a window that floats over the main window casts a
// shadow.
draw_frame_themed :: proc(ctx: ^mu.Context, rect: mu.Rect, colorid: mu.Color_Type) {
	// A window's frame is drawn while it is the current container
	// (begin_window). The main window and the rail are below everything.
	if colorid == .WINDOW_BG &&
	   ctx.container_stack.idx > 0 &&
	   mu.get_current_container(ctx).zindex >= 0 {
		render.draw_shadow(ctx, rect, theme.shadow)
	}
	if colorid == .SCROLL_BASE || colorid == .SCROLL_THUMB {
		scrollbar_frame(g_ui, rect, colorid)
		return
	}
	if colorid != .BASE_FOCUS {
		render.draw_frame(ctx, rect, colorid)
		return
	}
	// The outer line is snapped from the inner one, so that the two touch
	// on every side at any scale.
	radius := i32(render.CONTROL_RADIUS - 1)
	render.draw_rounded_outside(ctx, rect, ctx.style.colors[colorid], radius)
	render.draw_rounded_outside(ctx, rect, theme.accent, radius, border = true)
	render.draw_rounded_border(ctx, rect, theme.accent, radius)
}

// stable_button is mu.button, except that its id comes from `id_name` (under
// the current id stack) instead of from the label, so the label can
// change from frame to frame without the button becoming a new control.
// icon_button is a button with an icon on it instead of a label. While the
// pointer is on it, a hint below it shows the words the icon saves. Like
// stable_button, its id comes from `id_name`, so a button that changes
// what it shows (mute to unmute) keeps the same id.
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
	// Filled, without a border, or flat: a background only while the pointer
	// is on it or it is pressed.
	colorid := mu.Color_Type.BUTTON
	if ctx.focus_id == id {
		colorid = .BUTTON_FOCUS
	} else if ctx.hover_id == id {
		colorid = .BUTTON_HOVER
	}
	if !ui.flat_buttons || colorid != .BUTTON {
		render.draw_rounded(ctx, r, ctx.style.colors[colorid], render.CONTROL_RADIUS)
	}
	mu.draw_icon(ctx, render.icon_id(icon), r, color if color.a != 0 else ctx.style.colors[.TEXT])
	if ctx.hover_id == id {
		ui.hint, ui.hint_of = hint, r
	}
	return
}

// A spinner turns once a second, a step at a time.
SPINNER_STEP :: time.Second / render.SPINNER_STEPS

// spinner says that something is loading: a turning ring in the middle of
// `r`, dim unless it gets a `color`. While it is on screen, it asks for a frame
// when it is to turn next, and only then: a spinner scrolled out of view
// costs no frames.
spinner :: proc(ui: ^UI, r: mu.Rect, color := mu.Color{}) {
	ctx := &ui.ctx
	if mu.check_clip(ctx, r) == .ALL {
		return
	}
	// The same step everywhere, from the clock.
	ns := time.tick_now()._nsec
	step := ns / i64(SPINNER_STEP)
	mu.draw_icon(
		ctx,
		render.spinner_id(int(step % render.SPINNER_STEPS)),
		r,
		color if color.a != 0 else theme.dim,
	)
	ui_redraw_in(ui, time.Duration(i64(SPINNER_STEP) - ns % i64(SPINNER_STEP)))
}

// spinner_row is a row of its own with a spinner in its middle.
spinner_row :: proc(ui: ^UI) {
	mu.layout_row(&ui.ctx, {-1})
	spinner(ui, mu.layout_next(&ui.ctx))
}

// menu_list_begin starts a list of `rows` rows in a menu, `width` wide. The rows
// are buttons or labels, each on a row of its own, laid out with {-1}. The list
// is as tall as its rows, up to half the window, beyond which it scrolls instead
// of the menu growing off the window. It has no frame or padding of its own, so
// its rows line up with the menu's. End it with mu.end_panel.
menu_list_begin :: proc(ui: ^UI, name: string, width: i32, rows: int) {
	ctx := &ui.ctx
	row := ctx.style.size.y + 2 * ctx.style.padding
	tall := i32(rows) * (row + ctx.style.spacing) - ctx.style.spacing
	most := max(i32(ui.metrics.logical_h) / 2, 3 * row)
	mu.layout_row(ctx, {width}, clamp(tall, 0, most))
	padding := ctx.style.padding
	ctx.style.padding = 0
	mu.begin_panel(ctx, name, {.NO_FRAME})
	ctx.style.padding = padding
}

// icon_hint draws what the icon button under the pointer does, just below
// it, or the tooltip of whatever else set `ui.hint`, which may run over
// several lines. microui paints each window and popup as a whole, in
// z-order, so the hint gets a frameless window of its own, raised above
// the rest. If it were drawn inside the main window, a popup (the user menu)
// would cover it.
@(private = "file")
HINT_WINDOW :: "hint"

// The emoji a hint is about: one of the server's (by its index), or else a
// character as a string. Both are empty for none.
Hint_Emoji :: struct {
	custom:  Maybe(int),
	unicode: string, // temp
}

// hint_emoji_of makes the hint show `emoji` large: a reaction's or
// message's emoji, ":name:" for the server's, else the characters. Call with
// the View locked.
hint_emoji_of :: proc(ui: ^UI, emoji: string) {
	if strings.has_prefix(emoji, ":") && strings.has_suffix(emoji, ":") && len(emoji) > 2 {
		name := emoji[1:len(emoji) - 1]
		for n, i in ui.view.emoji.names {
			if n == name {
				ui.hint_emoji = {
					custom = i,
				}
				return
			}
		}
		return
	}
	ui.hint_emoji = {
		unicode = emoji,
	}
}

@(private = "file")
icon_hint :: proc(ui: ^UI, window_w, window_h: i32) {
	ctx := &ui.ctx
	if ui.hint == "" {
		return
	}
	emoji := ui.hint_emoji
	defer ui.hint, ui.hint_emoji = "", {}

	pad := ctx.style.padding
	line_h := ctx.text_height(ctx.style.font)
	w, lines: i32
	rest := ui.hint
	for line in strings.split_lines_iterator(&rest) {
		w = max(w, ctx.text_width(ctx.style.font, line))
		lines += 1
	}
	// The emoji, large, above the text.
	big_w, big_h: i32
	if _, custom := emoji.custom.?; custom || emoji.unicode != "" {
		big_h = ctx.text_height(render.PREVIEW_FONT)
		big_w = big_h
		if !custom {
			big_w = ctx.text_width(render.PREVIEW_FONT, emoji.unicode)
		}
		w = max(w, big_w)
	}
	w += 2 * pad
	h := lines * line_h + 2 * pad
	if big_h > 0 {
		h += big_h + pad
	}
	// Under the button, moved left if it would go off the side, and
	// above it if there is no room below (the chat box's Send button).
	x := min(ui.hint_of.x, max(window_w - w, 0))
	y := ui.hint_of.y + ui.hint_of.h + 2
	if y + h > window_h {
		y = max(ui.hint_of.y - h - 2, 0)
	}
	r := mu.Rect{x, y, w, h}
	// The pointer is on the button, never on the hint, so the window
	// doesn't take the hover away from the thing it describes.
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
	render.draw_rounded(ctx, r, ctx.style.colors[.BASE], render.CONTROL_RADIUS)
	render.draw_rounded_border(ctx, r, ctx.style.colors[.BORDER], render.CONTROL_RADIUS)
	line_y := y + pad
	if big_h > 0 {
		at := mu.Vec2{x + (w - big_w) / 2, line_y}
		if index, custom := emoji.custom.?; custom {
			if icon, ok := custom_emoji_icon(ui, index); ok {
				mu.draw_icon(ctx, icon, {at.x, at.y, big_w, big_h}, {255, 255, 255, 255})
			}
		} else {
			mu.draw_text(ctx, render.PREVIEW_FONT, emoji.unicode, at, ctx.style.colors[.TEXT])
		}
		line_y += big_h + pad
	}
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

// list_row is a line of a list to pick from (such as a settings tab's
// categories or the channels), shown as text. It is boxed and bold while it is
// the selected one and highlighted under the mouse. Clicking it with the left
// button submits it. With `accent`, the selected one is in the accent color
// (what is shown: a settings category, the channel that is open), rather than
// grey (the current choice in a dropdown or a list of options).
list_row :: proc(
	ctx: ^mu.Context,
	id_name, label: string,
	selected: bool,
	accent := false,
) -> (
	res: mu.Result_Set,
) {
	id := mu.get_id(ctx, id_name)
	r := mu.layout_next(ctx)
	mu.update_control(ctx, id, r)
	if ctx.hover_id == id && ctx.mouse_pressed_bits == {.LEFT} {
		res += {.SUBMIT}
	}
	switch {
	case selected && accent:
		color := theme.accent_hover if ctx.hover_id == id else theme.accent
		render.draw_rounded(ctx, r, color, render.CONTROL_RADIUS)
	case selected:
		render.draw_rounded(ctx, r, ctx.style.colors[.BUTTON_FOCUS], render.CONTROL_RADIUS)
	case ctx.hover_id == id:
		render.draw_rounded(ctx, r, ctx.style.colors[.BUTTON_HOVER], render.CONTROL_RADIUS)
	}
	saved, saved_text := ctx.style.font, ctx.style.colors[.TEXT]
	if selected {
		ctx.style.font = render.font_with_style(saved, .Bold)
	}
	if selected && accent {
		ctx.style.colors[.TEXT] = theme.accent_text
	}
	mu.draw_control_text(ctx, label, r, .TEXT, {})
	ctx.style.font, ctx.style.colors[.TEXT] = saved, saved_text
	return
}

// checkbox is mu.checkbox, except that it is ticked when the mouse button
// goes down on it, like a button, instead of when it comes up. Otherwise a
// press that closes a dropdown's list (dropdown_popup) or changes the
// settings page under the pointer would tick the checkbox that is there
// when the button comes up.
checkbox :: proc(ctx: ^mu.Context, label: string, state: ^bool) -> (res: mu.Result_Set) {
	id := mu.get_id(ctx, uintptr(state))
	r := mu.layout_next(ctx)
	box := mu.Rect{r.x, r.y, r.h, r.h}
	mu.update_control(ctx, id, r)
	if ctx.mouse_pressed_bits == {.LEFT} && ctx.focus_id == id {
		res += {.CHANGE}
		state^ = !state^
	}
	mu.draw_control_frame(ctx, id, box, .BASE)
	if state^ {
		mu.draw_icon(ctx, .CHECK, box, ctx.style.colors[.TEXT])
	}
	mu.draw_control_text(ctx, label, {r.x + box.w, r.y, r.w - box.w, r.h}, .TEXT)
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

// GLFW input -> microui. The callbacks run on the main thread, inside
// glfw.WaitEventsTimeout.

// to_logical turns window coordinates into the UI's (see Window_Metrics).
to_logical :: proc "contextless" (v: f64) -> i32 {
	return i32(v * f64(g_ui.input_scale))
}

// iconify_callback records that the desktop has minimized us, so the loop can
// move the client to the tray if the settings say so.
//
// Not every desktop reports this. X11 does. Wayland has no message for it, so
// there the window simply minimizes and the setting does nothing. The
// settings page says as much when it would matter.
@(private = "file")
iconify_callback :: proc "c" (window: glfw.WindowHandle, iconified: i32) {
	if iconified != 0 {
		g_ui.minimized = true
	}
	ui_redraw(g_ui)
}

// focus_callback draws a frame when the window gains or loses the focus,
// because animated pictures only play while it has the focus (see anims_running).
@(private = "file")
focus_callback :: proc "c" (window: glfw.WindowHandle, focused: i32) {
	ui_redraw(g_ui)
}

// refresh_callback is called when the window needs its contents drawn again,
// for example when it was uncovered and nothing kept them. A frame is then drawn
// at the next turn of the loop, except on Windows, where one is drawn right
// away. There it also comes while the window is being resized: dragging its edge
// runs a loop of the system's own until the mouse is released, and
// glfw.WaitEventsTimeout doesn't return before then, so without this
// the window would stand still for as long as the drag lasts.
@(private = "file")
refresh_callback :: proc "c" (window: glfw.WindowHandle) {
	context = platform.callback_context()
	context.logger = g_logger
	ui_redraw(g_ui)
	when ODIN_OS == .Windows {
		if g_ui.window == window && !g_ui.hidden {
			draw_frame(g_ui)
		}
	}
}

// resize_callback is macOS's way into the resize loop that refresh_callback
// describes. AppKit never asks a view whose layer is ours (Metal's) to
// draw, so no refresh comes while the edge is dragged, but the window's
// size changes do. Each one is drawn at once, in step with the window's new
// size (see render.gpu_resizing), or the picture would lag behind its edge.
when ODIN_OS == .Darwin {
	@(private = "file")
	resize_callback :: proc "c" (window: glfw.WindowHandle, width, height: i32) {
		context = platform.callback_context()
		context.logger = g_logger
		ui_redraw(g_ui)
		if g_ui.window == window && !g_ui.hidden {
			render.gpu_resizing(&g_ui.renderer.gpu, true)
			draw_frame(g_ui)
			render.gpu_resizing(&g_ui.renderer.gpu, false)
		}
	}
}

@(private = "file")
cursor_pos_callback :: proc "c" (window: glfw.WindowHandle, x, y: f64) {
	context = platform.callback_context()
	ui_redraw(g_ui)
	titlebar_motion(window)
	mu.input_mouse_move(&g_ui.ctx, to_logical(x), to_logical(y))
}

// cursor_enter_callback takes the pointer out of microui's sight when it
// leaves the window, so nothing stays hovered (for example an animated picture
// that plays while the pointer is on it). The exception is while a button is
// held, because something is being dragged, which carries on outside the window.
@(private = "file")
cursor_enter_callback :: proc "c" (window: glfw.WindowHandle, entered: i32) {
	context = platform.callback_context()
	if entered == 0 && g_ui.ctx.mouse_down_bits == {} {
		ui_redraw(g_ui)
		mu.input_mouse_move(&g_ui.ctx, -100_000, -100_000)
	}
}

@(private = "file")
mouse_button_callback :: proc "c" (window: glfw.WindowHandle, button, action, mods: i32) {
	context = platform.callback_context()
	context.logger = g_logger
	ui_redraw(g_ui)
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
	// press is somewhere else (because motion events were missed), it would click
	// whatever was under the old position, so drop the hover instead.
	// The edges of a window without a frame resize it (X11 only, see
	// ui_titlebar_x11.odin), and the strip where a title bar would be
	// moves it instead, where it isn't a control in the main window.
	if btn == .LEFT && action == glfw.PRESS {
		if edge := window_edge(g_ui, x, y); edge != .None {
			titlebar_resize(window, edge)
			return
		}
	}
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

// How far a notch of the mouse wheel scrolls, in pixels.
WHEEL_NOTCH :: 60

@(private = "file")
scroll_callback :: proc "c" (window: glfw.WindowHandle, x, y: f64) {
	context = platform.callback_context()
	ui_redraw(g_ui)
	// A wheel turns in whole notches, which are spread over a few frames
	// (scroll_step). A touchpad scrolls in fractions of one, a little at a
	// time already, so that goes to microui as it comes.
	if x == math.round(x) && y == math.round(y) {
		g_ui.scroll_left += {f32(-x * WHEEL_NOTCH), f32(-y * WHEEL_NOTCH)}
	} else {
		mu.input_scroll(&g_ui.ctx, i32(-x * WHEEL_NOTCH), i32(-y * WHEEL_NOTCH))
	}
}

// The mouse wheel's scrolling eases out: what is left shrinks by e every
// SCROLL_EASE, so a notch is mostly done in a few frames. While some is left,
// frames come every SCROLL_FRAME.
SCROLL_EASE :: 0.1 // seconds
SCROLL_FRAME :: time.Second / 60

// scroll_step hands microui this frame's share of the mouse wheel's
// scrolling, before the frame is laid out. Only whole pixels are handed over,
// so in the end a notch scrolls exactly as far as it would at once.
scroll_step :: proc(ui: ^UI) {
	if ui.scroll_left == {} {
		return
	}
	now := time.tick_now()
	// The first frame of a scroll gets a frame's share too.
	dt := f32(time.duration_seconds(SCROLL_FRAME))
	if ui.scroll_at != {} {
		dt = clamp(f32(time.duration_seconds(time.tick_diff(ui.scroll_at, now))), 0, 0.1)
	}
	left := ui.scroll_left * math.exp(-dt / SCROLL_EASE)
	for &v in left {
		if abs(v) < 1 {
			v = 0 // the rest, now
		}
	}
	give := [2]i32 {
		i32(math.round(ui.scroll_left.x - left.x)),
		i32(math.round(ui.scroll_left.y - left.y)),
	}
	// At least a pixel while some is left: with a slow ease, a frame's share
	// of the last few pixels rounds to none, and it would never finish.
	for &g, i in give {
		if g == 0 && ui.scroll_left[i] != 0 {
			g = 1 if ui.scroll_left[i] > 0 else -1
		}
	}
	ui.scroll_left -= {f32(give.x), f32(give.y)}
	mu.input_scroll(&ui.ctx, give.x, give.y)
	if ui.scroll_left != {} {
		ui.scroll_at = now
		ui_redraw_in(ui, SCROLL_FRAME)
	} else {
		ui.scroll_at = {}
	}
}

@(private = "file")
char_callback :: proc "c" (window: glfw.WindowHandle, codepoint: rune) {
	context = platform.callback_context()
	ui_redraw(g_ui)
	buf, n := utf8.encode_rune(codepoint)
	mu.input_text(&g_ui.ctx, string(buf[:n]))
}

@(private = "file")
key_callback :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
	context = platform.callback_context()
	ui_redraw(g_ui)
	// The composer's markdown keys, from the key's own modifiers.
	// Ctrl+Shift+X isn't Ctrl+X: it doesn't go on to cut.
	if action != glfw.RELEASE && mods & glfw.MOD_CONTROL != 0 && mods & glfw.MOD_ALT == 0 {
		shift := mods & glfw.MOD_SHIFT != 0
		format: Maybe(Extra_Key)
		switch {
		case key == glfw.KEY_B && !shift:
			format = .Bold
		case key == glfw.KEY_I && !shift:
			format = .Italic
		case key == glfw.KEY_U && !shift:
			format = .Underline
		case key == glfw.KEY_E && !shift:
			format = .Code
		case key == glfw.KEY_X && shift:
			format = .Strike
		}
		if f, ok := format.?; ok {
			g_ui.keys += {f}
			return
		}
	}
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
		// Close the enlarged image, if one is open. For the rest of
		// the frame, treat it as a key like microui's (see UI.keys).
		if action == glfw.PRESS {
			g_ui.images.viewer = {}
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
		// Shift+Enter starts a new line in a text area. The key's own
		// modifiers say so, even when Shift is released again before the
		// frame (and with it microui's SHIFT).
		if action != glfw.RELEASE && mods & glfw.MOD_SHIFT != 0 {
			g_ui.keys += {.Newline}
		}
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
	// Emscripten's GLFW has no clipboard. In a browser it comes from the page
	// (see ui_paste_web.odin).
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

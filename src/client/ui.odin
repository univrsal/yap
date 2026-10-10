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
	client:         ^conn.Voice_Client,
	thread:         Net_Thread,
	stop:           bool, // set atomically to end the network loop
	// Without threads there is nobody to notice `stop`, so the frame
	// loop notes here that the connection is done with (net_web.odin).
	stopped:        bool,

	// Owned copies; the UI's buffers may change while the thread runs.
	key_path:       string,
	server:         string,
	password:       string,
	known_servers:  string,
	channel:        string, // to look at and talk in from the start, if any
	look_at:        string, // or else the channel to look at
	// What the connection says, for the UI (the client's View), and what
	// the UI keeps of this server while another is shown (ui_servers.odin).
	view:           conn.View,
	stash:          Server_UI,
	// Which WebSockets are this session's in a web build: slot and
	// slot + 1 (conn/transport_web.odin).
	slot:           i32,
	// Whether it was last told whoever uses this is idle (ui_activity.odin).
	idle_told:      bool,
	// Being joined from the + dialog (ui_join.odin): off the rail, and
	// not in the settings, until it's logged in.
	joining:        bool,
	// Messages unread in its channels, and how many of them mention us,
	// as of this frame: for the rail (servers_frame).
	unread:         int,
	mentions:       int,
	// The call coming in there last told of on the desktop, so it's told
	// once (session_notices).
	call_announced: proto.Call_Id,
	// DMs unread there, which count on the inbox's icon rather than the
	// server's (servers_frame).
	dm_unread:      int,
	// When the server was last asked when the people in the inbox were
	// last here, and how many of them were online then: fewer now means
	// someone just left, and it's worth asking again (ask_last_seen).
	seen_asked:     time.Tick,
	seen_online:    int,

	// Audio devices, opened and closed on the UI thread (which owns the
	// miniaudio context); they feed the client's Voice rings.
	streams:        audio.Audio_Streams,
	// The microphone is wanted, and has been opened, or tried to be
	// (session_capture_update).
	capture_on:     bool,
}

Extra_Key :: enum {
	Up,
	Down,
	Tab,
	Escape,
	Newline, // Shift+Enter, or Enter on a phone's keyboard: a new line in a text area
	// Markdown in a composer (composer_keys): Ctrl+B, Ctrl+I, Ctrl+U,
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
	// What the shown server's connection says (its session's View), or
	// with none, `no_view`, which says nothing is connected.
	view:                ^conn.View,
	no_view:             conn.View,
	session:             ^Net_Session,
	// Every connection, in the rail's order (ui_servers.odin); `session`
	// is one of them, or nil with none. The one being joined from the +
	// dialog is among them too, though not on the rail (ui_join.odin).
	sessions:            [dynamic]^Net_Session,
	join:                UI_Join,
	rail:                UI_Rail, // its menu, and dragging (ui_servers.odin)
	// Messages unread on every server, in channels and DMs that aren't
	// muted: for the window's title and the tray (servers_frame).
	unread:              int,
	// Mentions unread on every server, muted channels too, and DMs: the
	// same, which the title and the tray show before `unread`.
	mentions:            int,
	// DMs unread on every server, for the inbox's icon on the rail.
	dm_unread:           int,
	// The inbox (ui_buddies.odin): everyone in it on every server, as of
	// this frame, and whose DM to open once the rail has switched to
	// their server (switch_now).
	inbox:               []Buddy_Entry,
	inbox_open:          proto.Account_Id,
	// Voice, or a call ringing, in a server that isn't shown, as of this
	// frame (ui_voice_panel.odin).
	voice_other:         Voice_Elsewhere,
	// What the UI keeps of the shown server, which each session keeps
	// while it isn't shown (Net_Session.stash; ui_servers.odin).
	using srv:           Server_UI,
	// The session in voice, as of this frame (session_capture_update).
	voice_at:            ^Net_Session,
	// The rail was clicked: which session to show after the frame. See
	// switch_now.
	switch_to:           ^Net_Session,
	switching:           bool,
	// Connecting/disconnecting waits on the network thread, which may be
	// waiting on the View lock, so it happens after layout, not during.
	action:              Action,
	log_seen:            int, // Log_Lines.total when the log panel was last scrolled
	// What the window's title says of unread messages: the mentions, -1
	// for "(*)" (something unread but no mention), 0 for neither (see
	// title_key).
	title_unread:        int,
	settings_tab:        Settings_Tab, // which the settings page shows (ui_settings.odin)
	// And the category picked in each of its tabs.
	settings_client:     Client_Category,
	settings_server:     Server_Category,
	// Which palette is in use, and what the desktop said (theme.odin).
	theme_state:         UI_Theme,
	// For the chat's local timestamps, every server's; nil means UTC
	// (ui_chat_time_native.odin).
	chat_tz:             ^datetime.TZ_Region,
	activity:            UI_Activity, // whether whoever uses this is idle (ui_activity.odin)
	video:               UI_Video, // screen sharing (ui_video.odin)
	app_audio:           UI_App_Audio, // sharing an application's audio (ui_app_audio_native.odin)
	muted:               bool,
	deafened:            bool,
	// Mute as it was before deafening turned it on, so undeafening can
	// put it back rather than always unmuting (see set_deafened).
	muted_before_deafen: bool,

	// Whose message header is being drawn, and where their name is in it
	// (byte range), so a click on the name opens their menu. 0: none.
	header_sender:       proto.Account_Id,
	header_name:         [2]int,
	// The settings page's microphone monitor and level meter (ui_gate.odin).
	monitor:             Mic_Monitor,
	listen_back:         bool,
	// The welcome and goodbye sounds (ui_app_sounds.odin).
	app_sound:           App_Sound,
	// The voice gate section, with the meter, was on screen last frame
	// (gate_settings); the microphone is only opened for it then.
	meter_shown:         bool,
	meter_level:         f32,
	meter_time:          time.Tick,
	// Slider drags change the settings every frame; save at most once a
	// second, and on exit.
	settings_dirty:      bool,
	// People's pictures and servers' emoji kept on disk between
	// sessions (ui_image_cache.odin), and the settings page's box for
	// its folder.
	image_cache:         conn.Image_Cache,
	image_cache_dir_buf: [512]u8,
	image_cache_dir_len: int,
	// Where the memory goes: the settings' page, the line in the log
	// (ui_memory.odin).
	memory:              UI_Memory,
	// Keys microui has no name for, pressed since the last frame.
	keys:                bit_set[Extra_Key],
	// A message was picked to edit, or a mention completed: its composer
	// takes the focus, with the cursor at `focus_composer_at` (-1: the
	// end).
	focus_composer:      bool,
	focus_composer_at:   int,
	focus_thread:        int, // which composer: Composer.thread
	// People's pictures (ui_avatars.odin).
	avatars:             UI_Avatars,
	// The last frame was laid out narrow, when an open thread takes the
	// conversation's place instead of floating (ui_threads.odin).
	narrow:              bool,
	// The bar over the message under the pointer (ui_message_bar.odin),
	// and whether this frame is a touch screen's tap (ui_touch_web.odin),
	// which shows a message's bar there.
	msg_bar:             UI_Message_Bar,
	touch_tap:           bool,
	settings_saved:      time.Tick,
	page:                Page,
	settings:            settings.Settings,
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
	// The strip along the top where macOS and Windows draw the window's
	// buttons over the UI, in logical pixels: where the first row starts,
	// how far in from the right it ends, and how tall the strip is. Zero
	// elsewhere (see ui_titlebar_darwin.odin, ui_titlebar_windows.odin).
	titlebar_left:       i32,
	titlebar_right:      i32,
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
	paste_to:            Attach_Target,
	// The file dialog, while it's open (ui_files_native.odin).
	file_pick:           ^File_Pick_Job,
	// The paperclip was pressed: after the frame, the dialog opens for
	// files to go with `attach_to`'s next message (ui_attachments.odin).
	attach_pick:         bool,
	attach_to:           Attach_Target,
	// Files dropped on the window since the last frame, to attach
	// (ui_files_*.odin); owned.
	dropped:             [dynamic]string,
	// What the icon button under the pointer does, and where it is, for
	// the hint drawn under it (see icon_button and icon_hint).
	hint:                string,
	hint_of:             mu.Rect,
	// The emoji the hint is about, drawn large above it (icon_hint).
	hint_emoji:          Hint_Emoji,
	// The picture chip under the pointer, shown over it
	// (chip_preview_popup).
	chip_preview:        Chip_Preview,
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
	// A frame is only drawn when there's something new to show (see
	// frame_due): how many more to draw whatever happens, when the
	// clock next changes something on screen (zero: nothing does), the
	// hash of the last frame's draw commands, and how many log lines
	// the log panel showed in it (-1: it wasn't on screen).
	redraw_frames:       int,
	redraw_at:           time.Tick,
	drawn_hash:          u64,
	log_drawn:           int,
}

// For GLFW's callbacks, which have no user data we can use cheaply, and
// the page's touch input in a web build (ui_touch_web.odin).
g_ui: ^UI
@(private = "file")
g_logger: log.Logger

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

	// Audio problems shouldn't keep the rest of the client from working;
	// the settings page shows what went wrong.
	audio.audio_init(&ui.audio)
	app_audio_init(ui)
	app_sound_play(ui, .Welcome)

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
	ui.ctx.draw_frame = render.draw_frame
	ui.input_scale = 1

	ui.action = .Start
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

	if ui.action != .None {
		ui_redraw(ui)
	}
	switch ui.action {
	case .None:
	case .Start:
		connect_joined(ui)
	case .Connect:
		connect(ui)
	case .Disconnect:
		disconnect(ui, ui.session)
	case .Trust_Key:
		trust_new_key(ui)
	}
	ui.action = .None
	join_frame(ui)
	rail_frame(ui)
	switch_now(ui)
	memory_frame(ui)

	// Wake up for input, or often enough for the work below that isn't
	// drawing; a frame is only drawn when there's something new to show
	// (frame_due). Listen back without a connection is fed from this
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

	if ui.settings_dirty && time.tick_since(ui.settings_saved) > time.Second {
		save_settings(ui)
	}

	// Listen back is a settings-page test; don't leave it running.
	if ui.page != .Settings {
		set_listen_back(ui, false)
	}
	monitor_update(ui)
	app_sound_step(ui)
	session_capture_update(ui)
	app_audio_frame(ui)
	servers_frame(ui)
	// Before the tray, so it shows what a hotkey just did, and before
	// giving up for a hidden window, since they work without one.
	hotkeys_frame(ui)
	tray_update(ui)
	activity_step(ui)
	if ui.hidden {
		ui.meter_shown = false
		return true // no window to draw in
	}
	if !frame_due(ui) {
		return true
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
	left, right, height := titlebar_area(ui.window)
	ui.titlebar_left = i32(left * m.input_scale)
	ui.titlebar_right = i32(right * m.input_scale)
	ui.titlebar_height = i32(height * m.input_scale)
	// Whatever asked for this frame has it; the layout asks again for
	// what still needs more (see frame_due).
	ui.redraw_frames = max(ui.redraw_frames - 1, 0)
	ui.redraw_at = {}
	ui.log_drawn = -1
	// microui turns a press into focus for whatever `hover_id` names,
	// without re-checking the pointer, and only a control itself clears
	// its hover. If a hovered control vanishes (a screen change, a
	// relabeled button), the stale id could fire on a click anywhere
	// once the id reappears. Recomputing hover on every frame without a
	// press keeps it tied to what's actually under the pointer.
	if ui.ctx.mouse_pressed_bits == {} && ui.ctx.mouse_down_bits == {} {
		ui.ctx.hover_id = 0
	}
	ui_images_frame(ui)
	clear(&ui.text_boxes)
	// The chat's text size, for measuring this frame and drawing it.
	render.set_chat_zoom(&ui.renderer, settings.chat_scale_factor(&ui.settings))
	activity_input(ui)
	voice_elsewhere_update(ui)
	theme_update(ui) // the palette for this frame (theme.odin)
	mu.begin(&ui.ctx)
	ui.meter_shown = false // until gate_settings draws it again
	layout(ui, i32(m.logical_w), i32(m.logical_h))
	mu.end(&ui.ctx)
	clock_redraws(ui)
	settle(ui)
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
	render.render(&ui.renderer, &ui.ctx, m.fb_w, m.fb_h, m.scale, theme.background)
	render.gpu_present(&ui.renderer.gpu)
}

/*
Drawing a frame lays out the whole UI, which costs the same whether
anything has changed or not, so the loop only draws one when something
asks for it:

- input, and the window changing size or needing its contents again
  (ui_redraw, from GLFW's callbacks);
- another thread changing something that's shown - the network side
  through the View (conn.view_write), pictures decoded, a dialog or
  paste done (ui_wake);
- the clock: what fades, counts or comes down after a while asks for a
  frame by when it next changes, every frame it's on screen
  (ui_redraw_at).

And a frame whose draw commands differ from the last one's is followed
by another (settle): much of the layout only catches up a frame later
(scrolling to the end, a focus moved, a menu opened by a click), and a
frame that changed nothing is the sign that's done.
*/

// After input, at least this many frames: microui answers some of it
// (a click) in the frame after the one that saw it.
@(private = "file")
SETTLE_FRAMES :: 2

// How often what moves smoothly (a fade, the level meter) is redrawn.
ANIMATION_FRAME :: time.Second / 30

// Set by ui_wake, from any thread.
@(private = "file")
g_wake: bool

/*
ui_wake asks for a frame from any thread, for a change that no input
says has happened: from the network side (View.wake), and threads done
with their work. It wakes the loop, if it's waiting.
*/
ui_wake :: proc "c" () {
	if !intrinsics.atomic_exchange(&g_wake, true) {
		glfw.PostEmptyEvent()
	}
}

// ui_redraw asks for frames now, from the UI's own thread.
ui_redraw :: proc "contextless" (ui: ^UI) {
	ui.redraw_frames = max(ui.redraw_frames, SETTLE_FRAMES)
}

// ui_redraw_at asks for a frame by `at`, for what changes by the clock
// alone. The layout asks again every frame that still needs it.
ui_redraw_at :: proc(ui: ^UI, at: time.Tick) {
	if ui.redraw_at == {} || time.tick_diff(at, ui.redraw_at) > 0 {
		ui.redraw_at = at
	}
}

ui_redraw_in :: proc(ui: ^UI, after: time.Duration) {
	ui_redraw_at(ui, time.tick_add(time.tick_now(), max(after, 0)))
}

// frame_due says whether the loop should draw a frame this turn.
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
	// A new size or scale; no callback for it is needed this way.
	if window_metrics(ui.window, settings.ui_scale_factor(&ui.settings)) != ui.metrics {
		return true
	}
	// Lines are logged from everywhere, far too often to wake for each
	// one, so it's only while they're on screen that they're looked for.
	if ui.log_drawn >= 0 && ui.opts.logs != nil {
		sync.guard(&ui.opts.logs.mutex)
		return ui.opts.logs.total != ui.log_drawn
	}
	return false
}

// clock_redraws asks for frames for what changes by the clock and is
// shown in too many places to ask from each: who is speaking and who is
// typing, which stop by themselves, the network side's notices, which
// come down after a while, and times shown to the minute.
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
	// Message times, "Today", "last seen 5 minutes ago": all of them
	// change on the minute.
	MINUTE :: i64(time.Minute)
	into := time.time_to_unix_nano(time.now()) % MINUTE
	ui_redraw_in(ui, time.Duration(MINUTE - into))
}

// settle asks for another frame when this one's draw commands differ
// from the last one's.
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

// ui_shutdown takes everything down in the order it went up.
ui_shutdown :: proc(ui: ^UI) {
	disconnect_all(ui)
	delete(ui.sessions)
	hotkeys_stop(ui)
	tray_hide(ui)
	monitor_stop(ui)
	app_sound_stop(ui)
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
	// Whatever the paste thread is doing, it uses the clipboard, so it
	// has to be done before that.
	paste_wait(ui)
	file_pick_wait(ui)
	// What the UI kept of each server went with its session
	// (disconnect_all).
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
	when !platform.WEB {
		glfw.SetWindowRefreshCallback(ui.window, refresh_callback)
	}
	glfw.SetCursorPosCallback(ui.window, cursor_pos_callback)
	glfw.SetMouseButtonCallback(ui.window, mouse_button_callback)
	glfw.SetScrollCallback(ui.window, scroll_callback)
	glfw.SetKeyCallback(ui.window, key_callback)
	glfw.SetCharCallback(ui.window, char_callback)
	when !platform.WEB {
		glfw.SetDropCallback(ui.window, drop_callback)
	}
	// The cursor outlives the window, but which one the window shows
	// doesn't (see set_cursor).
	ui.cursor_shown = .Arrow
	ui.metrics = {}
	ui_redraw(ui)
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
		// The framebuffer's whole pixels make the ratio wobble as the
		// window is resized (1.5, then 1.4995), and everything snapped
		// to physical pixels would shuffle by one, and the fonts be
		// rasterized again, at every step. Scales are whole 120ths
		// (Wayland's fractional scaling), which the wobble never
		// reaches.
		m.scale = math.round(ratio * 120) / 120
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

/*
connect_joined connects to every joined server at start, in the rail's
order, and shows the first; or, with a server given when the client was
started, joins that one (if it isn't joined yet) and shows it, looking
at the channel given with it.
*/
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
	for r in ui.settings.joined_servers {
		this := r.address == first
		connect_to(ui, r.address, r.password, ui.opts.channel if this else "", show = this)
	}
}

/*
connect connects again to the server on the connect screen: a server on
the rail that isn't connected, perhaps with another password now. The
connection takes the old one's place.
*/
connect :: proc(ui: ^UI) {
	server := conn.with_default_port(string(ui.server_buf[:ui.server_len]))
	if server == "" {
		return
	}
	// Show the port that was assumed; it's what gets saved, too.
	ui.server_len = copy(ui.server_buf[:], server)
	// Taken as typed: spaces may well be part of a password.
	password := string(ui.password_buf[:ui.password_len])
	settings.join_server(&ui.settings, server, password)
	save_settings(ui)
	connect_to(ui, server, password)
}

/*
connect_to connects to a server: a new session at the end of the rail,
or, for a server that has one already (failed, say, or with a key just
trusted), a new one in its place, which goes on with what the UI had of
it. With `show`, it's shown.
*/
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
	// The per-user volumes go once the server's key says which are
	// this server's (apply_gains).
	if ns == ui.session {
		ui.gains_for = {}
	} else {
		ns.stash.gains_for = {}
	}
	net_start(ns)
	return ns
}

// session_new makes a session for `server`, ready to start, which joins
// `channel` if there is one.
session_new :: proc(ui: ^UI, server, password: string, channel := "") -> ^Net_Session {
	ns := new(Net_Session)
	ns.key_path = strings.clone(ui.opts.key_path)
	ns.server = strings.clone(server)
	ns.password = strings.clone(password)
	ns.known_servers = strings.clone(ui.opts.known_servers)
	ns.channel = strings.clone(channel)
	// Without one asked for, the channel that was on screen the last
	// time is looked at again (and only looked at).
	ns.look_at = strings.clone(settings.joined_channel(&ui.settings, server))
	ns.slot = session_slot(ui)
	// Its login form, should it need one, starts with the account last
	// logged in to anywhere.
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
	return ns
}

/*
session_slot is the first pair of WebSocket slots no session has, for a
web build (conn/transport_web.odin): 0 and 1 for the first, 2 and 3 for
the next. A desktop build has no use for it.
*/
@(private = "file")
session_slot :: proc(ui: ^UI) -> i32 {
	for slot := i32(0);; slot += 2 {
		taken := false
		for other in ui.sessions {
			taken ||= other.slot == slot
		}
		if !taken {
			return slot
		}
	}
}

/*
disconnect leaves a server: its session ends, it's no longer joined,
and if it was the one shown, the one beside it in the rail is. One being
joined from the + dialog is given up instead. Between frames.
*/
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
	in_voice: bool
	{
		sync.guard(&ns.view.mutex)
		in_voice = ns.view.my_room != 0 || ns.view.voice_pending
	}
	if in_voice {
		// What was shared there has nobody to go to any more.
		conn.video_share_stop()
		app_audio_stop(ui)
	}
	session_remove(ui, ns)
	session_free(ui, ns)
}

/*
session_remove takes a session off the rail, with what the UI kept of
it; if it was the one shown, the one after it is shown, or the one
before, or none.
*/
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
	// Not one being joined, which isn't on the rail.
	next: ^Net_Session
	for i := min(index, len(ui.sessions) - 1); i >= 0; i -= 1 {
		if !ui.sessions[i].joining {
			next = ui.sessions[i]
			break
		}
	}
	show_session(ui, next)
}

// session_free stops a session that's off the rail and frees it.
session_free :: proc(ui: ^UI, ns: ^Net_Session) {
	app_audio_session_gone(ui, ns)
	// Devices first, so nothing touches the rings once the voice goes away.
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

// disconnect_all ends every session, at once.
disconnect_all :: proc(ui: ^UI) {
	for len(ui.sessions) > 0 {
		ns := ui.sessions[len(ui.sessions) - 1]
		session_remove(ui, ns)
		session_free(ui, ns)
	}
}

// set_muted plays the muted/unmuted sound, unless it's part of a
// deafen (`feedback` false), which plays its own.
set_muted :: proc(ui: ^UI, muted: bool, feedback := true) {
	if muted == ui.muted {
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
	for ns in ui.sessions {
		conn.push_command(
			&ns.client.commands,
			conn.Deafen_Command{deafened = deafened, feedback = ns == sound_session(ui)},
		)
	}
}

// reopen_audio switches the running connections to the devices now
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
			// Not wanted is left closed (session_capture_update).
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

/*
session_capture_update runs every frame, before the layout and with no
View locked: it notes which session is in voice (UI.voice_at; there's
one at most), and keeps a connection's microphone open only while it's
wanted, which is while it's in a voice room (a channel's voice or a
call) or on its way into one, and for the one shown, or in voice, while
the settings page tests it (mic_test_wanted; its meter and listen back
come from the connection). Joining a server alone doesn't open it.
*/
@(private = "file")
session_capture_update :: proc(ui: ^UI) {
	ui.voice_at = nil
	for ns in ui.sessions {
		if in_voice(ns) {
			ui.voice_at = ns
			break
		}
	}
	// The page's screen, if it's being shared, goes to the voice too.
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
	// The server rail down the left (ui_servers.odin), and one window
	// that always fills the rest of the OS window.
	rail := rail_width(ui)
	server_rail(ui, h)
	rail_menu(ui)
	if cnt := mu.get_container(ctx, "yap"); cnt != nil {
		cnt.rect = {rail, 0, w - rail, h}
		// Always under the windows that float over it (pins, threads,
		// the picker...): microui raises a clicked window unless its
		// zindex is below 0, and sorts the lowest first.
		cnt.zindex = -1
	}
	if mu.begin_window(ctx, "yap", {rail, 0, w - rail, h}, {.NO_TITLE, .NO_RESIZE, .NO_CLOSE}) {
		titlebar_buttons(ui, w)
		main_window(ui)
		mu.end_window(ctx)
	}
	// An enlarged image floats above it all (ui_images.odin).
	image_viewer(ui, w, h)
	join_dialog(ui, w, h)
	pins_window(ui, w, h)
	thread_windows(ui, w, h)
	profile_windows(ui, w, h)
	completion_window(ui)
	picker_window(ui, w, h)
	channels_window(ui, w, h)
	forward_window(ui, w, h)
	search_window(ui, w, h)
	// After every timeline, the thread windows' too.
	message_bar(ui)
	// Last, and in windows of their own, so they're over the popups too.
	chip_preview_popup(ui, w, h)
	icon_hint(ui, w, h)
}

@(private = "file")
main_window :: proc(ui: ^UI) {
	// Behind the + dialog while it connects (ui_join.odin), and with
	// no server at all, the start screen.
	if ui.session != nil && ui.session.joining {
		start_screen(ui)
		return
	}
	if ui.page == .Settings {
		settings_page(ui)
		return
	}
	if ui.session == nil {
		start_screen(ui)
		return
	}

	// Every server's part of the inbox, each View locked in turn, before
	// the shown one's is for the frame.
	ui.inbox = inbox_list(ui) if ui.page == .Buddies else nil
	v := ui.view
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

@(private = "file")
connect_screen :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := ui.view

	title_row(ui, {70, -(ICON_BUTTON + 8), ICON_BUTTON})
	mu.label(ctx, "Server")
	if .SUBMIT in text_box(ui, ui.server_buf[:], &ui.server_len) {
		ui.action = .Connect
	}
	if .SUBMIT in icon_button(ui, "send", .Send, "Connect") {
		ui.action = .Connect
	}

	mu.layout_row(ctx, {70, 200})
	mu.label(ctx, "Password")
	if .SUBMIT in password_box(ui, ui.password_buf[:], &ui.password_len) {
		ui.action = .Connect
	}

	if v.status == .Failed && v.error != "" {
		mu.layout_row(ctx, {-1})
		with_text_color(ctx, theme.error, v.error, label_proc)
	}
	if v.status == .Failed && v.key_change.changed {
		key_change_panel(ui)
	}
	// A server on the rail that isn't connected: connected again above,
	// or left here.
	mu.layout_row(ctx, {70, 200})
	mu.label(ctx, "")
	if .SUBMIT in mu.button(ctx, "Leave this server") {
		ui.action = .Disconnect
	}

}

/*
start_screen is what the main window shows with no server to show: none
joined yet, which it says, pointing at the + that joins one; or behind
the + dialog while it connects.
*/
@(private = "file")
start_screen :: proc(ui: ^UI) {
	ctx := &ui.ctx
	joining := ui.session != nil && ui.session.joining
	title_row(ui, {-1})
	switch {
	case joining:
		mu.label(ctx, "Joining a server...")
	case len(ui.sessions) == 0:
		mu.label(ctx, "Not on any server yet")
	case:
		mu.label(ctx, "No server shown")
	}
	if !joining {
		mu.layout_row(ctx, {-1})
		with_text_color(
			ctx,
			theme.dim,
			"Join a server with the + on the left: its address, and its password if it has one.",
			label_proc,
		)
		mu.layout_row(ctx, {160})
		if .SUBMIT in mu.button(ctx, "Join a server") {
			join_open(ui)
		}
	}
}

// Narrower than this (a phone, a window squeezed aside), the channels
// go above the chat instead of beside it.
NARROW_LAYOUT :: 600

@(private = "file")
session_screen :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := ui.view
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
	channel_menu(ui)
	message_menu(ui)
	app_audio_menu(ui)
}

/*
title_row is mu.layout_row for a screen's first row. That row shares the
top of the window with the window's buttons (see ui_titlebar_darwin.odin,
ui_titlebar_windows.odin), so it keeps clear of them: on macOS they're on
the left, and it starts to the right of them; on Windows they're on the
right, and the widths counted from the right-hand edge are counted from
them instead.
*/
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

/*
session_header is the row along the top while connected: the server
shown, or the inbox. The session screen and the inbox share it. How the
connection is doing and the settings are at the bottom of the rail
(rail_bottom); mute, deafen and what's shared are in the voice panel
(ui_voice_panel.odin).
*/
session_header :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := ui.view
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
		ui.log_drawn = total // for frame_due to look out for more

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

// The emoji a hint is about: one of the server's (its index), or else a
// character, as a string; both empty for none.
Hint_Emoji :: struct {
	custom:  Maybe(int),
	unicode: string, // temp
}

// hint_emoji_of has the hint show `emoji` large: a reaction's or
// message's, ":name:" for the server's, else the characters. Call with
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
	render.draw_border(ctx, r, ctx.style.colors[.BORDER])
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
	ui_redraw(g_ui)
}

/*
refresh_callback is the window needing its contents again: uncovered,
say, where nothing keeps them. That's a frame drawn at the next turn
round the loop - except on Windows, where it draws one right away, since
it also comes while the window is being resized: dragging its edge runs
a loop of the system's own until the mouse is let go, and
glfw.WaitEventsTimeout doesn't come back before then, so without this
the window would stand still for as long as the drag lasts.
*/
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

@(private = "file")
cursor_pos_callback :: proc "c" (window: glfw.WindowHandle, x, y: f64) {
	context = platform.callback_context()
	ui_redraw(g_ui)
	mu.input_mouse_move(&g_ui.ctx, to_logical(x), to_logical(y))
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
	ui_redraw(g_ui)
	mu.input_scroll(&g_ui.ctx, i32(-x * 30), i32(-y * 30))
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
		// Shift+Enter starts a line in a text area. The key's own
		// modifiers say so, even when Shift is let go again before the
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

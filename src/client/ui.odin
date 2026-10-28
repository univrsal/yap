package client

import "base:intrinsics"
import "client:audio"
import "client:conn"
import "client:render"
import "client:settings"
import "client:video"
import glfw "client:wglfw"
import "common:proto"
import log "common:wlog"
import "core:fmt"
import "core:math"
import "core:sync"
import "core:time"
import "core:time/datetime"
import mu "vendor:microui"


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
	client:          ^conn.Server_Conn,
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
	Back_Tab, // Shift+Tab
	Next_Area, // F6: the keyboard focus to the next area (ui_nav.odin)
	Prev_Area, // Shift+F6
	Escape,
	// Space, which presses the control with the keyboard focus (see ui_nav.odin).
	// It still types a space in a text box.
	Activate,
	// Ctrl+Space or Ctrl+K (Cmd+K on macOS): the command palette.
	Palette,
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
	server:              Text_Field(256),
	password:            Text_Field(proto.MAX_PASSWORD_SIZE),
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
	date_style:          Date_Style, // how dates and times are written (chat_time)
	activity:            UI_Activity, // whether whoever uses this is idle (ui_activity.odin)
	video:               UI_Video, // screen sharing (ui_video.odin)
	camera:              UI_Camera, // our camera and calls' video (ui_camera.odin)
	app_audio:           UI_App_Audio, // sharing an application's audio (ui_app_audio_native.odin)
	muted:               bool,
	deafened:            bool,
	// The mute state from before deafening turned it on, so that undeafening
	// restores it instead of always unmuting (see set_deafened).
	muted_before_deafen: bool,

	// The byte range of the name in the message header being drawn, which is
	// bold, and whose it is, so that a click on the name opens their menu (0:
	// none, as for our own).
	header_sender:       proto.Account_Id,
	header_name:         [2]int,
	// The byte range of the time in the header, which is dimmed ({} if it
	// has none, see time_column).
	header_time:         [2]int,
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
	// The keyboard focus (ui_nav.odin), and the command palette (ui_palette.odin).
	nav:                 UI_Nav,
	palette:             UI_Palette,
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
	image_cache_dir:     Text_Field(512),
	// Memory usage: the settings page and the line in the log
	// (see ui_memory.odin).
	memory:              UI_Memory,
	// Keys that microui has no name for, pressed since the last frame.
	keys:                bit_set[Extra_Key],
	// Presses of a key in KEYS_QUEUED that came while it was already in `keys`:
	// each goes into `keys` in a frame of its own (see key_press).
	keys_queued:         [Extra_Key]u8,
	// Ctrl+Space opened the palette: the space that may follow it as text
	// isn't typed (see char_callback).
	drop_space:          bool,
	// A message was picked to be edited, or a mention was completed: its composer
	// takes the focus, with the cursor at `focus_composer_at` (-1: at the
	// end).
	focus_composer:      bool,
	focus_composer_at:   int,
	focus_thread:        int, // which composer: Composer.thread
	// People's pictures (ui_avatars.odin).
	avatars:             UI_Avatars,
	// Whether this frame is laid out narrow, as layout works out before drawing
	// anything. Then the list and the conversation take turns, an open thread
	// takes the place of the conversation instead of floating over it (see
	// ui_threads.odin), and who we are and mute and deafen are in the rail
	// instead of the voice panel (see rail_bottom).
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
	// With the title bar merged, where the line under the first row (the
	// title row) is in this frame, or 0 where there is none. Above it the
	// window can be dragged (see mouse_button_callback).
	title_line:          i32,
	// Where the lighter line under a conversation's header is in this frame
	// (header_line_below), or 0 where there is none.
	conv_line:           i32,
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
g_logger: log.Logger

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

// Set by ui_wake, which can be called from any thread.
g_wake: bool

CURSOR_SHAPES := [Cursor]i32 {
	.Arrow       = 0,
	.Hand        = glfw.HAND_CURSOR,
	.IBeam       = glfw.IBEAM_CURSOR,
	.Resize_EW   = glfw.RESIZE_EW_CURSOR,
	.Resize_NS   = glfw.RESIZE_NS_CURSOR,
	.Resize_NWSE = glfw.RESIZE_NWSE_CURSOR,
	.Resize_NESW = glfw.RESIZE_NESW_CURSOR,
}

save_settings :: proc(ui: ^UI) {
	settings.settings_save(ui.opts.settings_path, ui.settings)
	ui.settings_dirty = false
	ui.settings_saved = time.tick_now()
}

layout :: proc(ui: ^UI, w, h: i32) {
	ctx := &ui.ctx
	// The server rail down the left (see ui_servers.odin), and one window
	// that always fills the rest of the OS window.
	rail := rail_width(ui)
	ui.narrow = w - rail < NARROW_LAYOUT
	server_rail(ui, h)
	rail_menu(ui)
	if cnt := mu.get_container(ctx, "yap"); cnt != nil {
		cnt.rect = {rail, 0, w - rail, h}
		// Always under the windows that float over it (pins, threads,
		// the picker...). microui raises a clicked window unless its
		// zindex is below 0, and sorts the lowest first.
		cnt.zindex = -1
	}
	// Without a frame: it is in the sidebars' color, and the content's surface
	// is painted over that (content_surface).
	opts := mu.Options{.NO_TITLE, .NO_FRAME, .NO_RESIZE, .NO_CLOSE}
	if mu.begin_window(ctx, "yap", {rail, 0, w - rail, h}, opts) {
		mu.draw_rect(ctx, mu.get_current_container(ctx).rect, theme.sidebar)
		titlebar_buttons(ui, w)
		ui.title_line, ui.conv_line = 0, 0
		main_window(ui)
		// Under the title row, from the rail to the window's right edge.
		if ui.title_line > 0 {
			mu.draw_rect(ctx, {rail, ui.title_line, w - rail, 1}, theme.divider)
		}
		mu.end_window(ctx)
	}
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
	palette_window(ui, w, h)
	// After every timeline, the thread windows' timelines too.
	message_bar(ui)
	dropdown_popup(ui, w, h)
	// Last, and in windows of their own, so they are over the popups too.
	chip_preview_popup(ui, w, h)
	icon_hint(ui, w, h)
	drop_hint(ui)
	voice_drag_frame(ui)
}

// content_surface paints the content's surface (theme.content) under the next
// layout cell: a conversation, a settings page, beside the sidebars. It reaches
// halfway into the gaps to the cells around it, and to the window's edges where
// the cell is next to one. It returns the area it painted, for the lines drawn
// along it once the cell has been laid out (conversation_lines).
content_surface :: proc(ui: ^UI) -> mu.Rect {
	ctx := &ui.ctx
	cell := mu.layout_next(ctx)
	mu.layout_set_next(ctx, cell, false)
	win := mu.get_current_container(ctx).rect
	near := ctx.style.padding + 1
	half := ctx.style.spacing / 2
	left := win.x if cell.x - win.x <= near else cell.x - half
	top := win.y if cell.y - win.y <= near else cell.y - half
	right := cell.x + cell.w
	right = win.x + win.w if win.x + win.w - right <= near else right + half
	bottom := cell.y + cell.h
	bottom = win.y + win.h if win.y + win.h - bottom <= near else bottom + half
	r := mu.Rect{left, top, right - left, bottom - top}
	mu.draw_rect(ctx, r, theme.content)
	return r
}

// keep_in_window keeps the current window, one that floats over the main window
// and can be dragged by its title bar, inside the OS window and below the
// strip along its top (the merged title bar and its line, UI.title_line), so
// that it can't cover the window's own buttons or be lost off an edge. microui
// moves a dragged window after drawing it, so this takes effect before it is
// drawn again. Call right after mu.begin_window.
keep_in_window :: proc(ui: ^UI) {
	cnt := mu.get_current_container(&ui.ctx)
	w, h := i32(ui.metrics.logical_w), i32(ui.metrics.logical_h)
	top := ui.titlebar_height
	if ui.title_line > 0 {
		top = max(top, ui.title_line + 1)
	}
	r := &cnt.rect
	r.w, r.h = min(r.w, max(w, 96)), min(r.h, max(h - top, 64))
	r.x = clamp(r.x, 0, max(w - r.w, 0))
	r.y = clamp(r.y, top, max(h - r.h, top))
}

// How much room a conversation's header has above and below its row, and in
// from the left. The search box beside it has the same (search_box).
CONV_HEADER_PAD :: 6

// header_pad is the room above or below a conversation's header: an empty row.
header_pad :: proc(ui: ^UI) {
	mu.layout_row(&ui.ctx, {-1}, CONV_HEADER_PAD)
	mu.layout_next(&ui.ctx)
}

// header_line_below ends a conversation's header with the room below it, and
// notes that it has a lighter line under that (conversation_lines), halfway
// into the gap to what follows.
header_line_below :: proc(ui: ^UI) {
	header_pad(ui)
	layout := mu.get_layout(&ui.ctx)
	ui.conv_line = layout.body.y + layout.next_row - ui.ctx.style.spacing / 2
}

// header_surface carries a conversation's surface `r` (content_surface) on
// across the members pinned down the side, along its header, where the search
// box is (search_box). Call after the conversation, before the members.
header_surface :: proc(ui: ^UI, r: mu.Rect) {
	if ui.conv_line <= r.y {
		return
	}
	ctx := &ui.ctx
	win := mu.get_current_container(ctx).rect
	x := r.x + r.w
	mu.draw_rect(ctx, {x, r.y, win.x + win.w - x, ui.conv_line - r.y}, theme.content)
}

// conversation_lines draws the lines along a conversation's surface `r`
// (content_surface): the lighter one under its header, from the surface's left
// edge to the window's right one (across the members' column), and with
// `divider`, the one down its right-hand edge between it and the members, from
// there to the bottom.
conversation_lines :: proc(ui: ^UI, r: mu.Rect, divider: bool) {
	ctx := &ui.ctx
	win := mu.get_current_container(ctx).rect
	top := r.y
	if ui.conv_line > 0 {
		top = ui.conv_line
		mu.draw_rect(ctx, {r.x, top, win.x + win.w - r.x, 1}, theme.divider_soft)
		top += 1
	}
	if divider {
		mu.draw_rect(ctx, {r.x + r.w, top, 1, r.y + r.h - top}, theme.divider)
	}
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
		error_note(ctx, v.error)
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
	if !key_change && .SUBMIT in button(ctx, "Reconnect") {
		ui.action = .Reconnect
	}
	if .SUBMIT in button(ctx, "Leave this server") {
		ui.action = .Disconnect
	}
}

// In a window narrower than this (a phone, or a window squeezed to the side),
// the channels go above the chat instead of beside it.
NARROW_LAYOUT :: 600

// In a window at least this wide, the members are pinned down the right of the
// channel instead of being in a window from the header's button.
MEMBERS_PIN_LAYOUT :: 1100
MEMBERS_PANEL_WIDTH :: 240

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
	narrow := ui.narrow
	ui.profiles.members_pinned = body.w >= MEMBERS_PIN_LAYOUT

	screen_tab_follow(ui)
	camera_tab_follow(ui)
	back_from_dms(ui)
	if camera_fullscreen(ui) {
		camera_full_screen(ui)
		return
	}
	if v.watching != 0 && video.is_fullscreen() {
		fullscreen_screen(ui)
		return
	}

	// A narrow window has no header of its own, except where the window's
	// buttons are among the content and the chat's own header would run into them.
	if !narrow || titlebar_merged(ui) {
		session_header(ui)
	}

	// Side by side where there is room. In a narrow window the list and
	// the chat take turns (see ui_channels.odin), over the voice panel if it
	// has anything to show.
	if narrow {
		mu.layout_row(ctx, {-1}, -(voice_panel_height(ui) + 1))
		if ui.channels.show_list {
			channel_list(ui)
		} else {
			surface := content_surface(ui)
			side_panel(ui, narrow)
			conversation_lines(ui, surface, false)
		}
		voice_panel(ui)
	} else {
		if ui.profiles.members_pinned {
			// -1 would leave the last cell no room, so the chat's cell
			// keeps the members' width (and the gap before it) free.
			mu.layout_row(
				ctx,
				{280, -(MEMBERS_PANEL_WIDTH + ctx.style.spacing + 1), MEMBERS_PANEL_WIDTH},
				-1,
			)
		} else {
			mu.layout_row(ctx, {280, -1}, -1)
		}
		channel_list(ui)
		surface := content_surface(ui)
		side_panel(ui, narrow)
		if ui.profiles.members_pinned {
			header_surface(ui, surface)
			members_panel(ui)
		}
		conversation_lines(ui, surface, ui.profiles.members_pinned)
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
//
// With the title bar merged, a line goes under the row (see UI.title_line).
title_row :: proc(ui: ^UI, widths: []i32, height: i32 = 0) {
	layout := mu.get_layout(&ui.ctx)
	if titlebar_merged(ui) && ui.title_line == 0 {
		// Halfway into the gap under the row, where the content's surface
		// starts (content_surface). A row of height 0 is a control's height.
		style := ui.ctx.style
		h := height if height > 0 else style.size.y + 2 * style.padding
		ui.title_line = layout.body.y + layout.next_row + h + style.spacing - style.spacing / 2
	}
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
		// A line too long for the panel is wrapped, as the chat wraps it, and
		// goes on below, indented as far as the time at its start (but no
		// more than a third of the width, in a narrow window).
		width := cnt.body.w - ctx.style.padding * 4
		indent := min(ctx.text_width(font, "00:00:00.000 "), width / 3)
		// Lines are numbered by the running total, so a selection stays
		// on the same lines as new lines come in (see ui_select.odin).
		first := i64(logs.total - len(logs.lines))
		for line, i in logs.lines {
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
			item := first + i64(i)
			select_item(ui, item, text)
			// One row for each part of the line, the whole of it if it fits
			// (which is measured first, as most lines do).
			start, x := 0, i32(0)
			for {
				end, next := len(text), len(text)
				if ctx.text_width(font, text[start:]) > width - x {
					e, n := wrap_line(ctx, font, text[start:], width - x)
					end, next = start + e, start + n
				}
				mu.layout_row(ctx, {-1}, render.LINE_HEIGHT)
				// Where mu.label would put it.
				r := mu.layout_next(ctx)
				pos := mu.Vec2 {
					r.x + ctx.style.padding + x,
					r.y + (r.h - ctx.text_height(font)) / 2,
				}
				select_line(ui, item, text, start, end, pos, font = font)
				mu.draw_text(ctx, font, text[start:end], pos, color)
				if next >= len(text) {
					break
				}
				start, x = next, indent
			}
		}
	}
	select_end(ui)
	mu.end_panel(ctx)
}

package ui

import "widgets"
import "core"
import "base:intrinsics"
import "client:audio"
import "client:conn"
import "client:render"
import "client:script"
import "client:settings"
import glfw "client:wglfw"
import "common:proto"
import log "common:wlog"
import "core:time"
import "core:time/datetime"


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
	// the UI keeps of this server while another one is shown (see ui/servers.odin).
	view:            conn.View,
	stash:           Server_UI,
	// Which WebSockets belong to this session in a web build: slot and
	// slot + 1 (see conn/transport_web.odin).
	slot:            i32,
	// Whether the server was last told that the user is idle, and that the
	// page is out of sight (see ui/activity.odin).
	idle_told:       bool,
	hidden_told:     bool,
	// Web Push (see ui/push_web.odin): whether the browser has been asked
	// about its subscription for this server's key, and the key it was asked for.
	push_checked:    bool,
	push_key:        [proto.PUSH_KEY_SIZE]u8,
	// Set while the server is being joined from the + page (see ui/join.odin). It
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

Page :: enum {
	Main,
	Settings,
	Buddies, // only while connected (ui/buddies.odin)
}

@(private = "file")
Action :: enum {
	None,
	Start, // connect to every joined server, on the first frame
	Disconnect,
	Reconnect, // the connect screen's "Reconnect"
	Trust_Key, // the connect screen's "Trust the new key" (ui/known_servers.odin)
}

UI :: struct {
	window:              glfw.WindowHandle,
	// What the widgets need (ui/core): the microui context, the keys, the text
	// selection, the focus ring, hints and the frame requests. Embedded, so that
	// ui.ctx and the like keep working, and a ^UI is a ^core.Env where one is
	// wanted.
	using env: core.Env,
	renderer:            render.Renderer,
	opts:                UI_Options,
	my_key:              [proto.KEY_SIZE]u8,
	server:              widgets.Text_Field(256),
	password:            widgets.Text_Field(proto.MAX_PASSWORD_SIZE),
	// The height of the connect screen's card in the last frame (see card_end).
	connect_card_h:      i32,
	no_view:             conn.View,
	session:             ^Net_Session,
	// Every connection, in the rail's order (see ui/servers.odin). `session`
	// is one of them, or nil if there are none. The one being joined from the +
	// dialog is included here too, although it is not on the rail (see ui/join.odin).
	sessions:            [dynamic]^Net_Session,
	join:                UI_Join,
	// In a web build, the joined server that this page's relay reaches: the
	// only one with a plain address that is connected (see relay_blocked).
	// Owned; "" if none has been chosen.
	relay_server:        string,
	rail:                UI_Rail, // its menu, and dragging (ui/servers.odin)
	// Messages unread on every server, in channels and DMs that aren't
	// muted. Used for the window's title and the tray (see servers_frame).
	unread:              int,
	// Mentions unread on every server, including muted channels and DMs. The
	// title and the tray show this before `unread`.
	mentions:            int,
	// DMs unread on every server, for the inbox's icon on the rail.
	dm_unread:           int,
	// The inbox (see ui/buddies.odin): everyone in it, across all servers, as of
	// this frame, and the DM to open once the rail has switched to
	// that person's server (see switch_now).
	inbox:               []Buddy_Entry,
	inbox_open:          proto.Account_Id,
	inbox_open_group:    proto.Conv_Id,
	// Voice, or a ringing call, in a server that isn't shown, as of this
	// frame (see ui/voice_panel.odin).
	voice_other:         Voice_Elsewhere,
	// What the UI keeps of the shown server. Each session keeps its own copy
	// while it isn't shown (see Net_Session.stash and ui/servers.odin).
	using srv:           Server_UI,
	// The session that is in voice, as of this frame (see session_capture_update).
	voice_at:            ^Net_Session,
	// The rail was clicked: the session to show after the frame. See
	// switch_now.
	switch_to:           ^Net_Session,
	switching:           bool,
	switch_stay:         bool, // stay on the page we're on (see switch_now)
	// Connecting and disconnecting wait on the network thread, which may be
	// waiting on the View lock, so they happen after the layout, not during it.
	action:              Action,
	// What the window's title says (owned; see servers_frame).
	window_title:        string,
	settings_tab:        Settings_Tab, // which the settings page shows (ui/settings.odin)
	// The category selected in each of the settings tabs.
	settings_client:     Client_Category,
	settings_server:     Server_Category,
	// In a narrow window: the list of categories is showing instead of the
	// selected one (see settings_page).
	settings_list:       bool,
	// Which palette is in use, and what the desktop reported (see theme.odin).
	theme_state:         UI_Theme,
	// For the chat's local timestamps, for every server. nil means UTC
	// (see ui/chat_time_native.odin).
	chat_tz:             ^datetime.TZ_Region,
	date_style:          Date_Style, // how dates and times are written (chat_time)
	activity:            UI_Activity, // whether whoever uses this is idle (ui/activity.odin)
	video:               UI_Video, // screen sharing (ui/video.odin)
	camera:              UI_Camera, // our camera and calls' video (ui/camera.odin)
	app_audio:           UI_App_Audio, // sharing an application's audio (ui/app_audio_native.odin)
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
	// header leaves room for it, see ui/bots.odin). 0 for none.
	header_bot:          int,
	// The settings page's microphone monitor and level meter (ui/gate.odin).
	monitor:             Mic_Monitor,
	listen_back:         bool,
	// The welcome and goodbye sounds (ui/app_sounds.odin).
	app_sound:           App_Sound,
	// The Sounds page (ui/sounds.odin), and the open dropdown (ui/widgets/dropdown.odin).
	sounds:              Sounds_UI,
	palette:             UI_Palette,
	// Whether the voice gate section, with the meter, was on screen in the last
	// frame (see gate_settings). The microphone is only opened for it in that case.
	meter_shown:         bool,
	meter_level:         f32,
	meter_time:          time.Tick,
	// People's pictures and servers' emoji that are kept on disk between
	// sessions (see ui/image_cache.odin), and the settings page's box for
	// the folder.
	image_cache:         conn.Image_Cache,
	image_cache_dir:     widgets.Text_Field(512),
	// The scripts that are running, nil if there is nowhere to keep them
	// (see client/script).
	scripts:             ^script.Runtime,
	script_ui:           UI_Scripts, // the Scripts page (ui/script_settings.odin)
	// Memory usage: the settings page and the line in the log
	// (see ui/memory.odin).
	memory:              UI_Memory,
	// Ctrl+Space opened the palette: the space that may follow it as text
	// isn't typed (see char_callback).
	drop_space:          bool,
	// A message was picked to be edited, or a mention was completed: its composer
	// takes the focus, with the cursor at `focus_composer_at` (-1: at the
	// end).
	focus_composer:      bool,
	focus_composer_at:   int,
	focus_thread:        int, // which composer: Composer.thread
	// People's pictures (ui/avatars.odin).
	avatars:             UI_Avatars,
	// Whether this frame is laid out narrow, as layout works out before drawing
	// anything. Then the list and the conversation take turns, an open thread
	// takes the place of the conversation instead of floating over it (see
	// ui/threads.odin), and who we are and mute and deafen are in the rail
	// instead of the voice panel (see rail_bottom).
	narrow:              bool,
	// Whether controls are sized for a finger (see style_apply): in a narrow
	// window, or once a touch screen has been used (web, ui/touch_web.odin).
	compact:             bool,
	// The bar over the message under the pointer (see ui/message_bar.odin),
	// and whether this frame is a tap on a touch screen (see ui/touch_web.odin),
	// which shows the message's bar.
	msg_bar:             UI_Message_Bar,
	touch_tap:           bool,
	settings_saved:      time.Tick,
	page:                Page,
	known:               UI_Known_Servers, // saved server keys (ui/known_servers.odin)
	hotkeys:             UI_Hotkeys, // global hotkeys (ui/hotkeys_native.odin)
	install:             UI_Install, // installing for the user (ui/install_native.odin)
	// The UI scale slider's own value in percent, updated live while it is being
	// dragged. It is only copied into settings.ui_scale on release, because
	// applying it while dragging would resize the very slider being dragged
	// (see ui/settings.odin).
	ui_scale_draft:      f32,
	chat_scale_draft:    f32, // the same for the chat's text size
	audio:               audio.Audio,

	// The strip along the top where the window's buttons are drawn over
	// the UI, merged with the title bar, in logical pixels: where
	// the first row starts, how far in from the right it ends, and how
	// tall the strip is. Zero where the title bar belongs to the desktop (see
	// ui/titlebar.odin).
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
	text_focused:        bool,
	// The pointing hand shown over links and the I-beam shown over text that
	// can be selected. They are created on first use and freed by glfw.Terminate.
	cursors:             [Cursor]glfw.CursorHandle,
	cursor_shown:        Cursor,
	// The image paste that is being read, if any (see ui/paste.odin), and where the
	// next one goes.
	paste:               ^Paste_Job,
	paste_to:            Attach_Target,
	// The file dialog, while it's open (ui/files_native.odin).
	file_pick:           ^File_Pick_Job,
	// The paperclip was pressed: after the frame, the dialog opens to pick
	// files for `attach_to`'s next message (see ui/attachments.odin).
	attach_pick:         bool,
	attach_to:           Attach_Target,
	// Files dropped on the window since the last frame, to be attached
	// (see ui_files_*.odin). Owned.
	dropped:             [dynamic]string,
	// Files being dragged over the window (see drop_hint).
	drag:                Drag,
	// The picture chip under the pointer, which is shown over it
	// (see chip_preview_popup).
	chip_preview:        Chip_Preview,
	// Chat images: decoded pictures and their textures (ui/images.odin).
	images:              UI_Images,
	// The system tray icon, if it's switched on (ui/tray.odin).
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
	// The mouse wheel's scrolling not handed to microui yet, in pixels, and
	// when some was last handed over (see scroll_step).
	scroll_left:         [2]f32,
	scroll_at:           time.Tick,
	drawn_hash:          u64,
	log_drawn:           int,
}

// For GLFW's callbacks, which have no user data we can use cheaply, and for
// the page's touch input in a web build (see ui/touch_web.odin).
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

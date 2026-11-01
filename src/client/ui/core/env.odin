package core

import "client:ui/redraw"
import "client:conn"
import "client:settings"
import mu "vendor:microui"

// What the widgets of the UI, and the code that only draws what the view and the
// settings say, need and nothing else: a ^UI embeds this (as
// `using env`), so ui.ctx and the like still work there, and a ^UI can be
// passed where a ^Env is wanted. A procedure that takes a ^Env says that it
// needs none of the rest of the UI.
Env :: struct {
	ctx:                 mu.Context,
	// A frame is only drawn when there is something new to show (see
	// frame_due). This holds how many more frames to draw regardless, and when
	// the clock will next change something on screen (zero: nothing will).
	redraw:              redraw.Request,
	// Keys that microui has no name for, pressed since the last frame.
	keys:                bit_set[Extra_Key],
	// Presses of a key in KEYS_QUEUED that came while it was already in `keys`:
	// each goes into `keys` in a frame of its own (see key_press).
	keys_queued:         [Extra_Key]u8,
	// Text selected in the chat or the log (ui/select.odin).
	select:              Selection,
	// The keyboard focus (ui/core/nav.odin), and the command palette (ui/palette.odin).
	nav:                 Nav,
	dropdown:            Dropdown_State,
	// What the icon button under the pointer does, and where it is, for
	// the hint drawn under it (see icon_button and icon_hint).
	hint:                string,
	hint_of:             mu.Rect,
	// The emoji the hint is about, drawn large above it (icon_hint).
	hint_emoji:          Hint_Emoji,
	// Where this frame's text boxes are, and whether one has the focus,
	// for a phone's keyboard in a web build (see ui/widgets/text_box.odin).
	text_boxes:          [dynamic]Text_Box,
	// Each panel's and window's scrollbar (ui/core/scrollbar.odin).
	scrollbar_fades:     map[^mu.Container]Scrollbar_Fade,
	// Icon buttons are drawn flat, with a background only while the pointer
	// is on them (the composer's, inside its box, see composer_buttons).
	touched:             bool,
	flat_buttons:        bool,
	// A finger is scrolling, with the pointer under it: nothing is hovered.
	touch_scrolling:     bool,
	metrics:             Window_Metrics,
	// Logical pixels per window coordinate, for mouse input (see
	// window_metrics).
	input_scale:         f32,

	// What is shown: the view of the server being looked at, and the settings.
	// What the shown server's connection reports (its session's View), or
	// `no_view` when nothing is connected.
	view:                ^conn.View,
	settings:            settings.Settings,
	// Slider drags change the settings every frame, so save at most once a
	// second, and on exit.
	settings_dirty:      bool,
}

// The UI's Env, for the code that is handed only a mu.Context (nav_of). Set when
// the UI starts, and nil in a test that has no UI.
g_env: ^Env

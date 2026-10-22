package client

import "core:sync"
import "core:thread"
import "core:time"
import mu "vendor:microui"

import "client:platform"
import "client:settings"

// The UI's colors: a dark palette and a light one, and the setting that
// picks between them (settings.theme: "system", "dark" or "light"). Every
// color the UI draws with comes from `theme`, except microui's own
// (ctx.style.colors), which theme_apply sets from the same palette. An
// image's tint, the white on a colored disc and the tray (whose panel
// has colors of its own, see ui_tray.odin) are the same in both palettes.
//
// "system" follows the desktop's own choice (platform.prefers_dark), which is
// queried again every few seconds so a change there shows up here without a
// restart. Querying can mean running a program (busctl on Linux, defaults on
// macOS), so it is done on a thread of its own and the UI only reads the
// answer.

Palette :: struct {
	style:          [mu.Color_Type]mu.Color, // microui's own colors
	background:     mu.Color, // behind every window
	// Text: dimmed, highlighted, and the colors that show how something went.
	dim:            mu.Color,
	strong:         mu.Color,
	notice_ok:      mu.Color,
	warning:        mu.Color,
	error:          mu.Color,
	// The state icons: a voice coming through, something switched off.
	speaking:       mu.Color,
	off:            mu.Color,
	// Channels: the name of an unread channel, the channel being looked at, and
	// the unread count badges (whose text is badge_text, or mention for mentions).
	unread_text:    mu.Color,
	viewing:        mu.Color,
	badge_text:     mu.Color,
	unread_badge:   mu.Color,
	muted_badge:    mu.Color,
	mention_badge:  mu.Color,
	// Chat: names, links, mentions, quotes and code, and the lines across
	// the timeline.
	chat_name:      mu.Color,
	chat_own:       mu.Color,
	link:           mu.Color,
	link_hover:     mu.Color,
	mention:        mu.Color,
	mention_me_bg:  mu.Color,
	quote_bar:      mu.Color,
	code_block:     mu.Color,
	code_span:      mu.Color,
	reply_bar:      mu.Color,
	day_line:       mu.Color,
	new_line:       mu.Color,
	pinned:         mu.Color,
	hover_tint:     mu.Color, // over the message the hover bar belongs to
	selection:      mu.Color, // selected text
	highlight:      mu.Color, // a highlighted message (from a search or a message link)
	highlight_more: mu.Color,
	// The server rail: a server that is not connected, its text, and the marks
	// next to the selected server and the position a dragged server is dropped to.
	failed_disc:    mu.Color,
	failed_text:    mu.Color,
	mark:           mu.Color,
	mentions:       mu.Color,
	plus_disc:      mu.Color, // the + button that joins a server
	// Voice: the panel, and how a call is going.
	panel:          mu.Color,
	connected:      mu.Color,
	ringing:        mu.Color,
	// Grey parts: an unlit bar, a progress bar's track, the background
	// behind an image, dividers, a deleted account's disc, and the ring
	// around an activity dot.
	unlit:          mu.Color,
	track:          mu.Color,
	image_bg:       mu.Color,
	divider:        mu.Color,
	deleted_disc:   mu.Color,
	dot_ring:       mu.Color,
	// What is ready to be done (the composer's send button once there is a
	// message), the same when the pointer is on it, and the text and icons on it.
	accent:         mu.Color,
	accent_hover:   mu.Color,
	accent_text:    mu.Color,
	shadow:         mu.Color, // under windows that float (render.draw_shadow)
}

DARK_PALETTE :: Palette {
	style = {
		.TEXT = {230, 230, 230, 255},
		.SELECTION_BG = {90, 90, 90, 255},
		.BORDER = {25, 25, 25, 255},
		.WINDOW_BG = {50, 50, 50, 255},
		.TITLE_BG = {25, 25, 25, 255},
		.TITLE_TEXT = {240, 240, 240, 255},
		.PANEL_BG = {0, 0, 0, 0},
		.BUTTON = {80, 80, 80, 255},
		.BUTTON_HOVER = {98, 98, 98, 255},
		.BUTTON_FOCUS = {116, 116, 116, 255},
		.BASE = {30, 30, 30, 255},
		.BASE_HOVER = {35, 35, 35, 255},
		.BASE_FOCUS = {40, 40, 40, 255},
		.SCROLL_BASE = {43, 43, 43, 255},
		.SCROLL_THUMB = {30, 30, 30, 255},
	},
	background = {30, 30, 30, 255},
	dim = {140, 140, 140, 255},
	strong = {240, 240, 240, 255},
	notice_ok = {120, 200, 120, 255},
	warning = {230, 200, 90, 255},
	error = {230, 90, 90, 255},
	speaking = {110, 220, 110, 255},
	off = {225, 115, 115, 255},
	unread_text = {255, 255, 255, 255},
	viewing = {230, 230, 230, 255},
	badge_text = {255, 255, 255, 255},
	unread_badge = {60, 110, 200, 255},
	muted_badge = {70, 70, 70, 255},
	mention_badge = {90, 65, 20, 255},
	chat_name = {120, 170, 230, 255},
	chat_own = {140, 200, 140, 255},
	link = {100, 165, 245, 255},
	link_hover = {160, 205, 255, 255},
	mention = {235, 185, 95, 255},
	mention_me_bg = {110, 80, 25, 255},
	quote_bar = {95, 95, 95, 255},
	code_block = {36, 36, 36, 255},
	code_span = {28, 28, 28, 255},
	reply_bar = {85, 105, 135, 255},
	day_line = {110, 110, 110, 255},
	new_line = {220, 90, 90, 255},
	pinned = {120, 170, 240, 255},
	hover_tint = {255, 255, 255, 10},
	selection = {55, 85, 135, 255},
	highlight = {70, 95, 140, 255},
	highlight_more = {85, 115, 165, 255},
	failed_disc = {70, 70, 70, 255},
	failed_text = {235, 110, 110, 255},
	mark = {230, 230, 230, 255},
	mentions = {215, 60, 60, 255},
	plus_disc = {70, 70, 70, 255},
	panel = {38, 38, 38, 255},
	connected = {110, 200, 120, 255},
	ringing = {230, 180, 90, 255},
	unlit = {75, 75, 75, 255},
	track = {60, 60, 60, 255},
	image_bg = {50, 50, 50, 255},
	divider = {70, 70, 70, 255},
	deleted_disc = {90, 90, 90, 255},
	dot_ring = {32, 32, 32, 255},
	accent = {60, 110, 200, 255},
	accent_hover = {80, 130, 220, 255},
	accent_text = {255, 255, 255, 255},
	shadow = {0, 0, 0, 120},
}

LIGHT_PALETTE :: Palette {
	style = {
		.TEXT = {30, 30, 30, 255},
		.SELECTION_BG = {185, 205, 240, 255},
		.BORDER = {195, 195, 195, 255},
		.WINDOW_BG = {246, 246, 246, 255},
		.TITLE_BG = {222, 222, 222, 255},
		.TITLE_TEXT = {20, 20, 20, 255},
		.PANEL_BG = {0, 0, 0, 0},
		.BUTTON = {214, 214, 214, 255},
		.BUTTON_HOVER = {200, 200, 200, 255},
		.BUTTON_FOCUS = {184, 184, 184, 255},
		.BASE = {255, 255, 255, 255},
		.BASE_HOVER = {250, 250, 250, 255},
		.BASE_FOCUS = {244, 246, 252, 255},
		.SCROLL_BASE = {230, 230, 230, 255},
		.SCROLL_THUMB = {190, 190, 190, 255},
	},
	background = {232, 232, 232, 255},
	dim = {115, 115, 115, 255},
	strong = {25, 25, 25, 255},
	notice_ok = {40, 140, 60, 255},
	warning = {165, 115, 0, 255},
	error = {200, 50, 50, 255},
	speaking = {40, 155, 60, 255},
	off = {205, 60, 60, 255},
	unread_text = {0, 0, 0, 255},
	viewing = {20, 20, 20, 255},
	badge_text = {255, 255, 255, 255},
	unread_badge = {60, 110, 200, 255},
	muted_badge = {165, 165, 165, 255},
	mention_badge = {250, 225, 170, 255},
	chat_name = {30, 95, 175, 255},
	chat_own = {40, 130, 55, 255},
	link = {20, 100, 205, 255},
	link_hover = {60, 140, 235, 255},
	mention = {155, 95, 0, 255},
	mention_me_bg = {250, 228, 175, 255},
	quote_bar = {185, 185, 185, 255},
	code_block = {236, 236, 236, 255},
	code_span = {228, 228, 228, 255},
	reply_bar = {150, 170, 205, 255},
	day_line = {175, 175, 175, 255},
	new_line = {210, 60, 60, 255},
	pinned = {40, 100, 195, 255},
	hover_tint = {0, 0, 0, 12},
	selection = {185, 208, 245, 255},
	highlight = {200, 215, 240, 255},
	highlight_more = {180, 200, 235, 255},
	failed_disc = {175, 175, 175, 255},
	failed_text = {190, 50, 50, 255},
	mark = {40, 40, 40, 255},
	mentions = {215, 60, 60, 255},
	plus_disc = {175, 175, 175, 255},
	panel = {238, 238, 238, 255},
	connected = {40, 150, 65, 255},
	ringing = {185, 120, 20, 255},
	unlit = {200, 200, 200, 255},
	track = {210, 210, 210, 255},
	image_bg = {220, 220, 220, 255},
	divider = {200, 200, 200, 255},
	deleted_disc = {165, 165, 165, 255},
	dot_ring = {246, 246, 246, 255},
	accent = {45, 100, 200, 255},
	accent_hover = {65, 120, 220, 255},
	accent_text = {255, 255, 255, 255},
	shadow = {0, 0, 0, 55},
}

// The palette the UI draws with this frame (theme_update).
theme := DARK_PALETTE

// The theme choices offered in the settings, in the order they are shown.
Theme_Choice :: enum {
	System,
	Dark,
	Light,
}

THEME_CHOICE_NAMES := [Theme_Choice]string {
	.System = "system",
	.Dark   = "dark",
	.Light  = "light",
}

THEME_CHOICE_LABELS := [Theme_Choice]string {
	.System = "Same as system",
	.Dark   = "Dark",
	.Light  = "Light",
}

// How often the desktop is asked again whether it is dark.
@(private = "file")
SYSTEM_ASK_EVERY :: 5 * time.Second

UI_Theme :: struct {
	dark:     bool, // the palette in use
	applied:  bool, // theme_apply has run at all
	// The desktop's answer (atomic: 1 for dark, 0 for light, -1 if not known yet),
	// whether a thread is currently asking, and when the last query was started.
	system:   i32,
	asking:   bool, // atomic
	last_ask: time.Tick,
}

// theme_choice returns the choice that is stored in the settings.
theme_choice :: proc(s: ^settings.Settings) -> Theme_Choice {
	for name, c in THEME_CHOICE_NAMES {
		if s.theme == name {
			return c
		}
	}
	return .System
}

// theme_update picks the palette for this frame from the setting and, for
// "system", from the desktop's last answer. It also asks the desktop again
// every now and then. Called once per frame, before the layout.
theme_update :: proc(ui: ^UI) {
	t := &ui.theme_state
	dark := true
	switch theme_choice(&ui.settings) {
	case .Dark:
		dark = true
	case .Light:
		dark = false
	case .System:
		if !t.applied {
			// On the first run, ask right here so that the first frame doesn't flash
			// the wrong palette.
			t.system = 1 if platform.prefers_dark() else 0
			t.last_ask = time.tick_now()
		} else if time.tick_since(t.last_ask) >= SYSTEM_ASK_EVERY {
			t.last_ask = time.tick_now()
			system_ask(ui)
		}
		dark = sync.atomic_load(&t.system) != 0
	}
	if !t.applied || dark != t.dark {
		theme_apply(ui, dark)
	}
}

// theme_apply switches to the dark or the light palette.
theme_apply :: proc(ui: ^UI, dark: bool) {
	ui.theme_state.dark, ui.theme_state.applied = dark, true
	theme = DARK_PALETTE if dark else LIGHT_PALETTE
	ui.ctx.style.colors = theme.style
	ui_redraw(ui)
}

// system_ask asks the desktop for its preference. It does so right here when
// that is quick, and otherwise on a thread of its own (unless one is already
// asking). The answer is picked up one frame after it arrives.
@(private = "file")
system_ask :: proc(ui: ^UI) {
	t := &ui.theme_state
	when platform.PREFERS_DARK_IS_QUICK {
		sync.atomic_store(&t.system, 1 if platform.prefers_dark() else 0)
		return
	}
	if sync.atomic_load(&t.asking) {
		return
	}
	sync.atomic_store(&t.asking, true)
	asked := thread.create_and_start_with_poly_data(t, proc(t: ^UI_Theme) {
			dark := platform.prefers_dark()
			if sync.atomic_exchange(&t.system, 1 if dark else 0) != (1 if dark else 0) {
				ui_wake()
			}
			sync.atomic_store(&t.asking, false)
		}, self_cleanup = true)
	if asked == nil {
		sync.atomic_store(&t.asking, false)
	}
}

package client

import "core:sync"
import "core:thread"
import "core:time"
import mu "vendor:microui"

import "client:platform"
import "client:settings"

/*
The UI's colours: a dark palette and a light one, and the setting that
picks between them (settings.theme: "system", "dark" or "light"). Every
colour the UI draws with comes from `theme`, besides microui's own
(ctx.style.colors), which theme_apply sets from the same palette. A
picture's tint, the white on a coloured disc and the tray (whose panel
has colours of its own, ui_tray.odin) are the same in both.

"system" follows the desktop's own choice (platform.prefers_dark), asked
again every few seconds so a change there shows here without a restart.
Asking can mean running a program (busctl on Linux, defaults on macOS),
so it's done on a thread of its own, and the UI only reads the answer.
*/

Palette :: struct {
	style:          [mu.Color_Type]mu.Color, // microui's
	background:     mu.Color, // behind every window
	// Text: dimmed, picked out, and what's said of how something went.
	dim:            mu.Color,
	strong:         mu.Color,
	notice_ok:      mu.Color,
	warning:        mu.Color,
	error:          mu.Color,
	// The state icons: a voice coming through, something switched off.
	speaking:       mu.Color,
	off:            mu.Color,
	// Channels: an unread one's name, the one being looked at, and the
	// counts' boxes (whose text is badge_text, or for mentions, mention).
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
	hover_tint:     mu.Color, // over the message the bar is for
	selection:      mu.Color, // selected text
	highlight:      mu.Color, // a message picked out (a search's, a link's)
	highlight_more: mu.Color,
	// The rail: a server not connected, its text, and the marks beside
	// the one shown and where one is dragged to.
	failed_disc:    mu.Color,
	failed_text:    mu.Color,
	mark:           mu.Color,
	mentions:       mu.Color,
	plus_disc:      mu.Color, // the + that joins one
	// Voice: the panel, and how a call is going.
	panel:          mu.Color,
	connected:      mu.Color,
	ringing:        mu.Color,
	// Grey parts: a bar that isn't lit, a progress bar's track, what's
	// behind a picture, dividers, a deleted account's disc, and the ring
	// round an activity dot.
	unlit:          mu.Color,
	track:          mu.Color,
	image_bg:       mu.Color,
	divider:        mu.Color,
	deleted_disc:   mu.Color,
	dot_ring:       mu.Color,
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
		.BUTTON = {75, 75, 75, 255},
		.BUTTON_HOVER = {95, 95, 95, 255},
		.BUTTON_FOCUS = {115, 115, 115, 255},
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
		.BUTTON = {222, 222, 222, 255},
		.BUTTON_HOVER = {208, 208, 208, 255},
		.BUTTON_FOCUS = {188, 188, 188, 255},
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
}

// The palette the UI draws with this frame (theme_update).
theme := DARK_PALETTE

// The settings' choices, in the order they're offered.
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
	.System = "Like the system",
	.Dark   = "Dark",
	.Light  = "Light",
}

// How often the desktop is asked again whether it's dark.
@(private = "file")
SYSTEM_ASK_EVERY :: 5 * time.Second

UI_Theme :: struct {
	dark:     bool, // the palette in use
	applied:  bool, // theme_apply has run at all
	// The desktop's answer (atomic; 1 dark, 0 light, -1 not known yet),
	// whether a thread is out asking, and when one last went.
	system:   i32,
	asking:   bool, // atomic
	last_ask: time.Tick,
}

// theme_choice is what the settings say to use.
theme_choice :: proc(s: ^settings.Settings) -> Theme_Choice {
	for name, c in THEME_CHOICE_NAMES {
		if s.theme == name {
			return c
		}
	}
	return .System
}

/*
theme_update picks the palette for this frame, from the setting and, for
"system", the desktop's last answer; and asks the desktop again now and
then. Called once a frame, before the layout.
*/
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
			// The first time, asked here: the first frame shouldn't flash
			// the other palette.
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

// theme_apply switches to the dark palette or the light one.
theme_apply :: proc(ui: ^UI, dark: bool) {
	ui.theme_state.dark, ui.theme_state.applied = dark, true
	theme = DARK_PALETTE if dark else LIGHT_PALETTE
	ui.ctx.style.colors = theme.style
	ui_redraw(ui)
}

// system_ask asks the desktop: right here where that's quick, else on a
// thread of its own, unless one is out asking already; the answer is
// there for a frame after it comes.
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

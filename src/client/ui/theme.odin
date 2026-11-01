package ui

import "core"
import "core:sync"
import "core:thread"
import "core:time"

import "client:platform"
import "client:settings"

// The UI's colors: a dark palette and a light one, and the setting that
// picks between them (settings.theme: "system", "dark" or "light"). Every
// color the UI draws with comes from `theme`, except microui's own
// (ctx.style.colors), which theme_apply sets from the same palette. An
// image's tint, the white on a colored disc and the tray (whose panel
// has colors of its own, see ui/tray.odin) are the same in both palettes.
//
// "system" follows the desktop's own choice (platform.prefers_dark), which is
// queried again every few seconds so a change there shows up here without a
// restart. Querying can mean running a program (busctl on Linux, defaults on
// macOS), so it is done on a thread of its own and the UI only reads the
// answer.

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
	core.theme_apply(ui, dark)
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

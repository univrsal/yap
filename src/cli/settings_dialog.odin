package main

import "core:fmt"
import "core:strings"

import "client:audio"
import "tui"

// The settings that matter in a terminal: the audio devices and how the voice is
// sent. A change is applied and saved to cli.json at once. (The window client
// has many more; its settings.json is only read.)

Setting :: enum {
	Input,
	Output,
	Quality,
	Noise,
	Gate,
	Gate_Open,
	Gate_Close,
}

@(private = "file")
LABELS := [Setting]string {
	.Input      = "Microphone",
	.Output     = "Speakers",
	.Quality    = "Quality",
	.Noise      = "Noise suppression",
	.Gate       = "Voice gate",
	.Gate_Open  = "Gate opens at",
	.Gate_Close = "Gate closes at",
}

QUALITIES := [?]string{"voice", "high", "music"}
GATE_STEP :: 5

open_settings :: proc(a: ^App) {
	dialog_close(a)
	a.dialog.kind, a.dialog.sel = .Settings, 0
	a.want_devices = true // the loop lists them
}

// setting_value is a setting as the dialog shows it.
setting_value :: proc(a: ^App, s: Setting) -> string {
	v := &a.voice_settings
	switch s {
	case .Input: return v.input_device if v.input_device != "" else "(system default)"
	case .Output: return v.output_device if v.output_device != "" else "(system default)"
	case .Quality: return v.quality
	case .Noise: return "on" if v.noise_suppression else "off"
	case .Gate: return "on" if v.voice_gate else "off"
	case .Gate_Open: return fmt.tprintf("%.0f dB", v.gate_open_db)
	case .Gate_Close: return fmt.tprintf("%.0f dB", v.gate_close_db)
	}
	return ""
}

// setting_change moves a setting to the next (dir 1) or previous (-1) value,
// tells the connections and saves.
setting_change :: proc(a: ^App, s: Setting, dir: int) {
	v := &a.voice_settings
	switch s {
	case .Input:
		cycle_device(&v.input_device, a.input_devices[:], dir)
		a.devices_changed = true
	case .Output:
		cycle_device(&v.output_device, a.output_devices[:], dir)
		a.devices_changed = true
	case .Quality:
		at := 0
		for q, i in QUALITIES {
			if q == v.quality {
				at = i
			}
		}
		delete(v.quality)
		v.quality = strings.clone(QUALITIES[(at + dir + len(QUALITIES)) %% len(QUALITIES)])
	case .Noise:
		v.noise_suppression = !v.noise_suppression
	case .Gate:
		v.voice_gate = !v.voice_gate
	case .Gate_Open:
		v.gate_open_db = clamp(v.gate_open_db + f32(dir * GATE_STEP), audio.MIN_LEVEL_DB, 0)
		v.gate_close_db = min(v.gate_close_db, v.gate_open_db)
	case .Gate_Close:
		v.gate_close_db = clamp(v.gate_close_db + f32(dir * GATE_STEP), audio.MIN_LEVEL_DB, v.gate_open_db)
	}
	for sv in a.servers {
		apply_voice_settings(sv.client, v^)
	}
	if !voice_settings_save(a.cli_path, v^) && a.cli_path != "" {
		say(a, "Could not save the settings.", true)
	}
}

// cycle_device picks the next device in the list; "" (the system's) comes first.
@(private = "file")
cycle_device :: proc(current: ^string, devices: []string, dir: int) {
	// 0 is the system's, then the devices.
	at := 0
	for d, i in devices {
		if d == current^ {
			at = i + 1
		}
	}
	at = (at + dir + len(devices) + 1) %% (len(devices) + 1)
	delete(current^)
	current^ = strings.clone(devices[at - 1]) if at > 0 else ""
}

draw_settings :: proc(a: ^App, b: ^tui.Buffer) {
	d := &a.dialog
	r := dialog_rect(b, 62, len(Setting) + 8)
	append(&a.hits, Hit{r, .Dialog, 0, ""})
	draw_box(b, r, "Settings")
	for s in Setting {
		y := r.y + 2 + int(s)
		picked := int(s) == d.sel
		style := theme.selected if picked else tui.Style{}
		tui.fill(b, {r.x + 1, y, r.w - 2, 1}, style)
		tui.put_string(b, r.x + 2, y, LABELS[s], style, r.x + r.w - 1)
		value := fmt.tprintf("◂ %s ▸", setting_value(a, s))
		vw := tui.string_width(value)
		tui.put_string(b, r.x + r.w - vw - 3, y, tui.cut_to_width(value, r.w - 24), style, r.x + r.w - 1)
		append(&a.hits, Hit{{r.x + 1, y, r.w - 2, 1}, .Setting_Row, u64(s), ""})
	}
	y := r.y + 3 + len(Setting)
	if a.audio_error != "" {
		tui.put_string(b, r.x + 2, y, a.audio_error, theme.error, r.x + r.w - 1)
	} else if len(a.input_devices) == 0 && len(a.output_devices) == 0 {
		tui.put_string(b, r.x + 2, y, "No audio devices found.", theme.dim, r.x + r.w - 1)
	}
	if a.view.mic_open {
		tui.put_string(b, r.x + 2, y + 1, fmt.tprintf("Microphone: %s", level_bar(a.view.mic_level)), theme.online, r.x + r.w - 1)
	}
	tui.put_string(b, r.x + 2, r.y + r.h - 2, "Up/Down: pick   Left/Right: change   Esc: close", theme.dim, r.x + r.w - 1)
}

settings_key :: proc(a: ^App, k: tui.Key_Event) {
	d := &a.dialog
	switch k.key {
	case .Up: d.sel = (d.sel - 1 + len(Setting)) % len(Setting)
	case .Down, .Tab: d.sel = (d.sel + 1) % len(Setting)
	case .Left: setting_change(a, Setting(d.sel), -1)
	case .Right, .Enter: setting_change(a, Setting(d.sel), 1)
	case .Escape: dialog_close(a)
	case .Rune, .Backspace, .Home, .End, .Page_Up, .Page_Down, .Insert, .Delete, .F1, .F2, .F3, .F4, .F5, .F6, .F7, .F8, .F9, .F10, .F11, .F12:
	}
}

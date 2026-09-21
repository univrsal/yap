package client

import "core:fmt"
import log "../common/wlog"
import "core:sync"
import "core:time"
import mu "vendor:microui"

/*
The voice gate's part of the settings page: an on/off toggle, a live
microphone level meter, sliders for the two thresholds, and listen back
(hear your processed microphone; see Voice.listen).

The meter's scale runs from MIN_LEVEL_DB to 0 dBFS, colored by what the
gate does at each level:

	red    below "close"      the gate closes (after GATE_HANGOVER)
	amber  between the two    it stays as it is
	green  above "open"       it opens

While connected the level comes from the network thread (the frames
actually being sent). Otherwise the settings page opens the microphone
itself (Mic_Monitor) and runs the same processing, sending nothing.
*/

// How fast the meter's bar falls; it rises instantly.
@(private = "file")
METER_DECAY_DB_PER_SEC :: 40
// Without a new level for this long, show "no input".
@(private = "file")
METER_STALE :: 500 * time.Millisecond

@(private = "file")
METER_HEIGHT :: 26

Mic_Monitor :: struct {
	active:  bool,
	voice:   Voice, // only its capture ring, denoiser and gate are used
	streams: Audio_Streams,
	level:   f32,
	open:    bool,
	time:    time.Tick,
}

// monitor_update runs every frame: it keeps the microphone open while the
// settings page is shown without a connection, and processes what it
// captured.
monitor_update :: proc(ui: ^UI) {
	m := &ui.monitor
	want := ui.page == .Settings && ui.session == nil && ui.audio.ctx != nil
	if want && !m.active {
		if voice_init(&m.voice) {
			open_capture(&ui.audio, &m.streams, &m.voice, ui.settings.input_device)
			m.active = true
		}
	}
	if !want {
		monitor_stop(ui)
		return
	}

	// Listen back plays through the output device, opened only for it.
	m.voice.listen = ui.listen_back
	if ui.listen_back && m.streams.playback == nil {
		// The UI thread only gets here once per frame, so keep more queued
		// than the network thread does.
		m.voice.output_target = 3 * FRAME
		open_playback(&ui.audio, &m.streams, &m.voice, ui.settings.output_device)
	} else if !ui.listen_back && m.streams.playback != nil {
		close_playback(&m.streams, &m.voice)
	}

	m.voice.denoise = ui.settings.noise_suppression
	// Mono or stereo processing, as the chosen preset would send (the
	// monitor never encodes, so no encoder change is needed).
	m.voice.quality = settings_quality(&ui.settings)
	cmd := gate_command(&ui.settings)
	m.voice.gate.enabled, m.voice.gate.open_db, m.voice.gate.close_db = cmd.enabled, cmd.open_db, cmd.close_db

	frame: [FRAME]f32
	for ring_available(&m.voice.capture) >= FRAME {
		ring_read(&m.voice.capture, frame[:])
		pass: bool
		m.level, pass = mic_process(&m.voice, frame[:])
		listen_feed(&m.voice, frame[:], pass)
		m.open = m.voice.gate.open
		m.time = time.tick_now()
	}
	if m.streams.playback != nil {
		mix_output(&m.voice)
	}
}

monitor_stop :: proc(ui: ^UI) {
	m := &ui.monitor
	if !m.active {
		return
	}
	close_streams(&m.streams, &m.voice)
	voice_destroy(&m.voice)
	m^ = {}
}

gate_settings :: proc(ui: ^UI) {
	ctx := &ui.ctx
	s := &ui.settings

	mu.layout_row(ctx, {-1})
	state := "on" if s.voice_gate else "off  (always sends)"
	label := fmt.tprintf("Voice gate: %s  (only sends while your microphone is above the threshold)", state)
	if .SUBMIT in stable_button(ctx, "gate", label) {
		s.voice_gate = !s.voice_gate
		gate_changed(ui)
	}

	mu.layout_row(ctx, {-1}, METER_HEIGHT)
	level_meter(ui)

	mu.layout_row(ctx, {90, -1})
	mu.label(ctx, "Open at")
	if .CHANGE in mu.slider(ctx, &s.gate_open_db, MIN_LEVEL_DB, 0, 1, "%.0f dB") {
		s.gate_close_db = min(s.gate_close_db, s.gate_open_db)
		gate_changed(ui)
	}
	mu.label(ctx, "Close below")
	if .CHANGE in mu.slider(ctx, &s.gate_close_db, MIN_LEVEL_DB, 0, 1, "%.0f dB") {
		s.gate_open_db = max(s.gate_open_db, s.gate_close_db)
		gate_changed(ui)
	}

	mu.layout_row(ctx, {-1})
	listen := "on" if ui.listen_back else "off"
	listen_label := fmt.tprintf("Listen back: %s  (hear your microphone as others would; use headphones)", listen)
	if .SUBMIT in stable_button(ctx, "listen", listen_label) {
		set_listen_back(ui, !ui.listen_back)
	}
}

// set_listen_back turns listen back on or off, for the monitor (picked up
// by monitor_update) and a running connection.
set_listen_back :: proc(ui: ^UI, on: bool) {
	if ui.listen_back == on {
		return
	}
	ui.listen_back = on
	log.infof("listen back %s", "on" if on else "off")
	if ui.session != nil {
		push_command(&ui.session.client.commands, Listen_Command{on})
	}
}

@(private = "file")
gate_changed :: proc(ui: ^UI) {
	ui.settings_dirty = true // saved within a second; sliders change every frame
	if ui.session != nil {
		push_command(&ui.session.client.commands, gate_command(&ui.settings))
	}
}

@(private = "file")
level_meter :: proc(ui: ^UI) {
	ctx := &ui.ctx
	s := &ui.settings
	r := mu.layout_next(ctx)

	// The latest level, from whichever side is processing the microphone.
	level: f32 = MIN_LEVEL_DB
	open := false
	fresh := false
	if ui.session != nil {
		v := &ui.view
		sync.guard(&v.mutex)
		level, open = v.mic_level, v.mic_open
		fresh = v.mic_time != {} && time.tick_since(v.mic_time) < METER_STALE
	} else if ui.monitor.active {
		m := &ui.monitor
		level, open = m.level, m.open
		fresh = m.time != {} && time.tick_since(m.time) < METER_STALE
	}
	if !fresh {
		level, open = MIN_LEVEL_DB, false
	}

	// Rise instantly, fall smoothly, so short peaks are readable.
	now := time.tick_now()
	dt := f32(time.duration_seconds(time.tick_diff(ui.meter_time, now)))
	ui.meter_time = now
	ui.meter_level = max(level, ui.meter_level - METER_DECAY_DB_PER_SEC * min(dt, 1))

	x_of := proc(r: mu.Rect, db: f32) -> i32 {
		t := clamp((db - MIN_LEVEL_DB) / -f32(MIN_LEVEL_DB), 0, 1)
		return r.x + i32(t * f32(r.w))
	}
	closed_color := mu.Color{110, 45, 45, 255}
	between_color := mu.Color{120, 100, 40, 255}
	open_color := mu.Color{45, 105, 55, 255}
	if !s.voice_gate {
		// The gate isn't doing anything; keep the scale but dim it.
		closed_color, between_color, open_color = {60, 60, 60, 255}, {70, 70, 70, 255}, {80, 80, 80, 255}
	}
	close_x, open_x := x_of(r, s.gate_close_db), x_of(r, s.gate_open_db)
	mu.draw_rect(ctx, {r.x, r.y, close_x - r.x, r.h}, closed_color)
	mu.draw_rect(ctx, {close_x, r.y, open_x - close_x, r.h}, between_color)
	mu.draw_rect(ctx, {open_x, r.y, r.x + r.w - open_x, r.h}, open_color)

	// The level: a bar through the middle, bright green while sending.
	bar_color := mu.Color{120, 235, 130, 255} if open || !s.voice_gate else mu.Color{215, 215, 215, 255}
	bar_h := r.h / 3
	mu.draw_rect(ctx, {r.x, r.y + bar_h, x_of(r, ui.meter_level) - r.x, bar_h}, bar_color)

	// Threshold markers.
	mu.draw_rect(ctx, {close_x - 1, r.y, 2, r.h}, {240, 240, 240, 255})
	mu.draw_rect(ctx, {open_x - 1, r.y, 2, r.h}, {240, 240, 240, 255})

	text: string
	switch {
	case !fresh:
		text = "no microphone input  "
	case !s.voice_gate:
		text = fmt.tprintf("%.0f dB  ", level)
	case:
		text = fmt.tprintf("%.0f dB  %s  ", level, "open" if open else "closed")
	}
	mu.draw_control_text(ctx, text, r, .TEXT, {.ALIGN_RIGHT})
}

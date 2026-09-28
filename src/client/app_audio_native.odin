#+build !wasi
package client

import log "../common/wlog"
import "core:os"
import "core:strings"
import "core:sync"
import mu "vendor:microui"

import "aac"

/*
Sharing an application's audio with the channel, next to the
microphone (native clients; see aac/aac.odin for which systems can).

The header's button opens a menu of the applications playing audio;
picking one captures it (on tinyaac's thread) into the Voice's app ring,
converted to 48 kHz stereo on the way. The network thread mixes it into
every frame it sends, after noise suppression and the voice gate, which
only ever see the microphone (see send_captured in voice.odin). Muting
the microphone mutes the application as well, unless the settings say
otherwise (mute_app_audio_with_mic); then it keeps being heard until the
share is stopped.

Like the audio devices, the capture belongs to the UI thread and to one
connection: disconnecting stops it.
*/

@(private = "file")
MENU_NAME :: "app audio"
// As wide as the user menu.
@(private = "file")
MENU_WIDTH :: 240

// One application being captured into a Voice's app ring. Its address
// is what tinyaac's callbacks get.
App_Share :: struct {
	capture: ^aac.Capture,
	voice:   ^Voice,
	// Resampling to SAMPLE_RATE (resample_write): the application's rate,
	// where the next output frame falls in the next input chunk (-1 is
	// `prev`), and the chunk before's last frame.
	rate:    u32,
	pos:     f64,
	prev:    [CHANNELS]f32,
	// Set by tinyaac's thread when the application has gone or the
	// capture failed, with why; the UI stops the share (app_audio_frame).
	ended:   bool, // atomic
	why:     [128]u8,
}

UI_App_Audio :: struct {
	available: bool, // tinyaac came up
	share:     ^App_Share, // nil while nothing is shared
	name:      string, // what's being shared; owned
	// The menu's applications, as they were when it was opened.
	list:      ^aac.App_List,
	requested: bool, // open the menu (see user_menu for why it's deferred)
	volume:    mu.Real, // the menu's slider, percent
	error:     string, // why the last share didn't start; owned
}

app_audio_init :: proc(ui: ^UI) {
	if aac.init() != .Ok {
		why := string(aac.last_error())
		if why == "" {
			why = "libpipewire-0.3 could not be loaded" // the one failure with nothing to say
		}
		log.infof("app audio: unavailable: %s", why)
		return
	}
	ui.app_audio.available = true
}

app_audio_destroy :: proc(ui: ^UI) {
	a := &ui.app_audio
	app_audio_stop(ui)
	if a.list != nil {
		aac.app_list_destroy(a.list)
		a.list = nil
	}
	delete(a.error)
	a.error = ""
	if a.available {
		aac.shutdown()
		a.available = false
	}
}

app_audio_available :: proc(ui: ^UI) -> bool {
	return ui.app_audio.available
}

// app_audio_frame ends a share whose application has gone away.
app_audio_frame :: proc(ui: ^UI) {
	s := ui.app_audio.share
	if s == nil || !sync.atomic_load(&s.ended) {
		return
	}
	log.infof("app audio: %s stopped: %s", ui.app_audio.name, cstring(&s.why[0]))
	app_audio_stop(ui)
}

// app_audio_stop stops sharing, if anything is shared.
app_audio_stop :: proc(ui: ^UI) {
	a := &ui.app_audio
	s := a.share
	if s == nil {
		return
	}
	sync.atomic_store(&s.voice.app_input, false)
	aac.capture_stop(s.capture) // after this the callbacks no longer run
	aac.capture_destroy(s.capture)
	free(s)
	a.share = nil
	log.infof("app audio: stopped sharing %s", a.name)
	delete(a.name)
	a.name = ""
}

// app_audio_button opens the menu. Green while something is shared.
app_audio_button :: proc(ui: ^UI) {
	a := &ui.app_audio
	hint := "Share an application's audio"
	color := mu.Color{}
	if a.share != nil {
		hint = strings.concatenate({"Sharing the audio of ", a.name}, context.temp_allocator)
		color = SPEAKING_COLOR
	}
	if .SUBMIT in icon_button(ui, "app audio", .App_Audio, hint, color) {
		app_audio_refresh(ui)
		a.volume = app_audio_gain(&ui.settings) * 100
		a.requested = true
	}
}

// app_audio_menu shows the menu while it's open: what's shared, how
// loud, and the applications to pick from.
app_audio_menu :: proc(ui: ^UI) {
	ctx := &ui.ctx
	a := &ui.app_audio
	if a.requested {
		a.requested = false
		mu.open_popup(ctx, MENU_NAME)
	}
	if cnt := mu.get_container(ctx, MENU_NAME, {.CLOSED}); cnt != nil && cnt.open {
		w, h := i32(ui.metrics.logical_w), i32(ui.metrics.logical_h)
		cnt.rect.x = clamp(cnt.rect.x, 0, max(w - cnt.rect.w, 0))
		cnt.rect.y = clamp(cnt.rect.y, 0, max(h - cnt.rect.h, 0))
	}
	if !mu.begin_popup(ctx, MENU_NAME) {
		return
	}
	defer mu.end_popup(ctx)

	if a.share != nil {
		mu.layout_row(ctx, {MENU_WIDTH})
		mu.label(ctx, strings.concatenate({"Sharing ", a.name}, context.temp_allocator))
		mu.layout_row(ctx, {MENU_WIDTH})
		if .SUBMIT in stable_button(ctx, "stop", "Stop sharing") {
			app_audio_stop(ui)
		}
	}

	mu.layout_row(ctx, {60, MENU_WIDTH - 60 - ctx.style.spacing})
	mu.label(ctx, "Volume")
	if .CHANGE in mu.slider(ctx, &a.volume, 0, MAX_USER_VOLUME * 100, 5, "%.0f%%") {
		ui.settings.app_audio_volume = a.volume / 100
		ui.settings_dirty = true
		if ui.session != nil {
			push_command(&ui.session.client.commands, app_audio_command(&ui.settings))
		}
	}

	mu.layout_row(ctx, {MENU_WIDTH})
	with_text_color(ctx, DIM_COLOR, "Share the audio of:", label_proc)
	count := 0
	if a.list != nil {
		me := u32(os.get_pid())
		for i in 0 ..< aac.app_list_count(a.list) {
			app := aac.app_list_get(a.list, i)
			// Not ourselves: everyone would hear themselves back.
			if app.process_id == me {
				continue
			}
			count += 1
			name := string(app.display_name)
			mu.push_id(ctx, uintptr(i))
			mu.layout_row(ctx, {MENU_WIDTH})
			if .SUBMIT in stable_button(ctx, "app", name) {
				app_audio_start(ui, i, name)
				mu.get_current_container(ctx).open = false
			}
			mu.pop_id(ctx)
		}
	}
	if count == 0 {
		mu.layout_row(ctx, {MENU_WIDTH})
		with_text_color(ctx, DIM_COLOR, "Nothing is playing audio.", label_proc)
	}
	mu.layout_row(ctx, {MENU_WIDTH})
	if .SUBMIT in stable_button(ctx, "refresh", "Refresh") {
		app_audio_refresh(ui)
	}
	if a.error != "" {
		mu.layout_row(ctx, {MENU_WIDTH})
		with_text_color(ctx, OFF_COLOR, a.error, label_proc)
	}
}

// app_audio_refresh lists the applications playing audio now.
@(private = "file")
app_audio_refresh :: proc(ui: ^UI) {
	a := &ui.app_audio
	if a.list != nil {
		aac.app_list_destroy(a.list)
		a.list = nil
	}
	if st := aac.app_list_create(&a.list); st != .Ok {
		a.list = nil
		log.errorf("app audio: could not list applications: %s", aac.last_error())
	}
}

// app_audio_start shares the menu list's application `index` (called
// `name`) with the connection, instead of whatever was shared before.
@(private = "file")
app_audio_start :: proc(ui: ^UI, index: uint, name: string) {
	a := &ui.app_audio
	app_audio_stop(ui)
	delete(a.error)
	a.error = ""
	ns := ui.session
	if ns == nil || !ns.client.voice.ready || a.list == nil {
		return
	}
	s := new(App_Share)
	s.voice = &ns.client.voice
	st := aac.capture_create(a.list, index, &s.capture)
	if st == .Ok {
		st = aac.capture_set_callbacks(s.capture, app_audio_callback, app_event_callback, s)
	}
	if st == .Ok {
		st = aac.capture_start(s.capture)
	}
	if st != .Ok {
		why := string(aac.last_error())
		log.errorf("app audio: could not share %s: %s", name, why)
		if st == .Permission_Denied {
			a.error = strings.clone("Not allowed to capture its audio; see the system's privacy settings.")
		} else {
			a.error = strings.concatenate({"Could not share it: ", why})
		}
		if s.capture != nil {
			aac.capture_destroy(s.capture)
		}
		free(s)
		return
	}
	push_command(&ns.client.commands, app_audio_command(&ui.settings))
	sync.atomic_store(&s.voice.app_input, true)
	a.share = s
	a.name = strings.clone(name)
	log.infof("app audio: sharing %s", name)
}

// Runs on tinyaac's thread. Like the device callbacks, it only moves
// samples into the ring, which drops what doesn't fit.
@(private = "file")
app_audio_callback :: proc "c" (frame: ^aac.Audio_Frame, user: rawptr) {
	s := (^App_Share)(user)
	channels := int(frame.channels)
	if channels == 0 || frame.sample_rate == 0 {
		return
	}
	if frame.sample_rate != s.rate {
		s.rate, s.pos, s.prev = frame.sample_rate, 0, {}
	}
	frames := int(frame.frame_count)
	CHUNK :: 256
	stereo: [CHUNK * CHANNELS]f32
	for done := 0; done < frames; done += CHUNK {
		n := min(CHUNK, frames - done)
		to_stereo(frame.samples[done * channels:][:n * channels], channels, stereo[:n * CHANNELS])
		if s.rate == SAMPLE_RATE {
			ring_write(&s.voice.app, stereo[:n * CHANNELS])
		} else {
			resample_write(s, stereo[:n * CHANNELS])
		}
	}
}

@(private = "file")
app_event_callback :: proc "c" (event: aac.Event, status: aac.Status, message: cstring, user: rawptr) {
	s := (^App_Share)(user)
	if event != .Target_Ended && event != .Backend_Error {
		return
	}
	if !sync.atomic_load(&s.ended) {
		text := string(message) if message != nil else ""
		copy(s.why[:len(s.why) - 1], text)
		sync.atomic_store(&s.ended, true)
	}
}

/*
resample_write converts stereo audio at s.rate to SAMPLE_RATE and writes
it to the ring, interpolating linearly between neighbouring frames. That
aliases a little, which is lost in Opus at the rates we send; most
applications play at 48 kHz anyway and skip this altogether.
*/
resample_write :: proc "contextless" (s: ^App_Share, input: []f32) {
	frames := len(input) / CHANNELS
	if frames == 0 {
		return
	}
	step := f64(s.rate) / SAMPLE_RATE
	out: [512 * CHANNELS]f32
	n := 0
	for s.pos < f64(frames - 1) {
		// pos >= -1, so this is its floor.
		i := int(s.pos + 1) - 1
		frac := f32(s.pos - f64(i))
		for c in 0 ..< CHANNELS {
			from := s.prev[c] if i < 0 else input[i * CHANNELS + c]
			to := input[(i + 1) * CHANNELS + c]
			out[n + c] = from + (to - from) * frac
		}
		n += CHANNELS
		if n == len(out) {
			ring_write(&s.voice.app, out[:n])
			n = 0
		}
		s.pos += step
	}
	ring_write(&s.voice.app, out[:n])
	s.pos -= f64(frames)
	copy(s.prev[:], input[(frames - 1) * CHANNELS:])
}

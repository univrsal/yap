package client

import "core:time"

import "client:audio"
import "client:platform"
import "client:settings"

// The welcome and goodbye sounds: played when the client starts and when it
// quits, not tied to any one server. They are the UI's own, played on the
// speakers through a Voice of their own (only its playback ring and its
// notifications are used), which is opened for the sound and closed once it has
// played out, the way the settings page's monitor opens the microphone
// (see ui_gate.odin).
//
// The Sounds page plays the sounds to try them out the same way
// (app_sound_preview).
//
// Nothing is played while deafened. A web build plays neither the welcome nor
// the goodbye, because a page may not make a sound before it has been clicked
// and has no quitting to wait for.

App_Sound :: struct {
	active:  bool,
	voice:   audio.Voice,
	streams: audio.Audio_Streams,
	// When the last of the sound was sent to the device, which still has some
	// left to play at that point.
	drained: time.Tick,
}

// How long the device is left open after the sound has been sent to it.
@(private = "file")
APP_SOUND_GRACE :: 200 * time.Millisecond

// The longest the client waits for the goodbye before it quits anyway.
@(private = "file")
APP_SOUND_GOODBYE_MAX :: 3 * time.Second

// app_sound_play starts the welcome or the goodbye sound.
app_sound_play :: proc(ui: ^UI, kind: audio.Sound_Event) {
	when platform.WEB {
		return
	}
	name := sound_effective(ui, kind)
	if name == "" || !app_sound_open(ui) {
		return
	}
	s := &ui.app_sound
	audio.notifications_set(&s.voice.notifications, kind, name)
	audio.notification_play(&s.voice.notifications, kind)
}

// app_sound_preview plays a sound (by its name, see audio.sound_acquire) to
// try it out, in place of any it is playing.
app_sound_preview :: proc(ui: ^UI, name: string) {
	if name != "" && app_sound_open(ui) {
		audio.notification_preview(&ui.app_sound.voice.notifications, name)
	}
}

// app_sound_open opens the speakers for a sound, unless they are already.
@(private = "file")
app_sound_open :: proc(ui: ^UI) -> bool {
	s := &ui.app_sound
	if ui.deafened || ui.audio.ctx == nil {
		return false
	}
	if !s.active {
		if !audio.voice_init(&s.voice) {
			return false
		}
		s.active = true
		audio.open_playback(&ui.audio, &s.streams, &s.voice, ui.settings.output_device)
		if s.streams.playback == nil {
			app_sound_stop(ui)
			return false
		}
	}
	s.voice.notifications.volume = settings.notification_gain(&ui.settings)
	s.drained = {}
	return true
}

// app_sound_step feeds the device what is left of the sound, and closes
// it once that has played. Called on every turn of the loop.
app_sound_step :: proc(ui: ^UI) {
	s := &ui.app_sound
	if !s.active {
		return
	}
	audio.notification_tail_step(&s.voice)
	if audio.notifications_pending(&s.voice.notifications) ||
	   audio.ring_available(&s.voice.playback) > 0 {
		return
	}
	if s.drained == {} {
		s.drained = time.tick_now()
	}
	if time.tick_since(s.drained) >= APP_SOUND_GRACE {
		app_sound_stop(ui)
	}
}

app_sound_stop :: proc(ui: ^UI) {
	s := &ui.app_sound
	if !s.active {
		return
	}
	audio.close_streams(&s.streams, &s.voice)
	audio.voice_destroy(&s.voice)
	s^ = {}
}

// app_sound_goodbye plays the goodbye as the client quits, after the window
// and the tray icon are already gone so that it looks finished to everyone,
// and waits (for a limited time) for it to finish.
app_sound_goodbye :: proc(ui: ^UI) {
	when platform.WEB {
		return
	}
	window_close(ui)
	tray_hide(ui)
	app_sound_play(ui, .Goodbye)
	start := time.tick_now()
	for ui.app_sound.active && time.tick_since(start) < APP_SOUND_GOODBYE_MAX {
		app_sound_step(ui)
		time.sleep(10 * time.Millisecond)
	}
	app_sound_stop(ui)
}

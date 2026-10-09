package client

import "core:time"

import "client:audio"
import "client:platform"
import "client:settings"

/*
The welcome and goodbye sounds: the client starting and the client
quitting, not any one server. They're the UI's own, played on the
speakers through a Voice of their own (only its playback ring and its
notifications are used), opened for the sound and closed once it has
played out, the way the settings page's monitor opens the microphone
(ui_gate.odin).

Nothing is played while deafened. A web build plays neither: a page
may not make a sound before it's been clicked, and has no quitting to
wait for.
*/

App_Sound :: struct {
	active:  bool,
	voice:   audio.Voice,
	streams: audio.Audio_Streams,
	// When the last of it went to the device, which still has some to
	// play then.
	drained: time.Tick,
}

// How long the device is left open after the sound has gone to it.
@(private = "file")
APP_SOUND_GRACE :: 200 * time.Millisecond

// The longest the client waits on the goodbye before it quits anyway.
@(private = "file")
APP_SOUND_GOODBYE_MAX :: 3 * time.Second

// app_sound_play starts the welcome or the goodbye.
app_sound_play :: proc(ui: ^UI, kind: audio.Notification_Kind) {
	when platform.WEB {
		return
	}
	s := &ui.app_sound
	if ui.deafened || ui.audio.ctx == nil {
		return
	}
	if !s.active {
		if !audio.voice_init(&s.voice) {
			return
		}
		s.active = true
		audio.open_playback(&ui.audio, &s.streams, &s.voice, ui.settings.output_device)
		if s.streams.playback == nil {
			app_sound_stop(ui)
			return
		}
	}
	s.voice.notifications.volume = settings.notification_gain(&ui.settings)
	s.drained = {}
	audio.notification_play(&s.voice.notifications, kind)
}

// app_sound_step feeds the device what's left of the sound, and closes
// it once that's played. Every turn round the loop.
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

/*
app_sound_goodbye plays the goodbye as the client quits, with the window
and the tray icon already gone so it's over as far as anyone can see,
and waits (a while at most) for it to finish.
*/
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

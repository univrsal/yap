package audio

// The most event sounds played at once (the loop not counted). A sound past
// that ends the one that has been playing the longest.
MAX_PLAYING :: 4

// The sounds a Voice plays for events (see sound_packs.odin), mixed into its
// playback with the voices: up to MAX_PLAYING at once, and under them at most
// one loop (a ringtone, or the connection staying bad).
Notification_Sounds :: struct {
	// The sound of each event, from the store (sound_store.odin); nil for
	// no sound. Set with notifications_set.
	clips:         [Sound_Event]^Sound_Clip,
	// A sound played to try it out (notification_preview).
	preview:       ^Sound_Clip,
	// The loop, played repeatedly (notification_loop), but not while
	// deafened.
	loop_event:    Sound_Event,
	loop:          Playing,
	loop_quiet:    bool,
	volume:        f32,
	// The sounds playing, the one that started first first.
	playing:       [MAX_PLAYING]Playing,
	playing_count: int,
}

// Playing is (part of) a sound being played: its samples, interleaved with
// its own channel count. A mono sound goes to both speakers as it is mixed,
// so it is only kept once.
Playing :: struct {
	samples:  []f32,
	channels: int,
	position: int, // in samples
}

// voice_notification_play plays a notification sound, unless we are
// deafened: a deafened client does not play any new notification sounds.
voice_notification_play :: proc(v: ^Voice, kind: Sound_Event) {
	if !v.deafened {
		notification_play(&v.notifications, kind)
	}
}

// voice_feedback_play plays the sound for the user's own mute or deafen
// toggle (Muted, Unmuted, Deafened, Undeafened). It plays even while
// deafened, since deafening is one of the actions it gives feedback for.
voice_feedback_play :: proc(v: ^Voice, kind: Sound_Event) {
	notification_play(&v.notifications, kind)
}

// The events whose sounds are kept while deafened.
@(private = "file")
FEEDBACK :: bit_set[Sound_Event]{.Muted, .Unmuted, .Deafened, .Undeafened}

// notifications_deafen drops every sound playing except the mute/deafen
// feedback. A deafened client hears nothing of what happens on the server,
// only the feedback for having just deafened.
notifications_deafen :: proc(s: ^Notification_Sounds) {
	kept := 0
	for i in 0 ..< s.playing_count {
		if is_feedback(s, s.playing[i]) {
			s.playing[kept] = s.playing[i]
			kept += 1
		}
	}
	for i in kept ..< s.playing_count {
		s.playing[i] = {}
	}
	s.playing_count = kept
}

@(private = "file")
is_feedback :: proc(s: ^Notification_Sounds, p: Playing) -> bool {
	for kind in FEEDBACK {
		if c := s.clips[kind]; c != nil && raw_data(p.samples) == raw_data(c.samples) {
			return true
		}
	}
	return false
}

notifications_clear :: proc(s: ^Notification_Sounds) {
	s.playing = {}
	s.playing_count = 0
}

notifications_pending :: proc(s: ^Notification_Sounds) -> bool {
	return s.playing_count > 0
}

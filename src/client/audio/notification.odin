package audio

// The sounds a Voice plays for events (see sound_packs.odin), mixed into its
// playback with the voices: one at a time, the others queued, and under
// them at most one loop (a ringtone, or the connection staying bad).
Notification_Sounds :: struct {
	// The sound of each event, from the store (sound_store.odin); nil for
	// no sound. Set with notifications_set.
	clips:        [Sound_Event]^Sound_Clip,
	// A sound played to try it out (notification_preview).
	preview:      ^Sound_Clip,
	// The loop, played repeatedly (notification_loop), but not while
	// deafened.
	loop_event:   Sound_Event,
	loop:         []f32,
	loop_pos:     int,
	loop_quiet:   bool,
	volume:       f32,
	active:       []f32,
	position:     int,
	queued:       [8][]f32,
	queued_count: int,
}

// voice_notification_play queues a notification sound, unless we are
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

// notifications_deafen drops every sound except the mute/deafen feedback,
// whether it is playing or queued. A deafened client hears nothing of what
// happens on the server, only the feedback for having just deafened.
notifications_deafen :: proc(s: ^Notification_Sounds) {
	if !is_feedback(s, s.active) {
		s.active = nil
		s.position = 0
	}
	kept := 0
	for i in 0 ..< s.queued_count {
		if is_feedback(s, s.queued[i]) {
			s.queued[kept] = s.queued[i]
			kept += 1
		}
	}
	for i in kept ..< s.queued_count {
		s.queued[i] = nil
	}
	s.queued_count = kept
}

@(private = "file")
is_feedback :: proc(s: ^Notification_Sounds, clip: []f32) -> bool {
	if len(clip) == 0 {
		return false
	}
	for kind in FEEDBACK {
		if c := s.clips[kind]; c != nil && raw_data(clip) == raw_data(c.samples) {
			return true
		}
	}
	return false
}

notifications_clear :: proc(s: ^Notification_Sounds) {
	s.active = nil
	s.position = 0
	for &clip in s.queued {
		clip = nil
	}
	s.queued_count = 0
}

notifications_pending :: proc(s: ^Notification_Sounds) -> bool {
	return len(s.active) > 0 || s.queued_count > 0
}

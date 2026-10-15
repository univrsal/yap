package audio

Notification_Kind :: enum {
	Join,
	Leave,
	Message,
	Welcome,
	Goodbye,
	// We muted or deafened ourselves, or undid it (voice_feedback_play).
	Muted,
	Unmuted,
	Mail,
	// A file sent to us has been received completely (conn/files.odin).
	Done,
}

Notification_Sounds :: struct {
	join:         []f32,
	leave:        []f32,
	message:      []f32,
	welcome:      []f32,
	goodbye:      []f32,
	muted:        []f32,
	unmuted:      []f32,
	mail:         []f32,
	done:         []f32,
	// Ringtones for an incoming call (ring) and for our own outgoing call
	// (ringback). They are played repeatedly while the call rings
	// (notification_loop), but not while deafened.
	ring:         []f32,
	ringback:     []f32,
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
voice_notification_play :: proc(v: ^Voice, kind: Notification_Kind) {
	if !v.deafened {
		notification_play(&v.notifications, kind)
	}
}

// voice_feedback_play plays the sound for the user's own mute or deafen
// toggle. It plays even while deafened, since deafening is one of the
// actions it gives feedback for.
voice_feedback_play :: proc(v: ^Voice, on: bool) {
	notification_play(&v.notifications, .Muted if on else .Unmuted)
}

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
	return raw_data(clip) == raw_data(s.muted) || raw_data(clip) == raw_data(s.unmuted)
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

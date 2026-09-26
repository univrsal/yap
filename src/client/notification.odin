package client

Notification_Kind :: enum {
	Join,
	Leave,
	Message,
	Welcome,
	Goodbye,
	// Our own mute or deafen, switched on or off (voice_feedback_play).
	Muted,
	Unmuted,
}

Notification_Sounds :: struct {
	join:         []f32,
	leave:        []f32,
	message:      []f32,
	welcome:      []f32,
	goodbye:      []f32,
	muted:        []f32,
	unmuted:      []f32,
	volume:       f32,
	active:       []f32,
	position:     int,
	queued:       [8][]f32,
	queued_count: int,
}

// voice_notification_play keeps local notification effects consistent with
// deafen: a deafened client does not queue any new notification sounds.
voice_notification_play :: proc(v: ^Voice, kind: Notification_Kind) {
	if !v.deafened {
		notification_play(&v.notifications, kind)
	}
}

// voice_feedback_play answers the user's own mute or deafen. It plays
// even while deafened, since deafening is one of the things it answers.
voice_feedback_play :: proc(v: ^Voice, on: bool) {
	notification_play(&v.notifications, .Muted if on else .Unmuted)
}

/*
notifications_deafen drops every sound but the mute/deafen feedback,
whether playing or queued: a deafened client hears nothing of what
happens on the server, only that it has just deafened.
*/
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

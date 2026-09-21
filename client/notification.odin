package client

Notification_Kind :: enum {
	Join,
	Leave,
	Message,
}

Notification_Sounds :: struct {
	join:         []f32,
	leave:        []f32,
	message:      []f32,
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

notifications_clear :: proc(s: ^Notification_Sounds) {
	s.active = nil
	s.position = 0
	for &clip in s.queued {
		clip = nil
	}
	s.queued_count = 0
}

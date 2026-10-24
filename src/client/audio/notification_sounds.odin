package audio

// notifications_init gives every event its default sound (DEFAULT_SOUNDS).
// The UI then sets the user's choices (notifications_set).
notifications_init :: proc(s: ^Notification_Sounds) {
	s.volume = 1
	for name, kind in DEFAULT_SOUNDS {
		s.clips[kind] = sound_acquire(name)
	}
}

notifications_destroy :: proc(s: ^Notification_Sounds) {
	for clip in s.clips {
		sound_release(clip)
	}
	sound_release(s.preview)
	s^ = {}
}

// notifications_set gives an event the sound of that name (see
// sound_acquire); "" or "none" is no sound.
notifications_set :: proc(s: ^Notification_Sounds, kind: Sound_Event, name: string) {
	old := s.clips[kind]
	if old != nil && old.name == name {
		return
	}
	s.clips[kind] = sound_acquire(name)
	if old != nil {
		forget(s, old)
		sound_release(old)
	}
	if kind == s.loop_event && kind != .None {
		// The loop goes on with the new sound.
		s.loop_event = .None
		notification_loop(s, kind)
	}
}

// forget stops playing a sound that is about to be let go of, unless another
// event of ours still has it.
@(private = "file")
forget :: proc(s: ^Notification_Sounds, clip: ^Sound_Clip) {
	if s.preview == clip {
		return
	}
	for c in s.clips {
		if c == clip {
			return
		}
	}
	same :: proc(p: Playing, clip: ^Sound_Clip) -> bool {
		a := p.samples
		return(
			len(a) > 0 &&
			raw_data(a) >= raw_data(clip.samples) &&
			raw_data(a) < raw_data(clip.samples[len(clip.samples):]) \
		)
	}
	kept := 0
	for i in 0 ..< s.playing_count {
		if !same(s.playing[i], clip) {
			s.playing[kept] = s.playing[i]
			kept += 1
		}
	}
	for i in kept ..< s.playing_count {
		s.playing[i] = {}
	}
	s.playing_count = kept
	if same(s.loop, clip) {
		s.loop = {}
	}
}

notification_play :: proc(s: ^Notification_Sounds, kind: Sound_Event) {
	if clip := s.clips[kind]; clip != nil {
		start(s, one_shot(clip))
	}
}

// notification_preview plays the sound of that name once, in place of
// anything playing, to try it out.
notification_preview :: proc(s: ^Notification_Sounds, name: string) {
	old := s.preview
	s.preview = sound_acquire(name)
	if old != nil {
		forget(s, old)
		sound_release(old)
	}
	notifications_clear(s)
	if s.preview != nil {
		start(s, one_shot(s.preview))
	}
}

// one_shot is what plays of a sound that isn't looped: at most
// ONE_SHOT_SECONDS of it.
@(private = "file")
one_shot :: proc(clip: ^Sound_Clip) -> Playing {
	limit := ONE_SHOT_SECONDS * SAMPLE_RATE * clip.channels
	return {clip.samples[:min(len(clip.samples), limit)], clip.channels, 0}
}

// start plays a sound over the others playing. A sound that is already
// playing starts over instead of being played twice, which would only be
// louder; past MAX_PLAYING, the sound that started first is ended.
@(private = "file")
start :: proc(s: ^Notification_Sounds, p: Playing) {
	if len(p.samples) == 0 {
		return
	}
	end := 0 // the one to take out, if any
	for end < s.playing_count && raw_data(s.playing[end].samples) != raw_data(p.samples) {
		end += 1
	}
	if end == s.playing_count && s.playing_count == MAX_PLAYING {
		end = 0
	}
	if end < s.playing_count {
		copy(s.playing[end:s.playing_count], s.playing[end + 1:s.playing_count])
		s.playing_count -= 1
	}
	s.playing[s.playing_count] = p
	s.playing_count += 1
}

// notification_loop starts playing an event's sound repeatedly, from its
// start unless that event is already looping. Passing .None stops the loop.
notification_loop :: proc(s: ^Notification_Sounds, kind: Sound_Event) {
	if kind == s.loop_event {
		return
	}
	s.loop_event = kind
	s.loop = {}
	if clip := s.clips[kind]; clip != nil && kind != .None {
		s.loop = {clip.samples, clip.channels, 0}
	}
}

// notifications_mix adds the sounds to `mix` (CHANNELS interleaved). A mono
// sound goes to every channel.
notifications_mix :: proc(s: ^Notification_Sounds, mix: []f32) {
	frames := len(mix) / CHANNELS
	if loop := &s.loop; len(loop.samples) > 0 {
		for f in 0 ..< frames {
			if !s.loop_quiet {
				for c in 0 ..< CHANNELS {
					mix[f * CHANNELS + c] +=
						loop.samples[loop.position + min(c, loop.channels - 1)] * s.volume
				}
			}
			loop.position = (loop.position + loop.channels) % len(loop.samples)
		}
	}
	kept := 0
	for i in 0 ..< s.playing_count {
		p := s.playing[i]
		count := min(frames, (len(p.samples) - p.position) / p.channels)
		for f in 0 ..< count {
			for c in 0 ..< CHANNELS {
				mix[f * CHANNELS + c] +=
					p.samples[p.position + f * p.channels + min(c, p.channels - 1)] * s.volume
			}
		}
		p.position += count * p.channels
		if p.position + p.channels <= len(p.samples) {
			s.playing[kept] = p
			kept += 1
		}
	}
	for i in kept ..< s.playing_count {
		s.playing[i] = {}
	}
	s.playing_count = kept
}

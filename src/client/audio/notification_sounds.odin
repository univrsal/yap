package audio

import log "common:wlog"
import "core:encoding/endian"

import "client:audio/opus"

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
	same :: proc(a: []f32, clip: ^Sound_Clip) -> bool {
		return len(a) > 0 && raw_data(a) >= raw_data(clip.samples) &&
			raw_data(a) < raw_data(clip.samples[len(clip.samples):])
	}
	if same(s.active, clip) {
		s.active, s.position = nil, 0
	}
	kept := 0
	for i in 0 ..< s.queued_count {
		if !same(s.queued[i], clip) {
			s.queued[kept] = s.queued[i]
			kept += 1
		}
	}
	for i in kept ..< s.queued_count {
		s.queued[i] = nil
	}
	s.queued_count = kept
	if same(s.loop, clip) {
		s.loop, s.loop_pos = nil, 0
	}
}

notification_play :: proc(s: ^Notification_Sounds, kind: Sound_Event) {
	if clip := s.clips[kind]; clip != nil {
		queue(s, one_shot(clip))
	}
}

// notification_preview plays the sound of that name once, ahead of anything
// queued, to try it out.
notification_preview :: proc(s: ^Notification_Sounds, name: string) {
	old := s.preview
	s.preview = sound_acquire(name)
	if old != nil {
		forget(s, old)
		sound_release(old)
	}
	notifications_clear(s)
	if s.preview != nil {
		queue(s, one_shot(s.preview))
	}
}

// one_shot is what plays of a sound that isn't looped: at most
// ONE_SHOT_SECONDS of it.
@(private = "file")
one_shot :: proc(clip: ^Sound_Clip) -> []f32 {
	return clip.samples[:min(len(clip.samples), ONE_SHOT_SECONDS * SAMPLE_RATE * CHANNELS)]
}

@(private = "file")
queue :: proc(s: ^Notification_Sounds, clip: []f32) {
	if len(clip) == 0 {
		return
	}
	if len(s.active) == 0 {
		s.active = clip
		s.position = 0
		return
	}
	if s.queued_count < len(s.queued) {
		s.queued[s.queued_count] = clip
		s.queued_count += 1
	} else {
		// During a burst, keep the earlier events but replace the last one
		// with the newest.
		s.queued[len(s.queued) - 1] = clip
	}
}

// notification_loop starts playing an event's sound repeatedly, from its
// start unless that event is already looping. Passing .None stops the loop.
notification_loop :: proc(s: ^Notification_Sounds, kind: Sound_Event) {
	if kind == s.loop_event {
		return
	}
	s.loop_event = kind
	s.loop, s.loop_pos = nil, 0
	if clip := s.clips[kind]; clip != nil && kind != .None {
		s.loop = clip.samples
	}
}

notifications_mix :: proc(s: ^Notification_Sounds, mix: []f32) {
	if len(s.loop) > 0 {
		for &m in mix {
			if !s.loop_quiet {
				m += s.loop[s.loop_pos] * s.volume
			}
			s.loop_pos = (s.loop_pos + 1) % len(s.loop)
		}
	}
	at := 0
	for at < len(mix) {
		if len(s.active) == 0 {
			if s.queued_count == 0 {
				return
			}
			s.active = s.queued[0]
			s.position = 0
			s.queued_count -= 1
			for i in 0 ..< s.queued_count {
				s.queued[i] = s.queued[i + 1]
			}
			s.queued[s.queued_count] = nil
		}
		count := min(len(mix) - at, len(s.active) - s.position)
		for i in 0 ..< count {
			mix[at + i] += s.active[s.position + i] * s.volume
		}
		at += count
		s.position += count
		if s.position == len(s.active) {
			s.active = nil
			s.position = 0
		}
	}
}

decode_ogg_opus :: proc(data: []u8, name: string) -> []f32 {
	pcm := make([dynamic]f32)
	err: opus.Error
	decoder := opus.decoder_create(SAMPLE_RATE, CHANNELS, &err)
	if decoder == nil {
		log.errorf(
			"opus: could not create decoder for %s notification: %s",
			name,
			opus.strerror(err),
		)
		return nil
	}
	defer opus.decoder_destroy(decoder)

	packet: [dynamic]u8
	defer delete(packet)
	at := 0
	packet_count := 0
	pre_skip := 0
	for at < len(data) {
		if at + 27 > len(data) ||
		   data[at] != 'O' ||
		   data[at + 1] != 'g' ||
		   data[at + 2] != 'g' ||
		   data[at + 3] != 'S' {
			log.errorf("opus: invalid Ogg page in %s notification", name)
			delete(pcm)
			return nil
		}
		segments := int(data[at + 26])
		lacing_at := at + 27
		body_at := lacing_at + segments
		if body_at > len(data) {
			log.errorf("opus: truncated Ogg page in %s notification", name)
			delete(pcm)
			return nil
		}
		body_end := body_at
		for i in 0 ..< segments {
			body_end += int(data[lacing_at + i])
		}
		if body_end > len(data) {
			log.errorf("opus: truncated Ogg packet in %s notification", name)
			delete(pcm)
			return nil
		}
		for i in 0 ..< segments {
			count := int(data[lacing_at + i])
			append(&packet, ..data[body_at:body_at + count])
			body_at += count
			if count == 255 {
				continue
			}
			switch packet_count {
			case 0:
				// Accept version 1 with mono or stereo. The decoder outputs
				// stereo either way.
				if len(packet) < 19 ||
				   string(packet[:8]) != "OpusHead" ||
				   packet[8] != 1 ||
				   packet[9] < 1 ||
				   packet[9] > 2 {
					log.errorf("opus: invalid Opus header in %s notification", name)
					delete(pcm)
					return nil
				}
				pre_skip = int(endian.unchecked_get_u16le(packet[10:]))
			case 1:
			// OpusTags contains no audio data.
			case:
				frame: [opus.MAX_FRAME_SAMPLES * CHANNELS]f32
				n := opus.decode_float(
					decoder,
					raw_data(packet[:]),
					i32(len(packet)),
					&frame[0],
					opus.MAX_FRAME_SAMPLES,
					0,
				)
				if n < 0 {
					log.errorf(
						"opus: could not decode %s notification: %s",
						name,
						opus.strerror(opus.Error(n)),
					)
					delete(pcm)
					return nil
				}
				skip := min(pre_skip, int(n))
				pre_skip -= skip
				for sample in frame[skip * CHANNELS:int(n) * CHANNELS] {
					append(&pcm, sample)
				}
			}
			packet_count += 1
			clear(&packet)
		}
		at = body_end
	}
	if packet_count < 3 || len(pcm) == 0 {
		log.errorf("opus: no audio in %s notification", name)
		delete(pcm)
		return nil
	}
	return pcm[:]
}

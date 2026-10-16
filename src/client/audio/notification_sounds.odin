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
	same :: proc(p: Playing, clip: ^Sound_Clip) -> bool {
		a := p.samples
		return len(a) > 0 && raw_data(a) >= raw_data(clip.samples) &&
			raw_data(a) < raw_data(clip.samples[len(clip.samples):])
	}
	if same(s.active, clip) {
		s.active, s.position = {}, 0
	}
	kept := 0
	for i in 0 ..< s.queued_count {
		if !same(s.queued[i], clip) {
			s.queued[kept] = s.queued[i]
			kept += 1
		}
	}
	for i in kept ..< s.queued_count {
		s.queued[i] = {}
	}
	s.queued_count = kept
	if same(s.loop, clip) {
		s.loop, s.loop_pos = {}, 0
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
one_shot :: proc(clip: ^Sound_Clip) -> Playing {
	limit := ONE_SHOT_SECONDS * SAMPLE_RATE * clip.channels
	return {clip.samples[:min(len(clip.samples), limit)], clip.channels}
}

@(private = "file")
queue :: proc(s: ^Notification_Sounds, p: Playing) {
	if len(p.samples) == 0 {
		return
	}
	if len(s.active.samples) == 0 {
		s.active = p
		s.position = 0
		return
	}
	if s.queued_count < len(s.queued) {
		s.queued[s.queued_count] = p
		s.queued_count += 1
	} else {
		// During a burst, keep the earlier events but replace the last one
		// with the newest.
		s.queued[len(s.queued) - 1] = p
	}
}

// notification_loop starts playing an event's sound repeatedly, from its
// start unless that event is already looping. Passing .None stops the loop.
notification_loop :: proc(s: ^Notification_Sounds, kind: Sound_Event) {
	if kind == s.loop_event {
		return
	}
	s.loop_event = kind
	s.loop, s.loop_pos = {}, 0
	if clip := s.clips[kind]; clip != nil && kind != .None {
		s.loop = {clip.samples, clip.channels}
	}
}

// notifications_mix adds the sounds to `mix` (CHANNELS interleaved). A mono
// sound goes to every channel.
notifications_mix :: proc(s: ^Notification_Sounds, mix: []f32) {
	frames := len(mix) / CHANNELS
	if loop := s.loop; len(loop.samples) > 0 {
		for f in 0 ..< frames {
			if !s.loop_quiet {
				for c in 0 ..< CHANNELS {
					mix[f * CHANNELS + c] += loop.samples[s.loop_pos + min(c, loop.channels - 1)] * s.volume
				}
			}
			s.loop_pos = (s.loop_pos + loop.channels) % len(loop.samples)
		}
	}
	at := 0 // frames
	for at < frames {
		if len(s.active.samples) == 0 {
			if s.queued_count == 0 {
				return
			}
			s.active = s.queued[0]
			s.position = 0
			s.queued_count -= 1
			for i in 0 ..< s.queued_count {
				s.queued[i] = s.queued[i + 1]
			}
			s.queued[s.queued_count] = {}
		}
		a := s.active
		count := min(frames - at, (len(a.samples) - s.position) / a.channels)
		for i in 0 ..< count {
			for c in 0 ..< CHANNELS {
				mix[(at + i) * CHANNELS + c] +=
					a.samples[s.position + i * a.channels + min(c, a.channels - 1)] * s.volume
			}
		}
		at += count
		s.position += count * a.channels
		if s.position + a.channels > len(a.samples) {
			s.active = {}
			s.position = 0
		}
	}
}

// decode_ogg_opus decodes an Ogg Opus file, with its own channel count (1 or
// 2). The samples are allocated once, as many as the stream says it has (its
// last granule position), rather than grown while decoding.
decode_ogg_opus :: proc(data: []u8, name: string) -> (samples: []f32, channels: int) {
	// The last granule position: how many samples (at 48 kHz, whatever the
	// stream was made from) the stream ends at, pre-skip included.
	last_granule := 0
	for at := 0; at + 27 <= len(data) && string(data[at:at + 4]) == "OggS"; {
		if granule := i64(endian.unchecked_get_u64le(data[at + 6:])); granule > 0 {
			last_granule = int(granule)
		}
		segments := int(data[at + 26])
		next := at + 27 + segments
		if next > len(data) {
			break
		}
		for i in 0 ..< segments {
			next += int(data[at + 27 + i])
		}
		at = next
	}

	decoder: ^opus.Decoder
	defer if decoder != nil {
		opus.decoder_destroy(decoder)
	}
	fail :: proc(samples: []f32, why, name: string) -> ([]f32, int) {
		log.errorf("opus: %s in %s", why, name)
		delete(samples)
		return nil, 0
	}
	filled := 0
	packet: [dynamic]u8
	defer delete(packet)
	at := 0
	packet_count := 0
	pre_skip := 0
	for at < len(data) {
		if at + 27 > len(data) || string(data[at:at + 4]) != "OggS" {
			return fail(samples, "invalid Ogg page", name)
		}
		segments := int(data[at + 26])
		lacing_at := at + 27
		body_at := lacing_at + segments
		if body_at > len(data) {
			return fail(samples, "truncated Ogg page", name)
		}
		body_end := body_at
		for i in 0 ..< segments {
			body_end += int(data[lacing_at + i])
		}
		if body_end > len(data) {
			return fail(samples, "truncated Ogg packet", name)
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
				// Version 1, mono or stereo.
				if len(packet) < 19 ||
				   string(packet[:8]) != "OpusHead" ||
				   packet[8] != 1 ||
				   packet[9] < 1 ||
				   packet[9] > 2 {
					return fail(samples, "invalid Opus header", name)
				}
				channels = int(packet[9])
				pre_skip = int(endian.unchecked_get_u16le(packet[10:]))
				err: opus.Error
				decoder = opus.decoder_create(SAMPLE_RATE, i32(channels), &err)
				if decoder == nil {
					log.errorf("opus: could not create a decoder for %s: %s", name, opus.strerror(err))
					return nil, 0
				}
				samples = make([]f32, max(last_granule - pre_skip, 0) * channels)
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
					return fail(samples, string(opus.strerror(opus.Error(n))), name)
				}
				skip := min(pre_skip, int(n))
				pre_skip -= skip
				// The last packet decodes past the end of the stream.
				decoded := frame[skip * channels:int(n) * channels]
				filled += copy(samples[filled:], decoded)
			}
			packet_count += 1
			clear(&packet)
		}
		at = body_end
	}
	if packet_count < 3 || filled == 0 {
		return fail(samples, "no audio", name)
	}
	return samples[:filled], channels
}

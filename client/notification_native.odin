#+build !wasi
package client

import log "../common/wlog"
import "core:encoding/endian"

import "opus"

@(private = "file")
JOIN_SOUND_DATA := #load("assets/join.opus")

@(private = "file")
LEAVE_SOUND_DATA := #load("assets/leave.opus")

@(private = "file")
MESSAGE_SOUND_DATA := #load("assets/msg.opus")

notifications_init :: proc(s: ^Notification_Sounds) {
	s.volume = 1
	s.join = decode_ogg_opus(JOIN_SOUND_DATA, "join")
	s.leave = decode_ogg_opus(LEAVE_SOUND_DATA, "leave")
	s.message = decode_ogg_opus(MESSAGE_SOUND_DATA, "message")
}

notifications_destroy :: proc(s: ^Notification_Sounds) {
	delete(s.join)
	delete(s.leave)
	delete(s.message)
	s^ = {}
}

notification_play :: proc(s: ^Notification_Sounds, kind: Notification_Kind) {
	clip: []f32
	switch kind {
	case .Join:
		clip = s.join
	case .Leave:
		clip = s.leave
	case .Message:
		clip = s.message
	}
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
		// Preserve earlier events, but keep the newest one during a burst.
		s.queued[len(s.queued) - 1] = clip
	}
}

notifications_mix :: proc(s: ^Notification_Sounds, mix: []f32) {
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

@(private = "file")
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
				if len(packet) < 19 || string(packet[:8]) != "OpusHead" || packet[9] != 1 {
					log.errorf("opus: invalid Opus header in %s notification", name)
					delete(pcm)
					return nil
				}
				pre_skip = int(endian.unchecked_get_u16le(packet[10:]))
			case 1:
			// OpusTags has no audio data.
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

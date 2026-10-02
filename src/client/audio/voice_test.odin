#+build !wasi
package audio

import "core:math"
import "core:sync"
import "core:testing"

import "client:audio/opus"

// Plays one speaker's tone through the receive path (decode -> jitter
// queue -> mix) at the given gain and returns the output level.
@(private = "file")
played_level :: proc(t: ^testing.T, gain: f32, set_gain: bool, deafened := false) -> f64 {
	v: Voice
	testing.expect(t, voice_init(&v))
	defer voice_destroy(&v)
	sync.atomic_store(&v.output, true)
	v.deafened = deafened
	if set_gain {
		// User 42 is account 7's; gains are looked up by account.
		v.user_accounts[42] = 7
		v.gains[7] = gain
	}

	err: opus.Error
	enc := opus.encoder_create(SAMPLE_RATE, 1, .VOIP, &err)
	defer opus.encoder_destroy(enc)

	sum: f64
	count: int
	out: [FRAME]f32
	for f in 0 ..< 50 {
		pcm: [FRAME_SAMPLES]f32
		for &s, i in pcm {
			s = f32(0.3 * math.sin(2 * math.PI * 440 * f64(f * FRAME_SAMPLES + i) / SAMPLE_RATE))
		}
		packet: [opus.MAX_PACKET_SIZE]u8
		n := opus.encode_float(enc, &pcm[0], FRAME_SAMPLES, &packet[0], len(packet))
		voice_receive(&v, 42, u32(f), packet[:n])
		voice_step(&v)
		// Stand in for the output device: take one frame per frame sent.
		got := ring_read(&v.playback, out[:])
		if f >= 25 {
			for s in out[:got] {
				sum += f64(s * s)
			}
			count += got
		}
	}
	return math.sqrt(sum / f64(max(count, 1)))
}

@(test)
test_user_gain :: proc(t: ^testing.T) {
	normal := played_level(t, 1, false)
	testing.expectf(t, normal > 0.15, "tone not played (level %.3f)", normal)

	half := played_level(t, 0.5, true)
	testing.expectf(
		t,
		abs(half / normal - 0.5) < 0.02,
		"half volume gave %.3f of normal",
		half / normal,
	)

	muted := played_level(t, 0, true)
	testing.expect_value(t, muted, 0)
}

// Deafened plays nothing, whatever the per-user gains say.
@(test)
test_deafen :: proc(t: ^testing.T) {
	normal := played_level(t, 1, false)
	testing.expectf(t, normal > 0.15, "tone not played (level %.3f)", normal)

	deafened := played_level(t, 1, false, true)
	testing.expect_value(t, deafened, 0)
}

@(test)
test_notification_sounds :: proc(t: ^testing.T) {
	v: Voice
	testing.expect(t, voice_init(&v))
	defer voice_destroy(&v)
	testing.expect(t, len(v.notifications.join) > 0)
	testing.expect(t, len(v.notifications.leave) > 0)
	testing.expect(t, len(v.notifications.message) > 0)
	testing.expect(t, len(v.notifications.welcome) > 0)
	testing.expect(t, len(v.notifications.goodbye) > 0)
	testing.expect(t, len(v.notifications.muted) > 0)
	testing.expect(t, len(v.notifications.unmuted) > 0)
	testing.expect(t, len(v.notifications.ring) > 0)
	testing.expect(t, len(v.notifications.ringback) > 0)

	for kind in Notification_Kind {
		notification_play(&v.notifications, kind)
		sum: f64
		count := 0
		for len(v.notifications.active) > 0 || v.notifications.queued_count > 0 {
			mix_output(&v)
			out: [FRAME]f32
			got := ring_read(&v.playback, out[:])
			for sample in out[:got] {
				sum += f64(sample * sample)
			}
			count += got
		}
		testing.expectf(t, count > 0 && sum > 0, "%v notification was silent", kind)
	}
}

@(test)
test_notification_tail :: proc(t: ^testing.T) {
	v: Voice
	testing.expect(t, voice_init(&v))
	defer voice_destroy(&v)
	notification_play(&v.notifications, .Goodbye)
	notification_tail_step(&v)
	testing.expect(t, !notifications_pending(&v.notifications))
	testing.expect(t, ring_available(&v.playback) > 0)
}

@(test)
test_notification_volume :: proc(t: ^testing.T) {
	clip := []f32{0.8, -0.4}
	sounds := Notification_Sounds {
		active = clip,
		volume = 0.25,
	}
	mix: [2]f32
	notifications_mix(&sounds, mix[:])
	testing.expect_value(t, mix, [2]f32{0.2, -0.1})
}

@(test)
test_deafen_suppresses_notifications :: proc(t: ^testing.T) {
	v: Voice
	testing.expect(t, voice_init(&v))
	defer voice_destroy(&v)
	v.deafened = true
	voice_notification_play(&v, .Message)
	testing.expect_value(t, len(v.notifications.active), 0)
	testing.expect_value(t, v.notifications.queued_count, 0)
	v.deafened = false
	voice_notification_play(&v, .Message)
	testing.expect(t, len(v.notifications.active) > 0)
	v.deafened = true
	mix_output(&v)
	testing.expect_value(t, len(v.notifications.active), 0)
	testing.expect_value(t, v.notifications.queued_count, 0)
}

// Deafening drops what's playing, but not the sound saying we deafened.
@(test)
test_deafen_keeps_feedback :: proc(t: ^testing.T) {
	v: Voice
	testing.expect(t, voice_init(&v))
	defer voice_destroy(&v)
	voice_notification_play(&v, .Message)
	voice_feedback_play(&v, true)
	v.deafened = true
	mix_output(&v)
	testing.expect(t, raw_data(v.notifications.active) == raw_data(v.notifications.muted))
	testing.expect_value(t, v.notifications.queued_count, 0)
}

@(test)
test_listen_back :: proc(t: ^testing.T) {
	v: Voice
	testing.expect(t, voice_init(&v))
	defer voice_destroy(&v)

	frame: [FRAME]f32
	for &s in frame {
		s = 0.5
	}
	out: [FRAME]f32
	level :: proc(x: []f32) -> f32 {
		sum: f32
		for s in x {
			sum += s * s
		}
		return sum / f32(len(x))
	}

	// Off: nothing is queued or played.
	listen_feed(&v, frame[:], true)
	mix_output(&v)
	ring_read(&v.playback, out[:])
	testing.expect_value(t, level(out[:]), 0)

	// On: frames that would be sent are played back (after the prefill),
	// frames the gate holds back are played as silence.
	ring_skip(&v.playback, ring_available(&v.playback)) // silence mixed while off
	v.listen = true
	for _ in 0 ..< 3 {
		listen_feed(&v, frame[:], true)
	}
	listen_feed(&v, frame[:], false)
	played: [4]f32
	for i in 0 ..< 4 {
		mix_output(&v)
		ring_read(&v.playback, out[:])
		played[i] = level(out[:])
	}
	// Exactly what was fed comes out, in order: three frames as captured,
	// then the gated one as silence.
	testing.expectf(
		t,
		played[0] > 0.2 && played[1] > 0.2 && played[2] > 0.2 && played[3] == 0,
		"listen back played %v",
		played,
	)

	// Switching off drops what was queued.
	v.listen = false
	listen_feed(&v, frame[:], true)
	mix_output(&v)
	testing.expect_value(t, ring_available(&v.loopback), 0)
}

@(test)
test_stereo_end_to_end :: proc(t: ^testing.T) {
	// A Music (stereo) sender with a tone on the left only: the receiver
	// must play it on the left only.
	sender: Voice
	testing.expect(t, voice_init(&sender))
	defer voice_destroy(&sender)
	testing.expect(t, encoder_setup(&sender, .Music))

	v: Voice
	testing.expect(t, voice_init(&v))
	defer voice_destroy(&v)
	sync.atomic_store(&v.output, true)

	left, right: f64
	for f in 0 ..< 50 {
		frame: [FRAME]f32
		for i in 0 ..< FRAME_SAMPLES {
			frame[i * CHANNELS] = f32(
				0.3 * math.sin(2 * math.PI * 440 * f64(f * FRAME_SAMPLES + i) / SAMPLE_RATE),
			)
		}
		_, pass := mic_process(&sender, frame[:]) // no suppression; gate off
		testing.expect(t, pass)
		packet: [opus.MAX_PACKET_SIZE]u8
		n := opus.encode_float(sender.encoder, &frame[0], FRAME_SAMPLES, &packet[0], len(packet))
		testing.expect(t, n > 0)
		testing.expect_value(t, opus.packet_get_nb_channels(&packet[0]), 2)

		voice_receive(&v, 7, u32(f), packet[:n])
		voice_step(&v)
		out: [FRAME]f32
		got := ring_read(&v.playback, out[:])
		if f >= 25 {
			for i := 0; i + 1 < got; i += CHANNELS {
				left += f64(out[i] * out[i])
				right += f64(out[i + 1] * out[i + 1])
			}
		}
	}
	testing.expectf(t, left > 100 * right && left > 0, "left %.3f, right %.5f", left, right)
}

@(test)
test_mono_downmix :: proc(t: ^testing.T) {
	v: Voice
	testing.expect(t, voice_init(&v))
	defer voice_destroy(&v)
	testing.expect_value(t, QUALITY_PRESETS[v.quality].channels, 1)

	// Left at 1, right at 0: a mono preset sends (and listens back to)
	// the average on both channels, and measures its level.
	frame: [FRAME]f32
	for i in 0 ..< FRAME_SAMPLES {
		frame[i * CHANNELS] = 1
	}
	level, _ := mic_process(&v, frame[:])
	testing.expect_value(t, frame[0], 0.5)
	testing.expect_value(t, frame[1], 0.5)
	testing.expect(t, abs(level - (-6.0206)) < 0.01) // 20*log10(0.5)
}

@(test)
test_to_stereo :: proc(t: ^testing.T) {
	out: [4]f32 // two stereo frames

	// Mono: duplicated to both sides (not left only).
	to_stereo([]f32{0.5, -0.25}, 1, out[:])
	testing.expect_value(t, out, [4]f32{0.5, 0.5, -0.25, -0.25})

	// Stereo: unchanged.
	to_stereo([]f32{0.1, 0.2, 0.3, 0.4}, 2, out[:])
	testing.expect_value(t, out, [4]f32{0.1, 0.2, 0.3, 0.4})

	// More channels: the first two of each frame.
	to_stereo([]f32{0.1, 0.2, 9, 9, 0.3, 0.4, 9, 9}, 4, out[:])
	testing.expect_value(t, out, [4]f32{0.1, 0.2, 0.3, 0.4})
}

@(test)
test_ring_loops :: proc(t: ^testing.T) {
	s: Notification_Sounds
	notifications_init(&s)
	defer notifications_destroy(&s)

	energy :: proc(s: ^Notification_Sounds, samples: int) -> f64 {
		mix := make([]f32, samples, context.temp_allocator)
		notifications_mix(s, mix)
		sum: f64
		for v in mix {
			sum += f64(v * v)
		}
		return sum
	}
	// Ringing: it goes on past its own length, from the start again.
	notification_loop(&s, .Ring)
	testing.expect(t, energy(&s, len(s.ring)) > 0)
	testing.expect(t, energy(&s, len(s.ring) / 2) > 0, "the ring didn't start again")
	// The same again doesn't start it over; another does.
	at := s.loop_pos
	notification_loop(&s, .Ring)
	testing.expect_value(t, s.loop_pos, at)
	notification_loop(&s, .Ringback)
	testing.expect_value(t, s.loop_pos, 0)
	// Deafened, it's quiet; stopped, it's gone.
	s.loop_quiet = true
	testing.expect_value(t, energy(&s, 4800), 0)
	s.loop_quiet = false
	notification_loop(&s, .None)
	testing.expect_value(t, energy(&s, 4800), 0)
}

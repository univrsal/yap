#+build !wasi
package client

import "core:math"
import "core:os"
import "core:sync"
import "core:testing"

import "../proto"
import "opus"

@(private = "file")
SPEAKER_KEY :: [proto.KEY_SIZE]u8 {
	0  = 0x42,
	31 = 0x42,
}

// Plays one speaker's tone through the receive path (decode -> jitter
// queue -> mix) at the given gain and returns the output level.
@(private = "file")
played_level :: proc(t: ^testing.T, gain: f32, set_gain: bool, deafened := false) -> f64 {
	c := new(Voice_Client, context.temp_allocator)
	testing.expect(t, voice_init(&c.voice))
	defer voice_destroy(&c.voice)
	sync.atomic_store(&c.voice.output, true)
	c.voice.deafened = deafened
	if set_gain {
		// User 42 is known by key; gains are looked up by key.
		c.voice.user_keys[42] = SPEAKER_KEY
		c.voice.gains[SPEAKER_KEY] = gain
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
		voice_receive(c, 42, u32(f), packet[:n])
		voice_step(c)
		// Stand in for the output device: take one frame per frame sent.
		got := ring_read(&c.voice.playback, out[:])
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

	for i in 0 ..< 5 {
		kind := Notification_Kind(i)
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

@(test)
test_settings_roundtrip :: proc(t: ^testing.T) {
	path := "yap-settings-test.json"
	defer os.remove(path)

	alice := [proto.KEY_SIZE]u8 {
		0  = 0x8e,
		1  = 0x41,
		31 = 1,
	}
	bob := [proto.KEY_SIZE]u8 {
		0  = 0xab,
		31 = 2,
	}
	carol := [proto.KEY_SIZE]u8 {
		0  = 0x11,
		31 = 3,
	}

	s := DEFAULT_SETTINGS
	defer settings_destroy(&s)
	set_setting(&s.server, "localhost:7777")
	set_setting(&s.name, "me")
	s.notification_volume = 0.5
	set_user_settings(&s, alice, {volume = 0.5})
	set_user_settings(&s, bob, {volume = 1, muted = true})
	set_user_settings(&s, carol, {volume = 1.5})
	set_user_settings(&s, carol, DEFAULT_USER) // back to default: not stored
	settings_save(path, s)

	loaded := settings_load(path)
	defer settings_destroy(&loaded)
	testing.expect_value(t, loaded.server, "localhost:7777")
	testing.expect_value(t, loaded.name, "me")
	testing.expect_value(t, loaded.noise_suppression, true)
	testing.expect_value(t, notification_gain(&loaded), f32(0.5))
	testing.expect_value(t, len(loaded.users), 2)
	testing.expect_value(t, user_settings(&loaded, alice), User_Settings{volume = 0.5})
	testing.expect_value(t, user_settings(&loaded, bob), User_Settings{volume = 1, muted = true})
	testing.expect_value(t, user_settings(&loaded, carol), DEFAULT_USER)
	testing.expect_value(t, user_gain(user_settings(&loaded, bob)), 0)
	// Entries are keyed by the full key, and parse back to it.
	for hex_key in loaded.users {
		key, ok := parse_user_key(hex_key)
		testing.expect(t, ok && (key == alice || key == bob))
	}
	_, legacy_ok := parse_user_key("8e41fa62") // the old 4-byte ids
	testing.expect(t, !legacy_ok)
}

@(test)
test_display_names :: proc(t: ^testing.T) {
	users := []proto.User_Info {
		{num = 1, key = {0 = 0xaa, 1 = 0xbb, 2 = 0xcc, 3 = 0xdd}, name = "alice"},
		{num = 2, key = {0 = 0x11, 1 = 0x22, 2 = 0x33, 3 = 0x44}, name = "Bob"},
		{num = 3, key = {0 = 0x55, 1 = 0x66, 2 = 0x77, 3 = 0x88}, name = "bob"},
		{num = 4, key = {0 = 0x99, 1 = 0x00, 2 = 0x11, 3 = 0x22}, name = ""},
	}
	testing.expect_value(t, display_name(users, 1), "alice")
	// Same name (ignoring case): both get their key fingerprint.
	testing.expect_value(t, display_name(users, 2), "Bob (11223344)")
	testing.expect_value(t, display_name(users, 3), "bob (55667788)")
	testing.expect_value(t, display_name(users, 4), "99001122")
	testing.expect_value(t, display_name(users, 9), "user #9")
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

	c := new(Voice_Client, context.temp_allocator)
	testing.expect(t, voice_init(&c.voice))
	defer voice_destroy(&c.voice)
	sync.atomic_store(&c.voice.output, true)

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

		voice_receive(c, 7, u32(f), packet[:n])
		voice_step(c)
		out: [FRAME]f32
		got := ring_read(&c.voice.playback, out[:])
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

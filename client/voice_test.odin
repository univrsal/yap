package client

import "core:math"
import "core:os"
import "core:sync"
import "core:testing"

import "opus"

// Plays one speaker's tone through the receive path (decode -> jitter
// queue -> mix) at the given gain and returns the output level.
@(private = "file")
played_level :: proc(t: ^testing.T, gain: f32, set_gain: bool) -> f64 {
	c := new(Voice_Client, context.temp_allocator)
	testing.expect(t, voice_init(&c.voice))
	defer voice_destroy(&c.voice)
	sync.atomic_store(&c.voice.output, true)
	if set_gain {
		c.voice.gains[42] = gain
	}

	err: opus.Error
	enc := opus.encoder_create(SAMPLE_RATE, 1, .VOIP, &err)
	defer opus.encoder_destroy(enc)

	sum: f64
	count: int
	out: [FRAME_SAMPLES]f32
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

@(test)
test_settings_roundtrip :: proc(t: ^testing.T) {
	path := "yap-settings-test.json"
	defer os.remove(path)

	s := DEFAULT_SETTINGS
	defer settings_destroy(&s)
	set_setting(&s.server, "localhost:7777")
	set_user_settings(&s, 0x8e41fa62, {volume = 0.5})
	set_user_settings(&s, 0x0000abcd, {volume = 1, muted = true})
	set_user_settings(&s, 0x11111111, {volume = 1.5})
	set_user_settings(&s, 0x11111111, DEFAULT_USER) // back to default: not stored
	settings_save(path, s)

	loaded := settings_load(path)
	defer settings_destroy(&loaded)
	testing.expect_value(t, loaded.server, "localhost:7777")
	testing.expect_value(t, loaded.noise_suppression, true)
	testing.expect_value(t, len(loaded.users), 2)
	testing.expect_value(t, user_settings(&loaded, 0x8e41fa62), User_Settings{volume = 0.5})
	testing.expect_value(
		t,
		user_settings(&loaded, 0x0000abcd),
		User_Settings{volume = 1, muted = true},
	)
	testing.expect_value(t, user_settings(&loaded, 0x11111111), DEFAULT_USER)
	testing.expect_value(t, user_gain(user_settings(&loaded, 0x0000abcd)), 0)
}

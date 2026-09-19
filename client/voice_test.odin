package client

import "core:math"
import "core:os"
import "core:sync"
import "core:testing"

import "../proto"
import "opus"

@(private = "file")
SPEAKER_KEY :: [proto.KEY_SIZE]u8{0 = 0x42, 31 = 0x42}

// Plays one speaker's tone through the receive path (decode -> jitter
// queue -> mix) at the given gain and returns the output level.
@(private = "file")
played_level :: proc(t: ^testing.T, gain: f32, set_gain: bool) -> f64 {
	c := new(Voice_Client, context.temp_allocator)
	testing.expect(t, voice_init(&c.voice))
	defer voice_destroy(&c.voice)
	sync.atomic_store(&c.voice.output, true)
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

	alice := [proto.KEY_SIZE]u8{0 = 0x8e, 1 = 0x41, 31 = 1}
	bob := [proto.KEY_SIZE]u8{0 = 0xab, 31 = 2}
	carol := [proto.KEY_SIZE]u8{0 = 0x11, 31 = 3}

	s := DEFAULT_SETTINGS
	defer settings_destroy(&s)
	set_setting(&s.server, "localhost:7777")
	set_setting(&s.name, "me")
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

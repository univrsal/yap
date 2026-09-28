#+build !wasi
package client

import "core:math"
import "core:sync"
import "core:testing"

// A shared application is mixed in only while something's shared, once
// it has buffered up, at its volume.
@(test)
test_app_mix :: proc(t: ^testing.T) {
	v: Voice
	testing.expect(t, voice_init(&v))
	defer voice_destroy(&v)
	testing.expect(t, encoder_setup(&v, .Music)) // stereo

	app: [FRAME]f32
	for i := 0; i < FRAME; i += CHANNELS {
		app[i], app[i + 1] = 0.25, -0.25
	}
	frame: [FRAME]f32

	// Nothing shared: queued audio is dropped, the frame left alone.
	ring_write(&v.app, app[:])
	testing.expect(t, !app_mix(&v, frame[:]))
	testing.expect_value(t, ring_available(&v.app), 0)

	sync.atomic_store(&v.app_input, true)
	for _ in 0 ..< APP_PREFILL / FRAME - 1 {
		ring_write(&v.app, app[:])
	}
	testing.expect(t, !app_frame_ready(&v))
	testing.expect(t, !app_mix(&v, frame[:])) // still buffering
	ring_write(&v.app, app[:])
	testing.expect(t, app_frame_ready(&v))

	v.app_volume = 2
	for i := 0; i < FRAME; i += CHANNELS {
		frame[i], frame[i + 1] = 0.1, 0.8 // the microphone
	}
	testing.expect(t, app_mix(&v, frame[:]))
	testing.expect(t, abs(frame[0] - 0.6) < 1e-6)
	testing.expect(t, abs(frame[1] - 0.3) < 1e-6)
	testing.expect(t, v.app_playing)

	// Loud enough to clip: clamped, not wrapped.
	v.app_volume = 3
	frame = {}
	frame[0] = 0.5
	testing.expect(t, app_mix(&v, frame[:]))
	testing.expect_value(t, frame[0], 1)
}

// A mono preset sends the left channel, so the application's two sides
// are averaged into it, as the microphone's are.
@(test)
test_app_mix_mono :: proc(t: ^testing.T) {
	v: Voice
	testing.expect(t, voice_init(&v))
	defer voice_destroy(&v)
	testing.expect_value(t, QUALITY_PRESETS[v.quality].channels, 1)
	sync.atomic_store(&v.app_input, true)

	app: [FRAME]f32
	for i := 0; i < FRAME; i += CHANNELS {
		app[i] = 1
	}
	for _ in 0 ..< APP_PREFILL / FRAME {
		ring_write(&v.app, app[:])
	}
	frame: [FRAME]f32
	testing.expect(t, app_mix(&v, frame[:]))
	testing.expect_value(t, frame[0], 0.5)
	testing.expect_value(t, frame[1], 0.5)
}

// 44.1 kHz comes out at 48 kHz: as many frames as the time it covers,
// and a tone at the same pitch.
@(test)
test_app_resample :: proc(t: ^testing.T) {
	v: Voice
	testing.expect(t, voice_init(&v))
	defer voice_destroy(&v)
	s := App_Share {
		voice = &v,
		rate  = 44100,
	}

	// 100 ms in 441-frame chunks, a 1 kHz tone on both sides.
	HZ :: 1000
	for chunk in 0 ..< 10 {
		input: [441 * CHANNELS]f32
		for i in 0 ..< 441 {
			x := f32(math.sin(2 * math.PI * HZ * f64(chunk * 441 + i) / 44100))
			input[i * CHANNELS], input[i * CHANNELS + 1] = x, x
		}
		resample_write(&s, input[:])
	}
	frames := ring_available(&v.app) / CHANNELS
	testing.expectf(t, abs(frames - 4800) <= 1, "%d frames for 100 ms", frames)

	out: [4800 * CHANNELS]f32
	got := ring_read(&v.app, out[:]) / CHANNELS
	// Past the first frame (which starts from silence), each output frame
	// is the tone at its own time at 48 kHz.
	worst: f32
	for i in 1 ..< got {
		want := f32(math.sin(2 * math.PI * HZ * f64(i) / SAMPLE_RATE))
		worst = max(worst, abs(out[i * CHANNELS] - want), abs(out[i * CHANNELS + 1] - want))
	}
	testing.expectf(t, worst < 0.01, "off by up to %.4f", worst)
}

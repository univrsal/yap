#+build !wasi
package rnn

import "core:math"
import "core:math/rand"
import "core:testing"

@(private = "file")
rms :: proc(samples: []f32) -> f64 {
	sum: f64
	for s in samples {
		sum += f64(s) * f64(s)
	}
	return math.sqrt(sum / f64(len(samples)))
}

@(test)
test_removes_steady_noise :: proc(t: ^testing.T) {
	d, ok := denoiser_create()
	testing.expect(t, ok)
	defer denoiser_destroy(&d)

	// Three seconds of brown noise (a random walk; most of its energy is
	// low-frequency, like fans or hum) at about -30 dBFS, processed in our
	// 20 ms frames. RNNoise targets real background noise like this; it
	// does comparatively little to loud *white* noise.
	r := rand.create(1)
	gen := rand.default_random_generator(&r)
	SECONDS :: 3
	samples := make([]f32, SAMPLE_RATE * SECONDS, context.temp_allocator)
	walk: f32
	for &s in samples {
		walk = clamp(walk + f32(rand.float64_range(-0.02, 0.02, gen)), -1, 1)
		s = walk
	}
	scale := f32(0.03 / rms(samples))
	for &s in samples {
		s *= scale
	}
	before := rms(samples[SAMPLE_RATE:])

	max_voice: f32
	for start := 0; start < len(samples); start += 2 * FRAME_SIZE {
		voice := denoise(&d, samples[start:][:2 * FRAME_SIZE])
		if start >= SAMPLE_RATE {
			max_voice = max(max_voice, voice)
		}
	}
	// After a second to adapt, the noise should be at least 20 dB down and
	// not mistaken for voice.
	after := rms(samples[SAMPLE_RATE:])
	testing.expectf(t, after < before * 0.1, "noise only reduced from %.4f to %.4f", before, after)
	testing.expectf(t, max_voice < 0.5, "noise looked like voice (%.2f)", max_voice)
}

@(test)
test_silence_stays_silent :: proc(t: ^testing.T) {
	d, ok := denoiser_create()
	testing.expect(t, ok)
	defer denoiser_destroy(&d)

	frame: [2 * FRAME_SIZE]f32
	for _ in 0 ..< 50 {
		denoise(&d, frame[:])
	}
	testing.expect_value(t, rms(frame[:]), 0)
}

@(test)
test_independent_states :: proc(t: ^testing.T) {
	// Two denoisers fed the same input produce the same output, so they
	// don't share hidden state.
	a, _ := denoiser_create()
	defer denoiser_destroy(&a)
	b, _ := denoiser_create()
	defer denoiser_destroy(&b)

	r := rand.create(2)
	gen := rand.default_random_generator(&r)
	fa, fb: [FRAME_SIZE]f32
	for _ in 0 ..< 20 {
		for i in 0 ..< FRAME_SIZE {
			fa[i] = f32(rand.float64_range(-0.3, 0.3, gen))
			fb[i] = fa[i]
		}
		denoise(&a, fa[:])
		denoise(&b, fb[:])
		testing.expect_value(t, fa, fb)
	}
}

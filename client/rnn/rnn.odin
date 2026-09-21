/*
RNNoise noise suppression (see yap_rnn.c; the sources in ref/ are the
RNNoise that OBS Studio's noise filter uses, BSD-3-Clause, ref/COPYING).
Build the library with build.sh / build.bat at the repo root.

Use Denoiser rather than the raw procs: it takes our float samples in
[-1, 1] and any multiple of 10 ms.
*/
package rnn

import "core:sync"

when ODIN_OS == .Windows {
	@(private)
	LIB :: "yap_rnn.lib"
} else {
	@(private)
	LIB :: "libyap_rnn.a"
}

when ODIN_OS != .WASI {
	when !#exists(LIB) {
		#panic("client/rnn/" + LIB + " is missing; build it with build.sh (or build.bat on Windows)")
	}
}


SAMPLE_RATE :: 48000
// RNNoise works on 10 ms frames.
FRAME_SIZE :: 480

State :: struct {}


@(private)
init_once: sync.Once

Denoiser :: struct {
	state: ^State,
}

denoiser_create :: proc() -> (d: Denoiser, ok: bool) {
	sync.once_do(&init_once, proc() {global_init()})
	d.state = create()
	return d, d.state != nil
}

denoiser_destroy :: proc(d: ^Denoiser) {
	if d.state != nil {
		destroy(d.state)
		d.state = nil
	}
}

// denoise removes noise from 48 kHz mono samples in place. len(samples)
// must be a multiple of FRAME_SIZE. Returns the highest voice probability
// among its 10 ms frames.
denoise :: proc(d: ^Denoiser, samples: []f32) -> (voice: f32) {
	assert(len(samples) % FRAME_SIZE == 0, "denoise needs whole 10 ms frames")
	input, output: [FRAME_SIZE]f32
	for start := 0; start < len(samples); start += FRAME_SIZE {
		frame := samples[start:][:FRAME_SIZE]
		for s, i in frame {
			input[i] = s * 32768
		}
		voice = max(voice, process_frame(d.state, &output[0], &input[0]))
		for &s, i in frame {
			s = output[i] / 32768
		}
	}
	return
}

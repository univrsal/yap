package client

import "core:math"
import "core:time"

import "rnn"

/*
The voice gate: only send while the microphone is loud enough, so
silence and background noise cost nothing and nobody hears your room.

It's a level gate with two thresholds (hysteresis), measured on each 20 ms
frame after noise suppression (if that's on):

	level >= open_db                  opens
	close_db <= level < open_db       stays as it is
	level < close_db for HANGOVER     closes

The gap between the thresholds keeps it from flickering around a single
value, and the hangover keeps word endings and short pauses.

mic_process is shared by the network loop and the settings page's level
meter, so the meter shows exactly what the gate decides.
*/

GATE_HANGOVER :: 300 * time.Millisecond

// Defaults, from measurements with RNNoise on: speech comes out at about
// -35..-16 dBFS, background noise at -80..-65 dBFS.
DEFAULT_GATE_OPEN_DB :: -45
DEFAULT_GATE_CLOSE_DB :: -55

// Levels are clamped to this floor; also the left end of the meter.
MIN_LEVEL_DB :: -80

Gate :: struct {
	enabled:    bool,
	open_db:    f32,
	close_db:   f32,
	open:       bool,
	last_above: time.Tick, // last frame at or above close_db while open
}

// gate_update feeds one frame's level and returns whether to send it.
gate_update :: proc(g: ^Gate, level_db: f32, now: time.Tick) -> bool {
	switch {
	case level_db >= g.open_db:
		g.open = true
		g.last_above = now
	case g.open && level_db >= g.close_db:
		g.last_above = now
	case g.open && time.tick_diff(g.last_above, now) > GATE_HANGOVER:
		g.open = false
	}
	return g.open || !g.enabled
}

// mic_process runs one captured stereo frame (FRAME interleaved samples)
// through noise suppression and the gate, in place. Mono presets are
// downmixed first and written back to both channels, so the frame then
// holds exactly what will be sent (and what listen back plays). Returns
// the frame's level and whether to send it.
mic_process :: proc(v: ^Voice, frame: []f32) -> (level_db: f32, send: bool) {
	assert(len(frame) == FRAME)
	denoise := v.denoise && v.denoisers[0].state != nil

	if QUALITY_PRESETS[v.quality].channels == 1 {
		mono: [FRAME_SAMPLES]f32
		for &s, i in mono {
			s = (frame[i * CHANNELS] + frame[i * CHANNELS + 1]) / 2
		}
		// The denoiser runs on every frame, even unsent ones, so its
		// state follows the room continuously.
		if denoise {
			rnn.denoise(&v.denoisers[0], mono[:])
		}
		for s, i in mono {
			frame[i * CHANNELS], frame[i * CHANNELS + 1] = s, s
		}
		level_db = level_dbfs(mono[:])
	} else {
		if denoise {
			channel: [FRAME_SAMPLES]f32
			for c in 0 ..< CHANNELS {
				for &s, i in channel {
					s = frame[i * CHANNELS + c]
				}
				rnn.denoise(&v.denoisers[c], channel[:])
				for s, i in channel {
					frame[i * CHANNELS + c] = s
				}
			}
		}
		level_db = level_dbfs(frame)
	}
	send = gate_update(&v.gate, level_db, time.tick_now())
	return
}

// level_dbfs is the RMS level of `samples` in dB relative to full scale.
level_dbfs :: proc(samples: []f32) -> f32 {
	sum: f32
	for s in samples {
		sum += s * s
	}
	rms := math.sqrt(sum / f32(max(len(samples), 1)))
	return max(20 * math.log10(max(rms, 1e-9)), MIN_LEVEL_DB)
}

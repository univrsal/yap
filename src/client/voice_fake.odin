#+build !wasi
package client

import log "../common/wlog"
import "core:math"
import "core:sync"
import "core:thread"
import "core:time"

/*
Fake audio for headless testing: one thread writes a sine tone, or a
looped recording, into the capture ring in real time (like a microphone
would), another drains the
playback ring in real time (like speakers would) and logs what it heard
each second: loudness, and the dominant frequency from zero crossings.
*/
Fake_Audio :: struct {
	voice:   ^Voice,
	tone_hz: f32,
	input:   []f32, // if set, looped instead of the tone
	stop:    bool, // atomic
	source:  ^thread.Thread,
	sink:    ^thread.Thread,
	heard:   Sink_Stats, // sink thread only
}

fake_audio_start :: proc(f: ^Fake_Audio, v: ^Voice, tone_hz: f32, input: []f32 = nil) {
	f.voice = v
	f.tone_hz = tone_hz
	f.input = input
	sync.atomic_store(&v.input, true)
	sync.atomic_store(&v.output, true)
	f.source = thread.create_and_start_with_poly_data(f, fake_source, init_context = context)
	f.sink = thread.create_and_start_with_poly_data(f, fake_sink, init_context = context)
}

fake_audio_stop :: proc(f: ^Fake_Audio) {
	if f.source == nil {
		return
	}
	sync.atomic_store(&f.stop, true)
	for t in ([]^thread.Thread{f.source, f.sink}) {
		thread.join(t)
		thread.destroy(t)
	}
	f.source, f.sink = nil, nil
	sync.atomic_store(&f.voice.input, false)
	sync.atomic_store(&f.voice.output, false)
}

// Runs `tick` every DEVICE_PERIOD_MS, on a fixed schedule like a device.
@(private = "file")
run_periodic :: proc(f: ^Fake_Audio, tick: proc(f: ^Fake_Audio, samples: []f32, n: int)) {
	PERIOD :: SAMPLE_RATE * DEVICE_PERIOD_MS / 1000
	buf: [PERIOD * CHANNELS]f32 // interleaved, like a device's buffer
	next := time.tick_now()
	n := 0
	for !sync.atomic_load(&f.stop) {
		tick(f, buf[:], n)
		n += 1
		next = time.tick_add(next, DEVICE_PERIOD_MS * time.Millisecond)
		if wait := time.tick_diff(time.tick_now(), next); wait > 0 {
			time.sleep(wait)
		}
	}
}

@(private = "file")
fake_source :: proc(f: ^Fake_Audio) {
	run_periodic(f, proc(f: ^Fake_Audio, buf: []f32, n: int) {
		// The tone and input files are mono: the same on both channels.
		frames := len(buf) / CHANNELS
		for i in 0 ..< frames {
			pos := n * frames + i
			s: f32
			if len(f.input) > 0 {
				s = f.input[pos % len(f.input)]
			} else {
				s = f32(0.3 * math.sin(2 * math.PI * f64(f.tone_hz) * f64(pos) / SAMPLE_RATE))
			}
			for c in 0 ..< CHANNELS {
				buf[i * CHANNELS + c] = s
			}
		}
		ring_write(&f.voice.capture, buf)
	})
}

Sink_Stats :: struct {
	sum_sq:    f64,
	samples:   int,
	crossings: int,
	last:      f32,
}

@(private = "file")
fake_sink :: proc(f: ^Fake_Audio) {
	run_periodic(f, proc(f: ^Fake_Audio, buf: []f32, n: int) {
		got := ring_read(&f.voice.playback, buf)
		for &s in buf[got:] {
			s = 0
		}
		if got < len(buf) {
			sync.atomic_add(&f.voice.underruns, 1)
		}
		// Measure the left channel.
		stats := &f.heard
		for i := 0; i < len(buf); i += CHANNELS {
			s := buf[i]
			stats.sum_sq += f64(s * s)
			if (s >= 0) != (stats.last >= 0) {
				stats.crossings += 1
			}
			stats.last = s
		}
		stats.samples += len(buf) / CHANNELS
		if stats.samples >= SAMPLE_RATE {
			rms := math.sqrt(stats.sum_sq / f64(stats.samples))
			seconds := f64(stats.samples) / SAMPLE_RATE
			if rms > 0.01 {
				log.infof("heard: level %.3f, ~%.0f Hz", rms, f64(stats.crossings) / 2 / seconds)
			} else {
				log.infof("heard: silence")
			}
			stats^ = {}
		}
	})
}

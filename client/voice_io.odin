package client

import "core:log"
import "core:math"
import "core:sync"
import "core:thread"
import "core:time"

import ma "miniaudio"

/*
The ends of the voice pipeline: real audio devices (UI), or a generated
tone and a measuring sink (headless -tone, for testing without a
microphone or speakers). Either way they only touch the Voice's rings.
*/

// Device period: how much audio each callback handles.
DEVICE_PERIOD_MS :: 10

// Audio_Streams are the open devices for one connection.
Audio_Streams :: struct {
	capture:  ^ma.Stream,
	playback: ^ma.Stream,
}

// The callbacks run on miniaudio's audio threads and must never block,
// so they only move samples through the lock-free rings.

@(private = "file")
capture_callback :: proc "c" (user: rawptr, samples: [^]f32, frame_count: u32) {
	v := (^Voice)(user)
	ring_write(&v.capture, samples[:frame_count]) // on overflow, the newest audio is dropped
}

@(private = "file")
playback_callback :: proc "c" (user: rawptr, samples: [^]f32, frame_count: u32) {
	v := (^Voice)(user)
	if ring_read(&v.playback, samples[:frame_count]) < int(frame_count) {
		// The rest stays silent (the buffer starts zeroed).
		sync.atomic_add(&v.underruns, 1)
	}
}

// open_capture opens the named input device ("" or missing: the system
// default) and starts feeding the Voice.
open_capture :: proc(a: ^Audio, s: ^Audio_Streams, v: ^Voice, device: string) {
	close_capture(s, v)
	s.capture = open_stream(a, .Capture, a.inputs[:], device, v, capture_callback)
	sync.atomic_store(&v.input, s.capture != nil)
}

open_playback :: proc(a: ^Audio, s: ^Audio_Streams, v: ^Voice, device: string) {
	close_playback(s, v)
	s.playback = open_stream(a, .Playback, a.outputs[:], device, v, playback_callback)
	sync.atomic_store(&v.output, s.playback != nil)
}

close_capture :: proc(s: ^Audio_Streams, v: ^Voice) {
	if s.capture != nil {
		sync.atomic_store(&v.input, false)
		ma.stream_close(s.capture) // after this the callback no longer runs
		s.capture = nil
	}
}

close_playback :: proc(s: ^Audio_Streams, v: ^Voice) {
	if s.playback != nil {
		sync.atomic_store(&v.output, false)
		ma.stream_close(s.playback)
		s.playback = nil
	}
}

close_streams :: proc(s: ^Audio_Streams, v: ^Voice) {
	close_capture(s, v)
	close_playback(s, v)
}

@(private = "file")
open_stream :: proc(a: ^Audio, dir: ma.Direction, devices: []Audio_Device, name: string, v: ^Voice, callback: ma.Callback) -> ^ma.Stream {
	if a.ctx == nil {
		return nil
	}
	what := "microphone" if dir == .Capture else "speakers"
	id: ^ma.Device_Id
	if d := find_device(devices, name); d != nil {
		id = &d.id
	}

	res: ma.Result
	s := ma.stream_open(a.ctx, dir, id, SAMPLE_RATE, 1, DEVICE_PERIOD_MS, callback, v, &res)
	if s == nil {
		log.errorf("audio: could not open the %s: %s", what, ma.result_string(res))
		return nil
	}
	if r := ma.stream_start(s); r != ma.SUCCESS {
		log.errorf("audio: could not start the %s: %s", what, ma.result_string(r))
		ma.stream_close(s)
		return nil
	}
	opened: [ma.NAME_SIZE]u8
	ma.stream_device_name(s, &opened)
	log.infof("audio: %s: %s", what, cstring(&opened[0]))
	return s
}

/*
Fake audio for headless testing: one thread writes a sine tone into the
capture ring in real time (like a microphone would), another drains the
playback ring in real time (like speakers would) and logs what it heard
each second: loudness, and the dominant frequency from zero crossings.
*/
Fake_Audio :: struct {
	voice:   ^Voice,
	tone_hz: f32,
	stop:    bool, // atomic
	source:  ^thread.Thread,
	sink:    ^thread.Thread,
	heard:   Sink_Stats, // sink thread only
}

fake_audio_start :: proc(f: ^Fake_Audio, v: ^Voice, tone_hz: f32) {
	f.voice = v
	f.tone_hz = tone_hz
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
	buf: [PERIOD]f32
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
		for &s, i in buf {
			t := f64(n * len(buf) + i) / SAMPLE_RATE
			s = f32(0.3 * math.sin(2 * math.PI * f64(f.tone_hz) * t))
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
		stats := &f.heard
		for s in buf {
			stats.sum_sq += f64(s * s)
			if (s >= 0) != (stats.last >= 0) {
				stats.crossings += 1
			}
			stats.last = s
		}
		stats.samples += len(buf)
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

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
	// The microphone is opened at its native channel count; the ring is
	// stereo. On overflow, the newest audio is dropped.
	channels := int(sync.atomic_load(&v.capture_channels))
	if channels == CHANNELS {
		ring_write(&v.capture, samples[:frame_count * CHANNELS])
		return
	}
	CHUNK :: 256
	stereo: [CHUNK * CHANNELS]f32
	for done := 0; done < int(frame_count); done += CHUNK {
		n := min(CHUNK, int(frame_count) - done)
		to_stereo(samples[done * channels:][:n * channels], channels, stereo[:n * CHANNELS])
		ring_write(&v.capture, stereo[:n * CHANNELS])
	}
}

@(private = "file")
playback_callback :: proc "c" (user: rawptr, samples: [^]f32, frame_count: u32) {
	v := (^Voice)(user)
	if ring_read(&v.playback, samples[:frame_count * CHANNELS]) < int(frame_count * CHANNELS) {
		// The rest stays silent (the buffer starts zeroed).
		sync.atomic_add(&v.underruns, 1)
	}
}

/*
to_stereo converts interleaved audio with `channels` channels to stereo:
mono is duplicated to both sides, stereo is copied, and devices with more
channels contribute their first two. (We do this ourselves because
miniaudio's own conversion follows the device's channel map: a mono
microphone that reports its channel as "front left" ended up on the
left only.)
*/
to_stereo :: proc "contextless" (input: []f32, channels: int, output: []f32) {
	frames := len(output) / CHANNELS
	for i in 0 ..< frames {
		left := input[i * channels]
		right := input[i * channels + 1] if channels > 1 else left
		output[i * CHANNELS], output[i * CHANNELS + 1] = left, right
	}
}

// open_capture opens the named input device ("" or missing: the system
// default) and starts feeding the Voice.
open_capture :: proc(a: ^Audio, s: ^Audio_Streams, v: ^Voice, device: string) {
	close_capture(s, v)
	s.capture = open_stream(a, .Capture, a.inputs[:], device, v, capture_callback, 0)
	sync.atomic_store(&v.input, s.capture != nil)
}

open_playback :: proc(a: ^Audio, s: ^Audio_Streams, v: ^Voice, device: string) {
	close_playback(s, v)
	s.playback = open_stream(a, .Playback, a.outputs[:], device, v, playback_callback, CHANNELS)
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

/*
Tries, in order: the device selected in the settings, the device the
system reports as its default (by id), and the backend's own notion of
"default". The last two differ in practice: after the default device
disappeared (a headset unplugged), PulseAudio via PipeWire kept failing
to open "default" while the new default opened fine by id.
*/
@(private = "file")
open_stream :: proc(
	a: ^Audio,
	dir: ma.Direction,
	devices: []Audio_Device,
	name: string,
	v: ^Voice,
	callback: ma.Callback,
	channels: u32, // 0: the device's native count
) -> ^ma.Stream {
	if a.ctx == nil {
		return nil
	}
	what := "microphone" if dir == .Capture else "speakers"

	candidates: [3]^ma.Device_Id
	count := 0
	if d := find_device(devices, name); d != nil {
		candidates[count] = &d.id
		count += 1
	}
	for &d in devices {
		if d.is_default && (count == 0 || &d.id != candidates[0]) {
			candidates[count] = &d.id
			count += 1
			break
		}
	}
	count += 1 // nil: the backend's default

	for id in candidates[:count] {
		res: ma.Result
		s := ma.stream_open(a.ctx, dir, id, SAMPLE_RATE, channels, DEVICE_PERIOD_MS, callback, v, &res)
		if s == nil {
			log.debugf(
				"audio: opening the %s failed (%s), trying the next option",
				what,
				ma.result_string(res),
			)
			continue
		}
		opened_channels := ma.stream_channels(s)
		if dir == .Capture {
			if opened_channels == 0 {
				ma.stream_close(s)
				continue
			}
			// Before starting, so the callback never sees a stale count.
			sync.atomic_store(&v.capture_channels, u32(opened_channels))
		}
		if r := ma.stream_start(s); r != ma.SUCCESS {
			log.debugf(
				"audio: starting the %s failed (%s), trying the next option",
				what,
				ma.result_string(r),
			)
			ma.stream_close(s)
			continue
		}
		opened: [ma.NAME_SIZE]u8
		ma.stream_device_name(s, &opened)
		log.infof("audio: %s: %s (%d channel%s)", what, cstring(&opened[0]), opened_channels, "" if opened_channels == 1 else "s")
		return s
	}
	log.errorf("audio: could not open the %s", what)
	return nil
}

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

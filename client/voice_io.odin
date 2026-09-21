package client

import log "../common/wlog"
import "core:sync"

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

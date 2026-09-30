#+build !wasi
package audio

import "core:strings"
import "core:sync"

import "client:audio/aac"

/*
Capturing an application's audio into a Voice's app ring (native
clients; see aac/aac.odin for which systems can), converted to 48 kHz
stereo on the way. The network thread mixes it into every frame it
sends (app_mix in voice.odin). What's shared, and when, is the UI's to
say: see the client's ui_app_audio_native.odin.
*/

// One application being captured into a Voice's app ring. Its address
// is what tinyaac's callbacks get.
App_Share :: struct {
	capture: ^aac.Capture,
	voice:   ^Voice,
	// Resampling to SAMPLE_RATE (resample_write): the application's rate,
	// where the next output frame falls in the next input chunk (-1 is
	// `prev`), and the chunk before's last frame.
	rate:    u32,
	pos:     f64,
	prev:    [CHANNELS]f32,
	// Set by tinyaac's thread when the application has gone or the
	// capture failed, with why; the UI stops the share (app_share_ended).
	ended:   bool, // atomic
	why:     [128]u8,
}

/*
app_share_start captures the application `index` of `list` into v's app
ring. The ring isn't read until v.app_input is set, which is left to the
caller. If it fails, `why` says so in words (temporary).
*/
app_share_start :: proc(
	v: ^Voice,
	list: ^aac.App_List,
	index: uint,
) -> (
	s: ^App_Share,
	st: aac.Status,
	why: string,
) {
	s = new(App_Share)
	s.voice = v
	st = aac.capture_create(list, index, &s.capture)
	if st == .Ok {
		st = aac.capture_set_callbacks(s.capture, app_audio_callback, app_event_callback, s)
	}
	if st == .Ok {
		st = aac.capture_start(s.capture)
	}
	if st != .Ok {
		why = strings.clone(string(aac.last_error()), context.temp_allocator)
		if s.capture != nil {
			aac.capture_destroy(s.capture)
		}
		free(s)
		return nil, st, why
	}
	return s, .Ok, ""
}

// app_share_stop ends the capture and frees it.
app_share_stop :: proc(s: ^App_Share) {
	sync.atomic_store(&s.voice.app_input, false)
	aac.capture_stop(s.capture) // after this the callbacks no longer run
	aac.capture_destroy(s.capture)
	free(s)
}

// app_share_ended is whether the application has gone or the capture
// failed; s.why says which.
app_share_ended :: proc(s: ^App_Share) -> bool {
	return sync.atomic_load(&s.ended)
}

// Runs on tinyaac's thread. Like the device callbacks, it only moves
// samples into the ring, which drops what doesn't fit.
@(private = "file")
app_audio_callback :: proc "c" (frame: ^aac.Audio_Frame, user: rawptr) {
	s := (^App_Share)(user)
	channels := int(frame.channels)
	if channels == 0 || frame.sample_rate == 0 {
		return
	}
	if frame.sample_rate != s.rate {
		s.rate, s.pos, s.prev = frame.sample_rate, 0, {}
	}
	frames := int(frame.frame_count)
	sync.atomic_add(&s.voice.app_received, u32(frames))
	CHUNK :: 256
	stereo: [CHUNK * CHANNELS]f32
	for done := 0; done < frames; done += CHUNK {
		n := min(CHUNK, frames - done)
		to_stereo(frame.samples[done * channels:][:n * channels], channels, stereo[:n * CHANNELS])
		if s.rate == SAMPLE_RATE {
			ring_write(&s.voice.app, stereo[:n * CHANNELS])
		} else {
			resample_write(s, stereo[:n * CHANNELS])
		}
	}
}

@(private = "file")
app_event_callback :: proc "c" (
	event: aac.Event,
	status: aac.Status,
	message: cstring,
	user: rawptr,
) {
	s := (^App_Share)(user)
	if event != .Target_Ended && event != .Backend_Error {
		return
	}
	if !sync.atomic_load(&s.ended) {
		text := string(message) if message != nil else ""
		copy(s.why[:len(s.why) - 1], text)
		sync.atomic_store(&s.ended, true)
	}
}

/*
resample_write converts stereo audio at s.rate to SAMPLE_RATE and writes
it to the ring, interpolating linearly between neighbouring frames. That
aliases a little, which is lost in Opus at the rates we send; most
applications play at 48 kHz anyway and skip this altogether.
*/
resample_write :: proc "contextless" (s: ^App_Share, input: []f32) {
	frames := len(input) / CHANNELS
	if frames == 0 {
		return
	}
	step := f64(s.rate) / SAMPLE_RATE
	out: [512 * CHANNELS]f32
	n := 0
	for s.pos < f64(frames - 1) {
		// pos >= -1, so this is its floor.
		i := int(s.pos + 1) - 1
		frac := f32(s.pos - f64(i))
		for c in 0 ..< CHANNELS {
			from := s.prev[c] if i < 0 else input[i * CHANNELS + c]
			to := input[(i + 1) * CHANNELS + c]
			out[n + c] = from + (to - from) * frac
		}
		n += CHANNELS
		if n == len(out) {
			ring_write(&s.voice.app, out[:n])
			n = 0
		}
		s.pos += step
	}
	ring_write(&s.voice.app, out[:n])
	s.pos -= f64(frames)
	copy(s.prev[:], input[(frames - 1) * CHANNELS:])
}

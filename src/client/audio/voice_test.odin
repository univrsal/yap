#+build !wasi
package audio

import "core:math"
import "core:strings"
import "core:sync"
import "core:testing"

import "client:audio/opus"

// Plays one speaker's tone through the receive path (decode -> jitter
// queue -> mix) at the given gain and returns the output level.
@(private = "file")
played_level :: proc(t: ^testing.T, gain: f32, set_gain: bool, deafened := false) -> f64 {
	v: Voice
	testing.expect(t, voice_init(&v))
	defer voice_destroy(&v)
	sync.atomic_store(&v.output, true)
	v.deafened = deafened
	if set_gain {
		// User 42 is account 7's; gains are looked up by account.
		v.user_accounts[42] = 7
		v.gains[7] = gain
	}

	err: opus.Error
	enc := opus.encoder_create(SAMPLE_RATE, 1, .VOIP, &err)
	defer opus.encoder_destroy(enc)

	sum: f64
	count: int
	out: [FRAME]f32
	for f in 0 ..< 50 {
		pcm: [FRAME_SAMPLES]f32
		for &s, i in pcm {
			s = f32(0.3 * math.sin(2 * math.PI * 440 * f64(f * FRAME_SAMPLES + i) / SAMPLE_RATE))
		}
		packet: [opus.MAX_PACKET_SIZE]u8
		n := opus.encode_float(enc, &pcm[0], FRAME_SAMPLES, &packet[0], len(packet))
		voice_receive(&v, 42, u32(f), packet[:n])
		voice_step(&v)
		// Stand in for the output device: take one frame per frame sent.
		got := ring_read(&v.playback, out[:])
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

// Deafened plays nothing, whatever the per-user gains say.
@(test)
test_deafen :: proc(t: ^testing.T) {
	normal := played_level(t, 1, false)
	testing.expectf(t, normal > 0.15, "tone not played (level %.3f)", normal)

	deafened := played_level(t, 1, false, true)
	testing.expect_value(t, deafened, 0)
}

@(test)
test_notification_sounds :: proc(t: ^testing.T) {
	v: Voice
	testing.expect(t, voice_init(&v))
	defer voice_destroy(&v)
	for name, kind in DEFAULT_SOUNDS {
		clip := v.notifications.clips[kind]
		testing.expectf(t, (name == "") == (clip == nil), "%v has the wrong sound", kind)
	}
	// Every event with a sound of its own, to hear them all.
	for kind in Sound_Event {
		if kind != .None && !SOUND_EVENTS[kind].loop {
			notifications_set(&v.notifications, kind, "aim/msg")
		}
	}

	for kind in Sound_Event {
		if kind == .None || SOUND_EVENTS[kind].loop {
			continue
		}
		notification_play(&v.notifications, kind)
		sum: f64
		count := 0
		for notifications_pending(&v.notifications) {
			mix_output(&v)
			out: [FRAME]f32
			got := ring_read(&v.playback, out[:])
			for sample in out[:got] {
				sum += f64(sample * sample)
			}
			count += got
		}
		testing.expectf(t, count > 0 && sum > 0, "%v notification was silent", kind)
	}
}

@(test)
test_notification_tail :: proc(t: ^testing.T) {
	v: Voice
	testing.expect(t, voice_init(&v))
	defer voice_destroy(&v)
	notifications_set(&v.notifications, .Goodbye, "aim/goodbye")
	notification_play(&v.notifications, .Goodbye)
	notification_tail_step(&v)
	testing.expect(t, !notifications_pending(&v.notifications))
	testing.expect(t, ring_available(&v.playback) > 0)
}

@(test)
test_notification_volume :: proc(t: ^testing.T) {
	clip := []f32{0.8, -0.4}
	sounds := Notification_Sounds {
		playing = {0 = {clip, 2, 0}},
		playing_count = 1,
		volume = 0.25,
	}
	mix: [2]f32
	notifications_mix(&sounds, mix[:])
	testing.expect_value(t, mix, [2]f32{0.2, -0.1})

	// A mono sound goes to both sides.
	mono := Notification_Sounds {
		playing = {0 = {clip, 1, 0}},
		playing_count = 1,
		volume = 0.5,
	}
	both: [4]f32
	notifications_mix(&mono, both[:])
	testing.expect_value(t, both, [4]f32{0.4, 0.4, -0.2, -0.2})
	testing.expect_value(t, mono.playing_count, 0)
}

// Sounds play over each other rather than one after the other.
@(test)
test_notifications_overlap :: proc(t: ^testing.T) {
	samples: [MAX_PLAYING + 1][4]f32
	clips: [MAX_PLAYING + 1]Sound_Clip
	s := Notification_Sounds {
		volume = 1,
	}
	for &clip, i in clips {
		samples[i] = 0.1 * f32(i + 1)
		clip = {
			samples  = samples[i][:],
			channels = 1,
		}
		s.clips[Sound_Event(1 + i)] = &clip
	}
	first, second := Sound_Event(1), Sound_Event(2)

	// Two at once are mixed.
	notification_play(&s, first)
	notification_play(&s, second)
	mix: [2]f32
	notifications_mix(&s, mix[:])
	testing.expect(t, abs(mix[0] - 0.3) < 1e-6, "the two sounds weren't mixed")
	testing.expect_value(t, s.playing_count, 2)

	// The same sound again starts over, and is not played twice.
	notification_play(&s, first)
	testing.expect_value(t, s.playing_count, 2)
	testing.expect(t, raw_data(s.playing[1].samples) == raw_data(clips[0].samples))
	testing.expect_value(t, s.playing[1].position, 0)

	// Past MAX_PLAYING, the one that started first ends.
	for i in 2 ..< len(clips) {
		notification_play(&s, Sound_Event(1 + i))
	}
	testing.expect_value(t, s.playing_count, MAX_PLAYING)
	for p in s.playing {
		testing.expect(t, raw_data(p.samples) != raw_data(clips[1].samples))
	}

	// Each ends on its own.
	long: [8]f32
	notifications_mix(&s, long[:])
	testing.expect_value(t, s.playing_count, 0)
}

@(test)
test_deafen_suppresses_notifications :: proc(t: ^testing.T) {
	v: Voice
	testing.expect(t, voice_init(&v))
	defer voice_destroy(&v)
	notifications_set(&v.notifications, .Message, "aim/msg")
	v.deafened = true
	voice_notification_play(&v, .Message)
	testing.expect_value(t, v.notifications.playing_count, 0)
	v.deafened = false
	voice_notification_play(&v, .Message)
	testing.expect_value(t, v.notifications.playing_count, 1)
	v.deafened = true
	mix_output(&v)
	testing.expect_value(t, v.notifications.playing_count, 0)
}

// Deafening drops what is playing, but not the sound confirming that we
// deafened.
@(test)
test_deafen_keeps_feedback :: proc(t: ^testing.T) {
	v: Voice
	testing.expect(t, voice_init(&v))
	defer voice_destroy(&v)
	voice_notification_play(&v, .Message)
	voice_feedback_play(&v, .Muted)
	v.deafened = true
	mix_output(&v)
	testing.expect_value(t, v.notifications.playing_count, 1)
	testing.expect(
		t,
		raw_data(v.notifications.playing[0].samples) ==
		raw_data(v.notifications.clips[.Muted].samples),
	)
}

@(test)
test_listen_back :: proc(t: ^testing.T) {
	v: Voice
	testing.expect(t, voice_init(&v))
	defer voice_destroy(&v)

	frame: [FRAME]f32
	for &s in frame {
		s = 0.5
	}
	out: [FRAME]f32
	level :: proc(x: []f32) -> f32 {
		sum: f32
		for s in x {
			sum += s * s
		}
		return sum / f32(len(x))
	}

	// Off: nothing is queued or played.
	listen_feed(&v, frame[:], true)
	mix_output(&v)
	ring_read(&v.playback, out[:])
	testing.expect_value(t, level(out[:]), 0)

	// On: frames that would be sent are played back (after the prefill),
	// frames the gate holds back are played as silence.
	ring_skip(&v.playback, ring_available(&v.playback)) // silence mixed while off
	v.listen = true
	for _ in 0 ..< 3 {
		listen_feed(&v, frame[:], true)
	}
	listen_feed(&v, frame[:], false)
	played: [4]f32
	for i in 0 ..< 4 {
		mix_output(&v)
		ring_read(&v.playback, out[:])
		played[i] = level(out[:])
	}
	// Exactly what was fed comes out, in order: three frames as captured,
	// then the gated one as silence.
	testing.expectf(
		t,
		played[0] > 0.2 && played[1] > 0.2 && played[2] > 0.2 && played[3] == 0,
		"listen back played %v",
		played,
	)

	// Switching off drops what was queued.
	v.listen = false
	listen_feed(&v, frame[:], true)
	mix_output(&v)
	testing.expect_value(t, ring_available(&v.loopback), 0)
}

@(test)
test_stereo_end_to_end :: proc(t: ^testing.T) {
	// A Music (stereo) sender with a tone on the left only: the receiver
	// must play it on the left only.
	sender: Voice
	testing.expect(t, voice_init(&sender))
	defer voice_destroy(&sender)
	testing.expect(t, encoder_setup(&sender, .Music))

	v: Voice
	testing.expect(t, voice_init(&v))
	defer voice_destroy(&v)
	sync.atomic_store(&v.output, true)

	left, right: f64
	for f in 0 ..< 50 {
		frame: [FRAME]f32
		for i in 0 ..< FRAME_SAMPLES {
			frame[i * CHANNELS] = f32(
				0.3 * math.sin(2 * math.PI * 440 * f64(f * FRAME_SAMPLES + i) / SAMPLE_RATE),
			)
		}
		_, pass := mic_process(&sender, frame[:]) // no suppression; gate off
		testing.expect(t, pass)
		packet: [opus.MAX_PACKET_SIZE]u8
		n := opus.encode_float(sender.encoder, &frame[0], FRAME_SAMPLES, &packet[0], len(packet))
		testing.expect(t, n > 0)
		testing.expect_value(t, opus.packet_get_nb_channels(&packet[0]), 2)

		voice_receive(&v, 7, u32(f), packet[:n])
		voice_step(&v)
		out: [FRAME]f32
		got := ring_read(&v.playback, out[:])
		if f >= 25 {
			for i := 0; i + 1 < got; i += CHANNELS {
				left += f64(out[i] * out[i])
				right += f64(out[i + 1] * out[i + 1])
			}
		}
	}
	testing.expectf(t, left > 100 * right && left > 0, "left %.3f, right %.5f", left, right)
}

@(test)
test_mono_downmix :: proc(t: ^testing.T) {
	v: Voice
	testing.expect(t, voice_init(&v))
	defer voice_destroy(&v)
	testing.expect_value(t, QUALITY_PRESETS[v.quality].channels, 1)

	// Left at 1, right at 0: a mono preset sends (and listens back to)
	// the average on both channels, and measures its level.
	frame: [FRAME]f32
	for i in 0 ..< FRAME_SAMPLES {
		frame[i * CHANNELS] = 1
	}
	level, _ := mic_process(&v, frame[:])
	testing.expect_value(t, frame[0], 0.5)
	testing.expect_value(t, frame[1], 0.5)
	testing.expect(t, abs(level - (-6.0206)) < 0.01) // 20*log10(0.5)
}

@(test)
test_to_stereo :: proc(t: ^testing.T) {
	out: [4]f32 // two stereo frames

	// Mono: duplicated to both sides (not left only).
	to_stereo([]f32{0.5, -0.25}, 1, out[:])
	testing.expect_value(t, out, [4]f32{0.5, 0.5, -0.25, -0.25})

	// Stereo: unchanged.
	to_stereo([]f32{0.1, 0.2, 0.3, 0.4}, 2, out[:])
	testing.expect_value(t, out, [4]f32{0.1, 0.2, 0.3, 0.4})

	// More channels: the first two of each frame.
	to_stereo([]f32{0.1, 0.2, 9, 9, 0.3, 0.4, 9, 9}, 4, out[:])
	testing.expect_value(t, out, [4]f32{0.1, 0.2, 0.3, 0.4})
}

@(test)
test_ring_loops :: proc(t: ^testing.T) {
	s: Notification_Sounds
	notifications_init(&s)
	defer notifications_destroy(&s)

	energy :: proc(s: ^Notification_Sounds, samples: int) -> f64 {
		mix := make([]f32, samples, context.temp_allocator)
		notifications_mix(s, mix)
		sum: f64
		for v in mix {
			sum += f64(v * v)
		}
		return sum
	}
	// Ringing: it goes on past its own length, from the start again.
	notification_loop(&s, .Ring)
	ring := s.clips[.Ring]
	ring_mix := len(ring.samples) / ring.channels * CHANNELS // as long as the ring, mixed
	testing.expect(t, energy(&s, ring_mix) > 0)
	testing.expect(t, energy(&s, ring_mix / 2) > 0, "the ring didn't start again")
	// The same again doesn't start it over; another does.
	at := s.loop.position
	notification_loop(&s, .Ring)
	testing.expect_value(t, s.loop.position, at)
	notification_loop(&s, .Ringback)
	testing.expect_value(t, s.loop.position, 0)
	// Deafened, it's quiet; stopped, it's gone.
	s.loop_quiet = true
	testing.expect_value(t, energy(&s, 4800), 0)
	s.loop_quiet = false
	notification_loop(&s, .None)
	testing.expect_value(t, energy(&s, 4800), 0)
}

// Every sound in the packs decodes, and every event's sound is one of them.
@(test)
test_sound_packs :: proc(t: ^testing.T) {
	for pack in SOUND_PACKS {
		testing.expectf(t, len(pack.files) > 0, "sound pack %s is empty", pack.name)
		for f in pack.files {
			testing.expectf(
				t,
				strings.has_suffix(f.name, ".opus"),
				"%s/%s isn't Opus",
				pack.name,
				f.name,
			)
			clip, channels := decode_ogg_opus(f.data, f.name)
			testing.expectf(
				t,
				channels == 1 || channels == 2,
				"%s/%s has %d channels",
				pack.name,
				f.name,
				channels,
			)
			testing.expectf(t, len(clip) > 0, "%s/%s didn't decode", pack.name, f.name)
			delete(clip)
		}
	}
	for name, kind in DEFAULT_SOUNDS {
		_, ok := sound_data(name)
		testing.expectf(t, name == "" || ok, "no sound %q for %v", name, kind)
	}
	for preset in SOUND_PRESETS {
		for name, kind in preset.sounds {
			_, ok := sound_data(name)
			testing.expectf(
				t,
				name == "" || ok,
				"%s: no sound %q for %v",
				preset.label,
				name,
				kind,
			)
		}
	}
}

// Choosing sounds: shared between Voices, let go of when no longer used, and
// a sound of one's own.
@(test)
test_sound_choices :: proc(t: ^testing.T) {
	a, b: Notification_Sounds
	notifications_init(&a)
	defer notifications_destroy(&a)
	notifications_init(&b)
	defer notifications_destroy(&b)

	notifications_set(&a, .Message, "skype/msg")
	notifications_set(&b, .Message, "skype/msg")
	testing.expect(t, a.clips[.Message] != nil && a.clips[.Message] == b.clips[.Message])
	testing.expect_value(t, a.clips[.Message].refs, 2)

	// Changing it while it plays stops it.
	notification_play(&a, .Message)
	testing.expect(t, raw_data(a.playing[0].samples) == raw_data(a.clips[.Message].samples))
	notifications_set(&a, .Message, NO_SOUND)
	testing.expect(t, a.clips[.Message] == nil)
	testing.expect_value(t, a.playing_count, 0)
	testing.expect_value(t, b.clips[.Message].refs, 1)
	notification_play(&a, .Message)
	testing.expect_value(t, a.playing_count, 0)

	// Half a second of a 440 Hz tone, as an 8 kHz mono WAV.
	RATE :: 8000
	FRAMES :: RATE / 2
	wav := make([dynamic]u8, context.temp_allocator)
	put32 :: proc(b: ^[dynamic]u8, v: u32) {
		append(b, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
	}
	put16 :: proc(b: ^[dynamic]u8, v: u16) {
		append(b, u8(v), u8(v >> 8))
	}
	append(&wav, "RIFF")
	put32(&wav, 36 + FRAMES * 2)
	append(&wav, "WAVEfmt ")
	put32(&wav, 16)
	put16(&wav, 1) // PCM
	put16(&wav, 1) // mono
	put32(&wav, RATE)
	put32(&wav, RATE * 2)
	put16(&wav, 2)
	put16(&wav, 16)
	append(&wav, "data")
	put32(&wav, FRAMES * 2)
	for i in 0 ..< FRAMES {
		put16(&wav, u16(i16(math.sin(f64(i) * 2 * math.PI * 440 / RATE) * 10000)))
	}
	samples, channels, err := sound_decode(wav[:], "tone.wav")
	defer delete(samples)
	testing.expect_value(t, err, "")
	testing.expect_value(t, channels, 1)
	testing.expectf(
		t,
		abs(len(samples) - SAMPLE_RATE / 2) < 100,
		"%d samples, not about half a second",
		len(samples),
	)

	sound_custom_add("custom:tone.wav", samples, channels)
	testing.expect(t, sound_custom_loaded("custom:tone.wav"))
	notifications_set(&a, .Ring, "custom:tone.wav")
	notification_loop(&a, .Ring)
	testing.expect(t, len(a.loop.samples) > 0)
	// Let go of by the UI, it still plays where it is chosen.
	sound_custom_remove("custom:tone.wav")
	testing.expect(t, !sound_custom_loaded("custom:tone.wav"))
	testing.expect_value(t, a.clips[.Ring].refs, 1)
	// A sound of one's own that isn't loaded is no sound.
	notifications_set(&b, .Ring, "custom:missing.wav")
	testing.expect(t, b.clips[.Ring] == nil)

	_, _, vorbis := sound_decode(transmute([]u8)string("OggS\x00\x02vorbis"), "x.ogg")
	testing.expect(t, vorbis != "")
	_, _, junk := sound_decode(transmute([]u8)string("not a sound"), "x.bin")
	testing.expect(t, junk != "")
}

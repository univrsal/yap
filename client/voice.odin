package client

import "core:encoding/endian"
import "core:log"
import "core:sync"
import "core:time"

import "../proto"
import "opus"
import "rnn"

/*
The voice pipeline. Everything here runs on the network thread; the audio
devices only touch the two rings (see voice_io.odin):

	microphone -> capture ring -> [encode] -> Voice packet -> server
	server -> Voice packet -> [decode, per speaker] -> jitter queue
	       -> [mix] -> playback ring -> speakers

Audio is 48 kHz, sent as 20 ms Opus frames in mono or stereo depending on
the quality preset (quality.odin). Internally everything is stereo: the
microphone is captured in stereo (a mono microphone arrives as L = R) and
downmixed for mono presets; decoders, queues, the mixer and the output are
stereo, and mono speakers play centered. All buffers hold interleaved
samples. Mixing is paced by the playback ring's fill level, so it follows
the output device's clock.

Captured frames go through noise suppression (RNNoise, optional) and the
voice gate (optional, see gate.odin) before encoding.

Loss handling: packets carry a per-sender sequence number that advances
every 20 ms whether or not anything was sent. A short gap is lost packets:
the last one is recovered from the next packet's in-band FEC when present
and the rest are concealed (PLC). A long gap is the speaker pausing (DTX
silence, or mute) and starts a fresh talkspurt.
*/

SAMPLE_RATE :: 48000
CHANNELS :: 2 // of every device and buffer
FRAME_SAMPLES :: 960 // 20 ms, per channel
FRAME :: FRAME_SAMPLES * CHANNELS // one 20 ms frame, interleaved

// Keep ~30 ms queued for the output device.
OUTPUT_TARGET :: FRAME * 3 / 2
// A speaker starts playing once 40 ms are queued (absorbs network jitter)...
JITTER_PREFILL :: 2 * FRAME
// ...and is trimmed back to that if the queue ever exceeds 200 ms.
JITTER_MAX :: 10 * FRAME
// Gaps longer than this many frames are pauses, not loss.
MAX_CONCEAL :: 5
// Drop a speaker's decoder after this long without packets.
SPEAKER_TIMEOUT :: 10 * time.Second
// If the network thread falls behind, don't send a backlog of old audio.
MAX_CAPTURE_BACKLOG :: 5 * FRAME

Speaker :: struct {
	decoder:     ^opus.Decoder,
	queue:       Ring, // decoded samples; only used on the network thread
	next_seq:    u32,
	started:     bool, // decoded at least one packet
	playing:     bool, // prefill reached, being mixed
	last_packet: time.Tick,
}

Voice :: struct {
	capture:     Ring, // capture callback -> network thread
	playback:    Ring, // network thread -> playback callback
	// Whether something produces into / consumes from the rings (a device,
	// or the fake audio in headless mode). Set by whoever opens them.
	input:       bool, // atomic
	output:      bool, // atomic
	// The microphone stream's channel count (its native one); the capture
	// callback converts to stereo. Atomic.
	capture_channels: u32,
	encoder:     ^opus.Encoder,
	quality:     Quality,
	send_seq:    u32,
	muted:       bool,
	denoisers:   [CHANNELS]rnn.Denoiser, // one per channel (stereo presets)
	denoise:     bool, // noise suppression
	gate:        Gate,
	// Listen back: our own processed microphone audio, as it would be sent
	// (after suppression, silent while the gate is closed), played back to
	// us through the mixer. For testing the settings; ignores mute.
	listen:      bool,
	loopback:    Ring, // same thread in and out, like a speaker's queue
	looping:     bool, // prefill reached, being mixed
	// How much to keep queued for the output device (see OUTPUT_TARGET).
	output_target: int,
	speakers:    map[u32]^Speaker,
	// Per-user playback gain (0 = muted), from the UI, by public key.
	// Missing means 1.
	gains:       map[[proto.KEY_SIZE]u8]f32, // by public key
	// User number -> public key, from the latest snapshot.
	user_keys:   map[u32][proto.KEY_SIZE]u8,

	// Stats, reset every second by log_stats.
	captured:    int, // frames read from the microphone
	gated:       int, // frames the voice gate held back
	sent_frames: int,
	sent_bytes:  int,
	received:    map[u32]int,
	concealed:   int,
	underruns:   u32, // atomic; incremented by the playback callback
}

voice_init :: proc(v: ^Voice) -> bool {
	v.gate = {
		open_db  = DEFAULT_GATE_OPEN_DB,
		close_db = DEFAULT_GATE_CLOSE_DB,
	}
	ring_init(&v.capture, SAMPLE_RATE / 2 * CHANNELS)
	ring_init(&v.playback, SAMPLE_RATE / 2 * CHANNELS)
	ring_init(&v.loopback, JITTER_MAX + 4 * FRAME)
	v.output_target = OUTPUT_TARGET
	v.capture_channels = CHANNELS

	if !encoder_setup(v, .Voice) {
		return false
	}
	for &d in v.denoisers {
		ok: bool
		if d, ok = rnn.denoiser_create(); !ok {
			log.error("rnnoise: could not create a denoiser; noise suppression is unavailable")
		}
	}
	return true
}

voice_destroy :: proc(v: ^Voice) {
	for _, sp in v.speakers {
		speaker_destroy(sp)
	}
	delete(v.speakers)
	delete(v.gains)
	delete(v.user_keys)
	delete(v.received)
	for &d in v.denoisers {
		rnn.denoiser_destroy(&d)
	}
	if v.encoder != nil {
		opus.encoder_destroy(v.encoder)
		v.encoder = nil
	}
	ring_destroy(&v.capture)
	ring_destroy(&v.playback)
	ring_destroy(&v.loopback)
}

// voice_step encodes and sends captured audio, and keeps the output fed.
voice_step :: proc(c: ^Voice_Client) {
	v := &c.voice
	if sync.atomic_load(&v.input) {
		send_captured(c)
	}
	if sync.atomic_load(&v.output) {
		mix_output(v)
	}
	expire_speakers(v)
}

@(private = "file")
send_captured :: proc(c: ^Voice_Client) {
	v := &c.voice
	if backlog := ring_available(&v.capture) - MAX_CAPTURE_BACKLOG; backlog > 0 {
		ring_skip(&v.capture, backlog)
	}

	frame: [FRAME]f32
	for ring_available(&v.capture) >= FRAME {
		ring_read(&v.capture, frame[:])
		// The sequence number tracks time, so it advances even for frames
		// that aren't sent; receivers read long gaps as pauses.
		seq := v.send_seq
		v.send_seq += 1
		v.captured += 1
		level, pass := mic_process(v, frame[:])
		listen_feed(v, frame[:], pass)
		publish_mic(c, level, v.gate.open)
		if v.muted || !c.has_current || !in_settled_channel(c) {
			continue
		}
		if !pass {
			v.gated += 1
			continue
		}

		// mic_process left the frame as stereo; mono presets encode the
		// (identical) left channel.
		pcm := frame[:]
		mono: [FRAME_SAMPLES]f32
		if QUALITY_PRESETS[v.quality].channels == 1 {
			for &s, i in mono {
				s = frame[i * CHANNELS]
			}
			pcm = mono[:]
		}
		msg: [proto.VOICE_UP_HEADER_SIZE + opus.MAX_PACKET_SIZE]u8
		n := opus.encode_float(
			v.encoder,
			raw_data(pcm),
			FRAME_SAMPLES,
			&msg[proto.VOICE_UP_HEADER_SIZE],
			opus.MAX_PACKET_SIZE,
		)
		if n < 0 {
			log.errorf("opus: encode failed: %s", opus.strerror(opus.Error(n)))
			continue
		}
		if n <= 2 {
			continue // DTX: silence, nothing worth sending
		}
		msg[0] = u8(proto.Message_Kind.Voice)
		endian.unchecked_put_u32le(msg[1:], seq)
		if send_data(c, msg[:proto.VOICE_UP_HEADER_SIZE + int(n)]) {
			v.sent_frames += 1
			v.sent_bytes += int(n)
			if me := my_num(c); me != 0 {
				publish_voice(c, me)
			}
		}
	}
}

// voice_receive handles one Voice message from the server.
voice_receive :: proc(c: ^Voice_Client, speaker: u32, seq: u32, packet: []u8) {
	v := &c.voice
	v.received[speaker] += 1
	publish_voice(c, speaker)
	if !sync.atomic_load(&v.output) || len(packet) == 0 {
		return // nothing to play it on
	}

	sp := v.speakers[speaker] or_else nil
	if sp == nil {
		ok: bool
		if sp, ok = speaker_create(); !ok {
			return
		}
		v.speakers[speaker] = sp
	}
	sp.last_packet = time.tick_now()

	if sp.started {
		gap := i32(seq - sp.next_seq)
		switch {
		case gap < 0:
			return // late or duplicate; its slot has already been played
		case gap > 0 && gap <= MAX_CONCEAL:
			// Lost packets: conceal all but the last, which this packet's
			// FEC may be able to recover.
			for _ in 0 ..< gap - 1 {
				decode_into(sp, nil, 0)
			}
			if opus.packet_has_lbrr(raw_data(packet), i32(len(packet))) == 1 {
				decode_into(sp, packet, 1)
			} else {
				decode_into(sp, nil, 0)
			}
			v.concealed += int(gap)
		}
		// A longer gap is a pause; just carry on from this packet.
	}
	decode_into(sp, packet, 0)
	sp.started = true
	sp.next_seq = seq + 1
}

// decode_into decodes a packet (nil: conceal a lost frame; fec: recover the
// previous frame from this packet) and queues the samples.
@(private = "file")
decode_into :: proc(sp: ^Speaker, packet: []u8, fec: i32) {
	pcm: [opus.MAX_FRAME_SAMPLES * CHANNELS]f32
	// Concealment and FEC produce exactly one of our frames; a normal
	// decode produces whatever the packet holds. Decoders are stereo, so
	// mono packets come out with L = R.
	frame_size: i32 = FRAME_SAMPLES if packet == nil || fec == 1 else opus.MAX_FRAME_SAMPLES
	n := opus.decode_float(
		sp.decoder,
		raw_data(packet),
		i32(len(packet)),
		&pcm[0],
		frame_size,
		fec,
	)
	if n < 0 {
		log.debugf("opus: decode failed: %s", opus.strerror(opus.Error(n)))
		return
	}
	ring_write(&sp.queue, pcm[:n * CHANNELS])
}

// listen_feed queues a processed microphone frame for listen back: the
// frame if it would be sent, silence if the gate is holding it back.
listen_feed :: proc(v: ^Voice, frame: []f32, pass: bool) {
	if !v.listen {
		return
	}
	if pass {
		ring_write(&v.loopback, frame)
	} else {
		silence: [FRAME]f32
		ring_write(&v.loopback, silence[:len(frame)])
	}
}

// mix_output keeps the playback ring filled with the mix of everyone
// speaking (and our own audio, with listen back on).
mix_output :: proc(v: ^Voice) {
	for ring_available(&v.playback) < v.output_target {
		mix: [FRAME]f32
		mix_loopback(v, mix[:])
		for id, sp in v.speakers {
			queued := ring_available(&sp.queue)
			if !sp.playing {
				if queued < JITTER_PREFILL {
					continue
				}
				sp.playing = true
			}
			if queued > JITTER_MAX {
				// Clock drift or a burst after a stall: catch up.
				ring_skip(&sp.queue, queued - JITTER_PREFILL)
			}
			// Muted speakers are still decoded and consumed, so unmuting
			// picks up cleanly where they are.
			frame: [FRAME]f32
			got := ring_read(&sp.queue, frame[:])
			gain: f32 = 1
			if key, known := v.user_keys[id]; known {
				gain = v.gains[key] or_else 1
			}
			if gain > 0 {
				for s, i in frame[:got] {
					mix[i] += s * gain
				}
			}
			if got < FRAME {
				sp.playing = false // ran dry: buffer up again before resuming
			}
		}
		for &s in mix {
			s = clamp(s, -1, 1)
		}
		ring_write(&v.playback, mix[:])
	}
}

// The listen back source: buffered and drift-corrected like a speaker,
// since the microphone and the output device run on different clocks.
@(private = "file")
mix_loopback :: proc(v: ^Voice, mix: []f32) {
	queued := ring_available(&v.loopback)
	if !v.listen {
		ring_skip(&v.loopback, queued)
		v.looping = false
		return
	}
	if !v.looping {
		if queued < JITTER_PREFILL {
			return
		}
		v.looping = true
	}
	if queued > JITTER_MAX {
		ring_skip(&v.loopback, queued - JITTER_PREFILL)
	}
	frame: [FRAME]f32
	got := ring_read(&v.loopback, frame[:len(mix)])
	for s, i in frame[:got] {
		mix[i] += s
	}
	if got < len(mix) {
		v.looping = false
	}
}

@(private = "file")
expire_speakers :: proc(v: ^Voice) {
	for id, sp in v.speakers {
		if time.tick_since(sp.last_packet) > SPEAKER_TIMEOUT && ring_available(&sp.queue) == 0 {
			speaker_destroy(sp)
			delete_key(&v.speakers, id)
			break // map changed; the rest can wait for the next step
		}
	}
}

@(private = "file")
speaker_create :: proc() -> (sp: ^Speaker, ok: bool) {
	err: opus.Error
	dec := opus.decoder_create(SAMPLE_RATE, CHANNELS, &err)
	if dec == nil {
		log.errorf("opus: could not create decoder: %s", opus.strerror(err))
		return nil, false
	}
	sp = new(Speaker)
	sp.decoder = dec
	ring_init(&sp.queue, JITTER_MAX + 4 * FRAME)
	return sp, true
}

@(private = "file")
speaker_destroy :: proc(sp: ^Speaker) {
	opus.decoder_destroy(sp.decoder)
	ring_destroy(&sp.queue)
	free(sp)
}

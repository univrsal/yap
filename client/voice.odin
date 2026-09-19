package client

import "core:encoding/endian"
import "core:log"
import "core:math"
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

Audio is 48 kHz mono, sent as 20 ms Opus frames. Mixing is paced by the
playback ring's fill level, so it follows the output device's clock.

Noise suppression (optional): captured frames go through RNNoise before
encoding, and its voice detection gates sending: frames are only sent
while voice was detected in the last VOICE_HANGOVER, so background noise
and silence cost no bandwidth and nobody hears your room.

Loss handling: packets carry a per-sender sequence number that advances
every 20 ms whether or not anything was sent. A short gap is lost packets:
the last one is recovered from the next packet's in-band FEC when present
and the rest are concealed (PLC). A long gap is the speaker pausing (DTX
silence, or mute) and starts a fresh talkspurt.
*/

SAMPLE_RATE :: 48000
FRAME_SAMPLES :: 960 // 20 ms

VOICE_BITRATE :: 24000

// Keep ~30 ms queued for the output device.
OUTPUT_TARGET :: FRAME_SAMPLES * 3 / 2
// A speaker starts playing once 40 ms are queued (absorbs network jitter)...
JITTER_PREFILL :: 2 * FRAME_SAMPLES
// ...and is trimmed back to that if the queue ever exceeds 200 ms.
JITTER_MAX :: 10 * FRAME_SAMPLES
// Gaps longer than this many frames are pauses, not loss.
MAX_CONCEAL :: 5
// Drop a speaker's decoder after this long without packets.
SPEAKER_TIMEOUT :: 10 * time.Second
// With noise suppression on, a frame counts as voice when RNNoise's voice
// probability is at least VOICE_THRESHOLD *and* the denoised frame is
// louder than VOICE_MIN_LEVEL. The probability alone isn't enough: this
// RNNoise model rates some broadband noise (e.g. pink noise) as voice,
// although it still removes it. Measured on noise vs speech, frames it
// wrongly calls voice come out of the denoiser at -78..-65 dBFS, real
// speech at -35..-16 dBFS; -50 dBFS sits well between the two.
VOICE_THRESHOLD :: 0.5
VOICE_MIN_LEVEL :: 0.00316 // -50 dBFS RMS
// Keep sending this long after the last voice frame, so word endings and
// short pauses aren't clipped.
VOICE_HANGOVER :: 300 * time.Millisecond
// If the network thread falls behind, don't send a backlog of old audio.
MAX_CAPTURE_BACKLOG :: 5 * FRAME_SAMPLES

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
	encoder:     ^opus.Encoder,
	send_seq:    u32,
	muted:       bool,
	denoiser:    rnn.Denoiser,
	denoise:     bool, // noise suppression and the voice gate
	last_voice:  time.Tick,
	speakers:    map[u32]^Speaker,
	// Per-user playback gain (0 = muted), from the UI. Missing means 1.
	gains:       map[u32]f32,

	// Stats, reset every second by log_stats.
	captured:    int, // frames read from the microphone
	gated:       int, // frames not sent because no voice was detected
	sent_frames: int,
	sent_bytes:  int,
	received:    map[u32]int,
	concealed:   int,
	underruns:   u32, // atomic; incremented by the playback callback
}

voice_init :: proc(v: ^Voice) -> bool {
	ring_init(&v.capture, SAMPLE_RATE / 2)
	ring_init(&v.playback, SAMPLE_RATE / 2)

	err: opus.Error
	v.encoder = opus.encoder_create(SAMPLE_RATE, 1, .VOIP, &err)
	if v.encoder == nil {
		log.errorf("opus: could not create encoder: %s", opus.strerror(err))
		return false
	}
	opus.encoder_set(v.encoder, .Set_Bitrate, VOICE_BITRATE)
	opus.encoder_set(v.encoder, .Set_Signal, opus.SIGNAL_VOICE)
	opus.encoder_set(v.encoder, .Set_Complexity, 8)
	// A low-bitrate copy of each frame rides in the next packet, so a
	// single lost packet can be recovered.
	opus.encoder_set(v.encoder, .Set_Inband_FEC, 1)
	opus.encoder_set(v.encoder, .Set_Packet_Loss_Perc, 10)
	// Near-silent frames become 1-2 byte packets, which we don't send.
	opus.encoder_set(v.encoder, .Set_DTX, 1)

	ok: bool
	if v.denoiser, ok = rnn.denoiser_create(); !ok {
		log.error("rnnoise: could not create a denoiser; noise suppression is unavailable")
	}
	return true
}

voice_destroy :: proc(v: ^Voice) {
	for _, sp in v.speakers {
		speaker_destroy(sp)
	}
	delete(v.speakers)
	delete(v.gains)
	delete(v.received)
	rnn.denoiser_destroy(&v.denoiser)
	if v.encoder != nil {
		opus.encoder_destroy(v.encoder)
		v.encoder = nil
	}
	ring_destroy(&v.capture)
	ring_destroy(&v.playback)
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

	frame: [FRAME_SAMPLES]f32
	for ring_available(&v.capture) >= FRAME_SAMPLES {
		ring_read(&v.capture, frame[:])
		// The sequence number tracks time, so it advances even for frames
		// that aren't sent; receivers read long gaps as pauses.
		seq := v.send_seq
		v.send_seq += 1
		v.captured += 1
		// Run the denoiser on every frame, even unsent ones, so its state
		// follows the room continuously.
		denoising := v.denoise && v.denoiser.state != nil
		if denoising &&
		   rnn.denoise(&v.denoiser, frame[:]) >= VOICE_THRESHOLD &&
		   rms(frame[:]) >= VOICE_MIN_LEVEL {
			v.last_voice = time.tick_now()
		}
		if v.muted || !c.has_current || !in_settled_channel(c) {
			continue
		}
		if denoising && time.tick_since(v.last_voice) > VOICE_HANGOVER {
			v.gated += 1
			continue
		}

		msg: [proto.VOICE_UP_HEADER_SIZE + opus.MAX_PACKET_SIZE]u8
		n := opus.encode_float(
			v.encoder,
			&frame[0],
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
			publish_voice(c, c.my_id)
		}
	}
}

@(private = "file")
rms :: proc(samples: []f32) -> f32 {
	sum: f32
	for s in samples {
		sum += s * s
	}
	return math.sqrt(sum / f32(len(samples)))
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
	pcm: [opus.MAX_FRAME_SAMPLES]f32
	// Concealment and FEC produce exactly one of our frames; a normal
	// decode produces whatever the packet holds.
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
	ring_write(&sp.queue, pcm[:n])
}

@(private = "file")
mix_output :: proc(v: ^Voice) {
	for ring_available(&v.playback) < OUTPUT_TARGET {
		mix: [FRAME_SAMPLES]f32
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
			frame: [FRAME_SAMPLES]f32
			got := ring_read(&sp.queue, frame[:])
			gain := v.gains[id] or_else 1
			if gain > 0 {
				for s, i in frame[:got] {
					mix[i] += s * gain
				}
			}
			if got < FRAME_SAMPLES {
				sp.playing = false // ran dry: buffer up again before resuming
			}
		}
		for &s in mix {
			s = clamp(s, -1, 1)
		}
		ring_write(&v.playback, mix[:])
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
	dec := opus.decoder_create(SAMPLE_RATE, 1, &err)
	if dec == nil {
		log.errorf("opus: could not create decoder: %s", opus.strerror(err))
		return nil, false
	}
	sp = new(Speaker)
	sp.decoder = dec
	ring_init(&sp.queue, JITTER_MAX + 4 * FRAME_SAMPLES)
	return sp, true
}

@(private = "file")
speaker_destroy :: proc(sp: ^Speaker) {
	opus.decoder_destroy(sp.decoder)
	ring_destroy(&sp.queue)
	free(sp)
}

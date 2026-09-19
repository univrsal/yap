package opus

import "core:math"
import "core:testing"

@(private = "file")
RATE :: 48000
@(private = "file")
FRAME :: 960 // 20 ms at 48 kHz

@(private = "file")
make_encoder :: proc(t: ^testing.T) -> ^Encoder {
	err: Error
	enc := encoder_create(RATE, 1, .VOIP, &err)
	testing.expect_value(t, err, Error.OK)
	testing.expect(t, enc != nil)
	return enc
}

@(private = "file")
make_decoder :: proc(t: ^testing.T) -> ^Decoder {
	err: Error
	dec := decoder_create(RATE, 1, &err)
	testing.expect_value(t, err, Error.OK)
	testing.expect(t, dec != nil)
	return dec
}

// A voice-ish test signal: two tones with a slow amplitude wobble.
@(private = "file")
signal :: proc(i: int) -> f32 {
	x := f64(i) / RATE
	env := 0.6 + 0.4 * math.sin(2 * math.PI * 3 * x)
	return f32(
		0.3 * env * (math.sin(2 * math.PI * 220 * x) + 0.5 * math.sin(2 * math.PI * 660 * x)),
	)
}

@(test)
test_version :: proc(t: ^testing.T) {
	testing.expect(t, len(string(get_version_string())) > 0)
	testing.expect_value(t, string(strerror(.Bad_Arg)), "invalid argument")
}

@(test)
test_ctl_roundtrip :: proc(t: ^testing.T) {
	enc := make_encoder(t)
	defer encoder_destroy(enc)

	// Setting and reading back checks both the request codes and that the
	// varargs are passed the way libopus reads them.
	settings := [?]struct {
		set, get: Request,
		value:    i32,
	} {
		{.Set_Bitrate, .Get_Bitrate, 24000},
		{.Set_Complexity, .Get_Complexity, 7},
		{.Set_Inband_FEC, .Get_Inband_FEC, 1},
		{.Set_Packet_Loss_Perc, .Get_Packet_Loss_Perc, 10},
		{.Set_DTX, .Get_DTX, 1},
		{.Set_Signal, .Get_Signal, SIGNAL_VOICE},
		{.Set_Max_Bandwidth, .Get_Max_Bandwidth, BANDWIDTH_WIDEBAND},
		{.Set_VBR, .Get_VBR, 0},
	}
	for s in settings {
		testing.expect_value(t, encoder_set(enc, s.set, s.value), Error.OK)
		v, err := encoder_get(enc, s.get)
		testing.expect_value(t, err, Error.OK)
		testing.expect_value(t, v, s.value)
	}

	rate, _ := encoder_get(enc, .Get_Sample_Rate)
	testing.expect_value(t, rate, RATE)
	lookahead, _ := encoder_get(enc, .Get_Lookahead)
	testing.expect(t, lookahead > 0 && lookahead < FRAME)

	// Out-of-range values and unknown requests are rejected, not ignored.
	testing.expect_value(t, encoder_set(enc, .Set_Complexity, 11), Error.Bad_Arg)
	testing.expect_value(t, encoder_ctl(enc, Request(3999)), Error.Unimplemented)
	testing.expect_value(t, encoder_reset(enc), Error.OK)
}

@(test)
test_encode_decode :: proc(t: ^testing.T) {
	enc := make_encoder(t)
	defer encoder_destroy(enc)
	dec := make_decoder(t)
	defer decoder_destroy(dec)
	testing.expect_value(t, encoder_set(enc, .Set_Bitrate, 32000), Error.OK)

	FRAMES :: 50 // one second
	input := make([]f32, FRAMES * FRAME, context.temp_allocator)
	output := make([]f32, FRAMES * FRAME, context.temp_allocator)
	for &s, i in input {
		s = signal(i)
	}

	total_bytes := 0
	packet: [MAX_PACKET_SIZE]u8
	for f in 0 ..< FRAMES {
		n := encode_float(enc, raw_data(input[f * FRAME:]), FRAME, &packet[0], len(packet))
		testing.expect(t, n > 0, "encode failed")
		if n <= 0 {
			return
		}
		total_bytes += int(n)

		testing.expect_value(t, packet_get_nb_samples(&packet[0], n, RATE), FRAME)
		testing.expect_value(t, packet_get_nb_channels(&packet[0]), 1)

		got := decode_float(dec, &packet[0], n, raw_data(output[f * FRAME:]), FRAME, 0)
		testing.expect_value(t, got, FRAME)
	}

	// ~32 kbit/s over one second is ~4000 bytes; allow for VBR.
	testing.expect(t, total_bytes > 2000 && total_bytes < 6000)

	// The codec delays the signal by its lookahead; find the best alignment
	// and require the output to closely match the input.
	lookahead, _ := encoder_get(enc, .Get_Lookahead)
	best: f64
	for lag in 0 ..= int(lookahead) * 2 {
		dot, ein, eout: f64
		for i in FRAME * 5 ..< len(input) - lag {
			a, b := f64(input[i]), f64(output[i + lag])
			dot += a * b
			ein += a * a
			eout += b * b
		}
		best = max(best, dot / math.sqrt(ein * eout))
	}
	testing.expectf(
		t,
		best > 0.95,
		"decoded audio doesn't match the input (correlation %.3f)",
		best,
	)
}

@(test)
test_loss_concealment_and_fec :: proc(t: ^testing.T) {
	enc := make_encoder(t)
	defer encoder_destroy(enc)
	dec := make_decoder(t)
	defer decoder_destroy(dec)
	encoder_set(enc, .Set_Bitrate, 24000)
	encoder_set(enc, .Set_Inband_FEC, 1)
	encoder_set(enc, .Set_Packet_Loss_Perc, 20)

	pcm: [FRAME]f32
	out: [FRAME]f32
	packets: [10][MAX_PACKET_SIZE]u8
	sizes: [10]i32
	for f in 0 ..< len(packets) {
		for &s, i in pcm {
			s = signal(f * FRAME + i)
		}
		sizes[f] = encode_float(enc, &pcm[0], FRAME, &packets[f][0], MAX_PACKET_SIZE)
		testing.expect(t, sizes[f] > 0)
	}

	// With FEC on, later packets carry a low-bitrate copy of the previous frame.
	testing.expect_value(t, packet_has_lbrr(&packets[8][0], sizes[8]), 1)

	for f in 0 ..< 5 {
		decode_float(dec, &packets[f][0], sizes[f], &out[0], FRAME, 0)
	}
	// Packet 5 is "lost": recover it from packet 6's FEC, then decode 6.
	testing.expect_value(t, decode_float(dec, &packets[6][0], sizes[6], &out[0], FRAME, 1), FRAME)
	testing.expect_value(t, decode_float(dec, &packets[6][0], sizes[6], &out[0], FRAME, 0), FRAME)
	// Packet 7 is lost with nothing to recover it from: conceal it.
	testing.expect_value(t, decode_float(dec, nil, 0, &out[0], FRAME, 0), FRAME)
	testing.expect_value(t, decode_float(dec, &packets[8][0], sizes[8], &out[0], FRAME, 0), FRAME)
}

@(test)
test_errors :: proc(t: ^testing.T) {
	enc := make_encoder(t)
	defer encoder_destroy(enc)
	dec := make_decoder(t)
	defer decoder_destroy(dec)

	pcm: [FRAME]f32
	packet: [MAX_PACKET_SIZE]u8
	// 100 samples isn't a valid Opus frame size.
	n := encode_float(enc, &pcm[0], 100, &packet[0], MAX_PACKET_SIZE)
	testing.expect_value(t, result_error(n), Error.Bad_Arg)

	// Garbage doesn't decode.
	junk := [?]u8{0xff, 0xff, 0xff}
	out: [FRAME]f32
	testing.expect(t, decode_float(dec, &junk[0], len(junk), &out[0], FRAME, 0) < 0)

	err: Error
	bad := encoder_create(44100, 1, .VOIP, &err) // unsupported rate
	testing.expect(t, bad == nil)
	testing.expect_value(t, err, Error.Bad_Arg)
}

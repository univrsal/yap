#+build !wasi
package audio

import "core:c"

import ma "client:audio/miniaudio"

// sound_decode_other decodes a WAV, FLAC or MP3 file with miniaudio, which
// also resamples it to SAMPLE_RATE and mixes it to CHANNELS.
sound_decode_other :: proc(data: []u8) -> (samples: []f32, err: string) {
	if len(data) == 0 {
		return nil, "the file is empty"
	}
	out: [^]f32
	frames: c.ulonglong
	if ma.decode(raw_data(data), c.size_t(len(data)), SAMPLE_RATE, CHANNELS, &out, &frames) !=
	   ma.SUCCESS {
		return nil, "not Opus, WAV, FLAC or MP3"
	}
	defer ma.decoded_free(out)
	n := min(int(frames), SOUND_MAX_SECONDS * SAMPLE_RATE) * CHANNELS
	samples = make([]f32, n)
	copy(samples, out[:n])
	return
}

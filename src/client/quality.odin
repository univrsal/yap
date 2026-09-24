package client

import log "../common/wlog"

import "opus"

/*
Send quality presets. Each client picks its own; receivers decode whatever
arrives (every Opus packet describes itself) and always play in stereo, so
presets can be mixed freely in a channel.

All presets use 20 ms frames, so they add no latency: Opus's delay comes
from the frame size and a fixed lookahead, not from the bitrate or mode.
Higher presets only cost bandwidth (upstream: one stream; downstream: one
per speaker).

	Voice  speech optimized (SILK), mono,    24 kbit/s
	High   full band, speech and music,  mono,    64 kbit/s
	Music  full band, speech and music,  stereo, 128 kbit/s

Noise suppression (RNNoise) is trained on speech and removes music, so
with the music-capable presets it's usually best off.
*/

Quality :: enum {
	Voice,
	High,
	Music,
}

Quality_Preset :: struct {
	name:        string, // as stored in settings.json and on the command line
	label:       string,
	description: string,
	channels:    i32,
	bitrate:     i32,
	application: opus.Application,
	signal:      i32,
	complexity:  i32,
}

QUALITY_PRESETS := [Quality]Quality_Preset {
	.Voice = {
		name = "voice",
		label = "Voice",
		description = "speech, mono, 24 kbit/s",
		channels = 1,
		bitrate = 24_000,
		application = .VOIP,
		signal = opus.SIGNAL_VOICE,
		complexity = 8,
	},
	.High = {
		name = "high",
		label = "High",
		description = "speech and music, mono, 64 kbit/s",
		channels = 1,
		bitrate = 64_000,
		application = .Audio,
		signal = opus.AUTO,
		complexity = 10,
	},
	.Music = {
		name = "music",
		label = "Music",
		description = "speech and music, stereo, 128 kbit/s",
		channels = 2,
		bitrate = 128_000,
		application = .Audio,
		signal = opus.AUTO,
		complexity = 10,
	},
}

// parse_quality maps a preset name ("voice", "high", "music") to its value.
parse_quality :: proc(name: string) -> (q: Quality, ok: bool) {
	for preset, quality in QUALITY_PRESETS {
		if preset.name == name {
			return quality, true
		}
	}
	return .Voice, false
}

// encoder_setup (re)creates the Voice's encoder for a preset. Changing the
// channel count or application needs a fresh encoder anyway.
encoder_setup :: proc(v: ^Voice, q: Quality) -> bool {
	p := QUALITY_PRESETS[q]
	err: opus.Error
	enc := opus.encoder_create(SAMPLE_RATE, p.channels, p.application, &err)
	if enc == nil {
		log.errorf("opus: could not create a %s encoder: %s", p.label, opus.strerror(err))
		return false
	}
	opus.encoder_set(enc, .Set_Bitrate, p.bitrate)
	opus.encoder_set(enc, .Set_Signal, p.signal)
	opus.encoder_set(enc, .Set_Complexity, p.complexity)
	opus.encoder_set(enc, .Set_Max_Bandwidth, opus.BANDWIDTH_FULLBAND)
	// A low-bitrate copy of each frame rides in the next packet, so a
	// single lost packet can be recovered. (Opus only does this in its
	// speech modes; music is covered by concealment.)
	opus.encoder_set(enc, .Set_Inband_FEC, 1)
	opus.encoder_set(enc, .Set_Packet_Loss_Perc, 10)
	// Near-silent frames become 1-2 byte packets, which we don't send.
	opus.encoder_set(enc, .Set_DTX, 1)

	if v.encoder != nil {
		opus.encoder_destroy(v.encoder)
	}
	v.encoder = enc
	v.quality = q
	return true
}

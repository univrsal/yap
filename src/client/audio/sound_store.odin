package audio

import "base:runtime"
import log "common:wlog"
import "core:encoding/endian"
import "core:slice"
import "core:strings"
import "core:sync"

import "client:audio/opus"

// The decoded sounds, shared by every Voice (each server's, and the UI's own)
// so that a sound is decoded once however many servers play it. A sound is
// decoded when the first Voice asks for it (sound_acquire) and freed when
// the last one lets go of it (sound_release).
//
// A sound of the user's own is named "custom:<file>" (the file is kept in the
// config folder, see ui_sounds.odin). The UI decodes it and hands the samples
// over (sound_custom_add) before any Voice asks for it; the store holds on to
// it until the UI lets go of it (sound_custom_remove).

Sound_Clip :: struct {
	name:     string,
	samples:  []f32, // at SAMPLE_RATE, `channels` (1 or 2) interleaved
	channels: int,
	refs:     int,
}

// The setting of an event with no sound.
NO_SOUND :: "none"
CUSTOM_SOUND_PREFIX :: "custom:"
// The largest sound file of one's own.
SOUND_FILE_MAX :: 5 * 1024 * 1024
// A sound is cut after this much, and a sound that isn't a loop plays at most
// ONE_SHOT_SECONDS of it.
SOUND_MAX_SECONDS :: 30
ONE_SHOT_SECONDS :: 10

// The allocator of everything here. The store is shared by threads, so it
// isn't any one thread's context.allocator; main sets this to the process's
// allocator (memtrack's, or emscripten's malloc in a browser). Left unset, as
// in tests, it is the heap.
sounds_allocator: runtime.Allocator

@(private = "file")
store: struct {
	mutex:  sync.Mutex,
	clips:  map[string]^Sound_Clip,
	// The sounds of the user's own that the store itself holds a reference
	// to (sound_custom_add).
	custom: map[string]^Sound_Clip,
}

@(private = "file")
store_allocator :: proc() -> runtime.Allocator {
	if sounds_allocator.procedure == nil {
		when ODIN_OS == .WASI {
			return context.allocator // there is no heap_allocator
		} else {
			return runtime.heap_allocator()
		}
	}
	return sounds_allocator
}

// sound_acquire returns the sound of that name ("aim/msg", "custom:x.wav"),
// decoding it if it isn't yet. It is nil for no sound, for an unknown name and
// for a sound of the user's own that isn't loaded. Let go of it with
// sound_release.
sound_acquire :: proc(name: string) -> ^Sound_Clip {
	if name == "" || name == NO_SOUND {
		return nil
	}
	sync.guard(&store.mutex)
	context.allocator = store_allocator()
	if clip, ok := store.clips[name]; ok {
		clip.refs += 1
		return clip
	}
	if strings.has_prefix(name, CUSTOM_SOUND_PREFIX) {
		return nil
	}
	data, ok := sound_data(name)
	if !ok {
		log.warnf("audio: no sound %q", name)
		return nil
	}
	samples, channels, err := sound_decode(data, name)
	if err != "" {
		log.errorf("audio: %s: %s", name, err)
		return nil
	}
	return store_add(name, samples, channels)
}

// sound_retain takes one more reference to a sound.
sound_retain :: proc(clip: ^Sound_Clip) {
	if clip != nil {
		sync.guard(&store.mutex)
		clip.refs += 1
	}
}

sound_release :: proc(clip: ^Sound_Clip) {
	if clip == nil {
		return
	}
	sync.guard(&store.mutex)
	store_unref(clip)
}

// sound_custom_add makes a sound of the user's own known by `name`
// ("custom:<file>"), from `samples` (`channels` at SAMPLE_RATE), which are
// copied. A name that is already known keeps its sound: a file of the user's
// own gets a name of its own (see ui_sounds.odin).
sound_custom_add :: proc(name: string, samples: []f32, channels: int) {
	sync.guard(&store.mutex)
	context.allocator = store_allocator()
	if name in store.custom {
		return
	}
	if clip, ok := store.clips[name]; ok {
		clip.refs += 1
		store.custom[clip.name] = clip
		return
	}
	limit := min(len(samples), SOUND_MAX_SECONDS * SAMPLE_RATE * channels)
	clip := store_add(name, slice.clone(samples[:limit]), channels)
	store.custom[clip.name] = clip
}

// sound_custom_remove lets go of a sound of the user's own. A Voice that still
// plays it keeps it until it lets go of it too.
sound_custom_remove :: proc(name: string) {
	sync.guard(&store.mutex)
	clip, ok := store.custom[name]
	if !ok {
		return
	}
	context.allocator = store_allocator()
	delete_key(&store.custom, name)
	if len(store.custom) == 0 {
		delete(store.custom)
		store.custom = nil
	}
	store_unref(clip)
}

// sound_custom_loaded says whether a sound of the user's own is known.
sound_custom_loaded :: proc(name: string) -> bool {
	sync.guard(&store.mutex)
	return name in store.custom
}

// sound_decode decodes a sound file: Ogg Opus here, and WAV, FLAC and MP3
// through miniaudio on a desktop (sound_decode_other). The samples are at
// SAMPLE_RATE, mono or stereo (`channels`), at most SOUND_MAX_SECONDS of them,
// in the context's allocator. `err` says what is wrong with a file that
// doesn't decode.
sound_decode :: proc(data: []u8, name: string) -> (samples: []f32, channels: int, err: string) {
	if len(data) >= 4 && string(data[:4]) == "OggS" {
		if !strings.contains(string(data[:min(len(data), 512)]), "OpusHead") {
			return nil, 0, "Ogg Vorbis, not Opus"
		}
		samples, channels = decode_ogg_opus(data, name)
		if samples == nil {
			return nil, 0, "its Opus data is broken"
		}
	} else {
		samples, err = sound_decode_other(data)
		if err != "" {
			return
		}
		channels = CHANNELS // what miniaudio hands over
	}
	// Stereo with the same on both sides is kept as mono.
	if channels == 2 {
		if mono := to_mono(samples); mono != nil {
			delete(samples)
			samples, channels = mono, 1
		}
	}
	limit := SOUND_MAX_SECONDS * SAMPLE_RATE * channels
	if len(samples) > limit {
		short := slice.clone(samples[:limit])
		delete(samples)
		samples = short
	}
	if len(samples) == 0 {
		delete(samples)
		return nil, 0, "no sound in it"
	}
	return
}

// decode_ogg_opus decodes an Ogg Opus file, with its own channel count (1 or
// 2). The samples are allocated once, as many as the stream says it has (its
// last granule position), rather than grown while decoding.
decode_ogg_opus :: proc(data: []u8, name: string) -> (samples: []f32, channels: int) {
	// The last granule position: how many samples (at 48 kHz, whatever the
	// stream was made from) the stream ends at, pre-skip included.
	last_granule := 0
	for at := 0; at + 27 <= len(data) && string(data[at:at + 4]) == "OggS"; {
		if granule := i64(endian.unchecked_get_u64le(data[at + 6:])); granule > 0 {
			last_granule = int(granule)
		}
		segments := int(data[at + 26])
		next := at + 27 + segments
		if next > len(data) {
			break
		}
		for i in 0 ..< segments {
			next += int(data[at + 27 + i])
		}
		at = next
	}

	decoder: ^opus.Decoder
	defer if decoder != nil {
		opus.decoder_destroy(decoder)
	}
	fail :: proc(samples: []f32, why, name: string) -> ([]f32, int) {
		log.errorf("opus: %s in %s", why, name)
		delete(samples)
		return nil, 0
	}
	filled := 0
	packet: [dynamic]u8
	defer delete(packet)
	at := 0
	packet_count := 0
	pre_skip := 0
	for at < len(data) {
		if at + 27 > len(data) || string(data[at:at + 4]) != "OggS" {
			return fail(samples, "invalid Ogg page", name)
		}
		segments := int(data[at + 26])
		lacing_at := at + 27
		body_at := lacing_at + segments
		if body_at > len(data) {
			return fail(samples, "truncated Ogg page", name)
		}
		body_end := body_at
		for i in 0 ..< segments {
			body_end += int(data[lacing_at + i])
		}
		if body_end > len(data) {
			return fail(samples, "truncated Ogg packet", name)
		}
		for i in 0 ..< segments {
			count := int(data[lacing_at + i])
			append(&packet, ..data[body_at:body_at + count])
			body_at += count
			if count == 255 {
				continue
			}
			switch packet_count {
			case 0:
				// Version 1, mono or stereo.
				if len(packet) < 19 ||
				   string(packet[:8]) != "OpusHead" ||
				   packet[8] != 1 ||
				   packet[9] < 1 ||
				   packet[9] > 2 {
					return fail(samples, "invalid Opus header", name)
				}
				channels = int(packet[9])
				pre_skip = int(endian.unchecked_get_u16le(packet[10:]))
				err: opus.Error
				decoder = opus.decoder_create(SAMPLE_RATE, i32(channels), &err)
				if decoder == nil {
					log.errorf(
						"opus: could not create a decoder for %s: %s",
						name,
						opus.strerror(err),
					)
					return nil, 0
				}
				samples = make([]f32, max(last_granule - pre_skip, 0) * channels)
			case 1:
			// OpusTags contains no audio data.
			case:
				frame: [opus.MAX_FRAME_SAMPLES * CHANNELS]f32
				n := opus.decode_float(
					decoder,
					raw_data(packet[:]),
					i32(len(packet)),
					&frame[0],
					opus.MAX_FRAME_SAMPLES,
					0,
				)
				if n < 0 {
					return fail(samples, string(opus.strerror(opus.Error(n))), name)
				}
				skip := min(pre_skip, int(n))
				pre_skip -= skip
				// The last packet decodes past the end of the stream.
				decoded := frame[skip * channels:int(n) * channels]
				filled += copy(samples[filled:], decoded)
			}
			packet_count += 1
			clear(&packet)
		}
		at = body_end
	}
	if packet_count < 3 || filled == 0 {
		return fail(samples, "no audio", name)
	}
	return samples[:filled], channels
}

// store_add adds a sound with one reference. Call with the mutex held and
// the store's allocator.
// to_mono returns a mono copy of stereo samples whose channels are the same
// throughout, and nil for any others.
@(private = "file")
to_mono :: proc(stereo: []f32) -> []f32 {
	frames := len(stereo) / 2
	for f in 0 ..< frames {
		if stereo[2 * f] != stereo[2 * f + 1] {
			return nil
		}
	}
	mono := make([]f32, frames)
	for &m, f in mono {
		m = stereo[2 * f]
	}
	return mono
}

@(private = "file")
store_add :: proc(name: string, samples: []f32, channels: int) -> ^Sound_Clip {
	clip := new(Sound_Clip)
	clip^ = {
		name     = strings.clone(name),
		samples  = samples,
		channels = channels,
		refs     = 1,
	}
	store.clips[clip.name] = clip
	return clip
}

// store_unref drops a reference, and the sound with the last one. Call with
// the mutex held.
@(private = "file")
store_unref :: proc(clip: ^Sound_Clip) {
	clip.refs -= 1
	if clip.refs > 0 {
		return
	}
	context.allocator = store_allocator()
	delete_key(&store.clips, clip.name)
	if len(store.clips) == 0 {
		delete(store.clips)
		store.clips = nil
	}
	delete(clip.samples)
	delete(clip.name)
	free(clip)
}

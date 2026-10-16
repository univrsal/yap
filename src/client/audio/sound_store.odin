package audio

import "base:runtime"
import log "common:wlog"
import "core:strings"
import "core:sync"

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
	clip := store_add(name, cut(samples[:limit]), channels)
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
sound_decode :: proc(
	data: []u8,
	name: string,
) -> (
	samples: []f32,
	channels: int,
	err: string,
) {
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
		short := cut(samples[:limit])
		delete(samples)
		samples = short
	}
	if len(samples) == 0 {
		delete(samples)
		return nil, 0, "no sound in it"
	}
	return
}

@(private = "file")
cut :: proc(samples: []f32) -> []f32 {
	out := make([]f32, len(samples))
	copy(out, samples)
	return out
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

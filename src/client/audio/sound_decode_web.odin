#+build wasi
package audio

// A browser decodes the user's own sound files itself (web/sounds.js), so only
// the built-in Opus sounds are decoded here.
sound_decode_other :: proc(data: []u8) -> (samples: []f32, err: string) {
	return nil, "not Ogg Opus"
}

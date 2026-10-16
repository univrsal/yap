#+build !wasi
package client

import "core:math"
import "core:os"
import "core:strings"
import "core:testing"

import "client:audio"
import "client:settings"

// A file of one's own is copied into the sounds folder next to the settings,
// under a name of its own, and the copy is deleted once no event plays it.
@(test)
test_sound_files :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "yap-sounds-*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	ui := new(UI)
	defer free(ui)
	ui.opts.settings_path, _ = os.join_path({dir, "settings.json"}, context.temp_allocator)
	ui.settings = settings.DEFAULT_SETTINGS
	defer settings.settings_destroy(&ui.settings)
	defer sounds_destroy(ui)

	write :: proc(dir, name: string, data: []u8) -> string {
		path, _ := os.join_path({dir, name}, context.temp_allocator)
		_ = os.write_entire_file(path, data)
		return path
	}
	copied :: proc(dir, file: string) -> bool {
		path, _ := os.join_path({dir, "sounds", file}, context.temp_allocator)
		return os.exists(path)
	}

	tone := write(dir, "My Tone.wav", test_wav(440))
	sound_file_picked(ui, .Ring, tone)
	testing.expect_value(t, settings.sound_name(&ui.settings, .Ring), "custom:My Tone.wav")
	testing.expect(t, copied(dir, "My Tone.wav"))
	testing.expect(t, audio.sound_custom_loaded("custom:My Tone.wav"))
	testing.expect_value(t, sound_effective(ui, .Ring), "custom:My Tone.wav")

	// The same file again is the same copy; another one of the same name
	// gets a name of its own.
	sound_file_picked(ui, .Mention, tone)
	testing.expect_value(t, settings.sound_name(&ui.settings, .Mention), "custom:My Tone.wav")
	other_dir, _ := os.join_path({dir, "other"}, context.temp_allocator)
	_ = os.make_directory(other_dir)
	sound_file_picked(ui, .Message, write(other_dir, "My Tone.wav", test_wav(880)))
	testing.expect_value(t, settings.sound_name(&ui.settings, .Message), "custom:My Tone-2.wav")

	// A copy that some event still plays is kept.
	sound_choose(ui, .Ring, "")
	testing.expect(t, copied(dir, "My Tone.wav"))
	sound_choose(ui, .Mention, "aim/mail")
	testing.expect(t, !copied(dir, "My Tone.wav"))
	testing.expect(t, !audio.sound_custom_loaded("custom:My Tone.wav"))
	sound_choose(ui, .Message, "")
	testing.expect(t, !copied(dir, "My Tone-2.wav"))

	// A file that won't play isn't chosen, and says why.
	sound_file_picked(
		ui,
		.Ring,
		write(dir, "broken.wav", transmute([]u8)string("RIFF....WAVEjunk")),
	)
	testing.expect_value(t, settings.sound_name(&ui.settings, .Ring), "")
	testing.expect(t, strings.contains(ui.sounds.notes[.Ring], "can't be played"))

	// A long name is cut, keeping its extension.
	long := strings.repeat("x", 100, context.temp_allocator)
	sound_file_picked(
		ui,
		.Knock,
		write(dir, strings.concatenate({long, ".wav"}, context.temp_allocator), test_wav(220)),
	)
	name := settings.sound_name(&ui.settings, .Knock)
	testing.expect(
		t,
		strings.has_suffix(name, ".wav") &&
		len(name) - len(audio.CUSTOM_SOUND_PREFIX) <= SOUND_FILE_NAME_MAX,
	)
	sound_choose(ui, .Knock, "")
}

// test_wav is a quarter of a second of a tone, as an 8 kHz mono WAV, in the
// temp allocator.
@(private = "file")
test_wav :: proc(freq: f64) -> []u8 {
	RATE :: 8000
	FRAMES :: RATE / 4
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
	put16(&wav, 1)
	put16(&wav, 1)
	put32(&wav, RATE)
	put32(&wav, RATE * 2)
	put16(&wav, 2)
	put16(&wav, 16)
	append(&wav, "data")
	put32(&wav, FRAMES * 2)
	for i in 0 ..< FRAMES {
		put16(&wav, u16(i16(math.sin(f64(i) * 2 * math.PI * freq / RATE) * 10000)))
	}
	return wav[:]
}

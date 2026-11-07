package main

import "core:os"
import "core:strings"

import "client:audio"
import "client:conn"
import "client:settings"

// How the voice is set up: the devices, the quality, noise suppression and the
// gate. They are the window client's (settings.json, read, never written) until
// something is changed here, from then on they are kept in cli.json, which is
// this client's own.

Voice_Settings :: struct {
	input_device:      string, // "" for the system's
	output_device:     string,
	quality:           string, // voice, high or music
	noise_suppression: bool,
	voice_gate:        bool,
	gate_open_db:      f32,
	gate_close_db:     f32,
}

voice_settings_destroy :: proc(v: ^Voice_Settings) {
	delete(v.input_device)
	delete(v.output_device)
	delete(v.quality)
	v^ = {}
}

voice_settings_clone :: proc(v: Voice_Settings) -> Voice_Settings {
	out := v
	out.input_device = strings.clone(v.input_device)
	out.output_device = strings.clone(v.output_device)
	out.quality = strings.clone(v.quality)
	return out
}

// voice_settings_load reads the voice settings from cli.json if it has any, else
// from the window client's settings (`gui_path`), else the defaults.
voice_settings_load :: proc(cli_path, gui_path: string) -> Voice_Settings {
	file := cli_file_load(cli_path)
	defer cli_file_destroy(&file)
	if v, has := file.voice.?; has {
		return voice_settings_clone(v)
	}
	gui := settings.DEFAULT_SETTINGS
	loaded := false
	if gui_path != "" && os.exists(gui_path) {
		gui = settings.settings_load(gui_path)
		loaded = true
	}
	defer if loaded {
		settings.settings_destroy(&gui)
	}
	return Voice_Settings {
		input_device = strings.clone(gui.input_device),
		output_device = strings.clone(gui.output_device),
		quality = strings.clone(gui.quality if gui.quality != "" else "voice"),
		noise_suppression = gui.noise_suppression,
		voice_gate = gui.voice_gate,
		gate_open_db = gui.gate_open_db,
		gate_close_db = gui.gate_close_db,
	}
}

// voice_settings_save keeps the voice settings in cli.json, leaving the rest of
// the file as it is.
voice_settings_save :: proc(path: string, v: Voice_Settings) -> bool {
	if path == "" {
		return false
	}
	file := cli_file_load(path)
	defer cli_file_destroy(&file)
	if old, has := file.voice.?; has {
		voice_settings_destroy(&old)
	}
	file.voice = voice_settings_clone(v)
	return cli_file_save(path, file)
}

// apply_voice_settings tells a connection how to send and what to filter.
apply_voice_settings :: proc(c: ^conn.Server_Conn, v: Voice_Settings) {
	q, _ := audio.parse_quality(v.quality)
	open := clamp(v.gate_open_db, audio.MIN_LEVEL_DB, 0)
	conn.push_command(&c.commands, conn.Quality_Command{q})
	conn.push_command(&c.commands, conn.Noise_Command{v.noise_suppression})
	conn.push_command(&c.commands, conn.Gate_Command{v.voice_gate, open, clamp(v.gate_close_db, audio.MIN_LEVEL_DB, open)})
}

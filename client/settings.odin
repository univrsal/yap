package client

import "core:encoding/hex"
import "core:encoding/json"
import "core:log"
import "core:os"
import "core:strings"

import "../proto"

/*
Client settings, kept in <config dir>/yap/settings.json:

	{
		"server": "localhost:7777",
		"input_device": "",
		"output_device": "Built-in Audio Analog Stereo",
		"quality": "voice",
		"noise_suppression": true,
		"tray": false,
		"close_to_tray": true,
		"minimize_to_tray": false,
		"voice_gate": true,
		"gate_open_db": -45,
		"gate_close_db": -55,
		"users": {
			"8e41fa62833a5a7751cd6873b91156e0dfc22fa2f939c26824a07ff64764a933": { "volume": 0.5, "muted": false }
		}
	}

Devices are stored by name rather than by miniaudio's device id: ids are
backend-specific binary blobs, while names are stable across runs and
readable. An empty name, or one that's no longer present (unplugged),
means the system default.
*/
Settings :: struct {
	server:            string, // last server connected to
	name:              string, // the name to go by
	input_device:      string,
	output_device:     string,
	// Send quality preset by name ("voice", "high", "music"; quality.odin).
	quality:           string,
	// RNNoise on the microphone.
	noise_suppression: bool,
	// Show an icon in the system tray (ui_tray.odin).
	tray:              bool,
	// What the window's own buttons do while that icon is there: hide
	// the client in the tray, or what they usually do. Minimizing is
	// only ours to decide where the desktop says it has happened.
	close_to_tray:     bool,
	minimize_to_tray:  bool,
	// Only send while the microphone level is above the thresholds (dBFS);
	// see gate.odin.
	voice_gate:        bool,
	gate_open_db:      f32,
	gate_close_db:     f32,
	// How to play other users, keyed by their public key (64 hex digits),
	// which is what identifies a user; names can be copied. Users with
	// default settings aren't stored.
	users:             map[string]User_Settings,
}

User_Settings :: struct {
	volume: f32, // 1 = as sent, 0..2
	muted:  bool,
}

DEFAULT_USER :: User_Settings {
	volume = 1,
}
MAX_USER_VOLUME :: 3

DEFAULT_SETTINGS :: Settings {
	noise_suppression = true,
	close_to_tray     = true,
	voice_gate        = true,
	gate_open_db      = DEFAULT_GATE_OPEN_DB,
	gate_close_db     = DEFAULT_GATE_CLOSE_DB,
}

// settings_load reads `path`, falling back to defaults if it doesn't exist
// or can't be parsed. The strings are owned by the result.
settings_load :: proc(path: string) -> (s: Settings) {
	// Fields missing from the file keep their defaults.
	s = DEFAULT_SETTINGS
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return
	}
	if json_err := json.unmarshal(data, &s); json_err != nil {
		log.warnf("ignoring unreadable settings in %s: %v", path, json_err)
		settings_destroy(&s)
		return DEFAULT_SETTINGS
	}
	return
}

settings_save :: proc(path: string, s: Settings) {
	data, err := json.marshal(
		s,
		{pretty = true, use_spaces = true, spaces = 2},
		context.temp_allocator,
	)
	if err != nil {
		log.errorf("could not encode settings: %v", err)
		return
	}
	dir, _ := os.split_path(path)
	if dir != "" {
		os.make_directory_all(dir)
	}
	if write_err := os.write_entire_file(path, data); write_err != nil {
		log.errorf("could not save settings to %s: %v", path, write_err)
	}
}

settings_destroy :: proc(s: ^Settings) {
	delete(s.server)
	delete(s.name)
	delete(s.quality)
	delete(s.input_device)
	delete(s.output_device)
	for key in s.users {
		delete(key)
	}
	delete(s.users)
	s^ = {}
}

// set_setting replaces an owned string field.
set_setting :: proc(field: ^string, value: string) {
	delete(field^)
	field^ = strings.clone(value)
}

user_key :: proc(key: [proto.KEY_SIZE]u8) -> string {
	key := key
	return string(hex.encode(key[:], context.temp_allocator))
}

// parse_user_key turns a settings key back into a public key; entries in
// any other form (e.g. the 8-digit ids of older versions) are skipped.
parse_user_key :: proc(s: string) -> (key: [proto.KEY_SIZE]u8, ok: bool) {
	if len(s) != 2 * proto.KEY_SIZE {
		return
	}
	raw := hex.decode(transmute([]u8)s, context.temp_allocator) or_return
	copy(key[:], raw)
	return key, true
}

user_settings :: proc(s: ^Settings, key: [proto.KEY_SIZE]u8) -> User_Settings {
	u := s.users[user_key(key)] or_else DEFAULT_USER
	u.volume = clamp(u.volume, 0, MAX_USER_VOLUME)
	return u
}

set_user_settings :: proc(s: ^Settings, user: [proto.KEY_SIZE]u8, u: User_Settings) {
	key := user_key(user)
	if u == DEFAULT_USER {
		if key in s.users {
			owned, _ := delete_key(&s.users, key)
			delete(owned)
		}
		return
	}
	if key in s.users {
		s.users[key] = u
	} else {
		s.users[strings.clone(key)] = u
	}
}

// settings_quality is the configured preset; Voice if unset or unknown.
settings_quality :: proc(s: ^Settings) -> Quality {
	q, _ := parse_quality(s.quality)
	return q
}

// gate_command is the voice gate as configured in `s`.
gate_command :: proc(s: ^Settings) -> Gate_Command {
	open := clamp(s.gate_open_db, MIN_LEVEL_DB, 0)
	return {s.voice_gate, open, clamp(s.gate_close_db, MIN_LEVEL_DB, open)}
}

// user_gain is what the mixer multiplies a user's audio by.
user_gain :: proc(u: User_Settings) -> f32 {
	return 0 if u.muted else u.volume
}

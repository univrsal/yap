package client

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"

/*
Client settings, kept in <config dir>/yap/settings.json:

	{
		"server": "localhost:7777",
		"input_device": "",
		"output_device": "Built-in Audio Analog Stereo",
		"noise_suppression": true,
		"users": {
			"8e41fa62": { "volume": 0.5, "muted": false }
		}
	}

Devices are stored by name rather than by miniaudio's device id: ids are
backend-specific binary blobs, while names are stable across runs and
readable. An empty name, or one that's no longer present (unplugged),
means the system default.
*/
Settings :: struct {
	server:            string, // last server connected to
	input_device:      string,
	output_device:     string,
	// RNNoise on the microphone, plus only sending while voice is detected.
	noise_suppression: bool,
	// How to play other users, keyed by user id (8 hex digits). Users with
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

user_key :: proc(id: u32) -> string {
	return fmt.tprintf("%08x", id)
}

user_settings :: proc(s: ^Settings, id: u32) -> User_Settings {
	u := s.users[user_key(id)] or_else DEFAULT_USER
	u.volume = clamp(u.volume, 0, MAX_USER_VOLUME)
	return u
}

set_user_settings :: proc(s: ^Settings, id: u32, u: User_Settings) {
	key := user_key(id)
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

// user_gain is what the mixer multiplies a user's audio by.
user_gain :: proc(u: User_Settings) -> f32 {
	return 0 if u.muted else u.volume
}

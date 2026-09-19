package client

import "core:encoding/json"
import "core:log"
import "core:os"
import "core:strings"

/*
Client settings, kept in <config dir>/yap/settings.json:

	{
		"server": "localhost:7777",
		"input_device": "",
		"output_device": "Built-in Audio Analog Stereo"
	}

Devices are stored by name rather than by miniaudio's device id: ids are
backend-specific binary blobs, while names are stable across runs and
readable. An empty name, or one that's no longer present (unplugged),
means the system default.
*/
Settings :: struct {
	server:        string, // last server connected to
	input_device:  string,
	output_device: string,
}

// settings_load reads `path`, falling back to defaults if it doesn't exist
// or can't be parsed. The strings are owned by the result.
settings_load :: proc(path: string) -> (s: Settings) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return
	}
	if json_err := json.unmarshal(data, &s); json_err != nil {
		log.warnf("ignoring unreadable settings in %s: %v", path, json_err)
		settings_destroy(&s)
		return {}
	}
	return
}

settings_save :: proc(path: string, s: Settings) {
	data, err := json.marshal(s, {pretty = true, use_spaces = true, spaces = 2}, context.temp_allocator)
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
	s^ = {}
}

// set_setting replaces an owned string field.
set_setting :: proc(field: ^string, value: string) {
	delete(field^)
	field^ = strings.clone(value)
}

package main

import "core:encoding/json"
import "core:os"

import "common:."

// cli.json, what this client keeps for itself, apart from the window client's
// settings.json (which it reads and never writes): the voice settings, and the
// servers added and taken away here.

Saved_Server :: struct {
	address:  string,
	password: string,
	channel:  string, // the channel to look at when it is connected to again
}

Cli_File :: struct {
	voice:   Maybe(Voice_Settings),
	// Servers connected to here with /connect: they are connected to at the next start.
	servers: [dynamic]Saved_Server,
	// Servers of the window client that were taken away here: they are not
	// connected to, though the window client still has them.
	hidden:  [dynamic]string,
}

cli_file_destroy :: proc(f: ^Cli_File) {
	if v, has := f.voice.?; has {
		voice_settings_destroy(&v)
	}
	for s in f.servers {
		delete(s.address)
		delete(s.password)
		delete(s.channel)
	}
	delete(f.servers)
	for h in f.hidden {
		delete(h)
	}
	delete(f.hidden)
	f^ = {}
}

// cli_file_load reads the file; one that is missing or unreadable is an empty one.
cli_file_load :: proc(path: string) -> (f: Cli_File) {
	if path == "" || !os.exists(path) {
		return
	}
	data, ok := common.store_read(path, context.temp_allocator)
	if !ok {
		return
	}
	if err := json.unmarshal(transmute([]u8)data, &f); err != nil {
		cli_file_destroy(&f)
		return {}
	}
	return
}

cli_file_save :: proc(path: string, f: Cli_File) -> bool {
	if path == "" {
		return false
	}
	data, err := json.marshal(
		f,
		{pretty = true, use_spaces = true, spaces = 2},
		context.temp_allocator,
	)
	if err != nil {
		return false
	}
	return common.store_write(path, string(data), private = true)
}

package server

import "core:encoding/json"
import "core:log"
import "core:os"

import "../proto"

/*
Channel list, loaded once at startup:

	{
		"channels": [
			{ "name": "Lobby" },
			{ "name": "Gaming" }
		]
	}

New users land in the first channel. Channels are objects rather than
bare strings so fields like a description or user limit can be added
later without changing the format.
*/

DEFAULT_CHANNELS_FILE :: "channels.json"
DEFAULT_CHANNEL_NAME :: "Lobby"

Channel_Config :: struct {
	name: string,
}

Channels_File :: struct {
	channels: []Channel_Config,
}

// load_channels returns the channel names from `path`, or a single
// default channel if the file doesn't exist. A file that exists but is
// invalid is an error rather than silently ignored.
load_channels :: proc(path: string) -> (names: []string, ok: bool) {
	if !os.exists(path) {
		log.infof("no %s, using a single %q channel", path, DEFAULT_CHANNEL_NAME)
		names = make([]string, 1)
		names[0] = DEFAULT_CHANNEL_NAME
		return names, true
	}

	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		log.errorf("failed to read %s: %v", path, err)
		return
	}

	file: Channels_File
	if json_err := json.unmarshal(data, &file); json_err != nil {
		log.errorf("%s is not valid: %v", path, json_err)
		return
	}

	switch {
	case len(file.channels) == 0:
		log.errorf("%s has no channels", path)
		return
	case len(file.channels) > proto.MAX_CHANNELS:
		log.errorf(
			"%s has %d channels; the maximum is %d",
			path,
			len(file.channels),
			proto.MAX_CHANNELS,
		)
		return
	}

	names = make([]string, len(file.channels))
	for ch, i in file.channels {
		if len(ch.name) == 0 || len(ch.name) > proto.MAX_CHANNEL_NAME_SIZE {
			log.errorf(
				"%s: channel %d must have a name of 1 to %d bytes",
				path,
				i + 1,
				proto.MAX_CHANNEL_NAME_SIZE,
			)
			return
		}
		for prev in names[:i] {
			if prev == ch.name {
				log.errorf("%s: channel %q is listed twice", path, ch.name)
				return
			}
		}
		names[i] = ch.name
	}
	log.infof("loaded %d channels from %s", len(names), path)
	return names, true
}

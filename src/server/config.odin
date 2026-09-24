package server

import "core:encoding/json"
import "core:log"
import "core:os"
import "core:reflect"
import "core:strings"

import "../common"
import "../proto"

/*
The server's settings, all in one file (config.json by default), read
once at startup:

	{
		"port": 7777,
		"key": "<64 hex digits>",
		"password": "",
		"log_level": "info",
		"log_file": "",
		"relay": {
			"enabled": false,
			"port": 8080,
			"web_dir": "web/out"
		},
		"channels": [
			{ "name": "Lobby" },
			{ "name": "Gaming" }
		]
	}

port       the UDP port to listen on.
key        the server's private key. Keep it: clients remember the
           public half and refuse to connect if it changes.
password   what clients have to give to get in; empty for none.
log_level  the lowest level to log: debug, info, warn or error.
log_file   also append the log to this file; empty for none.
relay      serve the web client over HTTP on `port` and relay browsers to
           this server over WebSockets (relay.odin), with the web build
           in `web_dir`; empty for web/out, or web in a release archive.
channels   the channel layout. New users land in the first channel.
           Channels are objects rather than bare strings so fields like a
           description or user limit can be added later.

Fields left out keep the defaults above, and with no channels there's a
single Lobby.

If the file doesn't exist it's written with the defaults and a new key.
A server that predates it kept those in server.key and channels.json,
and whatever of those is in the working directory is taken over into the
new file, so clients keep trusting the key. A file without a key gets a
new one written back into it.

The file holds the key and the password, so it's written readable by its
owner only.
*/

DEFAULT_CONFIG_FILE :: "config.json"
DEFAULT_PORT :: 7777
DEFAULT_RELAY_PORT :: 8080
DEFAULT_CHANNEL_NAME :: "Lobby"

// Where a server from before config.json kept its key and channels.
@(private = "file")
LEGACY_KEY_FILE :: "server.key"
@(private = "file")
LEGACY_CHANNELS_FILE :: "channels.json"

Config :: struct {
	port:      int,
	key:       string,
	password:  string,
	log_level: string,
	log_file:  string,
	relay:     Relay_Config,
	channels:  []Channel_Config,
}

Relay_Config :: struct {
	enabled: bool,
	port:    int,
	web_dir: string,
}

Channel_Config :: struct {
	name: string,
}

// The parts of a Config the server runs on, checked and parsed.
Settings :: struct {
	port:      int,
	key:       string, // hex; parsed by run_server
	password:  string,
	log_level: common.Log_Level,
	log_file:  string,
	relay:     Relay_Config, // web_dir resolved, see default_web_dir
	channels:  []string,
}

@(private = "file")
default_config :: proc() -> Config {
	return {
		port = DEFAULT_PORT,
		log_level = "info",
		relay = {port = DEFAULT_RELAY_PORT, web_dir = default_web_dir()},
	}
}

/*
load_config reads the config at `path`, creating it first if it doesn't
exist. Anything wrong with it is logged, and fails the load rather than
being ignored: a server that silently ran without its password would be
worse than one that doesn't start.
*/
load_config :: proc(path: string) -> (settings: Settings, ok: bool) {
	cfg := default_config()
	if !os.exists(path) {
		create_config(path, &cfg) or_return
		return check_config(path, cfg)
	}

	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		log.errorf("failed to read %s: %v", path, err)
		return
	}
	if json_err := json.unmarshal(data, &cfg); json_err != nil {
		log.errorf("%s is not valid: %v", path, json_err)
		return
	}
	settings = check_config(path, cfg) or_return
	if cfg.key == "" {
		cfg.key = common.generate_private_key() or_return
		save_config(path, cfg) or_return
		settings.key = cfg.key
		log.infof("%s had no key; generated a new one and saved it there", path)
	}
	return settings, true
}

// create_config fills in what a server from before config.json left
// behind, a new key if there isn't one, and writes the result.
@(private = "file")
create_config :: proc(path: string, cfg: ^Config) -> bool {
	if os.exists(LEGACY_KEY_FILE) {
		data, err := os.read_entire_file(LEGACY_KEY_FILE, context.allocator)
		if err != nil {
			log.errorf("failed to read %s: %v", LEGACY_KEY_FILE, err)
			return false
		}
		cfg.key = strings.trim_space(string(data))
		log.infof("taking the key over from %s", LEGACY_KEY_FILE)
	} else {
		cfg.key = common.generate_private_key() or_return
		log.info("generated a new private key")
	}

	if os.exists(LEGACY_CHANNELS_FILE) {
		data, err := os.read_entire_file(LEGACY_CHANNELS_FILE, context.allocator)
		if err != nil {
			log.errorf("failed to read %s: %v", LEGACY_CHANNELS_FILE, err)
			return false
		}
		legacy: struct {
			channels: []Channel_Config,
		}
		if json_err := json.unmarshal(data, &legacy); json_err != nil {
			log.errorf("%s is not valid: %v", LEGACY_CHANNELS_FILE, json_err)
			return false
		}
		cfg.channels = legacy.channels
		log.infof("taking the channels over from %s", LEGACY_CHANNELS_FILE)
	} else {
		cfg.channels = make([]Channel_Config, 1)
		cfg.channels[0] = {DEFAULT_CHANNEL_NAME}
	}

	if !save_config(path, cfg^) {
		return false
	}
	log.infof("wrote a new config to %s", path)
	return true
}

@(private = "file")
save_config :: proc(path: string, cfg: Config) -> bool {
	data, err := json.marshal(cfg, {pretty = true, use_spaces = true, spaces = 2}, context.temp_allocator)
	if err != nil {
		log.errorf("could not encode the config: %v", err)
		return false
	}
	return common.store_write(path, string(data), private = true)
}

@(private = "file")
check_config :: proc(path: string, cfg: Config) -> (s: Settings, ok: bool) {
	if cfg.port <= 0 || cfg.port > 65535 {
		log.errorf("%s: invalid port %d", path, cfg.port)
		return
	}
	if len(cfg.password) > proto.MAX_PASSWORD_SIZE {
		log.errorf("%s: the password is longer than %d bytes", path, proto.MAX_PASSWORD_SIZE)
		return
	}
	level, level_ok := reflect.enum_from_name(common.Log_Level, cfg.log_level)
	if !level_ok {
		log.errorf("%s: unknown log_level %q (debug, info, warn or error)", path, cfg.log_level)
		return
	}
	relay := cfg.relay
	if relay.enabled {
		if relay.port <= 0 || relay.port > 65535 {
			log.errorf("%s: invalid relay port %d", path, relay.port)
			return
		}
		if relay.port == cfg.port {
			// Allowed (one's TCP, the other UDP), but rarely meant.
			log.warnf("%s: the relay and the server share port %d", path, cfg.port)
		}
	}
	if relay.web_dir == "" {
		relay.web_dir = default_web_dir()
	}

	s = {
		port      = cfg.port,
		key       = cfg.key,
		password  = cfg.password,
		log_level = level,
		log_file  = cfg.log_file,
		relay     = relay,
	}
	s.channels = check_channels(path, cfg.channels) or_return
	return s, true
}

// check_channels returns the channel names, or a single default channel
// if there are none.
@(private = "file")
check_channels :: proc(path: string, channels: []Channel_Config) -> (names: []string, ok: bool) {
	if len(channels) == 0 {
		log.infof("%s lists no channels, using a single %q channel", path, DEFAULT_CHANNEL_NAME)
		names = make([]string, 1)
		names[0] = DEFAULT_CHANNEL_NAME
		return names, true
	}
	if len(channels) > proto.MAX_CHANNELS {
		log.errorf("%s has %d channels; the maximum is %d", path, len(channels), proto.MAX_CHANNELS)
		return
	}

	names = make([]string, len(channels))
	for ch, i in channels {
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
	log.infof("%s: %d channels", path, len(names))
	return names, true
}

// default_web_dir is where the web build is: web/out after web/build.sh,
// or web in a release archive.
@(private = "file")
default_web_dir :: proc() -> string {
	if !os.exists(DEFAULT_WEB_DIR) && os.exists("web/index.html") {
		return "web"
	}
	return DEFAULT_WEB_DIR
}

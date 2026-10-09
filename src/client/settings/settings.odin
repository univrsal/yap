package settings

import log "common:wlog"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"

import "client:audio"
import "common:."
import "common:proto"

/*
Client settings, kept in <config dir>/yap/settings.json:

	{
		"joined_servers": [
			{ "address": "localhost:7777", "password": "", "channel": "general" },
			{ "address": "voice.example.com:7777", "password": "hunter2", "channel": "" }
		],
		"input_device": "",
		"output_device": "Built-in Audio Analog Stereo",
		"quality": "voice",
		"theme": "system",
		"noise_suppression": true,
		"tray": false,
		"close_to_tray": true,
		"minimize_to_tray": false,
		"voice_gate": true,
		"gate_open_db": -45,
		"gate_close_db": -55,
		"notification_volume": 1,
		"app_audio_volume": 1,
		"mute_app_audio_with_mic": true,
		"ui_scale": 1,
		"chat_pictures": true,
		"chat_scale": 1,
		"image_cache_mb": 256,
		"image_cache_dir": "",
		"mute_hotkey": "Ctrl+Shift+M",
		"deafen_hotkey": "",
		"users": {
			"8e41fa62833a5a7751cd6873b91156e0dfc22fa2f939c26824a07ff64764a933/12": { "volume": 0.5, "muted": false }
		},
		"hidden_dms": {
			"8e41fa62833a5a7751cd6873b91156e0dfc22fa2f939c26824a07ff64764a933/40": 1234
		}
	}

Devices are stored by name rather than by miniaudio's device id: ids are
backend-specific binary blobs, while names are stable across runs and
readable. An empty name, or one that's no longer present (unplugged),
means the system default.

joined_servers are the servers this client has joined, in the order of
the server rail (docs/next, item 9), each with the password it was
joined with; all are connected to at start. The passwords are kept as
they are, so the file is written readable by its owner only. Settings
from before then had the last server (`server`) and the recent ones
(`recent_servers`) instead, which become the joined ones once
(settings_load).
*/
Settings :: struct {
	joined_servers:          [dynamic]Joined_Server, // in the rail's order
	// From before joined_servers, only read (settings_load).
	server:                  string `json:"server,omitempty"`,
	recent_servers:          [dynamic]Joined_Server `json:"recent_servers,omitempty"`,
	username:                string, // the account last logged in to, for the login form
	input_device:            string,
	output_device:           string,
	// Send quality preset by name ("voice", "high", "music"; audio/quality.odin).
	quality:                 string,
	// "system" (or unset), "dark" or "light" (theme.odin).
	theme:                   string,
	// RNNoise on the microphone.
	noise_suppression:       bool,
	// Show an icon in the system tray (ui_tray.odin).
	tray:                    bool,
	// What the window's own buttons do while that icon is there: hide
	// the client in the tray, or what they usually do. Minimizing is
	// only ours to decide where the desktop says it has happened.
	close_to_tray:           bool,
	minimize_to_tray:        bool,
	// Only send while the microphone level is above the thresholds (dBFS);
	// see audio/gate.odin.
	voice_gate:              bool,
	gate_open_db:            f32,
	gate_close_db:           f32,
	// How loudly local join, leave, message, and poke effects are mixed.
	notification_volume:     f32, // 1 = as encoded, 0..MAX_USER_VOLUME
	// How loudly a shared application's audio is sent
	// (ui_app_audio_native.odin).
	app_audio_volume:        f32, // 1 = as it plays, 0..MAX_USER_VOLUME
	// Muting the microphone mutes a shared application as well.
	mute_app_audio_with_mic: bool,
	// How fast files in DMs may go out and come in, in MB/s; 0 for no
	// limit (conn/files.odin).
	upload_limit:            f32,
	download_limit:          f32,
	// The UI's own zoom, independent of the display's DPI scale (see
	// window_metrics in ui.odin). 1 = 100%, MIN_UI_SCALE..MAX_UI_SCALE.
	ui_scale:                f32,
	// People's pictures beside their messages; off, the chat is
	// compact (ui_timeline.odin).
	chat_pictures:           bool,
	// The chat's text size, on top of ui_scale (it multiplies): 1 =
	// the UI's, MIN_CHAT_SCALE..MAX_CHAT_SCALE.
	chat_scale:              f32,
	// How much of people's pictures and servers' emoji to keep on disk
	// between sessions, in MB (0: none), and where; "" for the system's
	// cache folder (conn/image_cache_native.odin).
	image_cache_mb:          f32,
	image_cache_dir:         string,
	// Global hotkeys, as hotkeys.format writes them ("Ctrl+Shift+M"); ""
	// for none. See ui_hotkeys_native.odin.
	mute_hotkey:             string,
	deafen_hotkey:           string,
	// How to play other people, by their account: the server's public
	// key (64 hex digits), a slash, and the account's id on that server
	// (see server_key). Names can be copied and are the same on many
	// servers; this can't be. People with default settings aren't
	// stored.
	users:                   map[string]User_Settings,
	// DMs taken off the buddy list, keyed like `users` but with the
	// conversation's id: each is off it until a message after the one
	// noted here arrives (dm_hidden).
	hidden_dms:              map[string]u64,
}

User_Settings :: struct {
	volume: f32, // 1 = as sent, 0..2
	muted:  bool,
}

Joined_Server :: struct {
	address:  string, // as typed
	password: string, // empty for none
	channel:  string, // the channel last looked at there, to start with next time
}

DEFAULT_USER :: User_Settings {
	volume = 1,
}
MAX_USER_VOLUME :: 3

MIN_UI_SCALE :: 0.5
MAX_UI_SCALE :: 3.0
MIN_CHAT_SCALE :: 0.8
MAX_CHAT_SCALE :: 1.6

DEFAULT_SETTINGS :: Settings {
	noise_suppression       = true,
	close_to_tray           = true,
	voice_gate              = true,
	gate_open_db            = audio.DEFAULT_GATE_OPEN_DB,
	gate_close_db           = audio.DEFAULT_GATE_CLOSE_DB,
	notification_volume     = 1,
	app_audio_volume        = 1,
	mute_app_audio_with_mic = true,
	ui_scale                = 1,
	chat_pictures           = true,
	chat_scale              = 1,
	image_cache_mb          = 256,
}

// settings_load reads `path`, falling back to defaults if it doesn't exist
// or can't be parsed. The strings are owned by the result.
settings_load :: proc(path: string) -> (s: Settings) {
	// Fields missing from the file keep their defaults.
	s = DEFAULT_SETTINGS
	data, ok := common.store_read(path, context.temp_allocator)
	if !ok {
		return
	}
	if json_err := json.unmarshal(transmute([]u8)data, &s); json_err != nil {
		log.warnf("ignoring unreadable settings in %s: %v", path, json_err)
		settings_destroy(&s)
		return DEFAULT_SETTINGS
	}
	// Settings from before joining many servers: the recent servers, or
	// before those the last one, are the joined ones, once.
	if len(s.joined_servers) == 0 {
		for r in s.recent_servers {
			join_server(&s, r.address, r.password)
			set_joined_channel(&s, r.address, r.channel)
		}
		if len(s.recent_servers) == 0 && s.server != "" {
			join_server(&s, s.server, "")
		}
	}
	for r in s.recent_servers {
		joined_server_destroy(r)
	}
	delete(s.recent_servers)
	s.recent_servers = nil
	delete(s.server)
	s.server = ""
	// Per-user settings from before accounts went by the user's key,
	// which nothing is known by any more.
	stale := make([dynamic]string, context.temp_allocator)
	for k in s.users {
		if _, _, parsed := parse_server_key(k); !parsed {
			append(&stale, k)
		}
	}
	for k in stale {
		owned, _ := delete_key(&s.users, k)
		delete(owned)
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
	common.store_write(path, string(data), private = true)
}

settings_destroy :: proc(s: ^Settings) {
	delete(s.server)
	for r in s.recent_servers {
		joined_server_destroy(r)
	}
	delete(s.recent_servers)
	for r in s.joined_servers {
		joined_server_destroy(r)
	}
	delete(s.joined_servers)
	delete(s.username)
	delete(s.quality)
	delete(s.theme)
	delete(s.input_device)
	delete(s.output_device)
	delete(s.mute_hotkey)
	delete(s.deafen_hotkey)
	delete(s.image_cache_dir)
	for key in s.users {
		delete(key)
	}
	delete(s.users)
	for key in s.hidden_dms {
		delete(key)
	}
	delete(s.hidden_dms)
	s^ = {}
}

// set_setting replaces an owned string field.
set_setting :: proc(field: ^string, value: string) {
	delete(field^)
	field^ = strings.clone(value)
}

// join_server adds `address` to the end of the joined servers, with
// `password`; one joined already keeps its place, with the new password.
join_server :: proc(s: ^Settings, address, password: string) {
	for &r in s.joined_servers {
		if r.address == address {
			set_setting(&r.password, password)
			return
		}
	}
	append(
		&s.joined_servers,
		Joined_Server{address = strings.clone(address), password = strings.clone(password)},
	)
}

// leave_server takes `address` off the joined servers.
leave_server :: proc(s: ^Settings, address: string) {
	for r, i in s.joined_servers {
		if r.address == address {
			joined_server_destroy(r)
			ordered_remove(&s.joined_servers, i)
			return
		}
	}
}

// order_joined_servers puts the joined servers in the order of
// `addresses` (the rail's, after a drag); any not among them keep their
// order after those.
order_joined_servers :: proc(s: ^Settings, addresses: []string) {
	k := 0
	for a in addresses {
		for i in k ..< len(s.joined_servers) {
			if s.joined_servers[i].address == a {
				r := s.joined_servers[i]
				ordered_remove(&s.joined_servers, i)
				inject_at(&s.joined_servers, k, r)
				k += 1
				break
			}
		}
	}
}

// joined_password is the password `address` was joined with, or "".
joined_password :: proc(s: ^Settings, address: string) -> string {
	for r in s.joined_servers {
		if r.address == address {
			return r.password
		}
	}
	return ""
}

// joined_channel is the channel last looked at on `address`, or "".
joined_channel :: proc(s: ^Settings, address: string) -> string {
	for r in s.joined_servers {
		if r.address == address {
			return r.channel
		}
	}
	return ""
}

// set_joined_channel notes the channel being looked at on `address`.
// It returns whether that changed anything.
set_joined_channel :: proc(s: ^Settings, address, channel: string) -> bool {
	for &r in s.joined_servers {
		if r.address == address {
			if r.channel == channel {
				return false
			}
			set_setting(&r.channel, channel)
			return true
		}
	}
	return false
}

@(private = "file")
joined_server_destroy :: proc(r: Joined_Server) {
	delete(r.address)
	delete(r.password)
	delete(r.channel)
}

// key_hex is a public key in hex, as settings and commands write one.
key_hex :: proc(key: [proto.KEY_SIZE]u8) -> string {
	key := key
	return string(hex.encode(key[:], context.temp_allocator))
}

// parse_key_hex turns key_hex's back into a key.
parse_key_hex :: proc(s: string) -> (key: [proto.KEY_SIZE]u8, ok: bool) {
	if len(s) != 2 * proto.KEY_SIZE {
		return
	}
	raw := hex.decode(transmute([]u8)s, context.temp_allocator) or_return
	copy(key[:], raw)
	return key, true
}

// server_key is how `users` and `hidden_dms` name a thing on a server:
// the server's key, a slash, and the thing's id there. In the temp
// allocator.
server_key :: proc(server: [proto.KEY_SIZE]u8, id: u64) -> string {
	return fmt.tprintf("%s/%d", key_hex(server), id)
}

// parse_server_key is server_key's the other way; false for anything
// else (such as the public keys older versions kept users by).
parse_server_key :: proc(k: string) -> (server: [proto.KEY_SIZE]u8, id: u64, ok: bool) {
	slash := strings.index_byte(k, '/')
	if slash < 0 {
		return
	}
	server = parse_key_hex(k[:slash]) or_return
	id = strconv.parse_u64_of_base(k[slash + 1:], 10) or_return
	return server, id, true
}

user_settings :: proc(
	s: ^Settings,
	server: [proto.KEY_SIZE]u8,
	account: proto.Account_Id,
) -> User_Settings {
	u := s.users[server_key(server, u64(account))] or_else DEFAULT_USER
	u.volume = clamp(u.volume, 0, MAX_USER_VOLUME)
	return u
}

set_user_settings :: proc(
	s: ^Settings,
	server: [proto.KEY_SIZE]u8,
	account: proto.Account_Id,
	u: User_Settings,
) {
	key := server_key(server, u64(account))
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

// dm_hidden is whether a DM, whose newest message is `last`, is off the
// buddy list.
dm_hidden :: proc(
	s: ^Settings,
	server: [proto.KEY_SIZE]u8,
	conv: proto.Conv_Id,
	last: proto.Msg_Id,
) -> bool {
	upto, ok := s.hidden_dms[server_key(server, u64(conv))]
	return ok && u64(last) <= upto
}

// hide_dm takes a DM off the buddy list until a message after `last`
// arrives; with `last` 0 it's put back.
hide_dm :: proc(
	s: ^Settings,
	server: [proto.KEY_SIZE]u8,
	conv: proto.Conv_Id,
	last: proto.Msg_Id,
) {
	key := server_key(server, u64(conv))
	switch {
	case last == 0:
		if key in s.hidden_dms {
			owned, _ := delete_key(&s.hidden_dms, key)
			delete(owned)
		}
	case key in s.hidden_dms:
		s.hidden_dms[key] = u64(last)
	case:
		s.hidden_dms[strings.clone(key)] = u64(last)
	}
}

// settings_quality is the configured preset; Voice if unset or unknown.
settings_quality :: proc(s: ^Settings) -> audio.Quality {
	q, _ := audio.parse_quality(s.quality)
	return q
}

MAX_IMAGE_CACHE_MB :: 4096 // the most the settings' slider goes to
MAX_TRANSFER_LIMIT :: 100 // MB/s, the most the settings' sliders go to

// image_cache_bytes is how much of the image cache to keep, in bytes.
image_cache_bytes :: proc(s: ^Settings) -> int {
	return int(clamp(s.image_cache_mb, 0, MAX_IMAGE_CACHE_MB) * 1024 * 1024)
}

notification_gain :: proc(s: ^Settings) -> f32 {
	return clamp(s.notification_volume, 0, MAX_USER_VOLUME)
}

app_audio_gain :: proc(s: ^Settings) -> f32 {
	return clamp(s.app_audio_volume, 0, MAX_USER_VOLUME)
}

// ui_scale_factor is the configured UI zoom, clamped in case a hand-edited
// settings file would otherwise shrink the whole UI to nothing or blow it
// up past what's usable.
ui_scale_factor :: proc(s: ^Settings) -> f32 {
	return clamp(s.ui_scale, MIN_UI_SCALE, MAX_UI_SCALE)
}

// chat_scale_factor is the chat's text size, from a file that may say
// anything.
chat_scale_factor :: proc(s: ^Settings) -> f32 {
	return clamp(s.chat_scale, MIN_CHAT_SCALE, MAX_CHAT_SCALE)
}

// user_gain is what the mixer multiplies a user's audio by.
user_gain :: proc(u: User_Settings) -> f32 {
	return 0 if u.muted else u.volume
}

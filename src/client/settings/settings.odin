package settings

import log "common:wlog"
import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"

import "client:audio"
import "common:."
import "common:proto"

// Client settings, stored in <config dir>/yap/settings.json:
//
//	{
//		"joined_servers": [
//			{ "address": "localhost:7777", "password": "", "channel": "general" },
//			{ "address": "voice.example.com:7777", "password": "hunter2", "channel": "" }
//		],
//		"input_device": "",
//		"output_device": "Built-in Audio Analog Stereo",
//		"quality": "voice",
//		"theme": "system",
//		"noise_suppression": true,
//		"tray": false,
//		"close_to_tray": true,
//		"minimize_to_tray": false,
//		"voice_gate": true,
//		"gate_open_db": -45,
//		"gate_close_db": -55,
//		"notification_volume": 1,
//		"app_audio_volume": 1,
//		"mute_app_audio_with_mic": true,
//		"ui_scale": 1,
//		"chat_pictures": true,
//		"merge_title_bar": true,
//		"chat_scale": 1,
//		"animate_pictures": "hover",
//		"image_cache_mb": 256,
//		"image_cache_dir": "",
//		"mute_hotkey": "Ctrl+Shift+M",
//		"deafen_hotkey": "",
//		"share_preset": "1080p",
//		"share_fps": 0,
//		"share_kbit": 0,
//		"share_encoder": "",
//		"share_cursor": true,
//		"share_stats": false,
//		"camera_device": "",
//		"camera_quality": "auto",
//		"camera_mirror": true,
//		"share_audio": "default",
//		"users": {
//			"8e41fa62833a5a7751cd6873b91156e0dfc22fa2f939c26824a07ff64764a933/12": { "volume": 0.5, "muted": false }
//		},
//		"hidden_dms": {
//			"8e41fa62833a5a7751cd6873b91156e0dfc22fa2f939c26824a07ff64764a933/40": 1234
//		},
//		"reactions": {
//			"8e41fa62833a5a7751cd6873b91156e0dfc22fa2f939c26824a07ff64764a933": [
//				{ "emoji": ":party:", "uses": 12 }, { "emoji": "👍", "uses": 5 }
//			]
//		}
//	}
//
// Devices are stored by name instead of by miniaudio's device id, because
// ids are backend-specific binary blobs, while names are readable and stay
// the same across runs. An empty name, or one that is no longer present
// (e.g. because the device was unplugged), means the system default.
//
// joined_servers are the servers this client has joined, in the order of
// the server rail (docs/design/next.md, item 9), each with the password it
// was joined with. All of them are connected to at start. The passwords are
// stored as they are, so the file is only readable by its owner. Older
// settings had the last server (`server`) and the recent ones
// (`recent_servers`) instead, which are converted to joined servers once (see settings_load).
// Likewise, the last few reactions (`recent_reactions`) become `reactions`,
// used once each.
Settings :: struct {
	joined_servers:          [dynamic]Joined_Server, // in the rail's order
	// Legacy fields from before joined_servers. They are only read (see
	// settings_load).
	server:                  string `json:"server,omitempty"`,
	recent_servers:          [dynamic]Joined_Server `json:"recent_servers,omitempty"`,
	username:                string, // the account last logged in to, used to fill in the login form
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
	// What the window's own buttons do while that icon is shown: either
	// hide the client in the tray or do what they usually do. We can only
	// handle minimizing where the desktop tells us that it happened.
	close_to_tray:           bool,
	minimize_to_tray:        bool,
	// Only send audio while the microphone level is above the thresholds
	// (in dBFS); see audio/gate.odin.
	voice_gate:              bool,
	gate_open_db:            f32,
	gate_close_db:           f32,
	// How loud the local join, leave and message sound effects are.
	notification_volume:     f32, // 1 = as encoded, 0..MAX_USER_VOLUME
	// How loud a shared application's audio is when it is sent
	// (ui_app_audio_native.odin).
	app_audio_volume:        f32, // 1 = as it plays, 0..MAX_USER_VOLUME
	// Whether muting the microphone also mutes a shared application.
	mute_app_audio_with_mic: bool,
	// The maximum speed of file uploads and downloads in DMs, in MB/s.
	// 0 means no limit (conn/files.odin).
	upload_limit:            f32,
	download_limit:          f32,
	// The UI's own zoom, independent of the display's DPI scale (see
	// window_metrics in ui.odin). 1 = 100%, in the range
	// MIN_UI_SCALE..MAX_UI_SCALE.
	ui_scale:                f32,
	// Show people's pictures next to their messages. When off, the chat is
	// more compact (ui_timeline.odin).
	chat_pictures:           bool,
	// Draw the window's buttons in the UI's first row instead of using the
	// desktop's title bar (ui_titlebar_*.odin). On platforms where this is
	// not the native look (Linux, the BSDs), it is off by default.
	merge_title_bar:         bool,
	// The chat's text size, which is multiplied with ui_scale. 1 means the
	// same size as the rest of the UI, in the range
	// MIN_CHAT_SCALE..MAX_CHAT_SCALE.
	chat_scale:              f32,
	// When animated pictures in the chat play: "hover" (or unset) while
	// the pointer is over one, "always" or "never" (see animate_pictures).
	animate_pictures:        string,
	// How much of people's pictures and servers' emoji to keep on disk
	// between sessions, in MB (0 for none), and where. "" means the
	// system's cache folder (conn/image_cache_native.odin).
	image_cache_mb:          f32,
	image_cache_dir:         string,
	// Global hotkeys, as written by hotkeys.format ("Ctrl+Shift+M"). ""
	// means none. See ui_hotkeys_native.odin.
	mute_hotkey:             string,
	deafen_hotkey:           string,
	// Screen sharing on the desktop (ui_share_settings.odin): the size
	// preset by name (conn.SHARE_PRESETS; unset means 1080p), and the
	// advanced options: frames per second (0 means 60), the bitrate in
	// kbit/s (0 means the preset's), the encoder by yap_video's name ("" for
	// the best one that works), and whether the pointer is in the picture.
	// share_stats shows statistics below the stream we are watching.
	share_preset:            string,
	share_fps:               int,
	share_kbit:              int,
	share_encoder:           string,
	share_cursor:            bool,
	share_stats:             bool,
	// The camera (ui_camera_settings.odin): which one, by its id ("" for the
	// first there is, or in a browser its choice), the quality
	// (conn.Camera_Quality by name: "auto", "high" or "low"; unset means
	// auto), and whether our own view is mirrored.
	camera_device:           string,
	camera_quality:          string,
	camera_mirror:           bool,
	// What audio a screen share sends on the desktop (ui_app_audio_native.odin):
	// "" for none, "default" for the default playback device, or a
	// playback device by name (the default if it is gone).
	share_audio:             string,
	// How to play back other people, by their account: the server's public
	// key (64 hex digits), a slash, and the account's id on that server
	// (see server_key). Names can be copied and are shared between
	// servers, while this key can't be faked. People with default settings
	// are not stored.
	users:                   map[string]User_Settings,
	// DMs that were removed from the buddy list, keyed like `users` but
	// with the conversation's id. Each one stays hidden until a message
	// newer than the one stored here arrives (see dm_hidden).
	hidden_dms:              map[string]u64,
	// The emoji used for reactions on each server, by its key (key_hex),
	// with how often: the most used first, and of those used equally often
	// the latest first. The message bar offers the first few
	// (ui_message_bar.odin). They are kept per server, because a server's
	// own emoji (":name:") only exist there.
	reactions:               map[string][dynamic]Reaction_Use,
	// Legacy: the last few reactions on each server, latest first. Only read
	// (see settings_load).
	recent_reactions:        map[string][dynamic]string `json:"recent_reactions,omitempty"`,
	// The sound of each event (audio.Sound_Event), by the event's key in
	// audio.SOUND_EVENTS: a built-in sound ("aim/msg"), "none", or a file of
	// the user's own ("custom:<file>", kept in the config folder's "sounds"
	// folder). Events that play their default sound aren't stored.
	sounds:                  map[string]string,
}

Reaction_Use :: struct {
	emoji: string,
	uses:  int,
}

User_Settings :: struct {
	volume: f32, // 1 = as sent, 0..2
	muted:  bool,
}

Joined_Server :: struct {
	address:  string, // as entered by the user
	password: string, // empty for none
	channel:  string, // the channel last viewed on that server, opened again at next start
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
	merge_title_bar         = ODIN_OS == .Darwin || ODIN_OS == .Windows,
	chat_scale              = 1,
	image_cache_mb          = 256,
	share_cursor            = true,
	camera_mirror           = true,
}

// settings_load reads `path` and falls back to the defaults if the file
// doesn't exist or can't be parsed. The result owns its strings.
settings_load :: proc(path: string) -> (s: Settings) {
	// Fields that are missing from the file keep their defaults.
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
	// Settings from before joining multiple servers existed: the recent
	// servers (or, in even older settings, the last server) become the
	// joined servers. This only happens once.
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
	// Reactions from before they were counted: each was used once.
	for key, recent in s.recent_reactions {
		if key in s.reactions {
			continue
		}
		server, parsed := common.parse_key_hex(key)
		if !parsed {
			continue
		}
		for i := len(recent) - 1; i >= 0; i -= 1 {
			note_reaction(&s, server, recent[i])
		}
	}
	recent_reactions_destroy(&s)
	// Remove per-user settings from before accounts were identified by
	// the server key and account id, since those can no longer be matched
	// to a user.
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
	delete(s.animate_pictures)
	delete(s.input_device)
	delete(s.output_device)
	delete(s.mute_hotkey)
	delete(s.deafen_hotkey)
	delete(s.image_cache_dir)
	delete(s.share_preset)
	delete(s.share_encoder)
	delete(s.camera_device)
	delete(s.camera_quality)
	delete(s.share_audio)
	for key in s.users {
		delete(key)
	}
	delete(s.users)
	for key in s.hidden_dms {
		delete(key)
	}
	delete(s.hidden_dms)
	recent_reactions_destroy(s)
	for key, uses in s.reactions {
		delete(key)
		for u in uses {
			delete(u.emoji)
		}
		delete(uses)
	}
	delete(s.reactions)
	for key, name in s.sounds {
		delete(key)
		delete(name)
	}
	delete(s.sounds)
	s^ = {}
}

// When animated pictures in the chat (previews of attached files) play.
// The image viewer always plays them, regardless of this setting.
Animate_Pictures :: enum {
	Hover, // while the pointer is over one (the default)
	Always,
	Never,
}

ANIMATE_PICTURES_NAMES := [Animate_Pictures]string {
	.Hover  = "hover",
	.Always = "always",
	.Never  = "never",
}

// animate_pictures returns the setting of that name. Anything unknown
// (e.g. an older file without it) results in the default.
animate_pictures :: proc(s: ^Settings) -> Animate_Pictures {
	for name, a in ANIMATE_PICTURES_NAMES {
		if s.animate_pictures == name {
			return a
		}
	}
	return .Hover
}

// set_setting replaces an owned string field.
set_setting :: proc(field: ^string, value: string) {
	delete(field^)
	field^ = strings.clone(value)
}

// join_server adds `address` with `password` to the end of the joined
// servers. A server that is already joined keeps its place and only gets the
// new password.
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

// leave_server removes `address` from the joined servers.
leave_server :: proc(s: ^Settings, address: string) {
	for r, i in s.joined_servers {
		if r.address == address {
			joined_server_destroy(r)
			ordered_remove(&s.joined_servers, i)
			return
		}
	}
}

// order_joined_servers sorts the joined servers into the order of
// `addresses` (the server rail's order after a drag). Servers that are not
// listed keep their relative order and come after the listed ones.
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

// joined_password returns the password `address` was joined with, or "".
joined_password :: proc(s: ^Settings, address: string) -> string {
	for r in s.joined_servers {
		if r.address == address {
			return r.password
		}
	}
	return ""
}

// joined_channel returns the channel last viewed on `address`, or "".
joined_channel :: proc(s: ^Settings, address: string) -> string {
	for r in s.joined_servers {
		if r.address == address {
			return r.channel
		}
	}
	return ""
}

// set_joined_channel remembers the channel that is being viewed on `address`.
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

// server_key is how `users` and `hidden_dms` identify something on a server:
// the server's key, a slash, and the id of the thing on that server. The
// result is allocated with the temp allocator.
server_key :: proc(server: [proto.KEY_SIZE]u8, id: u64) -> string {
	return fmt.tprintf("%s/%d", common.key_hex(server), id)
}

// parse_server_key is the inverse of server_key. It returns false for
// anything else (such as the public keys that older versions used to
// identify users).
parse_server_key :: proc(k: string) -> (server: [proto.KEY_SIZE]u8, id: u64, ok: bool) {
	slash := strings.index_byte(k, '/')
	if slash < 0 {
		return
	}
	server = common.parse_key_hex(k[:slash]) or_return
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

// dm_hidden returns whether a DM whose newest message is `last` is hidden
// from the buddy list.
dm_hidden :: proc(
	s: ^Settings,
	server: [proto.KEY_SIZE]u8,
	conv: proto.Conv_Id,
	last: proto.Msg_Id,
) -> bool {
	upto, ok := s.hidden_dms[server_key(server, u64(conv))]
	return ok && u64(last) <= upto
}

// hide_dm removes a DM from the buddy list until a message newer than `last`
// arrives. With `last` set to 0, the DM is shown again.
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

// How many reactions the message bar offers, and how many are counted per
// server. A reaction that is used less than all the others counted is
// forgotten.
QUICK_REACTIONS :: 3
MAX_COUNTED_REACTIONS :: 40

// quick_reactions returns the emoji most used for reactions on `server`, most
// used first (of those used equally often, the latest first).
quick_reactions :: proc(s: ^Settings, server: [proto.KEY_SIZE]u8) -> []Reaction_Use {
	uses := s.reactions[common.key_hex(server)] or_else nil
	return uses[:min(len(uses), QUICK_REACTIONS)]
}

// note_reaction counts a use of `emoji` for a reaction on `server`.
note_reaction :: proc(s: ^Settings, server: [proto.KEY_SIZE]u8, emoji: string) {
	key := common.key_hex(server)
	if key not_in s.reactions {
		s.reactions[strings.clone(key)] = {}
	}
	list := &s.reactions[key]
	use := Reaction_Use{}
	for u, i in list {
		if u.emoji == emoji {
			use = u
			ordered_remove(list, i)
			break
		}
	}
	if use.emoji == "" {
		use.emoji = strings.clone(emoji)
	}
	use.uses += 1
	// Ahead of every one used as often or less.
	at := len(list)
	for u, i in list {
		if u.uses <= use.uses {
			at = i
			break
		}
	}
	inject_at(list, at, use)
	for len(list) > MAX_COUNTED_REACTIONS {
		delete(pop(list).emoji)
	}
}

@(private = "file")
recent_reactions_destroy :: proc(s: ^Settings) {
	for key, recent in s.recent_reactions {
		delete(key)
		for e in recent {
			delete(e)
		}
		delete(recent)
	}
	delete(s.recent_reactions)
	s.recent_reactions = nil
}

// settings_quality returns the configured preset, or Voice if it is unset or
// unknown.
settings_quality :: proc(s: ^Settings) -> audio.Quality {
	q, _ := audio.parse_quality(s.quality)
	return q
}

MAX_IMAGE_CACHE_MB :: 4096 // the maximum of the settings slider
MAX_TRANSFER_LIMIT :: 100 // in MB/s, the maximum of the settings sliders

// image_cache_bytes returns the size limit of the image cache in bytes.
image_cache_bytes :: proc(s: ^Settings) -> int {
	return int(clamp(s.image_cache_mb, 0, MAX_IMAGE_CACHE_MB) * 1024 * 1024)
}

notification_gain :: proc(s: ^Settings) -> f32 {
	return clamp(s.notification_volume, 0, MAX_USER_VOLUME)
}

app_audio_gain :: proc(s: ^Settings) -> f32 {
	return clamp(s.app_audio_volume, 0, MAX_USER_VOLUME)
}

// ui_scale_factor returns the configured UI zoom, clamped so that a
// hand-edited settings file can't shrink the UI to nothing or enlarge it
// beyond what is usable.
ui_scale_factor :: proc(s: ^Settings) -> f32 {
	return clamp(s.ui_scale, MIN_UI_SCALE, MAX_UI_SCALE)
}

// chat_scale_factor returns the chat's text size, clamped because the
// settings file could contain any value.
chat_scale_factor :: proc(s: ^Settings) -> f32 {
	return clamp(s.chat_scale, MIN_CHAT_SCALE, MAX_CHAT_SCALE)
}

// user_gain returns the factor the mixer multiplies a user's audio with.
user_gain :: proc(u: User_Settings) -> f32 {
	return 0 if u.muted else u.volume
}

// sound_name returns the sound an event plays: the user's choice, or the
// default. "" is no sound. A built-in sound that no longer exists (renamed
// in its pack) is the default again.
sound_name :: proc(s: ^Settings, kind: audio.Sound_Event) -> string {
	if name, ok := s.sounds[audio.SOUND_EVENTS[kind].key]; ok {
		switch {
		case name == audio.NO_SOUND:
			return ""
		case strings.has_prefix(name, audio.CUSTOM_SOUND_PREFIX):
			return name
		case:
			if _, known := audio.sound_data(name); known {
				return name
			}
		}
	}
	return audio.DEFAULT_SOUNDS[kind]
}

// set_sound_name gives an event a sound ("" for none). Its default isn't
// stored.
set_sound_name :: proc(s: ^Settings, kind: audio.Sound_Event, name: string) {
	key := audio.SOUND_EVENTS[kind].key
	old_key, old_name := delete_key(&s.sounds, key)
	delete(old_key)
	delete(old_name)
	if name == audio.DEFAULT_SOUNDS[kind] {
		return
	}
	s.sounds[strings.clone(key)] = strings.clone(name if name != "" else audio.NO_SOUND)
}

// sound_preset_use applies a preset of the Sounds page (audio.SOUND_PRESETS).
sound_preset_use :: proc(s: ^Settings, preset: audio.Sound_Preset) {
	for kind in audio.Sound_Event {
		if kind == .None {
			continue
		}
		switch preset.kind {
		case .Default:
			set_sound_name(s, kind, audio.DEFAULT_SOUNDS[kind])
		case .Quiet:
			set_sound_name(s, kind, "")
		case .Pack:
			if name := preset.sounds[kind]; name != "" {
				set_sound_name(s, kind, name)
			}
		}
	}
}

// sound_in_use says whether any event plays the sound `name`.
sound_in_use :: proc(s: ^Settings, name: string) -> bool {
	for kind in audio.Sound_Event {
		if kind != .None && sound_name(s, kind) == name {
			return true
		}
	}
	return false
}

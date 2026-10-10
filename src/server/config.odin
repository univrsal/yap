package server

import "core:encoding/json"
import "core:log"
import "core:os"
import "core:reflect"
import "core:strings"
import "core:time"

import "common:."
import "common:proto"

/*
The server's settings, all in one file (config.json by default), read
once at startup:

	{
		"name": "",
		"port": 7777,
		"key": "<64 hex digits>",
		"password": "",
		"data_dir": "",
		"max_sessions": 256,
		"log_level": "info",
		"log_file": "",
		"memory_log_minutes": 60,
		"relay": {
			"enabled": false,
			"port": 8080,
			"web_dir": "web/out"
		},
		"channels": [
			{ "name": "Lobby" },
			{ "name": "Gaming" }
		],
		"retention": {
			"message_days": 0,
			"file_days": 0,
			"blob_megabytes": 0
		},
		"attachments": {
			"max_megabytes": 100,
			"rate_kb": 2048
		},
		"email": {
			"address": "",
			"imap": "imaps://mail.example.org",
			"smtp": "smtps://mail.example.org",
			"username": "",
			"password": "",
			"poll_seconds": 60,
			"check_auth_results": true,
			"trusted_auth_host": ""
		},
		"registration": {
			"open": false,
			"require_email": false,
			"verify_email": false,
			"unverified_hours": 48,
			"require_invite": false
		}
	}

name       what clients show for this server, up to 64 bytes; empty for
           none, and they show its address. Only what a new database
           starts with: after that the owner changes it from a client,
           with a description and a picture (server_info.odin).
port       the UDP port to listen on.
key        the server's private key. Keep it: clients remember the
           public half and refuse to connect if it changes.
password   what clients have to give to get in; empty for none.
data_dir   where the server keeps what it stores: its database (yap.db,
           see db.odin) and the blobs folder (blobs.odin). Empty for the
           folder the config is in. It's created if it isn't there.
max_sessions  how many sessions there may be at once, which is about
           twice how many clients can be connected (each has two, one
           for each of its links, and more while they rekey). Left out
           or 0, it's 512.
log_level  the lowest level to log: debug, info, warn or error.
log_file   also append the log to this file; empty for none.
memory_log_minutes  log a line about the server's memory this often
           (memory.odin), to see a trend in a long log; 0 for never.
           Left out, it's 60.
relay      serve the web client over HTTP on `port` and relay browsers to
           this server over WebSockets (relay.odin), with the web build
           in `web_dir`; empty for web/out, or web in a release archive.
channels   the channels a new server starts with: they're taken over
           into its database the first time it runs, the first of them
           as the home channel everyone is in, and not read again after
           that (channels are made from a client then). Channels are
           objects rather than bare strings so fields like a description
           can be added later.
retention  how long what's posted is kept (retention.odin); 0 for no
           limit, which is what they start as. `message_days`: messages
           older than this many days are removed. `file_days`: older
           messages lose the files they carry, the text staying; ignored
           unless shorter than message_days. `blob_megabytes`: when the
           files in messages take more than this, the oldest lose theirs.
           Pinned messages are kept whole whatever these say.
attachments  files uploaded with messages (attachments.odin).
           `max_megabytes`: how big one may be; 0 takes none. `rate_kb`:
           how fast, in KB/s, the server takes and sends them, for each
           connection, which leaves room for voice. Left out, they're
           100 and 2048.
email      the server's own email account (email.odin); with no
           `address`, the server has no email. `imap` and `smtp` are the
           mail servers' URLs: imaps:// and smtps:// for TLS from the
           start, imap:// and smtp:// for STARTTLS (which only a server
           on this machine may do without), with the port if it isn't
           the usual one. No `smtp`: nothing is sent. `username` is the
           address if left empty. The mailbox is read every
           `poll_seconds` (at least 10; 60 if left out).
           `trusted_auth_host` is the mail server whose
           Authentication-Results headers are believed: the first word
           of the one it adds to mail it receives. With
           `check_auth_results` (true if left out) a mail that verifies
           an address has to have one of those saying the mail is from
           where its From says; false skips that, for a mail server
           that adds none, at the cost that anyone could verify an
           address that isn't theirs by writing it as the From (the
           server warns). Email needs
           libcurl, which Linux and macOS have to have installed (the
           server runs without email if they don't); `yap-server email
           test` tries it out.
registration  whether people may make their own accounts (register.odin);
           left out, they may not, and accounts are made by an admin.
           `open`: anyone may register. `require_email`: with an email
           address, which takes email (above). `verify_email`: the
           address has to be shown to be theirs (also takes email; not
           done yet). `unverified_hours`: how long an account may wait
           for that (48 if left out). `require_invite`: with an invite
           code, made by someone with Create_Invites; codes work, and
           are kept with the account, whether required or not.

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
DEFAULT_RELAY_PORT :: 8080
DEFAULT_UNVERIFIED_HOURS :: 48
DEFAULT_CHANNEL_NAME :: "Lobby"

// Where a server from before config.json kept its key and channels.
@(private = "file")
LEGACY_KEY_FILE :: "server.key"
@(private = "file")
LEGACY_CHANNELS_FILE :: "channels.json"

Config :: struct {
	name:               string,
	port:               int,
	key:                string,
	password:           string,
	data_dir:           string,
	max_sessions:       int,
	log_level:          string,
	log_file:           string,
	memory_log_minutes: int,
	relay:              Relay_Config,
	channels:           []Channel_Config,
	retention:          Retention_Config,
	attachments:        Attach_Config,
	email:              Email_Config,
	registration:       Registration_Config,
}

Registration_Config :: struct {
	open:             bool,
	require_email:    bool,
	verify_email:     bool,
	unverified_hours: int,
	require_invite:   bool,
}

Attach_Config :: struct {
	max_megabytes: int,
	rate_kb:       int,
}

Relay_Config :: struct {
	enabled: bool,
	port:    int,
	web_dir: string,
}

// Config_Bootstrap holds settings taken from a container environment while a
// new config is created. Nothing here overrides a config that already exists.
Config_Bootstrap :: struct {
	relay_enabled_set:      bool,
	relay_enabled:          bool,
	relay_port_set:         bool,
	relay_port:             int,
	initial_admin_password: string,
}

Channel_Config :: struct {
	name: string,
}

// The parts of a Config the server runs on, checked and parsed.
Settings :: struct {
	name:         string, // sanitized
	port:         int,
	key:          string, // hex; parsed by run_server
	password:     string,
	max_sessions: int,
	log_level:    common.Log_Level,
	log_file:     string,
	memory_log:   time.Duration, // 0: never
	relay:        Relay_Config, // web_dir resolved, see default_web_dir
	channels:     []string,
	// The database and the blobs' folder, in the data directory (db.odin,
	// blobs.odin).
	db_path:      string,
	blobs_dir:    string,
	// The pictures that are the server's own emoji (emoji.odin).
	emoji_dir:    string,
	retention:    Retention_Config,
	attachments:  Attach_Config,
	email:        Email_Config, // checked; address "" for none
	registration: Registration_Config,
}

@(private = "file")
default_config :: proc() -> Config {
	return {
		port = proto.DEFAULT_PORT,
		log_level = "info",
		memory_log_minutes = 60,
		relay = {port = DEFAULT_RELAY_PORT, web_dir = default_web_dir()},
		attachments = {max_megabytes = 100, rate_kb = 2048},
		email = {check_auth_results = true},
	}
}

/*
load_config reads the config at `path`, creating it first if it doesn't
exist. Anything wrong with it is logged, and fails the load rather than
being ignored: a server that silently ran without its password would be
worse than one that doesn't start.
*/
load_config :: proc(
	path: string,
	bootstrap := Config_Bootstrap{},
) -> (
	settings: Settings,
	ok: bool,
) {
	cfg := default_config()
	if !os.exists(path) {
		if bootstrap.relay_enabled_set {
			cfg.relay.enabled = bootstrap.relay_enabled
		}
		if bootstrap.relay_port_set {
			cfg.relay.port = bootstrap.relay_port
		}
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
	data, err := json.marshal(
		cfg,
		{pretty = true, use_spaces = true, spaces = 2},
		context.temp_allocator,
	)
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
	if len(cfg.name) > proto.MAX_SERVER_NAME {
		log.errorf("%s: the name is longer than %d bytes", path, proto.MAX_SERVER_NAME)
		return
	}
	if cfg.max_sessions < 0 || cfg.max_sessions > 65535 {
		log.errorf("%s: invalid max_sessions %d", path, cfg.max_sessions)
		return
	}
	if cfg.memory_log_minutes < 0 {
		log.errorf("%s: invalid memory_log_minutes %d", path, cfg.memory_log_minutes)
		return
	}
	name_buf := make([]u8, proto.MAX_SERVER_NAME)
	name := proto.sanitize_text(cfg.name, name_buf)
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
	r := cfg.retention
	if r.message_days < 0 || r.file_days < 0 || r.blob_megabytes < 0 {
		log.errorf("%s: a retention limit can't be negative (0 is none)", path)
		return
	}
	if r.message_days > 0 && r.file_days >= r.message_days {
		log.warnf("%s: file_days isn't shorter than message_days, so it does nothing", path)
	}
	attach := cfg.attachments
	if attach.max_megabytes < 0 || attach.rate_kb < 0 {
		log.errorf("%s: an attachment limit can't be negative", path)
		return
	}
	if attach.rate_kb == 0 {
		attach.rate_kb = 2048
	}

	email := check_email(path, cfg.email) or_return
	registration := cfg.registration
	if (registration.require_email || registration.verify_email) && email.address == "" {
		log.errorf(
			"%s: registration asks for an email address (require_email or verify_email), but the server has no email configured",
			path,
		)
		return
	}
	if registration.verify_email && email.check_auth_results && email.trusted_auth_host == "" {
		log.errorf(
			"%s: verify_email needs email's trusted_auth_host: the mail server whose Authentication-Results say where a mail came from (or check_auth_results false, to go without)",
			path,
		)
		return
	}
	if registration.verify_email && !email.check_auth_results {
		log.warnf(
			"%s: check_auth_results is off, so a mail that says it's from an address verifies it: anyone can verify an address that isn't theirs",
			path,
		)
	}
	if registration.unverified_hours < 0 {
		log.errorf("%s: unverified_hours can't be negative", path)
		return
	}
	if registration.unverified_hours == 0 {
		registration.unverified_hours = DEFAULT_UNVERIFIED_HOURS
	}
	if !registration.open && (registration.require_email || registration.require_invite) {
		log.warnf("%s: registration isn't open, so what it requires does nothing", path)
	}

	s = {
		email        = email,
		registration = registration,
		name         = name,
		port         = cfg.port,
		key          = cfg.key,
		password     = cfg.password,
		max_sessions = cfg.max_sessions if cfg.max_sessions > 0 else DEFAULT_MAX_SESSIONS,
		log_level    = level,
		log_file     = cfg.log_file,
		memory_log   = time.Duration(cfg.memory_log_minutes) * time.Minute,
		relay        = relay,
		retention    = r,
		attachments  = attach,
	}
	data_dir := cfg.data_dir if cfg.data_dir != "" else os.dir(path)
	if data_dir == "" {
		data_dir = "."
	}
	if err := os.make_directory_all(data_dir); err != nil && !os.is_directory(data_dir) {
		log.errorf("%s: could not create the data directory %s: %v", path, data_dir, err)
		return
	}
	s.db_path, _ = os.join_path({data_dir, DB_FILE}, context.allocator)
	s.blobs_dir, _ = os.join_path({data_dir, BLOBS_DIR}, context.allocator)
	s.emoji_dir, _ = os.join_path({data_dir, EMOJI_DIR}, context.allocator)
	s.channels = check_channels(path, cfg.channels) or_return
	return s, true
}

// check_email checks the email config; an empty address is no email.
@(private = "file")
check_email :: proc(path: string, cfg: Email_Config) -> (e: Email_Config, ok: bool) {
	e = cfg
	if e.address == "" {
		return {}, true
	}
	buf: [proto.MAX_EMAIL_SIZE]u8
	address, address_ok := proto.email_clean(e.address, &buf)
	if !address_ok {
		log.errorf("%s: %q is no email address", path, e.address)
		return
	}
	e.address = strings.clone(address)
	if !strings.has_prefix(e.imap, "imaps://") && !strings.has_prefix(e.imap, "imap://") {
		log.errorf("%s: email needs an imap URL, imaps://host or imap://host", path)
		return
	}
	if e.smtp != "" &&
	   !strings.has_prefix(e.smtp, "smtps://") &&
	   !strings.has_prefix(e.smtp, "smtp://") {
		log.errorf("%s: the smtp URL has to be smtps://host or smtp://host", path)
		return
	}
	if e.poll_seconds == 0 {
		e.poll_seconds = DEFAULT_POLL_SECONDS
	}
	if e.poll_seconds < MIN_POLL_SECONDS {
		log.errorf("%s: email's poll_seconds has to be at least %d", path, MIN_POLL_SECONDS)
		return
	}
	return e, true
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
		log.errorf(
			"%s has %d channels; the maximum is %d",
			path,
			len(channels),
			proto.MAX_CHANNELS,
		)
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

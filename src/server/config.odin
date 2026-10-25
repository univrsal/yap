package server

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:reflect"
import "core:slice"
import "core:strings"
import "core:time"

import "common:."
import "common:proto"

// The server's settings are all in one file (config.json by default), which is
// read once at startup:
//
//	{
//		"name": "",
//		"port": 7777,
//		"key": "<64 hex digits>",
//		"password": "",
//		"data_dir": "",
//		"max_sessions": 256,
//		"log_level": "info",
//		"log_file": "",
//		"memory_log_minutes": 60,
//		"relay": {
//			"enabled": false,
//			"port": 8080,
//			"bind": "",
//			"web_dir": "web/out",
//			"allow_sites": []
//		},
//		"api": {
//			"enabled": false,
//			"behind_proxy": false,
//			"trusted_proxy": "",
//			"max_connections": 64,
//			"rate": 10,
//			"burst": 30
//		},
//		"retention": {
//			"message_days": 0,
//			"file_days": 0,
//			"blob_megabytes": 0
//		},
//		"attachments": {
//			"max_megabytes": 100,
//			"rate_kb": 2048,
//			"daily_megabytes": 4096
//		},
//		"email": {
//			"address": "",
//			"imap": "imaps://mail.example.org",
//			"smtp": "smtps://mail.example.org",
//			"username": "",
//			"password": "",
//			"poll_seconds": 60,
//			"check_auth_results": true,
//			"trusted_auth_host": "",
//			"digest_minutes": 30
//		},
//		"registration": {
//			"open": false,
//			"require_email": false,
//			"verify_email": false,
//			"unverified_hours": 48,
//			"require_invite": false
//		},
//		"video": {
//			"enabled": true,
//			"port": 0,
//			"max_kbit": 20000,
//			"cache_ms": 500,
//			"max_cameras": 9,
//			"camera_max_kbit": 4000
//		},
//		"push": {
//			"enabled": true,
//			"vapid_key": "<64 hex digits>",
//			"subject": ""
//		}
//
// name       The name clients show for this server, up to 64 bytes. If empty,
//            clients show the server's address instead. This only sets the
//            initial name of a new database. Afterwards the owner changes it
//            from a client, together with a description and a picture
//            (see server_info.odin).
// port       The UDP port to listen on.
// key        The server's private key. Keep it safe: clients remember the
//            public half and refuse to connect if it changes.
// password   The password clients have to provide to connect. If empty, no
//            password is required.
// data_dir   Where the server stores its data: the database (yap.db, see
//            db.odin) and the blobs folder (see blobs.odin). If empty, the
//            folder containing the config is used. The directory is created
//            if it doesn't exist.
// max_sessions  The maximum number of sessions at once. This is about twice
//            the number of clients that can be connected, because each client
//            has two sessions (one for each of its links), and more while
//            sessions are being rekeyed. At most half of them can be
//            handshakes in progress (see gate/gate.odin). If left out
//            or 0, it is 512.
// log_level  The lowest level to log: debug, info, warn or error.
// log_file   If set, the log is also appended to this file.
// memory_log_minutes  How often to log a line about the server's memory usage
//            (see memory.odin), which helps to spot trends in a long log.
//            0 disables it. If left out, it is 60.
// relay      Serve the web client over HTTP on `port` and relay browsers to
//            this server over WebSockets (see relay.odin). `web_dir` is the
//            folder containing the web build. If empty, it is web/out, or web
//            in a release archive. `bind` is the address to listen on, e.g.
//            127.0.0.1 when a reverse proxy on this machine is the only way
//            in (which it should be: see api). If empty, it listens on all
//            interfaces. `allow_sites` lists the other sites whose web
//            clients may connect through the relay, as origins
//            ("https://chat.example.org"), or ["*"] for any. Without it, only
//            pages of this relay's own site may (see relay_site_allowed).
//            Allowing others lets a web client opened on another server's page
//            join this server too. Keep it empty for a server that is only
//            reachable inside a private network. Behind a reverse proxy, the
//            proxy has to pass on the Host it was asked for (or set
//            X-Forwarded-Host), or the relay's own web client is refused too
//            unless its address is listed here.
// api        The bot API (see docs/bot-api and lib/gateway): HTTP and JSON
//            for programs. It is served on the relay's port under /api/,
//            whether the relay is enabled or not (without the relay, the port
//            serves only the API). It uses plain HTTP, like the relay, so
//            anything but this machine should be put behind a reverse proxy
//            that provides TLS. In that case set `behind_proxy`, which makes
//            /login (which takes a password) only accepted when the proxy says
//            the request came over HTTPS (X-Forwarded-Proto). The header is
//            only believed from `trusted_proxy`, the proxy's IP address, or
//            if that is empty, from this machine and private networks (where
//            a proxy in front of a container is), since the port may also be
//            reachable without the proxy. Without behind_proxy, /login is
//            only accepted from this machine.
//            `max_connections` is the number of tokens that may be in use at
//            once. `rate` and `burst` are the number of requests per second a
//            token may make and the number it may make at once (further
//            requests get a 429 response). A rate of 0 means no limit.
//            If left out, they are 64, 10 and 30.
// retention  How long posted content is kept (see retention.odin). 0 means no
//            limit, which is the default.
//            `message_days`: messages older than this many days are removed.
//            `file_days`: files attached to older messages are removed, but
//            the message text stays. It is ignored unless it is shorter than
//            message_days.
//            `blob_megabytes`: when the files in messages take up more space
//            than this, the oldest ones are removed.
//            Pinned messages are always kept in full, regardless of these.
// attachments  Files uploaded with messages (see attachments.odin).
//            `max_megabytes`: the maximum size of a single file. 0 disables
//            attachments. `rate_kb`: the speed limit in KB/s per connection
//            for sending and receiving files, which leaves bandwidth for
//            voice. Uploads faster than that are slowed down by the server.
//            `daily_megabytes`: how much one account may upload in 24 hours,
//            so that one account can't fill the disk. 0 means no limit. If
//            left out, they are 100, 2048 and 4096.
// email      The server's own email account (see email.odin). Without an
//            `address`, the server has no email.
//            `imap` and `smtp` are the URLs of the mail servers: use imaps://
//            and smtps:// for TLS from the start, or imap:// and smtp:// for
//            STARTTLS (which is only allowed without TLS for a server on this
//            machine). Add the port if it isn't the usual one. Without `smtp`,
//            no mail is sent. `username` defaults to the address if empty.
//            The mailbox is read every `poll_seconds` (at least 10, and 60 if
//            left out).
//            `trusted_auth_host` is the mail server whose Authentication-Results
//            headers are trusted, specifically the first word of the header it
//            adds to the mail it receives. With `check_auth_results` (true if
//            left out), a mail that verifies an address must have such a header
//            confirming that it was sent from the address in its From header.
//            Setting it to false skips that check, for mail servers that don't
//            add the header. The downside is that anyone could verify an
//            address that isn't theirs by using it as the From address (the
//            server logs a warning).
//            With `smtp`, accounts that enable it in their settings are sent
//            the messages, mentions and direct messages they missed, once they
//            have been away for `digest_minutes` (at least 5, and 30 if left
//            out), and at most that often afterwards.
//            Email needs libcurl, which has to be installed on Linux and macOS
//            (the server runs without email if it is missing). `yap-server
//            email test` tries it out.
// registration  Whether people may create their own accounts (see
//            register.odin). If left out, they may not, and an admin has to
//            create accounts.
//            `open`: anyone may register.
//            `require_email`: registration requires an email address, which
//            needs email to be configured (see above).
//            `verify_email`: the email address has to be proven to belong to
//            the user (also needs email; not implemented yet).
//            `unverified_hours`: how long an account may wait for that
//            (48 if left out).
//            `require_invite`: registration requires an invite code, created
//            by someone with the Create_Invites permission. Invite codes are
//            also accepted and stored with the account when not required.
// video      Screen sharing from desktop clients (see media.odin). With
//            `enabled` (true if left out), video has its own UDP port and its
//            own thread. `port` is that port (0 means the one after the
//            server's). Without it, video goes through the main loop like a
//            browser's, which takes far less. `max_kbit` is the maximum
//            bitrate of one sharer's video in kbit/s (20000 if left out),
//            and anything above it is dropped. `cache_ms` is how long each
//            sharer's video is kept so that what viewers lost can be sent
//            again (500 if left out). -1 keeps none. This costs about that
//            fraction of a second of `max_kbit` in memory per sharer, at most
//            2.5 MB. `max_cameras` is how many cameras may be on at once in a
//            channel's voice (9 if left out, at most 16, 0 for no cameras), and
//            `camera_max_kbit` the maximum bitrate of one camera (4000 if left
//            out). Each camera goes to everyone watching it in the channel, so
//            a full channel costs about max_cameras x watchers x what each
//            camera sends (450 kbit/s at nine).
// push       Web Push (see push.odin): notifying browsers that enabled it about
//            messages while the client isn't open, through their push
//            services (Google's, Mozilla's, Apple's). This needs libcurl and
//            the server must be able to reach those services over HTTPS.
//            Enabled unless `enabled` is false. `vapid_key` is the key push
//            notifications are signed with, created on the first run. Keep
//            it, because browsers subscribed with its public half. `subject`
//            is how the push services can contact whoever runs the server, as
//            a mailto: or https: URL. If empty, it is a mailto: URL with the
//            server's email address, or the project's page if there is none.
//
// Fields that are left out use the defaults listed above.
//
// In a container, the environment variables YAP_PORT, YAP_VIDEO_PORT and
// YAP_RELAY_PORT set `port`, `video.port` and `relay.port` on every start and
// are saved to the file (see Config_Ports). So does YAP_RELAY_ALLOW_SITES, a
// comma separated list that sets `relay.allow_sites`; if it is empty or not
// set, the file's list stays. YAP_VIDEO_ENABLED (true, false, 1 or 0) sets
// `video.enabled`, the media link, the same way. YAP_RELAY_ENABLED and
// YAP_INITIAL_ADMIN_PASSWORD are only used when the file is created
// (Config_Bootstrap).
//
// Channels aren't configured here. A new database starts with a single channel
// called Lobby (DEFAULT_CHANNEL_NAME), which is the home channel that everyone
// is in. All other channels are created from a client.
//
// If the file doesn't exist, it is created with the default values and new
// keys. A file without a key or a vapid_key gets a new one, which is written
// back to it.
//
// The file contains the key and the password, so it is only readable by its
// owner.

DEFAULT_CONFIG_FILE :: "config.json"
DEFAULT_RELAY_PORT :: 8080
DEFAULT_UNVERIFIED_HOURS :: 48
DEFAULT_CHANNEL_NAME :: "Lobby"

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
	api:                Api_Config,
	retention:          Retention_Config,
	attachments:        Attach_Config,
	email:              Email_Config,
	registration:       Registration_Config,
	video:              Video_Config,
	push:               Push_Config,
}

Video_Config :: struct {
	enabled:         bool,
	port:            int,
	max_kbit:        int,
	cache_ms:        int,
	max_cameras:     int,
	camera_max_kbit: int,
}

Registration_Config :: struct {
	open:             bool,
	require_email:    bool,
	verify_email:     bool,
	unverified_hours: int,
	require_invite:   bool,
}

Attach_Config :: struct {
	max_megabytes:   int,
	rate_kb:         int,
	daily_megabytes: int, // 0 for no limit
}

Relay_Config :: struct {
	enabled:     bool,
	port:        int,
	bind:        string,
	web_dir:     string,
	allow_sites: []string, // as written, then normalized (see site_origin)
}

Api_Config :: struct {
	enabled:         bool,
	behind_proxy:    bool,
	trusted_proxy:   string,
	max_connections: int,
	rate:            f64,
	burst:           f64,
}

// Config_Bootstrap holds settings taken from a container environment while a
// new config is created. Nothing here overrides a config that already exists.
Config_Bootstrap :: struct {
	relay_enabled_set:      bool,
	relay_enabled:          bool,
	initial_admin_password: string,
}

// Config_Ports holds the ports taken from a container environment, 0 for those
// that aren't set, and the relay's allow_sites if that is set (nil if not).
// Unlike Config_Bootstrap, they are applied on every start
// and saved to the config, because they have to match the ports the container
// publishes: clients are told the video port, so it can't be mapped to another.
Config_Ports :: struct {
	port:              int,
	video_port:        int,
	relay_port:        int,
	allow_sites:       []string,
	// Whether the media link (video.enabled) is on, if the environment says.
	video_enabled_set: bool,
	video_enabled:     bool,
}

// Settings holds the validated and parsed parts of a Config that the server
// runs on.
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
	api:          Api_Config,
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
	video:        Video_Config, // checked; port 0 for the one after `port`
	push:         Push_Config, // subject filled in with a default if not set
}

// The subject used for push when neither a push subject nor an email address is
// configured.
DEFAULT_PUSH_SUBJECT :: "https://github.com/univrsal/yap"

@(private = "file")
default_config :: proc() -> Config {
	return {
		port = proto.DEFAULT_PORT,
		log_level = "info",
		memory_log_minutes = 60,
		relay = {port = DEFAULT_RELAY_PORT, web_dir = default_web_dir()},
		api = {max_connections = 64, rate = 10, burst = 30},
		attachments = {max_megabytes = 100, rate_kb = 2048, daily_megabytes = 4096},
		email = {check_auth_results = true},
		video = {enabled = true, max_kbit = 20000, max_cameras = 9, camera_max_kbit = 4000},
		push = {enabled = true},
	}
}

// load_config reads the config at `path`, creating it first if it doesn't
// exist. Any problem with the config is logged and makes the load fail instead
// of being ignored, because a server that silently ran without its password
// would be worse than one that doesn't start.
load_config :: proc(
	path: string,
	bootstrap := Config_Bootstrap{},
	ports := Config_Ports{},
) -> (
	settings: Settings,
	ok: bool,
) {
	cfg := default_config()
	if !os.exists(path) {
		if bootstrap.relay_enabled_set {
			cfg.relay.enabled = bootstrap.relay_enabled
		}
		apply_ports(&cfg, ports)
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
	if apply_ports(&cfg, ports) {
		settings = check_config(path, cfg) or_return
		save_config(path, cfg) or_return
		log.infof("saved the settings from the environment to %s", path)
	} else {
		settings = check_config(path, cfg) or_return
	}
	if cfg.key == "" {
		cfg.key = common.generate_private_key() or_return
		save_config(path, cfg) or_return
		settings.key = cfg.key
		log.infof("%s had no key, so a new one was generated and saved to it", path)
	}
	if cfg.push.vapid_key == "" {
		cfg.push.vapid_key = vapid_key_generate() or_return
		save_config(path, cfg) or_return
		settings.push.vapid_key = cfg.push.vapid_key
		log.infof("%s had no push vapid_key, so a new one was generated and saved to it", path)
	}
	return settings, true
}

// apply_ports sets the ports of `ports` that are set, and returns whether that
// changed any.
@(private = "file")
apply_ports :: proc(cfg: ^Config, ports: Config_Ports) -> (changed: bool) {
	set :: proc(field: ^int, port: int, changed: ^bool) {
		if port != 0 && field^ != port {
			field^ = port
			changed^ = true
		}
	}
	set(&cfg.port, ports.port, &changed)
	set(&cfg.video.port, ports.video_port, &changed)
	set(&cfg.relay.port, ports.relay_port, &changed)
	if ports.video_enabled_set && cfg.video.enabled != ports.video_enabled {
		cfg.video.enabled = ports.video_enabled
		changed = true
	}
	if len(ports.allow_sites) > 0 && !slice.equal(cfg.relay.allow_sites, ports.allow_sites) {
		cfg.relay.allow_sites = ports.allow_sites
		changed = true
	}
	return
}

// create_config generates a key for a new config and writes it to `path`.
@(private = "file")
create_config :: proc(path: string, cfg: ^Config) -> bool {
	cfg.key = common.generate_private_key() or_return
	cfg.push.vapid_key = vapid_key_generate() or_return
	log.info("generated a new private key")

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
	if relay.enabled || cfg.api.enabled {
		if relay.port <= 0 || relay.port > 65535 {
			log.errorf("%s: invalid relay port %d", path, relay.port)
			return
		}
		if relay.port == cfg.port {
			// This works because one uses TCP and the other UDP, but it is rarely intended.
			log.warnf("%s: the relay and the server share port %d", path, cfg.port)
		}
		if relay.bind != "" && net.parse_address(relay.bind) == nil {
			log.errorf("%s: the relay's bind %q is not an IP address", path, relay.bind)
			return
		}
		for &site in relay.allow_sites {
			origin, origin_ok := site_origin(site)
			if !origin_ok {
				log.errorf(
					"%s: the relay's allow_sites entry %q is neither \"*\" nor an origin such as \"https://chat.example.org\"",
					path,
					site,
				)
				return
			}
			site = origin
		}
	}
	if relay.web_dir == "" {
		relay.web_dir = default_web_dir()
	}
	api := cfg.api
	switch {
	case api.max_connections < 0 || api.rate < 0 || api.burst < 0:
		log.errorf("%s: an api limit can't be negative", path)
		return
	case api.trusted_proxy != "" && net.parse_address(api.trusted_proxy) == nil:
		log.errorf("%s: the api's trusted_proxy %q is not an IP address", path, api.trusted_proxy)
		return
	case api.rate > 0 && api.burst < 1:
		log.errorf(
			"%s: the api burst has to be at least 1, otherwise no request can get through",
			path,
		)
		return
	}
	r := cfg.retention
	if r.message_days < 0 || r.file_days < 0 || r.blob_megabytes < 0 {
		log.errorf("%s: a retention limit can't be negative (0 is none)", path)
		return
	}
	if r.message_days > 0 && r.file_days >= r.message_days {
		log.warnf("%s: file_days is not shorter than message_days, so it has no effect", path)
	}
	attach := cfg.attachments
	if attach.max_megabytes < 0 || attach.rate_kb < 0 || attach.daily_megabytes < 0 {
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
			"%s: registration requires an email address (require_email or verify_email), but no email is configured for the server",
			path,
		)
		return
	}
	if registration.verify_email && email.check_auth_results && email.trusted_auth_host == "" {
		log.errorf(
			"%s: verify_email needs email.trusted_auth_host, the mail server whose Authentication-Results headers say where a mail came from (or set check_auth_results to false to skip this check)",
			path,
		)
		return
	}
	if registration.verify_email && !email.check_auth_results {
		log.warnf(
			"%s: check_auth_results is off, so any mail that claims to be from an address verifies it, which means anyone can verify an address that isn't theirs",
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
		log.warnf("%s: registration isn't open, so its requirements have no effect", path)
	}
	video := cfg.video
	switch {
	case video.port < 0 || video.port > 65535:
		log.errorf("%s: invalid video port %d", path, video.port)
		return
	case video.port == 0 && video.enabled && cfg.port == 65535:
		log.errorf(
			"%s: video port can't default to the port after 65535; set video.port explicitly",
			path,
		)
		return
	case video.enabled && video.port == cfg.port:
		log.errorf("%s: video can't use the same port as the server (%d)", path, cfg.port)
		return
	case video.max_kbit < 0:
		log.errorf("%s: video.max_kbit can't be negative", path)
		return
	case video.cache_ms < -1 || video.cache_ms > 5000:
		log.errorf("%s: video.cache_ms has to be between -1 (none) and 5000", path)
		return
	case video.max_cameras < 0 || video.max_cameras > proto.MAX_CAMERAS:
		log.errorf(
			"%s: video.max_cameras has to be between 0 (none) and %d",
			path,
			proto.MAX_CAMERAS,
		)
		return
	case video.camera_max_kbit < 0:
		log.errorf("%s: video.camera_max_kbit can't be negative", path)
		return
	}
	if video.max_kbit == 0 {
		video.max_kbit = 20000
	}
	if video.camera_max_kbit == 0 {
		video.camera_max_kbit = 4000
	}
	switch video.cache_ms {
	case 0:
		video.cache_ms = 500
	case -1:
		video.cache_ms = 0
	}

	push := cfg.push
	if push.subject == "" {
		push.subject =
			fmt.aprintf("mailto:%s", email.address) if email.address != "" else DEFAULT_PUSH_SUBJECT
	} else if !strings.has_prefix(push.subject, "mailto:") &&
	   !strings.has_prefix(push.subject, "https://") {
		log.errorf("%s: push.subject must be a mailto: or https:// URL", path)
		return
	}
	if strings.contains_any(push.subject, "\"\\\r\n ") {
		log.errorf(
			"%s: push.subject must not contain spaces, line breaks, quotes or backslashes",
			path,
		)
		return
	}

	s = {
		push         = push,
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
		api          = api,
		retention    = r,
		attachments  = attach,
		video        = video,
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
	return s, true
}

// check_email validates the email config. An empty address means that email is
// not configured.
@(private = "file")
check_email :: proc(path: string, cfg: Email_Config) -> (e: Email_Config, ok: bool) {
	e = cfg
	if e.address == "" {
		return {}, true
	}
	buf: [proto.MAX_EMAIL_SIZE]u8
	address, address_ok := proto.email_clean(e.address, &buf)
	if !address_ok {
		log.errorf("%s: %q is not a valid email address", path, e.address)
		return
	}
	e.address = strings.clone(address)
	if !strings.has_prefix(e.imap, "imaps://") && !strings.has_prefix(e.imap, "imap://") {
		log.errorf("%s: email needs an imap URL like imaps://host or imap://host", path)
		return
	}
	if e.smtp != "" &&
	   !strings.has_prefix(e.smtp, "smtps://") &&
	   !strings.has_prefix(e.smtp, "smtp://") {
		log.errorf("%s: the smtp URL has to look like smtps://host or smtp://host", path)
		return
	}
	if e.poll_seconds == 0 {
		e.poll_seconds = DEFAULT_POLL_SECONDS
	}
	if e.poll_seconds < MIN_POLL_SECONDS {
		log.errorf("%s: email.poll_seconds has to be at least %d", path, MIN_POLL_SECONDS)
		return
	}
	if e.digest_minutes == 0 {
		e.digest_minutes = DEFAULT_DIGEST_MINUTES
	}
	if e.digest_minutes < MIN_DIGEST_MINUTES {
		log.errorf("%s: email.digest_minutes has to be at least %d", path, MIN_DIGEST_MINUTES)
		return
	}
	return e, true
}

// default_web_dir returns the folder containing the web build: web/out after
// running web/build.sh, or web in a release archive.
@(private = "file")
default_web_dir :: proc() -> string {
	if !os.exists(DEFAULT_WEB_DIR) && os.exists("web/index.html") {
		return "web"
	}
	return DEFAULT_WEB_DIR
}

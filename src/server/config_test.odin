package server

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "common:."
import "common:proto"
import "mail"

// Tests of loading and checking the server's config (config.odin). The config
// is a file, so each test writes one to a folder of its own and loads it the
// way the server does at startup.

// load_cfg loads the config in `body` (JSON) written to a new file in `dir`.
// Everything the load allocates comes from the temp allocator.
@(private = "file")
load_cfg :: proc(
	t: ^testing.T,
	dir, body: string,
	ports := Config_Ports{},
) -> (
	settings: Settings,
	ok: bool,
) {
	path := file_in(dir, "config.json")
	testing.expect(t, os.write_entire_file(path, body) == nil)
	context.allocator = context.temp_allocator
	context.logger = expected_errors() // the errors are expected
	return load_config(path, {}, ports)
}

@(test)
test_config_new :: proc(t: ^testing.T) {
	dir := test_dir(t)
	defer os.remove_all(dir)
	path := file_in(dir, "config.json")
	context.allocator = context.temp_allocator

	s, ok := load_config(path, {relay_enabled_set = true, relay_enabled = true})
	testing.expect(t, ok)
	testing.expect(t, os.exists(path), "a missing config is created")
	testing.expect_value(t, len(s.key), 64)
	testing.expect_value(t, len(s.push.vapid_key), 64)
	testing.expect_value(t, s.port, proto.DEFAULT_PORT)
	testing.expect_value(t, s.max_sessions, DEFAULT_MAX_SESSIONS)
	testing.expect_value(t, s.log_level, common.Log_Level.info)
	testing.expect_value(t, s.memory_log, 60 * time.Minute)
	testing.expect(t, s.relay.enabled, "the bootstrap enables the relay")
	testing.expect(t, s.relay.web_dir != "")
	testing.expect_value(t, s.video.max_kbit, 20000)
	testing.expect_value(t, s.video.cache_ms, 500)
	testing.expect_value(t, s.attachments.rate_kb, 2048)
	testing.expect_value(t, s.registration.unverified_hours, DEFAULT_UNVERIFIED_HOURS)
	testing.expect_value(t, s.push.subject, DEFAULT_PUSH_SUBJECT)
	testing.expect_value(t, s.db_path, file_in(dir, DB_FILE))
	testing.expect_value(t, s.blobs_dir, file_in(dir, BLOBS_DIR))

	// Loading it again gives the same server, with the same key.
	again, again_ok := load_config(path)
	testing.expect(t, again_ok)
	testing.expect_value(t, again.key, s.key)
	testing.expect_value(t, again.push.vapid_key, s.push.vapid_key)
	testing.expect(t, again.relay.enabled)
}

@(test)
test_config_generates_missing_keys :: proc(t: ^testing.T) {
	dir := test_dir(t)
	defer os.remove_all(dir)

	s, ok := load_cfg(t, dir, `{"name": "Test"}`)
	testing.expect(t, ok)
	testing.expect_value(t, s.name, "Test")
	testing.expect_value(t, len(s.key), 64)
	testing.expect_value(t, len(s.push.vapid_key), 64)

	// The keys were saved, so that the server keeps its identity.
	context.allocator = context.temp_allocator
	again, again_ok := load_config(file_in(dir, "config.json"))
	testing.expect(t, again_ok)
	testing.expect_value(t, again.key, s.key)
	testing.expect_value(t, again.push.vapid_key, s.push.vapid_key)
	testing.expect_value(t, again.name, "Test")
}

@(test)
test_config_keeps_given_key :: proc(t: ^testing.T) {
	dir := test_dir(t)
	defer os.remove_all(dir)

	key := strings.repeat("ab", 32, context.temp_allocator)
	s, ok := load_cfg(t, dir, fmt.tprintf(`{{"key": %q}}`, key))
	testing.expect(t, ok)
	testing.expect_value(t, s.key, key)
}

@(test)
test_config_not_json :: proc(t: ^testing.T) {
	dir := test_dir(t)
	defer os.remove_all(dir)

	for body in ([]string{"", "not json", `{"port": `, `[]`}) {
		_, ok := load_cfg(t, dir, body)
		testing.expectf(t, !ok, "%q was accepted", body)
	}
}

@(test)
test_config_rejects_invalid :: proc(t: ^testing.T) {
	dir := test_dir(t)
	defer os.remove_all(dir)

	long_name := strings.repeat("n", proto.MAX_SERVER_NAME + 1, context.temp_allocator)
	long_password := strings.repeat("p", proto.MAX_PASSWORD_SIZE + 1, context.temp_allocator)
	bad := []string {
		`{"port": 0}`,
		`{"port": -1}`,
		`{"port": 65536}`,
		fmt.tprintf(`{{"name": %q}}`, long_name),
		fmt.tprintf(`{{"password": %q}}`, long_password),
		`{"max_sessions": -1}`,
		`{"max_sessions": 65536}`,
		`{"memory_log_minutes": -1}`,
		`{"log_level": "verbose"}`,
		`{"log_level": ""}`,
		// The relay and the API are only checked when they are on.
		`{"relay": {"enabled": true, "port": 0}}`,
		`{"relay": {"enabled": true, "port": 70000}}`,
		`{"relay": {"enabled": true, "bind": "not an address"}}`,
		`{"relay": {"enabled": true, "allow_sites": ["chat.example.org"]}}`,
		`{"relay": {"enabled": true, "allow_sites": ["https://ok.example.org", "ftp://x"]}}`,
		`{"api": {"enabled": true, "port": 0}, "relay": {"port": 0}}`,
		`{"api": {"max_connections": -1}}`,
		`{"api": {"rate": -1}}`,
		`{"api": {"burst": -1}}`,
		`{"api": {"trusted_proxy": "proxy.example.org"}}`,
		`{"api": {"rate": 10, "burst": 0}}`,
		`{"retention": {"message_days": -1}}`,
		`{"retention": {"file_days": -1}}`,
		`{"retention": {"blob_megabytes": -1}}`,
		`{"attachments": {"max_megabytes": -1}}`,
		`{"attachments": {"rate_kb": -1}}`,
		`{"attachments": {"daily_megabytes": -1}}`,
		`{"email": {"address": "no-at-sign", "imap": "imaps://mail.example.org"}}`,
		`{"email": {"address": "bot@example.org"}}`,
		`{"email": {"address": "bot@example.org", "imap": "http://mail.example.org"}}`,
		`{"email": {"address": "bot@example.org", "imap": "imaps://m", "smtp": "http://m"}}`,
		`{"email": {"address": "bot@example.org", "imap": "imaps://m", "poll_seconds": 1}}`,
		`{"email": {"address": "bot@example.org", "imap": "imaps://m", "digest_minutes": 1}}`,
		// Registration that asks for an address needs a server that can mail.
		`{"registration": {"open": true, "require_email": true}}`,
		`{"registration": {"open": true, "verify_email": true}}`,
		// Verifying addresses is only safe when the mail's origin is checked.
		`{"registration": {"verify_email": true}, "email": {"address": "bot@example.org", "imap": "imaps://m"}}`,
		`{"registration": {"unverified_hours": -1}}`,
		`{"video": {"port": -1}}`,
		`{"video": {"port": 65536}}`,
		`{"video": {"port": 7777}}`,
		`{"port": 65535}`, // the media port would be 65536
		`{"video": {"max_kbit": -1}}`,
		`{"video": {"cache_ms": -2}}`,
		`{"video": {"cache_ms": 5001}}`,
		`{"video": {"max_cameras": -1}}`,
		`{"video": {"max_cameras": 1000}}`,
		`{"video": {"camera_max_kbit": -1}}`,
		`{"push": {"subject": "http://example.org"}}`,
		`{"push": {"subject": "example.org"}}`,
		`{"push": {"subject": "https://example.org/a b"}}`,
		`{"push": {"subject": "https://example.org/\"x"}}`,
	}
	for body in bad {
		_, ok := load_cfg(t, dir, body)
		testing.expectf(t, !ok, "%s was accepted", body)
	}
}

@(test)
test_config_accepts_unusual :: proc(t: ^testing.T) {
	dir := test_dir(t)
	defer os.remove_all(dir)

	good := []string {
		`{"port": 1}`,
		`{"port": 65535, "video": {"enabled": false}}`,
		`{"port": 65535, "video": {"port": 65000}}`,
		`{"max_sessions": 65535}`,
		`{"log_level": "debug"}`,
		`{"log_level": "error"}`,
		`{"relay": {"enabled": true, "bind": "127.0.0.1"}}`,
		`{"relay": {"enabled": true, "bind": "::1"}}`,
		`{"relay": {"enabled": true, "allow_sites": ["*"]}}`,
		// The relay sharing the server's port is only a warning.
		`{"relay": {"enabled": true, "port": 7777}}`,
		// A relay that is off isn't checked.
		`{"relay": {"enabled": false, "port": 0, "bind": "x"}}`,
		`{"api": {"trusted_proxy": "10.0.0.1"}}`,
		`{"api": {"rate": 0, "burst": 0}}`,
		// A file_days that is no shorter than message_days only warns.
		`{"retention": {"message_days": 10, "file_days": 20}}`,
		`{"registration": {"require_invite": true}}`,
		`{"video": {"cache_ms": -1}}`,
		`{"video": {"cache_ms": 5000}}`,
		`{"video": {"max_cameras": 0}}`,
		`{"push": {"subject": "mailto:ops@example.org"}}`,
		`{"push": {"enabled": false}}`,
	}
	for body in good {
		_, ok := load_cfg(t, dir, body)
		testing.expectf(t, ok, "%s was refused", body)
	}
}

@(test)
test_config_defaults_are_filled_in :: proc(t: ^testing.T) {
	dir := test_dir(t)
	defer os.remove_all(dir)

	// Zero means "the default" for these.
	s, ok := load_cfg(
		t,
		dir,
		`{
		"max_sessions": 0,
		"attachments": {"rate_kb": 0},
		"registration": {"unverified_hours": 0},
		"video": {"max_kbit": 0, "camera_max_kbit": 0, "cache_ms": 0}
	}`,
	)
	testing.expect(t, ok)
	testing.expect_value(t, s.max_sessions, DEFAULT_MAX_SESSIONS)
	testing.expect_value(t, s.attachments.rate_kb, 2048)
	testing.expect_value(t, s.registration.unverified_hours, DEFAULT_UNVERIFIED_HOURS)
	testing.expect_value(t, s.video.max_kbit, 20000)
	testing.expect_value(t, s.video.camera_max_kbit, 4000)
	testing.expect_value(t, s.video.cache_ms, 500)

	// Values that are set are kept, and -1 is how the cache is turned off.
	s, ok = load_cfg(
		t,
		dir,
		`{
		"max_sessions": 100,
		"memory_log_minutes": 0,
		"attachments": {"rate_kb": 10},
		"registration": {"unverified_hours": 5},
		"video": {"max_kbit": 1, "camera_max_kbit": 2, "cache_ms": -1}
	}`,
	)
	testing.expect(t, ok)
	testing.expect_value(t, s.max_sessions, 100)
	testing.expect_value(t, s.memory_log, time.Duration(0))
	testing.expect_value(t, s.attachments.rate_kb, 10)
	testing.expect_value(t, s.registration.unverified_hours, 5)
	testing.expect_value(t, s.video.max_kbit, 1)
	testing.expect_value(t, s.video.camera_max_kbit, 2)
	testing.expect_value(t, s.video.cache_ms, 0)
}

@(test)
test_config_name_is_sanitized :: proc(t: ^testing.T) {
	dir := test_dir(t)
	defer os.remove_all(dir)

	s, ok := load_cfg(t, dir, `{"name": "  Line\nbreak\u0007 "}`)
	testing.expect(t, ok)
	testing.expect(t, !strings.contains_any(s.name, "\n\a"), "control characters were kept")
}

@(test)
test_config_allow_sites_are_normalized :: proc(t: ^testing.T) {
	dir := test_dir(t)
	defer os.remove_all(dir)

	s, ok := load_cfg(
		t,
		dir,
		`{"relay": {"enabled": true, "allow_sites": ["https://Chat.Example.org/", " * "]}}`,
	)
	testing.expect(t, ok)
	testing.expect_value(t, len(s.relay.allow_sites), 2)
	if len(s.relay.allow_sites) == 2 {
		testing.expect_value(t, s.relay.allow_sites[0], "https://chat.example.org")
		testing.expect_value(t, s.relay.allow_sites[1], "*")
	}
}

@(test)
test_config_email :: proc(t: ^testing.T) {
	dir := test_dir(t)
	defer os.remove_all(dir)

	// Without an address, email is off whatever else is set.
	s, ok := load_cfg(t, dir, `{"email": {"imap": "junk", "poll_seconds": 1}}`)
	testing.expect(t, ok)
	testing.expect_value(t, s.email.address, "")

	s, ok = load_cfg(
		t,
		dir,
		`{"email": {"address": "Bot@Example.org", "imap": "imaps://mail.example.org"}}`,
	)
	testing.expect(t, ok)
	testing.expect_value(t, s.email.address, "bot@example.org")
	testing.expect_value(t, s.email.poll_seconds, mail.DEFAULT_POLL_SECONDS)
	testing.expect_value(t, s.email.digest_minutes, mail.DEFAULT_DIGEST_MINUTES)
	testing.expect(t, s.email.check_auth_results, "auth results are checked unless turned off")
	// With an address, push has someone to name as its contact.
	testing.expect_value(t, s.push.subject, "mailto:bot@example.org")

	s, ok = load_cfg(
		t,
		dir,
		`{"email": {"address": "bot@example.org", "imap": "imap://m", "smtp": "smtp://m",
		"poll_seconds": 10, "digest_minutes": 5}}`,
	)
	testing.expect(t, ok)
	testing.expect_value(t, s.email.poll_seconds, mail.MIN_POLL_SECONDS)
	testing.expect_value(t, s.email.digest_minutes, mail.MIN_DIGEST_MINUTES)

	// An explicit push subject wins over the address.
	s, ok = load_cfg(
		t,
		dir,
		`{"email": {"address": "bot@example.org", "imap": "imaps://m"},
		"push": {"subject": "https://example.org/contact"}}`,
	)
	testing.expect(t, ok)
	testing.expect_value(t, s.push.subject, "https://example.org/contact")

	// Registration that needs email works once email is set up.
	s, ok = load_cfg(
		t,
		dir,
		`{"registration": {"open": true, "require_email": true, "verify_email": true},
		"email": {"address": "bot@example.org", "imap": "imaps://m", "trusted_auth_host": "mx.example.org"}}`,
	)
	testing.expect(t, ok)
	testing.expect(t, s.registration.verify_email)
	// ... or verifying without the origin check, which is allowed but warned about.
	s, ok = load_cfg(
		t,
		dir,
		`{"registration": {"open": true, "verify_email": true},
		"email": {"address": "bot@example.org", "imap": "imaps://m", "check_auth_results": false}}`,
	)
	testing.expect(t, ok)
}

@(test)
test_config_data_dir :: proc(t: ^testing.T) {
	dir := test_dir(t)
	defer os.remove_all(dir)

	// The data directory is created, including its parents, and holds the data.
	data := file_in(dir, "a")
	data = file_in(data, "b")
	s, ok := load_cfg(t, dir, fmt.tprintf(`{{"data_dir": %q}}`, data))
	testing.expect(t, ok)
	testing.expect(t, os.is_directory(data))
	testing.expect_value(t, s.db_path, file_in(data, DB_FILE))
	testing.expect_value(t, s.blobs_dir, file_in(data, BLOBS_DIR))
	testing.expect_value(t, s.emoji_dir, file_in(data, EMOJI_DIR))

	// A data directory that can't be one makes the load fail.
	blocker := file_in(dir, "file")
	testing.expect(t, os.write_entire_file(blocker, "x") == nil)
	_, ok = load_cfg(t, dir, fmt.tprintf(`{{"data_dir": %q}}`, file_in(blocker, "sub")))
	testing.expect(t, !ok)
}

@(test)
test_config_ports_from_environment :: proc(t: ^testing.T) {
	dir := test_dir(t)
	defer os.remove_all(dir)

	sites := []string{"https://chat.example.org"}
	ports := Config_Ports {
		port              = 9000,
		video_port        = 9001,
		relay_port        = 9002,
		allow_sites       = sites,
		video_enabled_set = true,
		video_enabled     = false,
	}
	s, ok := load_cfg(t, dir, `{"relay": {"enabled": true}}`, ports)
	testing.expect(t, ok)
	testing.expect_value(t, s.port, 9000)
	testing.expect_value(t, s.video.port, 9001)
	testing.expect_value(t, s.relay.port, 9002)
	testing.expect(t, !s.video.enabled)
	testing.expect_value(t, len(s.relay.allow_sites), 1)

	// They are saved to the config, so they apply without the environment too.
	context.allocator = context.temp_allocator
	again, again_ok := load_config(file_in(dir, "config.json"))
	testing.expect(t, again_ok)
	testing.expect_value(t, again.port, 9000)
	testing.expect_value(t, again.video.port, 9001)
	testing.expect_value(t, again.relay.port, 9002)
	testing.expect(t, !again.video.enabled)
	testing.expect_value(t, again.key, s.key)

	// Ports that are not set leave the config alone.
	other, other_ok := load_config(file_in(dir, "config.json"), {}, Config_Ports{})
	testing.expect(t, other_ok)
	testing.expect_value(t, other.port, 9000)

	// The environment's ports are checked like the rest.
	context.logger = expected_errors() // the errors are expected
	_, bad := load_config(file_in(dir, "config.json"), {}, {port = 70000})
	testing.expect(t, !bad)
	_, clash := load_config(
		file_in(dir, "config.json"),
		{},
		{video_port = 9000, video_enabled_set = true, video_enabled = true},
	)
	testing.expect(t, !clash)
}

@(test)
test_config_ports_for_new_config :: proc(t: ^testing.T) {
	dir := test_dir(t)
	defer os.remove_all(dir)
	context.allocator = context.temp_allocator

	path := file_in(dir, "config.json")
	s, ok := load_config(path, {}, {port = 8123, relay_port = 8124})
	testing.expect(t, ok)
	testing.expect_value(t, s.port, 8123)
	testing.expect_value(t, s.relay.port, 8124)

	again, again_ok := load_config(path)
	testing.expect(t, again_ok)
	testing.expect_value(t, again.port, 8123)
	testing.expect_value(t, again.relay.port, 8124)
}

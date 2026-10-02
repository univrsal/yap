#+build !wasi
package settings

import "core:fmt"
import "core:os"
import "core:testing"

import "common:proto"

@(test)
test_recent_servers :: proc(t: ^testing.T) {
	s: Settings
	defer settings_destroy(&s)

	remember_recent_server(&s, "a:1", "")
	remember_recent_server(&s, "b:1", "pw")
	testing.expect_value(t, len(s.recent_servers), 2)
	testing.expect_value(t, s.recent_servers[0].address, "b:1") // newest first
	testing.expect_value(t, recent_password(&s, "b:1"), "pw")
	testing.expect_value(t, recent_password(&s, "c:1"), "")

	// Connecting again moves it to the top, with the new password,
	// rather than listing it twice.
	remember_recent_server(&s, "a:1", "new")
	testing.expect_value(t, len(s.recent_servers), 2)
	testing.expect_value(t, s.recent_servers[0].address, "a:1")
	testing.expect_value(t, recent_password(&s, "a:1"), "new")

	// What the connect screen does on a click: the entry is its own
	// argument.
	remember_recent_server(&s, s.recent_servers[1].address, s.recent_servers[1].password)
	testing.expect_value(t, s.recent_servers[0].address, "b:1")
	testing.expect_value(t, s.recent_servers[0].password, "pw")

	for i in 0 ..< 2 * MAX_RECENT_SERVERS {
		remember_recent_server(&s, fmt.tprintf("host%d:1", i), "")
	}
	testing.expect_value(t, len(s.recent_servers), MAX_RECENT_SERVERS)
	testing.expect_value(
		t,
		s.recent_servers[0].address,
		fmt.tprintf("host%d:1", 2 * MAX_RECENT_SERVERS - 1),
	)

	forget_recent_server(&s, s.recent_servers[0].address)
	testing.expect_value(t, len(s.recent_servers), MAX_RECENT_SERVERS - 1)
}

@(test)
test_settings_roundtrip :: proc(t: ^testing.T) {
	path := "yap-settings-test.json"
	defer os.remove(path)

	s := DEFAULT_SETTINGS
	defer settings_destroy(&s)
	set_setting(&s.server, "localhost:7777")
	set_setting(&s.username, "me")
	s.notification_volume = 0.5
	server, other: [proto.KEY_SIZE]u8
	server[0], other[0] = 7, 8
	set_user_settings(&s, server, 1, {volume = 0.5})
	set_user_settings(&s, server, 2, {volume = 1, muted = true})
	set_user_settings(&s, server, 3, {volume = 1.5})
	set_user_settings(&s, server, 3, DEFAULT_USER) // back to default: not stored
	set_user_settings(&s, other, 1, {volume = 2})
	hide_dm(&s, server, 40, 1234)
	hide_dm(&s, server, 41, 10)
	hide_dm(&s, server, 41, 0) // put back
	settings_save(path, s)

	loaded := settings_load(path)
	defer settings_destroy(&loaded)
	testing.expect_value(t, loaded.server, "localhost:7777")
	testing.expect_value(t, loaded.username, "me")
	testing.expect_value(t, loaded.noise_suppression, true)
	testing.expect_value(t, notification_gain(&loaded), f32(0.5))
	testing.expect_value(t, len(loaded.users), 3)
	testing.expect_value(t, user_settings(&loaded, server, 1), User_Settings{volume = 0.5})
	testing.expect_value(t, user_settings(&loaded, server, 2), User_Settings{volume = 1, muted = true})
	testing.expect_value(t, user_settings(&loaded, server, 3), DEFAULT_USER)
	// Account 1 on another server is somebody else.
	testing.expect_value(t, user_settings(&loaded, other, 1), User_Settings{volume = 2})
	testing.expect_value(t, user_gain(user_settings(&loaded, server, 2)), 0)
	// Entries are keyed by the server and the account, and parse back.
	for k in loaded.users {
		got_server, account, ok := parse_server_key(k)
		testing.expect(t, ok && (got_server == server || got_server == other) && account >= 1 && account <= 2)
	}
	_, _, legacy_ok := parse_server_key("8e41fa62833a5a7751cd6873b91156e0dfc22fa2f939c26824a07ff64764a933")
	testing.expect(t, !legacy_ok, "a key from before accounts")

	// Hidden until there's something newer.
	testing.expect(t, dm_hidden(&loaded, server, 40, 1234))
	testing.expect(t, !dm_hidden(&loaded, server, 40, 1235))
	testing.expect(t, !dm_hidden(&loaded, other, 40, 1234))
	testing.expect(t, !dm_hidden(&loaded, server, 41, 10))
}


@(test)
test_settings_from_before_accounts :: proc(t: ^testing.T) {
	path := "yap-settings-old-test.json"
	defer os.remove(path)
	old := `{
		"server": "localhost:7777",
		"users": {
			"8e41fa62833a5a7751cd6873b91156e0dfc22fa2f939c26824a07ff64764a933": { "volume": 0.5, "muted": false },
			"8e41fa62833a5a7751cd6873b91156e0dfc22fa2f939c26824a07ff64764a933/2": { "volume": 2, "muted": false }
		},
		"buddies": {
			"8e41fa62833a5a7751cd6873b91156e0dfc22fa2f939c26824a07ff64764a933": { "name": "alice" }
		}
	}`
	testing.expect(t, os.write_entire_file(path, old) == nil)
	s := settings_load(path)
	defer settings_destroy(&s)
	testing.expect_value(t, s.server, "localhost:7777")
	testing.expect_value(t, len(s.users), 1)
}

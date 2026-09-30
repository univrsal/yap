#+build !wasi
package settings

import "core:fmt"
import "core:os"
import "core:path/filepath"
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

	alice := [proto.KEY_SIZE]u8 {
		0  = 0x8e,
		1  = 0x41,
		31 = 1,
	}
	bob := [proto.KEY_SIZE]u8 {
		0  = 0xab,
		31 = 2,
	}
	carol := [proto.KEY_SIZE]u8 {
		0  = 0x11,
		31 = 3,
	}

	s := DEFAULT_SETTINGS
	defer settings_destroy(&s)
	set_setting(&s.server, "localhost:7777")
	set_setting(&s.name, "me")
	s.notification_volume = 0.5
	set_user_settings(&s, alice, {volume = 0.5})
	set_user_settings(&s, bob, {volume = 1, muted = true})
	set_user_settings(&s, carol, {volume = 1.5})
	set_user_settings(&s, carol, DEFAULT_USER) // back to default: not stored
	settings_save(path, s)

	loaded := settings_load(path)
	defer settings_destroy(&loaded)
	testing.expect_value(t, loaded.server, "localhost:7777")
	testing.expect_value(t, loaded.name, "me")
	testing.expect_value(t, loaded.noise_suppression, true)
	testing.expect_value(t, notification_gain(&loaded), f32(0.5))
	testing.expect_value(t, len(loaded.users), 2)
	testing.expect_value(t, user_settings(&loaded, alice), User_Settings{volume = 0.5})
	testing.expect_value(t, user_settings(&loaded, bob), User_Settings{volume = 1, muted = true})
	testing.expect_value(t, user_settings(&loaded, carol), DEFAULT_USER)
	testing.expect_value(t, user_gain(user_settings(&loaded, bob)), 0)
	// Entries are keyed by the full key, and parse back to it.
	for hex_key in loaded.users {
		key, ok := parse_user_key(hex_key)
		testing.expect(t, ok && (key == alice || key == bob))
	}
	_, legacy_ok := parse_user_key("8e41fa62") // the old 4-byte ids
	testing.expect(t, !legacy_ok)
}

@(test)
test_buddies_saved_and_loaded :: proc(t: ^testing.T) {
	alice, bob: [proto.KEY_SIZE]u8
	alice[0], bob[0] = 1, 2

	s := DEFAULT_SETTINGS
	testing.expect(t, add_buddy(&s, alice, "alice"))
	testing.expect(t, add_buddy(&s, bob, ""))
	testing.expect(t, !add_buddy(&s, alice, "alice"), "adding again changed something")
	testing.expect(t, add_buddy(&s, alice, "alice2"), "a new name wasn't kept")

	dir := os.get_env("TMPDIR", context.temp_allocator)
	if dir == "" {
		dir = "/tmp"
	}
	path, _ := filepath.join({dir, "yap-buddies-test.json"}, context.temp_allocator)
	defer os.remove(path)
	settings_save(path, s)
	settings_destroy(&s)

	loaded := settings_load(path)
	defer settings_destroy(&loaded)
	testing.expect(t, is_buddy(&loaded, alice))
	testing.expect(t, is_buddy(&loaded, bob))
	testing.expect_value(t, loaded.buddies[user_key(alice)].name, "alice2")

	testing.expect(t, remove_buddy(&loaded, bob))
	testing.expect(t, !remove_buddy(&loaded, bob))
	testing.expect(t, !is_buddy(&loaded, bob))
}

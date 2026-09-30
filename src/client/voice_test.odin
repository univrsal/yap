#+build !wasi
package client

import "core:os"
import "core:testing"

import "client:audio"
import "common:proto"

// A deafen from the UI mutes as well, and plays one sound, not two.
@(test)
test_deafen_plays_once :: proc(t: ^testing.T) {
	c: Voice_Client
	testing.expect(t, audio.voice_init(&c.voice))
	defer audio.voice_destroy(&c.voice)
	defer commands_destroy(&c.commands)
	sounds := &c.voice.notifications

	push_command(&c.commands, Mute_Command{muted = true, feedback = false})
	push_command(&c.commands, Deafen_Command{deafened = true, feedback = true})
	process_commands(&c)
	testing.expect(t, raw_data(sounds.active) == raw_data(sounds.muted))
	testing.expect_value(t, sounds.queued_count, 0)

	audio.notifications_clear(sounds)
	push_command(&c.commands, Mute_Command{muted = false, feedback = false})
	push_command(&c.commands, Deafen_Command{deafened = false, feedback = true})
	process_commands(&c)
	testing.expect(t, raw_data(sounds.active) == raw_data(sounds.unmuted))
	testing.expect_value(t, sounds.queued_count, 0)

	// Mute on its own, and a repeat of what's already so, which is quiet.
	audio.notifications_clear(sounds)
	push_command(&c.commands, Mute_Command{muted = true, feedback = true})
	push_command(&c.commands, Mute_Command{muted = true, feedback = true})
	process_commands(&c)
	testing.expect(t, raw_data(sounds.active) == raw_data(sounds.muted))
	testing.expect_value(t, sounds.queued_count, 0)
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
test_display_names :: proc(t: ^testing.T) {
	users := []proto.User_Info {
		{num = 1, key = {0 = 0xaa, 1 = 0xbb, 2 = 0xcc, 3 = 0xdd}, name = "alice"},
		{num = 2, key = {0 = 0x11, 1 = 0x22, 2 = 0x33, 3 = 0x44}, name = "Bob"},
		{num = 3, key = {0 = 0x55, 1 = 0x66, 2 = 0x77, 3 = 0x88}, name = "bob"},
		{num = 4, key = {0 = 0x99, 1 = 0x00, 2 = 0x11, 3 = 0x22}, name = ""},
	}
	testing.expect_value(t, display_name(users, 1), "alice")
	// Same name (ignoring case): both get their key fingerprint.
	testing.expect_value(t, display_name(users, 2), "Bob (11223344)")
	testing.expect_value(t, display_name(users, 3), "bob (55667788)")
	testing.expect_value(t, display_name(users, 4), "99001122")
	testing.expect_value(t, display_name(users, 9), "user #9")
}

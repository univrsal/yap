#+build !wasi
package settings

import "core:os"
import "core:testing"

import "client:audio"
import "common:proto"

@(test)
test_joined_servers :: proc(t: ^testing.T) {
	s: Settings
	defer settings_destroy(&s)

	join_server(&s, "a:1", "")
	join_server(&s, "b:1", "pw")
	testing.expect_value(t, len(s.joined_servers), 2)
	testing.expect_value(t, s.joined_servers[0].address, "a:1") // in the order joined
	testing.expect_value(t, joined_password(&s, "b:1"), "pw")
	testing.expect_value(t, joined_password(&s, "c:1"), "")

	// Joining again keeps its place, with the new password, rather than
	// listing it twice.
	join_server(&s, "a:1", "new")
	testing.expect_value(t, len(s.joined_servers), 2)
	testing.expect_value(t, s.joined_servers[0].address, "a:1")
	testing.expect_value(t, joined_password(&s, "a:1"), "new")

	testing.expect(t, set_joined_channel(&s, "b:1", "general"))
	testing.expect(t, !set_joined_channel(&s, "b:1", "general"))
	testing.expect(t, !set_joined_channel(&s, "c:1", "general"))
	testing.expect_value(t, joined_channel(&s, "b:1"), "general")

	// Reordered by dragging on the rail: c:1 isn't shown there (it only appears
	// after the next start), so it goes after the servers that are.
	join_server(&s, "c:1", "")
	join_server(&s, "d:1", "")
	order_joined_servers(&s, {"d:1", "b:1", "a:1"})
	testing.expect_value(t, s.joined_servers[0].address, "d:1")
	testing.expect_value(t, s.joined_servers[1].address, "b:1")
	testing.expect_value(t, s.joined_servers[2].address, "a:1")
	testing.expect_value(t, s.joined_servers[3].address, "c:1")
	testing.expect_value(t, joined_password(&s, "b:1"), "pw")
	leave_server(&s, "c:1")
	leave_server(&s, "d:1")

	leave_server(&s, "a:1")
	testing.expect_value(t, len(s.joined_servers), 1)
	testing.expect_value(t, s.joined_servers[0].address, "b:1")
	leave_server(&s, "c:1") // not joined: no-op
	testing.expect_value(t, len(s.joined_servers), 1)
}

@(test)
test_animate_pictures :: proc(t: ^testing.T) {
	path := "yap-settings-animate-test.json"
	defer os.remove(path)

	// A file from before this setting existed defaults to Hover.
	testing.expect(t, os.write_entire_file(path, `{ "theme": "dark" }`) == nil)
	s := settings_load(path)
	testing.expect_value(t, animate_pictures(&s), Animate_Pictures.Hover)
	set_setting(&s.animate_pictures, ANIMATE_PICTURES_NAMES[.Always])
	settings_save(path, s)
	settings_destroy(&s)

	again := settings_load(path)
	testing.expect_value(t, animate_pictures(&again), Animate_Pictures.Always)
	set_setting(&again.animate_pictures, "sometimes") // an unknown value
	testing.expect_value(t, animate_pictures(&again), Animate_Pictures.Hover)
	set_setting(&again.animate_pictures, "never")
	testing.expect_value(t, animate_pictures(&again), Animate_Pictures.Never)
	settings_destroy(&again)
}

@(test)
test_recent_servers_become_joined :: proc(t: ^testing.T) {
	path := "yap-settings-recent-test.json"
	defer os.remove(path)
	old := `{
		"server": "b:1",
		"recent_servers": [
			{ "address": "b:1", "password": "pw", "channel": "general" },
			{ "address": "a:1", "password": "", "channel": "" }
		]
	}`
	testing.expect(t, os.write_entire_file(path, old) == nil)
	s := settings_load(path)
	defer settings_destroy(&s)
	testing.expect_value(t, len(s.joined_servers), 2)
	testing.expect_value(t, s.joined_servers[0].address, "b:1")
	testing.expect_value(t, joined_password(&s, "b:1"), "pw")
	testing.expect_value(t, joined_channel(&s, "b:1"), "general")
	testing.expect_value(t, len(s.recent_servers), 0)
	testing.expect_value(t, s.server, "")

	// The migration happens only once: after leaving all servers, they don't
	// come back.
	leave_server(&s, "a:1")
	leave_server(&s, "b:1")
	settings_save(path, s)
	again := settings_load(path)
	defer settings_destroy(&again)
	testing.expect_value(t, len(again.joined_servers), 0)
}

@(test)
test_settings_roundtrip :: proc(t: ^testing.T) {
	path := "yap-settings-test.json"
	defer os.remove(path)

	s := DEFAULT_SETTINGS
	defer settings_destroy(&s)
	join_server(&s, "localhost:7777", "pw")
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
	for e in ([]string{"a", "b", ":c:", "d", "b"}) {
		note_reaction(&s, server, e)
	}
	testing.expect(t, !note_reaction(&s, server, "b"), "already the latest")
	note_reaction(&s, other, "x")
	settings_save(path, s)

	loaded := settings_load(path)
	defer settings_destroy(&loaded)
	testing.expect_value(t, len(loaded.joined_servers), 1)
	testing.expect_value(t, joined_password(&loaded, "localhost:7777"), "pw")
	testing.expect_value(t, loaded.username, "me")
	testing.expect_value(t, loaded.noise_suppression, true)
	testing.expect_value(t, notification_gain(&loaded), f32(0.5))
	testing.expect_value(t, len(loaded.users), 3)
	testing.expect_value(t, user_settings(&loaded, server, 1), User_Settings{volume = 0.5})
	testing.expect_value(
		t,
		user_settings(&loaded, server, 2),
		User_Settings{volume = 1, muted = true},
	)
	testing.expect_value(t, user_settings(&loaded, server, 3), DEFAULT_USER)
	// Account 1 on another server is somebody else.
	testing.expect_value(t, user_settings(&loaded, other, 1), User_Settings{volume = 2})
	testing.expect_value(t, user_gain(user_settings(&loaded, server, 2)), 0)
	// Entries are keyed by the server and the account, and parse back.
	for k in loaded.users {
		got_server, account, ok := parse_server_key(k)
		testing.expect(
			t,
			ok && (got_server == server || got_server == other) && account >= 1 && account <= 2,
		)
	}
	_, _, legacy_ok := parse_server_key(
		"8e41fa62833a5a7751cd6873b91156e0dfc22fa2f939c26824a07ff64764a933",
	)
	testing.expect(t, !legacy_ok, "a key from before accounts")

	// A hidden DM stays hidden until there's a newer message.
	testing.expect(t, dm_hidden(&loaded, server, 40, 1234))
	testing.expect(t, !dm_hidden(&loaded, server, 40, 1235))
	testing.expect(t, !dm_hidden(&loaded, other, 40, 1234))
	testing.expect(t, !dm_hidden(&loaded, server, 41, 10))

	// Most recent first, without duplicates, capped at MAX_RECENT_REACTIONS, and
	// tracked per server.
	recent := recent_reactions(&loaded, server)
	testing.expect_value(t, len(recent), MAX_RECENT_REACTIONS)
	testing.expect_value(t, recent[0], "b")
	testing.expect_value(t, recent[1], "d")
	testing.expect_value(t, recent[2], ":c:")
	testing.expect_value(t, len(recent_reactions(&loaded, other)), 1)
	third: [proto.KEY_SIZE]u8
	third[0] = 9
	testing.expect_value(t, len(recent_reactions(&loaded, third)), 0)
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
	testing.expect_value(t, len(s.joined_servers), 1)
	testing.expect_value(t, s.joined_servers[0].address, "localhost:7777")
	testing.expect_value(t, len(s.users), 1)
}

@(test)
test_sound_names :: proc(t: ^testing.T) {
	path := "yap-settings-sounds-test.json"
	defer os.remove(path)

	s := DEFAULT_SETTINGS
	defer settings_destroy(&s)
	testing.expect_value(t, sound_name(&s, .Ring), "base/ring")
	testing.expect_value(t, sound_name(&s, .Message), "")
	set_sound_name(&s, .Message, "skype/msg")
	set_sound_name(&s, .Ring, "")
	set_sound_name(&s, .Knock, "skype/knocking") // the default: not stored
	set_sound_name(&s, .Mention, "custom:ding.wav")
	testing.expect_value(t, len(s.sounds), 3)
	settings_save(path, s)

	loaded := settings_load(path)
	defer settings_destroy(&loaded)
	testing.expect_value(t, sound_name(&loaded, .Message), "skype/msg")
	testing.expect_value(t, sound_name(&loaded, .Ring), "")
	testing.expect_value(t, loaded.sounds["ring"], "none")
	testing.expect_value(t, sound_name(&loaded, .Mention), "custom:ding.wav")
	testing.expect(t, sound_in_use(&loaded, "custom:ding.wav"))
	// A built-in sound that is gone is the default again.
	set_sound_name(&loaded, .Ringback, "skype/no_such_sound")
	testing.expect_value(t, sound_name(&loaded, .Ringback), "base/ringback")

	// Presets: a pack leaves the events it has no sound for alone.
	for preset in audio.SOUND_PRESETS {
		if preset.label == "AIM" {
			sound_preset_use(&loaded, preset)
		}
	}
	testing.expect_value(t, sound_name(&loaded, .Join), "aim/join")
	testing.expect_value(t, sound_name(&loaded, .Ring), "")
	testing.expect_value(t, sound_name(&loaded, .Mention), "aim/mail")
	testing.expect(t, !sound_in_use(&loaded, "custom:ding.wav"))
	sound_preset_use(&loaded, audio.SOUND_PRESETS[1]) // Quiet
	for kind in audio.Sound_Event {
		testing.expect_value(t, sound_name(&loaded, kind), "")
	}
	sound_preset_use(&loaded, audio.SOUND_PRESETS[0]) // Default
	testing.expect_value(t, len(loaded.sounds), 0)
	testing.expect_value(t, sound_name(&loaded, .Ring), "base/ring")
}

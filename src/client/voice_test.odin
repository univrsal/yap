#+build !wasi
package client

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

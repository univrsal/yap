#+build !wasi
package conn

import "core:testing"

import "client:audio"

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
	c := new(Voice_Client)
	defer free(c)
	defer delete(c.auth.accounts)
	ch := &c.channels
	ch.users_buf[0] = {
		num     = 1,
		account = 10,
	}
	ch.users_buf[1] = {
		num     = 2,
		account = 11,
	}
	ch.users_buf[2] = {
		num     = 3,
		account = 12,
	}
	ch.users_buf[3] = {
		num     = 4,
		account = 10,
	} 	// alice's other device
	ch.users_buf[4] = {
		num     = 5,
		account = 99,
	} 	// one we weren't told of
	ch.state.users = ch.users_buf[:5]
	ch.have_state = true
	c.auth.accounts[10] = {
		username = "alice",
		display  = "Alice",
	}
	c.auth.accounts[11] = {
		username = "bob",
		display  = "Bob",
	}
	c.auth.accounts[12] = {
		username = "robert",
		display  = "bob",
	}
	// Here, but not connected: doesn't make anyone's name ambiguous.
	c.auth.accounts[13] = {
		username = "alice2",
		display  = "alice",
	}

	testing.expect_value(t, display_name(c, 1), "Alice")
	// The same account twice is still only one Alice.
	testing.expect_value(t, display_name(c, 4), "Alice")
	// Same name (ignoring case) on two accounts: both get their username.
	testing.expect_value(t, display_name(c, 2), "Bob (bob)")
	testing.expect_value(t, display_name(c, 3), "bob (robert)")
	testing.expect_value(t, display_name(c, 5), "account #99")
	testing.expect_value(t, display_name(c, 9), "user #9")

	testing.expect(t, named(c, &ch.users_buf[1], "Bob"))
	testing.expect(t, named(c, &ch.users_buf[1], "bob"))
	testing.expect(t, !named(c, &ch.users_buf[1], "robert"))
	testing.expect(t, !named(c, &ch.users_buf[4], ""))
	testing.expect_value(t, account_display(c, 12), "bob")
	testing.expect_value(t, account_display(c, 99), "")
	testing.expect_value(t, account_by_username(c, "ROBERT"), 12)
	testing.expect_value(t, account_by_username(c, "nobody"), 0)
}

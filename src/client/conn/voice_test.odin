#+build !wasi
package conn

import "core:testing"

import "client:audio"
import "common:proto"

// A deafen from the UI also mutes, and plays one sound instead of two.
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
	testing.expect_value(t, sounds.playing_count, 1)
	testing.expect(
		t,
		raw_data(sounds.playing[0].samples) == raw_data(sounds.clips[.Deafened].samples),
	)

	audio.notifications_clear(sounds)
	push_command(&c.commands, Mute_Command{muted = false, feedback = false})
	push_command(&c.commands, Deafen_Command{deafened = false, feedback = true})
	process_commands(&c)
	testing.expect_value(t, sounds.playing_count, 1)
	testing.expect(
		t,
		raw_data(sounds.playing[0].samples) == raw_data(sounds.clips[.Undeafened].samples),
	)

	// Mute on its own, and a repeat of what is already the case, which is silent.
	audio.notifications_clear(sounds)
	push_command(&c.commands, Mute_Command{muted = true, feedback = true})
	push_command(&c.commands, Mute_Command{muted = true, feedback = true})
	process_commands(&c)
	testing.expect_value(t, sounds.playing_count, 1)
	testing.expect(
		t,
		raw_data(sounds.playing[0].samples) == raw_data(sounds.clips[.Muted].samples),
	)
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
	} // alice's other device
	ch.users_buf[4] = {
		num     = 5,
		account = 99,
	} // an account we were not told about
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
	// Here, but not connected: does not make anyone's name ambiguous.
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

// The calls' sounds: the ring, a knock instead while our voice is busy on
// another server, and how our own calls end.
@(test)
test_call_sounds :: proc(t: ^testing.T) {
	c: Voice_Client
	testing.expect(t, audio.voice_init(&c.voice))
	defer audio.voice_destroy(&c.voice)
	defer commands_destroy(&c.commands)
	c.auth.me = 1
	sounds := &c.voice.notifications
	audio.notifications_set(sounds, .Call_Declined, "skype/busy")
	audio.notifications_set(sounds, .Call_Ended, "skype/hangup")

	ring_buf: [proto.CALL_RING_SIZE]u8
	calls_event(&c, .Call_Ring, proto.encode_call_ring(&ring_buf, 5, 2))
	testing.expect_value(t, sounds.loop_event, audio.Sound_Event.Ring)
	push_command(&c.commands, Voice_Elsewhere_Command{busy = true})
	process_commands(&c)
	testing.expect_value(t, sounds.loop_event, audio.Sound_Event.Knock)
	push_command(&c.commands, Voice_Elsewhere_Command{busy = false})
	process_commands(&c)
	testing.expect_value(t, sounds.loop_event, audio.Sound_Event.Ring)

	changed :: proc(c: ^Voice_Client, change: proto.Call_Change) {
		buf: [proto.CALL_CHANGED_SIZE]u8
		calls_event(c, .Call_Changed, proto.encode_call_changed(&buf, change))
	}
	// Declined while it rang: the ring stops, and nothing plays.
	changed(&c, {id = 5, state = .Ended, reason = .Declined, caller = 2, callee = 1})
	testing.expect_value(t, sounds.loop_event, audio.Sound_Event.None)
	testing.expect_value(t, sounds.playing_count, 0)

	// Our own call, not answered.
	c.call = {
		id     = 6,
		status = .Ringing_Out,
		peer   = 2,
		here   = true,
	}
	changed(&c, {id = 6, state = .Ended, reason = .Unanswered, caller = 1, callee = 2})
	testing.expect(
		t,
		raw_data(sounds.playing[0].samples) == raw_data(sounds.clips[.Call_Declined].samples),
	)
	audio.notifications_clear(sounds)

	// Cancelled by us: nothing.
	c.call = {
		id     = 7,
		status = .Ringing_Out,
		peer   = 2,
		here   = true,
	}
	changed(&c, {id = 7, state = .Ended, reason = .Cancelled, caller = 1, callee = 2})
	testing.expect_value(t, sounds.playing_count, 0)

	// A call we were in ends; on another of our devices, it says nothing.
	c.call = {
		id     = 8,
		status = .Active,
		peer   = 2,
		here   = true,
	}
	changed(&c, {id = 8, state = .Ended, reason = .Hung_Up, caller = 1, callee = 2})
	testing.expect(
		t,
		raw_data(sounds.playing[0].samples) == raw_data(sounds.clips[.Call_Ended].samples),
	)
	audio.notifications_clear(sounds)
	c.call = {
		id     = 9,
		status = .Active,
		peer   = 2,
	}
	changed(&c, {id = 9, state = .Ended, reason = .Hung_Up, caller = 1, callee = 2})
	testing.expect_value(t, sounds.playing_count, 0)
}

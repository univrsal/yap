#+build !wasi
package conn

import "core:strings"
import "core:testing"

import "common:proto"

// Tests of who is here and where their voice is (presence.odin): applying the
// server's snapshots, acknowledging them, and telling the server what we have
// switched off.

@(private = "file")
open_voice :: proc(t: ^testing.T, tc: ^Test_Conn) {
	tc_open(tc)
	tc_connect(t, tc)
	tc.c.auth.me = 1
	tc.c.auth.state = .Done
	tc_account(tc, 1, "bob", "Bob")
	tc_account(tc, 2, "alice", "Alice")
	tc_account(tc, 3, "carol", "Carol")
	tc_conv(tc, 4, "Lobby")
	tc_conv(tc, 5, "Gaming")
}

@(private = "file")
deliver :: proc(
	tc: ^Test_Conn,
	version: u32,
	me: proto.User_Num,
	users: []proto.User_Info,
	order: []int = nil,
) -> int {
	return tc_snapshot(tc, version, me, users, order)
}

// acks returns the versions of the State_Acks among the datagrams sent.
@(private = "file")
acks :: proc(t: ^testing.T, tc: ^Test_Conn) -> []u32 {
	versions := make([dynamic]u32, context.temp_allocator)
	for d in tc_datagrams(t, tc) {
		if kind, ok := proto.message_kind(d); ok && kind == .State_Ack && len(d) == proto.STATE_ACK_SIZE {
			append(&versions, proto.decode_state_ack(d))
		}
	}
	return versions[:]
}

@(test)
test_snapshot_is_applied_and_acknowledged :: proc(t: ^testing.T) {
	tc: Test_Conn
	open_voice(t, &tc)
	defer tc_close(&tc)
	c := &tc.c
	testing.expect_value(t, my_num(c), proto.User_Num(0))
	testing.expect_value(t, my_room(c), proto.Room(0))

	deliver(
		&tc,
		7,
		11,
		{
			{num = 12, account = 2, room = 4}, // not in the order of their numbers
			{num = 14, account = 2, room = 0},
			{num = 13, account = 3, room = 5},
			{num = 11, account = 1, room = 4},
		},
	)
	testing.expect(t, c.channels.have_state)
	testing.expect_value(t, c.channels.applied_version, u32(7))
	testing.expect_value(t, my_num(c), proto.User_Num(11))
	testing.expect_value(t, my_room(c), proto.Room(4))
	got := acks(t, &tc)
	testing.expect_value(t, len(got), 1)
	if len(got) == 1 {
		testing.expect_value(t, got[0], u32(7))
	}

	// Who is in which room, in the order of their numbers; nobody is in room 0.
	members := room_members(c, 4)
	testing.expect_value(t, len(members), 2)
	if len(members) == 2 {
		testing.expect_value(t, members[0], proto.User_Num(11))
		testing.expect_value(t, members[1], proto.User_Num(12))
	}
	testing.expect_value(t, len(room_members(c, 5)), 1)
	testing.expect_value(t, len(room_members(c, 0)), 0)
	testing.expect_value(t, len(room_members(c, 99)), 0)

	// The mixer finds each user's account.
	testing.expect_value(t, c.voice.user_accounts[12], proto.Account_Id(2))
	testing.expect_value(t, len(c.voice.user_accounts), 4)
}

@(test)
test_snapshot_waits_for_the_login :: proc(t: ^testing.T) {
	tc: Test_Conn
	open_voice(t, &tc)
	defer tc_close(&tc)
	c := &tc.c

	// Who is here means nothing before we know who everyone is. It is not
	// acknowledged either, so that the server sends it again.
	c.auth.state = .Working
	deliver(&tc, 3, 11, {{num = 11, account = 1}})
	testing.expect(t, !c.channels.have_state)
	testing.expect_value(t, len(acks(t, &tc)), 0)
	c.auth.state = .Done
	deliver(&tc, 3, 11, {{num = 11, account = 1}})
	testing.expect(t, c.channels.have_state)
	testing.expect_value(t, len(acks(t, &tc)), 1)
}

@(test)
test_snapshot_versions :: proc(t: ^testing.T) {
	tc: Test_Conn
	open_voice(t, &tc)
	defer tc_close(&tc)
	c := &tc.c
	one := []proto.User_Info{{num = 11, account = 1, room = 4}}
	two := []proto.User_Info{{num = 11, account = 1, room = 5}}

	deliver(&tc, 5, 11, one)
	_ = acks(t, &tc)

	// What we have again (our ack was lost): it is acknowledged again, not applied again.
	deliver(&tc, 5, 11, two)
	testing.expect_value(t, my_room(c), proto.Room(4))
	got := acks(t, &tc)
	testing.expect_value(t, len(got), 1)

	// Older than what we have: ignored without a word.
	deliver(&tc, 4, 11, two)
	testing.expect_value(t, my_room(c), proto.Room(4))
	testing.expect_value(t, len(acks(t, &tc)), 0)

	// Newer replaces it.
	deliver(&tc, 6, 11, two)
	testing.expect_value(t, my_room(c), proto.Room(5))
	testing.expect_value(t, c.channels.applied_version, u32(6))
	testing.expect_value(t, len(acks(t, &tc)), 1)

	// Versions wrap around: 1 is newer than the largest number.
	c.channels.applied_version = 0xffff_fffe
	deliver(&tc, 1, 11, one)
	testing.expect_value(t, my_room(c), proto.Room(4))
	testing.expect_value(t, c.channels.applied_version, u32(1))
}

@(test)
test_snapshot_in_pieces :: proc(t: ^testing.T) {
	tc: Test_Conn
	open_voice(t, &tc)
	defer tc_close(&tc)
	c := &tc.c

	// A server with a lot of connections needs several State messages.
	users := make([]proto.User_Info, 300, context.temp_allocator)
	for &u, i in users {
		u = {num = proto.User_Num(i + 1), account = proto.Account_Id(1 + i % 3), room = proto.Room(4 if i % 2 == 0 else 5)}
	}
	count := proto.state_chunk_count(300 * proto.USER_SIZE + 6)
	testing.expect(t, count >= 3, "the snapshot is too small to need pieces")

	// Delivered last piece first: nothing is applied until all have arrived, and
	// it is acknowledged once.
	order := make([]int, count, context.temp_allocator)
	for i in 0 ..< count {
		order[i] = count - 1 - i
	}
	deliver(&tc, 9, 1, users, order)
	testing.expect(t, c.channels.have_state)
	testing.expect_value(t, len(c.channels.state.users), 300)
	testing.expect_value(t, len(acks(t, &tc)), 1)

	// Part of a newer snapshot changes nothing yet.
	body := make([]u8, proto.MAX_STATE_SIZE, context.temp_allocator)
	encoded, _ := proto.encode_state({your_user = 1, users = users[:10]}, body)
	chunk := make([]u8, proto.MAX_PAYLOAD_SIZE, context.temp_allocator)
	big := make([]u8, 3 * proto.STATE_CHUNK_SIZE, context.temp_allocator)
	copy(big, encoded)
	handle_state_message(c, proto.encode_state_chunk(chunk, 10, big, 0))
	testing.expect_value(t, c.channels.applied_version, u32(9))
	testing.expect_value(t, len(acks(t, &tc)), 0)
}

@(test)
test_invalid_snapshot_keeps_the_old_one :: proc(t: ^testing.T) {
	tc: Test_Conn
	open_voice(t, &tc)
	defer tc_close(&tc)
	c := &tc.c
	deliver(&tc, 1, 11, {{num = 11, account = 1, room = 4}})
	_ = acks(t, &tc)

	// A snapshot that says more users than it holds.
	body := make([]u8, 64, context.temp_allocator)
	encoded, _ := proto.encode_state({your_user = 11, users = {{num = 11, account = 1}, {num = 12, account = 2}}}, body)
	chunk := make([]u8, proto.MAX_PAYLOAD_SIZE, context.temp_allocator)
	handle_state_message(c, proto.encode_state_chunk(chunk, 2, encoded[:len(encoded) - 5], 0))
	testing.expect_value(t, c.channels.applied_version, u32(1))
	testing.expect_value(t, len(c.channels.state.users), 1)
	testing.expect_value(t, my_room(c), proto.Room(4))
	testing.expect_value(t, len(acks(t, &tc)), 0)
}

@(test)
test_channels_restart :: proc(t: ^testing.T) {
	tc: Test_Conn
	open_voice(t, &tc)
	defer tc_close(&tc)
	c := &tc.c
	deliver(&tc, 8, 11, {{num = 11, account = 1, room = 4}})

	channels_restart(c)
	testing.expect(t, !c.channels.have_state)
	testing.expect_value(t, c.channels.applied_version, u32(0))
	testing.expect_value(t, my_num(c), proto.User_Num(0))
	testing.expect_value(t, my_room(c), proto.Room(0))
	testing.expect_value(t, len(room_members(c, 4)), 0)
	// The server counts versions from the start again on the new connection.
	deliver(&tc, 1, 11, {{num = 11, account = 1, room = 5}})
	testing.expect_value(t, my_room(c), proto.Room(5))
}

@(test)
test_leaving_the_guest_room :: proc(t: ^testing.T) {
	tc: Test_Conn
	open_voice(t, &tc)
	defer tc_close(&tc)
	c := &tc.c
	c.convs.guest_room, c.convs.guest_name = 9, strings.clone("Secret")

	// Moved there by a moderator: we are in it.
	deliver(&tc, 1, 11, {{num = 11, account = 1, room = 9}})
	testing.expect_value(t, c.convs.guest_room, proto.Room(9))
	// A snapshot that still has us in it keeps it.
	deliver(&tc, 2, 11, {{num = 11, account = 1, room = 9}, {num = 12, account = 2, room = 9}})
	testing.expect_value(t, c.convs.guest_room, proto.Room(9))
	// One that has us elsewhere forgets it.
	deliver(&tc, 3, 11, {{num = 11, account = 1, room = 4}})
	testing.expect_value(t, c.convs.guest_room, proto.Room(0))
	testing.expect_value(t, c.convs.guest_name, "")
}

// ---- what we have switched off ----

@(test)
test_sound_flags :: proc(t: ^testing.T) {
	testing.expect_value(t, sound_flags(false, false), proto.User_Flags{})
	testing.expect_value(t, sound_flags(true, false), proto.User_Flags{.Muted})
	testing.expect_value(t, sound_flags(false, true), proto.User_Flags{.Deafened})
	testing.expect_value(t, sound_flags(true, true), proto.User_Flags{.Muted, .Deafened})
}

@(private = "file")
sounds_sent :: proc(t: ^testing.T, tc: ^Test_Conn) -> []proto.User_Flags {
	flags := make([dynamic]proto.User_Flags, context.temp_allocator)
	for d in tc_datagrams(t, tc) {
		if kind, ok := proto.message_kind(d); ok && kind == .Sound {
			append(&flags, proto.decode_sound(d))
		}
	}
	return flags[:]
}

@(test)
test_sound_is_sent_until_the_server_shows_it :: proc(t: ^testing.T) {
	tc: Test_Conn
	open_voice(t, &tc)
	defer tc_close(&tc)
	c := &tc.c

	// Nothing to say before a snapshot, or when there is nothing to change.
	set_sound(c, .Muted, true)
	drive_sound(c)
	testing.expect_value(t, len(sounds_sent(t, &tc)), 0)
	deliver(&tc, 1, 11, {{num = 11, account = 1, room = 4}})
	_ = tc_datagrams(t, &tc)

	// In a room the server shows us as being in voice too, so Muted alone isn't it.
	drive_sound(c)
	got := sounds_sent(t, &tc)
	testing.expect_value(t, len(got), 1)
	if len(got) == 1 {
		testing.expect_value(t, got[0], proto.User_Flags{.Muted})
	}

	// It is not repeated at once, but is after a while, until the server shows it.
	drive_sound(c)
	testing.expect_value(t, len(sounds_sent(t, &tc)), 0)
	c.channels.last_sound_sent = {}
	drive_sound(c)
	testing.expect_value(t, len(sounds_sent(t, &tc)), 1)

	// The server shows what we sent (and that we are talking): enough.
	deliver(&tc, 2, 11, {{num = 11, account = 1, room = 4, flags = {.Muted, .In_Voice}}})
	_ = tc_datagrams(t, &tc)
	c.channels.last_sound_sent = {}
	drive_sound(c)
	testing.expect_value(t, len(sounds_sent(t, &tc)), 0)

	// Switching something else on sends the new set; changing it resets the wait.
	set_sound(c, .Deafened, true)
	drive_sound(c)
	got = sounds_sent(t, &tc)
	testing.expect_value(t, len(got), 1)
	if len(got) == 1 {
		testing.expect_value(t, got[0], proto.User_Flags{.Muted, .Deafened})
	}
	set_sound(c, .Deafened, false)
	set_sound(c, .Muted, false)
	deliver(&tc, 3, 11, {{num = 11, account = 1, room = 4, flags = {.Muted, .Deafened, .In_Voice}}})
	_ = tc_datagrams(t, &tc)
	drive_sound(c)
	got = sounds_sent(t, &tc)
	testing.expect_value(t, len(got), 1)
	if len(got) == 1 {
		testing.expect_value(t, got[0], proto.User_Flags{})
	}
}

@(test)
test_sound_in_calls_and_hidden_voice :: proc(t: ^testing.T) {
	tc: Test_Conn
	open_voice(t, &tc)
	defer tc_close(&tc)
	defer profiles_destroy(&tc.c)
	c := &tc.c

	// In a call the server shows In_Call instead of In_Voice.
	call := proto.call_room(3)
	set_sound(c, .Muted, true)
	deliver(&tc, 1, 11, {{num = 11, account = 1, room = call, flags = {.Muted, .In_Call}}})
	_ = tc_datagrams(t, &tc)
	drive_sound(c)
	testing.expect_value(t, len(sounds_sent(t, &tc)), 0)
	deliver(&tc, 2, 11, {{num = 11, account = 1, room = call, flags = {.Muted, .In_Voice}}})
	_ = tc_datagrams(t, &tc)
	drive_sound(c)
	testing.expect_value(t, len(sounds_sent(t, &tc)), 1)

	// Somebody who chose not to show that they are talking is shown without it.
	c.profiles.shared[strings.clone(proto.SETTING_VOICE_SHOWN)] = strings.clone(proto.VOICE_SHOWN_HIDDEN)
	deliver(&tc, 3, 11, {{num = 11, account = 1, room = 4, flags = {.Muted}}})
	_ = tc_datagrams(t, &tc)
	c.channels.last_sound_sent = {}
	drive_sound(c)
	testing.expect_value(t, len(sounds_sent(t, &tc)), 0)
	deliver(&tc, 4, 11, {{num = 11, account = 1, room = 4, flags = {.Muted, .In_Voice}}})
	_ = tc_datagrams(t, &tc)
	c.channels.last_sound_sent = {}
	drive_sound(c)
	testing.expect_value(t, len(sounds_sent(t, &tc)), 1)
}

@(test)
test_talking_elsewhere_is_sent :: proc(t: ^testing.T) {
	tc: Test_Conn
	open_voice(t, &tc)
	defer tc_close(&tc)
	c := &tc.c

	// In a voice room or call on another server, and in none here: the server
	// is told, since it can't know.
	c.channels.talking = {.In_Voice}
	deliver(&tc, 1, 11, {{num = 11, account = 1, room = 0}})
	_ = tc_datagrams(t, &tc)
	drive_sound(c)
	got := sounds_sent(t, &tc)
	testing.expect_value(t, len(got), 1)
	if len(got) == 1 {
		testing.expect_value(t, got[0], proto.User_Flags{.In_Voice})
	}
	deliver(&tc, 2, 11, {{num = 11, account = 1, room = 0, flags = {.In_Voice}}})
	_ = tc_datagrams(t, &tc)
	c.channels.last_sound_sent = {}
	drive_sound(c)
	testing.expect_value(t, len(sounds_sent(t, &tc)), 0)
}

// ---- rooms ----

@(test)
test_being_in_a_room :: proc(t: ^testing.T) {
	tc: Test_Conn
	open_voice(t, &tc)
	defer tc_close(&tc)
	c := &tc.c
	testing.expect(t, !in_room(c))
	deliver(&tc, 1, 11, {{num = 11, account = 1, room = 4}})
	testing.expect(t, in_room(c))
	// While changing rooms voice is neither sent nor played.
	c.convs.voice_pending = true
	testing.expect(t, !in_room(c))
	c.convs.voice_pending = false
	deliver(&tc, 2, 11, {{num = 11, account = 1, room = 0}})
	testing.expect(t, !in_room(c))
}

@(test)
test_room_rights :: proc(t: ^testing.T) {
	tc: Test_Conn
	open_voice(t, &tc)
	defer tc_close(&tc)
	c := &tc.c
	info := c.convs.convs[4]
	info.rights = {.Speak}
	c.convs.convs[4] = info

	// In no room, nothing.
	testing.expect(t, !room_right(c, .Speak))
	testing.expect(t, !room_right(c, .Video))

	// In one of our channels: what its rights say.
	deliver(&tc, 1, 11, {{num = 11, account = 1, room = 4}})
	testing.expect(t, room_right(c, .Speak))
	testing.expect(t, !room_right(c, .Video))

	// In a call both may do both.
	deliver(&tc, 2, 11, {{num = 11, account = 1, room = proto.call_room(7)}})
	testing.expect(t, room_right(c, .Speak) && room_right(c, .Video))

	// In a channel that isn't ours the server judges video; a moderator who
	// moved us there lets us speak but not film.
	deliver(&tc, 3, 11, {{num = 11, account = 1, room = 9}})
	testing.expect(t, room_right(c, .Video))
	testing.expect(t, room_right(c, .Speak))
	c.convs.guest_room = 9
	testing.expect(t, room_right(c, .Speak))
	testing.expect(t, !room_right(c, .Video))
}

@(test)
test_members_string :: proc(t: ^testing.T) {
	tc: Test_Conn
	open_voice(t, &tc)
	defer tc_close(&tc)
	c := &tc.c
	testing.expect_value(t, members_string(c, nil), "nobody")

	deliver(
		&tc,
		1,
		11,
		{
			{num = 11, account = 1, room = 4},
			{num = 12, account = 2, room = 4, flags = {.Muted}},
			{num = 13, account = 3, room = 4, flags = {.Muted, .Deafened}},
			{num = 14, account = 3, room = 5, flags = {.Sharing}},
		},
	)
	testing.expect_value(t, members_string(c, {11}), "Bob (you)")
	testing.expect_value(t, members_string(c, {11, 12}), "Bob (you), Alice [muted]")
	// Deafened says more than muted, and neither hides that they are sharing.
	text := members_string(c, {13})
	testing.expect(t, strings.contains(text, "[deafened]") && !strings.contains(text, "[muted]"))
	testing.expect(t, strings.contains(members_string(c, {14}), "[sharing]"))
	// Somebody the snapshot doesn't have is named by number.
	testing.expect(t, strings.contains(members_string(c, {99}), "99"))
}

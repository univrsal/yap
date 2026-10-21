package server

import "core:testing"

import "common:proto"

// Everyone is told who is talking in a voice room or a call, though not
// where, unless they chose not to show it (proto.SETTING_VOICE_SHOWN).

@(private = "file")
flags_of :: proc(s: ^Server, account, viewer: proto.Account_Id) -> proto.User_Flags {
	users, hidden := presence_list(s)
	for u in users_seen_by(s, users, hidden, viewer) {
		if u.account == account {
			return u.flags
		}
	}
	return {}
}

@(private = "file")
set_shown :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn, value: string) {
	buf: [proto.SETTING_MAX_SIZE]u8
	body := proto.encode_setting(buf[:], proto.SETTING_VOICE_SHOWN, transmute([]u8)value)
	status, _ := ts_ask(t, ts, u, .Setting_Set, body)
	testing.expect_value(t, status, proto.Status.Ok)
}

@(private = "file")
ask_call :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	op: proto.Request_Op,
	body: []u8,
) -> proto.Call_Id {
	status, answer := ts_ask(t, ts, u, op, body)
	testing.expect_value(t, status, proto.Status.Ok)
	id, _ := proto.decode_call_id(answer)
	return id
}

@(test)
test_talking_flags :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	alice_acc := ts_account(t, &ts, "alice", "a password")
	bob_acc := ts_account(t, &ts, "bob", "a password")
	carol_acc := ts_account(t, &ts, "carol", "a password")
	alice := logged_in(t, &ts, "alice")
	bob := logged_in(t, &ts, "bob")
	carol := logged_in(t, &ts, "carol")
	NONE :: proto.User_Flags{}
	CALL :: proto.User_Flags{.In_Call}

	testing.expect_value(t, flags_of(s, alice_acc.id, carol_acc.id), NONE)
	buf: [4]u8
	call := ask_call(t, &ts, alice, .Call_Start, proto.encode_account_id(&buf, bob_acc.id))
	// Ringing isn't talking yet.
	testing.expect_value(t, flags_of(s, alice_acc.id, carol_acc.id), NONE)
	ask_call(t, &ts, bob, .Call_Accept, proto.encode_call_id(&buf, call))
	// carol may not know about the call's room, but she is told they're in a call.
	testing.expect_value(t, flags_of(s, alice_acc.id, carol_acc.id), CALL)
	testing.expect_value(t, flags_of(s, bob_acc.id, carol_acc.id), CALL)

	set_shown(t, &ts, bob, proto.VOICE_SHOWN_HIDDEN)
	testing.expect(t, bob_acc.voice_hidden)
	testing.expect_value(t, flags_of(s, bob_acc.id, carol_acc.id), NONE)
	testing.expect_value(t, flags_of(s, alice_acc.id, carol_acc.id), CALL)
	set_shown(t, &ts, bob, "")
	testing.expect_value(t, flags_of(s, bob_acc.id, carol_acc.id), CALL)
	ask_call(t, &ts, alice, .Call_End, proto.encode_call_id(&buf, call))
	testing.expect_value(t, flags_of(s, alice_acc.id, carol_acc.id), NONE)

	// In a channel's voice room, it's a voice chat.
	room_buf: [4]u8
	status, _ := ts_ask(
		t,
		&ts,
		carol,
		.Voice_Join,
		proto.encode_room(&room_buf, proto.Room(s.convs.home.id)),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, flags_of(s, carol_acc.id, alice_acc.id), proto.User_Flags{.In_Voice})
}

// A client says that it is talking on another server with the same flags in
// Sound. They are shown unless the account hides them, and a room here counts
// instead.
@(test)
test_talking_elsewhere :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	alice_acc := ts_account(t, &ts, "alice", "a password")
	bob_acc := ts_account(t, &ts, "bob", "a password")
	alice := logged_in(t, &ts, "alice")
	logged_in(t, &ts, "bob")
	VOICE :: proto.User_Flags{.In_Voice}

	sound_set(s, alice, {.Muted, .In_Voice})
	testing.expect_value(
		t,
		flags_of(s, alice_acc.id, bob_acc.id),
		proto.User_Flags{.Muted, .In_Voice},
	)
	// Claiming both is a call.
	sound_set(s, alice, {.In_Voice, .In_Call})
	testing.expect_value(t, flags_of(s, alice_acc.id, bob_acc.id), proto.User_Flags{.In_Call})

	set_shown(t, &ts, alice, proto.VOICE_SHOWN_HIDDEN)
	testing.expect_value(t, flags_of(s, alice_acc.id, bob_acc.id), proto.User_Flags{})
	set_shown(t, &ts, alice, "")

	// In a voice room here, that is what is shown.
	room_buf: [4]u8
	home := proto.Room(s.convs.home.id)
	status, _ := ts_ask(t, &ts, alice, .Voice_Join, proto.encode_room(&room_buf, home))
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, flags_of(s, alice_acc.id, bob_acc.id), VOICE)
	sound_set(s, alice, {})
	testing.expect_value(t, flags_of(s, alice_acc.id, bob_acc.id), VOICE)
	status, _ = ts_ask(t, &ts, alice, .Voice_Join, proto.encode_room(&room_buf, 0))
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, flags_of(s, alice_acc.id, bob_acc.id), proto.User_Flags{})
}

package server

import "core:crypto/ecdh"
import "core:encoding/endian"
import "core:fmt"
import "core:net"
import "core:testing"

import "common:proto"

// Tests of moderation in voice (moderation.odin): moving people between rooms
// and out of them, and muting them for everyone.

@(private = "file")
move_as :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	account: proto.Account_Id,
	room: proto.Room,
) -> proto.Status {
	buf: [proto.VOICE_MOVE_SIZE]u8
	status, _ := ts_ask(t, ts, u, .Voice_Move, proto.encode_voice_move(&buf, account, room))
	return status
}

@(private = "file")
mute_as :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	account: proto.Account_Id,
	on: bool,
) -> proto.Status {
	buf: [proto.VOICE_MUTE_SIZE]u8
	status, _ := ts_ask(t, ts, u, .Voice_Mute, proto.encode_voice_mute(&buf, account, on))
	return status
}

@(private = "file")
join_as :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn, room: proto.Room) {
	buf: [4]u8
	status, _ := ts_ask(t, ts, u, .Voice_Join, proto.encode_room(&buf, room))
	testing.expect_value(t, status, proto.Status.Ok)
}

@(private = "file")
channel_as :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	name: string,
	private := false,
	flags := proto.Conv_Flags{},
) -> proto.Room {
	buf: [proto.CONV_CREATE_MAX_SIZE]u8
	status, body := ts_ask(
		t,
		ts,
		u,
		.Conv_Create,
		proto.encode_conv_create(buf[:], name, "", private, flags),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	id, _ := proto.decode_conv_id(body)
	return proto.Room(id)
}

// told_moved returns the room and mover of the last Voice_Moved a connection
// was sent since its events were last read, and whether there was one.
@(private = "file")
told_moved :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
) -> (
	room: proto.Room,
	by: proto.Account_Id,
	told: bool,
) {
	for e in ts_events(t, ts, u) {
		if e.op == .Voice_Moved {
			room, by, _, told = proto.decode_voice_moved(e.body)
		}
	}
	return
}

@(test)
test_voice_move :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	ts_account(t, &ts, "olga", "a password", {.Owner})
	alice_acc := ts_account(t, &ts, "alice", "a password")
	bob_acc := ts_account(t, &ts, "bob", "a password")
	carol_acc := ts_account(t, &ts, "carol", "a password")
	olga := logged_in(t, &ts, "olga")
	alice := logged_in(t, &ts, "alice")
	bob := logged_in(t, &ts, "bob")
	carol := logged_in(t, &ts, "carol")
	// Permissions are added to everyone's, as roles would.
	alice_acc.perms += {.Move_Members}

	home := proto.Room(s.convs.home.id)
	games := channel_as(t, &ts, olga, "games")
	quiet := channel_as(t, &ts, olga, "quiet", flags = {.Text_Only})
	// Only Manage_Channels (olga, as the owner) has Voice in "stage".
	stage := channel_as(t, &ts, olga, "stage")
	rights_buf: [proto.CONV_RIGHTS_SET_MAX_SIZE]u8
	status, _ := ts_ask(
		t,
		&ts,
		olga,
		.Conv_Rights_Set,
		proto.encode_conv_rights_set(
			rights_buf[:],
			proto.Conv_Id(stage),
			{{proto.EVERYONE_ROLE, {.See, .Write}}},
		),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	join_as(t, &ts, bob, home)
	ts_events(t, &ts, bob)

	// Only with Move_Members.
	testing.expect_value(t, move_as(t, &ts, carol, bob_acc.id, games), proto.Status.Denied)
	testing.expect_value(t, bob.room, home)

	// bob is moved, and told who did it.
	testing.expect_value(t, move_as(t, &ts, alice, bob_acc.id, games), proto.Status.Ok)
	testing.expect_value(t, bob.room, games)
	room, by, told := told_moved(t, &ts, bob)
	testing.expect(t, told)
	testing.expect_value(t, room, games)
	testing.expect_value(t, by, alice_acc.id)
	// Moving them where they are is fine and tells them nothing.
	testing.expect_value(t, move_as(t, &ts, alice, bob_acc.id, games), proto.Status.Ok)
	_, _, told = told_moved(t, &ts, bob)
	testing.expect(t, !told)

	// Not where the mover couldn't talk: alice has no Voice in "stage", and
	// nobody has it in a text-only channel. A room that doesn't exist isn't
	// found.
	testing.expect_value(t, move_as(t, &ts, alice, bob_acc.id, stage), proto.Status.Denied)
	testing.expect_value(t, move_as(t, &ts, olga, bob_acc.id, quiet), proto.Status.Denied)
	testing.expect_value(t, move_as(t, &ts, alice, bob_acc.id, 9999), proto.Status.Not_Found)
	testing.expect_value(t, bob.room, games)
	// What bob may do there doesn't matter (D5): olga may talk in "stage".
	testing.expect_value(t, move_as(t, &ts, olga, bob_acc.id, stage), proto.Status.Ok)
	testing.expect_value(t, bob.room, stage)

	// Disconnecting is moving to no room.
	ts_events(t, &ts, bob)
	testing.expect_value(t, move_as(t, &ts, alice, bob_acc.id, 0), proto.Status.Ok)
	testing.expect_value(t, bob.room, proto.Room(0))
	room, by, told = told_moved(t, &ts, bob)
	testing.expect(t, told && room == 0 && by == alice_acc.id)
	// Someone not in a room can't be moved.
	testing.expect_value(t, move_as(t, &ts, alice, bob_acc.id, home), proto.Status.Not_Found)
	testing.expect_value(t, bob.room, proto.Room(0))

	// Not oneself, not the owner, and not someone who may do more.
	join_as(t, &ts, alice, home)
	join_as(t, &ts, olga, home)
	join_as(t, &ts, carol, home)
	testing.expect_value(t, move_as(t, &ts, alice, alice_acc.id, games), proto.Status.Invalid)
	testing.expect_value(t, move_as(t, &ts, alice, 1, games), proto.Status.Invalid)
	carol_acc.perms += {.Move_Members, .Purge}
	testing.expect_value(t, move_as(t, &ts, alice, carol_acc.id, games), proto.Status.Denied)
	testing.expect_value(t, move_as(t, &ts, alice, 9999, games), proto.Status.Not_Found)
	account_perms_update(&ts.s.accounts, carol_acc)

	// Nobody can be taken out of a room the mover may not know about.
	secret := channel_as(t, &ts, olga, "secret", private = true)
	member_buf: [proto.CONV_MEMBER_SET_SIZE]u8
	status, _ = ts_ask(
		t,
		&ts,
		olga,
		.Conv_Member_Set,
		proto.encode_conv_member_set(&member_buf, proto.Conv_Id(secret), bob_acc.id, true),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	join_as(t, &ts, bob, secret)
	testing.expect_value(t, move_as(t, &ts, alice, bob_acc.id, 0), proto.Status.Not_Found)
	testing.expect_value(t, bob.room, secret)
	testing.expect_value(t, move_as(t, &ts, olga, bob_acc.id, 0), proto.Status.Ok)
}

// room_seen_by returns the room that `viewer` is told `account` is in.
@(private = "file")
room_seen_by :: proc(s: ^Server, account, viewer: proto.Account_Id) -> proto.Room {
	users, hidden := presence_list(s)
	for u in users_seen_by(s, users, hidden, viewer) {
		if u.account == account {
			return u.room
		}
	}
	return 0
}

@(test)
test_voice_guest :: proc(t: ^testing.T) {
	// Someone moved into a room they couldn't join stays there, and sees it,
	// until they go elsewhere or the room goes (D5).
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	ts_account(t, &ts, "olga", "a password", {.Owner})
	bob_acc := ts_account(t, &ts, "bob", "a password")
	carol_acc := ts_account(t, &ts, "carol", "a password")
	olga := logged_in(t, &ts, "olga")
	bob := logged_in(t, &ts, "bob")
	logged_in(t, &ts, "carol")
	home := proto.Room(s.convs.home.id)
	secret := channel_as(t, &ts, olga, "secret", private = true)
	join_as(t, &ts, bob, home)

	// bob isn't in "secret", yet is moved there, sees where he is, and is
	// told the room's name. carol, who isn't in it either, doesn't see it.
	ts_events(t, &ts, bob)
	testing.expect_value(t, move_as(t, &ts, olga, bob_acc.id, secret), proto.Status.Ok)
	testing.expect_value(t, bob.room, secret)
	testing.expect_value(t, room_seen_by(s, bob_acc.id, bob_acc.id), secret)
	testing.expect_value(t, room_seen_by(s, bob_acc.id, carol_acc.id), proto.Room(0))
	e, told := has_event(ts_events(t, &ts, bob), .Voice_Moved)
	testing.expect(t, told)
	_, _, name, _ := proto.decode_voice_moved(e.body)
	testing.expect_value(t, name, "secret")

	// Changing who may do what there doesn't take him out.
	rights_buf: [proto.CONV_RIGHTS_SET_MAX_SIZE]u8
	status, _ := ts_ask(
		t,
		&ts,
		olga,
		.Conv_Rights_Set,
		proto.encode_conv_rights_set(
			rights_buf[:],
			proto.Conv_Id(secret),
			{{proto.EVERYONE_ROLE, {.See}}},
		),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, bob.room, secret)

	// Once he has gone elsewhere, he can't come back on his own.
	join_as(t, &ts, bob, home)
	testing.expect_value(t, bob.guest_room, proto.Room(0))
	buf: [4]u8
	status, _ = ts_ask(t, &ts, bob, .Voice_Join, proto.encode_room(&buf, secret))
	testing.expect_value(t, status, proto.Status.Not_Found)

	// A room that goes away takes its guests with it.
	testing.expect_value(t, move_as(t, &ts, olga, bob_acc.id, secret), proto.Status.Ok)
	status, _ = ts_ask(
		t,
		&ts,
		olga,
		.Conv_Delete,
		proto.encode_conv_id(&buf, proto.Conv_Id(secret)),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, bob.room, proto.Room(0))
}

@(test)
test_voice_mute :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	ts_account(t, &ts, "olga", "a password", {.Owner})
	alice_acc := ts_account(t, &ts, "alice", "a password")
	bob_acc := ts_account(t, &ts, "bob", "a password")
	carol_acc := ts_account(t, &ts, "carol", "a password")
	alice := logged_in(t, &ts, "alice")
	bob := logged_in(t, &ts, "bob")
	carol := logged_in(t, &ts, "carol")
	// Permissions are added to everyone's, as roles would.
	alice_acc.perms += {.Mute_Members}

	testing.expect_value(t, mute_as(t, &ts, carol, bob_acc.id, true), proto.Status.Denied)
	testing.expect(t, .Server_Muted not_in bob_acc.flags)

	// Everyone sees the mute in bob's account record.
	ts_events(t, &ts, carol)
	testing.expect_value(t, mute_as(t, &ts, alice, bob_acc.id, true), proto.Status.Ok)
	testing.expect(t, .Server_Muted in bob_acc.flags)
	e, told := has_event(ts_events(t, &ts, carol), .Account_Changed)
	testing.expect(t, told)
	acc, ok := proto.decode_account(e.body)
	testing.expect(t, ok && acc.id == bob_acc.id && .Server_Muted in acc.flags)
	// Muting again changes nothing and tells nobody.
	testing.expect_value(t, mute_as(t, &ts, alice, bob_acc.id, true), proto.Status.Ok)
	_, told = has_event(ts_events(t, &ts, carol), .Account_Changed)
	testing.expect(t, !told)

	// It lasts across logins, and is kept in the database.
	ts_disconnect(&ts, bob)
	bob = ts_connect(&ts, bob.key)
	testing.expect(t, bob.account == bob_acc && .Server_Muted in bob_acc.flags)
	stored, rc := db_pragma_int(
		&ts.s.db,
		fmt.tprintf("SELECT flags FROM accounts WHERE id = %d", bob_acc.id),
	)
	testing.expect_value(t, rc, 0)
	testing.expect(t, .Server_Muted in transmute(proto.Account_Flags)u8(stored))

	// Not oneself, not the owner, and not someone who may do more.
	testing.expect_value(t, mute_as(t, &ts, alice, alice_acc.id, true), proto.Status.Invalid)
	testing.expect_value(t, mute_as(t, &ts, alice, 1, true), proto.Status.Invalid)
	carol_acc.perms += {.Mute_Members, .Purge}
	testing.expect_value(t, mute_as(t, &ts, alice, carol_acc.id, true), proto.Status.Denied)
	account_perms_update(&ts.s.accounts, carol_acc)

	testing.expect_value(t, mute_as(t, &ts, alice, bob_acc.id, false), proto.Status.Ok)
	testing.expect(t, .Server_Muted not_in bob_acc.flags)
}

// A muted account's voice isn't relayed. This one uses real sessions over
// loopback UDP sockets, like bulk_test.
@(test)
test_muted_voice_dropped :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	s.max_sessions = 16
	testing.expect(t, ecdh.private_key_generate(&s.key, .X25519))
	sock, err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	testing.expect_value(t, err, nil)
	s.sock = sock
	defer net.close(sock)
	defer delete(s.sessions)
	alice_acc := ts_account(t, &ts, "alice", "a password")
	bob_acc := ts_account(t, &ts, "bob", "a password")

	handle :: proc(data: rawptr, pkt: []u8, from: net.Endpoint) {
		handle_packet((^Server)(data), pkt, from)
	}
	out: [proto.MAX_PAYLOAD_SIZE]u8
	keys: [2]ecdh.Private_Key
	links: [2]Test_Link
	conns: [2]^Conn
	for i in 0 ..< 2 {
		testing.expect(t, ecdh.private_key_generate(&keys[i], .X25519))
		link_open_socket(t, &links[i])
		pt := link_handshake_with(t, &links[i], &keys[i], u64(i + 1), .Main, out[:], handle, s)
		testing.expect_value(t, proto.Message_Kind(pt[0]), proto.Message_Kind.Welcome)
		pub: [proto.KEY_SIZE]u8
		ecdh.private_key_public_bytes(&keys[i], pub[:])
		conns[i] = conn_of(s, pub)
		if !testing.expect(t, conns[i] != nil) {
			return
		}
	}
	defer net.close(links[0].sock)
	defer net.close(links[1].sock)
	alice, bob := conns[0], conns[1]
	conn_login(s, alice, alice_acc)
	conn_login(s, bob, bob_acc)
	home := proto.Room(s.convs.home.id)
	conn_set_room(s, alice, home)
	conn_set_room(s, bob, home)

	// alice says something, as voice frame `seq`.
	say :: proc(s: ^Server, l: ^Test_Link, seq: u32) {
		pt: [proto.VOICE_UP_HEADER_SIZE + 3]u8
		pt[0] = u8(proto.Message_Kind.Voice)
		endian.unchecked_put_u32le(pt[1:], seq)
		pkt_buf: [proto.MAX_PACKET_SIZE]u8
		pkt, _ := proto.seal(&l.sess, pt[:], pkt_buf[:])
		handle_packet(s, pkt, l.from)
	}
	// heard returns the frame number of the next voice that reaches `l`.
	heard :: proc(t: ^testing.T, l: ^Test_Link) -> u32 {
		buf: [proto.MAX_PAYLOAD_SIZE]u8
		for _ in 0 ..< 32 {
			pt := link_recv(t, l, buf[:])
			if len(pt) == 0 {
				return 0
			}
			if proto.Message_Kind(pt[0]) == .Voice && len(pt) >= 9 {
				return endian.unchecked_get_u32le(pt[5:])
			}
		}
		return 0
	}

	say(s, &links[0], 1)
	testing.expect_value(t, heard(t, &links[1]), 1)
	// Frame 2 is said while muted and goes nowhere, so the next bob hears
	// is frame 3, said once the mute was lifted.
	account_set_flags(&s.accounts, alice_acc, alice_acc.flags + {.Server_Muted})
	say(s, &links[0], 2)
	account_set_flags(&s.accounts, alice_acc, alice_acc.flags - {.Server_Muted})
	say(s, &links[0], 3)
	testing.expect_value(t, heard(t, &links[1]), 3)

	// Dropping their sessions removes the connections with them.
	for u in conns {
		if c := sending_session(s, u); c != nil {
			drop_session(s, c.local_idx)
		}
	}
	testing.expect_value(t, len(s.sessions), 0)
}

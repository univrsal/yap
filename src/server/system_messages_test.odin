package server

import "core:fmt"
import "core:testing"

import "common:proto"

// system_notes returns the system messages about channels and the server in a
// conversation's newest page of history.
@(private = "file")
system_notes :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	conv: proto.Conv_Id,
) -> []proto.Message {
	status, body := ts_ask(t, ts, u, .Msg_History, history_body(conv))
	testing.expect_value(t, status, proto.Status.Ok)
	buf := make([]proto.Message, proto.MAX_HISTORY_LIMIT, context.temp_allocator)
	_, msgs, ok := proto.decode_history_page(body, buf)
	testing.expect(t, ok)
	notes := make([dynamic]proto.Message, context.temp_allocator)
	for m in msgs {
		if m.kind == .System && !proto.system_counts_unread(m.system) {
			append(&notes, m)
		}
	}
	return notes[:]
}

// expect_note checks that a system message says that `sender` did `what` (to
// `arg`), changing what `text` says.
@(private = "file")
expect_note :: proc(
	t: ^testing.T,
	m: proto.Message,
	what: proto.Conv_System,
	sender: proto.Account_Id,
	arg: proto.Account_Id = 0,
	text := "",
	loc := #caller_location,
) {
	testing.expect_value(t, proto.Conv_System(m.system), what, loc = loc)
	testing.expect_value(t, m.sender, sender, loc = loc)
	testing.expect_value(t, proto.Account_Id(m.system_arg), arg, loc = loc)
	testing.expect_value(t, m.text, text, loc = loc)
}

@(test)
test_system_messages :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	admin_acc := ts_account(t, &ts, "admin", "a password", {.Owner})
	alice_acc := ts_account(t, &ts, "alice", "a password")
	bob_acc := ts_account(t, &ts, "bob", "a password")
	admin := logged_in(t, &ts, "admin")
	alice := logged_in(t, &ts, "alice")
	bob := logged_in(t, &ts, "bob")
	gaming := conv_by_name(&s.convs, "Gaming")
	sub_buf: [proto.CONV_SUBSCRIBE_SIZE]u8
	id_buf: [4]u8

	// Joining a channel says so, renaming it and changing its topic too, and
	// none of it is unread.
	status, _ := ts_ask(
		t,
		&ts,
		alice,
		.Conv_Subscribe,
		proto.encode_conv_subscribe(&sub_buf, gaming.id, true),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	update_buf: [proto.CONV_UPDATE_MAX_SIZE]u8
	status, _ = ts_ask(
		t,
		&ts,
		admin,
		.Conv_Update,
		proto.encode_conv_update(
			update_buf[:],
			{
				conv = gaming.id,
				mask = proto.CONV_UPDATE_NAME | proto.CONV_UPDATE_TOPIC,
				name = "Games",
				topic = "play nice",
			},
		),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, conv_record(&s.convs, gaming, alice_acc.id).unread, 0)
	ts_events(t, &ts, alice)

	// Mentioning someone in a public channel adds them, which says so. The
	// mention itself is unread, the note isn't.
	status, _ = post(t, &ts, alice, gaming.id, fmt.tprintf("hi <@%d>", bob_acc.id), 1)
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, conv_record(&s.convs, gaming, bob_acc.id).unread, 1)
	status, _ = ts_ask(
		t,
		&ts,
		alice,
		.Conv_Subscribe,
		proto.encode_conv_subscribe(&sub_buf, gaming.id, false),
	)
	testing.expect_value(t, status, proto.Status.Ok)

	notes := system_notes(t, &ts, bob, gaming.id)
	testing.expect_value(t, len(notes), 5)
	if len(notes) == 5 {
		expect_note(t, notes[0], .Joined, alice_acc.id)
		expect_note(t, notes[1], .Renamed, admin_acc.id, text = "Gaming\nGames")
		expect_note(t, notes[2], .Topic_Changed, admin_acc.id, text = "\nplay nice")
		expect_note(t, notes[3], .Added, alice_acc.id, bob_acc.id)
		expect_note(t, notes[4], .Left, alice_acc.id)
	}

	// Adding someone to a private channel and taking them out again, and
	// archiving a channel.
	create_buf: [proto.CONV_CREATE_MAX_SIZE]u8
	body: []u8
	status, body = ts_ask(
		t,
		&ts,
		admin,
		.Conv_Create,
		proto.encode_conv_create(create_buf[:], "Secret", "", true),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	secret, _ := proto.decode_conv_id(body)
	member_buf: [proto.CONV_MEMBER_SET_SIZE]u8
	for on in ([]bool{true, false}) {
		status, _ = ts_ask(
			t,
			&ts,
			admin,
			.Conv_Member_Set,
			proto.encode_conv_member_set(&member_buf, secret, bob_acc.id, on),
		)
		testing.expect_value(t, status, proto.Status.Ok)
	}
	notes = system_notes(t, &ts, admin, secret)
	testing.expect_value(t, len(notes), 2)
	if len(notes) == 2 {
		expect_note(t, notes[0], .Added, admin_acc.id, bob_acc.id)
		expect_note(t, notes[1], .Removed, admin_acc.id, bob_acc.id)
	}
	// An archived channel can't be read any more, but its members are told
	// before it goes.
	ts_events(t, &ts, admin)
	status, _ = ts_ask(t, &ts, admin, .Conv_Delete, proto.encode_conv_id(&id_buf, secret))
	testing.expect_value(t, status, proto.Status.Ok)
	archived := false
	for e in ts_events(t, &ts, admin) {
		if e.op == .Msg_New {
			m, _ := proto.decode_message(e.body)
			archived ||= m.conv == secret && proto.Conv_System(m.system) == .Archived
		}
	}
	testing.expect(t, archived, "archiving the channel didn't say so")

	// An account that is made and deleted joins and leaves the server, in the
	// home channel.
	account_buf: [proto.ACCOUNT_BODY_MAX]u8
	status, body = ts_ask(
		t,
		&ts,
		admin,
		.Account_Create,
		proto.encode_account_create(account_buf[:], "carol", "first password", "Carol"),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	carol, _ := proto.decode_account_id(body)
	status, _ = ts_ask(
		t,
		&ts,
		admin,
		.Account_Delete,
		proto.encode_account_delete(account_buf[:], carol, ""),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	notes = system_notes(t, &ts, bob, s.convs.home.id)
	testing.expect_value(t, len(notes), 2)
	if len(notes) == 2 {
		expect_note(t, notes[0], .Joined_Server, carol)
		expect_note(t, notes[1], .Left_Server, carol)
	}
	testing.expect_value(t, conv_record(&s.convs, s.convs.home, bob_acc.id).unread, 0)
}

// A system message's kind and text are kept, and read back, as they were.
@(test)
test_system_message_record :: proc(t: ^testing.T) {
	m := proto.Message {
		id         = 3,
		conv       = 1,
		sender     = 2,
		kind       = .System,
		system     = u8(proto.Conv_System.Renamed),
		system_arg = 7,
		text       = "old\nnew",
	}
	buf: [proto.MESSAGE_MAX_SIZE]u8
	got, ok := proto.decode_message(proto.encode_message(buf[:], m))
	testing.expect(t, ok)
	testing.expect_value(t, got.system, m.system)
	testing.expect_value(t, got.system_arg, m.system_arg)
	testing.expect_value(t, got.text, "old\nnew")
	old, new := proto.system_change(got.text)
	testing.expect(t, old == "old" && new == "new")
	testing.expect(t, proto.system_counts_unread(u8(proto.Call_System.Missed)))
	testing.expect(t, !proto.system_counts_unread(m.system))
}

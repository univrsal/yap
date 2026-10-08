package server

import "core:fmt"
import "core:testing"

import "common:proto"

// Tests of mentions, on the Test_Server of auth_test.odin.

@(private = "file")
mentions_of :: proc(ts: ^Test_Server, conv: ^Conv, acc: ^Account) -> int {
	return conv_record(&ts.s.convs, conv, acc.id).mentions
}

@(test)
test_mentions :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	home := s.convs.home
	gaming := conv_by_name(&s.convs, "Gaming")
	alice_acc := ts_account(t, &ts, "alice", "a password")
	bob_acc := ts_account(t, &ts, "bob", "a password")
	carol_acc := ts_account(t, &ts, "carol", "a password")
	ts_account(t, &ts, "admin", "a password", {.Owner})
	alice := logged_in(t, &ts, "alice")
	bob := logged_in(t, &ts, "bob")
	carol := logged_in(t, &ts, "carol")
	admin := logged_in(t, &ts, "admin")
	tok :: proc(a: ^Account) -> string {
		return proto.mention_token(a.id)
	}

	// Who exists and isn't the poster; <@everyone> only from who may.
	_, id := post(
		t,
		&ts,
		alice,
		home.id,
		fmt.tprintf("hi %s <@999> %s <@everyone>", tok(bob_acc), tok(alice_acc)),
		1,
	)
	m, _ := msg_by_id(s, id)
	testing.expect_value(
		t,
		m.text,
		fmt.tprintf("hi %s <@999> %s @everyone", tok(bob_acc), tok(alice_acc)),
	)
	testing.expect_value(t, mentions_of(&ts, home, bob_acc), 1)
	testing.expect_value(t, mentions_of(&ts, home, carol_acc), 0)
	testing.expect_value(t, mentions_of(&ts, home, alice_acc), 0)
	_, everyone := post(t, &ts, admin, home.id, "<@everyone> listen", 2)
	testing.expect_value(t, mentions_of(&ts, home, bob_acc), 2)
	testing.expect_value(t, mentions_of(&ts, home, carol_acc), 1)
	testing.expect_value(t, mentions_of(&ts, home, alice_acc), 1)

	// Reading them clears them.
	status, _ := ts_ask(t, &ts, bob, .Mark_Read, mark_body(home.id, everyone))
	testing.expect_value(t, status, proto.Status.Ok)
	state, told := read_state(t, &ts, bob)
	testing.expect(t, told)
	testing.expect_value(t, state.mentions, 0)

	// An edit that drops a mention tells who it was for; one that adds
	// one, too.
	ts_events(t, &ts, carol)
	_, plain := post(t, &ts, alice, home.id, "nothing to see", 3)
	testing.expect_value(
		t,
		edit_as(t, &ts, alice, plain, fmt.tprintf("look %s", tok(carol_acc))),
		proto.Status.Ok,
	)
	state, told = read_state(t, &ts, carol)
	testing.expect(t, told, "carol wasn't told she's mentioned now")
	testing.expect_value(t, state.mentions, 2)
	testing.expect_value(t, edit_as(t, &ts, alice, plain, "never mind"), proto.Status.Ok)
	state, told = read_state(t, &ts, carol)
	testing.expect(t, told)
	testing.expect_value(t, state.mentions, 1)
	// So does deleting one.
	testing.expect_value(t, delete_as(t, &ts, admin, everyone), proto.Status.Ok)
	state, told = read_state(t, &ts, carol)
	testing.expect(t, told)
	testing.expect_value(t, state.mentions, 0)

	// In a public channel, being mentioned subscribes; the message is
	// unread for them, and a mention.
	testing.expect(t, conv_member_add(&s.convs, gaming, alice_acc.id))
	testing.expect(t, !conv_is_member(gaming, carol_acc.id))
	ts_events(t, &ts, carol)
	_, there := post(t, &ts, alice, gaming.id, fmt.tprintf("%s come here", tok(carol_acc)), 4)
	testing.expect(t, conv_is_member(gaming, carol_acc.id))
	record := conv_record(&s.convs, gaming, carol_acc.id)
	testing.expect_value(t, record.unread, 1)
	testing.expect_value(t, record.mentions, 1)
	conv_told, msg_told := false, false
	for e in ts_events(t, &ts, carol) {
		#partial switch e.op {
		case .Conv_Changed:
			c, _ := proto.decode_conv(e.body)
			if c.id == gaming.id {
				testing.expect(t, !msg_told, "the message came before the channel")
				conv_told = true
			}
		case .Msg_New:
			got, _ := proto.decode_message(e.body)
			msg_told ||= got.id == there
		}
	}
	testing.expect(t, conv_told && msg_told)

	// Not in a DM, or anywhere else one can't read.
	buf: [4]u8
	_, body := ts_ask(t, &ts, alice, .DM_Open, proto.encode_account_id(&buf, bob_acc.id))
	dm, _ := proto.decode_conv_id(body)
	_, private_mention := post(t, &ts, alice, dm, fmt.tprintf("between us, %s", tok(carol_acc)), 5)
	for a in mentioned_in(s, private_mention) {
		testing.expect(t, a != carol_acc.id, "carol counted for a DM she isn't in")
	}
	testing.expect(t, !conv_is_member(conv_by_id(&s.convs, dm), carol_acc.id))
}

@(test)
test_role_mentions :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	gaming := conv_by_name(&s.convs, "Gaming")
	alice_acc := ts_account(t, &ts, "alice", "a password")
	bob_acc := ts_account(t, &ts, "bob", "a password")
	carol_acc := ts_account(t, &ts, "carol", "a password")
	ts_account(t, &ts, "admin", "a password", {.Owner})
	alice := logged_in(t, &ts, "alice")
	admin := logged_in(t, &ts, "admin")
	make_role :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn, r: proto.Role) -> proto.Role_Id {
		buf: [proto.ROLE_MAX_SIZE]u8
		status, body := ts_ask(t, ts, u, .Role_Set, proto.encode_role(buf[:], r))
		testing.expect_value(t, status, proto.Status.Ok)
		id, _ := proto.decode_account_id(body)
		return proto.Role_Id(id)
	}
	leads := make_role(t, &ts, admin, {name = "Team Leads", flags = {.Mentionable}})
	quiet := make_role(t, &ts, admin, {name = "quiet"})
	testing.expect_value(t, s.accounts.roles[leads].flags, proto.Role_Flags{.Mentionable})
	for acc in ([]^Account{alice_acc, bob_acc, carol_acc}) {
		testing.expect(t, account_roles_set(&s.accounts, acc, {leads, quiet}))
	}
	// Everyone's role can't be: that's @everyone.
	make_role(t, &ts, admin, {id = proto.EVERYONE_ROLE, name = "everyone", flags = {.Mentionable}})
	testing.expect_value(t, s.accounts.roles[proto.EVERYONE_ROLE].flags, proto.Role_Flags{})

	// Whoever has it, among the members, but not the poster; nobody is
	// subscribed by it.
	testing.expect(t, conv_member_add(&s.convs, gaming, alice_acc.id))
	testing.expect(t, conv_member_add(&s.convs, gaming, bob_acc.id))
	testing.expect(t, !conv_is_member(gaming, carol_acc.id))
	text := fmt.tprintf(
		"%s and %s",
		proto.role_mention_token(leads),
		proto.role_mention_token(quiet),
	)
	_, id := post(t, &ts, alice, gaming.id, text, 1)
	m, _ := msg_by_id(s, id)
	// One that can't be mentioned is its name.
	testing.expect_value(t, m.text, fmt.tprintf("%s and @quiet", proto.role_mention_token(leads)))
	testing.expect(t, !conv_is_member(gaming, carol_acc.id), "carol was subscribed by a role")
	mentioned := mentioned_in(s, id)
	testing.expect_value(t, len(mentioned), 1)
	if len(mentioned) == 1 {
		testing.expect_value(t, mentioned[0], bob_acc.id)
	}
	testing.expect_value(t, mentions_of(&ts, gaming, bob_acc), 1)

	// Once it can't be, an edit drops it.
	make_role(t, &ts, admin, {id = leads, name = "Team Leads"})
	testing.expect_value(t, edit_as(t, &ts, alice, id, m.text), proto.Status.Ok)
	m, _ = msg_by_id(s, id)
	testing.expect_value(t, m.text, "@Team Leads and @quiet")
	testing.expect_value(t, len(mentioned_in(s, id)), 0)
}

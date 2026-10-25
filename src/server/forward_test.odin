package server

import "core:strings"
import "core:testing"

import "common:proto"

// Tests of forwarding and links (proto/forward.odin), using the Test_Server
// from harness_test.odin.

@(private = "file")
forward :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	to: proto.Conv_Id,
	msg: proto.Msg_Id,
	nonce: u64,
) -> (
	status: proto.Status,
	id: proto.Msg_Id,
) {
	buf: [proto.MSG_FORWARD_SIZE]u8
	answer: []u8
	status, answer = ts_ask(
		t,
		ts,
		u,
		.Msg_Forward,
		proto.encode_msg_forward(&buf, {conv = to, nonce = nonce, msg = msg}),
	)
	if status == .Ok {
		ok: bool
		id, _, ok = proto.decode_msg_posted(answer)
		testing.expect(t, ok)
	}
	return
}

@(test)
test_forward :: proc(t: ^testing.T) {
	dir := test_dir(t)
	defer remove_tree(dir)
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	testing.expect(t, blob_store_open(&s.blobs, &s.db, dir))
	home := s.convs.home.id
	gaming := conv_by_name(&s.convs, "Gaming")
	alice_acc := ts_account(t, &ts, "alice", "a password")
	bob_acc := ts_account(t, &ts, "bob", "a password")
	carol_acc := ts_account(t, &ts, "carol", "a password")
	alice := logged_in(t, &ts, "alice")
	bob := logged_in(t, &ts, "bob")
	carol := logged_in(t, &ts, "carol")
	testing.expect(t, conv_member_add(&s.convs, gaming, alice_acc.id))

	// Only messages that the user is allowed to read can be forwarded.
	_, secret := post(t, &ts, alice, gaming.id, "only in Gaming", 1)
	status, _ := forward(t, &ts, bob, home, secret, 100)
	testing.expect_value(t, status, proto.Status.Not_Found)

	// Forwarding from the channel to a DM records where the message came from.
	// Mentions in the message don't mention anyone again.
	_, said := post(t, &ts, alice, home, "hello <@3>", 2)
	dm_status, dm := dm_open_as(t, &ts, bob, carol_acc.id)
	testing.expect_value(t, dm_status, proto.Status.Ok)
	copy_id: proto.Msg_Id
	status, copy_id = forward(t, &ts, bob, dm, said, 101)
	testing.expect_value(t, status, proto.Status.Ok)
	m, found := msg_by_id(s, copy_id)
	testing.expect(t, found)
	original, _ := msg_by_id(s, said)
	testing.expect_value(t, m.kind, proto.Msg_Kind.Text)
	testing.expect_value(t, m.text, "hello <@3>")
	testing.expect_value(t, m.sender, bob_acc.id)
	testing.expect(t, .Forwarded in m.flags)
	testing.expect_value(t, m.forward, proto.Forward_Info{alice_acc.id, home, original.time})
	testing.expect_value(t, len(mentioned_in(s, copy_id)), 0)
	// Reusing the same nonce returns the same copy.
	again: proto.Msg_Id
	status, again = forward(t, &ts, bob, dm, said, 101)
	testing.expect_value(t, again, copy_id)

	// A copy of a copy refers to the original message.
	status, copy_id = forward(t, &ts, carol, home, copy_id, 300)
	testing.expect_value(t, status, proto.Status.Ok)
	m, _ = msg_by_id(s, copy_id)
	testing.expect_value(t, m.forward.sender, alice_acc.id)
	testing.expect_value(t, m.forward.conv, home)

	// Nobody can edit a copy.
	testing.expect_value(t, edit_as(t, &ts, carol, copy_id, "changed"), proto.Status.Invalid)

	// The files of a message (e.g. a pasted picture) are shared as the same blobs.
	blob, _ := blob_put(&s.blobs, .File, test_jpeg(32, 32, 1), 32, 32)
	pic := proto.Message {
		conv             = home,
		sender           = alice_acc.id,
		kind             = .Text,
		flags            = {.Has_Attachments},
		attachment_count = 1,
	}
	pic.attachments[0] = {
		blob = blob,
		size = 3000,
		name = "pasted-image.jpg",
	}
	testing.expect(t, msg_store(s, conv_by_id(&s.convs, home), &pic, 3))
	status, copy_id = forward(t, &ts, bob, dm, pic.id, 102)
	testing.expect_value(t, status, proto.Status.Ok)
	m, _ = msg_by_id(s, copy_id)
	testing.expect(t, .Has_Attachments in m.flags)
	testing.expect_value(t, m.attachment_count, 1)
	testing.expect_value(t, m.attachments[0].blob, blob)
	testing.expect_value(t, m.attachments[0].name, "pasted-image.jpg")

	// A deleted message can't be forwarded.
	testing.expect_value(t, delete_as(t, &ts, alice, said), proto.Status.Ok)
	status, _ = forward(t, &ts, bob, dm, said, 103)
	testing.expect_value(t, status, proto.Status.Invalid)

	// A link to a DM message only works inside that DM.
	_, in_dm := post(t, &ts, bob, dm, "between us", 104)
	link := proto.link_token(dm, in_dm)
	_, kept := post(
		t,
		&ts,
		carol,
		dm,
		strings.concatenate({"see ", link}, context.temp_allocator),
		301,
	)
	m, _ = msg_by_id(s, kept)
	testing.expect_value(t, m.text, strings.concatenate({"see ", link}, context.temp_allocator))
	_, plain := post(
		t,
		&ts,
		bob,
		home,
		strings.concatenate({"see ", link}, context.temp_allocator),
		105,
	)
	m, _ = msg_by_id(s, plain)
	testing.expect_value(t, m.text, "see (a message in a DM)")
	// Many of them would make the text longer than a message can be, so
	// such a message is refused.
	many := strings.repeat(
		strings.concatenate({link, " "}, context.temp_allocator),
		proto.MAX_CHAT_SIZE / (len(link) + 1),
		context.temp_allocator,
	)
	status, _ = post(t, &ts, bob, home, many, 107)
	testing.expect_value(t, status, proto.Status.Too_Large)
	// A link to a channel message can be posted anywhere.
	channel_link := proto.link_token(home, pic.id)
	_, kept = post(t, &ts, bob, dm, channel_link, 106)
	m, _ = msg_by_id(s, kept)
	testing.expect_value(t, m.text, channel_link)
}

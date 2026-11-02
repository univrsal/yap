#+build !wasi
package conn

import "core:testing"

import "common:proto"

// Tests of the outbox (outbox.odin): messages of ours that are on their way.

// posted answers a Msg_Post as the server would.
@(private = "file")
posted :: proc(tc: ^Test_Conn, id: u32, msg: proto.Msg_Id) {
	buf: [proto.MSG_POSTED_SIZE]u8
	tc_answer(tc, id, .Ok, proto.encode_msg_posted(&buf, msg, 5000))
}

// sent_post returns the post a request carried.
@(private = "file")
sent_post :: proc(t: ^testing.T, r: Test_Request) -> proto.Msg_Post {
	testing.expect_value(t, r.op, proto.Request_Op.Msg_Post)
	p, ok := proto.decode_msg_post(r.body)
	testing.expect(t, ok)
	return p
}

// only returns the requests of one op. Opening a conversation also asks for
// its history, which these tests don't look at.
@(private = "file")
only :: proc(sent: []Test_Request, op: proto.Request_Op) -> []Test_Request {
	found := make([dynamic]Test_Request, context.temp_allocator)
	for r in sent {
		if r.op == op {
			append(&found, r)
		}
	}
	return found[:]
}

@(private = "file")
open_lobby :: proc(tc: ^Test_Conn) {
	tc_open(tc)
	tc.c.auth.me = 1
	tc_conv(tc, 1, "Lobby")
	tc_account(tc, 1, "bob")
	tc_account(tc, 2, "alice")
	tc.c.convs.viewing = 1
}

@(test)
test_outbox_posts_in_order :: proc(t: ^testing.T) {
	tc: Test_Conn
	open_lobby(&tc)
	defer tc_close(&tc)
	c := &tc.c

	chat_send(c, "first")
	chat_send(c, "second")
	testing.expect_value(t, len(c.msgs.outbox), 2)
	testing.expect(t, c.msgs.outbox[0].nonce != c.msgs.outbox[1].nonce)
	testing.expect(t, c.msgs.outbox[0].nonce != 0)

	// Only the oldest goes out, and only once however often the outbox is driven.
	drive_outbox(c)
	drive_outbox(c)
	sent := tc_sent(t, &tc)
	testing.expect_value(t, len(sent), 1)
	first := sent_post(t, sent[0])
	testing.expect_value(t, first.text, "first")
	testing.expect_value(t, first.conv, proto.Conv_Id(1))
	testing.expect_value(t, first.nonce, c.msgs.outbox[0].nonce)
	testing.expect_value(t, first.thread_root, proto.Msg_Id(0))

	// The next goes once the first is posted.
	posted(&tc, sent[0].id, 10)
	testing.expect_value(t, len(c.msgs.outbox), 1)
	testing.expect_value(t, c.convs.convs[1].last, proto.Msg_Id(10))
	drive_outbox(c)
	sent = tc_sent(t, &tc)
	testing.expect_value(t, len(sent), 1)
	testing.expect_value(t, sent_post(t, sent[0]).text, "second")
	posted(&tc, sent[0].id, 11)
	testing.expect_value(t, len(c.msgs.outbox), 0)
	testing.expect_value(t, c.convs.convs[1].last, proto.Msg_Id(11))
}

@(test)
test_outbox_repeats_with_the_same_nonce :: proc(t: ^testing.T) {
	tc: Test_Conn
	open_lobby(&tc)
	defer tc_close(&tc)
	c := &tc.c

	chat_send(c, "hello")
	drive_outbox(c)
	sent := tc_sent(t, &tc)
	nonce := sent_post(t, sent[0]).nonce

	// The connection is lost before the answer. The server recognizes the
	// nonce, so the post may be repeated without it appearing twice.
	tc_restart(&tc)
	testing.expect_value(t, len(c.msgs.outbox), 1)
	testing.expect(t, !c.msgs.outbox[0].asking)
	drive_outbox(c)
	sent = tc_sent(t, &tc)
	testing.expect_value(t, len(sent), 1)
	testing.expect_value(t, sent_post(t, sent[0]).nonce, nonce)

	// A late answer to the first attempt is not an answer to the second.
	tc_answer(&tc, 1, .Ok)
	testing.expect_value(t, len(c.msgs.outbox), 1)
	posted(&tc, sent[0].id, 7)
	testing.expect_value(t, len(c.msgs.outbox), 0)
}

@(test)
test_outbox_ignores_empty_and_homeless :: proc(t: ^testing.T) {
	tc: Test_Conn
	open_lobby(&tc)
	defer tc_close(&tc)
	c := &tc.c

	chat_send(c, "")
	chat_send(c, "   \n\t ")
	testing.expect_value(t, len(c.msgs.outbox), 0)

	// Without a conversation to write to, there is nowhere for it to go.
	c.convs.viewing = 0
	chat_send(c, "hello?")
	testing.expect_value(t, len(c.msgs.outbox), 0)
	// ... and neither in one that isn't ours.
	chat_send(c, "hello?", channel = 99)
	testing.expect_value(t, len(c.msgs.outbox), 0)

	// A channel can be named, whatever is being looked at.
	chat_send(c, "to the lobby", channel = 1)
	testing.expect_value(t, len(c.msgs.outbox), 1)
	testing.expect_value(t, c.msgs.outbox[0].conv, proto.Conv_Id(1))
}

@(test)
test_outbox_waits_for_the_connection :: proc(t: ^testing.T) {
	tc: Test_Conn
	open_lobby(&tc)
	defer tc_close(&tc)
	c := &tc.c

	chat_send(c, "hello")
	c.convs.synced = false
	drive_outbox(c)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	c.convs.synced = true
	c.has_current = false
	drive_outbox(c)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	c.has_current = true
	drive_outbox(c)
	testing.expect_value(t, len(tc_sent(t, &tc)), 1)
}

@(test)
test_outbox_text_is_cleaned :: proc(t: ^testing.T) {
	tc: Test_Conn
	open_lobby(&tc)
	defer tc_close(&tc)
	c := &tc.c

	chat_send(c, "a\x00b\x07c")
	drive_outbox(c)
	sent := tc_sent(t, &tc)
	testing.expect_value(t, len(sent), 1)
	text := sent_post(t, sent[0]).text
	testing.expect(t, text != "" && text != "a\x00b\x07c", "control characters were sent")
}

@(test)
test_outbox_gives_up_on_refusals :: proc(t: ^testing.T) {
	context.logger = expected_errors() // the warnings are expected

	for status in ([]proto.Status{.Denied, .Invalid, .Not_Found, .Internal, .Rate_Limited}) {
		tc: Test_Conn
		open_lobby(&tc)
		defer tc_close(&tc)
		c := &tc.c

		chat_send(c, "one")
		chat_send(c, "two")
		drive_outbox(c)
		sent := tc_sent(t, &tc)
		tc_answer(&tc, sent[0].id, status)
		// What was refused is dropped, so that it can't hold up the rest.
		testing.expectf(t, len(c.msgs.outbox) == 1, "%v: %d left", status, len(c.msgs.outbox))
		drive_outbox(c)
		sent = tc_sent(t, &tc)
		testing.expectf(t, len(sent) == 1, "%v: the next was not sent", status)
		if len(sent) == 1 {
			testing.expect_value(t, sent_post(t, sent[0]).text, "two")
		}
	}
}

@(test)
test_outbox_drops_posts_to_channels_we_left :: proc(t: ^testing.T) {
	context.logger = expected_errors() // the warning is expected
	tc: Test_Conn
	open_lobby(&tc)
	defer tc_close(&tc)
	c := &tc.c

	chat_send(c, "hello")
	delete(c.convs.convs[1].name)
	delete_key(&c.convs.convs, 1)
	drive_outbox(c)
	testing.expect_value(t, len(c.msgs.outbox), 0)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
}

@(test)
test_outbox_opens_a_dm_first :: proc(t: ^testing.T) {
	tc: Test_Conn
	open_lobby(&tc)
	defer tc_close(&tc)
	c := &tc.c

	chat_send(c, "psst", dm_to = 2)
	testing.expect_value(t, len(c.msgs.outbox), 1)
	testing.expect_value(t, c.msgs.outbox[0].state, Post_State.Open)

	// The DM has to exist before anything is posted to it.
	drive_outbox(c)
	drive_outbox(c)
	sent := tc_sent(t, &tc)
	testing.expect_value(t, len(sent), 1)
	testing.expect_value(t, sent[0].op, proto.Request_Op.DM_Open)
	account, ok := proto.decode_account_id(sent[0].body)
	testing.expect(t, ok)
	testing.expect_value(t, account, proto.Account_Id(2))

	// The server tells us about the DM and then answers.
	c.convs.convs[5] = {
		kind          = .DM,
		accounts      = {0 = 1, 1 = 2},
		account_count = 2,
	}
	buf: [4]u8
	tc_answer(&tc, sent[0].id, .Ok, proto.encode_conv_id(&buf, 5))
	testing.expect_value(t, c.msgs.outbox[0].state, Post_State.Post)
	testing.expect_value(t, c.msgs.outbox[0].conv, proto.Conv_Id(5))

	drive_outbox(c)
	sent = only(tc_sent(t, &tc), .Msg_Post)
	testing.expect_value(t, len(sent), 1)
	post := sent_post(t, sent[0])
	testing.expect_value(t, post.conv, proto.Conv_Id(5))
	testing.expect_value(t, post.text, "psst")
	posted(&tc, sent[0].id, 3)
	testing.expect_value(t, len(c.msgs.outbox), 0)

	// With the DM there, the next one goes straight to it.
	chat_send(c, "again", dm_to = 2)
	testing.expect_value(t, c.msgs.outbox[0].state, Post_State.Post)
	testing.expect_value(t, c.msgs.outbox[0].conv, proto.Conv_Id(5))
}

@(test)
test_outbox_dm_that_cannot_be_opened :: proc(t: ^testing.T) {
	context.logger = expected_errors() // the warning is expected
	tc: Test_Conn
	open_lobby(&tc)
	defer tc_close(&tc)
	c := &tc.c

	chat_send(c, "psst", dm_to = 2)
	drive_outbox(c)
	sent := tc_sent(t, &tc)
	tc_answer(&tc, sent[0].id, .Denied)
	testing.expect_value(t, len(c.msgs.outbox), 0)

	// A connection lost meanwhile asks again instead of giving up.
	chat_send(c, "psst", dm_to = 2)
	drive_outbox(c)
	_ = tc_sent(t, &tc)
	tc_restart(&tc)
	testing.expect_value(t, len(c.msgs.outbox), 1)
	drive_outbox(c)
	sent = tc_sent(t, &tc)
	testing.expect_value(t, len(sent), 1)
	testing.expect_value(t, sent[0].op, proto.Request_Op.DM_Open)
}

@(test)
test_outbox_reply_in_a_thread :: proc(t: ^testing.T) {
	tc: Test_Conn
	open_lobby(&tc)
	defer tc_close(&tc)
	c := &tc.c

	chat_send(c, "in reply", thread = {conv = 1, root = 40})
	testing.expect_value(t, c.msgs.outbox[0].root, proto.Msg_Id(40))
	drive_outbox(c)
	sent := tc_sent(t, &tc)
	post := sent_post(t, sent[0])
	testing.expect_value(t, post.thread_root, proto.Msg_Id(40))
	testing.expect_value(t, post.conv, proto.Conv_Id(1))
}

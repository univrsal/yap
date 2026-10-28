package server

import "core:testing"

import "common:proto"

// persona_post posts `text` as `u` under a persona and returns the answer.
@(private = "file")
persona_post :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	conv: proto.Conv_Id,
	persona: proto.Persona,
	nonce: u64,
) -> (
	status: proto.Status,
	id: proto.Msg_Id,
) {
	buf := make([]u8, proto.MSG_POST_MAX_SIZE, context.temp_allocator)
	body := proto.encode_msg_post(
		buf,
		{conv = conv, nonce = nonce, kind = .Text, text = "hello", persona = persona},
	)
	answer: []u8
	status, answer = ts_ask(t, ts, u, .Msg_Post, body)
	if status == .Ok {
		ok: bool
		id, _, ok = proto.decode_msg_posted(answer)
		testing.expect(t, ok)
	}
	return
}

@(test)
test_persona :: proc(t: ^testing.T) {
	dir := test_dir(t)
	defer remove_tree(dir)
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	testing.expect(t, blob_store_open(&s.blobs, &s.db, dir))
	ts_account(t, &ts, "alice", "a password")
	bot := ts_account(t, &ts, "ci", "", {.Bot})
	key := ts_bot_key(7)
	testing.expect(t, device_link(&s.accounts, key, bot, "token", "") != nil)
	a := logged_in(t, &ts, "alice")
	b := ts_connect(&ts, key)
	testing.expect(t, b.account == bot)
	ts_events(t, &ts, a)
	home := s.convs.home.id

	// Only bots have personas.
	status, _ := persona_post(t, &ts, a, home, {name = "Build"}, 1)
	testing.expect_value(t, status, proto.Status.Denied)

	// Not the name of an account, in any case, nor an empty one.
	status, _ = persona_post(t, &ts, b, home, {name = "ALICE"}, 2)
	testing.expect_value(t, status, proto.Status.Denied)
	status, _ = persona_post(t, &ts, b, home, {name = "CI"}, 3)
	testing.expect_value(t, status, proto.Status.Denied)
	status, _ = persona_post(t, &ts, b, home, {name = " \t\n"}, 4)
	testing.expect_value(t, status, proto.Status.Invalid)

	// The picture has to be a stored avatar.
	status, _ = persona_post(t, &ts, b, home, {name = "Build", avatar = 999}, 5)
	testing.expect_value(t, status, proto.Status.Not_Found)
	file, _ := blob_put(&s.blobs, .File, test_jpeg(64, 64, 4), 64, 64)
	status, _ = persona_post(t, &ts, b, home, {name = "Build", avatar = file}, 6)
	testing.expect_value(t, status, proto.Status.Invalid)

	// Nobody can fetch the picture until a message uses it.
	pic, stored := blob_put(&s.blobs, .Avatar, test_jpeg(64, 64, 9), 64, 64)
	testing.expect(t, stored)
	id_buf: [proto.BLOB_GET_SIZE]u8
	status, _ = ts_ask(t, &ts, a, .Blob_Get, proto.encode_blob_id(&id_buf, pic))
	testing.expect_value(t, status, proto.Status.Not_Found)

	id: proto.Msg_Id
	status, id = persona_post(t, &ts, b, home, {name = "  Build Server #123 ", avatar = pic}, 7)
	testing.expect_value(t, status, proto.Status.Ok)
	status, _ = ts_ask(t, &ts, a, .Blob_Get, proto.encode_blob_id(&id_buf, pic))
	testing.expect_value(t, status, proto.Status.Ok)

	// Everyone is sent the message with the persona, which is the bot's.
	e, told := has_event(ts_events(t, &ts, a), .Msg_New)
	testing.expect(t, told)
	m, ok := proto.decode_message(e.body)
	testing.expect(t, ok)
	testing.expect_value(t, m.sender, bot.id)
	testing.expect_value(t, m.flags, proto.Msg_Flags{.Persona})
	testing.expect_value(t, m.persona, proto.Persona{"Build Server #123", pic})

	// History and a changed message keep it, a post without one has none.
	status, _ = persona_post(t, &ts, b, home, {}, 8)
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, edit_as(t, &ts, b, id, "edited"), proto.Status.Ok)
	msgs, _ := history_of(t, &ts, a, home)
	found := 0
	for got in msgs {
		switch got.id {
		case id:
			found += 1
			testing.expect_value(t, got.persona, proto.Persona{"Build Server #123", pic})
			testing.expect_value(t, got.text, "edited")
		case:
			testing.expect_value(t, .Persona in got.flags, false)
		}
	}
	testing.expect_value(t, found, 1)

	// Deleting a message removes the persona, and with the last message that
	// used it, the picture is no longer available.
	testing.expect_value(t, delete_as(t, &ts, b, id), proto.Status.Ok)
	msgs, _ = history_of(t, &ts, a, home)
	for got in msgs {
		if got.id == id {
			testing.expect_value(t, got.persona, proto.Persona{})
			testing.expect(t, .Deleted in got.flags && .Persona not_in got.flags)
		}
	}
	status, _ = ts_ask(t, &ts, a, .Blob_Get, proto.encode_blob_id(&id_buf, pic))
	testing.expect_value(t, status, proto.Status.Not_Found)
}

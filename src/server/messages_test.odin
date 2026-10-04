package server

import "core:os"
import "core:testing"

import "common:proto"

// Tests of messages and blobs, on the Test_Server of auth_test.odin.

history_body :: proc(
	conv: proto.Conv_Id,
	anchor: proto.Msg_Id = 0,
	dir := proto.History_Dir.Before,
	limit := proto.MAX_HISTORY_LIMIT,
) -> []u8 {
	buf := new([proto.MSG_HISTORY_SIZE]u8, context.temp_allocator)
	return proto.encode_msg_history(buf, {conv = conv, anchor = anchor, dir = dir, limit = limit})
}

// post posts a text message as `u`; its id if it was posted.
post :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	conv: proto.Conv_Id,
	text: string,
	nonce: u64,
) -> (
	status: proto.Status,
	id: proto.Msg_Id,
) {
	buf := make([]u8, proto.MSG_POST_MAX_SIZE, context.temp_allocator)
	body := proto.encode_msg_post(buf, {conv = conv, nonce = nonce, kind = .Text, text = text})
	answer: []u8
	status, answer = ts_ask(t, ts, u, .Msg_Post, body)
	if status == .Ok {
		ok: bool
		id, _, ok = proto.decode_msg_posted(answer)
		testing.expect(t, ok)
	}
	return
}

// history reads a page; the messages are in the temp allocator.
@(private = "file")
history :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	conv: proto.Conv_Id,
	anchor: proto.Msg_Id = 0,
	dir := proto.History_Dir.Before,
	limit := proto.MAX_HISTORY_LIMIT,
) -> (
	msgs: []proto.Message,
	more: u8,
) {
	status, body := ts_ask(t, ts, u, .Msg_History, history_body(conv, anchor, dir, limit))
	testing.expect_value(t, status, proto.Status.Ok)
	buf := make([]proto.Message, proto.MAX_HISTORY_LIMIT, context.temp_allocator)
	ok: bool
	more, msgs, ok = proto.decode_history_page(body, buf)
	testing.expect(t, ok)
	return
}

@(private = "file")
new_messages :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn) -> (msgs: [dynamic]proto.Message) {
	msgs = make([dynamic]proto.Message, context.temp_allocator)
	for e in ts_events(t, ts, u) {
		if e.op == .Msg_New {
			m, ok := proto.decode_message(e.body)
			testing.expect(t, ok)
			append(&msgs, m)
		}
	}
	return
}

@(test)
test_post_and_read :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	ts_account(t, &ts, "alice", "a password")
	ts_account(t, &ts, "bob", "a password")
	ts_account(t, &ts, "carol", "a password")
	laptop := logged_in(t, &ts, "alice")
	phone := logged_in(t, &ts, "alice")
	bob := logged_in(t, &ts, "bob")
	carol := logged_in(t, &ts, "carol")
	home := s.convs.home.id
	gaming := conv_by_name(&s.convs, "Gaming")
	testing.expect(t, conv_member_add(&s.convs, gaming, laptop.account.id))
	testing.expect(t, conv_member_add(&s.convs, gaming, bob.account.id))

	// Posted, it goes to every connection of every member, the poster's
	// own included, and to nobody else.
	status, id := post(t, &ts, laptop, gaming.id, "  hello\tthere ", 1)
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect(t, id != 0)
	testing.expect_value(t, gaming.last_msg, id)
	for u in ([]^Conn{laptop, phone, bob}) {
		got := new_messages(t, &ts, u)
		testing.expect_value(t, len(got), 1)
		testing.expect_value(t, got[0].id, id)
		testing.expect_value(t, got[0].text, "hello there") // sanitized
		testing.expect_value(t, got[0].sender, laptop.account.id)
		testing.expect_value(t, got[0].conv, gaming.id)
	}
	testing.expect_value(t, len(new_messages(t, &ts, carol)), 0)

	// And it's there to read.
	msgs, more := history(t, &ts, bob, gaming.id)
	testing.expect_value(t, len(msgs), 1)
	testing.expect_value(t, msgs[0].id, id)
	testing.expect_value(t, msgs[0].text, "hello there")
	testing.expect_value(t, more, 0)

	// Only by members: carol isn't in Gaming, and nobody is in a channel
	// that isn't there.
	status, _ = ts_ask(t, &ts, carol, .Msg_History, history_body(gaming.id))
	testing.expect_value(t, status, proto.Status.Denied)
	status, _ = post(t, &ts, carol, gaming.id, "let me in", 2)
	testing.expect_value(t, status, proto.Status.Denied)
	status, _ = ts_ask(t, &ts, carol, .Msg_History, history_body(999))
	testing.expect_value(t, status, proto.Status.Not_Found)
	status, _ = post(t, &ts, carol, home, "hi all", 3)
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, len(new_messages(t, &ts, bob)), 1) // bob is in home

	// The same post again (its answer lost with the connection) is the
	// same message, stored and delivered once.
	again, other: proto.Msg_Id
	status, again = post(t, &ts, phone, gaming.id, "hello there", 1)
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, again, id)
	testing.expect_value(t, len(new_messages(t, &ts, bob)), 0)
	msgs, _ = history(t, &ts, bob, gaming.id)
	testing.expect_value(t, len(msgs), 1)
	// The nonce is the poster's: bob's 1 is another message.
	status, other = post(t, &ts, bob, gaming.id, "me too", 1)
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect(t, other > id)

	// Nothing to post, no nonce, or a thread with no root is refused.
	status, _ = post(t, &ts, bob, gaming.id, " \t ", 4)
	testing.expect_value(t, status, proto.Status.Invalid)
	status, _ = post(t, &ts, bob, gaming.id, "no nonce", 0)
	testing.expect_value(t, status, proto.Status.Invalid)
	buf: [proto.MSG_POST_MAX_SIZE]u8
	status, _ = ts_ask(
		t,
		&ts,
		bob,
		.Msg_Post,
		proto.encode_msg_post(
			buf[:],
			{conv = gaming.id, nonce = 5, thread_root = 999, kind = .Text, text = "re"},
		),
	)
	testing.expect_value(t, status, proto.Status.Invalid)
	status, _ = ts_ask(t, &ts, bob, .Msg_Post, []u8{1, 2, 3})
	testing.expect_value(t, status, proto.Status.Invalid)
}

@(test)
test_history_pages :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	ts_account(t, &ts, "alice", "a password")
	alice := logged_in(t, &ts, "alice")
	home := s.convs.home.id
	gaming := conv_by_name(&s.convs, "Gaming")
	testing.expect(t, conv_member_add(&s.convs, gaming, alice.account.id))

	// 120 in home, with others in Gaming between them that mustn't show.
	N :: 120
	ids: [N]proto.Msg_Id
	for i in 0 ..< N {
		status: proto.Status
		status, ids[i] = post(t, &ts, alice, home, "a message", u64(1000 + i))
		testing.expect_value(t, status, proto.Status.Ok)
		if i % 7 == 0 {
			post(t, &ts, alice, gaming.id, "elsewhere", u64(5000 + i))
		}
	}
	ts_events(t, &ts, alice)

	// From the newest back, a page at a time, to the first.
	seen := make([dynamic]proto.Msg_Id, context.temp_allocator)
	anchor: proto.Msg_Id
	for pages := 0;; pages += 1 {
		testing.expect(t, pages < 5)
		msgs, more := history(t, &ts, alice, home, anchor)
		for i := len(msgs) - 1; i >= 0; i -= 1 {
			testing.expect_value(t, msgs[i].conv, home)
			append(&seen, msgs[i].id)
		}
		if anchor != 0 {
			testing.expect(t, more & proto.MORE_AFTER != 0)
		}
		if more & proto.MORE_BEFORE == 0 {
			break
		}
		anchor = msgs[0].id
	}
	testing.expect_value(t, len(seen), N)
	for id, i in seen {
		testing.expect_value(t, id, ids[N - 1 - i])
	}

	// And forward from the start.
	msgs, more := history(t, &ts, alice, home, 0, .After)
	testing.expect_value(t, len(msgs), proto.MAX_HISTORY_LIMIT)
	testing.expect_value(t, msgs[0].id, ids[0])
	testing.expect_value(t, more, proto.MORE_AFTER)
	msgs, more = history(t, &ts, alice, home, ids[99], .After)
	testing.expect_value(t, len(msgs), 20)
	testing.expect_value(t, msgs[0].id, ids[100])
	testing.expect_value(t, msgs[19].id, ids[119])
	testing.expect_value(t, more, proto.MORE_BEFORE)

	// Around one: it, the older half and the newer half.
	msgs, more = history(t, &ts, alice, home, ids[60], .Around, 20)
	testing.expect_value(t, len(msgs), 20)
	testing.expect_value(t, msgs[0].id, ids[51])
	testing.expect_value(t, msgs[9].id, ids[60])
	testing.expect_value(t, msgs[19].id, ids[70])
	testing.expect_value(t, more, proto.MORE_BEFORE | proto.MORE_AFTER)
	// Near the start there's less before it, and more after.
	msgs, more = history(t, &ts, alice, home, ids[2], .Around, 20)
	testing.expect_value(t, msgs[0].id, ids[0])
	testing.expect_value(t, msgs[2].id, ids[2])
	testing.expect_value(t, len(msgs), 20)
	testing.expect_value(t, more, proto.MORE_AFTER)
	// At the end, the newest and nothing after.
	msgs, more = history(t, &ts, alice, home, ids[N - 1], .Around, 20)
	testing.expect_value(t, msgs[len(msgs) - 1].id, ids[N - 1])
	testing.expect_value(t, more, proto.MORE_BEFORE)

	// An empty channel is an empty page.
	music := conv_add(&s.convs, "Music", "", {}, 0)
	testing.expect(t, conv_member_add(&s.convs, music, alice.account.id))
	msgs, more = history(t, &ts, alice, music.id)
	testing.expect_value(t, len(msgs), 0)
	testing.expect_value(t, more, 0)
}

// test_jpeg is the start of a JPEG of the given size: enough for its
// header to be read.
test_jpeg :: proc(width, height: int, filler: u8) -> []u8 {
	data := make([dynamic]u8, context.temp_allocator)
	append(&data, 0xFF, 0xD8)
	// An application segment first, as real ones have.
	append(&data, 0xFF, 0xE0, 0x00, 0x04, filler, filler)
	append(&data, 0xFF, 0xC0, 0x00, 0x11, 0x08)
	append(&data, u8(height >> 8), u8(height), u8(width >> 8), u8(width))
	append(&data, 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1)
	for _ in 0 ..< 3000 {
		append(&data, filler)
	}
	append(&data, 0xFF, 0xD9)
	return data[:]
}

@(test)
test_jpeg_size :: proc(t: ^testing.T) {
	w, h, ok := jpeg_size(test_jpeg(1920, 1080, 7))
	testing.expect(t, ok && w == 1920 && h == 1080)
	_, _, ok = jpeg_size([]u8{0x89, 'P', 'N', 'G'})
	testing.expect(t, !ok)
	_, _, ok = jpeg_size(test_jpeg(1920, 1080, 7)[:12])
	testing.expect(t, !ok)
	_, _, ok = jpeg_size(nil)
	testing.expect(t, !ok)
}

// upload sends all of `data` as the connection's upload, the way the
// chunks would come.
upload :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	data: []u8,
	put: proto.Blob_Put,
) -> (
	blob: proto.Blob_Id,
	stored: bool,
) {
	put_buf: [proto.BLOB_PUT_SIZE]u8
	status, answer := ts_ask(t, ts, u, .Blob_Put, proto.encode_blob_put(&put_buf, put))
	testing.expect_value(t, status, proto.Status.Ok)
	got, has, h, ok := proto.decode_blob_put_answer(answer)
	testing.expect(t, ok)
	if has {
		return got, true
	}
	testing.expect_value(t, u.upload.handle, h)
	for i in 0 ..< proto.blob_chunk_count(len(data)) {
		start, end := proto.blob_chunk_range(len(data), i)
		done: bool
		done, stored = upload_chunk(&ts.s, u, i, data[start:end])
		testing.expect_value(t, done, i == proto.blob_chunk_count(len(data)) - 1)
	}
	if !stored {
		return 0, false
	}
	// Asked again, it's there.
	status, answer = ts_ask(t, ts, u, .Blob_Put, proto.encode_blob_put(&put_buf, put))
	testing.expect_value(t, status, proto.Status.Ok)
	got, has, _, ok = proto.decode_blob_put_answer(answer)
	testing.expect(t, ok && has)
	return got, true
}

@(test)
test_pictures :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "yap-test-*", context.temp_allocator)
	defer os.remove_all(dir)
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	testing.expect(t, blob_store_open(&s.blobs, &s.db, dir))
	ts_account(t, &ts, "alice", "a password")
	ts_account(t, &ts, "bob", "a password")
	alice := logged_in(t, &ts, "alice")
	bob := logged_in(t, &ts, "bob")
	gaming := conv_by_name(&s.convs, "Gaming")
	testing.expect(t, conv_member_add(&s.convs, gaming, alice.account.id))

	jpeg := test_jpeg(640, 480, 1)
	put := proto.Blob_Put {
		kind   = .Image,
		size   = len(jpeg),
		hash   = blob_hash(jpeg),
		width  = 640,
		height = 480,
	}
	// Not what was announced: another hash, or another size of picture.
	wrong := put
	wrong.hash[0] ~= 1
	_, stored := upload(t, &ts, alice, jpeg, wrong)
	testing.expect(t, !stored)
	testing.expect(t, !alice.upload.active)
	wrong = put
	wrong.width = 641
	_, stored = upload(t, &ts, alice, jpeg, wrong)
	testing.expect(t, !stored)
	// Not a picture at all, too big, or of a kind not uploaded.
	put_buf: [proto.BLOB_PUT_SIZE]u8
	bad := put
	bad.size = proto.MAX_IMAGE_SIZE + 1
	status, _ := ts_ask(t, &ts, alice, .Blob_Put, proto.encode_blob_put(&put_buf, bad))
	testing.expect_value(t, status, proto.Status.Too_Large)
	bad = put
	bad.kind = .Emoji_Sheet
	status, _ = ts_ask(t, &ts, alice, .Blob_Put, proto.encode_blob_put(&put_buf, bad))
	testing.expect_value(t, status, proto.Status.Invalid)

	// What it said it is: kept, once.
	blob, ok := upload(t, &ts, alice, jpeg, put)
	testing.expect(t, ok)
	again, _ := upload(t, &ts, bob, jpeg, put)
	testing.expect_value(t, again, blob)

	// Posted in Gaming, where bob isn't.
	post_buf: [proto.MSG_POST_MAX_SIZE]u8
	body := proto.encode_msg_post(
		post_buf[:],
		{conv = gaming.id, nonce = 9, kind = .Image, blob = blob},
	)
	status, _ = ts_ask(t, &ts, alice, .Msg_Post, body)
	testing.expect_value(t, status, proto.Status.Ok)
	msgs, _ := history(t, &ts, alice, gaming.id)
	testing.expect_value(t, len(msgs), 1)
	testing.expect_value(t, msgs[0].kind, proto.Msg_Kind.Image)
	testing.expect_value(
		t,
		msgs[0].image,
		proto.Msg_Image{blob = blob, width = 640, height = 480, size = u32(len(jpeg))},
	)
	body = proto.encode_msg_post(
		post_buf[:],
		{conv = gaming.id, nonce = 10, kind = .Image, blob = 999},
	)
	status, _ = ts_ask(t, &ts, alice, .Msg_Post, body)
	testing.expect_value(t, status, proto.Status.Not_Found)

	// Fetched by who may read it, and nobody else.
	id_buf: [proto.BLOB_GET_SIZE]u8
	answer: []u8
	status, answer = ts_ask(t, &ts, alice, .Blob_Get, proto.encode_blob_id(&id_buf, blob))
	testing.expect_value(t, status, proto.Status.Ok)
	size, handle, get_ok := proto.decode_blob_get_answer(answer)
	testing.expect(t, get_ok)
	testing.expect_value(t, size, len(jpeg))
	testing.expect_value(t, alice.download.handle, handle)
	testing.expect_value(t, string(alice.download.data), string(jpeg))
	status, _ = ts_ask(t, &ts, bob, .Blob_Get, proto.encode_blob_id(&id_buf, blob))
	testing.expect_value(t, status, proto.Status.Not_Found)
	testing.expect(t, conv_member_add(&s.convs, gaming, bob.account.id))
	status, _ = ts_ask(t, &ts, bob, .Blob_Get, proto.encode_blob_id(&id_buf, blob))
	testing.expect_value(t, status, proto.Status.Ok)
}

@(test)
test_messages_kept :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "yap-test-*", context.temp_allocator)
	defer os.remove_all(dir)
	path, _ := os.join_path({dir, DB_FILE}, context.temp_allocator)

	last: proto.Msg_Id
	{
		ts: Test_Server
		ts_open(t, &ts, path)
		defer ts_close(&ts)
		ts_account(t, &ts, "alice", "a password")
		alice := logged_in(t, &ts, "alice")
		for i in 0 ..< 3 {
			_, last = post(t, &ts, alice, ts.s.convs.home.id, "remember me", u64(i + 1))
		}
		db_commit(&ts.s.db)
	}

	// After a restart: the messages, and which was the last.
	ts: Test_Server
	ts_open(t, &ts, path)
	defer ts_close(&ts)
	testing.expect_value(t, ts.s.convs.home.last_msg, last)
	// The same device as before, which the server knows.
	alice := ts_connect(&ts)
	testing.expect(t, alice.account != nil)
	ts_events(t, &ts, alice)
	msgs, _ := history(t, &ts, alice, ts.s.convs.home.id)
	testing.expect_value(t, len(msgs), 3)
	testing.expect_value(t, msgs[2].id, last)
	testing.expect_value(t, msgs[2].text, "remember me")
	// A repeat of a post from before the restart is still known.
	status, again := post(t, &ts, alice, ts.s.convs.home.id, "remember me", 3)
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, again, last)
}

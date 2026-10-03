package server

import "core:fmt"
import "core:os"
import "core:testing"

import "common:proto"
import "sqlite"

// Tests of purging (retention.odin), on the Test_Server of auth_test.odin.

// age sets when messages were posted: `days` ago, for ids from `first`
// to `last`.
@(private = "file")
age_messages :: proc(t: ^testing.T, ts: ^Test_Server, first, last: proto.Msg_Id, days: int) {
	at := unix_ms() - i64(days) * DAY_MS
	testing.expect(t, db_exec(&ts.s.db, fmt.tprintf("UPDATE messages SET time = %d WHERE id BETWEEN %d AND %d", at, first, last)))
}

@(private = "file")
age_blobs :: proc(t: ^testing.T, ts: ^Test_Server, hours: int) {
	at := unix_ms() - i64(hours) * 60 * 60 * 1000
	testing.expect(t, db_exec(&ts.s.db, fmt.tprintf("UPDATE blobs SET created = %d", at)))
}

@(private = "file")
count_of :: proc(t: ^testing.T, ts: ^Test_Server, sql: string) -> i64 {
	n, rc := db_pragma_int(&ts.s.db, sql)
	testing.expect_value(t, rc, sqlite.OK)
	return n
}

@(private = "file")
exists :: proc(ts: ^Test_Server, id: proto.Msg_Id) -> bool {
	_, found := msg_by_id(&ts.s, id)
	return found
}

@(private = "file")
reply :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn, conv: proto.Conv_Id, root: proto.Msg_Id, text: string, nonce: u64) -> proto.Msg_Id {
	buf := make([]u8, proto.MSG_POST_MAX_SIZE, context.temp_allocator)
	body := proto.encode_msg_post(buf, {conv = conv, nonce = nonce, kind = .Text, text = text, thread_root = root})
	status, answer := ts_ask(t, ts, u, .Msg_Post, body)
	testing.expect_value(t, status, proto.Status.Ok)
	id, _, _ := proto.decode_msg_posted(answer)
	return id
}

@(private = "file")
picture :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn, conv: proto.Conv_Id, blob: Blob_Id, nonce: u64) -> proto.Msg_Id {
	buf := make([]u8, proto.MSG_POST_MAX_SIZE, context.temp_allocator)
	body := proto.encode_msg_post(buf, {conv = conv, nonce = nonce, kind = .Image, blob = blob})
	status, answer := ts_ask(t, ts, u, .Msg_Post, body)
	testing.expect_value(t, status, proto.Status.Ok)
	id, _, _ := proto.decode_msg_posted(answer)
	return id
}

@(private = "file")
pin :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn, id: proto.Msg_Id, on := true) {
	buf: [proto.MSG_PIN_SIZE]u8
	status, _ := ts_ask(t, ts, u, .Msg_Pin, proto.encode_msg_pin(&buf, id, on))
	testing.expect_value(t, status, proto.Status.Ok)
}

// purge asks for a purge and lets it run to the end; its answer.
@(private = "file")
purge :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	p: proto.Purge,
) -> (
	status: proto.Status,
	messages, blobs: int,
) {
	ts.requests += 1
	id := ts.requests
	buf: [proto.PURGE_SIZE]u8
	rpc_handle(&ts.s, u, proto.encode_request(id, .Purge, proto.encode_purge(&buf, p)))
	retention_drain(&ts.s.retention, &ts.s.blobs, &ts.s)
	ts_pump(t, ts, u)
	r, answered := ts.clients[u].responses[id]
	if !answered {
		testing.fail_now(t, "no answer to a purge")
	}
	if r.status == .Ok {
		ok: bool
		messages, blobs, ok = proto.decode_purge_answer(r.body)
		testing.expect(t, ok)
	}
	return r.status, messages, blobs
}

// purged is the Msgs_Purged a connection was told of last.
@(private = "file")
purged :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn) -> (p: proto.Msgs_Purged, told: bool) {
	for e in ts_events(t, ts, u) {
		if e.op == .Msgs_Purged {
			ok: bool
			p, ok = proto.decode_msgs_purged(e.body)
			testing.expect(t, ok)
			told = true
		}
	}
	return
}

@(test)
test_msg_boundary :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	db := &ts.s.db
	testing.expect_value(t, msg_boundary(db, unix_ms()), proto.Msg_Id(1))

	home := ts.s.convs.home.id
	ts_account(t, &ts, "alice", "a password")
	alice := logged_in(t, &ts, "alice")
	ids: [10]proto.Msg_Id
	for &id, i in ids {
		_, id = post(t, &ts, alice, home, "words", u64(i + 1))
	}
	// 10 days old to 1 day old, a day apart.
	for id, i in ids {
		age_messages(t, &ts, id, id, 10 - i)
	}
	now := unix_ms()
	testing.expect_value(t, msg_boundary(db, now - 100 * DAY_MS), ids[0])
	testing.expect_value(t, msg_boundary(db, now - 10 * DAY_MS - 1), ids[0])
	testing.expect_value(t, msg_boundary(db, now - 10 * DAY_MS + 1), ids[1])
	testing.expect_value(t, msg_boundary(db, now - 5 * DAY_MS - 1000), ids[5])
	testing.expect_value(t, msg_boundary(db, now), ids[9] + 1)
	// With gaps where messages were.
	testing.expect(t, db_exec(db, fmt.tprintf("DELETE FROM messages WHERE id IN (%d, %d, %d)", ids[4], ids[5], ids[6])))
	// Anywhere in the gap will do: what's below is the same.
	for before in ([]i64{now - 5 * DAY_MS - 1000, now - 7 * DAY_MS + 1000}) {
		b := msg_boundary(db, before)
		testing.expectf(t, b > ids[3] && b <= ids[7], "%d isn't in the gap", b)
	}
	testing.expect_value(t, msg_boundary(db, now - 7 * DAY_MS - 1000), ids[3])
}

@(test)
test_purge_messages :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "yap-test-*", context.temp_allocator)
	defer os.remove_all(dir)
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	testing.expect(t, blob_store_open(&s.blobs, &s.db, dir))
	home := s.convs.home.id
	gaming := conv_by_name(&s.convs, "Gaming")
	ts_account(t, &ts, "admin", "a password", {.Owner})
	ts_account(t, &ts, "alice", "a password")
	ts_account(t, &ts, "bob", "a password")
	admin := logged_in(t, &ts, "admin")
	alice := logged_in(t, &ts, "alice")
	bob := logged_in(t, &ts, "bob")
	testing.expect(t, conv_member_add(&s.convs, gaming, alice.account.id))

	nonce: u64
	say :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn, conv: proto.Conv_Id, nonce: ^u64, text := "hello <@3>") -> proto.Msg_Id {
		nonce^ += 1
		_, id := post(t, ts, u, conv, text, nonce^)
		return id
	}
	old := say(t, &ts, alice, home, &nonce)
	pinned := say(t, &ts, alice, home, &nonce)
	root := say(t, &ts, alice, home, &nonce) // a reply that's kept keeps it
	gone_root := say(t, &ts, alice, home, &nonce) // its replies all go
	old_reply := reply(t, &ts, bob, home, root, "an old reply", 100)
	gone_reply := reply(t, &ts, bob, home, gone_root, "another", 101)
	elsewhere := say(t, &ts, alice, gaming.id, &nonce)
	age_messages(t, &ts, old, elsewhere, 30)
	new_reply := reply(t, &ts, bob, home, root, "a new reply", 102)
	recent := say(t, &ts, alice, home, &nonce)
	pin(t, &ts, admin, pinned)
	react_buf: [proto.MSG_REACT_MAX_SIZE]u8
	react_status, _ := ts_ask(t, &ts, bob, .Msg_React, proto.encode_msg_react(&react_buf, old, "👍", true))
	testing.expect_value(t, react_status, proto.Status.Ok)
	testing.expect(t, count_of(t, &ts, "SELECT count(*) FROM mentions") > 0)
	ts_events(t, &ts, bob)

	// Not for everyone.
	status, _, _ := purge(t, &ts, bob, {conv = home, before = proto.Unix_Ms(unix_ms() - 7 * DAY_MS)})
	testing.expect_value(t, status, proto.Status.Denied)
	status, _, _ = purge(t, &ts, admin, {conv = 999, before = proto.Unix_Ms(unix_ms())})
	testing.expect_value(t, status, proto.Status.Not_Found)

	// What's older than a week in the home channel.
	messages: int
	status, messages, _ = purge(t, &ts, admin, {conv = home, before = proto.Unix_Ms(unix_ms() - 7 * DAY_MS)})
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, messages, 4) // old, gone_root, old_reply, gone_reply
	for id in ([]proto.Msg_Id{old, gone_root, old_reply, gone_reply}) {
		testing.expectf(t, !exists(&ts, id), "message %d is still there", id)
	}
	for id in ([]proto.Msg_Id{pinned, root, new_reply, recent, elsewhere}) {
		testing.expectf(t, exists(&ts, id), "message %d went", id)
	}
	// With what hung off them, and nothing left in their place.
	testing.expect_value(t, count_of(t, &ts, fmt.tprintf("SELECT count(*) FROM reactions WHERE message = %d", old)), 0)
	testing.expect_value(t, count_of(t, &ts, fmt.tprintf("SELECT count(*) FROM mentions WHERE message = %d", old)), 0)
	// The root that stays counts the reply it has left.
	m, _ := msg_by_id(s, root)
	testing.expect_value(t, m.reply_count, 1)
	testing.expect(t, .Has_Thread in m.flags)

	// Bob is told; and it can't be fetched.
	p, told := purged(t, &ts, bob)
	testing.expect(t, told)
	testing.expect_value(t, p, proto.Msgs_Purged{conv = home, before = new_reply, what = .Messages})
	msgs, _ := history_of(t, &ts, bob, home)
	for msg in msgs {
		testing.expect(t, msg.id != old && msg.id != old_reply)
	}

	// The reply goes; then the root has nothing keeping it.
	age_messages(t, &ts, new_reply, new_reply, 30)
	status, messages, _ = purge(t, &ts, admin, {before = proto.Unix_Ms(unix_ms() - 7 * DAY_MS)})
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, messages, 3) // root, new_reply, elsewhere
	testing.expect(t, !exists(&ts, root) && !exists(&ts, elsewhere))
	testing.expect(t, exists(&ts, pinned) && exists(&ts, recent))
	// Unpinned, it goes too.
	pin(t, &ts, admin, pinned, false)
	status, messages, _ = purge(t, &ts, admin, {before = proto.Unix_Ms(unix_ms() - 7 * DAY_MS)})
	testing.expect_value(t, messages, 1)
	testing.expect(t, !exists(&ts, pinned))
}

@(private = "file")
history_of :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn, conv: proto.Conv_Id) -> (msgs: []proto.Message, more: u8) {
	status, body := ts_ask(t, ts, u, .Msg_History, history_body(conv))
	testing.expect_value(t, status, proto.Status.Ok)
	buf := make([]proto.Message, proto.MAX_HISTORY_LIMIT, context.temp_allocator)
	ok: bool
	more, msgs, ok = proto.decode_history_page(body, buf)
	testing.expect(t, ok)
	return
}

@(test)
test_purge_pictures :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "yap-test-*", context.temp_allocator)
	defer os.remove_all(dir)
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	testing.expect(t, blob_store_open(&s.blobs, &s.db, dir))
	home := s.convs.home.id
	ts_account(t, &ts, "admin", "a password", {.Owner})
	ts_account(t, &ts, "alice", "a password")
	admin := logged_in(t, &ts, "admin")
	alice := logged_in(t, &ts, "alice")

	shared, _ := blob_put(&s.blobs, .Image, test_jpeg(32, 32, 1), 32, 32)
	alone, _ := blob_put(&s.blobs, .Image, test_jpeg(32, 32, 2), 32, 32)
	kept, _ := blob_put(&s.blobs, .Image, test_jpeg(32, 32, 3), 32, 32)
	unused, _ := blob_put(&s.blobs, .Image, test_jpeg(32, 32, 4), 32, 32)
	avatar, _ := blob_put(&s.blobs, .Avatar, test_jpeg(32, 32, 5), 32, 32)
	testing.expect(t, account_set_avatar(&s.accounts, alice.account, avatar))
	first := picture(t, &ts, alice, home, shared, 1)
	second := picture(t, &ts, alice, home, alone, 2)
	pinned := picture(t, &ts, alice, home, kept, 3)
	pin(t, &ts, admin, pinned)
	age_messages(t, &ts, first, pinned, 30)
	again := picture(t, &ts, alice, home, shared, 4) // the same picture, new
	file_of :: proc(s: ^Server, id: Blob_Id) -> string {
		b, _ := blob_get(&s.blobs, id)
		return blob_path(&s.blobs, b.hash)
	}
	shared_file, alone_file, unused_file := file_of(s, shared), file_of(s, alone), file_of(s, unused)
	ts_events(t, &ts, alice)

	// Uploaded this past hour: nothing is collected yet, used or not.
	status, messages, blobs := purge(t, &ts, admin, {before = proto.Unix_Ms(unix_ms() - 7 * DAY_MS), what = .Images})
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, messages, 2)
	testing.expect_value(t, blobs, 0)
	p, told := purged(t, &ts, alice)
	testing.expect(t, told)
	testing.expect_value(t, p.what, proto.Purge_What.Images)
	// The messages stay, without their pictures.
	m, _ := msg_by_id(s, second)
	testing.expect_value(t, m.kind, proto.Msg_Kind.Image)
	testing.expect_value(t, m.image.blob, Blob_Id(0))
	m, _ = msg_by_id(s, pinned)
	testing.expect_value(t, m.image.blob, kept)
	id_buf: [proto.BLOB_GET_SIZE]u8
	status, _ = ts_ask(t, &ts, alice, .Blob_Get, proto.encode_blob_id(&id_buf, alone))
	testing.expect_value(t, status, proto.Status.Not_Found)

	// An hour on: what nothing uses goes, file and all; the picture the
	// new message shows, the pinned one's, and a profile's stay.
	age_blobs(t, &ts, 2)
	status, _, blobs = purge(t, &ts, admin, {before = proto.Unix_Ms(unix_ms() - 7 * DAY_MS), what = .Images})
	testing.expect_value(t, blobs, 2) // alone, unused
	_, found := blob_get(&s.blobs, alone)
	testing.expect(t, !found)
	testing.expect(t, !os.exists(alone_file) && !os.exists(unused_file))
	testing.expect(t, os.exists(shared_file))
	for id in ([]Blob_Id{shared, kept, avatar}) {
		_, found = blob_get(&s.blobs, id)
		testing.expectf(t, found, "blob %d went", id)
	}

	// Once the new message has gone too, its picture does.
	age_messages(t, &ts, again, again, 30)
	status, messages, blobs = purge(t, &ts, admin, {before = proto.Unix_Ms(unix_ms() - 7 * DAY_MS)})
	testing.expect_value(t, messages, 3) // first, second, again
	testing.expect_value(t, blobs, 1)
	testing.expect(t, !os.exists(shared_file))
}

@(test)
test_retention_config :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "yap-test-*", context.temp_allocator)
	defer os.remove_all(dir)
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	testing.expect(t, blob_store_open(&s.blobs, &s.db, dir))
	home := s.convs.home.id
	ts_account(t, &ts, "alice", "a password")
	alice := logged_in(t, &ts, "alice")

	// Five pictures of about 3 KB each, a day apart, and a text from
	// each day; the oldest is 50 days old.
	pics, texts: [5]proto.Msg_Id
	blobs: [5]Blob_Id
	for i in 0 ..< 5 {
		jpeg := test_jpeg(64, 64, u8(i + 1))
		blobs[i], _ = blob_put(&s.blobs, .Image, jpeg, 64, 64)
		pics[i] = picture(t, &ts, alice, home, blobs[i], u64(2 * i + 1))
		_, texts[i] = post(t, &ts, alice, home, "a day's words", u64(2 * i + 2))
		age_messages(t, &ts, pics[i], texts[i], 50 - 10 * i)
	}
	age_blobs(t, &ts, 2)
	r := &s.retention

	// Messages a month old go, pictures over three weeks old.
	r.config = {message_days = 31, image_days = 21}
	retention_schedule(r, &s.db, unix_ms())
	retention_drain(r, &s.blobs, s)
	testing.expect(t, !exists(&ts, pics[0]) && !exists(&ts, texts[1]))
	testing.expect(t, exists(&ts, pics[2]) && exists(&ts, texts[2]))
	m, _ := msg_by_id(s, pics[2])
	testing.expect_value(t, m.image.blob, Blob_Id(0))
	m, _ = msg_by_id(s, pics[3])
	testing.expect_value(t, m.image.blob, blobs[3])
	for b, i in blobs {
		_, found := blob_get(&s.blobs, b)
		testing.expect_value(t, found, i >= 3)
	}

	// The pictures may take no more than one of them: the older goes.
	sizes := count_of(t, &ts, "SELECT sum(size) FROM blobs WHERE kind = 1")
	testing.expect(t, sizes > 0)
	r.config = {blob_megabytes = 1}
	retention_schedule(r, &s.db, unix_ms())
	retention_drain(r, &s.blobs, s)
	m, _ = msg_by_id(s, pics[3])
	testing.expect_value(t, m.image.blob, blobs[3]) // within a megabyte
	r.config.blob_megabytes = 0
	// Not settable below a megabyte from the config, but the step
	// works the same with a smaller aim.
	append(&r.steps, Purge_Step{kind = .Stored, below = pics[4] + 1, bytes = 1})
	append(&r.steps, Purge_Step{kind = .Collect})
	retention_drain(r, &s.blobs, s)
	m, _ = msg_by_id(s, pics[3])
	testing.expect_value(t, m.image.blob, Blob_Id(0))
	m, _ = msg_by_id(s, pics[4])
	testing.expect_value(t, m.image.blob, blobs[4])
	_, found := blob_get(&s.blobs, blobs[3])
	testing.expect(t, !found)

	// No limits: nothing goes.
	r.config = {}
	before := count_of(t, &ts, "SELECT count(*) FROM messages")
	retention_schedule(r, &s.db, unix_ms())
	retention_drain(r, &s.blobs, s)
	testing.expect_value(t, count_of(t, &ts, "SELECT count(*) FROM messages"), before)
}

@(test)
test_purge_resumes :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "yap-test-*", context.temp_allocator)
	defer os.remove_all(dir)
	path, _ := os.join_path({dir, DB_FILE}, context.temp_allocator)
	blobs_dir, _ := os.join_path({dir, BLOBS_DIR}, context.temp_allocator)

	COUNT :: 3 * PURGE_CHUNK + 5
	last: proto.Msg_Id
	{
		ts: Test_Server
		ts_open(t, &ts, path)
		defer ts_close(&ts)
		s := &ts.s
		testing.expect(t, blob_store_open(&s.blobs, &s.db, blobs_dir))
		ts_account(t, &ts, "admin", "a password", {.Owner})
		admin := logged_in(t, &ts, "admin")
		for i in 0 ..< COUNT {
			_, last = post(t, &ts, admin, s.convs.home.id, "old words", u64(i + 1))
		}
		age_messages(t, &ts, 1, last, 30)
		// Asked for, and part done when the server stops.
		testing.expect(t, retention_ask(&s.retention, &s.db, {before = proto.Unix_Ms(unix_ms())}, unix_ms()))
		testing.expect(t, !retention_ask(&s.retention, &s.db, {before = proto.Unix_Ms(unix_ms())}, unix_ms()))
		_, finished := retention_chunk(&s.retention, &s.blobs, unix_ms())
		testing.expect(t, !finished)
		db_commit(&s.db)
		testing.expect_value(t, count_of(t, &ts, "SELECT count(*) FROM messages"), COUNT - PURGE_CHUNK)
	}

	// Started again, it carries on.
	ts: Test_Server
	ts_open(t, &ts, path)
	defer ts_close(&ts)
	s := &ts.s
	testing.expect(t, blob_store_open(&s.blobs, &s.db, blobs_dir))
	retention_open(&s.retention, &s.db, {})
	testing.expect(t, s.retention.asked)
	messages, _ := retention_drain(&s.retention, &s.blobs, s)
	testing.expect_value(t, messages, COUNT - PURGE_CHUNK)
	testing.expect_value(t, count_of(t, &ts, "SELECT count(*) FROM messages"), 0)
	testing.expect(t, !s.retention.asked)
	// And is done with: not again the next time.
	retention_close(&s.retention)
	retention_open(&s.retention, &s.db, {})
	testing.expect(t, !s.retention.asked)
	testing.expect_value(t, len(s.retention.steps), 0)
}

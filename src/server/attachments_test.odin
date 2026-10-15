package server

import "core:os"
import "core:slice"
import "core:testing"
import "core:time"

import "common:proto"

// Tests of attachments, on the Test_Server of auth_test.odin.

// The messages the server sent to each connection (attach_test_sent),
// oldest first.
@(thread_local, private = "file")
sent: map[^Conn][dynamic][]u8

@(private = "file")
record_sent :: proc(u: ^Conn, msg: []u8) {
	if u not_in sent {
		sent[u] = make([dynamic][]u8, context.temp_allocator)
	}
	append(&sent[u], temp_copy(msg))
}

// sent_reset forgets what was sent, so that the next test on this thread
// starts clean. The lists use this test's temp allocator and the map uses
// the regular allocator.
@(private = "file")
sent_reset :: proc() {
	delete(sent)
	sent = nil
}

// taken returns what was sent to `u` since it was last called.
@(private = "file")
taken :: proc(u: ^Conn) -> [][]u8 {
	list := sent[u] or_else nil
	out := slice.clone(list[:], context.temp_allocator)
	if u in sent {
		clear(&sent[u])
	}
	return out
}

@(private = "file")
test_file :: proc(size: int, seed: u8) -> []u8 {
	data := make([]u8, size, context.temp_allocator)
	for &b, i in data {
		b = u8(i * 31) ~ u8(i >> 10) ~ seed
	}
	return data
}

// put announces an upload and returns its id if the server accepts it.
@(private = "file")
put :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	size: int,
	name: string,
) -> (
	status: proto.Status,
	id: u64,
) {
	buf: [proto.ATTACH_PUT_MAX_SIZE]u8
	answer: []u8
	status, answer = ts_ask(
		t,
		ts,
		u,
		.Attach_Put,
		proto.encode_attach_put(buf[:], {size = u64(size), name = name}),
	)
	if status == .Ok {
		ok: bool
		id, ok = proto.decode_attach_id(answer)
		testing.expect(t, ok)
	}
	return
}

// send_file uploads `data` under `id`, sending the chunks of each window
// (proto.FILE_WINDOW) in reverse order with some of them repeated. It returns
// the blob the upload was stored as, if it was stored.
@(private = "file")
send_file :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	id: u64,
	data: []u8,
) -> proto.Blob_Id {
	chunks := i64(proto.file_chunk_count(u64(len(data))))
	out: [proto.MAX_PAYLOAD_SIZE]u8
	// Send the chunks backwards, and every third one twice, to test
	// out-of-order and duplicate chunks. Senders stay within FILE_WINDOW of
	// the first missing chunk, so each window is sent backwards in turn.
	for window := i64(0); window < chunks; window += proto.FILE_WINDOW {
		for i := min(window + proto.FILE_WINDOW, chunks) - 1; i >= window; i -= 1 {
			from, to := proto.file_chunk_range(u64(len(data)), u32(i))
			msg := proto.encode_transfer_chunk(out[:], .Upload_Chunk, id, u32(i), data[from:to])
			handle_upload_chunk(&ts.s, u, msg)
			if i % 3 == 0 {
				handle_upload_chunk(&ts.s, u, msg)
			}
		}
	}
	// The last ack reports the upload as complete.
	acks := taken(u)
	testing.expect(t, len(acks) > 0)
	if len(acks) > 0 {
		ack, _, _, ok := proto.decode_transfer_ack(acks[len(acks) - 1])
		testing.expect(t, ok && ack.complete && ack.id == id)
	}
	up := ts.s.attach.uploads[id] or_else nil
	return up.blob if up != nil else 0
}

@(private = "file")
post_files :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	conv: proto.Conv_Id,
	text: string,
	nonce: u64,
	uploads: ..u64,
) -> (
	status: proto.Status,
	id: proto.Msg_Id,
) {
	p := proto.Msg_Post {
		conv             = conv,
		nonce            = nonce,
		kind             = .Text,
		text             = text,
		attachment_count = len(uploads),
	}
	copy(p.uploads[:], uploads)
	buf: [proto.MSG_POST_MAX_SIZE]u8
	answer: []u8
	status, answer = ts_ask(t, ts, u, .Msg_Post, proto.encode_msg_post(buf[:], p))
	if status == .Ok {
		id, _, _ = proto.decode_msg_posted(answer)
	}
	return
}

// fetch downloads a blob as `u`, acknowledging chunks like a client
// would, and returns the downloaded data.
@(private = "file")
fetch :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	blob: proto.Blob_Id,
) -> (
	status: proto.Status,
	data: []u8,
) {
	id_buf: [8]u8
	answer: []u8
	status, answer = ts_ask(t, ts, u, .Attach_Get, proto.encode_attach_id(&id_buf, u64(blob)))
	if status != .Ok {
		return
	}
	size, download, ok := proto.decode_attach_get_answer(answer)
	testing.expect(t, ok)
	data = make([]u8, size, context.temp_allocator)
	r: proto.Transfer_Receiver
	proto.transfer_receiver_init(&r, size)
	out: [proto.MAX_PAYLOAD_SIZE]u8
	for _ in 0 ..< 10_000 {
		time.sleep(time.Millisecond)
		attachments_sync(&ts.s)
		for msg in taken(u) {
			// Acks for stored uploads are sent again for a while
			// (attachments_sync), which belong to the client's uploads and
			// are skipped here.
			kind, _ := proto.message_kind(msg)
			if kind == .Upload_Ack {
				continue
			}
			testing.expect_value(t, kind, proto.Message_Kind.Download_Chunk)
			got_id, index, chunk := proto.decode_transfer_chunk(msg)
			testing.expect_value(t, got_id, download)
			if proto.transfer_wants(&r, index, len(chunk)) {
				from, _ := proto.file_chunk_range(size, index)
				copy(data[from:], chunk)
				proto.transfer_got(&r, index, len(chunk))
			}
		}
		handle_download_ack(
			&ts.s,
			u,
			proto.transfer_encode_ack(&r, out[:], .Download_Ack, download, 0, time.tick_now()),
		)
		if proto.transfer_complete(&r) {
			testing.expect(t, download not_in ts.s.attach.downloads)
			proto.transfer_receiver_destroy(&r)
			return
		}
	}
	proto.transfer_receiver_destroy(&r)
	testing.fail_now(t, "the download didn't finish")
}

@(test)
test_attachments :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "yap-test-*", context.temp_allocator)
	defer remove_tree(dir)
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	testing.expect(t, blob_store_open(&s.blobs, &s.db, dir))
	attachments_open(s, {max_megabytes = 4, rate_kb = 1024 * 1024})
	defer attachments_close(s)
	attach_test_sent = record_sent
	defer attach_test_sent = nil
	defer sent_reset()

	ts_account(t, &ts, "alice", "a password")
	ts_account(t, &ts, "bob", "a password")
	alice := logged_in(t, &ts, "alice")
	bob := logged_in(t, &ts, "bob")
	gaming := conv_by_name(&s.convs, "Gaming")
	testing.expect(t, conv_member_add(&s.convs, gaming, alice.account.id))

	// Uploads are rejected if they are empty, have no name or are too big.
	status, _ := put(t, &ts, alice, 0, "empty.txt")
	testing.expect_value(t, status, proto.Status.Invalid)
	status, _ = put(t, &ts, alice, 10, "")
	testing.expect_value(t, status, proto.Status.Invalid)
	status, _ = put(t, &ts, alice, 4 * 1024 * 1024 + 1, "big.iso")
	testing.expect_value(t, status, proto.Status.Too_Large)

	// A file of a few thousand chunks, sent in any order, is stored intact.
	report := test_file(3000 * proto.FILE_CHUNK_DATA + 77, 1)
	upload: u64
	status, upload = put(t, &ts, alice, len(report), "../reports/report 2026.pdf")
	testing.expect_value(t, status, proto.Status.Ok)
	// A chunk further ahead than a sender may go is dropped (it would make
	// the server read back and hash everything before it in one go).
	{
		out: [proto.MAX_PAYLOAD_SIZE]u8
		from, to := proto.file_chunk_range(u64(len(report)), proto.FILE_WINDOW)
		msg := proto.encode_transfer_chunk(
			out[:],
			.Upload_Chunk,
			upload,
			proto.FILE_WINDOW,
			report[from:to],
		)
		handle_upload_chunk(&ts.s, alice, msg)
		testing.expect_value(t, s.attach.uploads[upload].recv.received, 0)
	}
	blob := send_file(t, &ts, alice, upload, report)
	testing.expect(t, blob != 0)
	kept, read_ok := blob_read(&s.blobs, blob, context.temp_allocator)
	testing.expect(t, read_ok)
	testing.expect(t, string(kept) == string(report))
	b, _ := blob_get(&s.blobs, blob)
	testing.expect_value(t, b.kind, Blob_Kind.File)

	// The same content uploaded by bob is only stored once.
	bobs: u64
	_, bobs = put(t, &ts, bob, len(report), "copy.pdf")
	testing.expect_value(t, send_file(t, &ts, bob, bobs, report), blob)

	// A small file is uploaded too, and both are posted together in Gaming.
	tool := test_file(5000, 2)
	tool_upload: u64
	_, tool_upload = put(t, &ts, alice, len(tool), "setup.exe")
	tool_blob := send_file(t, &ts, alice, tool_upload, tool)
	ts_events(t, &ts, alice)
	id: proto.Msg_Id
	status, id = post_files(t, &ts, alice, gaming.id, "the files", 1, upload, tool_upload)
	testing.expect_value(t, status, proto.Status.Ok)
	news: [dynamic]proto.Message
	for e in ts_events(t, &ts, alice) {
		if e.op == .Msg_New {
			m, ok := proto.decode_message(e.body)
			testing.expect(t, ok)
			append(&news, m)
		}
	}
	defer delete(news)
	testing.expect_value(t, len(news), 1)
	if len(news) == 1 {
		m := news[0]
		testing.expect(t, .Has_Attachments in m.flags)
		testing.expect_value(t, m.attachment_count, 2)
		testing.expect_value(
			t,
			m.attachments[0],
			proto.Attachment{blob, u64(len(report)), "report 2026.pdf"},
		)
		testing.expect_value(
			t,
			m.attachments[1],
			proto.Attachment{tool_blob, u64(len(tool)), "setup.exe"},
		)
	}
	// The message is read back exactly as it was posted.
	m, found := msg_by_id(s, id)
	testing.expect(t, found)
	testing.expect_value(t, m.attachment_count, 2)
	testing.expect_value(t, m.attachments[1].name, "setup.exe")
	// Posting again after a reconnect returns the same message.
	again: proto.Msg_Id
	_, again = post_files(t, &ts, alice, gaming.id, "the files", 1, upload, tool_upload)
	testing.expect_value(t, again, id)

	// A post may have only files and no text, but it can't use bob's
	// upload or the same upload twice.
	status, _ = post_files(t, &ts, alice, gaming.id, "", 2, tool_upload)
	testing.expect_value(t, status, proto.Status.Ok)
	status, _ = post_files(t, &ts, alice, gaming.id, "", 3, bobs)
	testing.expect_value(t, status, proto.Status.Not_Found)
	status, _ = post_files(t, &ts, alice, gaming.id, "", 4, upload, upload)
	testing.expect_value(t, status, proto.Status.Invalid)

	// A file can only be fetched by accounts that may read the message.
	// Bob can't until he joins Gaming.
	status, _ = fetch(t, &ts, bob, blob)
	testing.expect_value(t, status, proto.Status.Not_Found)
	got: []u8
	status, got = fetch(t, &ts, alice, blob)
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect(t, string(got) == string(report))
	testing.expect(t, conv_member_add(&s.convs, gaming, bob.account.id))
	status, got = fetch(t, &ts, bob, tool_blob)
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect(t, string(got) == string(tool))
	// Nor can anyone while the channel is archived.
	gaming.flags += {.Archived}
	status, _ = fetch(t, &ts, bob, tool_blob)
	testing.expect_value(t, status, proto.Status.Not_Found)
	gaming.flags -= {.Archived}

	// After the message is deleted it has no files any more and nobody
	// can fetch them. An hour later the report is removed, while the tool
	// (which is also in the other message) stays.
	id_buf: [proto.MSG_ID_SIZE]u8
	status, _ = ts_ask(t, &ts, alice, .Msg_Delete, proto.encode_msg_id(&id_buf, id))
	testing.expect_value(t, status, proto.Status.Ok)
	m, _ = msg_by_id(s, id)
	testing.expect(t, .Has_Attachments not_in m.flags)
	testing.expect_value(t, m.attachment_count, 0)
	status, _ = fetch(t, &ts, alice, blob)
	testing.expect_value(t, status, proto.Status.Not_Found)
	r: Retention
	append(&r.steps, Purge_Step{kind = .Collect})
	for len(r.steps) > 0 {
		retention_chunk(&r, &s.blobs, unix_ms() + 2 * 3600 * 1000)
	}
	retention_close(&r)
	_, found = blob_get(&s.blobs, blob)
	testing.expect(t, !found)
	_, found = blob_get(&s.blobs, tool_blob)
	testing.expect(t, found)

	// A server that doesn't accept uploads denies them.
	s.attach.max_size = 0
	status, _ = put(t, &ts, alice, 10, "a.txt")
	testing.expect_value(t, status, proto.Status.Denied)
}

// An unfinished upload is removed with its connection, including its
// file. A finished upload stays so it can still be posted.
@(test)
test_attachments_conn_gone :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "yap-test-*", context.temp_allocator)
	defer remove_tree(dir)
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	testing.expect(t, blob_store_open(&s.blobs, &s.db, dir))
	attachments_open(s, {max_megabytes = 1, rate_kb = 1024})
	defer attachments_close(s)
	attach_test_sent = record_sent
	defer attach_test_sent = nil
	defer sent_reset()

	ts_account(t, &ts, "alice", "a password")
	alice := logged_in(t, &ts, "alice")
	data := test_file(10_000, 3)
	_, done := put(t, &ts, alice, len(data), "done.zip")
	testing.expect(t, send_file(t, &ts, alice, done, data) != 0)
	_, half := put(t, &ts, alice, len(data), "half.zip")
	out: [proto.MAX_PAYLOAD_SIZE]u8
	handle_upload_chunk(
		s,
		alice,
		proto.encode_transfer_chunk(out[:], .Upload_Chunk, half, 0, data[:proto.FILE_CHUNK_DATA]),
	)
	part := s.attach.uploads[half].part
	testing.expect(t, os.exists(part))

	// More than MAX_ATTACH_TRANSFERS at the same time are refused.
	for _ in 1 ..< proto.MAX_ATTACH_TRANSFERS {
		status, _ := put(t, &ts, alice, 10, "more.zip")
		testing.expect_value(t, status, proto.Status.Ok)
	}
	status, _ := put(t, &ts, alice, 10, "one too many.zip")
	testing.expect_value(t, status, proto.Status.Rate_Limited)

	attachments_conn_gone(s, alice)
	testing.expect(t, half not_in s.attach.uploads)
	testing.expect(t, !os.exists(part))
	testing.expect(t, done in s.attach.uploads)
	_, ok := attach_upload_for(s, alice.account.id, done)
	testing.expect(t, ok)
}

// Upload chunks that come faster than `rate_kb` (with some slack) are
// dropped, and an account can't upload more than `daily_megabytes` in a
// day, counting what its uploads in progress will still send.
@(test)
test_attachments_quota :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "yap-test-*", context.temp_allocator)
	defer remove_tree(dir)
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	testing.expect(t, blob_store_open(&s.blobs, &s.db, dir))
	attachments_open(s, {max_megabytes = 4, rate_kb = 1024, daily_megabytes = 3})
	defer attachments_close(s)
	attach_test_sent = record_sent
	defer attach_test_sent = nil
	defer sent_reset()

	ts_account(t, &ts, "alice", "a password")
	alice := logged_in(t, &ts, "alice")
	MIB :: 1024 * 1024
	data := test_file(2 * MIB, 4)
	_, id := put(t, &ts, alice, len(data), "big.zip")
	up := s.attach.uploads[id]
	send_all :: proc(s: ^Server, u: ^Conn, id: u64, data: []u8) {
		out: [proto.MAX_PAYLOAD_SIZE]u8
		for i in 0 ..< proto.file_chunk_count(u64(len(data))) {
			from, to := proto.file_chunk_range(u64(len(data)), i)
			handle_upload_chunk(
				s,
				u,
				proto.encode_transfer_chunk(out[:], .Upload_Chunk, id, i, data[from:to]),
			)
		}
	}

	// Sent all at once, only the burst (a second's worth) arrives.
	send_all(s, alice, id, data)
	testing.expectf(
		t,
		up.recv.done > MIB - proto.FILE_CHUNK_DATA && up.recv.done < MIB + 64 * 1024,
		"%d bytes arrived",
		up.recv.done,
	)

	// About 1 MiB has arrived and about 1 MiB is still to come, so 1.5 MiB
	// more would go over 3 MiB, but 0.75 MiB wouldn't.
	status, _ := put(t, &ts, alice, 3 * MIB / 2, "too much.zip")
	testing.expect_value(t, status, proto.Status.Quota)
	status, _ = put(t, &ts, alice, 3 * MIB / 4, "fits.zip")
	testing.expect_value(t, status, proto.Status.Ok)

	// A second later the rest arrives.
	up.paced_at = time.tick_add(up.paced_at, -time.Second)
	send_all(s, alice, id, data)
	testing.expect(t, up.blob != 0)
	status, _ = put(t, &ts, alice, MIB / 2, "too much.zip")
	testing.expect_value(t, status, proto.Status.Quota)

	// The next day the count starts over.
	use := &s.attach.used[alice.account.id]
	use.since = time.tick_add(use.since, -25 * time.Hour)
	status, _ = put(t, &ts, alice, MIB / 2, "tomorrow.zip")
	testing.expect_value(t, status, proto.Status.Ok)
}

// Retention removes the files of messages the same way it removes their
// pictures. It removes the files of older messages (file_days, or a
// purge of files) and the oldest files while pictures and files use too
// much space. The messages keep their list of files.
@(test)
test_attachments_retention :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "yap-test-*", context.temp_allocator)
	defer remove_tree(dir)
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	testing.expect(t, blob_store_open(&s.blobs, &s.db, dir))
	attachments_open(s, {max_megabytes = 8, rate_kb = 1024 * 1024})
	defer attachments_close(s)
	attach_test_sent = record_sent
	defer attach_test_sent = nil
	defer sent_reset()

	ts_account(t, &ts, "alice", "a password")
	alice := logged_in(t, &ts, "alice")
	home := s.convs.home.id
	posted :: proc(
		t: ^testing.T,
		ts: ^Test_Server,
		u: ^Conn,
		conv: proto.Conv_Id,
		data: []u8,
		name: string,
		nonce: u64,
	) -> proto.Msg_Id {
		_, upload := put(t, ts, u, len(data), name)
		send_file(t, ts, u, upload, data)
		status, id := post_files(t, ts, u, conv, "", nonce, upload)
		testing.expect_value(t, status, proto.Status.Ok)
		return id
	}
	first := posted(t, &ts, alice, home, test_file(2 * 1024 * 1024, 1), "one.zip", 1)
	second := posted(t, &ts, alice, home, test_file(5000, 2), "two.zip", 2)
	ts_events(t, &ts, alice)

	// A purge of files keeps the messages and their lists of files, but
	// the files themselves are gone. The purge only affects files older
	// than now, which the second one wouldn't be if it was posted in this
	// very millisecond, so wait a moment first.
	time.sleep(2 * time.Millisecond)
	testing.expect(
		t,
		retention_ask(
			&s.retention,
			&s.db,
			{before = proto.Unix_Ms(unix_ms() + 1000), what = .Files},
			unix_ms(),
		),
	)
	messages, _ := retention_drain(&s.retention, &s.blobs, s)
	testing.expect_value(t, messages, 2)
	m, found := msg_by_id(s, first)
	testing.expect(t, found && .Has_Attachments in m.flags)
	testing.expect_value(t, m.attachments[0], proto.Attachment{0, 2 * 1024 * 1024, "one.zip"})
	told := false
	for e in ts_events(t, &ts, alice) {
		if e.op == .Msgs_Purged {
			p, ok := proto.decode_msgs_purged(e.body)
			told = ok && p.what == .Files && p.before > second
		}
	}
	testing.expect(t, told, "alice wasn't told the files went")
	status, _ := fetch(t, &ts, alice, m.attachments[0].blob)
	testing.expect_value(t, status, proto.Status.Not_Found)

	// When too much space is used, the oldest files are removed until
	// there is enough space.
	third := posted(t, &ts, alice, home, test_file(3 * 1024 * 1024, 3), "three.zip", 3)
	fourth := posted(t, &ts, alice, home, test_file(1000, 4), "four.zip", 4)
	r := &s.retention
	r.config.blob_megabytes = 4 // 5 MB are stored, because the two purged blobs aren't collected yet
	append(&r.steps, Purge_Step{kind = .Size_Cap})
	retention_drain(r, &s.blobs, s)
	m, _ = msg_by_id(s, third)
	testing.expect_value(t, m.attachments[0].blob, proto.Blob_Id(0))
	m, _ = msg_by_id(s, fourth)
	testing.expect(t, m.attachments[0].blob != 0)
}

// Search finds messages by the names of their files as well as by their
// words. Each message is found once, newest first, and files of deleted
// messages are no longer found.
@(test)
test_attachments_search :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "yap-test-*", context.temp_allocator)
	defer remove_tree(dir)
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	testing.expect(t, blob_store_open(&s.blobs, &s.db, dir))
	attachments_open(s, {max_megabytes = 1, rate_kb = 1024})
	defer attachments_close(s)
	attach_test_sent = record_sent
	defer attach_test_sent = nil
	defer sent_reset()

	ts_account(t, &ts, "alice", "a password")
	alice := logged_in(t, &ts, "alice")
	home := s.convs.home.id
	upload :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn, name: string, seed: u8) -> u64 {
		data := test_file(3000, seed)
		_, id := put(t, ts, u, len(data), name)
		send_file(t, ts, u, id, data)
		return id
	}
	search :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn, query: string) -> []proto.Msg_Id {
		buf: [proto.MSG_SEARCH_MAX_SIZE]u8
		status, body := ts_ask(
			t,
			ts,
			u,
			.Msg_Search,
			proto.encode_msg_search(&buf, {limit = 20, query = query}),
		)
		testing.expect_value(t, status, proto.Status.Ok)
		msgs := make([]proto.Message, 20, context.temp_allocator)
		_, _, found, ok := proto.decode_search_answer(body, msgs)
		testing.expect(t, ok)
		ids := make([]proto.Msg_Id, len(found), context.temp_allocator)
		for m, i in found {
			ids[i] = m.id
		}
		return ids
	}

	_, words := post(t, &ts, alice, home, "the quarterly report is late", 1)
	_, report := post_files(
		t,
		&ts,
		alice,
		home,
		"",
		2,
		upload(t, &ts, alice, "Quarterly Report.pdf", 1),
	)
	_, both := post_files(
		t,
		&ts,
		alice,
		home,
		"the report, attached",
		3,
		upload(t, &ts, alice, "report-final.pdf", 2),
	)
	_, other := post_files(t, &ts, alice, home, "", 4, upload(t, &ts, alice, "holiday.jpg", 3))

	testing.expect(
		t,
		slice.equal(search(t, &ts, alice, "report"), []proto.Msg_Id{both, report, words}),
	)
	testing.expect(
		t,
		slice.equal(search(t, &ts, alice, "quarterly"), []proto.Msg_Id{report, words}),
	)
	testing.expect(t, slice.equal(search(t, &ts, alice, "holiday"), []proto.Msg_Id{other}))
	testing.expect(t, slice.equal(search(t, &ts, alice, "final"), []proto.Msg_Id{both}))

	id_buf: [proto.MSG_ID_SIZE]u8
	status, _ := ts_ask(t, &ts, alice, .Msg_Delete, proto.encode_msg_id(&id_buf, report))
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect(t, slice.equal(search(t, &ts, alice, "quarterly"), []proto.Msg_Id{words}))
}

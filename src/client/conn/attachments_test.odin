#+build !wasi
package conn

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "common:proto"

// Tests of files attached to messages (attachments.odin): uploading them to the
// server before the message is posted, giving up when the server refuses or
// goes quiet, and saving or previewing the files of messages that arrive.

@(private = "file")
Rig :: struct {
	tc:  Test_Conn,
	dir: string,
}

@(private = "file")
rig_open :: proc(t: ^testing.T, r: ^Rig) -> ^View {
	tc := &r.tc
	tc_open(tc)
	tc_connect(t, tc)
	c := &tc.c
	c.auth.me = 1
	c.auth.state = .Done
	tc_account(tc, 1, "bob", "Bob")
	tc_account(tc, 2, "alice", "Alice")
	tc_conv(tc, 3, "Lobby")
	c.convs.viewing = 3
	c.rpc.server.max_attachment = 1 << 20
	base, _ := os.temp_directory(context.temp_allocator)
	dir, err := os.make_directory_temp(base, "yap-attach-*", context.allocator)
	testing.expect(t, err == nil)
	r.dir = dir
	c.files.download_dir = strings.clone(dir)
	return tc_view(tc)
}

@(private = "file")
rig_close :: proc(r: ^Rig) {
	attachments_destroy(&r.tc.c)
	files_destroy(&r.tc.c)
	blobs_destroy(&r.tc.c)
	tc_close(&r.tc)
	os.remove_all(r.dir)
	delete(r.dir)
}

@(private = "file")
content :: proc(n: int) -> []u8 {
	data := make([]u8, n, context.temp_allocator)
	for &b, i in data {
		b = u8(i * 17 + i / 199)
	}
	return data
}

// pasted is a file to attach whose bytes are in memory, like a pasted picture.
@(private = "file")
pasted :: proc(name: string, data: []u8) -> Attach_File {
	return {web_name = strings.clone(name), data = slice_clone(data)}
}

@(private = "file")
slice_clone :: proc(data: []u8) -> []u8 {
	out := make([]u8, len(data))
	copy(out, data)
	return out
}

// attach_path sends a message with the one file at `path`.
@(private = "file")
attach_path :: proc(c: ^Server_Conn, path: string) {
	files := make([]Attach_File, 1)
	files[0] = {path = strings.clone(path)}
	tc_run(attach_send, c, Attach_Send_Command{files = files})
}

@(private = "file")
send :: proc(c: ^Server_Conn, text: string, files: ..Attach_File) {
	list := make([]Attach_File, len(files))
	copy(list, files)
	cmd := Attach_Send_Command{text = strings.clone(text), files = list}
	attach_send(c, cmd)
	command_destroy(cmd)
}

@(private = "file")
of_kind :: proc(t: ^testing.T, tc: ^Test_Conn, kind: proto.Message_Kind) -> [][]u8 {
	found := make([dynamic][]u8, context.temp_allocator)
	for d in tc_datagrams(t, tc) {
		if k, ok := proto.message_kind(d); ok && k == kind {
			append(&found, d)
		}
	}
	return found[:]
}

// put answers the Attach_Put that is pending, as the server would.
@(private = "file")
put_ok :: proc(t: ^testing.T, tc: ^Test_Conn, id: u64) -> Test_Request {
	attachments_step(&tc.c)
	r, _ := tc_one(t, tc, .Attach_Put)
	buf: [8]u8
	tc_answer(tc, r.id, .Ok, proto.encode_attach_id(&buf, id))
	return r
}

// ---- what can be attached ----

@(test)
test_attach_refusals :: proc(t: ^testing.T) {
	context.logger = expected_errors() // an unreadable file is logged as an error
	r: Rig
	v := rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c

	Case :: struct {
		files: []Attach_File,
		text:  string,
	}
	// No files, or too many.
	few := Attach_Send_Command{text = strings.clone("x")}
	attach_send(c, few)
	command_destroy(few)
	testing.expect_value(t, v.notice.text, "A message can have at most 10 files attached.")
	many := make([]Attach_File, proto.MAX_ATTACHMENTS + 1)
	for &f in many {
		f = pasted("a.png", content(10))
	}
	too_many := Attach_Send_Command{files = many}
	attach_send(c, too_many)
	command_destroy(too_many)
	testing.expect_value(t, v.notice.count, 2)

	// A server that takes none.
	c.rpc.server.max_attachment = 0
	send(c, "x", pasted("a.png", content(10)))
	testing.expect_value(t, v.notice.text, "This server does not accept file attachments.")
	c.rpc.server.max_attachment = 100

	// Empty, too big, nameless, unreadable. The second of two being bad refuses both.
	send(c, "x", pasted("a.png", nil)) // nil data is read from a path that is not there
	testing.expect_value(t, v.notice.text, "A file could not be read, so the message was not sent.")
	// A file with nothing in it (on disk: an empty slice in memory reads as none).
	empty, _ := os.join_path({r.dir, "empty.png"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(empty, nil) == nil)
	attach_path(c, empty)
	testing.expect_value(t, v.notice.text, "Empty files cannot be sent.")
	send(c, "x", pasted("big.png", content(101)))
	testing.expect_value(t, v.notice.text, "A file is larger than the maximum size this server allows.")
	send(c, "x", pasted("", content(10)))
	testing.expect_value(t, v.notice.text, "A file has a name that cannot be used.")
	send(c, "x", pasted("fine.png", content(10)), pasted("big.png", content(101)))
	testing.expect_value(t, v.notice.text, "A file is larger than the maximum size this server allows.")
	testing.expect_value(t, len(c.attach.posts), 0)
	testing.expect_value(t, len(tc_sent(t, &r.tc)), 0)

	// Nowhere to send it: not an error the user needs told about.
	c.convs.viewing = 0
	count := v.notice.count
	send(c, "x", pasted("a.png", content(10)))
	testing.expect_value(t, len(c.attach.posts), 0)
	testing.expect_value(t, v.notice.count, count)
}

@(test)
test_attach_names_are_cleaned :: proc(t: ^testing.T) {
	r: Rig
	_ = rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c
	send(c, "x", pasted("../../etc/passwd.png", content(10)))
	testing.expect_value(t, len(c.attach.posts), 1)
	if len(c.attach.posts) == 1 {
		testing.expect_value(t, c.attach.posts[0].files[0].name, "passwd.png")
	}
}

// ---- uploading ----

@(test)
test_uploading_and_posting :: proc(t: ^testing.T) {
	r: Rig
	_ = rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c
	data := content(proto.FILE_CHUNK_DATA * 2 + 50)

	send(c, "look at this", pasted("pic.png", data))
	testing.expect_value(t, len(c.attach.posts), 1)
	p := c.attach.posts[0]
	testing.expect_value(t, p.text, "look at this")
	testing.expect_value(t, p.conv, proto.Conv_Id(3))
	testing.expect_value(t, p.files[0].state, Upload_State.Waiting)
	testing.expect(t, !p.queued)
	// Nothing is in the outbox yet: the message waits for its files.
	testing.expect_value(t, len(c.msgs.outbox), 0)

	// The server is told the file's size and name first.
	attachments_step(c)
	req, ok := tc_one(t, &r.tc, .Attach_Put)
	testing.expect(t, ok)
	put, dec := proto.decode_attach_put(req.body)
	testing.expect(t, dec)
	testing.expect_value(t, put.size, u64(len(data)))
	testing.expect_value(t, put.name, "pic.png")
	testing.expect_value(t, p.files[0].state, Upload_State.Putting)
	attachments_step(c) // not asked twice
	testing.expect_value(t, len(tc_sent(t, &r.tc)), 0)

	// Its answer is the upload's id, and the chunks go out under it.
	buf: [8]u8
	tc_answer(&r.tc, req.id, .Ok, proto.encode_attach_id(&buf, 77))
	testing.expect_value(t, p.files[0].state, Upload_State.Sending)
	testing.expect_value(t, p.files[0].id, u64(77))
	// Sending is paced; with a limit this low a turn sends one chunk, whatever
	// time has passed.
	c.files.upload_limit = 1
	chunks := make([dynamic][]u8, context.temp_allocator)
	for _ in 0 ..< 3 {
		p.files[0].send.pace.tokens = 1
		attachments_step(c)
		got := of_kind(t, &r.tc, .Upload_Chunk)
		testing.expect_value(t, len(got), 1)
		append(&chunks, ..got)
	}

	// The server receives the file; when it says so, the message is queued.
	recv: proto.Transfer_Receiver
	proto.transfer_receiver_init(&recv, u64(len(data)))
	defer proto.transfer_receiver_destroy(&recv)
	stored := make([]u8, len(data), context.temp_allocator)
	for d in chunks {
		id, index, part := proto.decode_transfer_chunk(d)
		testing.expect_value(t, id, u64(77))
		start, _ := proto.file_chunk_range(u64(len(data)), index)
		copy(stored[start:], part)
		proto.transfer_got(&recv, index, len(part))
	}
	testing.expect_value(t, string(stored), string(data))
	out: [proto.MAX_PAYLOAD_SIZE]u8
	handle_upload_ack(c, proto.transfer_encode_ack(&recv, out[:], .Upload_Ack, 77, 0, time.tick_now()))
	testing.expect_value(t, p.files[0].state, Upload_State.Done)
	testing.expect(t, !p.queued)
	attachments_step(c)
	testing.expect(t, p.queued)
	testing.expect_value(t, len(c.msgs.outbox), 1)

	// It is posted naming the upload, and the post is what ends the attachment.
	drive_outbox(c)
	post_req, post_ok := tc_one(t, &r.tc, .Msg_Post)
	testing.expect(t, post_ok)
	post, post_dec := proto.decode_msg_post(post_req.body)
	testing.expect(t, post_dec)
	testing.expect_value(t, post.text, "look at this")
	testing.expect_value(t, post.attachment_count, 1)
	testing.expect_value(t, post.uploads[0], u64(77))
	testing.expect_value(t, post.conv, proto.Conv_Id(3))
	posted: [proto.MSG_POSTED_SIZE]u8
	tc_answer(&r.tc, post_req.id, .Ok, proto.encode_msg_posted(&posted, 900, 1000))
	testing.expect_value(t, len(c.attach.posts), 0)
	testing.expect_value(t, len(c.msgs.outbox), 0)
}

@(test)
test_files_from_disk :: proc(t: ^testing.T) {
	r: Rig
	_ = rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c
	data := content(proto.FILE_CHUNK_DATA + 10)
	path, _ := os.join_path({r.dir, "from disk.png"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(path, data) == nil)

	attach_path(c, path)
	testing.expect_value(t, len(c.attach.posts), 1)
	_ = put_ok(t, &r.tc, 5)
	c.files.upload_limit = 1
	chunks := make([dynamic][]u8, context.temp_allocator)
	for _ in 0 ..< 2 {
		c.attach.posts[0].files[0].send.pace.tokens = 1
		attachments_step(c)
		append(&chunks, ..of_kind(t, &r.tc, .Upload_Chunk))
	}
	testing.expect_value(t, len(chunks), 2)
	got := make([]u8, len(data), context.temp_allocator)
	for d in chunks {
		_, index, part := proto.decode_transfer_chunk(d)
		start, _ := proto.file_chunk_range(u64(len(data)), index)
		copy(got[start:], part)
	}
	testing.expect_value(t, string(got), string(data))
}

@(test)
test_one_file_at_a_time :: proc(t: ^testing.T) {
	r: Rig
	_ = rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c
	send(c, "first", pasted("a.png", content(50)), pasted("b.png", content(50)))
	send(c, "second", pasted("c.png", content(50)))

	// The first file of the first message is announced. Nothing else is, until it is done.
	attachments_step(c)
	req, ok := tc_one(t, &r.tc, .Attach_Put)
	testing.expect(t, ok)
	put, _ := proto.decode_attach_put(req.body)
	testing.expect_value(t, put.name, "a.png")
	attachments_step(c)
	testing.expect_value(t, len(tc_sent(t, &r.tc)), 0)
	buf: [8]u8
	tc_answer(&r.tc, req.id, .Ok, proto.encode_attach_id(&buf, 1))
	attachments_step(c)
	testing.expect_value(t, len(tc_sent(t, &r.tc)), 0)

	// Finishing it makes the next file of the same message the one in turn.
	out: [proto.MAX_PAYLOAD_SIZE]u8
	recv: proto.Transfer_Receiver
	proto.transfer_receiver_init(&recv, 50)
	defer proto.transfer_receiver_destroy(&recv)
	proto.transfer_got(&recv, 0, 50)
	handle_upload_ack(c, proto.transfer_encode_ack(&recv, out[:], .Upload_Ack, 1, 0, time.tick_now()))
	_ = tc_datagrams(t, &r.tc)
	attachments_step(c)
	req, ok = tc_one(t, &r.tc, .Attach_Put)
	testing.expect(t, ok)
	put, _ = proto.decode_attach_put(req.body)
	testing.expect_value(t, put.name, "b.png")
}

@(test)
test_put_answers :: proc(t: ^testing.T) {
	Case :: struct {
		status: proto.Status,
		text:   string, // "" when the file is just asked for again
	}
	cases := []Case {
		{.Too_Large, "A file is larger than the maximum size this server allows."},
		{.Denied, "You don't have permission to send files here."},
		{.Closed, "The server has no room for more files."},
		{.Quota, "You have sent as many files as this server allows for today."},
		{.Internal, "The server rejected the file."},
		{.Rate_Limited, ""},
		{.Reset, ""},
	}
	for k in cases {
		r: Rig
		v := rig_open(t, &r)
		defer rig_close(&r)
		c := &r.tc.c
		send(c, "x", pasted("a.png", content(50)))
		attachments_step(c)
		req, _ := tc_one(t, &r.tc, .Attach_Put)
		tc_answer(&r.tc, req.id, k.status)
		if k.text != "" {
			testing.expectf(t, len(c.attach.posts) == 0, "%v: the message was kept", k.status)
			testing.expectf(t, v.notice.text == k.text, "%v: %q", k.status, v.notice.text)
			testing.expect(t, !v.notice.ok)
		} else {
			testing.expectf(t, len(c.attach.posts) == 1, "%v: the message was dropped", k.status)
			testing.expect_value(t, c.attach.posts[0].files[0].state, Upload_State.Waiting)
			// It is asked for again.
			attachments_step(c)
			_, again := tc_one(t, &r.tc, .Attach_Put)
			testing.expectf(t, again, "%v: not asked for again", k.status)
		}
	}
}

@(test)
test_put_answer_that_is_unreadable :: proc(t: ^testing.T) {
	r: Rig
	_ = rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c
	send(c, "x", pasted("a.png", content(50)))
	attachments_step(c)
	req, _ := tc_one(t, &r.tc, .Attach_Put)
	tc_answer(&r.tc, req.id, .Ok, []u8{1, 2})
	testing.expect_value(t, c.attach.posts[0].files[0].state, Upload_State.Waiting)
	// An answer for a message that is gone is ignored.
	attachments_step(c)
	req, _ = tc_one(t, &r.tc, .Attach_Put)
	attach_cancel(c, c.attach.posts[0].nonce)
	buf: [8]u8
	tc_answer(&r.tc, req.id, .Ok, proto.encode_attach_id(&buf, 9))
	testing.expect_value(t, len(c.attach.posts), 0)
}

// ---- stopping ----

@(test)
test_cancelling_an_upload :: proc(t: ^testing.T) {
	r: Rig
	_ = rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c
	send(c, "x", pasted("a.png", content(50)))
	nonce := c.attach.posts[0].nonce
	_ = put_ok(t, &r.tc, 31)
	_ = tc_datagrams(t, &r.tc)

	// Stopped while sending: the server is told, so that it drops the upload.
	attach_cancel(c, nonce)
	testing.expect_value(t, len(c.attach.posts), 0)
	cancels := of_kind(t, &r.tc, .Transfer_Cancel)
	testing.expect_value(t, len(cancels), 1)
	if len(cancels) == 1 {
		id, reason := proto.decode_transfer_cancel(cancels[0])
		testing.expect_value(t, id, u64(31))
		testing.expect_value(t, reason, proto.File_Cancel_Reason.Cancelled)
	}
	// Cancelling what isn't there is nothing.
	attach_cancel(c, nonce)
	attach_cancel(c, 12345)
}

@(private = "file")
upload_all :: proc(t: ^testing.T, r: ^Rig, id: u64, size: int) {
	c := &r.tc.c
	_ = put_ok(t, &r.tc, id)
	out: [proto.MAX_PAYLOAD_SIZE]u8
	recv: proto.Transfer_Receiver
	proto.transfer_receiver_init(&recv, u64(size))
	defer proto.transfer_receiver_destroy(&recv)
	proto.transfer_got(&recv, 0, size)
	handle_upload_ack(c, proto.transfer_encode_ack(&recv, out[:], .Upload_Ack, id, 0, time.tick_now()))
	attachments_step(c)
}

@(test)
test_cancelling_a_message_in_the_outbox :: proc(t: ^testing.T) {
	r: Rig
	_ = rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c
	send(c, "x", pasted("a.png", content(50)))
	nonce := c.attach.posts[0].nonce
	upload_all(t, &r, 31, 50)
	testing.expect_value(t, len(c.msgs.outbox), 1)

	// Waiting its turn in the outbox, it can be taken back.
	attach_cancel(c, nonce)
	testing.expect_value(t, len(c.msgs.outbox), 0)
	testing.expect_value(t, len(c.attach.posts), 0)

	// Once it is being posted it is too late.
	send(c, "y", pasted("b.png", content(50)))
	nonce = c.attach.posts[0].nonce
	upload_all(t, &r, 32, 50)
	drive_outbox(c)
	_ = tc_sent(t, &r.tc)
	attach_cancel(c, nonce)
	testing.expect_value(t, len(c.msgs.outbox), 1)
	testing.expect_value(t, len(c.attach.posts), 1)
}

@(test)
test_giving_up_on_a_silent_server :: proc(t: ^testing.T) {
	r: Rig
	v := rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c
	send(c, "x", pasted("a.png", content(50)))
	_ = put_ok(t, &r.tc, 41)
	f := &c.attach.posts[0].files[0]

	// Quiet for a while is not yet a reason.
	f.last_heard = time.tick_add(time.tick_now(), -(FILE_TIMEOUT / 2))
	attachments_step(c)
	testing.expect_value(t, f.state, Upload_State.Sending)

	// Each time it goes quiet the file is announced again, up to a point, then
	// the message is given up and the user told.
	for try in 1 ..< ATTACH_TRIES {
		f.last_heard = time.tick_add(time.tick_now(), -(FILE_TIMEOUT + time.Second))
		attachments_step(c)
		testing.expectf(t, len(c.attach.posts) == 1, "given up after %d tries", try)
		testing.expect_value(t, f.state, Upload_State.Waiting)
		testing.expect_value(t, f.tries, try)
		_ = put_ok(t, &r.tc, u64(41 + try))
		f = &c.attach.posts[0].files[0]
	}
	f.last_heard = time.tick_add(time.tick_now(), -(FILE_TIMEOUT + time.Second))
	attachments_step(c)
	testing.expect_value(t, len(c.attach.posts), 0)
	testing.expect_value(t, v.notice.text, "A file could not be sent because the server rejected it.")
}

@(test)
test_server_stops_an_upload :: proc(t: ^testing.T) {
	r: Rig
	v := rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c
	send(c, "x", pasted("a.png", content(50)))
	_ = put_ok(t, &r.tc, 51)
	buf: [proto.TRANSFER_CANCEL_SIZE]u8

	// Cancelled (for example because it restarted): the file is sent again.
	handle_transfer_cancel(c, proto.encode_transfer_cancel(&buf, 51, .Cancelled))
	testing.expect_value(t, c.attach.posts[0].files[0].state, Upload_State.Waiting)
	_ = put_ok(t, &r.tc, 52)
	// Failed to store it: the message is given up.
	handle_transfer_cancel(c, proto.encode_transfer_cancel(&buf, 52, .Failed))
	testing.expect_value(t, len(c.attach.posts), 0)
	testing.expect_value(t, v.notice.text, "The server failed to store a file, so the message was not sent.")
	// For a transfer we know nothing of: nothing.
	handle_transfer_cancel(c, proto.encode_transfer_cancel(&buf, 999, .Failed))
}

@(test)
test_uploads_that_are_gone_are_uploaded_again :: proc(t: ^testing.T) {
	r: Rig
	_ = rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c
	send(c, "x", pasted("a.png", content(50)))
	upload_all(t, &r, 61, 50)
	drive_outbox(c)
	req, _ := tc_one(t, &r.tc, .Msg_Post)

	// The server no longer has the uploads (it restarted, or an hour went by):
	// the files are sent again and the message is queued again afterwards.
	tc_answer(&r.tc, req.id, .Not_Found)
	testing.expect_value(t, len(c.msgs.outbox), 0)
	testing.expect_value(t, len(c.attach.posts), 1)
	p := c.attach.posts[0]
	testing.expect(t, !p.queued)
	testing.expect_value(t, p.files[0].state, Upload_State.Waiting)
	testing.expect_value(t, p.files[0].id, u64(0))
	upload_all(t, &r, 62, 50)
	testing.expect_value(t, len(c.msgs.outbox), 1)
	drive_outbox(c)
	req, _ = tc_one(t, &r.tc, .Msg_Post)
	post, _ := proto.decode_msg_post(req.body)
	testing.expect_value(t, post.uploads[0], u64(62))
}

@(test)
test_post_refused_after_the_upload :: proc(t: ^testing.T) {
	r: Rig
	v := rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c
	send(c, "x", pasted("a.png", content(50)))
	upload_all(t, &r, 61, 50)
	drive_outbox(c)
	req, _ := tc_one(t, &r.tc, .Msg_Post)
	tc_answer(&r.tc, req.id, .Denied)
	testing.expect_value(t, len(c.msgs.outbox), 0)
	testing.expect_value(t, len(c.attach.posts), 0)
	testing.expect_value(t, v.notice.text, "A message wasn't posted because you can't write or attach files there.")
}

@(test)
test_uploads_restart_with_the_connection :: proc(t: ^testing.T) {
	r: Rig
	_ = rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c
	send(c, "a", pasted("a.png", content(50)))
	send(c, "b", pasted("b.png", content(50)))
	attachments_step(c)
	_ = tc_sent(t, &r.tc)

	attachments_restart(c, false)
	testing.expect_value(t, len(c.attach.posts), 2)
	testing.expect_value(t, c.attach.posts[0].files[0].state, Upload_State.Waiting)
	// The first file is announced again.
	attachments_step(c)
	req, ok := tc_one(t, &r.tc, .Attach_Put)
	testing.expect(t, ok)
	put, _ := proto.decode_attach_put(req.body)
	testing.expect_value(t, put.name, "a.png")

	// Logged out: everything is forgotten.
	attachments_restart(c, true)
	testing.expect_value(t, len(c.attach.posts), 0)
}

// ---- saving ----

@(private = "file")
with_file :: proc(r: ^Rig, name: string, size: u64, blob: proto.Blob_Id = 700) {
	tc_message_with_files(&r.tc, 3, 40, {{blob = blob, size = size, name = name}})
}

@(test)
test_saving_a_file :: proc(t: ^testing.T) {
	r: Rig
	_ = rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c
	data := content(proto.FILE_CHUNK_DATA * 2 + 20)
	with_file(&r, "report.zip", u64(len(data)))

	attach_save(c, {msg = 40, index = 0})
	sv := c.attach.saves[700]
	testing.expect(t, sv != nil)
	testing.expect_value(t, sv.state, Save_State.Asking)
	testing.expect(t, strings.has_prefix(sv.path, r.dir))
	testing.expect(t, strings.has_suffix(sv.path, "report.zip"))
	testing.expect(t, os.exists(strings.concatenate({sv.path, ".part"}, context.temp_allocator)))

	// It is asked for once, and the answer names the download and says its size.
	attachments_step(c)
	attachments_step(c)
	req, ok := tc_one(t, &r.tc, .Attach_Get)
	testing.expect(t, ok)
	blob, dec := proto.decode_attach_id(req.body)
	testing.expect(t, dec)
	testing.expect_value(t, blob, u64(700))
	buf: [proto.ATTACH_GET_ANSWER_SIZE]u8
	tc_answer(&r.tc, req.id, .Ok, proto.encode_attach_get_answer(&buf, u64(len(data)), 88))
	testing.expect_value(t, sv.state, Save_State.Receiving)
	testing.expect_value(t, sv.id, u64(88))
	// What is here is acknowledged at once, so nothing is sent twice after a restart.
	acks := of_kind(t, &r.tc, .Download_Ack)
	testing.expect(t, len(acks) >= 1)

	// The chunks, in any order, with a repeat and one that doesn't fit.
	out: [proto.MAX_PAYLOAD_SIZE]u8
	chunk :: proc(out: []u8, data: []u8, id: u64, index: u32) -> []u8 {
		s, e := proto.file_chunk_range(u64(len(data)), index)
		return proto.encode_transfer_chunk(out, .Download_Chunk, id, index, data[s:e])
	}
	handle_download_chunk(c, chunk(out[:], data, 88, 2))
	handle_download_chunk(c, chunk(out[:], data, 88, 2))
	handle_download_chunk(c, proto.encode_transfer_chunk(out[:], .Download_Chunk, 88, 1, data[:5]))
	handle_download_chunk(c, chunk(out[:], data, 999, 0)) // another download's
	testing.expect_value(t, sv.state, Save_State.Receiving)
	handle_download_chunk(c, chunk(out[:], data, 88, 0))
	handle_download_chunk(c, chunk(out[:], data, 88, 1))

	testing.expect_value(t, sv.state, Save_State.Done)
	saved, read_err := os.read_entire_file(sv.path, context.temp_allocator)
	testing.expect(t, read_err == nil)
	testing.expect_value(t, string(saved), string(data))
	testing.expect(t, !os.exists(strings.concatenate({sv.path, ".part"}, context.temp_allocator)))
	// The server is told that it is complete.
	acks = of_kind(t, &r.tc, .Download_Ack)
	testing.expect(t, len(acks) >= 1)
	if len(acks) >= 1 {
		ack, _, _, ack_ok := proto.decode_transfer_ack(acks[len(acks) - 1])
		testing.expect(t, ack_ok && ack.complete)
	}
}

@(test)
test_saving_refusals :: proc(t: ^testing.T) {
	r: Rig
	v := rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c
	with_file(&r, "report.zip", 100, 700)
	tc_message_with_files(&r.tc, 3, 41, {{blob = 0, size = 100, name = "gone.zip"}})
	tc_message_with_files(&r.tc, 3, 42, {{blob = 701, size = proto.MAX_FILE_SIZE + 1, name = "huge.zip"}})

	// Not a message of ours, not a file of it.
	attach_save(c, {msg = 999, index = 0})
	attach_save(c, {msg = 40, index = 1})
	attach_save(c, {msg = 40, index = -1})
	testing.expect_value(t, len(c.attach.saves), 0)
	// A file the retention policy has removed, or one too large to be saved.
	attach_save(c, {msg = 41, index = 0})
	testing.expect_value(t, v.notice.text, "That file is no longer available on the server.")
	attach_save(c, {msg = 42, index = 0})
	testing.expect_value(t, v.notice.text, "That file is too large to be saved.")
	testing.expect_value(t, len(c.attach.saves), 0)

	// A downloads folder that can't be written to.
	blocker, _ := os.join_path({r.dir, "blocker"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(blocker, "x") == nil)
	delete(c.files.download_dir)
	c.files.download_dir = strings.clone(strings.concatenate({blocker, "/sub"}, context.temp_allocator))
	context.logger = expected_errors()
	attach_save(c, {msg = 40, index = 0})
	testing.expect_value(
		t,
		v.notice.text,
		"The file could not be saved because the downloads folder is not writable.",
	)
	testing.expect_value(t, len(c.attach.saves), 0)
}

@(test)
test_saving_twice_and_again :: proc(t: ^testing.T) {
	r: Rig
	_ = rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c
	with_file(&r, "report.zip", 100)

	attach_save(c, {msg = 40, index = 0})
	first := c.attach.saves[700]
	// Asked for again while it is on its way: nothing new.
	attach_save(c, {msg = 40, index = 0})
	testing.expect(t, c.attach.saves[700] == first)
	testing.expect_value(t, len(c.attach.saves), 1)

	// Once it is over, saving it again starts a new file next to the first.
	// The first one is dropped for the second without being finished, so its
	// file is closed here.
	unfinished := first.sink
	first.state = .Done
	attach_save(c, {msg = 40, index = 0})
	file_sink_abort(&unfinished)
	second := c.attach.saves[700]
	testing.expect_value(t, second.state, Save_State.Asking)
	testing.expect(t, strings.has_suffix(second.path, "report (1).zip"))
}

@(test)
test_cancelling_a_save :: proc(t: ^testing.T) {
	r: Rig
	_ = rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c
	with_file(&r, "report.zip", 100)
	attach_save(c, {msg = 40, index = 0})
	sv := c.attach.saves[700]
	part := strings.concatenate({sv.path, ".part"}, context.temp_allocator)

	// Before the server has named the download there is nobody to tell.
	attach_save(c, {msg = 40, index = 0, cancel = true})
	testing.expect_value(t, sv.state, Save_State.Cancelled)
	testing.expect(t, !os.exists(part), "a cancelled save left a partial file")
	testing.expect_value(t, len(of_kind(t, &r.tc, .Transfer_Cancel)), 0)

	// While receiving, the server is told.
	attach_save(c, {msg = 40, index = 0})
	sv = c.attach.saves[700]
	attachments_step(c)
	req, _ := tc_one(t, &r.tc, .Attach_Get)
	buf: [proto.ATTACH_GET_ANSWER_SIZE]u8
	tc_answer(&r.tc, req.id, .Ok, proto.encode_attach_get_answer(&buf, 100, 91))
	_ = tc_datagrams(t, &r.tc)
	attach_save(c, {msg = 40, index = 0, cancel = true})
	testing.expect_value(t, sv.state, Save_State.Cancelled)
	cancels := of_kind(t, &r.tc, .Transfer_Cancel)
	testing.expect_value(t, len(cancels), 1)
	if len(cancels) == 1 {
		id, _ := proto.decode_transfer_cancel(cancels[0])
		testing.expect_value(t, id, u64(91))
	}
	// Cancelling what isn't being saved does nothing.
	attach_save(c, {msg = 40, index = 0, cancel = true})
	testing.expect_value(t, sv.state, Save_State.Cancelled)
}

@(test)
test_save_answers :: proc(t: ^testing.T) {
	Case :: struct {
		status: proto.Status,
		body:   []u8,
		state:  Save_State,
		notice: string,
	}
	size_ok := [proto.ATTACH_GET_ANSWER_SIZE]u8{}
	wrong := [proto.ATTACH_GET_ANSWER_SIZE]u8{}
	proto_buf: [proto.ATTACH_GET_ANSWER_SIZE]u8
	good := proto.encode_attach_get_answer(&proto_buf, 100, 5)
	copy(size_ok[:], good)
	wrong_buf: [proto.ATTACH_GET_ANSWER_SIZE]u8
	bad := proto.encode_attach_get_answer(&wrong_buf, 101, 5)
	copy(wrong[:], bad)
	cases := []Case {
		{.Ok, size_ok[:], .Receiving, ""},
		{.Ok, wrong[:], .Failed, ""}, // not the size its message says
		{.Ok, []u8{1}, .Failed, ""},
		{.Not_Found, nil, .Failed, "That file is no longer available on the server."},
		{.Denied, nil, .Failed, ""},
		{.Rate_Limited, nil, .Asking, ""}, // asked again
		{.Reset, nil, .Asking, ""},
	}
	for k in cases {
		context.logger = expected_errors()
		r: Rig
		v := rig_open(t, &r)
		defer rig_close(&r)
		c := &r.tc.c
		with_file(&r, "report.zip", 100)
		attach_save(c, {msg = 40, index = 0})
		attachments_step(c)
		req, _ := tc_one(t, &r.tc, .Attach_Get)
		tc_answer(&r.tc, req.id, k.status, k.body)
		sv := c.attach.saves[700]
		testing.expectf(t, sv.state == k.state, "%v %v: %v", k.status, len(k.body), sv.state)
		if k.notice != "" {
			testing.expect_value(t, v.notice.text, k.notice)
		}
		if k.state == .Asking {
			attachments_step(c)
			_, again := tc_one(t, &r.tc, .Attach_Get)
			testing.expectf(t, again, "%v: not asked for again", k.status)
		}
	}
}

@(test)
test_save_resumes_after_a_restart :: proc(t: ^testing.T) {
	r: Rig
	_ = rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c
	data := content(proto.FILE_CHUNK_DATA * 2 + 20)
	with_file(&r, "report.zip", u64(len(data)))
	attach_save(c, {msg = 40, index = 0})
	attachments_step(c)
	req, _ := tc_one(t, &r.tc, .Attach_Get)
	buf: [proto.ATTACH_GET_ANSWER_SIZE]u8
	tc_answer(&r.tc, req.id, .Ok, proto.encode_attach_get_answer(&buf, u64(len(data)), 7))
	out: [proto.MAX_PAYLOAD_SIZE]u8
	s0, e0 := proto.file_chunk_range(u64(len(data)), 0)
	handle_download_chunk(c, proto.encode_transfer_chunk(out[:], .Download_Chunk, 7, 0, data[s0:e0]))
	sv := c.attach.saves[700]
	testing.expect_value(t, sv.recv.done, e0 - s0)
	_ = tc_datagrams(t, &r.tc)

	// The connection restarts: the file is asked for again, and what has arrived stays.
	attachments_restart(c, false)
	testing.expect_value(t, sv.state, Save_State.Asking)
	attachments_step(c)
	req, _ = tc_one(t, &r.tc, .Attach_Get)
	tc_answer(&r.tc, req.id, .Ok, proto.encode_attach_get_answer(&buf, u64(len(data)), 8))
	testing.expect_value(t, sv.state, Save_State.Receiving)
	testing.expect_value(t, sv.recv.done, e0 - s0)
	// The first thing said is what is already here.
	acks := of_kind(t, &r.tc, .Download_Ack)
	testing.expect(t, len(acks) >= 1)
	if len(acks) >= 1 {
		ack, _, _, ok := proto.decode_transfer_ack(acks[0])
		testing.expect(t, ok)
		testing.expect_value(t, ack.id, u64(8))
		testing.expect_value(t, ack.base, u32(1))
	}
	for index in 1 ..< 3 {
		s, e := proto.file_chunk_range(u64(len(data)), u32(index))
		handle_download_chunk(c, proto.encode_transfer_chunk(out[:], .Download_Chunk, 8, u32(index), data[s:e]))
	}
	testing.expect_value(t, sv.state, Save_State.Done)
	saved, err := os.read_entire_file(sv.path, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, string(saved), string(data))
}

@(test)
test_server_stops_a_download :: proc(t: ^testing.T) {
	r: Rig
	_ = rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c
	with_file(&r, "report.zip", 100)
	attach_save(c, {msg = 40, index = 0})
	attachments_step(c)
	req, _ := tc_one(t, &r.tc, .Attach_Get)
	buf: [proto.ATTACH_GET_ANSWER_SIZE]u8
	tc_answer(&r.tc, req.id, .Ok, proto.encode_attach_get_answer(&buf, 100, 12))
	sv := c.attach.saves[700]
	cancel: [proto.TRANSFER_CANCEL_SIZE]u8

	// Cancelled: asked for again. Failed: given up.
	handle_transfer_cancel(c, proto.encode_transfer_cancel(&cancel, 12, .Cancelled))
	testing.expect_value(t, sv.state, Save_State.Asking)
	attachments_step(c)
	req, _ = tc_one(t, &r.tc, .Attach_Get)
	tc_answer(&r.tc, req.id, .Ok, proto.encode_attach_get_answer(&buf, 100, 13))
	handle_transfer_cancel(c, proto.encode_transfer_cancel(&cancel, 13, .Failed))
	testing.expect_value(t, sv.state, Save_State.Failed)
	testing.expect(t, !os.exists(strings.concatenate({sv.path, ".part"}, context.temp_allocator)))
}

@(test)
test_download_that_goes_quiet :: proc(t: ^testing.T) {
	r: Rig
	_ = rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c
	with_file(&r, "report.zip", 100)
	attach_save(c, {msg = 40, index = 0})
	attachments_step(c)
	req, _ := tc_one(t, &r.tc, .Attach_Get)
	buf: [proto.ATTACH_GET_ANSWER_SIZE]u8
	tc_answer(&r.tc, req.id, .Ok, proto.encode_attach_get_answer(&buf, 100, 12))
	sv := c.attach.saves[700]

	// Quiet for too long: it is asked for again.
	sv.last_heard = time.tick_add(time.tick_now(), -(FILE_TIMEOUT + time.Second))
	attachments_step(c)
	testing.expect_value(t, sv.state, Save_State.Asking)
	attachments_step(c)
	_, asked := tc_one(t, &r.tc, .Attach_Get)
	testing.expect(t, asked)
}

// ---- previews ----

@(test)
test_which_files_are_previewed :: proc(t: ^testing.T) {
	testing.expect(t, preview_wanted("photo.png", 1000))
	testing.expect(t, preview_wanted("PHOTO.JPG", 1000))
	testing.expect(t, preview_wanted("a.b.jpeg", 1))
	for ext in ([]string{"gif", "bmp", "webp"}) {
		testing.expect(t, preview_wanted(strings.concatenate({"x.", ext}, context.temp_allocator), 10))
	}
	testing.expect(t, preview_wanted("big.png", PREVIEW_MAX))
	testing.expect(t, !preview_wanted("big.png", PREVIEW_MAX + 1))
	testing.expect(t, !preview_wanted("empty.png", 0))
	testing.expect(t, !preview_wanted("archive.zip", 100))
	testing.expect(t, !preview_wanted("noextension", 100))
	testing.expect(t, !preview_wanted("png", 100))
	testing.expect(t, !preview_wanted("photo.pngx", 100))
	testing.expect(t, !preview_wanted("", 100))
}

@(test)
test_previewing_a_picture :: proc(t: ^testing.T) {
	r: Rig
	_ = rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c
	data := content(proto.FILE_CHUNK_DATA + 30)
	with_file(&r, "photo.png", u64(len(data)), 800)

	attach_preview(c, {msg = 40, index = 0})
	sv := c.attach.previews[800]
	testing.expect(t, sv != nil)
	testing.expect(t, sv.memory)
	testing.expect_value(t, len(sv.data), len(data))
	// Asked for once, however often the UI asks.
	attach_preview(c, {msg = 40, index = 0})
	testing.expect_value(t, len(c.attach.previews), 1)
	attachments_step(c)
	req, ok := tc_one(t, &r.tc, .Attach_Get)
	testing.expect(t, ok)
	buf: [proto.ATTACH_GET_ANSWER_SIZE]u8
	tc_answer(&r.tc, req.id, .Ok, proto.encode_attach_get_answer(&buf, u64(len(data)), 15))
	testing.expect_value(t, sv.state, Save_State.Receiving)

	out: [proto.MAX_PAYLOAD_SIZE]u8
	for index in 0 ..< 2 {
		s, e := proto.file_chunk_range(u64(len(data)), u32(index))
		handle_download_chunk(c, proto.encode_transfer_chunk(out[:], .Download_Chunk, 15, u32(index), data[s:e]))
	}
	// The picture goes to the pictures that messages show, not to a file.
	fetch := c.blobs.cache[800] or_else nil
	testing.expect(t, fetch != nil && fetch.state == .Ready)
	testing.expect_value(t, len(c.attach.saves), 0)
	entries, _ := os.read_all_directory_by_path(r.dir, context.temp_allocator)
	testing.expect_value(t, len(entries), 0)
}

@(test)
test_previews_that_are_not_wanted :: proc(t: ^testing.T) {
	r: Rig
	_ = rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c
	tc_message_with_files(
		&r.tc,
		3,
		40,
		{
			{blob = 801, size = 100, name = "archive.zip"},
			{blob = 0, size = 100, name = "removed.png"},
			{blob = 802, size = PREVIEW_MAX + 1, name = "huge.png"},
			{blob = 803, size = 100, name = "ok.png"},
		},
	)
	for index in 0 ..< 4 {
		attach_preview(c, {msg = 40, index = index})
	}
	// Only the last is a picture that is there and small enough.
	testing.expect_value(t, len(c.attach.previews), 1)
	testing.expect(t, 803 in c.attach.previews)
	// Not a message of ours, not a file of it.
	attach_preview(c, {msg = 999, index = 0})
	attach_preview(c, {msg = 40, index = 4})
	attach_preview(c, {msg = 40, index = -1})
	testing.expect_value(t, len(c.attach.previews), 1)
}

@(test)
test_preview_failures :: proc(t: ^testing.T) {
	r: Rig
	v := rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c
	with_file(&r, "photo.png", 100, 800)
	attach_preview(c, {msg = 40, index = 0})
	attachments_step(c)
	req, _ := tc_one(t, &r.tc, .Attach_Get)
	count := v.notice.count
	// A picture that is gone is not worth telling the user about: it is only a preview.
	tc_answer(&r.tc, req.id, .Not_Found)
	testing.expect_value(t, c.attach.previews[800].state, Save_State.Failed)
	testing.expect_value(t, v.notice.count, count)
	// It is not asked for again.
	attach_preview(c, {msg = 40, index = 0})
	attachments_step(c)
	testing.expect_value(t, len(tc_sent(t, &r.tc)), 0)
}

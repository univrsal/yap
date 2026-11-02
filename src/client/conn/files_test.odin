#+build !wasi
package conn

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "client:settings"
import "common:proto"

// Tests of the files that are sent directly between two accounts (files.odin):
// offering, accepting and declining, and the chunks themselves, with real files
// in a folder of the test's own and the other end played by the test.

@(private = "file")
Rig :: struct {
	tc:  Test_Conn,
	dir: string, // the downloads folder, and where files to send are
}

@(private = "file")
rig_open :: proc(t: ^testing.T, r: ^Rig) {
	tc := &r.tc
	tc_open(tc)
	tc_connect(t, tc)
	c := &tc.c
	c.auth.me = 1
	c.auth.state = .Done
	tc_account(tc, 1, "bob", "Bob")
	tc_account(tc, 2, "alice", "Alice")
	base, _ := os.temp_directory(context.temp_allocator)
	dir, err := os.make_directory_temp(base, "yap-files-*", context.allocator)
	testing.expect(t, err == nil)
	r.dir = dir
	c.files.download_dir = strings.clone(dir)
	tc_dm_with(tc, 20, 1, 2)
	// Alice is here.
	tc_snapshot(tc, 1, 11, {{num = 11, account = 1}, {num = 12, account = 2}})
	_ = tc_datagrams(t, tc)
}

@(private = "file")
rig_close :: proc(r: ^Rig) {
	files_destroy(&r.tc.c)
	tc_close(&r.tc)
	os.remove_all(r.dir)
	delete(r.dir)
}

// content makes `n` bytes that differ from place to place.
@(private = "file")
content :: proc(n: int) -> []u8 {
	data := make([]u8, n, context.temp_allocator)
	for &b, i in data {
		b = u8(i * 31 + i / 251)
	}
	return data
}

@(private = "file")
write_file :: proc(t: ^testing.T, r: ^Rig, name: string, data: []u8) -> string {
	path, _ := os.join_path({r.dir, name}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(path, data) == nil)
	return path
}

@(private = "file")
read_file :: proc(path: string) -> (data: []u8, ok: bool) {
	d, err := os.read_entire_file(path, context.temp_allocator)
	return d, err == nil
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

// ---- pure ----

@(test)
test_transfer_rate :: proc(t: ^testing.T) {
	// The lowest of the two limits and the most there is; 0 is no limit.
	testing.expect_value(t, transfer_rate(0, 0), f32(FILE_MAX_RATE))
	testing.expect_value(t, transfer_rate(1000, 0), f32(1000))
	testing.expect_value(t, transfer_rate(0, 2000), f32(2000))
	testing.expect_value(t, transfer_rate(1000, 2000), f32(1000))
	testing.expect_value(t, transfer_rate(5000, 2000), f32(2000))
	testing.expect_value(t, transfer_rate(max(u32), max(u32)), f32(FILE_MAX_RATE))
}

@(test)
test_format_bytes :: proc(t: ^testing.T) {
	testing.expect_value(t, format_bytes(0), "0 bytes")
	testing.expect_value(t, format_bytes(1023), "1023 bytes")
	testing.expect_value(t, format_bytes(1024), "1 KB")
	testing.expect_value(t, format_bytes(1536), "2 KB")
	testing.expect_value(t, format_bytes(1 << 20), "1.0 MB")
	testing.expect_value(t, format_bytes(5 << 19), "2.5 MB")
	testing.expect_value(t, format_bytes(3 << 30), "3.00 GB")
}

@(test)
test_file_states :: proc(t: ^testing.T) {
	for s in File_State {
		over := s >= .Done
		testing.expectf(t, file_state_over(s) == over, "%v", s)
	}
	testing.expect(t, !file_state_over(.Transferring))
	testing.expect(t, file_state_over(.Elsewhere))
}

@(test)
test_transfer_limits_from_settings :: proc(t: ^testing.T) {
	s := settings.Settings {
		upload_limit   = 1.5,
		download_limit = 0,
	}
	l := transfer_limits_command(&s)
	testing.expect_value(t, l.upload, u32(1.5 * 1024 * 1024))
	testing.expect_value(t, l.download, u32(0))
	// The sliders' ends, and values outside of them.
	s.upload_limit, s.download_limit = 1000, -5
	l = transfer_limits_command(&s)
	testing.expect_value(t, l.upload, u32(settings.MAX_TRANSFER_LIMIT * 1024 * 1024))
	testing.expect_value(t, l.download, u32(0))
}

// ---- offering ----

@(test)
test_offer_refusals :: proc(t: ^testing.T) {
	context.logger = expected_errors() // the missing file is logged as an error
	r: Rig
	rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c
	good := write_file(t, &r, "photo.png", content(100))
	empty := write_file(t, &r, "empty.png", nil)
	exe := write_file(t, &r, "tool.exe", content(100))
	noext := write_file(t, &r, "README", content(100))

	// Nobody, ourselves, a stranger.
	offer_file(c, {path = strings.clone(good), name = strings.clone("nobody")})
	offer_file(c, {path = strings.clone(good), to = 1})
	offer_file(c, {path = strings.clone(good), name = strings.clone("bob")})
	// Somebody who isn't here: the file would have nowhere to go.
	tc_snapshot(&r.tc, 2, 11, {{num = 11, account = 1}})
	offer_file(c, {path = strings.clone(good), to = 2})
	tc_snapshot(&r.tc, 3, 11, {{num = 11, account = 1}, {num = 12, account = 2}})
	// Files of a kind that is not allowed, empty, or that isn't there.
	offer_file(c, {path = strings.clone(exe), to = 2})
	offer_file(c, {path = strings.clone(noext), to = 2})
	offer_file(c, {path = strings.clone(empty), to = 2})
	offer_file(c, {path = strings.clone("/nonexistent/missing.png"), to = 2})
	testing.expect_value(t, len(c.files.posting), 0)
	testing.expect_value(t, len(c.msgs.outbox), 0)
	testing.expect_value(t, len(c.files.transfers), 0)
}

@(test)
test_offer_is_posted_like_a_message :: proc(t: ^testing.T) {
	r: Rig
	rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c
	data := content(proto.FILE_CHUNK_DATA * 2 + 100)
	path := write_file(t, &r, "My Photo.png", data)

	offer_file(c, {path = strings.clone(path), name = strings.clone("alice")})
	testing.expect_value(t, len(c.files.posting), 1)
	testing.expect_value(t, len(c.msgs.outbox), 1)
	nonce := c.msgs.outbox[0].nonce
	testing.expect_value(t, c.msgs.outbox[0].kind, proto.Msg_Kind.File)
	testing.expect_value(t, c.msgs.outbox[0].size, u64(len(data)))
	testing.expect_value(t, c.msgs.outbox[0].text, "My Photo.png")
	t0, found := c.files.posting[nonce]
	testing.expect(t, found)
	testing.expect_value(t, t0.state, File_State.Posting)
	testing.expect(t, t0.outgoing)
	testing.expect_value(t, t0.peer, proto.Account_Id(2))

	drive_outbox(c)
	req, ok := tc_one(t, &r.tc, .Msg_Post)
	testing.expect(t, ok)
	post, dec := proto.decode_msg_post(req.body)
	testing.expect(t, dec)
	testing.expect_value(t, post.kind, proto.Msg_Kind.File)
	testing.expect_value(t, post.file_size, u64(len(data)))
	testing.expect_value(t, post.conv, proto.Conv_Id(20))

	// Posted: from now on the transfer goes by the offer's message id.
	buf: [proto.MSG_POSTED_SIZE]u8
	tc_answer(&r.tc, req.id, .Ok, proto.encode_msg_posted(&buf, 500, 1000))
	testing.expect_value(t, len(c.files.posting), 0)
	offer, has := c.files.transfers[500]
	testing.expect(t, has)
	testing.expect_value(t, offer.state, File_State.Offered)
}

@(test)
test_offer_that_cannot_be_posted :: proc(t: ^testing.T) {
	r: Rig
	rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c
	path := write_file(t, &r, "photo.png", content(100))

	offer_file(c, {path = strings.clone(path), to = 2})
	drive_outbox(c)
	req, _ := tc_one(t, &r.tc, .Msg_Post)
	// Refused: there is nothing to send the file for, and it is let go.
	tc_answer(&r.tc, req.id, .Denied)
	testing.expect_value(t, len(c.files.posting), 0)
	testing.expect_value(t, len(c.files.transfers), 0)
	testing.expect_value(t, len(c.msgs.outbox), 0)
}

// ---- sending ----

// offer_file makes an offer and frees the command, as process_commands does.
@(private = "file")
offer_file :: proc(c: ^Server_Conn, cmd: Send_File_Command) {
	send_file(c, cmd)
	command_destroy(cmd)
}

// offered makes an offer and gets it posted as message `id`.
@(private = "file")
offered :: proc(t: ^testing.T, r: ^Rig, name: string, data: []u8, id: proto.Msg_Id) -> ^File_Transfer {
	c := &r.tc.c
	path := write_file(t, r, name, data)
	offer_file(c, {path = strings.clone(path), to = 2})
	drive_outbox(c)
	req, _ := tc_one(t, &r.tc, .Msg_Post)
	buf: [proto.MSG_POSTED_SIZE]u8
	tc_answer(&r.tc, req.id, .Ok, proto.encode_msg_posted(&buf, id, 1000))
	return c.files.transfers[id]
}

// accept gives the client the other side's acceptance of an offer.
@(private = "file")
accept :: proc(tc: ^Test_Conn, id: proto.Msg_Id, from: proto.Account_Id, rate: u32 = 0) {
	buf: [proto.FILE_ACCEPT_SIZE]u8
	handle_file_accept(&tc.c, proto.encode_file_accept(&buf, id, from, rate))
}

@(test)
test_sending_a_file :: proc(t: ^testing.T) {
	r: Rig
	rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c
	data := content(proto.FILE_CHUNK_DATA * 2 + 100)
	offer := offered(t, &r, "photo.png", data, 500)

	// Nothing is sent before they accept.
	files_step(c)
	testing.expect_value(t, len(of_kind(t, &r.tc, .File_Chunk)), 0)

	// Somebody else's acceptance, or of an offer we never made, is not one.
	accept(&r.tc, 500, 3)
	accept(&r.tc, 999, 2)
	testing.expect_value(t, offer.state, File_State.Offered)
	cancels := of_kind(t, &r.tc, .File_Cancel)
	testing.expect_value(t, len(cancels), 2) // both told that there is nothing to send

	accept(&r.tc, 500, 2)
	testing.expect_value(t, offer.state, File_State.Transferring)
	// Accepting again changes nothing.
	accept(&r.tc, 500, 2)
	testing.expect_value(t, offer.state, File_State.Transferring)

	// Sending is paced. With a limit this low a turn sends one chunk however long
	// it has been (the bucket holds one chunk at most), and what is in it is set
	// here so that the test does not depend on how long it takes to run.
	c.files.upload_limit = 1
	chunks := make([dynamic][]u8, context.temp_allocator)
	for _ in 0 ..< 3 {
		offer.send.pace.tokens = 1
		files_step(c)
		got := of_kind(t, &r.tc, .File_Chunk)
		testing.expect_value(t, len(got), 1)
		append(&chunks, ..got)
	}

	// Together the chunks are the file.
	rebuilt := make([]u8, len(data), context.temp_allocator)
	recv: proto.Transfer_Receiver
	proto.transfer_receiver_init(&recv, u64(len(data)))
	defer proto.transfer_receiver_destroy(&recv)
	for d in chunks {
		id, index, part := proto.decode_transfer_chunk(d)
		testing.expect_value(t, id, u64(500))
		start, _ := proto.file_chunk_range(u64(len(data)), index)
		testing.expect(t, proto.transfer_wants(&recv, index, len(part)))
		copy(rebuilt[start:], part)
		proto.transfer_got(&recv, index, len(part))
	}
	testing.expect_value(t, string(rebuilt), string(data))

	// When they say they have it all, the transfer is done and the file closed.
	out: [proto.MAX_PAYLOAD_SIZE]u8
	ack := proto.transfer_encode_ack(&recv, out[:], .File_Ack, 500, 0, time.tick_now())
	handle_file_ack(c, ack)
	testing.expect_value(t, offer.state, File_State.Done)
	testing.expect_value(t, offer.done, u64(len(data)))
	// Later acks, and chunks for a finished transfer, change nothing.
	handle_file_ack(c, ack)
	testing.expect_value(t, offer.state, File_State.Done)
}

@(test)
test_sending_is_paced_by_their_limit :: proc(t: ^testing.T) {
	r: Rig
	rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c
	data := content(proto.FILE_CHUNK_DATA * 40)
	slow := offered(t, &r, "slow.zip", data, 600)
	fast := offered(t, &r, "fast.zip", data, 601)

	// A receiver that takes very little gets about a chunk, however much there
	// is to spend; one without a limit gets a good part of the file.
	accept(&r.tc, 600, 2, 1000)
	testing.expect_value(t, slow.send.peer_rate, u32(1000))
	slow.send.pace.tokens = FILE_BURST
	files_step(c)
	few := len(of_kind(t, &r.tc, .File_Chunk))
	testing.expect(t, few >= 1 && few <= 2, "a receiver that asked for 1 kB/s was sent a burst")

	files_destroy_one(c, 600)
	accept(&r.tc, 601, 2, 0)
	fast.send.pace.tokens = FILE_BURST
	files_step(c)
	many := len(of_kind(t, &r.tc, .File_Chunk))
	testing.expect_value(t, many, 40)
}

// files_destroy_one ends a transfer so that it doesn't take part in the next turn.
@(private = "file")
files_destroy_one :: proc(c: ^Server_Conn, id: proto.Msg_Id) {
	t := c.files.transfers[id] or_else nil
	if t != nil {
		file_action(c, id, .Cancel)
	}
}

@(test)
test_sending_stops_when_they_cancel :: proc(t: ^testing.T) {
	Case :: struct {
		reason: proto.File_Cancel_Reason,
		state:  File_State,
	}
	for k in ([]Case {
			{.Declined, .Declined},
			{.Cancelled, .Cancelled},
			{.Gone, .Interrupted},
			{.Expired, .Expired},
			{.Elsewhere, .Elsewhere},
			{.Failed, .Failed},
		}) {
		r: Rig
		rig_open(t, &r)
		defer rig_close(&r)
		c := &r.tc.c
		offer := offered(t, &r, "photo.png", content(100), 500)

		// From someone else it is not about this transfer.
		buf: [proto.FILE_CANCEL_SIZE]u8
		handle_file_cancel(c, proto.encode_file_cancel(&buf, 500, 3, k.reason))
		testing.expect_value(t, offer.state, File_State.Offered)
		handle_file_cancel(c, proto.encode_file_cancel(&buf, 500, 2, k.reason))
		testing.expectf(t, offer.state == k.state, "%v: %v", k.reason, offer.state)
		// Once over it stays so.
		handle_file_cancel(c, proto.encode_file_cancel(&buf, 500, 2, .Cancelled))
		testing.expectf(t, offer.state == k.state, "%v: changed to %v", k.reason, offer.state)
	}
}

@(test)
test_we_can_cancel_our_offer :: proc(t: ^testing.T) {
	r: Rig
	rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c
	offer := offered(t, &r, "photo.png", content(100), 500)
	_ = tc_datagrams(t, &r.tc)

	// Accepting or declining are for the one who was offered the file.
	file_action(c, 500, .Accept)
	file_action(c, 500, .Decline)
	testing.expect_value(t, offer.state, File_State.Offered)
	file_action(c, 500, .Cancel)
	testing.expect_value(t, offer.state, File_State.Cancelled)
	cancels := of_kind(t, &r.tc, .File_Cancel)
	testing.expect_value(t, len(cancels), 1)
	if len(cancels) == 1 {
		id, to, reason := proto.decode_file_cancel(cancels[0])
		testing.expect_value(t, id, proto.Msg_Id(500))
		testing.expect_value(t, to, proto.Account_Id(2))
		testing.expect_value(t, reason, proto.File_Cancel_Reason.Cancelled)
	}
	// Nothing more to cancel, and an unknown id is nothing.
	file_action(c, 500, .Cancel)
	file_action(c, 12345, .Cancel)
	testing.expect_value(t, len(of_kind(t, &r.tc, .File_Cancel)), 0)
}

@(test)
test_transfer_ends_when_the_other_side_goes :: proc(t: ^testing.T) {
	r: Rig
	rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c
	offer := offered(t, &r, "photo.png", content(100), 500)
	accept(&r.tc, 500, 2)
	testing.expect_value(t, offer.state, File_State.Transferring)

	// Alice goes offline: the transfer is interrupted, quietly.
	tc_snapshot(&r.tc, 5, 11, {{num = 11, account = 1}})
	_ = tc_datagrams(t, &r.tc)
	files_step(c)
	testing.expect_value(t, offer.state, File_State.Interrupted)
	testing.expect_value(t, len(of_kind(t, &r.tc, .File_Cancel)), 0)
}

@(test)
test_transfer_ends_when_the_other_side_is_silent :: proc(t: ^testing.T) {
	r: Rig
	rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c
	offer := offered(t, &r, "photo.png", content(100), 500)
	accept(&r.tc, 500, 2)
	_ = tc_datagrams(t, &r.tc)

	// Quiet for a little is fine; for too long is a failure, which they are told.
	offer.last_heard = time.tick_add(time.tick_now(), -(FILE_TIMEOUT / 2))
	files_step(c)
	testing.expect_value(t, offer.state, File_State.Transferring)
	offer.last_heard = time.tick_add(time.tick_now(), -(FILE_TIMEOUT + time.Second))
	files_step(c)
	testing.expect_value(t, offer.state, File_State.Failed)
	cancels := of_kind(t, &r.tc, .File_Cancel)
	testing.expect_value(t, len(cancels), 1)
	if len(cancels) == 1 {
		_, _, reason := proto.decode_file_cancel(cancels[0])
		testing.expect_value(t, reason, proto.File_Cancel_Reason.Failed)
	}
}

// ---- receiving ----

@(private = "file")
offer_message :: proc(id: proto.Msg_Id, name: string, size: u64) -> proto.Message {
	return {id = id, conv = 20, sender = 2, kind = .File, file_name = name, file_size = size}
}

@(test)
test_incoming_offer_is_checked :: proc(t: ^testing.T) {
	r: Rig
	rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c

	file_offer_received(c, offer_message(700, "holiday.png", 5000))
	offer := c.files.transfers[700]
	testing.expect_value(t, offer.state, File_State.Incoming)
	testing.expect_value(t, offer.name, "holiday.png")
	testing.expect_value(t, offer.size, u64(5000))
	testing.expect_value(t, offer.peer, proto.Account_Id(2))
	testing.expect(t, !offer.outgoing)
	testing.expect_value(t, len(of_kind(t, &r.tc, .File_Cancel)), 0)

	// The same offer again (history, or a second device) is not a second offer.
	file_offer_received(c, offer_message(700, "other.png", 1))
	testing.expect_value(t, c.files.transfers[700].name, "holiday.png")
	testing.expect_value(t, len(c.files.transfers), 1)

	// What we would not save is declined straight away, and they are told.
	for bad, i in ([]proto.Message {
			offer_message(701, "tool.exe", 100),
			offer_message(702, "noextension", 100),
			offer_message(703, "photo.png", 0),
			offer_message(704, "photo.png", proto.MAX_FILE_SIZE + 1),
			offer_message(705, "", 100),
		}) {
		file_offer_received(c, bad)
		testing.expectf(t, c.files.transfers[bad.id].state == .Declined, "%q: %v", bad.file_name, c.files.transfers[bad.id].state)
		got := of_kind(t, &r.tc, .File_Cancel)
		testing.expectf(t, len(got) == 1, "%q: %d cancels", bad.file_name, len(got))
		if len(got) == 1 {
			_, to, reason := proto.decode_file_cancel(got[0])
			testing.expect_value(t, to, proto.Account_Id(2))
			testing.expect_value(t, reason, proto.File_Cancel_Reason.Declined)
		}
		_ = i
	}

	// The name it came with cannot take the file out of the downloads folder.
	file_offer_received(c, offer_message(710, "../../etc/evil.zip", 100))
	testing.expect_value(t, c.files.transfers[710].name, "evil.zip")
}

@(test)
test_receiving_a_file :: proc(t: ^testing.T) {
	r: Rig
	rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c
	data := content(proto.FILE_CHUNK_DATA * 2 + 100)
	file_offer_received(c, offer_message(700, "holiday.png", u64(len(data))))
	offer := c.files.transfers[700]

	// Chunks before it was accepted are not taken.
	out: [proto.MAX_PAYLOAD_SIZE]u8
	start, end := proto.file_chunk_range(u64(len(data)), 0)
	handle_file_chunk(c, proto.encode_transfer_chunk(out[:], .File_Chunk, 700, 0, data[start:end]))
	testing.expect_value(t, offer.state, File_State.Incoming)

	file_action(c, 700, .Accept)
	testing.expect_value(t, offer.state, File_State.Starting)
	final := offer.path
	testing.expect(t, strings.has_prefix(final, r.dir))
	testing.expect(t, strings.has_suffix(final, "holiday.png"))
	part := strings.concatenate({final, ".part"}, context.temp_allocator)
	testing.expect(t, os.exists(part), "no partial file while receiving")
	testing.expect(t, !os.exists(final), "the file has its final name before it is complete")

	// Until chunks arrive, the sender is asked for them.
	files_step(c)
	accepts := of_kind(t, &r.tc, .File_Accept)
	testing.expect_value(t, len(accepts), 1)
	if len(accepts) == 1 {
		id, from, _ := proto.decode_file_accept(accepts[0])
		testing.expect_value(t, id, proto.Msg_Id(700))
		testing.expect_value(t, from, proto.Account_Id(2))
	}

	// Chunks in any order; a repeated one and a broken one are skipped.
	chunk :: proc(out: []u8, id: u64, data: []u8, index: u32) -> []u8 {
		s, e := proto.file_chunk_range(u64(len(data)), index)
		return proto.encode_transfer_chunk(out, .File_Chunk, id, index, data[s:e])
	}
	handle_file_chunk(c, chunk(out[:], 700, data, 2))
	testing.expect_value(t, offer.state, File_State.Transferring)
	handle_file_chunk(c, chunk(out[:], 700, data, 2))
	handle_file_chunk(c, proto.encode_transfer_chunk(out[:], .File_Chunk, 700, 1, data[:10]))
	handle_file_chunk(c, proto.encode_transfer_chunk(out[:], .File_Chunk, 700, 99, data[:10]))
	testing.expect_value(t, offer.done, u64(100))
	handle_file_chunk(c, chunk(out[:], 700, data, 0))
	testing.expect_value(t, offer.state, File_State.Transferring)
	handle_file_chunk(c, chunk(out[:], 700, data, 1))

	testing.expect_value(t, offer.state, File_State.Done)
	testing.expect(t, os.exists(final))
	testing.expect(t, !os.exists(part), "the partial file is left behind")
	saved, ok := read_file(final)
	testing.expect(t, ok)
	testing.expect_value(t, string(saved), string(data))

	// The sender is told that it is complete.
	acks := of_kind(t, &r.tc, .File_Ack)
	testing.expect(t, len(acks) >= 1)
	if len(acks) >= 1 {
		ack, _, _, dec := proto.decode_transfer_ack(acks[len(acks) - 1])
		testing.expect(t, dec && ack.complete)
		testing.expect_value(t, ack.id, u64(700))
	}
}

@(test)
test_received_files_do_not_overwrite :: proc(t: ^testing.T) {
	r: Rig
	rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c
	write_file(t, &r, "photo.png", content(10))

	file_offer_received(c, offer_message(700, "photo.png", 50))
	file_offer_received(c, offer_message(701, "photo.png", 50))
	file_action(c, 700, .Accept)
	file_action(c, 701, .Accept)
	testing.expect(t, strings.has_suffix(c.files.transfers[700].path, "photo (1).png"))
	testing.expect(t, strings.has_suffix(c.files.transfers[701].path, "photo (2).png"))
	// The file that was there is still there.
	existing, ok := read_file(strings.concatenate({r.dir, "/photo.png"}, context.temp_allocator))
	testing.expect(t, ok)
	testing.expect_value(t, len(existing), 10)
}

@(test)
test_declining_and_cancelling_a_received_file :: proc(t: ^testing.T) {
	r: Rig
	rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c

	file_offer_received(c, offer_message(700, "a.png", 5000))
	file_action(c, 700, .Decline)
	testing.expect_value(t, c.files.transfers[700].state, File_State.Declined)
	cancels := of_kind(t, &r.tc, .File_Cancel)
	testing.expect_value(t, len(cancels), 1)
	if len(cancels) == 1 {
		_, _, reason := proto.decode_file_cancel(cancels[0])
		testing.expect_value(t, reason, proto.File_Cancel_Reason.Declined)
	}
	// Declined is declined: it can't be accepted afterwards.
	file_action(c, 700, .Accept)
	testing.expect_value(t, c.files.transfers[700].state, File_State.Declined)

	// Cancelling one that was accepted throws away what has arrived.
	file_offer_received(c, offer_message(701, "b.png", 5000))
	file_action(c, 701, .Accept)
	offer := c.files.transfers[701]
	part := strings.concatenate({offer.path, ".part"}, context.temp_allocator)
	testing.expect(t, os.exists(part))
	file_action(c, 701, .Cancel)
	testing.expect_value(t, offer.state, File_State.Cancelled)
	testing.expect(t, !os.exists(part), "a cancelled transfer left a partial file")
	testing.expect(t, !os.exists(offer.path))
}

@(test)
test_offer_deleted_before_it_was_answered :: proc(t: ^testing.T) {
	r: Rig
	rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c
	file_offer_received(c, offer_message(700, "a.png", 5000))
	file_offer_deleted(c, 700)
	testing.expect_value(t, c.files.transfers[700].state, File_State.Expired)

	// One that is being received is not stopped by its message going.
	file_offer_received(c, offer_message(701, "b.png", 5000))
	file_action(c, 701, .Accept)
	file_offer_deleted(c, 701)
	testing.expect_value(t, c.files.transfers[701].state, File_State.Starting)
	file_offer_deleted(c, 999)
}

@(test)
test_sender_cancels_a_received_file :: proc(t: ^testing.T) {
	r: Rig
	rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c
	file_offer_received(c, offer_message(700, "a.png", 5000))
	file_action(c, 700, .Accept)
	offer := c.files.transfers[700]
	part := strings.concatenate({offer.path, ".part"}, context.temp_allocator)

	buf: [proto.FILE_CANCEL_SIZE]u8
	handle_file_cancel(c, proto.encode_file_cancel(&buf, 700, 2, .Gone))
	testing.expect_value(t, offer.state, File_State.Interrupted)
	testing.expect(t, !os.exists(part))
}

@(test)
test_received_file_that_goes_quiet :: proc(t: ^testing.T) {
	r: Rig
	rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c
	file_offer_received(c, offer_message(700, "a.png", 5000))
	file_action(c, 700, .Accept)
	offer := c.files.transfers[700]
	_ = tc_datagrams(t, &r.tc)

	offer.last_heard = time.tick_add(time.tick_now(), -(FILE_TIMEOUT + time.Second))
	files_step(c)
	testing.expect_value(t, offer.state, File_State.Failed)
	got := of_kind(t, &r.tc, .File_Cancel)
	testing.expect_value(t, len(got), 1)
	// The partial file is thrown away.
	testing.expect(t, !os.exists(strings.concatenate({offer.path, ".part"}, context.temp_allocator)))
}

@(test)
test_complete_acks_are_repeated :: proc(t: ^testing.T) {
	r: Rig
	rig_open(t, &r)
	defer rig_close(&r)
	c := &r.tc.c
	data := content(300)
	file_offer_received(c, offer_message(700, "a.png", u64(len(data))))
	file_action(c, 700, .Accept)
	out: [proto.MAX_PAYLOAD_SIZE]u8
	handle_file_chunk(c, proto.encode_transfer_chunk(out[:], .File_Chunk, 700, 0, data))
	offer := c.files.transfers[700]
	testing.expect_value(t, offer.state, File_State.Done)
	_ = tc_datagrams(t, &r.tc)

	// In case the first ack was lost it is said again, a few times and not forever.
	for _ in 0 ..< 10 {
		offer.recv.last_ack = time.tick_add(time.tick_now(), -time.Second)
		files_step(c)
	}
	testing.expect_value(t, len(of_kind(t, &r.tc, .File_Ack)), proto.TRANSFER_COMPLETE_ACKS - 1)
}

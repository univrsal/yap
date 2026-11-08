#+build !wasi
package conn

import "core:crypto/hash"
import "core:strings"
import "core:testing"
import "core:time"

import "common:proto"

// Tests of uploading our own pictures (picture_upload.odin): announcing a
// picture, sending its chunks, handling what the server says about them, and
// setting the avatar or the server's picture once the server has it.

@(private = "file")
open_pictures :: proc(t: ^testing.T, tc: ^Test_Conn) -> ^View {
	tc_open(tc)
	tc_connect(t, tc)
	tc.c.auth.me = 1
	tc.c.auth.state = .Done
	return tc_view(tc)
}

@(private = "file")
jpeg :: proc(size: int) -> []u8 {
	data := make([]u8, size)
	for &b, i in data {
		b = u8(i * 13 + i / 97)
	}
	return data
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

// announced makes the server answer the Blob_Put with the handle to send under.
@(private = "file")
announced :: proc(t: ^testing.T, tc: ^Test_Conn, handle: u64) -> Test_Request {
	drive_pictures(&tc.c)
	r, _ := tc_one(t, tc, .Blob_Put)
	buf: [proto.BLOB_PUT_ANSWER_SIZE]u8
	tc_answer(tc, r.id, .Ok, proto.encode_blob_put_answer(&buf, 0, false, handle))
	return r
}

@(test)
test_picture_is_queued :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_pictures(t, &tc)
	defer tc_close(&tc)
	defer blobs_destroy(&tc.c)
	c := &tc.c

	data := jpeg(300)
	picture_upload(c, {jpeg = data, width = 64, height = 48})
	testing.expect_value(t, len(c.blobs.pictures), 1)
	p := &c.blobs.pictures[0]
	testing.expect_value(t, p.state, Picture_State.Put)
	testing.expect(t, !p.server)
	testing.expect(t, p.tag != 0)
	// It is announced as what it is: its size, dimensions and a hash of it.
	testing.expect_value(t, p.put.kind, proto.Blob_Kind.Avatar)
	testing.expect_value(t, p.put.size, 300)
	testing.expect_value(t, p.put.width, 64)
	testing.expect_value(t, p.put.height, 48)
	want: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, data, want[:])
	testing.expect_value(t, p.put.hash, want)
	testing.expect(t, v.uploading.avatar && !v.uploading.server)

	// The server's picture is shown as such; names go with it.
	picture_upload(
		c,
		{jpeg = jpeg(100), width = 32, height = 32},
		server = true,
		name = strings.clone("N"),
		about = strings.clone("A"),
	)
	testing.expect(t, v.uploading.avatar && v.uploading.server)
	testing.expect(t, c.blobs.pictures[1].server)
	testing.expect(t, c.blobs.pictures[1].tag != p.tag)

	// Done with the first, the other is next, and the indicator follows.
	picture_done(c)
	testing.expect_value(t, len(c.blobs.pictures), 1)
	testing.expect(t, !v.uploading.avatar && v.uploading.server)
	picture_done(c)
	testing.expect(t, !v.uploading.avatar && !v.uploading.server)
}

@(test)
test_pictures_wait_for_the_connection :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_pictures(t, &tc)
	defer tc_close(&tc)
	defer blobs_destroy(&tc.c)
	c := &tc.c
	picture_upload(c, {jpeg = jpeg(100), width = 10, height = 10})

	// Not before the connection has synced, or without a session.
	c.convs.synced = false
	drive_pictures(c)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	c.convs.synced = true
	c.has_current = false
	drive_pictures(c)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	c.has_current = true

	// Announced once, however often it is driven.
	drive_pictures(c)
	drive_pictures(c)
	req, ok := tc_one(t, &tc, .Blob_Put)
	testing.expect(t, ok)
	// Nothing queued does nothing.
	picture_done(c)
	drive_pictures(c)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	_ = req
}

@(test)
test_picture_the_server_already_has :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_pictures(t, &tc)
	defer tc_close(&tc)
	defer blobs_destroy(&tc.c)
	c := &tc.c
	picture_upload(c, {jpeg = jpeg(100), width = 10, height = 10})
	drive_pictures(c)
	req, _ := tc_one(t, &tc, .Blob_Put)
	put, dec := proto.decode_blob_put(req.body)
	testing.expect(t, dec)
	testing.expect_value(t, put.size, 100)

	// It has it: no upload, the avatar is set to it.
	buf: [proto.BLOB_PUT_ANSWER_SIZE]u8
	tc_answer(&tc, req.id, .Ok, proto.encode_blob_put_answer(&buf, 555, true, 0))
	testing.expect_value(t, c.blobs.pictures[0].state, Picture_State.Set)
	testing.expect_value(t, c.blobs.pictures[0].blob, proto.Blob_Id(555))
	drive_pictures(c)
	set, ok := tc_one(t, &tc, .Profile_Set)
	testing.expect(t, ok)
	profile, prof_ok := proto.decode_profile_set(set.body)
	testing.expect(t, prof_ok)
	testing.expect_value(t, profile.mask, u8(proto.PROFILE_AVATAR))
	testing.expect_value(t, profile.avatar, proto.Blob_Id(555))
	// Asked for once.
	drive_pictures(c)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)

	// Once set, the picture is ours to show at once and the queue is empty.
	tc_answer(&tc, set.id, .Ok)
	testing.expect_value(t, len(c.blobs.pictures), 0)
	fetch := c.blobs.cache[555] or_else nil
	testing.expect(t, fetch != nil && fetch.state == .Ready)
	testing.expect(t, !v.uploading.avatar)
}

@(test)
test_server_picture_is_set_with_its_details :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_pictures(t, &tc)
	defer tc_close(&tc)
	defer blobs_destroy(&tc.c)
	c := &tc.c
	picture_upload(
		c,
		{jpeg = jpeg(100), width = 32, height = 32},
		server = true,
		name = strings.clone("Name"),
		about = strings.clone("About"),
	)
	drive_pictures(c)
	req, _ := tc_one(t, &tc, .Blob_Put)
	buf: [proto.BLOB_PUT_ANSWER_SIZE]u8
	tc_answer(&tc, req.id, .Ok, proto.encode_blob_put_answer(&buf, 66, true, 0))
	drive_pictures(c)
	set, ok := tc_one(t, &tc, .Server_Info_Set)
	testing.expect(t, ok)
	info, dec := proto.decode_server_info_set(set.body)
	testing.expect(t, dec)
	testing.expect_value(t, info.name, "Name")
	testing.expect_value(t, info.description, "About")
	testing.expect_value(t, info.icon, proto.Blob_Id(66))
}

@(test)
test_announcing_is_refused :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_pictures(t, &tc)
	defer tc_close(&tc)
	defer blobs_destroy(&tc.c)
	c := &tc.c
	picture_upload(c, {jpeg = jpeg(100), width = 10, height = 10})
	drive_pictures(c)
	req, _ := tc_one(t, &tc, .Blob_Put)

	// A body that can't be read keeps it waiting; a lost connection asks again.
	tc_answer(&tc, req.id, .Ok, []u8{1, 2, 3})
	testing.expect_value(t, len(c.blobs.pictures), 1)
	testing.expect(t, !c.blobs.pictures[0].asking)
	drive_pictures(c)
	req, _ = tc_one(t, &tc, .Blob_Put)
	tc_restart(&tc)
	testing.expect_value(t, len(c.blobs.pictures), 1)

	// A refusal drops the picture and says so.
	drive_pictures(c)
	req, _ = tc_one(t, &tc, .Blob_Put)
	tc_answer(&tc, req.id, .Too_Large)
	testing.expect_value(t, len(c.blobs.pictures), 0)
	testing.expect_value(t, v.notice.text, "The server refused to accept the picture.")
	testing.expect(t, !v.notice.ok)

	// An answer for a picture that is no longer at the head is not for the next one.
	picture_upload(c, {jpeg = jpeg(100), width = 10, height = 10})
	drive_pictures(c)
	req, _ = tc_one(t, &tc, .Blob_Put)
	picture_done(c)
	picture_upload(c, {jpeg = jpeg(100), width = 10, height = 10})
	buf: [proto.BLOB_PUT_ANSWER_SIZE]u8
	tc_answer(&tc, req.id, .Ok, proto.encode_blob_put_answer(&buf, 7, true, 0))
	testing.expect_value(t, c.blobs.pictures[0].state, Picture_State.Put)
}

@(test)
test_picture_is_sent_in_chunks :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_pictures(t, &tc)
	defer tc_close(&tc)
	defer blobs_destroy(&tc.c)
	c := &tc.c
	data := jpeg(proto.BLOB_CHUNK_SIZE * 3 + 10)
	picture_upload(c, {jpeg = data, width = 64, height = 64})
	_ = announced(t, &tc, 4711)
	p := &c.blobs.pictures[0]
	testing.expect_value(t, p.state, Picture_State.Upload)
	testing.expect_value(t, p.upload.handle, u64(4711))

	// Sending is paced; the pace is topped up here as time would, until all is sent.
	rebuilt := make([]u8, len(data), context.temp_allocator)
	seen := make(map[int]bool, 4, context.temp_allocator)
	for _ in 0 ..< 10 {
		p.upload.pace.tokens = proto.BLOB_CHUNK_SIZE
		drive_pictures(c)
		for d in of_kind(t, &tc, .Blob_Chunk) {
			handle, index, part := proto.decode_blob_chunk(d)
			testing.expect_value(t, handle, u64(4711))
			start, end := proto.blob_chunk_range(len(data), index)
			testing.expect_value(t, len(part), end - start)
			copy(rebuilt[start:], part)
			seen[index] = true
		}
	}
	testing.expect_value(t, len(seen), 4)
	testing.expect_value(t, string(rebuilt), string(data))
	testing.expect(t, proto.blob_sender_idle(&p.upload.send))
}

@(private = "file")
need :: proc(handle: u64, complete: bool, missing: []u16, failed := false) -> []u8 {
	out := make([]u8, proto.MAX_PAYLOAD_SIZE, context.temp_allocator)
	msg, _ := proto.encode_blob_need(out, handle, complete, missing, failed)
	return msg
}

@(private = "file")
uploading :: proc(t: ^testing.T, tc: ^Test_Conn, size: int) -> ^Picture_Up {
	picture_upload(&tc.c, {jpeg = jpeg(size), width = 64, height = 64})
	_ = announced(t, tc, 99)
	return &tc.c.blobs.pictures[0]
}

@(test)
test_server_says_what_is_missing :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_pictures(t, &tc)
	defer tc_close(&tc)
	defer blobs_destroy(&tc.c)
	c := &tc.c
	p := uploading(t, &tc, proto.BLOB_CHUNK_SIZE * 3 + 10)

	// During the first pass what is missing is just not here yet.
	testing.expect(t, upload_need(c, need(99, false, {1})))
	testing.expect_value(t, len(p.upload.send.resend), 0)
	// After it, the chunks it names are sent again.
	for _ in 0 ..< 10 {
		p.upload.pace.tokens = proto.BLOB_CHUNK_SIZE
		drive_pictures(c)
	}
	_ = tc_datagrams(t, &tc)
	testing.expect(t, upload_need(c, need(99, false, {1, 3})))
	p.upload.pace.tokens = proto.BLOB_CHUNK_SIZE * 4
	drive_pictures(c)
	resent := of_kind(t, &tc, .Blob_Chunk)
	testing.expect_value(t, len(resent), 2)
	if len(resent) == 2 {
		_, first, _ := proto.decode_blob_chunk(resent[0])
		_, second, _ := proto.decode_blob_chunk(resent[1])
		testing.expect_value(t, first, 1)
		testing.expect_value(t, second, 3)
	}
}

@(test)
test_complete_upload_is_announced_again :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_pictures(t, &tc)
	defer tc_close(&tc)
	defer blobs_destroy(&tc.c)
	c := &tc.c
	p := uploading(t, &tc, 500)

	// Everything has arrived: announcing it again gets us its id.
	testing.expect(t, upload_need(c, need(99, true, nil)))
	testing.expect_value(t, p.state, Picture_State.Put)
	testing.expect(t, !p.asking)
	drive_pictures(c)
	req, ok := tc_one(t, &tc, .Blob_Put)
	testing.expect(t, ok)
	buf: [proto.BLOB_PUT_ANSWER_SIZE]u8
	tc_answer(&tc, req.id, .Ok, proto.encode_blob_put_answer(&buf, 321, true, 0))
	testing.expect_value(t, p.state, Picture_State.Set)
	testing.expect_value(t, p.blob, proto.Blob_Id(321))
}

@(test)
test_upload_is_rejected_by_the_server :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_pictures(t, &tc)
	defer tc_close(&tc)
	defer blobs_destroy(&tc.c)
	c := &tc.c
	_ = uploading(t, &tc, 500)

	// It is sent again twice, then given up on.
	for try in 1 ..< UPLOAD_TRIES {
		testing.expect(t, upload_need(c, need(99, false, nil, failed = true)))
		testing.expect_value(t, len(c.blobs.pictures), 1)
		testing.expect_value(t, c.blobs.pictures[0].tries, try)
		testing.expect_value(t, c.blobs.pictures[0].state, Picture_State.Put)
		drive_pictures(c)
		_ = announced_again(t, &tc)
	}
	testing.expect(t, upload_need(c, need(99, false, nil, failed = true)))
	testing.expect_value(t, len(c.blobs.pictures), 0)
	testing.expect_value(
		t,
		v.notice.text,
		"A picture couldn't be sent because the server rejected the upload.",
	)
}

// announced_again answers the Blob_Put that is pending with the same handle.
@(private = "file")
announced_again :: proc(t: ^testing.T, tc: ^Test_Conn) -> Test_Request {
	r, _ := tc_one(t, tc, .Blob_Put)
	buf: [proto.BLOB_PUT_ANSWER_SIZE]u8
	tc_answer(tc, r.id, .Ok, proto.encode_blob_put_answer(&buf, 0, false, 99))
	return r
}

@(test)
test_need_for_something_else :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_pictures(t, &tc)
	defer tc_close(&tc)
	defer blobs_destroy(&tc.c)
	c := &tc.c

	// Nothing is being uploaded: the packet is somebody else's (a download).
	testing.expect(t, !upload_need(c, need(99, true, nil)))
	p := uploading(t, &tc, 500)
	// A different handle, a short packet, garbage.
	testing.expect(t, !upload_need(c, need(100, true, nil)))
	testing.expect(t, !upload_need(c, []u8{1, 2, 3}))
	testing.expect(t, !upload_need(c, nil))
	testing.expect_value(t, p.state, Picture_State.Upload)
	// Not while the picture is not being uploaded.
	p.state = .Set
	testing.expect(t, !upload_need(c, need(99, true, nil)))
}

@(test)
test_quiet_upload_is_announced_again :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_pictures(t, &tc)
	defer tc_close(&tc)
	defer blobs_destroy(&tc.c)
	c := &tc.c
	p := uploading(t, &tc, 500)
	// Send it all, then wait.
	for _ in 0 ..< 3 {
		p.upload.pace.tokens = proto.BLOB_CHUNK_SIZE
		drive_pictures(c)
	}
	_ = tc_datagrams(t, &tc)
	p.upload.last_heard = time.tick_now()
	drive_pictures(c)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)

	// The server has said nothing for a while: ask how far it got.
	p.upload.last_heard = time.tick_add(time.tick_now(), -(UPLOAD_QUIET + time.Second))
	drive_pictures(c)
	_, ok := tc_one(t, &tc, .Blob_Put)
	testing.expect(t, ok)
	// The answer for an upload that is still going on changes nothing.
	req_buf: [proto.BLOB_PUT_ANSWER_SIZE]u8
	c.blobs.pictures[0].asking = true
	tc_answer(&tc, 1, .Ok, proto.encode_blob_put_answer(&req_buf, 0, false, 99))
	testing.expect_value(t, p.state, Picture_State.Upload)
}

@(test)
test_pictures_after_a_restart :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_pictures(t, &tc)
	defer tc_close(&tc)
	defer blobs_destroy(&tc.c)
	c := &tc.c
	p := uploading(t, &tc, 500)
	picture_upload(c, {jpeg = jpeg(100), width = 10, height = 10})
	c.blobs.pictures[1].blob = 77
	c.blobs.pictures[1].state = .Set

	// The server forgot the upload, so it starts over. One that was complete
	// and has its id doesn't.
	pictures_restart(c, false)
	testing.expect_value(t, len(c.blobs.pictures), 2)
	testing.expect_value(t, c.blobs.pictures[0].state, Picture_State.Put)
	testing.expect_value(t, c.blobs.pictures[0].upload.handle, u64(0))
	testing.expect(t, !c.blobs.pictures[0].asking)
	testing.expect_value(t, c.blobs.pictures[1].state, Picture_State.Set)
	_ = p

	// Logged out: gone.
	pictures_restart(c, true)
	testing.expect_value(t, len(c.blobs.pictures), 0)
	testing.expect(t, !v.uploading.avatar && !v.uploading.server)
}

@(test)
test_picture_gone_from_the_server :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_pictures(t, &tc)
	defer tc_close(&tc)
	defer blobs_destroy(&tc.c)
	c := &tc.c
	picture_upload(c, {jpeg = jpeg(100), width = 10, height = 10})
	drive_pictures(c)
	req, _ := tc_one(t, &tc, .Blob_Put)
	buf: [proto.BLOB_PUT_ANSWER_SIZE]u8
	tc_answer(&tc, req.id, .Ok, proto.encode_blob_put_answer(&buf, 55, true, 0))
	drive_pictures(c)
	set, _ := tc_one(t, &tc, .Profile_Set)

	// Setting it says the picture isn't there (any more): it is uploaded again.
	tc_answer(&tc, set.id, .Not_Found)
	p := &c.blobs.pictures[0]
	testing.expect_value(t, p.state, Picture_State.Put)
	testing.expect_value(t, p.blob, proto.Blob_Id(0))
	drive_pictures(c)
	again: bool
	req, again = tc_one(t, &tc, .Blob_Put)
	testing.expect(t, again)

	// Anything else gives it up, with the notice.
	tc_answer(&tc, req.id, .Ok, proto.encode_blob_put_answer(&buf, 56, true, 0))
	drive_pictures(c)
	set, _ = tc_one(t, &tc, .Profile_Set)
	tc_answer(&tc, set.id, .Denied)
	testing.expect_value(t, len(c.blobs.pictures), 0)
	testing.expect_value(t, v.notice.text, "The server rejected your new picture.")

	// A lost connection sets it again instead.
	picture_upload(c, {jpeg = jpeg(100), width = 10, height = 10})
	drive_pictures(c)
	req, _ = tc_one(t, &tc, .Blob_Put)
	tc_answer(&tc, req.id, .Ok, proto.encode_blob_put_answer(&buf, 57, true, 0))
	drive_pictures(c)
	_ = tc_sent(t, &tc)
	tc_restart(&tc)
	testing.expect_value(t, len(c.blobs.pictures), 1)
	testing.expect_value(t, c.blobs.pictures[0].state, Picture_State.Set)
}

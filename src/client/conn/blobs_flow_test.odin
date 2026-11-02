#+build !wasi
package conn

import "core:sync"
import "core:testing"
import "core:time"

import "common:proto"

// Tests of fetching the pictures that messages and people show (blobs.odin):
// what is wanted and in which order, the request and its answers, the chunks,
// asking again when they stop, keeping the pictures within a budget, and
// sharing the bytes with the View.

@(private = "file")
open_blobs :: proc(t: ^testing.T, tc: ^Test_Conn) -> ^View {
	tc_open(tc)
	tc_connect(t, tc)
	tc.c.auth.me = 1
	tc.c.auth.state = .Done
	return tc_view(tc)
}

@(private = "file")
close_blobs :: proc(tc: ^Test_Conn) {
	blobs_destroy(&tc.c)
	tc_close(tc)
}

@(private = "file")
picture :: proc(size: int) -> []u8 {
	data := make([]u8, size, context.temp_allocator)
	for &b, i in data {
		b = u8(i * 7 + i / 251)
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

// get_answer answers the Blob_Get that is pending, naming the handle.
@(private = "file")
answered :: proc(tc: ^Test_Conn, req: Test_Request, size: int, handle: u64) {
	buf: [proto.BLOB_GET_ANSWER_SIZE]u8
	tc_answer(tc, req.id, .Ok, proto.encode_blob_get_answer(&buf, size, handle))
}

@(private = "file")
send_chunks :: proc(tc: ^Test_Conn, handle: u64, data: []u8, indices: ..int) {
	out: [proto.MAX_PAYLOAD_SIZE]u8
	for i in indices {
		start, end := proto.blob_chunk_range(len(data), i)
		handle_blob_chunk(&tc.c, proto.encode_blob_chunk(out[:], handle, i, data[start:end]))
	}
}

// ---- what is wanted ----

@(test)
test_wanting_pictures :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_blobs(t, &tc)
	defer close_blobs(&tc)
	c := &tc.c

	// No blob is no picture, and one past what is transferred is not fetched.
	blob_want(c, {blob = 0, size = 100})
	blob_want(c, {blob = 5, size = proto.MAX_BLOB_SIZE + 1})
	testing.expect_value(t, len(c.blobs.cache), 0)

	blob_want(c, {blob = 10, size = 100})
	blob_want(c, {blob = 11, size = 0}) // the server will say how big
	testing.expect_value(t, len(c.blobs.cache), 2)
	testing.expect_value(t, c.blobs.cache[10].state, Image_State.Wanted)
	testing.expect_value(t, v.blobs[10].state, Image_State.Wanted)
	// The one wanted last is fetched first.
	testing.expect_value(t, c.blobs.queue[0], proto.Blob_Id(11))
	blob_want(c, {blob = 12, size = 100})
	testing.expect_value(t, c.blobs.queue[0], proto.Blob_Id(12))
	// Wanted again, it moves to the front instead of being queued twice.
	blob_want(c, {blob = 10, size = 100})
	testing.expect_value(t, len(c.blobs.queue), 3)
	testing.expect_value(t, c.blobs.queue[0], proto.Blob_Id(10))
	testing.expect_value(t, c.blobs.queue[1], proto.Blob_Id(12))

	// Only being kept is added to what is there.
	testing.expect(t, !c.blobs.cache[10].keep)
	blob_want(c, {blob = 10, size = 100}, keep = true)
	testing.expect(t, c.blobs.cache[10].keep)
	blob_want(c, {blob = 10, size = 100}, keep = false)
	testing.expect(t, c.blobs.cache[10].keep, "a kept picture was let go")
}

@(test)
test_fetching_a_picture :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_blobs(t, &tc)
	defer close_blobs(&tc)
	c := &tc.c
	data := picture(proto.BLOB_CHUNK_SIZE * 2 + 10)
	blob_want(c, {blob = 10, size = u32(len(data))})

	// Nothing before the connection has synced.
	c.convs.synced = false
	blobs_step(c)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	c.convs.synced = true

	blobs_step(c)
	req, ok := tc_one(t, &tc, .Blob_Get)
	testing.expect(t, ok)
	id, dec := proto.decode_blob_id(req.body)
	testing.expect(t, dec)
	testing.expect_value(t, id, proto.Blob_Id(10))
	testing.expect_value(t, c.blobs.active, proto.Blob_Id(10))
	testing.expect_value(t, c.blobs.cache[10].state, Image_State.Loading)
	testing.expect_value(t, v.blobs[10].state, Image_State.Loading)
	// Asked once, however often the loop turns.
	blobs_step(c)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)

	answered(&tc, req, len(data), 77)
	testing.expect_value(t, c.blobs.cache[10].handle, u64(77))

	// Chunks in any order, ones for another transfer, and a repeat, are handled.
	send_chunks(&tc, 78, data, 0) // another handle
	send_chunks(&tc, 77, data, 2, 2, 0)
	testing.expect_value(t, c.blobs.cache[10].state, Image_State.Loading)
	send_chunks(&tc, 77, data, 1)
	fetch := c.blobs.cache[10]
	testing.expect_value(t, fetch.state, Image_State.Ready)
	testing.expect_value(t, string(fetch.data), string(data))
	testing.expect_value(t, c.blobs.bytes, len(data))
	testing.expect_value(t, c.blobs.active, proto.Blob_Id(0))
	// The server is told that it is complete, so it can release it.
	needs := of_kind(t, &tc, .Blob_Need)
	testing.expect(t, len(needs) >= 1)
	if len(needs) >= 1 {
		handle, complete, _, _, need_ok := proto.decode_blob_need(needs[len(needs) - 1])
		testing.expect(t, need_ok && complete)
		testing.expect_value(t, handle, u64(77))
	}
	// The UI has the bytes.
	testing.expect_value(t, v.blobs[10].state, Image_State.Ready)
	testing.expect_value(t, string(v.blobs[10].jpeg), string(data))
	// Chunks after it is done are nothing.
	send_chunks(&tc, 77, data, 0)
	testing.expect_value(t, c.blobs.cache[10].state, Image_State.Ready)
}

@(test)
test_one_picture_at_a_time :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_blobs(t, &tc)
	defer close_blobs(&tc)
	c := &tc.c
	one := picture(100)
	blob_want(c, {blob = 10, size = 100})
	blob_want(c, {blob = 11, size = 100})

	blobs_step(c)
	req, _ := tc_one(t, &tc, .Blob_Get)
	id, _ := proto.decode_blob_id(req.body)
	testing.expect_value(t, id, proto.Blob_Id(11)) // wanted last
	blobs_step(c)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)

	answered(&tc, req, 100, 5)
	send_chunks(&tc, 5, one, 0)
	testing.expect_value(t, c.blobs.cache[11].state, Image_State.Ready)
	// Now the other one's turn.
	blobs_step(c)
	req, _ = tc_one(t, &tc, .Blob_Get)
	id, _ = proto.decode_blob_id(req.body)
	testing.expect_value(t, id, proto.Blob_Id(10))
}

@(test)
test_a_picture_of_unknown_size :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_blobs(t, &tc)
	defer close_blobs(&tc)
	c := &tc.c
	data := picture(300)
	blob_want(c, {blob = 10, size = 0})
	blobs_step(c)
	req, _ := tc_one(t, &tc, .Blob_Get)
	// The server says how big it is.
	answered(&tc, req, 300, 9)
	testing.expect_value(t, c.blobs.cache[10].image.size, u32(300))
	send_chunks(&tc, 9, data, 0)
	testing.expect_value(t, c.blobs.cache[10].state, Image_State.Ready)

	// ... but not bigger than a person's picture can be.
	blob_want(c, {blob = 11, size = 0})
	blobs_step(c)
	req, _ = tc_one(t, &tc, .Blob_Get)
	answered(&tc, req, proto.MAX_AVATAR_SIZE + 1, 10)
	testing.expect_value(t, c.blobs.cache[11].state, Image_State.Gone)
}

@(test)
test_a_picture_that_is_not_what_it_was_said_to_be :: proc(t: ^testing.T) {
	Case :: struct {
		status: proto.Status,
		size:   int, // what the answer says; -1 for an answer that can't be read
	}
	for k in ([]Case{{.Ok, 99}, {.Ok, -1}, {.Not_Found, 100}, {.Denied, 100}, {.Internal, 100}}) {
		context.logger = expected_errors()
		tc: Test_Conn
		v := open_blobs(t, &tc)
		defer close_blobs(&tc)
		c := &tc.c
		blob_want(c, {blob = 10, size = 100})
		blob_want(c, {blob = 11, size = 100})
		blobs_step(c)
		req, _ := tc_one(t, &tc, .Blob_Get)
		if k.size >= 0 {
			buf: [proto.BLOB_GET_ANSWER_SIZE]u8
			tc_answer(&tc, req.id, k.status, proto.encode_blob_get_answer(&buf, k.size, 5))
		} else {
			tc_answer(&tc, req.id, k.status, []u8{1, 2})
		}
		// Given up on, and not asked for again; the next picture is.
		testing.expectf(t, c.blobs.cache[11].state == .Gone, "%v %d: %v", k.status, k.size, c.blobs.cache[11].state)
		testing.expect_value(t, v.blobs[11].state, Image_State.Gone)
		testing.expect_value(t, c.blobs.active, proto.Blob_Id(0))
		blobs_step(c)
		next, _ := tc_one(t, &tc, .Blob_Get)
		id, _ := proto.decode_blob_id(next.body)
		testing.expect_value(t, id, proto.Blob_Id(10))
		// What is gone is not queued again by being wanted.
		blob_want(c, {blob = 11, size = 100})
		testing.expect_value(t, c.blobs.cache[11].state, Image_State.Gone)
	}
}

@(test)
test_a_lost_connection_asks_again :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_blobs(t, &tc)
	defer close_blobs(&tc)
	c := &tc.c
	data := picture(proto.BLOB_CHUNK_SIZE + 10)
	blob_want(c, {blob = 10, size = u32(len(data))})
	blobs_step(c)
	req, _ := tc_one(t, &tc, .Blob_Get)
	answered(&tc, req, len(data), 5)
	send_chunks(&tc, 5, data, 0)
	blob_want(c, {blob = 11, size = 100}) // waiting its turn

	// A new connection starts the picture over, ahead of the one that waited.
	tc_restart(&tc)
	blobs_restart(c, false)
	fetch := c.blobs.cache[10]
	testing.expect_value(t, fetch.state, Image_State.Wanted)
	testing.expect_value(t, fetch.handle, u64(0))
	testing.expect_value(t, c.blobs.active, proto.Blob_Id(0))
	testing.expect_value(t, c.blobs.queue[0], proto.Blob_Id(10))
	testing.expect_value(t, c.blobs.queue[1], proto.Blob_Id(11))
	blobs_step(c)
	ok: bool
	req, ok = tc_one(t, &tc, .Blob_Get)
	testing.expect(t, ok)
	answered(&tc, req, len(data), 6)
	send_chunks(&tc, 6, data, 0, 1)
	testing.expect_value(t, fetch.state, Image_State.Ready)
	testing.expect_value(t, string(fetch.data), string(data))

	// With nothing in progress there is nothing to start over.
	blobs_restart(c, false)
	testing.expect_value(t, fetch.state, Image_State.Ready)
}

@(test)
test_missing_chunks_are_asked_for :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_blobs(t, &tc)
	defer close_blobs(&tc)
	c := &tc.c
	data := picture(proto.BLOB_CHUNK_SIZE * 3 + 10)
	blob_want(c, {blob = 10, size = u32(len(data))})
	blobs_step(c)
	req, _ := tc_one(t, &tc, .Blob_Get)
	answered(&tc, req, len(data), 5)
	_ = tc_datagrams(t, &tc)
	send_chunks(&tc, 5, data, 0, 3)
	fetch := c.blobs.cache[10]

	// Right after chunks arrived nothing is asked.
	blobs_step(c)
	testing.expect_value(t, len(of_kind(t, &tc, .Blob_Need)), 0)

	// Once they have stopped, the server is told which are missing.
	fetch.asked = time.tick_add(time.tick_now(), -(proto.CONTROL_RESEND + time.Millisecond))
	fetch.last_chunk = time.tick_add(time.tick_now(), -(proto.CONTROL_RESEND + time.Millisecond))
	blobs_step(c)
	needs := of_kind(t, &tc, .Blob_Need)
	testing.expect_value(t, len(needs), 1)
	if len(needs) == 1 {
		handle, complete, count, indices, ok := proto.decode_blob_need(needs[0])
		testing.expect(t, ok && !complete)
		testing.expect_value(t, handle, u64(5))
		testing.expect_value(t, count, 2)
		if count == 2 {
			seen := [2]int{proto.blob_need_index(indices, 0), proto.blob_need_index(indices, 1)}
			testing.expect(t, (seen[0] == 1 && seen[1] == 2) || (seen[0] == 2 && seen[1] == 1))
		}
	}
	// Not again straight away.
	blobs_step(c)
	testing.expect_value(t, len(of_kind(t, &tc, .Blob_Need)), 0)
}

@(test)
test_a_silent_server_is_asked_from_the_start :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_blobs(t, &tc)
	defer close_blobs(&tc)
	c := &tc.c
	blob_want(c, {blob = 10, size = 100})
	blobs_step(c)
	req, _ := tc_one(t, &tc, .Blob_Get)
	answered(&tc, req, 100, 5)
	fetch := c.blobs.cache[10]

	// Nothing has come for too long: the whole picture is requested again.
	old := time.tick_add(time.tick_now(), -(FETCH_QUIET + time.Second))
	fetch.asked, fetch.last_chunk = old, old
	blobs_step(c)
	again, asked := tc_one(t, &tc, .Blob_Get)
	testing.expect(t, asked)
	// The answer may name a new handle.
	answered(&tc, again, 100, 8)
	testing.expect_value(t, fetch.handle, u64(8))
	data := picture(100)
	send_chunks(&tc, 5, data, 0) // the old handle is nothing now
	testing.expect_value(t, fetch.state, Image_State.Loading)
	send_chunks(&tc, 8, data, 0)
	testing.expect_value(t, fetch.state, Image_State.Ready)
}

// ---- keeping within a budget ----

@(test)
test_old_pictures_are_dropped_to_stay_within_the_budget :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_blobs(t, &tc)
	defer close_blobs(&tc)
	c := &tc.c
	size := 7 * 1024 * 1024

	blob_have(c, 1, make([]u8, size), 100, 100)
	blob_have(c, 2, make([]u8, size), 100, 100)
	testing.expect_value(t, len(c.blobs.cache), 2)
	testing.expect_value(t, c.blobs.bytes, 2 * size)
	// A third passes BLOB_CACHE_BYTES: the one that arrived first goes.
	blob_have(c, 3, make([]u8, size), 100, 100)
	testing.expect(t, 1 not_in c.blobs.cache)
	testing.expect(t, 2 in c.blobs.cache && 3 in c.blobs.cache)
	testing.expect_value(t, c.blobs.bytes, 2 * size)
	_, shown := v.blobs[1]
	testing.expect(t, !shown, "a dropped picture is still shown")
}

@(test)
test_kept_pictures_are_not_dropped :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_blobs(t, &tc)
	defer close_blobs(&tc)
	c := &tc.c
	size := 7 * 1024 * 1024
	blob_have(c, 1, make([]u8, size), 100, 100)
	c.blobs.cache[1].keep = true
	blob_have(c, 2, make([]u8, size), 100, 100)
	blob_have(c, 3, make([]u8, size), 100, 100)
	testing.expect(t, 1 in c.blobs.cache, "a kept picture was dropped")
	testing.expect(t, 2 not_in c.blobs.cache)
	testing.expect(t, 3 in c.blobs.cache)
	// Even past the budget, when nothing else can go.
	blob_have(c, 4, make([]u8, size), 100, 100)
	blob_have(c, 5, make([]u8, size), 100, 100)
	testing.expect(t, 1 in c.blobs.cache)
}

@(test)
test_a_picture_we_just_sent :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_blobs(t, &tc)
	defer close_blobs(&tc)
	c := &tc.c

	blob_have(c, 5, picture_copy(300), 30, 20)
	fetch := c.blobs.cache[5]
	testing.expect_value(t, fetch.state, Image_State.Ready)
	testing.expect_value(t, fetch.image.width, u16(30))
	testing.expect_value(t, fetch.image.height, u16(20))
	testing.expect_value(t, fetch.image.size, u32(300))
	testing.expect_value(t, len(v.blobs[5].jpeg), 300)
	testing.expect_value(t, c.blobs.bytes, 300)

	// Having it already, the new bytes are let go and nothing changes.
	before := fetch.data
	blob_have(c, 5, picture_copy(400), 1, 1)
	testing.expect(t, raw_data(c.blobs.cache[5].data) == raw_data(before))
	testing.expect_value(t, c.blobs.bytes, 300)

	// A picture that was wanted becomes this one, and is not fetched.
	blob_want(c, {blob = 6, size = 100})
	blob_have(c, 6, picture_copy(100), 10, 10)
	testing.expect_value(t, c.blobs.cache[6].state, Image_State.Ready)
	blobs_step(c)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
}

@(private = "file")
picture_copy :: proc(size: int) -> []u8 {
	out := make([]u8, size)
	copy(out, picture(size))
	return out
}

// ---- sharing the bytes with the UI ----

@(test)
test_the_ui_may_keep_a_picture_the_cache_dropped :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_blobs(t, &tc)
	defer close_blobs(&tc)
	c := &tc.c

	blob_have(c, 5, picture_copy(300), 30, 20)
	shared := c.blobs.cache[5].shared
	testing.expect_value(t, sync.atomic_load(&shared.refs), i32(2)) // the cache and the View
	// Publishing again does not leak a reference.
	publish_blob(c, 5)
	testing.expect_value(t, sync.atomic_load(&shared.refs), i32(2))

	// The UI thread is drawing it (it holds the bytes of its own) when the cache
	// is trimmed and the picture dropped from the cache and the View.
	ui := shared_ref(shared)
	blob_have(c, 6, make([]u8, 9 * 1024 * 1024), 1, 1)
	blob_have(c, 7, make([]u8, 9 * 1024 * 1024), 1, 1)
	testing.expect(t, 5 not_in c.blobs.cache)
	_, shown := v.blobs[5]
	testing.expect(t, !shown)
	// What the UI holds is still good, and the last one to let go frees it.
	testing.expect_value(t, sync.atomic_load(&ui.refs), i32(1))
	testing.expect_value(t, string(ui.data), string(picture(300)))
	shared_unref(ui)
}

@(test)
test_references_to_shared_bytes :: proc(t: ^testing.T) {
	b := new(Shared_Bytes)
	b^ = {
		data      = make([]u8, 10),
		refs      = 1,
		allocator = context.allocator,
	}
	testing.expect(t, shared_ref(b) == b)
	testing.expect_value(t, b.refs, i32(2))
	shared_unref(b)
	testing.expect_value(t, b.refs, i32(1))
	shared_unref(b) // freed here; nothing to check but that it does not crash
	// Nothing at all is fine too.
	testing.expect(t, shared_ref(nil) == nil)
	shared_unref(nil)
}

// ---- uploads' answers ----

@(test)
test_the_servers_word_on_our_upload :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_blobs(t, &tc)
	defer close_blobs(&tc)
	c := &tc.c
	// With nothing being uploaded, a Blob_Need is nobody's.
	out: [proto.MAX_PAYLOAD_SIZE]u8
	msg, _ := proto.encode_blob_need(out[:], 5, true, nil)
	handle_blob_need(c, msg)
	testing.expect_value(t, len(c.blobs.pictures), 0)

	picture_upload(c, {jpeg = picture_copy(100), width = 10, height = 10})
	drive_pictures(c)
	req, _ := tc_one(t, &tc, .Blob_Put)
	buf: [proto.BLOB_PUT_ANSWER_SIZE]u8
	tc_answer(&tc, req.id, .Ok, proto.encode_blob_put_answer(&buf, 0, false, 5))
	handle_blob_need(c, msg)
	testing.expect_value(t, c.blobs.pictures[0].state, Picture_State.Put)
}

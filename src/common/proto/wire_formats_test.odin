#+build !wasi
package proto

import "core:testing"

// Round trips and malformed input for the smaller message formats: bookmarks
// (bookmarks.odin), searching (search.odin), attachments (attachments.odin)
// and activity (activity.odin). Everything here is decoded from bytes that a
// peer chose, so each decoder is also fed every truncation of a good body.

@(private = "file")
sample_message :: proc(id: Msg_Id, text: string) -> Message {
	return Message{id = id, conv = 3, sender = 9, time = Unix_Ms(1000 + id), kind = .Text, text = text}
}

// ---- bookmarks ----

@(test)
test_bookmark_set :: proc(t: ^testing.T) {
	buf: [BOOKMARK_SET_SIZE]u8
	for on in ([]bool{true, false}) {
		id, got_on, ok := decode_bookmark_set(encode_bookmark_set(&buf, 0x0102030405060708, on))
		testing.expect(t, ok)
		testing.expect_value(t, id, Msg_Id(0x0102030405060708))
		testing.expect_value(t, got_on, on)
	}
	good := encode_bookmark_set(&buf, 5, true)
	// Only exactly the size, a flag that is 0 or 1, and a message that exists.
	for n in 0 ..< len(good) {
		_, _, ok := decode_bookmark_set(good[:n])
		testing.expectf(t, !ok, "%d bytes were accepted", n)
	}
	_, _, ok := decode_bookmark_set(append_byte(good, 0))
	testing.expect(t, !ok, "a body with extra bytes was accepted")
	bad := buf
	bad[8] = 2
	_, _, ok = decode_bookmark_set(bad[:])
	testing.expect(t, !ok)
	_, _, ok = decode_bookmark_set(encode_bookmark_set(&buf, 0, true))
	testing.expect(t, !ok, "message 0 was accepted")
}

// append_byte returns `body` with one more byte, in the temp allocator.
@(private = "file")
append_byte :: proc(body: []u8, b: u8) -> []u8 {
	out := make([]u8, len(body) + 1, context.temp_allocator)
	copy(out, body)
	out[len(body)] = b
	return out
}

@(test)
test_bookmarks_get :: proc(t: ^testing.T) {
	buf: [BOOKMARKS_GET_SIZE]u8
	time_, before, ok := decode_bookmarks_get(encode_bookmarks_get(&buf, 12345, 678))
	testing.expect(t, ok)
	testing.expect_value(t, time_, Unix_Ms(12345))
	testing.expect_value(t, before, Msg_Id(678))
	// Both 0 asks from the newest.
	time_, before, ok = decode_bookmarks_get(encode_bookmarks_get(&buf, 0, 0))
	testing.expect(t, ok && time_ == 0 && before == 0)
	for n in 0 ..< BOOKMARKS_GET_SIZE {
		_, _, ok = decode_bookmarks_get(buf[:n])
		testing.expect(t, !ok)
	}
	_, _, ok = decode_bookmarks_get(append_byte(buf[:], 0))
	testing.expect(t, !ok)
}

@(test)
test_bookmarks_page :: proc(t: ^testing.T) {
	list := []Bookmark {
		{time = 500, msg = sample_message(10, "first")},
		{time = 400, msg = sample_message(7, "second, a little longer")},
		{time = 300, msg = sample_message(3, "")},
	}
	out: [4096]u8
	body, count := encode_bookmarks_page(out[:], list, false)
	testing.expect_value(t, count, 3)

	buf: [8]Bookmark
	got, more, ok := decode_bookmarks_page(body, buf[:])
	testing.expect(t, ok)
	testing.expect(t, !more)
	testing.expect_value(t, len(got), 3)
	if len(got) == 3 {
		for want, i in list {
			testing.expect_value(t, got[i].time, want.time)
			testing.expect_value(t, got[i].msg.id, want.msg.id)
			testing.expect_value(t, got[i].msg.text, want.msg.text)
			testing.expect_value(t, got[i].msg.conv, want.msg.conv)
		}
	}

	// `more` is passed on, and an empty list is a valid page.
	body, _ = encode_bookmarks_page(out[:], list[:1], true)
	_, more, ok = decode_bookmarks_page(body, buf[:])
	testing.expect(t, ok && more)
	body, count = encode_bookmarks_page(out[:], nil, false)
	testing.expect_value(t, count, 0)
	got, more, ok = decode_bookmarks_page(body, buf[:])
	testing.expect(t, ok && !more && len(got) == 0)

	// Every shorter body is refused (the decoder has to notice, not read past the end).
	body, _ = encode_bookmarks_page(out[:], list, false)
	for n in 0 ..< len(body) {
		_, _, ok = decode_bookmarks_page(body[:n], buf[:])
		testing.expectf(t, !ok, "a page cut to %d of %d bytes was accepted", n, len(body))
	}
	// ... and one with something after it.
	_, _, ok = decode_bookmarks_page(append_byte(body, 0), buf[:])
	testing.expect(t, !ok)
	// A page with more bookmarks than the caller has room for.
	_, _, ok = decode_bookmarks_page(body, buf[:2])
	testing.expect(t, !ok)
}

@(test)
test_bookmarks_page_fits_the_buffer :: proc(t: ^testing.T) {
	list: [10]Bookmark
	for &b, i in list {
		b = {
			time = Unix_Ms(100 - i),
			msg  = sample_message(Msg_Id(50 - i), "some text for the message"),
		}
	}
	// Room for only some of them: the page says so and the rest are asked for later.
	size := 2 + 1 + 3 * (8 + message_size(list[0].msg)) + 5
	out := make([]u8, size, context.temp_allocator)
	body, count := encode_bookmarks_page(out, list[:], false)
	testing.expect_value(t, count, 3)
	buf: [10]Bookmark
	got, more, ok := decode_bookmarks_page(body, buf[:])
	testing.expect(t, ok)
	testing.expect(t, more, "a page that left some out did not say there is more")
	testing.expect_value(t, len(got), 3)
	if len(got) == 3 {
		testing.expect_value(t, got[2].msg.id, Msg_Id(48))
	}

	// A buffer too small even for the header gives nothing.
	body, count = encode_bookmarks_page(make([]u8, 2, context.temp_allocator), list[:], false)
	testing.expect(t, body == nil && count == 0)
}

@(test)
test_bookmarks_list :: proc(t: ^testing.T) {
	buf: [BOOKMARKS_MAX_SIZE]u8
	ids := [?]Msg_Id{5, 1, 0xffffffffffffffff, 9}
	var: [MAX_BOOKMARKS]Msg_Id
	got, ok := decode_bookmarks(encode_bookmarks(&buf, ids[:]), &var)
	testing.expect(t, ok)
	testing.expect_value(t, len(got), 4)
	if len(got) == 4 {
		for id, i in ids {
			testing.expect_value(t, got[i], id)
		}
	}
	got, ok = decode_bookmarks(encode_bookmarks(&buf, nil), &var)
	testing.expect(t, ok && len(got) == 0)

	// More than the most are cut, and what is left still decodes.
	many := make([]Msg_Id, MAX_BOOKMARKS + 10, context.temp_allocator)
	for &id, i in many {
		id = Msg_Id(i + 1)
	}
	body := encode_bookmarks(&buf, many)
	testing.expect_value(t, len(body), 2 + MAX_BOOKMARKS * 8)
	got, ok = decode_bookmarks(body, &var)
	testing.expect(t, ok)
	testing.expect_value(t, len(got), MAX_BOOKMARKS)

	// A count that doesn't match the size, or is over the limit.
	short := encode_bookmarks(&buf, ids[:])
	for n in 0 ..< len(short) {
		_, ok = decode_bookmarks(short[:n], &var)
		testing.expectf(t, !ok, "%d of %d bytes were accepted", n, len(short))
	}
	_, ok = decode_bookmarks(append_byte(short, 0), &var)
	testing.expect(t, !ok)
	over := []u8{0xe9, 0x03} // 1001
	_, ok = decode_bookmarks(over, &var)
	testing.expect(t, !ok)
	huge := make([]u8, 2, context.temp_allocator)
	huge[0], huge[1] = 0xff, 0xff
	_, ok = decode_bookmarks(huge, &var)
	testing.expect(t, !ok)
	// A body that really holds one id too many, whose size matches its count:
	// reading it would write past the caller's buffer.
	full := make([]u8, 2 + (MAX_BOOKMARKS + 1) * 8, context.temp_allocator)
	full[0], full[1] = u8((MAX_BOOKMARKS + 1) & 0xff), u8((MAX_BOOKMARKS + 1) >> 8)
	_, ok = decode_bookmarks(full, &var)
	testing.expect(t, !ok, "a list over the most was accepted")
}

@(test)
test_bookmark_changed :: proc(t: ^testing.T) {
	buf: [BOOKMARK_CHANGED_SIZE]u8
	id, time_, on, ok := decode_bookmark_changed(encode_bookmark_changed(&buf, 77, 123456, true))
	testing.expect(t, ok && on)
	testing.expect_value(t, id, Msg_Id(77))
	testing.expect_value(t, time_, Unix_Ms(123456))
	_, _, on, ok = decode_bookmark_changed(encode_bookmark_changed(&buf, 77, 0, false))
	testing.expect(t, ok && !on)

	good := encode_bookmark_changed(&buf, 77, 5, true)
	for n in 0 ..< len(good) {
		_, _, _, ok = decode_bookmark_changed(good[:n])
		testing.expect(t, !ok)
	}
	_, _, _, ok = decode_bookmark_changed(append_byte(good, 0))
	testing.expect(t, !ok)
	flag := buf
	flag[16] = 7
	_, _, _, ok = decode_bookmark_changed(flag[:])
	testing.expect(t, !ok)
	_, _, _, ok = decode_bookmark_changed(encode_bookmark_changed(&buf, 0, 5, true))
	testing.expect(t, !ok)
}

// ---- search ----

@(test)
test_msg_search :: proc(t: ^testing.T) {
	buf: [MSG_SEARCH_MAX_SIZE]u8
	s, ok := decode_msg_search(
		encode_msg_search(&buf, {conv = 4, before = 99, limit = 20, query = `from:alice "exact phrase" word`}),
	)
	testing.expect(t, ok)
	testing.expect_value(t, s.conv, Conv_Id(4))
	testing.expect_value(t, s.before, Msg_Id(99))
	testing.expect_value(t, s.limit, 20)
	testing.expect_value(t, s.query, `from:alice "exact phrase" word`)

	// All conversations, from the newest.
	s, ok = decode_msg_search(encode_msg_search(&buf, {limit = 1, query = "x"}))
	testing.expect(t, ok && s.conv == 0 && s.before == 0)

	// The limit is kept within what the server accepts, and the query too.
	s, ok = decode_msg_search(encode_msg_search(&buf, {limit = 1000, query = "x"}))
	testing.expect(t, ok)
	testing.expect_value(t, s.limit, MAX_SEARCH_LIMIT)
	s, ok = decode_msg_search(encode_msg_search(&buf, {limit = -5, query = "x"}))
	testing.expect(t, ok)
	testing.expect_value(t, s.limit, 1)
	long := make([]u8, MAX_SEARCH_QUERY + 50, context.temp_allocator)
	for &b in long {
		b = 'a'
	}
	s, ok = decode_msg_search(encode_msg_search(&buf, {limit = 5, query = string(long)}))
	testing.expect(t, ok)
	testing.expect_value(t, len(s.query), MAX_SEARCH_QUERY)

	// The query may be empty on the wire (the server answers Invalid for it).
	s, ok = decode_msg_search(encode_msg_search(&buf, {limit = 5}))
	testing.expect(t, ok)
	testing.expect_value(t, s.query, "")
}

@(test)
test_msg_search_malformed :: proc(t: ^testing.T) {
	buf: [MSG_SEARCH_MAX_SIZE]u8
	good := encode_msg_search(&buf, {conv = 1, before = 2, limit = 10, query = "hello"})
	for n in 0 ..< len(good) {
		_, ok := decode_msg_search(good[:n])
		testing.expectf(t, !ok, "%d of %d bytes were accepted", n, len(good))
	}
	// A limit of 0 or above the most, written by a client that doesn't use the encoder.
	for limit in ([]u8{0, MAX_SEARCH_LIMIT + 1, 255}) {
		bad := make([]u8, len(good), context.temp_allocator)
		copy(bad, good)
		bad[12] = limit
		_, ok := decode_msg_search(bad)
		testing.expectf(t, !ok, "a limit of %d was accepted", limit)
	}
	// A query longer than the most.
	big := make([]u8, 4 + 8 + 1 + 1 + MAX_SEARCH_QUERY + 1, context.temp_allocator)
	big[12] = 5
	big[13] = u8(MAX_SEARCH_QUERY + 1)
	_, ok := decode_msg_search(big)
	testing.expect(t, !ok)
	// A query that claims to be longer than the body.
	short := []u8{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5, 200, 'a'}
	_, ok = decode_msg_search(short)
	testing.expect(t, !ok)
}

@(test)
test_search_answer :: proc(t: ^testing.T) {
	msgs := []Message{sample_message(90, "alpha"), sample_message(80, "beta beta"), sample_message(70, "")}
	out: [2048]u8
	body, fitted := encode_search_answer(out[:], 65, MORE_BEFORE, msgs)
	testing.expect_value(t, fitted, 3)

	buf: [8]Message
	searched_to, more, got, ok := decode_search_answer(body, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, searched_to, Msg_Id(65))
	testing.expect_value(t, more, u8(MORE_BEFORE))
	testing.expect_value(t, len(got), 3)
	if len(got) == 3 {
		testing.expect_value(t, got[0].text, "alpha")
		testing.expect_value(t, got[1].id, Msg_Id(80))
		testing.expect_value(t, got[2].text, "")
	}

	// Nothing found is still an answer, and says how far the search got.
	body, fitted = encode_search_answer(out[:], 12, 0, nil)
	testing.expect_value(t, fitted, 0)
	searched_to, more, got, ok = decode_search_answer(body, buf[:])
	testing.expect(t, ok && searched_to == 12 && more == 0 && len(got) == 0)

	// Cut anywhere, it is refused.
	body, _ = encode_search_answer(out[:], 65, 0, msgs)
	for n in 0 ..< len(body) {
		_, _, _, ok = decode_search_answer(body[:n], buf[:])
		testing.expectf(t, !ok, "an answer cut to %d of %d bytes was accepted", n, len(body))
	}

	// With room for fewer messages the rest are left out, and the count says so.
	small := make([]u8, 8 + 3 + message_size(msgs[0]) + 2, context.temp_allocator)
	body, fitted = encode_search_answer(small, 65, 0, msgs)
	testing.expect_value(t, fitted, 1)
	_, _, got, ok = decode_search_answer(body, buf[:])
	testing.expect(t, ok && len(got) == 1)
	// ... and no room for the header gives no answer at all.
	body, fitted = encode_search_answer(make([]u8, 7, context.temp_allocator), 1, 0, msgs)
	testing.expect(t, body == nil && fitted == 0)
}

// ---- attachments ----

@(test)
test_attach_put :: proc(t: ^testing.T) {
	buf: [ATTACH_PUT_MAX_SIZE]u8
	p, ok := decode_attach_put(encode_attach_put(buf[:], {size = 1 << 40, name = "holiday photos.zip"}))
	testing.expect(t, ok)
	testing.expect_value(t, p.size, u64(1 << 40))
	testing.expect_value(t, p.name, "holiday photos.zip")
	// An empty file with a name that is just a letter.
	p, ok = decode_attach_put(encode_attach_put(buf[:], {size = 0, name = "a"}))
	testing.expect(t, ok && p.size == 0 && p.name == "a")

	good := encode_attach_put(buf[:], {size = 5, name = "x.txt"})
	for n in 0 ..< len(good) {
		_, ok = decode_attach_put(good[:n])
		testing.expectf(t, !ok, "%d of %d bytes were accepted", n, len(good))
	}
	_, ok = decode_attach_put(append_byte(good, 0))
	testing.expect(t, !ok, "extra bytes were accepted")

	// A name over the limit is not written, nor read.
	long := make([]u8, MAX_FILE_NAME + 1, context.temp_allocator)
	for &b in long {
		b = 'n'
	}
	testing.expect(t, encode_attach_put(buf[:], {size = 1, name = string(long)}) == nil)
	exact := string(long[:MAX_FILE_NAME])
	p, ok = decode_attach_put(encode_attach_put(buf[:], {size = 1, name = exact}))
	testing.expect(t, ok)
	testing.expect_value(t, len(p.name), MAX_FILE_NAME)
	// A name that is within what a length byte can say but over the limit,
	// written by a client that doesn't use the encoder.
	for length in ([]int{MAX_FILE_NAME + 1, 255}) {
		raw := make([]u8, 8 + 1 + length, context.temp_allocator)
		raw[8] = u8(length)
		for i in 9 ..< len(raw) {
			raw[i] = 'n'
		}
		_, ok = decode_attach_put(raw)
		testing.expectf(t, !ok, "a name of %d bytes was accepted", length)
	}
	// An output buffer that is too small is not an overrun.
	testing.expect(t, encode_attach_put(buf[:5], {size = 1, name = "x"}) == nil)
}

@(test)
test_attach_ids_and_answers :: proc(t: ^testing.T) {
	id_buf: [8]u8
	id, ok := decode_attach_id(encode_attach_id(&id_buf, 0xdeadbeef12345678))
	testing.expect(t, ok)
	testing.expect_value(t, id, u64(0xdeadbeef12345678))
	for n in 0 ..< 8 {
		_, ok = decode_attach_id(id_buf[:n])
		testing.expect(t, !ok)
	}

	buf: [ATTACH_GET_ANSWER_SIZE]u8
	size, download: u64
	size, download, ok = decode_attach_get_answer(encode_attach_get_answer(&buf, 123456789, 42))
	testing.expect(t, ok)
	testing.expect_value(t, size, u64(123456789))
	testing.expect_value(t, download, u64(42))
	for n in 0 ..< ATTACH_GET_ANSWER_SIZE {
		_, _, ok = decode_attach_get_answer(buf[:n])
		testing.expect(t, !ok)
	}
	_, _, ok = decode_attach_get_answer(append_byte(buf[:], 0))
	testing.expect(t, !ok)
}

// ---- activity ----

@(test)
test_activity :: proc(t: ^testing.T) {
	buf: [ACTIVITY_SET_SIZE]u8
	for a in Activity {
		got, ok := decode_activity(encode_activity(&buf, a))
		testing.expect(t, ok)
		testing.expect_value(t, got, a)
	}

	// Without a time it is one byte, which means "now".
	body := encode_activity(&buf, .Busy)
	testing.expect_value(t, len(body), 1)
	testing.expect_value(t, decode_activity_at(body), Unix_Ms(0))
	// With one, the time follows.
	body = encode_activity(&buf, .Away, 1_700_000_000_000)
	testing.expect_value(t, len(body), ACTIVITY_SET_SIZE)
	testing.expect_value(t, decode_activity_at(body), Unix_Ms(1_700_000_000_000))
	a, ok := decode_activity(body)
	testing.expect(t, ok && a == .Away)
	// A cut-off time is no time.
	for n in 1 ..< ACTIVITY_SET_SIZE {
		testing.expect_value(t, decode_activity_at(body[:n]), Unix_Ms(0))
	}

	// Nothing, or an activity from a newer version, is refused.
	_, ok = decode_activity(nil)
	testing.expect(t, !ok)
	for b in 4 ..= 255 {
		_, ok = decode_activity([]u8{u8(b)})
		testing.expectf(t, !ok, "activity %d was accepted", b)
	}
}

@(test)
test_idle :: proc(t: ^testing.T) {
	buf: [1]u8
	for idle in ([]bool{false, true}) {
		for hidden in ([]bool{false, true}) {
			i, h, ok := decode_idle(encode_idle(&buf, idle, hidden))
			testing.expect(t, ok)
			testing.expect_value(t, i, idle)
			testing.expect_value(t, h, hidden)
		}
	}
	// The two flags are separate bits, and a server ignores bits it doesn't know.
	i, h, ok := decode_idle([]u8{0b0000_0001})
	testing.expect(t, ok && i && !h)
	i, h, ok = decode_idle([]u8{0b0000_0010})
	testing.expect(t, ok && !i && h)
	i, h, ok = decode_idle([]u8{0b1111_1100})
	testing.expect(t, ok && !i && !h)
	// A client that only knows idle sends the same byte with bit 1 clear.
	_, _, ok = decode_idle(nil)
	testing.expect(t, !ok)
}

@(test)
test_self_activity :: proc(t: ^testing.T) {
	buf: [SELF_SIZE]u8
	for a in Activity {
		self := encode_self(&buf, 7, {}, {}, a)
		testing.expect_value(t, self_activity(self), a)
	}
	// An event that is too short, or has an activity this version doesn't
	// know, is read as Online.
	good := encode_self(&buf, 7, {}, {}, .Busy)
	for n in 0 ..< SELF_FIXED_SIZE {
		testing.expect_value(t, self_activity(good[:n]), Activity.Online)
	}
	bad := make([]u8, len(good), context.temp_allocator)
	copy(bad, good)
	bad[SELF_FIXED_SIZE - 1] = 200
	testing.expect_value(t, self_activity(bad), Activity.Online)
}

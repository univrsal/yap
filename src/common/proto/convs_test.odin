#+build !wasi
package proto

import "core:testing"

@(test)
test_conv_record :: proc(t: ^testing.T) {
	buf: [CONV_MAX_SIZE]u8
	topic := make([]u8, MAX_TOPIC_SIZE, context.temp_allocator)
	for &b in topic {
		b = 't'
	}
	c := Conv {
		id     = 9,
		kind   = .Channel,
		flags  = {.Home},
		name   = "01234567890123456789012345678901",
		topic    = string(topic),
		member   = true,
		last     = 1234,
		read     = 1200,
		unread   = 7,
		mentions = 2,
		notify   = .Mentions,
		position = 70000,
	}
	body := encode_conv(buf[:], c)
	testing.expect(t, body != nil)
	// The longest conversation is what CONV_MAX_SIZE says it is.
	testing.expect_value(t, len(body), CONV_MAX_SIZE)
	got, ok := decode_conv(body)
	testing.expect(t, ok)
	testing.expect_value(t, got.id, c.id)
	testing.expect_value(t, got.kind, c.kind)
	testing.expect_value(t, got.flags, c.flags)
	testing.expect_value(t, got.name, c.name)
	testing.expect_value(t, got.topic, c.topic)
	testing.expect(t, got.member)
	testing.expect_value(t, got.last, c.last)
	testing.expect_value(t, got.read, c.read)
	testing.expect_value(t, got.unread, 7)
	testing.expect_value(t, got.mentions, 2)
	testing.expect_value(t, got.notify, Notify_Level.Mentions)
	testing.expect_value(t, got.position, c.position)

	// Counts past the cap go as the cap; a level from a newer server is
	// taken as the default.
	many := c
	many.unread = 5000
	got, ok = decode_conv(encode_conv(buf[:], many))
	testing.expect_value(t, got.unread, UNREAD_CAP)
	body = encode_conv(buf[:], c)
	body[len(body) - 5] = 9 // the notify level, before the position
	got, ok = decode_conv(body)
	testing.expect(t, ok)
	testing.expect_value(t, got.notify, Notify_Level.All)
	body = encode_conv(buf[:], c)

	_, ok = decode_conv(body[:len(body) - 1])
	testing.expect(t, !ok)
	_, ok = decode_conv(nil)
	testing.expect(t, !ok)
	// One that doesn't fit isn't written at all.
	testing.expect(t, encode_conv(buf[:20], c) == nil)
}

@(test)
test_conv_list :: proc(t: ^testing.T) {
	convs := []Conv {
		{id = 1, name = "Lobby", flags = {.Home}, member = true},
		{id = 2, name = "Gaming", topic = "games"},
		{id = 5, name = "Music"},
	}
	out: [2 + 3 * CONV_MAX_SIZE]u8
	body := encode_conv_list(out[:], convs)
	testing.expect(t, body != nil)
	buf: [8]Conv
	got, ok := decode_conv_list(body, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, len(got), 3)
	testing.expect_value(t, got[0].name, "Lobby")
	testing.expect(t, got[0].member)
	testing.expect_value(t, got[1].topic, "games")
	testing.expect_value(t, got[2].id, 5)

	// Without room for them all, it takes the first of them.
	body = encode_conv_list(out[:2 + CONV_MAX_SIZE], convs)
	got, ok = decode_conv_list(body, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, len(got), 1)
	testing.expect_value(t, got[0].name, "Lobby")

	got, ok = decode_conv_list([]u8{0, 0}, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, len(got), 0)
	_, ok = decode_conv_list(body, buf[:0])
	testing.expect(t, !ok)
	_, ok = decode_conv_list(body[:len(body) - 1], buf[:])
	testing.expect(t, !ok)
}

@(test)
test_browse :: proc(t: ^testing.T) {
	req_buf: [CONV_BROWSE_MAX_SIZE]u8
	b, ok := decode_conv_browse(encode_conv_browse(&req_buf, {query = "gam", offset = 50, limit = 20}))
	testing.expect(t, ok)
	testing.expect_value(t, b, Browse{query = "gam", offset = 50, limit = 20})
	// Empty: the first page of all.
	b, ok = decode_conv_browse(nil)
	testing.expect(t, ok)
	testing.expect_value(t, b, Browse{limit = BROWSE_PAGE})
	// No limit, or more than one may ask for.
	_, ok = decode_conv_browse([]u8{0, 0, 0, 0, 0})
	testing.expect(t, !ok)
	_, ok = decode_conv_browse([]u8{0, 0, 0, MAX_BROWSE_LIMIT + 1, 0})
	testing.expect(t, !ok)

	convs := []Conv{{id = 2, name = "Gaming"}, {id = 5, name = "Music"}}
	out: [1 + 2 + 2 * CONV_MAX_SIZE]u8
	buf: [4]Conv
	more, got, read := decode_browse_page(encode_browse_page(out[:], true, convs), buf[:])
	testing.expect(t, read && more)
	testing.expect_value(t, len(got), 2)
	more, got, read = decode_browse_page(encode_browse_page(out[:], false, convs), buf[:])
	testing.expect(t, read && !more)
	// What doesn't fit means there are more.
	more, got, read = decode_browse_page(encode_browse_page(out[:1 + 2 + CONV_MAX_SIZE], false, convs), buf[:])
	testing.expect(t, read && more)
	testing.expect_value(t, len(got), 1)
}

@(test)
test_conv_bodies :: proc(t: ^testing.T) {
	{
		buf: [CONV_CREATE_MAX_SIZE]u8
		name, topic, private, ok := decode_conv_create(encode_conv_create(buf[:], "Gaming", "for games", true))
		testing.expect(t, ok)
		testing.expect_value(t, name, "Gaming")
		testing.expect_value(t, topic, "for games")
		testing.expect(t, private)
		_, _, _, ok = decode_conv_create(buf[:3])
		testing.expect(t, !ok)
	}
	{
		buf: [4]u8
		conv, ok := decode_conv_id(encode_conv_id(&buf, 0xdeadbeef))
		testing.expect(t, ok)
		testing.expect_value(t, conv, 0xdeadbeef)
		_, ok = decode_conv_id(buf[:3])
		testing.expect(t, !ok)

		room: Room
		room, ok = decode_room(encode_room(&buf, 77))
		testing.expect(t, ok)
		testing.expect_value(t, room, 77)
	}
	{
		buf: [CONV_SUBSCRIBE_SIZE]u8
		conv, on, ok := decode_conv_subscribe(encode_conv_subscribe(&buf, 12, true))
		testing.expect(t, ok)
		testing.expect_value(t, conv, 12)
		testing.expect(t, on)
		_, on, ok = decode_conv_subscribe(encode_conv_subscribe(&buf, 12, false))
		testing.expect(t, ok && !on)
	}
	{
		accounts := []Account_Id{3, 1, 4, 1, 5}
		out: [2 + 5 * 4]u8
		buf: [8]Account_Id
		got, ok := decode_conv_members(encode_conv_members(out[:], accounts), buf[:])
		testing.expect(t, ok)
		testing.expect_value(t, len(got), 5)
		testing.expect_value(t, got[2], 4)
		// Room for three takes three.
		got, ok = decode_conv_members(encode_conv_members(out[:2 + 3 * 4], accounts), buf[:])
		testing.expect(t, ok)
		testing.expect_value(t, len(got), 3)
		_, ok = decode_conv_members(out[:5], buf[:])
		testing.expect(t, !ok)
	}
}

@(test)
test_read_bodies :: proc(t: ^testing.T) {
	mark_buf: [MARK_READ_SIZE]u8
	conv, id, ok := decode_mark_read(encode_mark_read(&mark_buf, 4, 99))
	testing.expect(t, ok && conv == 4 && id == 99)
	_, _, ok = decode_mark_read(mark_buf[:5])
	testing.expect(t, !ok)

	notify_buf: [CONV_NOTIFY_SIZE]u8
	c2, level, ok2 := decode_conv_notify(encode_conv_notify(&notify_buf, 4, .None))
	testing.expect(t, ok2 && c2 == 4 && level == .None)
	notify_buf[4] = 3
	_, _, ok2 = decode_conv_notify(notify_buf[:])
	testing.expect(t, !ok2)

	read_buf: [READ_CHANGED_SIZE]u8
	want := Read_State{conv = 4, read = 120, unread = 3, mentions = 1}
	got, ok3 := decode_read_changed(encode_read_changed(&read_buf, want))
	testing.expect(t, ok3)
	testing.expect_value(t, got, want)
	got, _ = decode_read_changed(encode_read_changed(&read_buf, {conv = 1, unread = 1000}))
	testing.expect_value(t, got.unread, UNREAD_CAP)
	_, ok3 = decode_read_changed(read_buf[:3])
	testing.expect(t, !ok3)
}

@(test)
test_dm_record :: proc(t: ^testing.T) {
	buf: [CONV_MAX_SIZE]u8
	body := encode_conv(buf[:], {id = 12, kind = .DM, member = true, a = 3, b = 9, last = 40})
	got, ok := decode_conv(body)
	testing.expect(t, ok)
	testing.expect_value(t, got.kind, Conv_Kind.DM)
	testing.expect_value(t, got.a, Account_Id(3))
	testing.expect_value(t, got.b, Account_Id(9))
	testing.expect_value(t, got.name, "")

	open_buf: [4]u8
	account, open_ok := decode_account_id(encode_account_id(&open_buf, 9))
	testing.expect(t, open_ok && account == 9)
}

@(test)
test_buddies_and_last_seen :: proc(t: ^testing.T) {
	buf: [BUDDY_SET_SIZE]u8
	account, on, ok := decode_buddy(encode_buddy(&buf, 7, true))
	testing.expect(t, ok && on)
	testing.expect_value(t, account, Account_Id(7))
	_, _, ok = decode_buddy(encode_buddy(&buf, 0, true))
	testing.expect(t, !ok, "a buddy of account 0")

	asked := [3]Account_Id{1, 2, 3}
	ask_buf: [64]u8
	got_buf: [8]Account_Id
	got, ask_ok := decode_last_seen_ask(encode_last_seen_ask(ask_buf[:], asked[:]), got_buf[:])
	testing.expect(t, ask_ok)
	testing.expect_value(t, len(got), 3)
	_, ask_ok = decode_last_seen_ask(encode_last_seen_ask(ask_buf[:], asked[:]), got_buf[:2])
	testing.expect(t, !ask_ok, "more than fit")

	entries := [2]Last_Seen_Entry{{account = 1, time = 1000}, {account = 2, time = LAST_SEEN_HIDDEN}}
	answer_buf: [64]u8
	entry_buf: [4]Last_Seen_Entry
	back, answer_ok := decode_last_seen_answer(encode_last_seen_answer(answer_buf[:], entries[:]), entry_buf[:])
	testing.expect(t, answer_ok)
	testing.expect_value(t, len(back), 2)
	if len(back) == 2 {
		testing.expect_value(t, back[1].time, LAST_SEEN_HIDDEN)
	}
}

@(test)
test_conv_update :: proc(t: ^testing.T) {
	buf: [CONV_UPDATE_MAX_SIZE]u8
	u, ok := decode_conv_update(encode_conv_update(buf[:], {conv = 3, mask = CONV_UPDATE_NAME | CONV_UPDATE_POSITION, name = "Games", position = 2}))
	testing.expect(t, ok)
	testing.expect(t, u.conv == 3 && u.mask == CONV_UPDATE_NAME | CONV_UPDATE_POSITION && u.name == "Games" && u.topic == "" && u.position == 2)
	body := encode_conv_update(buf[:], {conv = 3, mask = 0x80})
	_, ok = decode_conv_update(body)
	testing.expect(t, !ok)

	mbuf: [CONV_MEMBER_SET_SIZE]u8
	conv, account, on, m_ok := decode_conv_member_set(encode_conv_member_set(&mbuf, 4, 8, true))
	testing.expect(t, m_ok && conv == 4 && account == 8 && on)
	_, _, _, m_ok = decode_conv_member_set(mbuf[:8])
	testing.expect(t, !m_ok)
}

@(test)
test_calls :: proc(t: ^testing.T) {
	testing.expect_value(t, room_call(call_room(7)), 7)
	testing.expect_value(t, room_call(Room(7)), 0)
	testing.expect_value(t, room_call(0), 0)

	ring_buf: [CALL_RING_SIZE]u8
	id, from, ok := decode_call_ring(encode_call_ring(&ring_buf, 3, 9))
	testing.expect(t, ok && id == 3 && from == 9)
	_, _, ok = decode_call_ring(ring_buf[:7])
	testing.expect(t, !ok)

	changed_buf: [CALL_CHANGED_SIZE]u8
	c := Call_Change{id = 3, state = .Ended, reason = .Declined, caller = 4, callee = 5}
	got, c_ok := decode_call_changed(encode_call_changed(&changed_buf, c))
	testing.expect(t, c_ok)
	testing.expect_value(t, got, c)
	changed_buf[4] = 9
	_, c_ok = decode_call_changed(changed_buf[:])
	testing.expect(t, !c_ok)
}

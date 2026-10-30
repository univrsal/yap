#+build !wasi
package proto

import "core:slice"
import "core:strings"
import "core:testing"

@(test)
test_conv_record :: proc(t: ^testing.T) {
	buf: [CONV_MAX_SIZE]u8
	topic := make([]u8, MAX_TOPIC_SIZE, context.temp_allocator)
	for &b in topic {
		b = 't'
	}
	name := strings.repeat("n", MAX_CHANNEL_NAME_SIZE, context.temp_allocator)
	c := Conv {
		id        = 9,
		kind      = .Channel,
		flags     = {.Home},
		name      = name,
		topic     = string(topic),
		member    = true,
		last      = 1234,
		read      = 1200,
		unread    = 7,
		mentions  = 2,
		notify    = .Mentions,
		position  = 70000,
		last_time = 1_700_000_000_000,
		rights    = {.See, .React},
	}
	// No real conversation has a name and accounts both, but the largest
	// record has room for both.
	conv_set_accounts(&c, {1, 2, 3, 4, 5, 6, 7, 8})
	body := encode_conv(buf[:], c)
	testing.expect(t, body != nil)
	// The largest possible conversation is exactly CONV_MAX_SIZE bytes.
	testing.expect_value(t, len(body), CONV_MAX_SIZE)
	got, ok := decode_conv(body)
	testing.expect(t, ok)
	testing.expect_value(t, got.id, c.id)
	testing.expect_value(t, got.kind, c.kind)
	testing.expect_value(t, got.flags, c.flags)
	testing.expect_value(t, got.name, c.name)
	testing.expect_value(t, got.topic, c.topic)
	testing.expect(t, got.member && !got.admin)
	c.admin = true
	admin, admin_ok := decode_conv(encode_conv(buf[:], c))
	testing.expect(t, admin_ok && admin.member && admin.admin)
	testing.expect_value(t, got.last, c.last)
	testing.expect_value(t, got.read, c.read)
	testing.expect_value(t, got.last_time, c.last_time)
	testing.expect_value(t, got.unread, 7)
	testing.expect_value(t, got.mentions, 2)
	testing.expect_value(t, got.notify, Notify_Level.Mentions)
	testing.expect_value(t, got.position, c.position)
	testing.expect_value(t, got.rights, c.rights)

	// Counts above the cap are sent as the cap, and an unknown notify level
	// from a newer server is treated as the default.
	many := c
	many.unread = 5000
	got, ok = decode_conv(encode_conv(buf[:], many))
	testing.expect_value(t, got.unread, UNREAD_CAP)
	body = encode_conv(buf[:], c)
	body[len(body) - 15] = 9 // the notify level, before the position, the last time and the rights
	got, ok = decode_conv(body)
	testing.expect(t, ok)
	testing.expect_value(t, got.notify, Notify_Level.All)
	body = encode_conv(buf[:], c)

	// A record from an older server has no rights, which means all of them.
	got, ok = decode_conv(body[:len(body) - 2])
	testing.expect(t, ok)
	testing.expect_value(t, got.rights, CONV_RIGHTS_ALL)
	text_only := c
	text_only.flags += {.Text_Only}
	got, ok = decode_conv(encode_conv(buf[:], text_only)[:len(body) - 2])
	testing.expect(t, ok)
	testing.expect_value(t, got.rights, CONV_RIGHTS_ALL - {.Voice, .Speak, .Video})
	// Rights that break the rules between them are settled when read.
	odd := c
	odd.rights = {.Write, .Edit}
	got, _ = decode_conv(encode_conv(buf[:], odd))
	testing.expect_value(t, got.rights, Conv_Rights{})
	odd.rights = {.See, .Edit, .Delete, .Voice}
	got, _ = decode_conv(encode_conv(buf[:], odd))
	testing.expect_value(t, got.rights, Conv_Rights{.See, .Voice})
	// Speaking and video take Voice, and survive the trip in the second byte.
	odd.rights = {.See, .Speak, .Video}
	got, _ = decode_conv(encode_conv(buf[:], odd))
	testing.expect_value(t, got.rights, Conv_Rights{.See})
	odd.rights = {.See, .Voice, .Video}
	got, _ = decode_conv(encode_conv(buf[:], odd))
	testing.expect_value(t, got.rights, Conv_Rights{.See, .Voice, .Video})

	_, ok = decode_conv(body[:len(body) - 3])
	testing.expect(t, !ok)
	_, ok = decode_conv(nil)
	testing.expect(t, !ok)
	// A conversation that doesn't fit into the buffer isn't written at all.
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

	// Without room for all of them, only the first ones are encoded.
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
	b, ok := decode_conv_browse(
		encode_conv_browse(&req_buf, {query = "gam", offset = 50, limit = 20}),
	)
	testing.expect(t, ok)
	testing.expect_value(t, b, Browse{query = "gam", offset = 50, limit = 20})
	// The flags are only sent when there are some, and older requests have none.
	body := encode_conv_browse(&req_buf, {query = "gam", limit = 20, flags = BROWSE_ALL})
	testing.expect_value(t, len(body), 2 + 3 + 2 + 2 + 1)
	b, ok = decode_conv_browse(body)
	testing.expect(t, ok)
	testing.expect_value(t, b, Browse{query = "gam", limit = 20, flags = BROWSE_ALL})
	testing.expect_value(
		t,
		len(encode_conv_browse(&req_buf, {query = "gam", limit = 20})),
		2 + 3 + 2 + 2,
	)
	// An empty request asks for the first page of all conversations.
	b, ok = decode_conv_browse(nil)
	testing.expect(t, ok)
	testing.expect_value(t, b, Browse{limit = BROWSE_PAGE})
	// A limit of 0, or one above MAX_BROWSE_LIMIT, is refused.
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
	// If not all conversations fit, the page is marked as having more.
	more, got, read = decode_browse_page(
		encode_browse_page(out[:1 + 2 + CONV_MAX_SIZE], false, convs),
		buf[:],
	)
	testing.expect(t, read && more)
	testing.expect_value(t, len(got), 1)
}

@(test)
test_conv_bodies :: proc(t: ^testing.T) {
	{
		buf: [CONV_CREATE_MAX_SIZE]u8
		body := encode_conv_create(buf[:], "Gaming", "for games", true)
		name, topic, flags, ok := decode_conv_create(body)
		testing.expect(t, ok)
		testing.expect_value(t, name, "Gaming")
		testing.expect_value(t, topic, "for games")
		testing.expect_value(t, flags, Conv_Flags{.Private})
		// Without Default or Text_Only, the body is what an older server knows.
		testing.expect_value(t, len(body), 2 + 6 + 2 + 9 + 1)
		_, _, _, ok = decode_conv_create(buf[:3])
		testing.expect(t, !ok)
		// Only Default and Text_Only can be asked for besides Private.
		body = encode_conv_create(buf[:], "News", "", false, {.Default, .Text_Only, .Home})
		_, _, flags, ok = decode_conv_create(body)
		testing.expect(t, ok)
		testing.expect_value(t, flags, Conv_Flags{.Default, .Text_Only})
		body[len(body) - 1] = 0xff
		_, _, flags, _ = decode_conv_create(body)
		testing.expect_value(t, flags, CONV_SETTABLE_FLAGS)
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
		// A buffer with room for three members holds exactly three.
		got, ok = decode_conv_members(encode_conv_members(out[:2 + 3 * 4], accounts), buf[:])
		testing.expect(t, ok)
		testing.expect_value(t, len(got), 3)
		_, ok = decode_conv_members(out[:5], buf[:])
		testing.expect(t, !ok)
		// Without room for the admins, they are left out.
		admins_buf: [8]Account_Id
		admins: []Account_Id
		admins, ok = decode_conv_admins(
			encode_conv_members(out[:2 + 3 * 4], accounts, {4}),
			admins_buf[:],
		)
		testing.expect(t, ok && len(admins) == 0)
		big: [2 + 5 * 4 + 2 + 2 * 4]u8
		body := encode_conv_members(big[:], accounts, {4, 5})
		got, ok = decode_conv_members(body, buf[:])
		testing.expect(t, ok && len(got) == 5)
		admins, ok = decode_conv_admins(body, admins_buf[:])
		testing.expect(t, ok && len(admins) == 2 && admins[0] == 4 && admins[1] == 5)
		_, ok = decode_conv_admins(body[:len(body) - 1], admins_buf[:])
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
	want := Read_State {
		conv     = 4,
		read     = 120,
		unread   = 3,
		mentions = 1,
	}
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
	dm := Conv {
		id     = 12,
		kind   = .DM,
		member = true,
		last   = 40,
	}
	conv_set_accounts(&dm, {9, 3})
	body := encode_conv(buf[:], dm)
	got, ok := decode_conv(body)
	testing.expect(t, ok)
	testing.expect_value(t, got.kind, Conv_Kind.DM)
	testing.expect(t, slice.equal(conv_accounts(&got), []Account_Id{3, 9}))
	testing.expect_value(t, got.name, "")
	testing.expect_value(t, got.last, Msg_Id(40))

	open_buf: [4]u8
	account, open_ok := decode_account_id(encode_account_id(&open_buf, 9))
	testing.expect(t, open_ok && account == 9)
}

@(test)
test_group_record :: proc(t: ^testing.T) {
	buf: [CONV_MAX_SIZE]u8
	group := Conv {
		id   = 7,
		kind = .Group,
		last = 5,
	}
	conv_set_accounts(&group, {8, 2, 5, 1, 4, 3, 7, 6})
	got, ok := decode_conv(encode_conv(buf[:], group))
	testing.expect(t, ok)
	testing.expect_value(t, got.kind, Conv_Kind.Group)
	testing.expect(t, slice.equal(conv_accounts(&got), []Account_Id{1, 2, 3, 4, 5, 6, 7, 8}))
	testing.expect_value(t, got.last, Msg_Id(5))

	// A channel lists nobody.
	channel, channel_ok := decode_conv(encode_conv(buf[:], {id = 1, name = "lobby"}))
	testing.expect(t, channel_ok && len(conv_accounts(&channel)) == 0 && channel.name == "lobby")

	// More accounts than a group can have don't decode.
	body := encode_conv(buf[:], group)
	bad := slice.clone(body, context.temp_allocator)
	bad[4 + 1 + 1 + 2 + 2] = MAX_GROUP_MEMBERS + 1
	_, bad_ok := decode_conv(bad)
	testing.expect(t, !bad_ok)
}

@(test)
test_group_open :: proc(t: ^testing.T) {
	out: [GROUP_OPEN_MAX_SIZE]u8
	buf: [MAX_GROUP_MEMBERS - 1]Account_Id
	others, ok := decode_group_open(encode_group_open(&out, {4, 2}), &buf)
	testing.expect(t, ok && slice.equal(others, []Account_Id{4, 2}))
	others, ok = decode_group_open(encode_group_open(&out, {1, 2, 3, 4, 5, 6, 7}), &buf)
	testing.expect(t, ok && len(others) == 7)

	// One other is a DM, eight others are too many.
	testing.expect(t, encode_group_open(&out, {4}) == nil)
	testing.expect(t, encode_group_open(&out, {1, 2, 3, 4, 5, 6, 7, 8}) == nil)
	_, ok = decode_group_open({1, 4, 0, 0, 0}, &buf)
	testing.expect(t, !ok)
	_, ok = decode_group_open({8, 1, 0, 0, 0, 2, 0, 0, 0}, &buf)
	testing.expect(t, !ok)
	// Nobody twice, nobody 0, nothing after.
	_, ok = decode_group_open({2, 4, 0, 0, 0, 4, 0, 0, 0}, &buf)
	testing.expect(t, !ok)
	_, ok = decode_group_open({2, 4, 0, 0, 0, 0, 0, 0, 0}, &buf)
	testing.expect(t, !ok)
	_, ok = decode_group_open({2, 4, 0, 0, 0, 5, 0, 0, 0, 1}, &buf)
	testing.expect(t, !ok)
}

@(test)
test_buddies_and_last_seen :: proc(t: ^testing.T) {
	buf: [BUDDY_SET_SIZE]u8
	account, on, ok := decode_buddy(encode_buddy(&buf, 7, true))
	testing.expect(t, ok && on)
	testing.expect_value(t, account, Account_Id(7))
	_, _, ok = decode_buddy(encode_buddy(&buf, 0, true))
	testing.expect(t, !ok, "a buddy entry for account 0 was accepted")

	asked := [3]Account_Id{1, 2, 3}
	ask_buf: [64]u8
	got_buf: [8]Account_Id
	got, ask_ok := decode_last_seen_ask(encode_last_seen_ask(ask_buf[:], asked[:]), got_buf[:])
	testing.expect(t, ask_ok)
	testing.expect_value(t, len(got), 3)
	_, ask_ok = decode_last_seen_ask(encode_last_seen_ask(ask_buf[:], asked[:]), got_buf[:2])
	testing.expect(t, !ask_ok, "more accounts than fit in the buffer were accepted")

	entries := [2]Last_Seen_Entry {
		{account = 1, time = 1000},
		{account = 2, time = LAST_SEEN_HIDDEN},
	}
	answer_buf: [64]u8
	entry_buf: [4]Last_Seen_Entry
	back, answer_ok := decode_last_seen_answer(
		encode_last_seen_answer(answer_buf[:], entries[:]),
		entry_buf[:],
	)
	testing.expect(t, answer_ok)
	testing.expect_value(t, len(back), 2)
	if len(back) == 2 {
		testing.expect_value(t, back[1].time, LAST_SEEN_HIDDEN)
	}
}

@(test)
test_conv_update :: proc(t: ^testing.T) {
	buf: [CONV_UPDATE_MAX_SIZE]u8
	u, ok := decode_conv_update(
		encode_conv_update(
			buf[:],
			{
				conv = 3,
				mask = CONV_UPDATE_NAME | CONV_UPDATE_POSITION,
				name = "Games",
				position = 2,
			},
		),
	)
	testing.expect(t, ok)
	testing.expect(
		t,
		u.conv == 3 &&
		u.mask == CONV_UPDATE_NAME | CONV_UPDATE_POSITION &&
		u.name == "Games" &&
		u.topic == "" &&
		u.position == 2,
	)
	body := encode_conv_update(buf[:], {conv = 3, mask = 0x80})
	_, ok = decode_conv_update(body)
	testing.expect(t, !ok)

	// The flags are only there with their bit.
	body = encode_conv_update(buf[:], {conv = 3, mask = CONV_UPDATE_FLAGS, flags = {.Text_Only}})
	u, ok = decode_conv_update(body)
	testing.expect(t, ok && u.flags == {.Text_Only})
	_, ok = decode_conv_update(body[:len(body) - 1])
	testing.expect(t, !ok)
	plain := encode_conv_update(buf[:], {conv = 3, mask = CONV_UPDATE_TOPIC, flags = {.Default}})
	testing.expect_value(t, len(plain), len(body) - 1)

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
	c := Call_Change {
		id     = 3,
		state  = .Ended,
		reason = .Declined,
		caller = 4,
		callee = 5,
	}
	got, c_ok := decode_call_changed(encode_call_changed(&changed_buf, c))
	testing.expect(t, c_ok)
	testing.expect_value(t, got, c)
	changed_buf[4] = 9
	_, c_ok = decode_call_changed(changed_buf[:])
	testing.expect(t, !c_ok)
}

@(test)
test_conv_rights :: proc(t: ^testing.T) {
	testing.expect_value(t, conv_rights_default(.Channel, {}), CONV_RIGHTS_ALL)
	testing.expect_value(
		t,
		conv_rights_default(.DM, {}),
		CONV_RIGHTS_ALL - {.Voice, .Speak, .Video},
	)
	testing.expect_value(
		t,
		conv_rights_default(.Group, {}),
		CONV_RIGHTS_ALL - {.Voice, .Speak, .Video},
	)
	testing.expect_value(t, conv_rights_settle({.See, .Voice}, {.Text_Only}), Conv_Rights{.See})
	testing.expect_value(t, conv_rights_settle({.See, .Attach}, {}), Conv_Rights{.See})
	testing.expect_value(
		t,
		conv_rights_settle({.See, .Write, .Attach}, {}),
		Conv_Rights{.See, .Write, .Attach},
	)

	entries := []Role_Rights{{EVERYONE_ROLE, {.See, .React}}, {7, CONV_RIGHTS_ALL}}
	buf: [CONV_RIGHTS_SET_MAX_SIZE]u8
	got_buf: [MAX_ROLES]Role_Rights
	conv, got, ok := decode_conv_rights_set(encode_conv_rights_set(buf[:], 5, entries), got_buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, conv, 5)
	testing.expect_value(t, len(got), 2)
	if len(got) == 2 {
		testing.expect_value(t, got[0], entries[0])
		testing.expect_value(t, got[1], entries[1])
	}
	body := encode_conv_rights_set(buf[:], 5, entries)
	_, _, ok = decode_conv_rights_set(body[:len(body) - 1], got_buf[:])
	testing.expect(t, !ok)
	// Trailing bytes and more entries than the buffer holds are refused.
	extra := make([]u8, len(body) + 1, context.temp_allocator)
	copy(extra, body)
	_, _, ok = decode_conv_rights_set(extra, got_buf[:])
	testing.expect(t, !ok)
	_, _, ok = decode_conv_rights_set(body, got_buf[:1])
	testing.expect(t, !ok)
	// Unknown rights are dropped.
	body[len(body) - 1] = 0xff
	_, got, _ = decode_conv_rights_set(body, got_buf[:])
	testing.expect_value(t, got[1].rights, CONV_RIGHTS_ALL)

	map_buf: [RIGHTS_MAP_MAX_SIZE]u8
	got, ok = decode_rights_map(encode_rights_map(map_buf[:], entries), got_buf[:])
	testing.expect(t, ok && len(got) == 2 && got[0] == entries[0])
	too_many := make([]Role_Rights, MAX_ROLES + 1, context.temp_allocator)
	testing.expect(t, encode_rights_map(map_buf[:], too_many) == nil)
}

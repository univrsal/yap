#+build !wasi
package conn

import "core:strings"
import "core:testing"

import "common:proto"

// Tests of administering a channel (conv_admin.odin): what is asked of the
// server for each command, how a rights map written as text is read, and what
// the channel settings are shown while its rights map is fetched.

@(private = "file")
open_channel_admin :: proc(tc: ^Test_Conn) -> ^View {
	tc_open(tc)
	tc.c.auth.me = 1
	tc.c.auth.state = .Done
	tc_account(tc, 1, "root")
	tc_account(tc, 2, "alice", "Alice")
	tc_account(tc, 3, "bob", "Robert")
	tc_conv(tc, 4, "Lobby")
	tc_conv(tc, 5, "Gaming")
	tc.c.convs.viewing = 4
	buf: [proto.ROLE_MAX_SIZE]u8
	tc_event(
		tc,
		.Role_Changed,
		proto.encode_role(buf[:], {id = proto.EVERYONE_ROLE, name = "everyone"}),
	)
	tc_event(tc, .Role_Changed, proto.encode_role(buf[:], {id = 10, name = "Mods", position = 1}))
	return tc_view(tc)
}

@(private = "file")
rights_set_sent :: proc(
	t: ^testing.T,
	tc: ^Test_Conn,
	buf: []proto.Role_Rights,
) -> (
	conv: proto.Conv_Id,
	entries: []proto.Role_Rights,
	id: u32,
	ok: bool,
) {
	r := tc_one(t, tc, .Conv_Rights_Set) or_return
	conv, entries, ok = proto.decode_conv_rights_set(r.body, buf)
	testing.expect(t, ok, "the Conv_Rights_Set could not be read")
	return conv, entries, r.id, ok
}

@(test)
test_conv_rights_parse :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_channel_admin(&tc)
	defer tc_close(&tc)
	c := &tc.c
	buf: [proto.MAX_ROLES]proto.Role_Rights

	// Roles by name, in any case; rights in any case; blanks between words.
	entries, ok := conv_rights_parse(c, "  everyone=see,react   MODS=See,write,EDIT ", buf[:])
	testing.expect(t, ok)
	if testing.expect_value(t, len(entries), 2) {
		testing.expect_value(t, entries[0].role, proto.EVERYONE_ROLE)
		testing.expect_value(t, entries[0].rights, proto.Conv_Rights{.See, .React})
		testing.expect_value(t, entries[1].role, proto.Role_Id(10))
		testing.expect_value(t, entries[1].rights, proto.Conv_Rights{.See, .Write, .Edit})
	}

	// A role by its number, and no rights written three ways.
	entries, ok = conv_rights_parse(c, "10=none everyone= ", buf[:])
	testing.expect(t, ok)
	if testing.expect_value(t, len(entries), 2) {
		testing.expect_value(t, entries[0].role, proto.Role_Id(10))
		testing.expect_value(t, entries[0].rights, proto.Conv_Rights{})
		testing.expect_value(t, entries[1].rights, proto.Conv_Rights{})
	}
	entries, ok = conv_rights_parse(c, "mods", buf[:])
	testing.expect(t, ok && len(entries) == 1 && entries[0].rights == {})

	// Every right has a name.
	all := strings.builder_make(context.temp_allocator)
	every: proto.Conv_Rights
	strings.write_string(&all, "mods=")
	for r, i in proto.Conv_Right {
		if i > 0 {
			strings.write_byte(&all, ',')
		}
		strings.write_string(&all, rights_text({r}))
		every += {r}
	}
	entries, ok = conv_rights_parse(c, strings.to_string(all), buf[:])
	testing.expect(t, ok && len(entries) == 1)
	if len(entries) == 1 {
		testing.expect_value(t, entries[0].rights, every)
	}

	// Nothing is a map with no entries.
	entries, ok = conv_rights_parse(c, "", buf[:])
	testing.expect(t, ok && len(entries) == 0)

	// A role that doesn't exist, by name or by number, a right that doesn't, and
	// more roles than fit: the whole map is refused.
	_, ok = conv_rights_parse(c, "everyone=see nobody=see", buf[:])
	testing.expect(t, !ok)
	_, ok = conv_rights_parse(c, "99=see", buf[:])
	testing.expect(t, !ok)
	_, ok = conv_rights_parse(c, "mods=see,fly", buf[:])
	testing.expect(t, !ok)
	_, ok = conv_rights_parse(c, "everyone=see mods=see", buf[:1])
	testing.expect(t, !ok)
}

@(test)
test_rights_text :: proc(t: ^testing.T) {
	testing.expect_value(t, rights_text({}), "none")
	testing.expect_value(t, rights_text({.See}), "see")
	testing.expect_value(t, rights_text({.Video, .See, .Write}), "see, write, video")
}

@(test)
test_conv_rights_text_set :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_channel_admin(&tc)
	defer tc_close(&tc)
	c := &tc.c
	buf: [proto.MAX_ROLES]proto.Role_Rights

	// The channel being looked at, unless another is named.
	conv_rights_text_set(c, {text = "everyone=see mods=see,write"})
	conv, entries, _, ok := rights_set_sent(t, &tc, buf[:])
	if ok {
		testing.expect_value(t, conv, proto.Conv_Id(4))
		testing.expect_value(t, len(entries), 2)
	}
	conv_rights_text_set(c, {conv = 5, text = "everyone=none"})
	conv, entries, _, ok = rights_set_sent(t, &tc, buf[:])
	if ok {
		testing.expect_value(t, conv, proto.Conv_Id(5))
		testing.expect_value(t, len(entries), 1)
	}

	// A map that can't be read sends nothing.
	conv_rights_text_set(c, {text = "everyone=see nobody=write"})
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
}

@(test)
test_conv_rights_fetch :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_channel_admin(&tc)
	defer tc_close(&tc)
	c := &tc.c

	// While it is on its way, the settings show it loading.
	conv_rights_fetch(c, 5)
	r, ok := tc_one(t, &tc, .Conv_Rights_Get)
	testing.expect(t, ok)
	conv, _ := proto.decode_conv_id(r.body)
	testing.expect_value(t, conv, proto.Conv_Id(5))
	testing.expect_value(t, v.rights_map.conv, proto.Conv_Id(5))
	testing.expect(t, v.rights_map.loading)
	count := v.rights_map.count

	map_buf: [proto.RIGHTS_MAP_MAX_SIZE]u8
	answer := proto.encode_rights_map(
		map_buf[:],
		{{proto.EVERYONE_ROLE, {.See}}, {10, {.See, .Write, .Delete}}},
	)
	tc_answer(&tc, r.id, .Ok, answer)
	testing.expect(t, !v.rights_map.loading)
	testing.expect_value(t, v.rights_map.count, count + 1)
	if testing.expect_value(t, len(v.rights_map.entries), 2) {
		testing.expect_value(t, v.rights_map.entries[1].role, proto.Role_Id(10))
		testing.expect_value(
			t,
			v.rights_map.entries[1].rights,
			proto.Conv_Rights{.See, .Write, .Delete},
		)
	}

	// Refused: the map is emptied and the user told why.
	conv_rights_fetch(c, 5)
	r, _ = tc_one(t, &tc, .Conv_Rights_Get)
	tc_answer(&tc, r.id, .Denied)
	testing.expect(t, !v.rights_map.loading)
	testing.expect_value(t, len(v.rights_map.entries), 0)
	testing.expect(t, !v.notice.ok)
	testing.expect_value(t, v.notice.text, status_text(.Denied, "role, account or channel"))

	// An answer that can't be read is treated as an invalid one.
	conv_rights_fetch(c, 4)
	r, _ = tc_one(t, &tc, .Conv_Rights_Get)
	tc_answer(&tc, r.id, .Ok, []u8{3, 1})
	testing.expect(t, !v.rights_map.loading)
	testing.expect_value(t, len(v.rights_map.entries), 0)
	testing.expect_value(t, v.notice.text, status_text(.Invalid, "role, account or channel"))

	// Lost with the connection: it stops loading, and nobody is told.
	conv_rights_fetch(c, 4)
	_, _ = tc_one(t, &tc, .Conv_Rights_Get)
	notices := v.notice.count
	tc_restart(&tc)
	testing.expect(t, !v.rights_map.loading)
	testing.expect_value(t, v.notice.count, notices)

	// No channel, no request.
	conv_rights_fetch(c, 0)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
}

@(test)
test_conv_rights_set :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_channel_admin(&tc)
	defer tc_close(&tc)
	c := &tc.c
	buf: [proto.MAX_ROLES]proto.Role_Rights

	// The settings show channel 5's map, so once a change to it is done, the map
	// is fetched again to show what the server made of it.
	conv_rights_fetch(c, 5)
	r, _ := tc_one(t, &tc, .Conv_Rights_Get)
	tc_answer(&tc, r.id, .Ok, []u8{0})
	conv_rights_set(c, {conv = 5, entries = {{proto.EVERYONE_ROLE, {.See}}}})
	_, entries, id, ok := rights_set_sent(t, &tc, buf[:])
	if ok {
		testing.expect_value(t, entries[0].rights, proto.Conv_Rights{.See})
	}
	tc_answer(&tc, id, .Ok)
	r, ok = tc_one(t, &tc, .Conv_Rights_Get)
	if ok {
		conv, _ := proto.decode_conv_id(r.body)
		testing.expect_value(t, conv, proto.Conv_Id(5))
	}
	tc_answer(&tc, r.id, .Ok, []u8{0})

	// A change to another channel, or one that failed, fetches nothing.
	conv_rights_set(c, {conv = 4, entries = {{proto.EVERYONE_ROLE, {}}}})
	_, _, id, _ = rights_set_sent(t, &tc, buf[:])
	tc_answer(&tc, id, .Ok)
	conv_rights_set(c, {conv = 5, entries = {{proto.EVERYONE_ROLE, {}}}})
	_, _, id, _ = rights_set_sent(t, &tc, buf[:])
	tc_answer(&tc, id, .Denied)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	testing.expect_value(t, v.notice.text, status_text(.Denied, "role, account or channel"))

	// More entries than there can be roles is not sent.
	many := make([]proto.Role_Rights, proto.MAX_ROLES + 1, context.temp_allocator)
	conv_rights_set(c, {conv = 5, entries = many})
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	testing.expect_value(t, v.notice.text, "There are too many roles in that.")
}

@(test)
test_conv_update :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_channel_admin(&tc)
	defer tc_close(&tc)
	c := &tc.c

	conv_update(
		c,
		{mask = proto.CONV_UPDATE_NAME | proto.CONV_UPDATE_TOPIC, name = "Hall", topic = "Hi"},
	)
	r, ok := tc_one(t, &tc, .Conv_Update)
	testing.expect(t, ok)
	u, u_ok := proto.decode_conv_update(r.body)
	testing.expect(t, u_ok)
	testing.expect_value(t, u.conv, proto.Conv_Id(4))
	testing.expect_value(t, u.mask, u8(proto.CONV_UPDATE_NAME | proto.CONV_UPDATE_TOPIC))
	testing.expect_value(t, u.name, "Hall")
	testing.expect_value(t, u.topic, "Hi")

	conv_update(c, {conv = 5, mask = proto.CONV_UPDATE_POSITION, position = 3})
	r, ok = tc_one(t, &tc, .Conv_Update)
	u, _ = proto.decode_conv_update(r.body)
	testing.expect_value(t, u.conv, proto.Conv_Id(5))
	testing.expect_value(t, u.position, 3)

	// A name and topic too long for a request are not sent.
	long := strings.repeat("x", proto.CONV_UPDATE_MAX_SIZE, context.temp_allocator)
	conv_update(c, {mask = proto.CONV_UPDATE_TOPIC, topic = long})
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	testing.expect_value(t, v.notice.text, "The channel name or topic is too long.")
	testing.expect(t, !v.notice.ok)
}

@(test)
test_conv_flag_set :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_channel_admin(&tc)
	defer tc_close(&tc)
	c := &tc.c
	info := c.convs.convs[4]
	info.flags = {.Home, .Default}
	c.convs.convs[4] = info

	// One flag changes and the other is kept. Flags that Conv_Update doesn't
	// set (Home) are not sent.
	conv_flag_set(c, {flag = .Text_Only, on = true})
	r, ok := tc_one(t, &tc, .Conv_Update)
	testing.expect(t, ok)
	u, _ := proto.decode_conv_update(r.body)
	testing.expect_value(t, u.conv, proto.Conv_Id(4))
	testing.expect_value(t, u.mask, u8(proto.CONV_UPDATE_FLAGS))
	testing.expect_value(t, u.flags, proto.Conv_Flags{.Default, .Text_Only})

	conv_flag_set(c, {conv = 4, flag = .Default, on = false})
	r, _ = tc_one(t, &tc, .Conv_Update)
	u, _ = proto.decode_conv_update(r.body)
	testing.expect_value(t, u.flags, proto.Conv_Flags{})

	// Not one of our channels.
	conv_flag_set(c, {conv = 99, flag = .Default, on = true})
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
}

// A change to a channel may change the lists of channels, which are fetched
// again once the last of several changes (moving a channel) is answered.
@(test)
test_conv_changes_refresh_the_lists :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_channel_admin(&tc)
	defer tc_close(&tc)
	c := &tc.c
	c.convs.all_wanted = true

	conv_update(c, {conv = 4, mask = proto.CONV_UPDATE_POSITION, position = 1})
	conv_update(c, {conv = 5, mask = proto.CONV_UPDATE_POSITION, position = 0})
	sent := tc_sent(t, &tc)
	if !testing.expect_value(t, len(sent), 2) {
		return
	}
	testing.expect_value(t, c.convs.changing, 2)
	tc_answer(&tc, sent[0].id, .Ok)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	tc_answer(&tc, sent[1].id, .Ok)
	r, ok := tc_one(t, &tc, .Conv_Browse)
	testing.expect(t, ok)
	b, _ := proto.decode_conv_browse(r.body)
	testing.expect_value(t, b.flags, proto.BROWSE_ALL)
	// The list itself doesn't matter here. (A refusal would mean the lists are
	// not ours to manage, and they would not be fetched again.)
	tc_answer(&tc, r.id, .Invalid)

	// A refusal is shown, and the lists are fetched again all the same.
	conv_delete(c, 0)
	r, ok = tc_one(t, &tc, .Conv_Delete)
	testing.expect(t, ok)
	conv, _ := proto.decode_conv_id(r.body)
	testing.expect_value(t, conv, proto.Conv_Id(4))
	tc_answer(&tc, r.id, .Denied)
	testing.expect(t, !v.notice.ok)
	_, ok = tc_one(t, &tc, .Conv_Browse)
	testing.expect(t, ok)
	testing.expect_value(t, c.convs.changing, 0)

	// Lost with the connection: nothing is fetched until there is a connection
	// again, and the count doesn't go wrong.
	conv_delete(c, 5)
	r, _ = tc_one(t, &tc, .Conv_Delete)
	conv, _ = proto.decode_conv_id(r.body)
	testing.expect_value(t, conv, proto.Conv_Id(5))
	tc_restart(&tc)
	testing.expect_value(t, c.convs.changing, 0)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
}

@(test)
test_conv_member_and_admin_set :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_channel_admin(&tc)
	defer tc_close(&tc)
	c := &tc.c

	// By display name, in the channel being looked at.
	conv_member_set(c, {name = "Robert", on = true})
	r, ok := tc_one(t, &tc, .Conv_Member_Set)
	testing.expect(t, ok)
	conv, account, on, dec := proto.decode_conv_member_set(r.body)
	testing.expect(t, dec && on)
	testing.expect_value(t, conv, proto.Conv_Id(4))
	testing.expect_value(t, account, proto.Account_Id(3))

	// The members shown are fetched again once it is done.
	c.profiles.members_conv = 4
	tc_answer(&tc, r.id, .Ok)
	r, ok = tc_one(t, &tc, .Conv_Members)
	testing.expect(t, ok)
	tc_answer(&tc, r.id, .Denied)

	// By id, to remove; refused, so nothing is fetched.
	conv_member_set(c, {conv = 5, account = 2, on = false})
	r, _ = tc_one(t, &tc, .Conv_Member_Set)
	conv, account, on, _ = proto.decode_conv_member_set(r.body)
	testing.expect(t, !on)
	testing.expect_value(t, conv, proto.Conv_Id(5))
	testing.expect_value(t, account, proto.Account_Id(2))
	tc_answer(&tc, r.id, .Denied)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)

	conv_admin_set(c, {name = "alice", on = true})
	r, ok = tc_one(t, &tc, .Conv_Admin_Set)
	testing.expect(t, ok)
	conv, account, on, _ = proto.decode_conv_member_set(r.body)
	testing.expect(t, on)
	testing.expect_value(t, conv, proto.Conv_Id(4))
	testing.expect_value(t, account, proto.Account_Id(2))
	tc_answer(&tc, r.id, .Ok)
	r, ok = tc_one(t, &tc, .Conv_Members)
	testing.expect(t, ok)
	tc_answer(&tc, r.id, .Denied)

	// Nobody by that name: nothing is sent.
	conv_member_set(c, {name = "nobody", on = true})
	conv_admin_set(c, {name = "nobody", on = true})
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
}

#+build !wasi
package conn

import "core:strings"
import "core:testing"
import "core:time"

import "common:proto"

// Tests of the conversations we are in (convs.odin): what the server tells us
// about them, what we look at, the voice room, browsing and managing the
// channels, subscribing, creating, and telling the server what we have read.
// Counting unread messages is in convs_test.odin.

@(private = "file")
open_convs :: proc(t: ^testing.T, tc: ^Test_Conn) -> ^View {
	tc_open(tc)
	tc_connect(t, tc)
	c := &tc.c
	c.convs.synced = false
	c.auth.me = 1
	c.auth.state = .Done
	tc_account(tc, 1, "bob", "Bob")
	tc_account(tc, 2, "alice", "Alice")
	return tc_view(tc)
}

@(private = "file")
close_convs :: proc(tc: ^Test_Conn) {
	messages_destroy(&tc.c)
	tc_close(tc)
}

@(private = "file")
channel :: proc(id: proto.Conv_Id, name: string, flags := proto.Conv_Flags{}) -> proto.Conv {
	return {
		id = id,
		kind = .Channel,
		name = name,
		topic = "about it",
		flags = flags,
		member = true,
		rights = proto.CONV_RIGHTS_ALL,
	}
}

// told gives the client a conversation, as the server does with Conv_Changed.
@(private = "file")
told :: proc(tc: ^Test_Conn, record: proto.Conv) {
	buf := make([]u8, 1024, context.temp_allocator)
	tc_event(tc, .Conv_Changed, proto.encode_conv(buf, record))
}

// synced runs a sync that brings these conversations.
@(private = "file")
synced :: proc(tc: ^Test_Conn, records: ..proto.Conv) {
	tc_event(tc, .Sync_Begin)
	for r in records {
		told(tc, r)
	}
	tc_event(tc, .Sync_End)
}

@(private = "file")
requests_of :: proc(t: ^testing.T, tc: ^Test_Conn, op: proto.Request_Op) -> []Test_Request {
	found := make([dynamic]Test_Request, context.temp_allocator)
	for r in tc_sent(t, tc) {
		if r.op == op {
			append(&found, r)
		}
	}
	return found[:]
}

// ---- what the server tells us ----

@(test)
test_conversations_follow_the_server :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_convs(t, &tc)
	defer close_convs(&tc)
	c := &tc.c

	tc_event(&tc, .Sync_Begin)
	lobby := channel(3, "Lobby", {.Home})
	lobby.last = 40
	lobby.read = 38
	lobby.unread = 2
	lobby.mentions = 1
	lobby.notify = .Mentions
	lobby.position = 1
	lobby.admin = true
	told(&tc, lobby)
	info := c.convs.convs[3]
	testing.expect_value(t, info.name, "Lobby")
	testing.expect_value(t, info.topic, "about it")
	testing.expect_value(t, info.last, proto.Msg_Id(40))
	testing.expect_value(t, info.unread, 2)
	testing.expect_value(t, info.mentions, 1)
	testing.expect_value(t, info.notify, proto.Notify_Level.Mentions)
	testing.expect(t, info.admin && .Home in info.flags)
	testing.expect(t, .Voice in info.rights)

	// A DM says whom it is between.
	dm := proto.Conv {
		id            = 5,
		kind          = .DM,
		member        = true,
		account_count = 2,
	}
	dm.accounts[0], dm.accounts[1] = 1, 2
	told(&tc, dm)
	testing.expect_value(t, dm_other(c, c.convs.convs[5]), proto.Account_Id(2))

	// What we are not a member of, and what can't be read, is not ours.
	gone := channel(6, "Elsewhere")
	gone.member = false
	told(&tc, gone)
	tc_event(&tc, .Conv_Changed, []u8{1, 2, 3})
	testing.expect_value(t, len(c.convs.convs), 2)
}

@(test)
test_a_change_does_not_unread_what_we_read :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_convs(t, &tc)
	defer close_convs(&tc)
	c := &tc.c
	told(&tc, channel(3, "Lobby"))
	info := &c.convs.convs[3]
	// We have read further than the server knows, and not told it yet.
	info.last, info.read, info.unread, info.mentions = 50, 50, 0, 0

	stale := channel(3, "Lobby renamed")
	stale.last, stale.read, stale.unread, stale.mentions = 48, 45, 3, 1
	told(&tc, stale)
	info = &c.convs.convs[3]
	testing.expect_value(t, info.name, "Lobby renamed")
	testing.expect_value(t, info.read, proto.Msg_Id(50))
	testing.expect_value(t, info.unread, 0)
	testing.expect_value(t, info.last, proto.Msg_Id(50)) // never goes back

	// A server that is ahead of us is believed.
	ahead := channel(3, "Lobby renamed")
	ahead.last, ahead.read, ahead.unread = 60, 55, 5
	told(&tc, ahead)
	info = &c.convs.convs[3]
	testing.expect_value(t, info.read, proto.Msg_Id(55))
	testing.expect_value(t, info.unread, 5)
	testing.expect_value(t, info.last, proto.Msg_Id(60))
}

@(test)
test_leaving_a_conversation :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_convs(t, &tc)
	defer close_convs(&tc)
	c := &tc.c
	synced(&tc, channel(3, "Lobby", {.Home}), channel(4, "Gaming"))
	conv_view(c, 4)
	testing.expect_value(t, c.convs.viewing, proto.Conv_Id(4))
	testing.expect_value(t, c.convs.channel, proto.Conv_Id(4))
	_ = tc_sent(t, &tc)

	// Taken out of the one we look at, we look at the home channel instead.
	buf: [4]u8
	tc_event(&tc, .Conv_Removed, proto.encode_conv_id(&buf, 4))
	testing.expect(t, 4 not_in c.convs.convs)
	testing.expect_value(t, c.convs.viewing, proto.Conv_Id(3))
	testing.expect_value(t, c.convs.channel, proto.Conv_Id(3)) // (the home channel is one)

	// Another one, or one we never had, changes nothing we look at.
	told(&tc, channel(7, "Other"))
	tc_event(&tc, .Conv_Removed, proto.encode_conv_id(&buf, 7))
	tc_event(&tc, .Conv_Removed, proto.encode_conv_id(&buf, 77))
	tc_event(&tc, .Conv_Removed, []u8{1})
	testing.expect_value(t, c.convs.viewing, proto.Conv_Id(3))
}

@(private = "file")
read_changed :: proc(tc: ^Test_Conn, s: proto.Read_State) {
	buf: [proto.READ_CHANGED_SIZE]u8
	tc_event(tc, .Read_Changed, proto.encode_read_changed(&buf, s))
}

@(test)
test_what_another_device_read :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_convs(t, &tc)
	defer close_convs(&tc)
	c := &tc.c
	synced(&tc, channel(3, "Lobby", {.Home}))
	info := &c.convs.convs[3]
	info.last, info.read, info.unread = 30, 20, 10

	// A position behind ours is old news. So is one behind what we are about to tell the server.
	read_changed(&tc, {conv = 3, read = 15, unread = 15})
	testing.expect_value(t, c.convs.convs[3].read, proto.Msg_Id(20))
	c.convs.marks[3] = {due = 25}
	read_changed(&tc, {conv = 3, read = 22, unread = 8})
	testing.expect_value(t, c.convs.convs[3].read, proto.Msg_Id(20))
	delete_key(&c.convs.marks, 3)
	// One ahead of ours is taken, and a conversation we don't have is nothing.
	read_changed(&tc, {conv = 3, read = 28, unread = 2, mentions = 1})
	testing.expect_value(t, c.convs.convs[3].read, proto.Msg_Id(28))
	testing.expect_value(t, c.convs.convs[3].unread, 2)
	testing.expect_value(t, c.convs.convs[3].mentions, 1)
	read_changed(&tc, {conv = 99, read = 5})
}

// ---- looking at conversations ----

@(test)
test_start_after_the_sync :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_convs(t, &tc)
	defer close_convs(&tc)
	c := &tc.c

	// By default the home channel is looked at.
	synced(&tc, channel(3, "Lobby", {.Home}), channel(4, "Gaming"))
	testing.expect(t, c.convs.synced)
	testing.expect_value(t, c.convs.viewing, proto.Conv_Id(3))
	testing.expect_value(t, home_conv(c), proto.Conv_Id(3))
	testing.expect_value(t, conv_by_name(c, "gaming"), proto.Conv_Id(4))
	testing.expect_value(t, conv_by_name(c, "nothing"), proto.Conv_Id(0))

	// A name asked for before connecting comes first, once.
	tc_event(&tc, .Sync_Begin)
	conv_start_viewing(c, "Gaming")
	told(&tc, channel(3, "Lobby", {.Home}))
	told(&tc, channel(4, "Gaming"))
	tc_event(&tc, .Sync_End)
	testing.expect_value(t, c.convs.viewing, proto.Conv_Id(4))
	testing.expect_value(t, c.convs.want_view, "")
	// ... and a channel that isn't there falls back to home.
	c.convs.viewing = 0
	tc_event(&tc, .Sync_Begin)
	conv_start_viewing(c, "Missing")
	told(&tc, channel(3, "Lobby", {.Home}))
	tc_event(&tc, .Sync_End)
	testing.expect_value(t, c.convs.viewing, proto.Conv_Id(3))
}

@(test)
test_start_with_voice :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_convs(t, &tc)
	defer close_convs(&tc)
	c := &tc.c
	_ = tc_sent(t, &tc)

	conv_start_in(c, "Gaming")
	synced(&tc, channel(3, "Lobby", {.Home}), channel(4, "Gaming"))
	testing.expect_value(t, c.convs.viewing, proto.Conv_Id(4))
	joins := requests_of(t, &tc, .Voice_Join)
	testing.expect_value(t, len(joins), 1)
	if len(joins) == 1 {
		room, ok := proto.decode_room(joins[0].body)
		testing.expect(t, ok)
		testing.expect_value(t, room, proto.Room(4))
	}
	testing.expect_value(t, c.convs.want_voice, "")

	// A channel with no voice room for us is not joined, and nor is one that isn't there.
	text_only := channel(5, "Notes", {.Text_Only})
	text_only.rights = {.See, .Write}
	conv_start_in(c, "Notes")
	synced(&tc, channel(3, "Lobby", {.Home}), text_only)
	testing.expect_value(t, len(requests_of(t, &tc, .Voice_Join)), 0)
	conv_start_in(c, "Nowhere")
	synced(&tc, channel(3, "Lobby", {.Home}))
	testing.expect_value(t, len(requests_of(t, &tc, .Voice_Join)), 0)
}

@(test)
test_viewing_a_conversation :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_convs(t, &tc)
	defer close_convs(&tc)
	c := &tc.c
	dm := proto.Conv {
		id            = 5,
		kind          = .DM,
		member        = true,
		account_count = 2,
	}
	dm.accounts[0], dm.accounts[1] = 1, 2
	dm.last, dm.unread = 9, 4
	synced(&tc, channel(3, "Lobby", {.Home}), channel(4, "Gaming"), dm)
	_ = tc_sent(t, &tc)
	c.view = nil // headless: what is looked at counts as read

	conv_view(c, 4)
	testing.expect_value(t, c.convs.viewing, proto.Conv_Id(4))
	testing.expect_value(t, c.convs.channel, proto.Conv_Id(4))
	// Its messages are asked for.
	testing.expect_value(t, len(requests_of(t, &tc, .Msg_History)), 1)
	// Looking at it again, or at nothing known, changes nothing.
	conv_view(c, 4)
	conv_view(c, 99)
	testing.expect_value(t, c.convs.viewing, proto.Conv_Id(4))
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)

	// A DM is looked at, but the channel to go back to is the last channel.
	conv_view(c, 5)
	testing.expect_value(t, c.convs.viewing, proto.Conv_Id(5))
	testing.expect_value(t, c.convs.channel, proto.Conv_Id(4))
	// Headless, looking at the DM reads it.
	testing.expect_value(t, c.convs.convs[5].unread, 0)
	testing.expect_value(t, c.convs.convs[5].read, proto.Msg_Id(9))
	// Nothing at all.
	conv_view(c, 0)
	testing.expect_value(t, c.convs.viewing, proto.Conv_Id(0))
}

@(test)
test_view_commands :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_convs(t, &tc)
	defer close_convs(&tc)
	c := &tc.c

	// Before the sync a name is kept for later.
	tc_run(conv_view_command, c, {name = strings.clone("Gaming")})
	testing.expect_value(t, c.convs.want_view, "Gaming")
	testing.expect_value(t, c.convs.viewing, proto.Conv_Id(0))

	dm := proto.Conv {
		id            = 5,
		kind          = .DM,
		member        = true,
		account_count = 2,
	}
	dm.accounts[0], dm.accounts[1] = 1, 2
	synced(&tc, channel(3, "Lobby", {.Home}), channel(4, "Gaming"), dm)
	testing.expect_value(t, c.convs.viewing, proto.Conv_Id(4))

	tc_run(conv_view_command, c, {name = strings.clone("lobby")})
	testing.expect_value(t, c.convs.viewing, proto.Conv_Id(3))
	tc_run(conv_view_command, c, {conv = 5})
	testing.expect_value(t, c.convs.viewing, proto.Conv_Id(5))
	// Back from a DM goes to the channel before it, or home if there is none.
	tc_run(conv_view_command, c, {back = true})
	testing.expect_value(t, c.convs.viewing, proto.Conv_Id(3))
	tc_run(conv_view_command, c, {conv = 4})
	tc_run(conv_view_command, c, {conv = 5})
	tc_run(conv_view_command, c, {back = true})
	testing.expect_value(t, c.convs.viewing, proto.Conv_Id(4))
	// Neither id nor name: nothing is shown. An unknown name changes nothing.
	tc_run(conv_view_command, c, {name = strings.clone("nowhere")})
	testing.expect_value(t, c.convs.viewing, proto.Conv_Id(4))
	tc_run(conv_view_command, c, {})
	testing.expect_value(t, c.convs.viewing, proto.Conv_Id(0))
}

// ---- voice ----

@(test)
test_joining_voice :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_convs(t, &tc)
	defer close_convs(&tc)
	c := &tc.c
	text_only := channel(5, "Notes", {.Text_Only})
	text_only.rights = {.See, .Write}
	muted := channel(6, "Quiet")
	muted.rights = {.See, .Write, .Voice} // may join, may not speak
	synced(&tc, channel(3, "Lobby", {.Home}), channel(4, "Gaming"), text_only, muted)
	_ = tc_sent(t, &tc)

	tc_run(voice_command, c, {name = strings.clone("gaming")})
	joins := requests_of(t, &tc, .Voice_Join)
	testing.expect_value(t, len(joins), 1)
	testing.expect(t, c.convs.voice_pending)
	// The answer ends the wait.
	if len(joins) == 1 {
		tc_answer(&tc, joins[0].id, .Ok)
	}
	testing.expect(t, !c.convs.voice_pending)

	// A channel with no voice room, or none we may use, says so.
	v := tc_view(&tc)
	tc_run(voice_command, c, {conv = 5})
	testing.expect_value(t, v.notice.text, "That channel has no voice room.")
	tc_run(voice_command, c, {conv = 3})
	_ = tc_sent(t, &tc)
	info := c.convs.convs[3]
	info.rights -= {.Voice}
	c.convs.convs[3] = info
	tc_run(voice_command, c, {conv = 3})
	testing.expect_value(t, v.notice.text, "You can't talk in that channel.")
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	tc_run(voice_command, c, {name = strings.clone("nowhere")})
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	// A channel that isn't ours is left to the server to judge.
	tc_run(voice_command, c, {conv = 99})
	testing.expect_value(t, len(requests_of(t, &tc, .Voice_Join)), 1)
}

@(test)
test_leaving_voice_and_the_room_we_are_in :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_convs(t, &tc)
	defer close_convs(&tc)
	c := &tc.c
	synced(&tc, channel(3, "Lobby", {.Home}), channel(4, "Gaming"))
	_ = tc_sent(t, &tc)
	tc_snapshot(&tc, 1, 11, {{num = 11, account = 1, room = 4}})

	// Already there: nothing to ask for. Leaving is room 0.
	voice_join(c, 4)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	tc_run(voice_command, c, {})
	req, ok := tc_one(t, &tc, .Voice_Join)
	testing.expect(t, ok)
	room, _ := proto.decode_room(req.body)
	testing.expect_value(t, room, proto.Room(0))
	// A failed join ends the wait too, and so does a lost connection.
	tc_answer(&tc, req.id, .Denied)
	testing.expect(t, !c.convs.voice_pending)
	voice_join(c, 3)
	req, _ = tc_one(t, &tc, .Voice_Join)
	tc_restart(&tc)
	testing.expect(t, !c.convs.voice_pending)

	// Before the sync a name is kept for the end of it.
	c.convs.synced = false
	tc_run(voice_command, c, {name = strings.clone("Gaming")})
	testing.expect_value(t, c.convs.want_voice, "Gaming")
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
}

// ---- browsing ----

@(private = "file")
browse_page :: proc(more: bool, records: ..proto.Conv) -> []u8 {
	out := make([]u8, 16 * 1024, context.temp_allocator)
	return proto.encode_browse_page(out, more, records)
}

@(test)
test_browsing_channels :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_convs(t, &tc)
	defer close_convs(&tc)
	c := &tc.c

	one := channel(10, "Books")
	one.member = false
	two := channel(11, "Cooking")
	two.member = true
	tc_run(conv_browse, c, {query = strings.clone("o"), limit = 2})
	req, ok := tc_one(t, &tc, .Conv_Browse)
	testing.expect(t, ok)
	b, dec := proto.decode_conv_browse(req.body)
	testing.expect(t, dec)
	testing.expect_value(t, b.query, "o")
	testing.expect_value(t, b.offset, 0)
	testing.expect_value(t, b.limit, 2)
	tc_answer(&tc, req.id, .Ok, browse_page(true, one, two))
	testing.expect_value(t, len(c.convs.browse), 2)
	testing.expect(t, c.convs.browse_more)
	testing.expect(t, !c.convs.browse[0].member && c.convs.browse[1].member)
	testing.expect_value(t, len(v.browse), 2)
	testing.expect_value(t, v.browse_more, true)

	// More continues after what is shown, with the same query and page size.
	tc_run(conv_browse, c, {more = true})
	req, _ = tc_one(t, &tc, .Conv_Browse)
	b, _ = proto.decode_conv_browse(req.body)
	testing.expect_value(t, b.query, "o")
	testing.expect_value(t, b.offset, 2)
	testing.expect_value(t, b.limit, 2)
	three := channel(12, "Movies")
	tc_answer(&tc, req.id, .Ok, browse_page(false, three))
	testing.expect_value(t, len(c.convs.browse), 3)
	testing.expect(t, !c.convs.browse_more)

	// A new query replaces them, from where it says; the default page size is used for 0.
	tc_run(conv_browse, c, {query = strings.clone("x"), offset = 4})
	req, _ = tc_one(t, &tc, .Conv_Browse)
	b, _ = proto.decode_conv_browse(req.body)
	testing.expect_value(t, b.offset, 4)
	testing.expect_value(t, b.limit, proto.BROWSE_PAGE)
	tc_answer(&tc, req.id, .Ok, browse_page(false, one))
	testing.expect_value(t, len(c.convs.browse), 1)
	testing.expect_value(t, c.convs.browse_offset, 4)
}

@(test)
test_old_browse_answers_are_dropped :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_convs(t, &tc)
	defer close_convs(&tc)
	c := &tc.c

	tc_run(conv_browse, c, {query = strings.clone("a")})
	old, _ := tc_one(t, &tc, .Conv_Browse)
	tc_run(conv_browse, c, {query = strings.clone("b")})
	newer, _ := tc_one(t, &tc, .Conv_Browse)
	tc_answer(&tc, old.id, .Ok, browse_page(false, channel(10, "Old")))
	testing.expect_value(t, len(c.convs.browse), 0)
	tc_answer(&tc, newer.id, .Ok, browse_page(false, channel(11, "New")))
	testing.expect_value(t, len(c.convs.browse), 1)
	testing.expect_value(t, c.convs.browse[0].name, "New")

	// A refusal, a lost connection and an unreadable page leave what is there.
	tc_run(conv_browse, c, {query = strings.clone("b")})
	r, _ := tc_one(t, &tc, .Conv_Browse)
	tc_answer(&tc, r.id, .Denied)
	tc_run(conv_browse, c, {query = strings.clone("b")})
	r, _ = tc_one(t, &tc, .Conv_Browse)
	tc_answer(&tc, r.id, .Ok, []u8{9})
	testing.expect_value(t, len(c.convs.browse), 1)
}

@(test)
test_all_channels_for_managing :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_convs(t, &tc)
	defer close_convs(&tc)
	c := &tc.c

	fetch_all_channels(c)
	req, ok := tc_one(t, &tc, .Conv_Browse)
	testing.expect(t, ok)
	b, _ := proto.decode_conv_browse(req.body)
	testing.expect_value(t, b.flags, u8(proto.BROWSE_ALL))
	testing.expect_value(t, b.offset, 0)
	testing.expect_value(t, b.limit, proto.MAX_BROWSE_LIMIT)
	testing.expect(t, c.convs.all_wanted)

	// Pages are asked for one after the other until the server has no more, and
	// the list is shown when it is complete.
	tc_answer(&tc, req.id, .Ok, browse_page(true, channel(10, "A"), channel(11, "B")))
	testing.expect_value(t, v.all_channels_count, 0)
	req, ok = tc_one(t, &tc, .Conv_Browse)
	testing.expect(t, ok)
	b, _ = proto.decode_conv_browse(req.body)
	testing.expect_value(t, b.offset, 2)
	tc_answer(&tc, req.id, .Ok, browse_page(false, channel(12, "C")))
	testing.expect_value(t, len(c.convs.all), 3)
	testing.expect_value(t, len(v.all_channels), 3)
	testing.expect_value(t, v.all_channels_count, 1)

	// An empty page that claims there is more does not loop.
	fetch_all_channels(c)
	req, _ = tc_one(t, &tc, .Conv_Browse)
	tc_answer(&tc, req.id, .Ok, browse_page(true))
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)

	// An answer to an earlier fetch is dropped.
	fetch_all_channels(c)
	old, _ := tc_one(t, &tc, .Conv_Browse)
	fetch_all_channels(c)
	_, _ = tc_one(t, &tc, .Conv_Browse)
	tc_answer(&tc, old.id, .Ok, browse_page(false, channel(99, "Stale")))
	testing.expect_value(t, len(c.convs.all), 0)

	// Not ours to manage: it is not asked for again.
	fetch_all_channels(c)
	req, _ = tc_one(t, &tc, .Conv_Browse)
	tc_answer(&tc, req.id, .Denied)
	testing.expect(t, !c.convs.all_wanted)
}

@(test)
test_browsing_does_not_clear_the_managed_list :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_convs(t, &tc)
	defer close_convs(&tc)
	c := &tc.c

	fetch_all_channels(c)
	req, _ := tc_one(t, &tc, .Conv_Browse)
	tc_answer(&tc, req.id, .Ok, browse_page(false, channel(10, "A"), channel(11, "B")))
	testing.expect_value(t, len(v.all_channels), 2)

	// A browse answer (of channels to subscribe to) says nothing about the list
	// the channel manager shows.
	tc_run(conv_browse, c, {query = strings.clone("a")})
	req, _ = tc_one(t, &tc, .Conv_Browse)
	tc_answer(&tc, req.id, .Ok, browse_page(false, channel(20, "Alpha")))
	testing.expect_value(t, len(v.browse), 1)
	testing.expect_value(t, len(v.all_channels), 2)
}

@(test)
test_channels_changed_asks_for_the_lists_again :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_convs(t, &tc)
	defer close_convs(&tc)
	c := &tc.c

	// Neither list was ever asked for: nothing to refresh.
	channels_changed(c)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)

	tc_run(conv_browse, c, {query = strings.clone("q"), offset = 3, limit = 5})
	_ = tc_sent(t, &tc)
	channels_changed(c)
	req, ok := tc_one(t, &tc, .Conv_Browse)
	testing.expect(t, ok)
	b, _ := proto.decode_conv_browse(req.body)
	testing.expect_value(t, b.query, "q")
	testing.expect_value(t, b.limit, 5)

	fetch_all_channels(c)
	_ = tc_sent(t, &tc)
	channels_changed(c)
	testing.expect_value(t, len(tc_sent(t, &tc)), 2)
}

// ---- subscribing and creating ----

@(test)
test_subscribing :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_convs(t, &tc)
	defer close_convs(&tc)
	c := &tc.c
	synced(&tc, channel(3, "Lobby", {.Home}), channel(4, "Gaming"))
	_ = tc_sent(t, &tc)

	// Leaving one of ours, by id or by name.
	tc_run(conv_subscribe_command, c, {conv = 4, on = false})
	req, ok := tc_one(t, &tc, .Conv_Subscribe)
	testing.expect(t, ok)
	conv, on, dec := proto.decode_conv_subscribe(req.body)
	testing.expect(t, dec && !on)
	testing.expect_value(t, conv, proto.Conv_Id(4))
	tc_run(conv_subscribe_command, c, {name = strings.clone("GAMING"), on = false})
	req, _ = tc_one(t, &tc, .Conv_Subscribe)
	conv, _, _ = proto.decode_conv_subscribe(req.body)
	testing.expect_value(t, conv, proto.Conv_Id(4))

	// One that was shown by a browse is subscribed to by name.
	append(&c.convs.browse, Browse_Entry{id = 30, name = strings.clone("Books")})
	tc_run(conv_subscribe_command, c, {name = strings.clone("books"), on = true})
	req, _ = tc_one(t, &tc, .Conv_Subscribe)
	conv, on, _ = proto.decode_conv_subscribe(req.body)
	testing.expect_value(t, conv, proto.Conv_Id(30))
	testing.expect(t, on)

	// Leaving one we are not in is nothing.
	tc_run(conv_subscribe_command, c, {name = strings.clone("nowhere"), on = false})
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
}

@(test)
test_subscribing_to_a_channel_not_yet_shown :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_convs(t, &tc)
	defer close_convs(&tc)
	c := &tc.c

	// The channel is looked for by name, and subscribed to when it is there.
	tc_run(conv_subscribe_command, c, {name = strings.clone("Books"), on = true})
	search, ok := tc_one(t, &tc, .Conv_Browse)
	testing.expect(t, ok)
	b, _ := proto.decode_conv_browse(search.body)
	testing.expect_value(t, b.query, "Books")
	tc_answer(&tc, search.id, .Ok, browse_page(false, channel(31, "Bookshelf"), channel(32, "books")))
	req, sub := tc_one(t, &tc, .Conv_Subscribe)
	testing.expect(t, sub)
	conv, _, _ := proto.decode_conv_subscribe(req.body)
	testing.expect_value(t, conv, proto.Conv_Id(32)) // the one with that name, not one that contains it

	// If no channel has that name, nothing is subscribed to.
	tc_run(conv_subscribe_command, c, {name = strings.clone("Missing"), on = true})
	search, _ = tc_one(t, &tc, .Conv_Browse)
	tc_answer(&tc, search.id, .Ok, browse_page(false, channel(31, "Bookshelf")))
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
}

@(test)
test_subscription_answers :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_convs(t, &tc)
	defer close_convs(&tc)
	c := &tc.c
	synced(&tc, channel(3, "Lobby", {.Home}), channel(4, "Gaming"))
	tc_run(conv_browse, c, {query = strings.clone("x")})
	_ = tc_sent(t, &tc)

	// A change that went through changes what can be subscribed to.
	tc_run(conv_subscribe_command, c, {conv = 4, on = false})
	req, _ := tc_one(t, &tc, .Conv_Subscribe)
	tc_answer(&tc, req.id, .Ok)
	_, browsed := tc_one(t, &tc, .Conv_Browse)
	testing.expect(t, browsed)

	// A refusal or a lost connection doesn't.
	for status in ([]proto.Status{.Denied, .Reset, .Internal}) {
		tc_run(conv_subscribe_command, c, {conv = 4, on = false})
		req, _ = tc_one(t, &tc, .Conv_Subscribe)
		tc_answer(&tc, req.id, status)
		testing.expectf(t, len(tc_sent(t, &tc)) == 0, "%v asked for the list again", status)
	}
}

@(test)
test_creating_a_channel :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_convs(t, &tc)
	defer close_convs(&tc)
	c := &tc.c
	_ = tc_sent(t, &tc)

	conv_create(c, "Music", "what we listen to", true, {.Default})
	req, ok := tc_one(t, &tc, .Conv_Create)
	testing.expect(t, ok)
	name, topic, flags, dec := proto.decode_conv_create(req.body)
	testing.expect(t, dec)
	testing.expect_value(t, name, "Music")
	testing.expect_value(t, topic, "what we listen to")
	testing.expect(t, .Private in flags && .Default in flags)

	tc_answer(&tc, req.id, .Ok)
	testing.expect_value(t, v.notice.text, "Channel created.")
	testing.expect(t, v.notice.ok)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0) // no list was ever asked for

	// With a list of channels to subscribe to, the new one may belong in it.
	tc_run(conv_browse, c, {query = strings.clone("m")})
	_ = tc_sent(t, &tc)
	conv_create(c, "Music", "", false)
	req, _ = tc_one(t, &tc, .Conv_Create)
	tc_answer(&tc, req.id, .Ok)
	_, browsed := tc_one(t, &tc, .Conv_Browse)
	testing.expect(t, browsed)

	Case :: struct {
		status: proto.Status,
		text:   string,
	}
	for k in ([]Case {
			{.Denied, "You don't have permission to create channels."},
			{.Conflict, "A channel with that name already exists."},
			{.Invalid, "A channel must have a name, and a private one can't be default."},
			{.Too_Large, "You've reached the maximum number of channels."},
			{.Internal, "The server failed to create the channel (Internal)."},
		}) {
		conv_create(c, "Music", "", false)
		req, _ = tc_one(t, &tc, .Conv_Create)
		tc_answer(&tc, req.id, k.status)
		testing.expectf(t, v.notice.text == k.text, "%v: %q", k.status, v.notice.text)
		testing.expect(t, !v.notice.ok)
	}
	count := v.notice.count
	conv_create(c, "Music", "", false)
	req, _ = tc_one(t, &tc, .Conv_Create)
	tc_restart(&tc)
	testing.expect_value(t, v.notice.count, count)

	// A name too long to send is not sent.
	conv_create(c, strings.repeat("n", 2 * proto.MAX_TOPIC_SIZE, context.temp_allocator), "", false)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
}

// ---- what we have read ----

@(test)
test_reading_is_told_to_the_server :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_convs(t, &tc)
	defer close_convs(&tc)
	c := &tc.c
	lobby := channel(3, "Lobby", {.Home})
	lobby.last, lobby.read, lobby.unread = 20, 10, 10
	synced(&tc, lobby, channel(4, "Gaming"))
	_ = tc_sent(t, &tc)

	// Reading a conversation counts what is in it as read.
	conv_reading(c, 3)
	testing.expect_value(t, c.convs.reading, proto.Conv_Id(3))
	testing.expect_value(t, c.convs.convs[3].read, proto.Msg_Id(20))
	testing.expect_value(t, c.convs.convs[3].unread, 0)
	testing.expect_value(t, c.convs.marks[3].due, proto.Msg_Id(20))

	// The server is told, once.
	convs_step(c)
	req, ok := tc_one(t, &tc, .Mark_Read)
	testing.expect(t, ok)
	conv, id, dec := proto.decode_mark_read(req.body)
	testing.expect(t, dec)
	testing.expect_value(t, conv, proto.Conv_Id(3))
	testing.expect_value(t, id, proto.Msg_Id(20))
	testing.expect_value(t, c.convs.marks[3].due, proto.Msg_Id(0))
	convs_step(c)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)

	// More read soon after waits for the interval to pass.
	read_to :: proc(c: ^Server_Conn, conv: proto.Conv_Id, last: proto.Msg_Id) {
		info := c.convs.convs[conv]
		info.last = last
		c.convs.convs[conv] = info
		conv_reading(c, conv)
	}
	read_to(c, 3, 25)
	convs_step(c)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	mark := c.convs.marks[3]
	mark.sent = time.tick_add(time.tick_now(), -(MARK_INTERVAL + time.Millisecond))
	c.convs.marks[3] = mark
	convs_step(c)
	req, ok = tc_one(t, &tc, .Mark_Read)
	testing.expect(t, ok)
	_, id, _ = proto.decode_mark_read(req.body)
	testing.expect_value(t, id, proto.Msg_Id(25))

	// Reading less than is read, or nothing at all, is nothing.
	conv_reading(c, 3)
	conv_reading(c, 99)
	testing.expect_value(t, c.convs.marks[3].due, proto.Msg_Id(0))
	conv_reading(c, 0)
	testing.expect_value(t, c.convs.reading, proto.Conv_Id(0))
	// Not without a connection.
	read_to(c, 4, 7)
	c.has_current = false
	convs_step(c)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
}

@(test)
test_changing_how_much_a_channel_notifies :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_convs(t, &tc)
	defer close_convs(&tc)
	c := &tc.c
	synced(&tc, channel(3, "Lobby", {.Home}), channel(4, "Gaming"))
	_ = tc_sent(t, &tc)

	tc_run(conv_notify, c, {name = strings.clone("gaming"), notify = .Mentions})
	req, ok := tc_one(t, &tc, .Conv_Notify)
	testing.expect(t, ok)
	conv, level, dec := proto.decode_conv_notify(req.body)
	testing.expect(t, dec)
	testing.expect_value(t, conv, proto.Conv_Id(4))
	testing.expect_value(t, level, proto.Notify_Level.Mentions)
	tc_run(conv_notify, c, {conv = 3, notify = .None})
	req, _ = tc_one(t, &tc, .Conv_Notify)
	conv, level, _ = proto.decode_conv_notify(req.body)
	testing.expect_value(t, conv, proto.Conv_Id(3))
	testing.expect_value(t, level, proto.Notify_Level.None)
	tc_run(conv_notify, c, {name = strings.clone("nowhere"), notify = .None})
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
}

// ---- lists and restarts ----

@(test)
test_channels_are_listed_in_order :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_convs(t, &tc)
	defer close_convs(&tc)
	c := &tc.c
	b := channel(11, "B")
	b.position = 2
	a := channel(10, "A")
	a.position = 2
	first := channel(12, "First")
	first.position = 1
	dm := proto.Conv {
		id            = 5,
		kind          = .DM,
		member        = true,
		account_count = 2,
	}
	dm.accounts[0], dm.accounts[1] = 1, 2
	home := channel(13, "Home", {.Home})
	home.position = 9
	synced(&tc, b, a, first, dm, home)

	order := convs_ordered(c)
	testing.expect_value(t, len(order), 4) // no DM
	if len(order) == 4 {
		// The home channel first, then by position, then by id.
		testing.expect_value(t, order[0], proto.Conv_Id(13))
		testing.expect_value(t, order[1], proto.Conv_Id(12))
		testing.expect_value(t, order[2], proto.Conv_Id(10))
		testing.expect_value(t, order[3], proto.Conv_Id(11))
	}
	list_channels(c) // (logged)
}

@(test)
test_a_new_connection_remembers_where_we_were :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_convs(t, &tc)
	defer close_convs(&tc)
	c := &tc.c
	synced(&tc, channel(3, "Lobby", {.Home}), channel(4, "Gaming"))
	conv_view(c, 4)
	tc_snapshot(&tc, 1, 11, {{num = 11, account = 1, room = 4}})
	_ = tc_sent(t, &tc)
	c.convs.voice_pending = true
	c.convs.all_asked = 5

	// The server tells us about everything again, and where we were is asked for
	// again once it has.
	convs_restart(c)
	testing.expect_value(t, len(c.convs.convs), 0)
	testing.expect(t, !c.convs.synced)
	testing.expect_value(t, c.convs.viewing, proto.Conv_Id(0))
	testing.expect_value(t, c.convs.want_view_id, proto.Conv_Id(4))
	testing.expect_value(t, c.convs.want_channel, proto.Conv_Id(4))
	testing.expect_value(t, c.convs.want_voice, "Gaming")
	testing.expect(t, !c.convs.voice_pending)
	testing.expect_value(t, c.convs.all_asked, u64(6)) // what was on its way is from before

	tc_event(&tc, .Sync_Begin)
	told(&tc, channel(3, "Lobby", {.Home}))
	told(&tc, channel(4, "Gaming"))
	tc_event(&tc, .Sync_End)
	testing.expect_value(t, c.convs.viewing, proto.Conv_Id(4))
	testing.expect_value(t, c.convs.channel, proto.Conv_Id(4))

	// Logged out: none of that is wanted.
	c.convs.marks[4] = {
		due = 3,
	}
	c.convs.all_wanted = true
	convs_restart(c, forget = true)
	testing.expect_value(t, c.convs.want_view_id, proto.Conv_Id(0))
	testing.expect_value(t, c.convs.want_voice, "")
	testing.expect_value(t, len(c.convs.marks), 0)
	testing.expect(t, !c.convs.all_wanted)
}

@(test)
test_guest_room_is_forgotten_with_the_conversations :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_convs(t, &tc)
	defer close_convs(&tc)
	c := &tc.c
	c.convs.guest_room, c.convs.guest_name = 9, strings.clone("Secret")
	testing.expect_value(t, room_name(c, 9), "Secret")
	tc_event(&tc, .Sync_Begin)
	testing.expect_value(t, c.convs.guest_room, proto.Room(0))
	testing.expect_value(t, room_name(c, 9), "channel #9")
}

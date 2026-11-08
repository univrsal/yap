#+build !wasi
package conn

import "core:strings"
import "core:testing"
import "core:time"

import "common:proto"

// Tests of the messages we keep (messages.odin): the window of each
// conversation and of each open thread, how pages are asked for and put
// together, what a new, edited or purged message does to them, and what is
// dropped when the connection starts over. The window's own bookkeeping is
// tested in messages_test.odin.

@(private = "file")
open_msgs :: proc(tc: ^Test_Conn) -> ^View {
	tc_open(tc)
	tc.c.auth.me = 1
	tc.c.auth.state = .Done
	tc_account(tc, 1, "bob", "Bob")
	tc_account(tc, 2, "alice", "Alice")
	tc_account(tc, 3, "carol", "Carol")
	tc_conv(tc, 3, "Lobby")
	tc_conv(tc, 4, "Gaming")
	tc_dm_with(tc, 5, 1, 2)
	return tc_view(tc)
}

@(private = "file")
close_msgs :: proc(tc: ^Test_Conn) {
	bookmarks_destroy(&tc.c)
	files_destroy(&tc.c)
	tc_close(tc)
}

@(private = "file")
pm :: proc(
	id: proto.Msg_Id,
	text := "message",
	conv := proto.Conv_Id(3),
	sender := proto.Account_Id(2),
) -> proto.Message {
	return {
		id = id,
		conv = conv,
		sender = sender,
		time = proto.Unix_Ms(1000 + id),
		kind = .Text,
		text = text,
	}
}

@(private = "file")
page :: proc(more: u8, msgs: ..proto.Message) -> []u8 {
	out := make([]u8, 32 * 1024, context.temp_allocator)
	body, _ := proto.encode_history_page(out, more, msgs)
	return body
}

@(private = "file")
history :: proc(t: ^testing.T, tc: ^Test_Conn) -> (proto.Msg_History, Test_Request) {
	r, ok := tc_one(t, tc, .Msg_History)
	h, dec := proto.decode_msg_history(r.body)
	testing.expect(t, ok && dec)
	return h, r
}

@(private = "file")
ids :: proc(cache: ^Conv_Cache) -> []int {
	out := make([]int, len(cache.messages), context.temp_allocator)
	for m, i in cache.messages {
		out[i] = int(m.id)
	}
	return out
}

@(private = "file")
expect_ids :: proc(t: ^testing.T, cache: ^Conv_Cache, want: ..int, loc := #caller_location) {
	got := ids(cache)
	same := len(got) == len(want)
	for i in 0 ..< min(len(got), len(want)) {
		same &&= got[i] == want[i]
	}
	testing.expectf(t, same, "the window is %v, not %v", got, want, loc = loc)
}

// arrive gives the client a message that was just posted.
@(private = "file")
arrive :: proc(tc: ^Test_Conn, m: proto.Message) {
	buf := make([]u8, 4096, context.temp_allocator)
	tc_event(tc, .Msg_New, proto.encode_message(buf, m))
}

@(private = "file")
changed :: proc(tc: ^Test_Conn, m: proto.Message) {
	buf := make([]u8, 4096, context.temp_allocator)
	tc_event(tc, .Msg_Changed, proto.encode_message(buf, m))
}

// ---- the window of a conversation ----

@(test)
test_viewing_asks_for_the_newest_page :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_msgs(&tc)
	defer close_msgs(&tc)
	c := &tc.c

	// No conversation, or no sync yet: nothing is asked for (an unsynced
	// window is made, but it waits).
	messages_view(c, 0)
	c.convs.synced = false
	messages_view(c, 3)
	c.convs.synced = true
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	testing.expect(t, !c.msgs.caches[{3, 0}].loading)

	messages_view(c, 3)
	h, req := history(t, &tc)
	testing.expect_value(t, h.conv, proto.Conv_Id(3))
	testing.expect_value(t, h.thread_root, proto.Msg_Id(0))
	testing.expect_value(t, h.anchor, proto.Msg_Id(0))
	testing.expect_value(t, h.dir, proto.History_Dir.Before)
	testing.expect_value(t, h.limit, HISTORY_PAGE)
	cache := c.msgs.caches[{3, 0}]
	testing.expect(t, cache.loading)

	// Looking again while it is on its way asks for nothing more.
	messages_view(c, 3)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)

	tc_answer(&tc, req.id, .Ok, page(proto.MORE_BEFORE, pm(10), pm(11), pm(12)))
	expect_ids(t, cache, 10, 11, 12)
	testing.expect(t, !cache.loading)
	testing.expect(t, cache.have_newest && !cache.have_oldest)
	testing.expect_value(t, len(v.timelines[{3, 0}].messages), 3)

	// With messages in it, looking again doesn't ask.
	messages_view(c, 3)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
}

@(test)
test_an_empty_conversation_is_asked_for_once :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_msgs(&tc)
	defer close_msgs(&tc)
	c := &tc.c
	messages_view(c, 3)
	_, req := history(t, &tc)
	tc_answer(&tc, req.id, .Ok, page(0))
	cache := c.msgs.caches[{3, 0}]
	testing.expect(t, cache.have_oldest && cache.have_newest)
	testing.expect_value(t, len(cache.messages), 0)
	messages_view(c, 3)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
}

@(test)
test_scrolling_back_and_forward :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_msgs(&tc)
	defer close_msgs(&tc)
	c := &tc.c
	messages_view(c, 3)
	_, req := history(t, &tc)
	tc_answer(&tc, req.id, .Ok, page(proto.MORE_BEFORE, pm(10), pm(11), pm(12)))
	cache := c.msgs.caches[{3, 0}]

	// Older messages come before the first one; a page that overlaps adds only what is new.
	messages_more(c, {3, 0}, false)
	h, older := history(t, &tc)
	testing.expect_value(t, h.anchor, proto.Msg_Id(10))
	testing.expect_value(t, h.dir, proto.History_Dir.Before)
	messages_more(c, {3, 0}, false) // not while one is on its way
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	tc_answer(&tc, older.id, .Ok, page(proto.MORE_BEFORE, pm(8), pm(9), pm(10)))
	expect_ids(t, cache, 8, 9, 10, 11, 12)
	testing.expect(t, !cache.have_oldest)

	// The first page of the conversation: nothing older to ask for after it.
	messages_more(c, {3, 0}, false)
	_, older = history(t, &tc)
	tc_answer(&tc, older.id, .Ok, page(0, pm(6), pm(7)))
	expect_ids(t, cache, 6, 7, 8, 9, 10, 11, 12)
	testing.expect(t, cache.have_oldest)
	messages_more(c, {3, 0}, false)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)

	// A window that reaches the end has nothing newer to ask for; one that stops short does.
	messages_more(c, {3, 0}, true)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	cache.have_newest = false
	messages_more(c, {3, 0}, true)
	newer: Test_Request
	h, newer = history(t, &tc)
	testing.expect_value(t, h.anchor, proto.Msg_Id(12))
	testing.expect_value(t, h.dir, proto.History_Dir.After)
	tc_answer(&tc, newer.id, .Ok, page(proto.MORE_AFTER, pm(13), pm(14)))
	expect_ids(t, cache, 6, 7, 8, 9, 10, 11, 12, 13, 14)
	testing.expect(t, !cache.have_newest)

	// No window, or an empty one, is nothing to scroll.
	messages_more(c, {4, 0}, false)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
}

@(test)
test_jumping_to_a_message :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_msgs(&tc)
	defer close_msgs(&tc)
	c := &tc.c
	messages_view(c, 3)
	_, req := history(t, &tc)
	tc_answer(&tc, req.id, .Ok, page(proto.MORE_BEFORE, pm(10), pm(11), pm(12)))
	cache := c.msgs.caches[{3, 0}]

	// Nothing to look at: nothing to jump in. In the window already: nothing to fetch.
	messages_jump_to(c, 500)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	c.convs.viewing = 3
	messages_jump_to(c, 11)
	messages_jump_to(c, 10)
	messages_jump_to(c, 12)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)

	// Outside of it, the page around the message replaces the window.
	messages_jump_to(c, 500)
	h, jump := history(t, &tc)
	testing.expect_value(t, h.anchor, proto.Msg_Id(500))
	testing.expect_value(t, h.dir, proto.History_Dir.Around)
	messages_jump(c, 3, 600) // not while one is on its way
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	tc_answer(
		&tc,
		jump.id,
		.Ok,
		page(proto.MORE_BEFORE | proto.MORE_AFTER, pm(499), pm(500), pm(501)),
	)
	expect_ids(t, cache, 499, 500, 501)
	testing.expect(t, !cache.have_newest && !cache.have_oldest)
}

@(test)
test_pages_that_arrive_too_late_or_wrong :: proc(t: ^testing.T) {
	context.logger = expected_errors() // refusals are logged
	tc: Test_Conn
	_ = open_msgs(&tc)
	defer close_msgs(&tc)
	c := &tc.c

	// The window is dropped (the connection started over) before the page arrives.
	messages_view(c, 3)
	_, req := history(t, &tc)
	messages_restart(c)
	tc_answer(&tc, req.id, .Ok, page(0, pm(10)))
	testing.expect_value(t, len(c.msgs.caches), 0)

	// A refusal, a lost connection and a page that can't be read end the wait and keep the window.
	messages_view(c, 3)
	_, req = history(t, &tc)
	tc_answer(&tc, req.id, .Ok, page(0, pm(10)))
	cache := c.msgs.caches[{3, 0}]
	for k in ([]struct {
			status: proto.Status,
			body:   []u8,
		}{{.Denied, nil}, {.Reset, nil}, {.Ok, []u8{1, 2, 3}}}) {
		messages_more(c, {3, 0}, false)
		cache.have_oldest = false
		messages_more(c, {3, 0}, false)
		_, older := history(t, &tc)
		tc_answer(&tc, older.id, k.status, k.body)
		testing.expectf(t, !cache.loading, "%v: still loading", k.status)
		expect_ids(t, cache, 10)
	}
}

@(test)
test_only_the_latest_windows_are_kept :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_msgs(&tc)
	defer close_msgs(&tc)
	c := &tc.c
	base := time.tick_now()
	for i in 0 ..< CACHE_KEEP + 3 {
		id := proto.Conv_Id(20 + i)
		tc_conv(&tc, id, "extra")
		messages_view(c, id)
		c.msgs.caches[{id, 0}].used = time.tick_add(base, time.Duration(i) * time.Second)
	}
	// The ones looked at longest ago are dropped; the one just opened is not.
	count := 0
	for key in c.msgs.caches {
		if key.root == 0 {
			count += 1
		}
	}
	testing.expect_value(t, count, CACHE_KEEP)
	testing.expect(t, ({20 + CACHE_KEEP + 2, 0}) in c.msgs.caches)
	testing.expect(t, ({20, 0}) not_in c.msgs.caches)
	testing.expect(t, ({21, 0}) not_in c.msgs.caches)
}

// ---- new messages ----

@(test)
test_a_new_message_joins_the_window :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_msgs(&tc)
	defer close_msgs(&tc)
	c := &tc.c
	messages_view(c, 3)
	_, req := history(t, &tc)
	tc_answer(&tc, req.id, .Ok, page(0, pm(10), pm(11)))
	cache := c.msgs.caches[{3, 0}]

	arrive(&tc, pm(12, "new"))
	expect_ids(t, cache, 10, 11, 12)
	testing.expect_value(t, v.timelines[{3, 0}].messages[2].text, "new")
	testing.expect_value(t, c.convs.convs[3].unread, 1)
	// Told twice (ours is announced and answered): the second changes nothing.
	arrive(&tc, pm(12, "new"))
	arrive(&tc, pm(11, "old"))
	expect_ids(t, cache, 10, 11, 12)
	testing.expect_value(t, c.convs.convs[3].unread, 1)
	// Scripts are told once, however often it is announced.
	events := tc_events(&tc)
	testing.expect_value(t, len(events), 1)
	if len(events) == 1 {
		told, is_message := events[0].(Event_Message)
		testing.expect(t, is_message)
		testing.expect_value(t, told.id, proto.Msg_Id(12))
	}
	for &e in events {
		event_destroy(&e)
	}

	// A window that stops short of the end doesn't take what comes after it.
	cache.have_newest = false
	arrive(&tc, pm(13))
	expect_ids(t, cache, 10, 11, 12)
	testing.expect_value(t, c.convs.convs[3].unread, 2)
}

@(test)
test_messages_in_a_conversation_without_a_window :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_msgs(&tc)
	defer close_msgs(&tc)
	c := &tc.c
	tc_conv(&tc, 6, "Quiet", last = 20)

	// Not newer than what we know of was seen before.
	arrive(&tc, pm(15, "old", 6))
	arrive(&tc, pm(20, "same", 6))
	testing.expect_value(t, c.convs.convs[6].unread, 0)
	arrive(&tc, pm(21, "new", 6))
	testing.expect_value(t, c.convs.convs[6].unread, 1)
	testing.expect_value(t, len(c.msgs.caches), 0)
	// A message of a conversation we don't know is not an error.
	arrive(&tc, pm(1, "nowhere", 99))
}

@(test)
test_replies_join_the_open_thread :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_msgs(&tc)
	defer close_msgs(&tc)
	c := &tc.c
	messages_view(c, 3)
	_, req := history(t, &tc)
	tc_answer(&tc, req.id, .Ok, page(0, pm(10), pm(11)))
	thread_open(c, {3, 10})
	_ = tc_sent(t, &tc)
	thread := c.msgs.caches[{3, 10}]
	thread.have_newest = true

	reply := pm(12, "a reply")
	reply.thread_root = 10
	arrive(&tc, reply)
	expect_ids(t, thread, 12)
	expect_ids(t, c.msgs.caches[{3, 0}], 10, 11, 12)
	// A reply to a thread that isn't open is in the conversation only.
	other := pm(13, "elsewhere")
	other.thread_root = 11
	arrive(&tc, other)
	testing.expect_value(t, len(c.msgs.caches), 2)
	expect_ids(t, c.msgs.caches[{3, 0}], 10, 11, 12, 13)
}

@(test)
test_direct_messages_are_announced :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_msgs(&tc)
	defer close_msgs(&tc)
	c := &tc.c
	tc_group_for_test(&tc, 7, 1, 2, 3)

	// A DM from somebody else is announced with who it is from and what it says.
	arrive(&tc, pm(30, "hello there", 5))
	mentions := view_take_mentions(v)
	testing.expect_value(t, len(mentions), 1)
	if len(mentions) == 1 {
		testing.expect(t, mentions[0].dm && !mentions[0].group)
		testing.expect_value(t, mentions[0].name, "Alice")
		testing.expect_value(t, mentions[0].place, "DMs with Alice")
		testing.expect_value(t, mentions[0].text, "hello there")
		testing.expect_value(t, mentions[0].conv, proto.Conv_Id(5))
		testing.expect_value(t, mentions[0].msg, proto.Msg_Id(30))
	}
	// Taking them empties the list.
	testing.expect_value(t, len(view_take_mentions(v)), 0)

	// A group is a DM too, and says so.
	arrive(&tc, pm(31, "all", 7, 3))
	mentions = view_take_mentions(v)
	testing.expect_value(t, len(mentions), 1)
	if len(mentions) == 1 {
		testing.expect(t, mentions[0].dm && mentions[0].group)
	}

	// Files and files-with-no-text are announced as what they are.
	file := proto.Message {
		id        = 32,
		conv      = 5,
		sender    = 2,
		kind      = .File,
		file_name = "photo.png",
		file_size = 1000,
	}
	arrive(&tc, file)
	mentions = view_take_mentions(v)
	if len(mentions) == 1 {
		testing.expect_value(t, mentions[0].text, `Sent you the file "photo.png"`)
	}
	with_files := pm(33, "", 5)
	with_files.flags = {.Has_Attachments}
	arrive(&tc, with_files)
	mentions = view_take_mentions(v)
	if len(mentions) == 1 {
		testing.expect_value(t, mentions[0].text, "Sent you a file")
	}

	// Not our own, not from a muted DM, not a system message, not a deleted one.
	arrive(&tc, pm(34, "mine", 5, 1))
	info := c.convs.convs[5]
	info.notify = .None
	c.convs.convs[5] = info
	arrive(&tc, pm(35, "muted", 5))
	info.notify = .All
	c.convs.convs[5] = info
	system := pm(36, "", 5)
	system.kind = .System
	arrive(&tc, system)
	gone := pm(37, "gone", 5)
	gone.flags = {.Deleted}
	arrive(&tc, gone)
	testing.expect_value(t, len(view_take_mentions(v)), 0)
}

@(private = "file")
tc_group_for_test :: proc(tc: ^Test_Conn, id: proto.Conv_Id, members: ..proto.Account_Id) {
	info := Conv_Info {
		kind          = .Group,
		account_count = len(members),
	}
	for m, i in members {
		info.accounts[i] = m
	}
	tc.c.convs.convs[id] = info
}

@(test)
test_mentions_in_a_channel_are_announced :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_msgs(&tc)
	defer close_msgs(&tc)

	arrive(&tc, pm(40, "nothing for you"))
	testing.expect_value(t, len(view_take_mentions(v)), 0)
	arrive(&tc, pm(41, "hey <@1>, look"))
	mentions := view_take_mentions(v)
	testing.expect_value(t, len(mentions), 1)
	if len(mentions) == 1 {
		testing.expect(t, !mentions[0].dm)
		testing.expect_value(t, mentions[0].text, "hey @Bob, look")
		testing.expect_value(t, mentions[0].place, "Lobby")
		testing.expect_value(t, mentions[0].name, "Alice")
	}
	// Somebody else's mention, and our own message mentioning us, are not for us.
	arrive(&tc, pm(42, "hey <@3>"))
	arrive(&tc, pm(43, "note to self <@1>", 3, 1))
	testing.expect_value(t, len(view_take_mentions(v)), 0)
}

// ---- changes to a message ----

@(test)
test_an_edited_message_is_replaced_everywhere :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_msgs(&tc)
	defer close_msgs(&tc)
	c := &tc.c
	messages_view(c, 3)
	_, req := history(t, &tc)
	first := pm(10, "before")
	proto.set_reactions(&first, {{"👍", 2, true}, {"🎉", 1, false}})
	tc_answer(&tc, req.id, .Ok, page(0, first, pm(11)))
	// The same message in the window of its thread, and as a fetched root.
	thread := new(Conv_Cache)
	thread.have_newest = true
	append(&thread.messages, msg_of(first))
	c.msgs.caches[{3, 10}] = thread
	c.msgs.roots[10] = {
		conv = 3,
		have = true,
		msg  = msg_of(first),
	}

	edited := pm(10, "after")
	edited.edited = 5000
	// An event doesn't say which reactions are ours.
	proto.set_reactions(&edited, {{"👍", 3, false}, {"🎉", 1, false}})
	changed(&tc, edited)

	for key in ([]Timeline_Key{{3, 0}, {3, 10}}) {
		cache := c.msgs.caches[key]
		testing.expect_value(t, cache.messages[0].text, "after")
		testing.expect_value(t, cache.messages[0].edited, proto.Unix_Ms(5000))
		testing.expect_value(t, len(cache.messages[0].reactions), 2)
		testing.expect_value(t, cache.messages[0].reactions[0].count, 3)
		testing.expect(t, cache.messages[0].reactions[0].me, "our reaction was lost")
		testing.expect(t, !cache.messages[0].reactions[1].me)
	}
	testing.expect_value(t, c.msgs.roots[10].msg.text, "after")
	testing.expect_value(t, c.msgs.caches[{3, 0}].messages[1].text, "message")
	testing.expect_value(t, v.timelines[{3, 0}].messages[0].text, "after")

	// A message that is in no window is nothing to change.
	changed(&tc, pm(99, "elsewhere"))
	testing.expect_value(t, len(c.msgs.caches[{3, 0}].messages), 2)
}

@(test)
test_a_change_refreshes_the_pins :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_msgs(&tc)
	defer close_msgs(&tc)
	c := &tc.c
	changed(&tc, pm(10))
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)

	// Pinning or unpinning something in the conversation whose pins are shown
	// asks for them again, because it may have become or stopped being one.
	c.msgs.pins_conv = 3
	changed(&tc, pm(10))
	_, ok := tc_one(t, &tc, .Pins_Get)
	testing.expect(t, ok)
	c.msgs.pins_conv = 4
	changed(&tc, pm(10))
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
}

// ---- purges ----

@(private = "file")
purged :: proc(tc: ^Test_Conn, p: proto.Msgs_Purged) {
	buf: [proto.MSGS_PURGED_MAX_SIZE]u8
	tc_event(tc, .Msgs_Purged, proto.encode_msgs_purged(&buf, p))
}

@(private = "file")
window :: proc(t: ^testing.T, tc: ^Test_Conn, msgs: ..proto.Message) -> ^Conv_Cache {
	messages_view(&tc.c, 3)
	_, req := history(t, tc)
	tc_answer(tc, req.id, .Ok, page(0, ..msgs))
	return tc.c.msgs.caches[{3, 0}]
}

@(test)
test_purging_old_messages :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_msgs(&tc)
	defer close_msgs(&tc)
	c := &tc.c
	cache := window(t, &tc, pm(10), pm(11), pm(12), pm(13), pm(14))
	testing.expect(t, cache.have_oldest)

	purged(&tc, {conv = 3, before = 12})
	expect_ids(t, cache, 12, 13, 14)
	// The start of the conversation is no longer in the window.
	testing.expect(t, !cache.have_oldest)

	// Another conversation's purge is not ours to apply.
	purged(&tc, {conv = 4, before = 100})
	expect_ids(t, cache, 12, 13, 14)

	// Everything gone: the window is dropped, and fetched again if it is on screen.
	c.convs.viewing = 3
	purged(&tc, {conv = 3, before = 100})
	_, again := history(t, &tc)
	testing.expect_value(t, again.id != 0, true)
	testing.expect_value(t, len(c.msgs.caches[{3, 0}].messages), 0)
	// ... but not if it isn't.
	cache = c.msgs.caches[{3, 0}]
	tc_answer(&tc, again.id, .Ok, page(0, pm(200), pm(201)))
	c.convs.viewing = 0
	purged(&tc, {conv = 3, before = 1000})
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	testing.expect(t, ({3, 0}) not_in c.msgs.caches)
}

@(test)
test_purging_one_authors_messages :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_msgs(&tc)
	defer close_msgs(&tc)
	c := &tc.c
	cache := window(
		t,
		&tc,
		pm(10, sender = 3),
		pm(11, sender = 2),
		pm(12, sender = 3),
		pm(13, sender = 3),
		pm(14, sender = 2),
	)
	// A root of theirs that others replied to stays, as a deleted message.
	cache.messages[3].flags = {.Deleted, .Has_Thread}

	// Theirs from message 11 on go, wherever they are; before that they stay.
	purged(&tc, {conv = 3, author = 3, from = 11})
	expect_ids(t, cache, 10, 11, 13, 14)
	// Another author's are not touched.
	purged(&tc, {conv = 3, author = 9, from = 1})
	expect_ids(t, cache, 10, 11, 13, 14)

	// The pins shown may have included theirs.
	c.msgs.pins_conv = 3
	purged(&tc, {conv = 3, author = 2, from = 1})
	expect_ids(t, cache, 10, 13)
	_, pins := tc_one(t, &tc, .Pins_Get)
	testing.expect(t, pins)
}

@(test)
test_purging_the_files_of_messages :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_msgs(&tc)
	defer close_msgs(&tc)
	cache := window(t, &tc, pm(10), pm(11), pm(12))
	for &m, i in cache.messages {
		m.files = make([]Msg_File, 1)
		m.files[0] = {
			blob = proto.Blob_Id(100 + i),
			size = 10,
			name = strings.clone("a.png"),
		}
	}
	cache.messages[0].flags = {.Pinned}

	// The files below the boundary go, except from pinned messages; the
	// messages themselves stay.
	purged(&tc, {conv = 3, before = 12, what = .Files})
	expect_ids(t, cache, 10, 11, 12)
	testing.expect_value(t, cache.messages[0].files[0].blob, proto.Blob_Id(100)) // pinned
	testing.expect_value(t, cache.messages[1].files[0].blob, proto.Blob_Id(0))
	testing.expect_value(t, cache.messages[2].files[0].blob, proto.Blob_Id(102)) // not below it
	testing.expect_value(t, cache.messages[1].files[0].name, "a.png") // still listed
}

@(test)
test_purging_drops_the_roots_it_removes :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_msgs(&tc)
	defer close_msgs(&tc)
	c := &tc.c
	c.msgs.roots[10] = {
		conv = 3,
		have = true,
		msg  = msg_of(pm(10)),
	}
	c.msgs.roots[60] = {
		conv = 3,
		have = true,
		msg  = msg_of(pm(60)),
	}
	publish_root(c, c.msgs.roots[10])

	purged(&tc, {conv = 3, before = 50})
	testing.expect(t, 10 not_in c.msgs.roots)
	testing.expect(t, 60 in c.msgs.roots)
	_, shown := v.roots[10]
	testing.expect(t, !shown)

	// A root that an open thread needs is fetched again.
	append(&c.msgs.threads, Timeline_Key{3, 60})
	purged(&tc, {conv = 3, before = 70})
	testing.expect(t, 60 in c.msgs.roots)
	testing.expect(t, !c.msgs.roots[60].have)
	h, ok := history(t, &tc)
	_ = ok
	testing.expect_value(t, h.anchor, proto.Msg_Id(60))
}

// ---- reactions ----

@(private = "file")
reacted :: proc(tc: ^Test_Conn, change: proto.Reaction_Change) {
	buf: [proto.REACTION_CHANGED_MAX_SIZE]u8
	tc_event(tc, .Reaction_Changed, proto.encode_reaction_changed(&buf, change))
}

@(test)
test_reactions_change :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_msgs(&tc)
	defer close_msgs(&tc)
	cache := window(t, &tc, pm(10), pm(11))

	// A new reaction, then others joining it, one of them ours.
	reacted(&tc, {id = 10, conv = 3, emoji = "👍", count = 1, account = 2, on = true})
	testing.expect_value(t, len(cache.messages[0].reactions), 1)
	testing.expect_value(t, cache.messages[0].reactions[0].count, 1)
	testing.expect(t, !cache.messages[0].reactions[0].me)
	reacted(&tc, {id = 10, conv = 3, emoji = "👍", count = 2, account = 1, on = true})
	testing.expect_value(t, cache.messages[0].reactions[0].count, 2)
	testing.expect(t, cache.messages[0].reactions[0].me)
	reacted(&tc, {id = 10, conv = 3, emoji = "🎉", count = 1, account = 3, on = true})
	testing.expect_value(t, len(cache.messages[0].reactions), 2)
	// Somebody else taking theirs back leaves ours.
	reacted(&tc, {id = 10, conv = 3, emoji = "👍", count = 1, account = 2, on = false})
	testing.expect_value(t, cache.messages[0].reactions[0].count, 1)
	testing.expect(t, cache.messages[0].reactions[0].me)
	// Ours going takes it off us; the last one going takes the reaction away.
	reacted(&tc, {id = 10, conv = 3, emoji = "👍", count = 0, account = 1, on = false})
	testing.expect_value(t, len(cache.messages[0].reactions), 1)
	testing.expect_value(t, cache.messages[0].reactions[0].emoji, "🎉")
	// A count of 0 for one that isn't there adds nothing.
	reacted(&tc, {id = 10, conv = 3, emoji = "😀", count = 0, account = 2, on = false})
	testing.expect_value(t, len(cache.messages[0].reactions), 1)
	// Another message is not touched, nor one that isn't in a window.
	testing.expect_value(t, len(cache.messages[1].reactions), 0)
	reacted(&tc, {id = 99, conv = 3, emoji = "👍", count = 1, account = 2, on = true})
	reacted(&tc, {id = 10, conv = 4, emoji = "👍", count = 1, account = 2, on = true})
	testing.expect_value(t, len(cache.messages[0].reactions), 1)

	// The list of who reacted that is shown is out of date now, but only for that emoji.
	v.reactors.id, v.reactors.emoji = 10, strings.clone("🎉")
	reacted(&tc, {id = 10, conv = 3, emoji = "👍", count = 1, account = 2, on = true})
	testing.expect_value(t, v.reactors.id, proto.Msg_Id(10))
	reacted(&tc, {id = 10, conv = 3, emoji = "🎉", count = 2, account = 2, on = true})
	testing.expect_value(t, v.reactors.id, proto.Msg_Id(0))
}

@(test)
test_reactions_reach_threads_and_roots :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_msgs(&tc)
	defer close_msgs(&tc)
	c := &tc.c
	_ = window(t, &tc, pm(10))
	thread := new(Conv_Cache)
	append(&thread.messages, msg_of(pm(10)))
	c.msgs.caches[{3, 10}] = thread
	c.msgs.roots[10] = {
		conv = 3,
		have = true,
		msg  = msg_of(pm(10)),
	}

	reacted(&tc, {id = 10, conv = 3, emoji = "👍", count = 1, account = 2, on = true})
	testing.expect_value(t, len(c.msgs.caches[{3, 0}].messages[0].reactions), 1)
	testing.expect_value(t, len(thread.messages[0].reactions), 1)
	testing.expect_value(t, len(c.msgs.roots[10].msg.reactions), 1)
}

// ---- threads ----

@(test)
test_opening_a_thread :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_msgs(&tc)
	defer close_msgs(&tc)
	c := &tc.c

	thread_open(c, {0, 50})
	thread_open(c, {3, 0})
	testing.expect_value(t, len(c.msgs.threads), 0)

	thread_open(c, {3, 50})
	testing.expect_value(t, len(c.msgs.threads), 1)
	sent := tc_sent(t, &tc)
	testing.expect_value(t, len(sent), 2)
	if len(sent) == 2 {
		// The replies, and the root.
		replies, _ := proto.decode_msg_history(sent[0].body)
		testing.expect_value(t, replies.thread_root, proto.Msg_Id(50))
		testing.expect_value(t, replies.dir, proto.History_Dir.Before)
		root, _ := proto.decode_msg_history(sent[1].body)
		testing.expect_value(t, root.anchor, proto.Msg_Id(50))
		testing.expect_value(t, root.dir, proto.History_Dir.Around)
		testing.expect_value(t, root.limit, 1)
		testing.expect_value(t, root.thread_root, proto.Msg_Id(0))

		// The root arrives and is shown.
		tc_answer(&tc, sent[1].id, .Ok, page(0, pm(50, "the root")))
		testing.expect(t, c.msgs.roots[50].have)
		testing.expect_value(t, v.roots[50].msg.text, "the root")
		tc_answer(&tc, sent[0].id, .Ok, page(0, pm(51), pm(52)))
		expect_ids(t, c.msgs.caches[{3, 50}], 51, 52)
	}
	// Opening it again changes nothing.
	thread_open(c, {3, 50})
	testing.expect_value(t, len(c.msgs.threads), 1)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
}

@(test)
test_a_root_that_is_not_there :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_msgs(&tc)
	defer close_msgs(&tc)
	c := &tc.c

	// Nothing to fetch for no root, an unknown conversation, or before the sync.
	root_want(c, 3, 0)
	root_want(c, 99, 50)
	c.convs.synced = false
	root_want(c, 3, 50)
	c.convs.synced = true
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)

	root_want(c, 3, 50)
	r1, _ := tc_one(t, &tc, .Msg_History)
	root_want(c, 3, 50) // asked once
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	// A page that has another message, or none, means the root is gone.
	tc_answer(&tc, r1.id, .Ok, page(0, pm(49)))
	testing.expect(t, v.roots_missing[50])

	root_want(c, 3, 51)
	r2, _ := tc_one(t, &tc, .Msg_History)
	tc_answer(&tc, r2.id, .Ok, page(0))
	testing.expect(t, v.roots_missing[51])
	root_want(c, 3, 52)
	r3, _ := tc_one(t, &tc, .Msg_History)
	tc_answer(&tc, r3.id, .Denied)
	testing.expect(t, v.roots_missing[52])

	// A lost connection is not a missing root: it is asked for again.
	root_want(c, 3, 53)
	r4, _ := tc_one(t, &tc, .Msg_History)
	tc_restart(&tc)
	_ = r4
	testing.expect(t, 53 not_in c.msgs.roots)
	root_want(c, 3, 53)
	_, again := tc_one(t, &tc, .Msg_History)
	testing.expect(t, again)
	testing.expect(t, !v.roots_missing[53])
}

@(test)
test_only_a_few_threads_stay_open :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_msgs(&tc)
	defer close_msgs(&tc)
	c := &tc.c
	for i in 0 ..< MAX_THREADS {
		thread_open(c, {3, proto.Msg_Id(50 + i)})
	}
	_ = tc_sent(t, &tc)
	testing.expect_value(t, len(c.msgs.threads), MAX_THREADS)
	testing.expect(t, ({3, 50}) in c.msgs.caches)

	// Another one closes the one opened longest ago, with its window and root.
	thread_open(c, {3, 99})
	testing.expect_value(t, len(c.msgs.threads), MAX_THREADS)
	testing.expect(t, ({3, 50}) not_in c.msgs.caches)
	testing.expect(t, 50 not_in c.msgs.roots)
	testing.expect(t, ({3, 99}) in c.msgs.caches)
	testing.expect(t, ({3, 51}) in c.msgs.caches)
}

@(test)
test_closing_a_thread :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_msgs(&tc)
	defer close_msgs(&tc)
	c := &tc.c

	thread_open(c, {3, 50})
	_ = tc_sent(t, &tc)
	thread_close(c, {3, 50})
	testing.expect_value(t, len(c.msgs.threads), 0)
	testing.expect(t, ({3, 50}) not_in c.msgs.caches)
	testing.expect(t, 50 not_in c.msgs.roots)

	// When the conversation's own window is there, the root is kept for it.
	messages_view(c, 3)
	_ = tc_sent(t, &tc)
	thread_open(c, {3, 60})
	_ = tc_sent(t, &tc)
	thread_close(c, {3, 60})
	testing.expect(t, 60 in c.msgs.roots)
	// Closing what isn't open is harmless.
	thread_close(c, {3, 77})
}

@(test)
test_open_threads_are_fetched_again_with_the_conversation :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_msgs(&tc)
	defer close_msgs(&tc)
	c := &tc.c
	thread_open(c, {3, 50})
	_ = tc_sent(t, &tc)

	// A new connection drops every window and root, but not the open threads.
	messages_restart(c)
	testing.expect_value(t, len(c.msgs.caches), 0)
	testing.expect_value(t, len(c.msgs.roots), 0)
	testing.expect_value(t, len(c.msgs.threads), 1)
	messages_view(c, 3)
	sent := tc_sent(t, &tc)
	// The conversation, then the thread's replies and its root.
	testing.expect_value(t, len(sent), 3)
}

@(test)
test_restart_and_logout :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_msgs(&tc)
	defer close_msgs(&tc)
	c := &tc.c
	_ = window(t, &tc, pm(10))
	c.convs.viewing = 3
	c.msgs.pins_conv = 3
	c.msgs.last_typing = time.tick_now()
	chat_send(c, "unsent")
	drive_outbox(c)
	_ = tc_sent(t, &tc)
	testing.expect(t, c.msgs.outbox[0].asking)
	thread_open(c, {3, 10})
	_ = tc_sent(t, &tc)

	// A new connection: the window is gone, the outbox is posted again.
	messages_restart(c)
	testing.expect_value(t, len(c.msgs.caches), 0)
	testing.expect_value(t, c.msgs.pins_conv, proto.Conv_Id(0))
	testing.expect_value(t, c.msgs.last_typing, time.Tick{})
	testing.expect_value(t, len(c.msgs.outbox), 1)
	testing.expect(t, !c.msgs.outbox[0].asking)
	testing.expect_value(t, len(c.msgs.threads), 1)

	// Logged out: what was written but not sent, and the threads, are forgotten.
	messages_restart(c, forget = true)
	testing.expect_value(t, len(c.msgs.outbox), 0)
	testing.expect_value(t, len(c.msgs.threads), 0)
}

// ---- finding messages ----

@(test)
test_finding_a_message :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_msgs(&tc)
	defer close_msgs(&tc)
	c := &tc.c
	_ = window(t, &tc, pm(10), pm(11))
	c.msgs.roots[50] = {
		conv = 3,
		have = true,
		msg  = msg_of(pm(50, "a root")),
	}
	c.msgs.roots[51] = {
		conv = 3,
		have = false,
	}

	m, found := msg_find(c, 3, 11)
	testing.expect(t, found)
	testing.expect_value(t, m.id, proto.Msg_Id(11))
	m, found = msg_find(c, 3, 50)
	testing.expect(t, found)
	testing.expect_value(t, m.text, "a root")
	// Not in another conversation, not one that isn't fetched yet, not one we don't have.
	_, found = msg_find(c, 4, 11)
	testing.expect(t, !found)
	_, found = msg_find(c, 3, 51)
	testing.expect(t, !found)
	_, found = msg_find(c, 3, 999)
	testing.expect(t, !found)
}

@(test)
test_posting_brings_the_window_to_its_end :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_msgs(&tc)
	defer close_msgs(&tc)
	c := &tc.c
	cache := window(t, &tc, pm(10))
	to_the_end(c, {3, 0})
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	cache.have_newest = false
	to_the_end(c, {3, 0})
	h, _ := history(t, &tc)
	testing.expect_value(t, h.anchor, proto.Msg_Id(0))
	testing.expect_value(t, h.dir, proto.History_Dir.Before)
	// Once, while it is on its way.
	to_the_end(c, {3, 0})
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	to_the_end(c, {4, 0})
}

// ---- how a message is kept ----

@(test)
test_a_message_as_we_keep_it :: proc(t: ^testing.T) {
	m := proto.Message {
		id               = 5,
		sender           = 2,
		kind             = .Text,
		text             = "hi",
		flags            = {.Has_Attachments, .Persona},
		reply_count      = 3,
		last_reply       = 9,
		attachment_count = 3,
	}
	m.persona = {
		name   = "Bot Name",
		avatar = 77,
	}
	m.attachments[0] = {
		blob   = 1,
		size   = 10,
		name   = "../../x.png",
		width  = 4,
		height = 5,
	}
	m.attachments[1] = {
		blob = 2,
		size = 20,
		name = "",
	}
	m.attachments[2] = {
		blob = 0,
		size = 30,
		name = "removed.zip",
	}
	kept := msg_of(m)
	defer msg_destroy(&kept)
	testing.expect_value(t, kept.text, "hi")
	testing.expect_value(t, kept.reply_count, 3)
	testing.expect_value(t, kept.persona.name, "Bot Name")
	testing.expect_value(t, kept.persona.avatar, proto.Blob_Id(77))
	testing.expect_value(t, len(kept.files), 3)
	// Names cannot take a path with them, and a missing name is still a file.
	testing.expect_value(t, kept.files[0].name, "x.png")
	testing.expect_value(t, kept.files[0].width, 4)
	testing.expect_value(t, kept.files[1].name, "file")
	testing.expect_value(t, kept.files[2].blob, proto.Blob_Id(0))

	// A file's message shows its name as its text.
	f := msg_of({id = 6, kind = .File, file_name = "doc.zip", file_size = 99, text = "ignored"})
	defer msg_destroy(&f)
	testing.expect_value(t, f.text, "doc.zip")
	testing.expect_value(t, f.file_size, u64(99))
	// Without the flag, attachments are not read.
	plain := msg_of({id = 7, kind = .Text, text = "x", attachment_count = 2})
	defer msg_destroy(&plain)
	testing.expect_value(t, len(plain.files), 0)
	testing.expect_value(t, len(plain.persona.name), 0)
}

#+build !wasi
package conn

import "core:fmt"
import "core:testing"

import "common:proto"

// Tests of bookmarks (bookmarks.odin) and of acting on messages
// (message_actions.odin): what is asked of the server, what is shown when
// the answers arrive, and what is ignored because it came too late.

@(private = "file")
open_chat :: proc(tc: ^Test_Conn) -> ^View {
	tc_open(tc)
	tc.c.auth.me = 1
	tc_account(tc, 1, "bob", "Bob")
	tc_account(tc, 2, "alice", "Alice")
	tc_conv(tc, 3, "Lobby")
	tc_conv(tc, 4, "Gaming")
	return tc_view(tc)
}

@(private = "file")
page_body :: proc(list: []proto.Bookmark, more: bool) -> []u8 {
	out := make([]u8, 16 * 1024, context.temp_allocator)
	body, _ := proto.encode_bookmarks_page(out, list, more)
	return body
}

@(private = "file")
marked :: proc(id: proto.Msg_Id, time: proto.Unix_Ms, text: string) -> proto.Bookmark {
	return {
		time = time,
		msg = {id = id, conv = 3, sender = 2, time = time, kind = .Text, text = text},
	}
}

// ---- bookmarks ----

@(test)
test_bookmark_ids_follow_the_server :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_chat(&tc)
	defer tc_close(&tc)
	defer bookmarks_destroy(&tc.c)

	// The login sync says which are bookmarked.
	buf: [proto.BOOKMARKS_MAX_SIZE]u8
	tc_event(&tc, .Bookmarks, proto.encode_bookmarks(&buf, {5, 9, 12}))
	testing.expect_value(t, len(tc.c.bookmarks.ids), 3)
	testing.expect(t, tc.c.bookmarks.ids[9])
	testing.expect_value(t, len(v.bookmarks.ids), 3)

	// A new sync replaces them, one change adds or removes one.
	tc_event(&tc, .Bookmarks, proto.encode_bookmarks(&buf, {7}))
	testing.expect_value(t, len(tc.c.bookmarks.ids), 1)
	changed: [proto.BOOKMARK_CHANGED_SIZE]u8
	tc_event(&tc, .Bookmark_Changed, proto.encode_bookmark_changed(&changed, 20, 1000, true))
	testing.expect(t, tc.c.bookmarks.ids[20] && tc.c.bookmarks.ids[7])
	testing.expect(t, v.bookmarks.ids[20])
	tc_event(&tc, .Bookmark_Changed, proto.encode_bookmark_changed(&changed, 7, 1001, false))
	testing.expect(t, !tc.c.bookmarks.ids[7])
	testing.expect(t, !v.bookmarks.ids[7])
	testing.expect_value(t, len(v.bookmarks.ids), 1)

	// Bad bodies change nothing. No list is asked for while it isn't shown.
	count := v.bookmarks.count
	tc_event(&tc, .Bookmark_Changed, []u8{1, 2, 3})
	tc_event(&tc, .Bookmarks, []u8{9})
	testing.expect_value(t, v.bookmarks.count, count)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
}

@(test)
test_bookmark_list_pages :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_chat(&tc)
	defer tc_close(&tc)
	defer bookmarks_destroy(&tc.c)
	c := &tc.c

	bookmarks_command(c, {})
	testing.expect(t, c.bookmarks.listing)
	testing.expect(t, v.bookmarks.loading)
	r, ok := tc_one(t, &tc, .Bookmarks_Get)
	testing.expect(t, ok)
	before_time, before, dec := proto.decode_bookmarks_get(r.body)
	testing.expect(t, dec && before_time == 0 && before == 0)

	// The first page.
	tc_answer(
		&tc,
		r.id,
		.Ok,
		page_body({marked(30, 900, "newest"), marked(20, 800, "middle")}, true),
	)
	testing.expect_value(t, len(v.bookmarks.list), 2)
	testing.expect(t, v.bookmarks.listed && v.bookmarks.more && !v.bookmarks.loading)
	if len(v.bookmarks.list) == 2 {
		testing.expect_value(t, v.bookmarks.list[0].msg.text, "newest")
		testing.expect_value(t, v.bookmarks.list[0].time, proto.Unix_Ms(900))
		testing.expect_value(t, v.bookmarks.list[1].msg.id, proto.Msg_Id(20))
	}

	// The next page starts after the last one shown, and is added to the list.
	bookmarks_command(c, {more = true})
	r, ok = tc_one(t, &tc, .Bookmarks_Get)
	testing.expect(t, ok)
	before_time, before, _ = proto.decode_bookmarks_get(r.body)
	testing.expect_value(t, before_time, proto.Unix_Ms(800))
	testing.expect_value(t, before, proto.Msg_Id(20))
	tc_answer(&tc, r.id, .Ok, page_body({marked(10, 700, "oldest")}, false))
	testing.expect_value(t, len(v.bookmarks.list), 3)
	testing.expect(t, !v.bookmarks.more)

	// A change to the bookmarks while the list is shown starts it over.
	changed: [proto.BOOKMARK_CHANGED_SIZE]u8
	tc_event(&tc, .Bookmark_Changed, proto.encode_bookmark_changed(&changed, 40, 1000, true))
	r, ok = tc_one(t, &tc, .Bookmarks_Get)
	testing.expect(t, ok)
	before_time, before, _ = proto.decode_bookmarks_get(r.body)
	testing.expect(t, before_time == 0 && before == 0)
	tc_answer(&tc, r.id, .Ok, page_body({marked(40, 1000, "fresh")}, false))
	testing.expect_value(t, len(v.bookmarks.list), 1)
	testing.expect_value(t, v.bookmarks.list[0].msg.text, "fresh")

	// An empty first page is an empty list, shown as loaded.
	bookmarks_command(c, {})
	r, _ = tc_one(t, &tc, .Bookmarks_Get)
	tc_answer(&tc, r.id, .Ok, page_body(nil, false))
	testing.expect_value(t, len(v.bookmarks.list), 0)
	testing.expect(t, v.bookmarks.listed)
	// Nothing more to ask for after it.
	bookmarks_command(c, {more = true})
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
}

@(test)
test_bookmark_list_stale_pages :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_chat(&tc)
	defer tc_close(&tc)
	defer bookmarks_destroy(&tc.c)
	c := &tc.c

	// The list is closed while its first page is on its way: the page is dropped.
	bookmarks_command(c, {})
	r, _ := tc_one(t, &tc, .Bookmarks_Get)
	bookmarks_command(c, {close = true})
	testing.expect(t, !c.bookmarks.listing)
	tc_answer(&tc, r.id, .Ok, page_body({marked(1, 1, "x")}, false))
	testing.expect_value(t, len(v.bookmarks.list), 0)

	// ... and a changed bookmark no longer asks for the list.
	changed: [proto.BOOKMARK_CHANGED_SIZE]u8
	tc_event(&tc, .Bookmark_Changed, proto.encode_bookmark_changed(&changed, 2, 1, true))
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	// Asking for more of a list that isn't shown does nothing.
	bookmarks_command(c, {more = true})
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)

	// Two requests for the first page: only the last one counts.
	bookmarks_command(c, {})
	first, _ := tc_one(t, &tc, .Bookmarks_Get)
	bookmarks_command(c, {})
	second, _ := tc_one(t, &tc, .Bookmarks_Get)
	tc_answer(&tc, first.id, .Ok, page_body({marked(1, 1, "old answer")}, false))
	testing.expect_value(t, len(v.bookmarks.list), 0)
	tc_answer(&tc, second.id, .Ok, page_body({marked(2, 2, "new answer")}, false))
	testing.expect_value(t, len(v.bookmarks.list), 1)
	testing.expect_value(t, v.bookmarks.list[0].msg.text, "new answer")
}

@(test)
test_bookmark_list_failures :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_chat(&tc)
	defer tc_close(&tc)
	defer bookmarks_destroy(&tc.c)

	bookmarks_command(&tc.c, {})
	r, _ := tc_one(t, &tc, .Bookmarks_Get)
	tc_answer(&tc, r.id, .Internal)
	testing.expect_value(t, v.notice.text, "The server failed to list the bookmarks (Internal).")
	testing.expect(t, !v.notice.ok)
	testing.expect(t, !v.bookmarks.loading, "the list was left loading")

	// A lost connection is not worth a notice; the list is asked for again
	// once the sync arrives.
	count := v.notice.count
	bookmarks_command(&tc.c, {})
	_ = tc_sent(t, &tc)
	tc_restart(&tc)
	testing.expect_value(t, v.notice.count, count)

	// A page that can't be read changes nothing.
	bookmarks_command(&tc.c, {})
	r, _ = tc_one(t, &tc, .Bookmarks_Get)
	tc_answer(&tc, r.id, .Ok, []u8{5, 5, 5})
	testing.expect_value(t, len(v.bookmarks.list), 0)
}

@(test)
test_bookmarked_message_changes :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_chat(&tc)
	defer tc_close(&tc)
	defer bookmarks_destroy(&tc.c)
	c := &tc.c

	buf: [proto.BOOKMARKS_MAX_SIZE]u8
	tc_event(&tc, .Bookmarks, proto.encode_bookmarks(&buf, {30}))
	bookmarks_command(c, {})
	r, _ := tc_one(t, &tc, .Bookmarks_Get)
	tc_answer(
		&tc,
		r.id,
		.Ok,
		page_body({marked(30, 900, "before"), marked(31, 800, "other")}, false),
	)

	// An edit to a bookmarked message is shown in the list; one to another message is not.
	edited := msg_of({id = 30, conv = 3, sender = 2, kind = .Text, text = "after", edited = 5000})
	defer msg_destroy(&edited)
	bookmarked_changed(c, edited)
	testing.expect_value(t, v.bookmarks.list[0].msg.text, "after")
	testing.expect_value(t, v.bookmarks.list[1].msg.text, "other")
	unmarked := msg_of({id = 31, conv = 3, sender = 2, kind = .Text, text = "changed"})
	defer msg_destroy(&unmarked)
	bookmarked_changed(c, unmarked)
	testing.expect_value(t, v.bookmarks.list[1].msg.text, "other")

	// With the list closed nothing is kept up to date.
	bookmarks_command(c, {close = true})
	again := msg_of({id = 30, conv = 3, sender = 2, kind = .Text, text = "later"})
	defer msg_destroy(&again)
	bookmarked_changed(c, again)
	testing.expect_value(t, v.bookmarks.list[0].msg.text, "after")
}

@(test)
test_bookmark_set :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_chat(&tc)
	defer tc_close(&tc)
	defer bookmarks_destroy(&tc.c)

	bookmark_set(&tc.c, 55, true)
	r, ok := tc_one(t, &tc, .Bookmark_Set)
	testing.expect(t, ok)
	id, on, dec := proto.decode_bookmark_set(r.body)
	testing.expect(t, dec && on)
	testing.expect_value(t, id, proto.Msg_Id(55))
	// Success is not announced: the bookmark arrives as an event.
	count := v.notice.count
	tc_answer(&tc, r.id, .Ok)
	testing.expect_value(t, v.notice.count, count)
	testing.expect(t, !tc.c.bookmarks.ids[55])

	bookmark_set(&tc.c, 55, false)
	r, _ = tc_one(t, &tc, .Bookmark_Set)
	_, on, _ = proto.decode_bookmark_set(r.body)
	testing.expect(t, !on)

	Case :: struct {
		status: proto.Status,
		text:   string,
	}
	for k in ([]Case {
			{
				.Too_Large,
				fmt.tprintf("You can't have more than %d bookmarks.", proto.MAX_BOOKMARKS),
			},
			{.Not_Found, "That message no longer exists."},
			{.Invalid, "A deleted message can't be bookmarked."},
			{.Internal, "The server failed to change the bookmark (Internal)."},
		}) {
		bookmark_set(&tc.c, 55, true)
		r, _ = tc_one(t, &tc, .Bookmark_Set)
		tc_answer(&tc, r.id, k.status)
		testing.expectf(t, v.notice.text == k.text, "%v: %q", k.status, v.notice.text)
	}
}

// ---- acting on messages ----

@(test)
test_react :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_chat(&tc)
	defer tc_close(&tc)

	msg_react(&tc.c, {id = 77, emoji = "🎉", on = true})
	r, ok := tc_one(t, &tc, .Msg_React)
	testing.expect(t, ok)
	id, emoji, on, dec := proto.decode_msg_react(r.body)
	testing.expect(t, dec && on)
	testing.expect_value(t, id, proto.Msg_Id(77))
	testing.expect_value(t, emoji, "🎉")
	msg_react(&tc.c, {id = 77, emoji = "🎉", on = false})
	r, _ = tc_one(t, &tc, .Msg_React)
	_, _, on, _ = proto.decode_msg_react(r.body)
	testing.expect(t, !on)

	// An emoji too long to send is not sent.
	long := make([]u8, 400, context.temp_allocator)
	for &b in long {
		b = 'e'
	}
	msg_react(&tc.c, {id = 77, emoji = string(long), on = true})
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)

	count := v.notice.count
	msg_react(&tc.c, {id = 77, emoji = "🎉", on = true})
	r, _ = tc_one(t, &tc, .Msg_React)
	tc_answer(&tc, r.id, .Ok)
	testing.expect_value(t, v.notice.count, count)
	Case :: struct {
		status: proto.Status,
		text:   string,
	}
	for k in ([]Case {
			{
				.Too_Large,
				fmt.tprintf(
					"A message can't have more than %d different reactions.",
					proto.MAX_REACTIONS,
				),
			},
			{.Invalid, "That emoji can't be used as a reaction here."},
			{.Not_Found, "The server failed to add the reaction (Not_Found)."},
		}) {
		msg_react(&tc.c, {id = 77, emoji = "🎉", on = true})
		r, _ = tc_one(t, &tc, .Msg_React)
		tc_answer(&tc, r.id, k.status)
		testing.expectf(t, v.notice.text == k.text, "%v: %q", k.status, v.notice.text)
	}
}

@(test)
test_forward :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_chat(&tc)
	defer tc_close(&tc)

	msg_forward(&tc.c, {msg = 90, name = "gaming"})
	r, ok := tc_one(t, &tc, .Msg_Forward)
	testing.expect(t, ok)
	f, dec := proto.decode_msg_forward(r.body)
	testing.expect(t, dec)
	testing.expect_value(t, f.conv, proto.Conv_Id(4))
	testing.expect_value(t, f.msg, proto.Msg_Id(90))
	testing.expect(t, f.nonce != 0)
	first_nonce := f.nonce

	// By id, with a nonce of its own.
	msg_forward(&tc.c, {msg = 90, conv = 3})
	r, _ = tc_one(t, &tc, .Msg_Forward)
	f, _ = proto.decode_msg_forward(r.body)
	testing.expect_value(t, f.conv, proto.Conv_Id(3))
	testing.expect(t, f.nonce != first_nonce)

	msg_forward(&tc.c, {msg = 90, name = "nowhere"})
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)

	Case :: struct {
		status: proto.Status,
		text:   string,
		ok:     bool,
	}
	for k in ([]Case {
			{.Ok, "Forwarded.", true},
			{
				.Not_Found,
				"The message to forward or the destination conversation no longer exists.",
				false,
			},
			{.Invalid, "That message can't be forwarded.", false},
			{.Denied, "You don't have permission to post in that conversation.", false},
			{.Internal, "The server failed to forward the message (Internal).", false},
		}) {
		msg_forward(&tc.c, {msg = 90, conv = 3})
		r, _ = tc_one(t, &tc, .Msg_Forward)
		tc_answer(&tc, r.id, k.status)
		testing.expectf(t, v.notice.text == k.text, "%v: %q", k.status, v.notice.text)
		testing.expect_value(t, v.notice.ok, k.ok)
	}
}

@(test)
test_edit_delete_pin :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_chat(&tc)
	defer tc_close(&tc)

	msg_edit(&tc.c, 60, "  new text\x00 ")
	r, ok := tc_one(t, &tc, .Msg_Edit)
	testing.expect(t, ok)
	id, text, dec := proto.decode_msg_edit(r.body)
	testing.expect(t, dec)
	testing.expect_value(t, id, proto.Msg_Id(60))
	testing.expect(t, text != "" && !contains_byte(text, 0))
	// An edit to nothing is not sent.
	msg_edit(&tc.c, 60, "")
	msg_edit(&tc.c, 60, "   ")
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)

	msg_delete(&tc.c, 61)
	r, ok = tc_one(t, &tc, .Msg_Delete)
	testing.expect(t, ok)
	del, del_ok := proto.decode_msg_id(r.body)
	testing.expect(t, del_ok)
	testing.expect_value(t, del, proto.Msg_Id(61))

	msg_pin(&tc.c, 62, true)
	r, ok = tc_one(t, &tc, .Msg_Pin)
	testing.expect(t, ok)
	pinned, on, pin_ok := proto.decode_msg_pin(r.body)
	testing.expect(t, pin_ok && on)
	testing.expect_value(t, pinned, proto.Msg_Id(62))
	msg_pin(&tc.c, 62, false)
	r, _ = tc_one(t, &tc, .Msg_Pin)
	_, on, _ = proto.decode_msg_pin(r.body)
	testing.expect(t, !on)

	// All three are answered the same way.
	Case :: struct {
		status: proto.Status,
		text:   string,
	}
	count := v.notice.count
	msg_delete(&tc.c, 61)
	r, _ = tc_one(t, &tc, .Msg_Delete)
	tc_answer(&tc, r.id, .Ok)
	testing.expect_value(t, v.notice.count, count)
	for k in ([]Case {
			{.Denied, "You aren't allowed to modify this message."},
			{
				.Too_Large,
				fmt.tprintf(
					"A conversation can't have more than %d pinned messages.",
					proto.MAX_PINS,
				),
			},
			{.Not_Found, "That message no longer exists."},
			{.Internal, "The server failed to change the message (Internal)."},
		}) {
		msg_pin(&tc.c, 62, true)
		r, _ = tc_one(t, &tc, .Msg_Pin)
		tc_answer(&tc, r.id, k.status)
		testing.expectf(t, v.notice.text == k.text, "%v: %q", k.status, v.notice.text)
	}
}

@(private = "file")
contains_byte :: proc(s: string, b: u8) -> bool {
	for x in transmute([]u8)s {
		if x == b {
			return true
		}
	}
	return false
}

@(test)
test_pins_paging :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_chat(&tc)
	defer tc_close(&tc)
	c := &tc.c

	pins_fetch(c, 0)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)

	out := make([]u8, 8192, context.temp_allocator)
	pin :: proc(id: proto.Msg_Id) -> proto.Message {
		return {id = id, conv = 3, sender = 2, kind = .Text, text = "pinned"}
	}

	pins_fetch(c, 3)
	testing.expect(t, v.pins.loading)
	testing.expect_value(t, v.pins.conv, proto.Conv_Id(3))
	r, ok := tc_one(t, &tc, .Pins_Get)
	testing.expect(t, ok)
	conv, offset, dec := proto.decode_pins_get(r.body)
	testing.expect(t, dec && conv == 3 && offset == 0)

	// A page that says there is more makes the next one be asked for, from
	// where this one ended.
	body, _ := proto.encode_pins_page(out, {pin(1), pin(2), pin(3)}, true)
	tc_answer(&tc, r.id, .Ok, body)
	testing.expect_value(t, len(v.pins.messages), 3)
	testing.expect(t, v.pins.loading)
	r, ok = tc_one(t, &tc, .Pins_Get)
	testing.expect(t, ok)
	conv, offset, _ = proto.decode_pins_get(r.body)
	testing.expect_value(t, offset, 3)
	body, _ = proto.encode_pins_page(out, {pin(4)}, false)
	tc_answer(&tc, r.id, .Ok, body)
	testing.expect_value(t, len(v.pins.messages), 4)
	testing.expect(t, !v.pins.loading)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)

	// Asking again starts over for the same conversation.
	pins_fetch(c, 3)
	r, _ = tc_one(t, &tc, .Pins_Get)
	body, _ = proto.encode_pins_page(out, {pin(9)}, false)
	tc_answer(&tc, r.id, .Ok, body)
	testing.expect_value(t, len(v.pins.messages), 1)

	// A page that claims more but is empty does not loop.
	pins_fetch(c, 3)
	r, _ = tc_one(t, &tc, .Pins_Get)
	body, _ = proto.encode_pins_page(out, nil, true)
	tc_answer(&tc, r.id, .Ok, body)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	testing.expect(t, !v.pins.loading)
}

@(test)
test_pins_for_another_conversation_are_dropped :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_chat(&tc)
	defer tc_close(&tc)
	out := make([]u8, 4096, context.temp_allocator)

	pins_fetch(&tc.c, 3)
	first, _ := tc_one(t, &tc, .Pins_Get)
	pins_fetch(&tc.c, 4) // the window moved on
	second, _ := tc_one(t, &tc, .Pins_Get)
	body, _ := proto.encode_pins_page(out, {{id = 1, conv = 3, kind = .Text, text = "old"}}, false)
	tc_answer(&tc, first.id, .Ok, body)
	testing.expect_value(t, len(v.pins.messages), 0)
	body, _ = proto.encode_pins_page(out, {{id = 2, conv = 4, kind = .Text, text = "new"}}, false)
	tc_answer(&tc, second.id, .Ok, body)
	testing.expect_value(t, len(v.pins.messages), 1)
	testing.expect_value(t, v.pins.conv, proto.Conv_Id(4))

	// A failure leaves what is shown as it was.
	pins_fetch(&tc.c, 4)
	r, _ := tc_one(t, &tc, .Pins_Get)
	tc_answer(&tc, r.id, .Denied)
	testing.expect_value(t, len(v.pins.messages), 1)
}

@(test)
test_reactors :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_chat(&tc)
	defer tc_close(&tc)

	reactors_fetch(&tc.c, 70, "👍")
	r, ok := tc_one(t, &tc, .Reactors_Get)
	testing.expect(t, ok)
	id, emoji, dec := proto.decode_reactors_get(r.body)
	testing.expect(t, dec)
	testing.expect_value(t, id, proto.Msg_Id(70))
	testing.expect_value(t, emoji, "👍")

	buf: [proto.REACTORS_MAX_SIZE]u8
	tc_answer(&tc, r.id, .Ok, proto.encode_reactors(&buf, 7, {1, 2, 3}))
	testing.expect_value(t, v.reactors.id, proto.Msg_Id(70))
	testing.expect_value(t, v.reactors.emoji, "👍")
	testing.expect_value(t, v.reactors.total, 7)
	testing.expect_value(t, len(v.reactors.accounts), 3)

	// The answer to a question that was replaced is dropped.
	reactors_fetch(&tc.c, 71, "🎉")
	old, _ := tc_one(t, &tc, .Reactors_Get)
	reactors_fetch(&tc.c, 72, "🎉")
	newer, _ := tc_one(t, &tc, .Reactors_Get)
	tc_answer(&tc, old.id, .Ok, proto.encode_reactors(&buf, 1, {4}))
	testing.expect_value(t, v.reactors.id, proto.Msg_Id(70))
	tc_answer(&tc, newer.id, .Ok, proto.encode_reactors(&buf, 2, {5, 6}))
	testing.expect_value(t, v.reactors.id, proto.Msg_Id(72))
	testing.expect_value(t, len(v.reactors.accounts), 2)

	// A failed or unreadable answer leaves what is shown alone.
	reactors_fetch(&tc.c, 72, "🎉")
	r, _ = tc_one(t, &tc, .Reactors_Get)
	tc_answer(&tc, r.id, .Not_Found)
	reactors_fetch(&tc.c, 72, "🎉")
	r, _ = tc_one(t, &tc, .Reactors_Get)
	tc_answer(&tc, r.id, .Ok, []u8{1})
	testing.expect_value(t, v.reactors.total, 2)
}

// ---- typing ----

@(test)
test_typing_notices :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_chat(&tc)
	defer tc_close(&tc)
	c := &tc.c
	buf: [proto.TYPING_DOWN_SIZE]u8

	// Someone typing in a conversation we are in.
	handle_typing(c, proto.encode_typing_down(&buf, 3, 0, 2))
	testing.expect(t, is_typing(v, 2, 3))
	testing.expect(t, !is_typing(v, 2, 4), "typing shown in another conversation")
	testing.expect(t, !is_typing(v, 2, 3, 9), "typing shown in a thread it isn't in")
	testing.expect(t, !is_typing(v, 5, 3))
	testing.expect(t, !is_typing_in_thread(v, 2, 3))
	testing.expect(t, typing_until(v) != {})

	// In a thread.
	handle_typing(c, proto.encode_typing_down(&buf, 3, 50, 2))
	testing.expect(t, is_typing(v, 2, 3, 50))
	testing.expect(t, !is_typing(v, 2, 3))
	testing.expect(t, is_typing_in_thread(v, 2, 3))
	testing.expect(t, !is_typing_in_thread(v, 2, 4))

	// Our own typing, and typing in conversations we don't know, are ignored.
	handle_typing(c, proto.encode_typing_down(&buf, 3, 0, 1))
	handle_typing(c, proto.encode_typing_down(&buf, 99, 0, 5))
	testing.expect(t, !is_typing(v, 1, 3))
	testing.expect(t, !is_typing(v, 5, 99))
	// A truncated or padded packet is ignored.
	handle_typing(c, buf[:len(buf) - 1])
	handle_typing(c, nil)
	testing.expect_value(t, len(v.typing), 1)

	// Posting ends it, but only if it was in the same place.
	publish_typing_done(c, {3, 0}, 2)
	testing.expect(t, is_typing(v, 2, 3, 50))
	publish_typing_done(c, {3, 50}, 2)
	testing.expect(t, !is_typing(v, 2, 3, 50))
	testing.expect(t, typing_until(v) == {}, "a typing notice is still due to end")
}

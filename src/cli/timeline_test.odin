package main

import "core:strings"
import "core:testing"

import "client:conn"
import "common:proto"
import "tui"

@(private = "file")
layout :: proc(v: ^conn.View, width := 60, unread_from := proto.Msg_Id(0)) -> Timeline_Layout {
	l: Timeline_Layout
	layout_update(&l, v, {conv = 1}, width, nil, unread_from)
	return l
}

@(test)
test_messages_with_day_line_time_and_name :: proc(t: ^testing.T) {
	v := test_view()
	defer conn.view_destroy(&v)
	add_account(&v, 1, "me")
	add_account(&v, 2, "anna")
	add_message(&v, 1, 10, 2, T0, "morning")
	add_message(&v, 1, 11, 1, T0 + 2 * MINUTE, "hi anna")
	l := layout(&v)
	defer layout_destroy(&l)
	rows := rows_text(&l)
	testing.expect_value(t, len(rows), 4)
	testing.expect_value(t, rows[0], "- start of the conversation -")
	testing.expect(t, strings.has_prefix(rows[1], "── Tue 14 Nov 2023 "), rows[1])
	testing.expect_value(t, rows[2], "22:13 anna morning")
	testing.expect_value(t, rows[3], "22:15 me   hi anna")
	testing.expect_value(t, l.rows[2].msg, 10)
	testing.expect_value(t, l.rows[2].kind, Row_Kind.Head)
}

@(test)
test_a_second_day_gets_its_own_line :: proc(t: ^testing.T) {
	v := test_view()
	defer conn.view_destroy(&v)
	add_account(&v, 2, "anna")
	add_message(&v, 1, 10, 2, T0, "one")
	add_message(&v, 1, 11, 2, T0 + 24 * 60 * MINUTE, "two")
	l := layout(&v)
	defer layout_destroy(&l)
	days := 0
	for r in l.rows {
		if r.kind == .Day {
			days += 1
		}
	}
	testing.expect_value(t, days, 2)
}

@(test)
test_same_sender_in_the_same_minute_is_merged :: proc(t: ^testing.T) {
	v := test_view()
	defer conn.view_destroy(&v)
	add_account(&v, 2, "anna")
	add_account(&v, 3, "ben")
	add_message(&v, 1, 10, 2, T0, "one")
	add_message(&v, 1, 11, 2, T0 + 5_000, "two")
	add_message(&v, 1, 12, 2, T0 + 2 * MINUTE, "three") // another minute
	add_message(&v, 1, 13, 3, T0 + 2 * MINUTE + 1_000, "four") // another sender
	l := layout(&v)
	defer layout_destroy(&l)
	rows := rows_text(&l)[2:]
	testing.expect_value(t, rows[0], "22:13 anna one")
	testing.expect_value(t, rows[1], "           two")
	testing.expect_value(t, rows[2], "22:15 anna three")
	testing.expect_value(t, rows[3], "22:15 ben  four")
}

@(test)
test_long_text_is_wrapped_under_the_text :: proc(t: ^testing.T) {
	v := test_view()
	defer conn.view_destroy(&v)
	add_account(&v, 2, "anna")
	add_message(&v, 1, 10, 2, T0, "the quick brown fox jumps over the lazy dog again and again")
	l := layout(&v, 30)
	defer layout_destroy(&l)
	rows := rows_text(&l)[2:]
	testing.expect(t, len(rows) >= 3)
	for r in rows {
		testing.expectf(t, tui.string_width(r) <= 30, "%q is too wide", r)
	}
	testing.expect(t, strings.has_prefix(rows[1], "           "), rows[1])
	testing.expect_value(t, l.rows[3].kind, Row_Kind.Body)
	// And all the words are still there.
	all := strings.join(rows, " ", context.temp_allocator)
	testing.expect(t, strings.contains(all, "lazy"))
	testing.expect(t, strings.contains(all, "again"))
}

@(test)
test_the_new_messages_line :: proc(t: ^testing.T) {
	v := test_view()
	defer conn.view_destroy(&v)
	add_account(&v, 2, "anna")
	add_message(&v, 1, 10, 2, T0, "old")
	add_message(&v, 1, 11, 2, T0 + 2 * MINUTE, "new")
	l := layout(&v, 40, 10)
	defer layout_destroy(&l)
	at := -1
	for r, i in l.rows {
		if r.kind == .New_Messages {
			at = i
		}
	}
	testing.expect(t, at > 0)
	testing.expect_value(t, row_text(l.rows[at + 1]), "22:15 anna new")
	testing.expect(t, strings.contains(row_text(l.rows[at]), "new messages"))

	// Nothing is unread: no line.
	l2 := layout(&v, 40, 0)
	defer layout_destroy(&l2)
	for r in l2.rows {
		testing.expect(t, r.kind != .New_Messages)
	}
}

@(test)
test_everything_unread_puts_the_line_first :: proc(t: ^testing.T) {
	v := test_view()
	defer conn.view_destroy(&v)
	add_account(&v, 2, "anna")
	add_message(&v, 1, 10, 2, T0, "first")
	l := layout(&v, 40, 5) // read up to a message before the first
	defer layout_destroy(&l)
	found := false
	for r in l.rows {
		found ||= r.kind == .New_Messages
	}
	testing.expect(t, found)
}

@(test)
test_reactions_threads_edits_and_pins :: proc(t: ^testing.T) {
	v := test_view()
	defer conn.view_destroy(&v)
	add_account(&v, 2, "anna")
	m := add_message(&v, 1, 10, 2, T0, "hello")
	m.edited = T0 + 1000
	m.flags += {.Pinned, .Has_Thread}
	m.reply_count = 3
	append(&m.reactions, conn.Reaction{emoji = strings.clone("👍"), count = 2, me = true})
	append(&m.reactions, conn.Reaction{emoji = strings.clone("❤"), count = 1})
	l := layout(&v)
	defer layout_destroy(&l)
	rows := rows_text(&l)[2:]
	testing.expect_value(t, rows[0], "22:13 anna hello (edited) 📌")
	testing.expect_value(t, strings.trim_space(rows[1]), "👍 2   ❤ 1")
	testing.expect_value(t, strings.trim_space(rows[2]), "↩ 3 replies")
	testing.expect_value(t, l.rows[3].kind, Row_Kind.Reactions)
	testing.expect_value(t, l.rows[4].kind, Row_Kind.Thread)
	// The reaction we made is told apart.
	testing.expect(t, l.rows[3].segs[1].style == theme.reaction_me)
	testing.expect(t, l.rows[3].segs[3].style == theme.reaction)
}

@(test)
test_deleted_files_and_system_messages :: proc(t: ^testing.T) {
	v := test_view()
	defer conn.view_destroy(&v)
	add_account(&v, 2, "anna")
	d := add_message(&v, 1, 10, 2, T0, "secret")
	d.flags += {.Deleted}
	f := add_message(&v, 1, 11, 2, T0 + 3 * MINUTE, "report.pdf")
	f.kind = .File
	f.file_size = 3 * 1024 * 1024 + 512 * 1024
	l := layout(&v)
	defer layout_destroy(&l)
	rows := rows_text(&l)[2:]
	testing.expect_value(t, rows[0], "22:13 anna message deleted")
	testing.expect_value(t, rows[1], "22:16 anna 📎 report.pdf  3.5 MB")
}

@(test)
test_files_of_a_message :: proc(t: ^testing.T) {
	v := test_view()
	defer conn.view_destroy(&v)
	add_account(&v, 2, "anna")
	m := add_message(&v, 1, 10, 2, T0, "look")
	m.files = make([]conn.Msg_File, 2)
	m.files[0] = {
		name = strings.clone("a.png"),
		size = 100,
	}
	m.files[1] = {
		name = strings.clone("b.zip"),
		size = 2048,
	}
	l := layout(&v)
	defer layout_destroy(&l)
	rows := rows_text(&l)[2:]
	testing.expect_value(t, strings.trim_space(rows[1]), "📎 a.png  100 B")
	testing.expect_value(t, strings.trim_space(rows[2]), "📎 b.zip  2.0 KB")
}

@(test)
test_mentions_are_shown_by_name :: proc(t: ^testing.T) {
	v := test_view()
	defer conn.view_destroy(&v)
	add_account(&v, 1, "me")
	add_account(&v, 2, "anna")
	add_message(&v, 1, 10, 2, T0, "hey <@1> and <@2>")
	l := layout(&v)
	defer layout_destroy(&l)
	testing.expect_value(t, rows_text(&l)[2], "22:13 anna hey @me and @anna")
	// The one of us is highlighted differently.
	styles: [dynamic]tui.Style
	defer delete(styles)
	for s in l.rows[2].segs {
		if strings.has_prefix(s.text, "@") {
			append(&styles, s.style)
		}
	}
	testing.expect_value(t, len(styles), 2)
	testing.expect(t, styles[0] == theme.mention_me)
	testing.expect(t, styles[1] == theme.mention)
}

@(test)
test_replies_say_what_they_reply_to :: proc(t: ^testing.T) {
	v := test_view()
	defer conn.view_destroy(&v)
	add_account(&v, 2, "anna")
	add_account(&v, 3, "ben")
	m := add_message(&v, 1, 20, 3, T0 + MINUTE, "agreed")
	m.thread_root = 10
	root := conn.View_Message {
		id     = 10,
		sender = 2,
		time   = T0,
		text   = strings.clone("shall we ship?"),
	}
	v.roots[10] = {
		conv = 1,
		msg  = root,
	}
	l := layout(&v)
	defer layout_destroy(&l)
	rows := rows_text(&l)[2:]
	testing.expect_value(t, strings.trim_space(rows[0]), "↪ anna: shall we ship?")
	testing.expect_value(t, l.rows[2].kind, Row_Kind.Reply_To)
	testing.expect_value(t, rows[1], "22:14 ben  agreed")

	// Not in the thread's own window.
	tl := timeline_of(&v, 1, 10)
	append(
		&tl.messages,
		conn.View_Message {
			id = 20,
			sender = 3,
			time = T0 + MINUTE,
			thread_root = 10,
			text = strings.clone("agreed"),
		},
	)
	l2: Timeline_Layout
	defer layout_destroy(&l2)
	layout_update(&l2, &v, {conv = 1, root = 10}, 60, nil, 0)
	for r in l2.rows {
		testing.expect(t, r.kind != .Reply_To)
	}
}

@(test)
test_pending_messages_are_shown_last :: proc(t: ^testing.T) {
	v := test_view()
	defer conn.view_destroy(&v)
	add_account(&v, 2, "anna")
	add_message(&v, 1, 10, 2, T0, "hi")
	append(&v.outbox, conn.View_Pending{conv = 1, text = strings.clone("on its way")})
	l := layout(&v)
	defer layout_destroy(&l)
	last := l.rows[len(l.rows) - 1]
	testing.expect_value(t, last.kind, Row_Kind.Pending)
	testing.expect(t, strings.contains(row_text(last), "on its way"))
	testing.expect(t, strings.has_prefix(row_text(last), "sending"))
}

@(test)
test_unknown_and_loading_timelines :: proc(t: ^testing.T) {
	v := test_view()
	defer conn.view_destroy(&v)
	l := layout(&v)
	defer layout_destroy(&l)
	testing.expect_value(t, len(l.rows), 1)
	testing.expect_value(t, row_text(l.rows[0]), "loading...")
}

@(test)
test_layout_is_kept_until_something_changes :: proc(t: ^testing.T) {
	v := test_view()
	defer conn.view_destroy(&v)
	add_account(&v, 2, "anna")
	add_message(&v, 1, 10, 2, T0, "one")
	l: Timeline_Layout
	defer layout_destroy(&l)
	layout_update(&l, &v, {conv = 1}, 60, nil, 0)
	first := raw_data(l.rows)
	n := len(l.rows)
	layout_update(&l, &v, {conv = 1}, 60, nil, 0)
	testing.expect_value(t, len(l.rows), n)
	testing.expect(t, first == raw_data(l.rows))
	// A new message, a new width.
	add_message(&v, 1, 11, 2, T0 + 5 * MINUTE, "two")
	layout_update(&l, &v, {conv = 1}, 60, nil, 0)
	testing.expect(t, len(l.rows) > n)
	n = len(l.rows)
	layout_update(&l, &v, {conv = 1}, 30, nil, 0)
	testing.expect_value(t, l.key.width, 30)
	testing.expect(t, len(l.rows) >= n)
}

@(test)
test_a_narrow_pane_shows_nothing_rather_than_breaking :: proc(t: ^testing.T) {
	v := test_view()
	defer conn.view_destroy(&v)
	add_account(&v, 2, "anna")
	add_message(&v, 1, 10, 2, T0, "one")
	l := layout(&v, 5)
	defer layout_destroy(&l)
	testing.expect_value(t, len(l.rows), 0)
}

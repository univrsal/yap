#+build !wasi
package proto

import "core:strings"
import "core:testing"

@(test)
test_message_record :: proc(t: ^testing.T) {
	long := strings.repeat("x", MAX_CHAT_SIZE, context.temp_allocator)
	msgs := []Message {
		{
			id = 1,
			conv = 2,
			sender = 3,
			time = 1_700_000_000_123,
			kind = .Text,
			text = "Zoë says ☺",
		},
		{id = 2, conv = 2, sender = 3, time = 1, kind = .Text, text = long},
		{
			id = 3,
			conv = 2,
			sender = 4,
			kind = .Image,
			image = {blob = 77, width = 1920, height = 1080, size = 200_000},
		},
		{id = 4, conv = 9, sender = 4, kind = .File, file_size = 1 << 40, file_name = "a.tar"},
		{id = 5, conv = 9, sender = 4, kind = .System, system = 2, system_arg = 17},
		{
			id = 6,
			conv = 9,
			sender = 4,
			kind = .Text,
			text = "root",
			flags = {.Pinned, .Has_Thread},
			thread_root = 0,
			edited = 55,
			reply_count = 3,
			last_reply = 99,
		},
	}
	for m in msgs {
		buf: [MESSAGE_MAX_SIZE + 64]u8
		body := encode_message(buf[:], m)
		testing.expect(t, body != nil)
		testing.expect_value(t, len(body), message_size(m))
		got, ok := decode_message(body)
		testing.expect(t, ok)
		again: [MESSAGE_MAX_SIZE + 64]u8
		testing.expect_value(t, string(encode_message(again[:], got)), string(body))
		testing.expect(t, got.id == m.id && got.conv == m.conv && got.sender == m.sender)
		testing.expect(t, got.kind == m.kind && got.flags == m.flags && got.time == m.time)
		testing.expect(
			t,
			got.text == m.text && got.image == m.image && got.file_name == m.file_name,
		)
		testing.expect(t, got.reply_count == m.reply_count && got.system_arg == m.system_arg)
		// Cut short, or with something left over, it doesn't read.
		_, ok = decode_message(body[:len(body) - 1])
		testing.expect(t, !ok)
		padded := buf[:len(body) + 1]
		_, ok = decode_message(padded)
		testing.expect(t, !ok)
	}

	// Reactions are carried along as they came, for whoever knows them.
	with := make([dynamic]u8, context.temp_allocator)
	buf: [MESSAGE_MAX_SIZE]u8
	body := encode_message(buf[:], msgs[0])
	append(&with, ..body[:len(body) - 1])
	append(&with, 1, 2, 'o', 'k', 5, 0, 1)
	got, ok := decode_message(with[:])
	testing.expect(t, ok)
	testing.expect_value(t, got.reaction_count, 1)
	testing.expect_value(t, len(got.reactions), 6)

	// Too long a text, a kind from a newer server, and id 0 are refused.
	bad := msgs[0]
	bad.text = strings.repeat("x", MAX_CHAT_SIZE + 1, context.temp_allocator)
	big: [2 * MESSAGE_MAX_SIZE]u8
	testing.expect(t, encode_message(big[:], bad) == nil)
	body = encode_message(buf[:], msgs[0])
	body[24] = 9
	_, ok = decode_message(body)
	testing.expect(t, !ok)
	zero := msgs[0]
	zero.id = 0
	_, ok = decode_message(encode_message(buf[:], zero))
	testing.expect(t, !ok)
}

@(test)
test_history_page :: proc(t: ^testing.T) {
	long := strings.repeat("y", MAX_CHAT_SIZE, context.temp_allocator)
	msgs := make([]Message, MAX_HISTORY_LIMIT, context.temp_allocator)
	for &m, i in msgs {
		m = {
			id     = Msg_Id(100 + i),
			conv   = 1,
			sender = 2,
			kind   = .Text,
			text   = long,
		}
	}
	// A page of the longest messages is as many as fit in one stream
	// message (the server cuts pages to fit, history_page).
	out := make([]u8, MAX_BODY_SIZE, context.temp_allocator)
	body, count := encode_history_page(out, MORE_BEFORE, msgs)
	fit := min(MAX_HISTORY_LIMIT, (MAX_BODY_SIZE - HISTORY_HEADER_SIZE) / message_size(msgs[0]))
	testing.expect_value(t, count, fit)
	buf: [MAX_HISTORY_LIMIT]Message
	more, got, ok := decode_history_page(body, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, more, MORE_BEFORE)
	testing.expect_value(t, len(got), fit)
	testing.expect_value(t, got[fit - 1].id, Msg_Id(100 + fit - 1))
	testing.expect_value(t, got[fit - 1].text, long)

	// Where they don't all fit, as many as do, from the first.
	small := make(
		[]u8,
		3 * message_size(msgs[0]) + HISTORY_HEADER_SIZE + 10,
		context.temp_allocator,
	)
	body, count = encode_history_page(small, 0, msgs)
	testing.expect_value(t, count, 3)
	more, got, ok = decode_history_page(body, buf[:])
	testing.expect(t, ok && len(got) == 3 && got[0].id == 100)

	// More than there's room for on this side is refused.
	_, _, ok = decode_history_page(body, buf[:2])
	testing.expect(t, !ok)
	// So is an empty body, and one cut short.
	_, _, ok = decode_history_page(nil, buf[:])
	testing.expect(t, !ok)
	_, _, ok = decode_history_page(body[:len(body) - 1], buf[:])
	testing.expect(t, !ok)
	// An empty page is one.
	body, count = encode_history_page(out, MORE_AFTER, nil)
	more, got, ok = decode_history_page(body, buf[:])
	testing.expect(t, ok && len(got) == 0 && more == MORE_AFTER)
}

@(test)
test_msg_bodies :: proc(t: ^testing.T) {
	// Posting.
	post_buf: [MSG_POST_MAX_SIZE]u8
	body := encode_msg_post(post_buf[:], {conv = 3, nonce = 0xfeed, kind = .Text, text = "hello"})
	p, ok := decode_msg_post(body)
	testing.expect(t, ok)
	testing.expect_value(t, p, Msg_Post{conv = 3, nonce = 0xfeed, kind = .Text, text = "hello"})
	body = encode_msg_post(
		post_buf[:],
		{conv = 3, nonce = 1, thread_root = 8, kind = .Image, blob = 42},
	)
	p, ok = decode_msg_post(body)
	testing.expect(t, ok && p.kind == .Image && p.blob == 42 && p.thread_root == 8)
	_, ok = decode_msg_post(body[:len(body) - 1])
	testing.expect(t, !ok)
	// Only text and pictures are posted like this.
	testing.expect(t, encode_msg_post(post_buf[:], {conv = 3, kind = .System}) == nil)
	body = encode_msg_post(post_buf[:], {conv = 3, kind = .Image, blob = 1})
	body[20] = u8(Msg_Kind.File)
	_, ok = decode_msg_post(body)
	testing.expect(t, !ok)
	long := strings.repeat("z", MAX_CHAT_SIZE + 1, context.temp_allocator)
	big: [2 * MSG_POST_MAX_SIZE]u8
	body = encode_msg_post(big[:], {conv = 3, kind = .Text, text = long})
	_, ok = decode_msg_post(body)
	testing.expect(t, !ok)

	posted_buf: [MSG_POSTED_SIZE]u8
	id, time, posted_ok := decode_msg_posted(encode_msg_posted(&posted_buf, 12, 34))
	testing.expect(t, posted_ok && id == 12 && time == 34)

	// History.
	history_buf: [MSG_HISTORY_SIZE]u8
	want := Msg_History {
		conv   = 5,
		anchor = 900,
		dir    = .Around,
		limit  = 20,
	}
	h, h_ok := decode_msg_history(encode_msg_history(&history_buf, want))
	testing.expect(t, h_ok)
	testing.expect_value(t, h, want)
	history_buf[21] = MAX_HISTORY_LIMIT + 1
	_, h_ok = decode_msg_history(history_buf[:])
	testing.expect(t, !h_ok)
	history_buf[21] = 1
	history_buf[20] = 3
	_, h_ok = decode_msg_history(history_buf[:])
	testing.expect(t, !h_ok)

	// Blobs.
	put_buf: [BLOB_PUT_SIZE]u8
	put := Blob_Put {
		kind   = .Image,
		size   = 1234,
		width  = 640,
		height = 480,
	}
	put.hash[0], put.hash[31] = 1, 2
	got_put, put_ok := decode_blob_put(encode_blob_put(&put_buf, put))
	testing.expect(t, put_ok)
	testing.expect_value(t, got_put, put)

	answer_buf: [BLOB_PUT_ANSWER_SIZE]u8
	blob, have, handle, answer_ok := decode_blob_put_answer(
		encode_blob_put_answer(&answer_buf, 7, true, 0),
	)
	testing.expect(t, answer_ok && blob == 7 && have && handle == 0)
	blob, have, handle, answer_ok = decode_blob_put_answer(
		encode_blob_put_answer(&answer_buf, 0, false, 99),
	)
	testing.expect(t, answer_ok && !have && handle == 99)
	_, _, _, answer_ok = decode_blob_put_answer(encode_blob_put_answer(&answer_buf, 0, true, 0))
	testing.expect(t, !answer_ok)

	id_buf: [BLOB_GET_SIZE]u8
	got_blob, blob_ok := decode_blob_id(encode_blob_id(&id_buf, 55))
	testing.expect(t, blob_ok && got_blob == 55)
	get_buf: [BLOB_GET_ANSWER_SIZE]u8
	size, get_handle, get_ok := decode_blob_get_answer(encode_blob_get_answer(&get_buf, 1000, 3))
	testing.expect(t, get_ok && size == 1000 && get_handle == 3)
	_, _, get_ok = decode_blob_get_answer(encode_blob_get_answer(&get_buf, MAX_BLOB_SIZE + 1, 3))
	testing.expect(t, !get_ok)

	// A refused upload says so.
	need_buf: [MAX_PAYLOAD_SIZE]u8
	need, _ := encode_blob_need(need_buf[:], 99, false, nil, failed = true)
	testing.expect(t, blob_need_failed(need))
	need, _ = encode_blob_need(need_buf[:], 99, true, nil)
	testing.expect(t, !blob_need_failed(need))
}

@(test)
test_typing :: proc(t: ^testing.T) {
	up_buf: [TYPING_UP_SIZE]u8
	up := encode_typing_up(&up_buf, 4, 0)
	kind, ok := message_kind(up)
	testing.expect(t, ok && kind == .Typing)
	conv, root := decode_typing_up(up)
	testing.expect(t, conv == 4 && root == 0)

	down_buf: [TYPING_DOWN_SIZE]u8
	down := encode_typing_down(&down_buf, 4, 8, 17)
	kind, ok = message_kind(down)
	testing.expect(t, ok && kind == .Typing)
	conv2, root2, account := decode_typing_down(down)
	testing.expect(t, conv2 == 4 && root2 == 8 && account == 17)

	// The old sizes are gone.
	_, ok = message_kind(up[:1])
	testing.expect(t, !ok)
	_, ok = message_kind(down[:5])
	testing.expect(t, !ok)
}

@(test)
test_old_chat_retired :: proc(t: ^testing.T) {
	for kind in ([]Message_Kind {
			.Chat_Send,
			.Chat_Sent,
			.Chat,
			.Chat_Received,
			.Image_Send,
			.Image_Get,
			.Image_Gone,
		}) {
		pt := make([]u8, 64, context.temp_allocator)
		pt[0] = u8(kind)
		_, ok := message_kind(pt)
		testing.expect(t, !ok)
	}
}

@(test)
test_sanitize_text :: proc(t: ^testing.T) {
	buf: [MAX_CHAT_SIZE]u8
	testing.expect_value(t, sanitize_text("  a\tb\r\nc\x00‮  ", buf[:]), "a b  c")
	long := strings.repeat("é", MAX_CHAT_SIZE, context.temp_allocator)
	got := sanitize_text(long, buf[:])
	// Cut at a character boundary.
	testing.expect_value(t, len(got), MAX_CHAT_SIZE)
}

@(test)
test_sanitize_message :: proc(t: ^testing.T) {
	buf: [MAX_CHAT_SIZE]u8
	cases := [?][2]string {
		{"one line", "one line"},
		{"  \n\n  first\nsecond  \n\n", "first\nsecond"},
		{"a\r\nb\rc\u2028d", "a\nb\nc\nd"},
		{"a\r\n\r\nb", "a\n\nb"},
		// Indentation stays, trailing whitespace goes.
		{"list:\n  - one \t\n\t- two", "list:\n  - one\n - two"},
		// At most two blank lines in a row.
		{"a\n\n\n\n\n\nb", "a\n\n\nb"},
		{"a\n \n\t\n \n\nb", "a\n\n\nb"},
		{"a\x00b\u202ec\x7f", "abc"},
		{" \n\t\r\n", ""},
	}
	for c in cases {
		testing.expect_value(t, sanitize_message(c[0], buf[:]), c[1])
	}
	long := strings.repeat("é", MAX_CHAT_SIZE, context.temp_allocator)
	got := sanitize_message(long, buf[:])
	testing.expect_value(t, len(got), MAX_CHAT_SIZE)
	// A line that doesn't fit isn't started.
	small: [4]u8
	testing.expect_value(t, sanitize_message("abc\nd", small[:]), "abc")
}

@(test)
test_edit_delete_pin_bodies :: proc(t: ^testing.T) {
	edit_buf: [MSG_EDIT_MAX_SIZE]u8
	id, text, ok := decode_msg_edit(encode_msg_edit(&edit_buf, 42, "better words"))
	testing.expect(t, ok)
	testing.expect_value(t, id, Msg_Id(42))
	testing.expect_value(t, text, "better words")
	_, _, ok = decode_msg_edit(edit_buf[:5])
	testing.expect(t, !ok, "a cut-off edit")

	id_buf: [MSG_ID_SIZE]u8
	id, ok = decode_msg_id(encode_msg_id(&id_buf, 7))
	testing.expect(t, ok && id == 7)
	_, ok = decode_msg_id(encode_msg_id(&id_buf, 0))
	testing.expect(t, !ok, "message 0")

	pin_buf: [MSG_PIN_SIZE]u8
	on: bool
	id, on, ok = decode_msg_pin(encode_msg_pin(&pin_buf, 9, true))
	testing.expect(t, ok && on && id == 9)

	msgs := []Message {
		{id = 1, conv = 2, sender = 3, kind = .Text, text = "pinned", flags = {.Pinned}},
		{id = 4, conv = 2, sender = 3, kind = .Text, flags = {.Deleted}, edited = 99},
	}
	list_buf: [1024]u8
	got_buf: [4]Message
	got, list_ok := decode_message_list(encode_message_list(list_buf[:], msgs), got_buf[:])
	testing.expect(t, list_ok)
	testing.expect_value(t, len(got), 2)
	if len(got) == 2 {
		testing.expect_value(t, got[0].text, "pinned")
		testing.expect_value(t, got[0].flags, Msg_Flags{.Pinned})
		testing.expect_value(t, got[1].edited, Unix_Ms(99))
	}
}

@(test)
test_reactions :: proc(t: ^testing.T) {
	m := Message {
		id     = 1,
		conv   = 2,
		sender = 3,
		kind   = .Text,
		text   = "hi",
	}
	set_reactions(&m, {{"👍", 3, true}, {":party:", 1, false}})
	buf: [MESSAGE_MAX_SIZE]u8
	got, ok := decode_message(encode_message(buf[:], m))
	testing.expect(t, ok)
	rbuf: [MAX_REACTIONS]Reaction
	rs := reactions_of(got, rbuf[:])
	testing.expect_value(t, len(rs), 2)
	if len(rs) == 2 {
		testing.expect_value(t, rs[0], Reaction{"👍", 3, true})
		testing.expect_value(t, rs[1], Reaction{":party:", 1, false})
	}

	// The most a message can carry fits in a record.
	many: [MAX_REACTIONS]Reaction
	for &r in many {
		r = {":abcdefghijklmnopqrstuvwxyz012345:", 999, true}
	}
	m.text = string(make([]u8, MAX_CHAT_SIZE, context.temp_allocator))
	set_reactions(&m, many[:])
	testing.expect(t, encode_message(buf[:], m) != nil)

	react_buf: [MSG_REACT_MAX_SIZE]u8
	id, emoji, on, react_ok := decode_msg_react(encode_msg_react(&react_buf, 5, "🎉", true))
	testing.expect(t, react_ok && id == 5 && emoji == "🎉" && on)
	changed_buf: [REACTION_CHANGED_MAX_SIZE]u8
	c, changed_ok := decode_reaction_changed(
		encode_reaction_changed(&changed_buf, {5, 6, ":party:", 2, 7, false}),
	)
	testing.expect(t, changed_ok)
	testing.expect_value(t, c, Reaction_Change{5, 6, ":party:", 2, 7, false})
}

@(test)
test_reactors_roundtrip :: proc(t: ^testing.T) {
	get_buf: [REACTORS_GET_MAX_SIZE]u8
	id, emoji, ok := decode_reactors_get(encode_reactors_get(&get_buf, 42, ":party:"))
	testing.expect(t, ok)
	testing.expect_value(t, id, Msg_Id(42))
	testing.expect_value(t, emoji, ":party:")
	_, _, ok = decode_reactors_get(encode_reactors_get(&get_buf, 0, ":party:"))
	testing.expect(t, !ok)

	// More accounts than an answer holds: the first MAX_REACTORS.
	many: [MAX_REACTORS + 3]Account_Id
	for &a, i in many {
		a = Account_Id(i + 1)
	}
	buf: [REACTORS_MAX_SIZE]u8
	got: [MAX_REACTORS]Account_Id
	total, accounts, read := decode_reactors(encode_reactors(&buf, 70, many[:]), &got)
	testing.expect(t, read)
	testing.expect_value(t, total, 70)
	testing.expect_value(t, len(accounts), MAX_REACTORS)
	testing.expect_value(t, accounts[MAX_REACTORS - 1], Account_Id(MAX_REACTORS))
}

@(test)
test_attachments_record :: proc(t: ^testing.T) {
	m := Message {
		id               = 5,
		conv             = 2,
		sender           = 3,
		kind             = .Text,
		flags            = {.Has_Attachments},
		text             = "",
		attachment_count = 2,
	}
	m.attachments[0] = {
		blob = 11,
		size = 1 << 33,
		name = "big.iso",
	}
	m.attachments[1] = {
		blob = 12,
		size = 7,
		name = "setup.exe",
	}
	buf: [MESSAGE_MAX_SIZE]u8
	body := encode_message(buf[:], m)
	testing.expect_value(t, len(body), message_size(m))
	got, ok := decode_message(body)
	testing.expect(t, ok)
	testing.expect_value(t, got.attachment_count, 2)
	testing.expect_value(t, got.attachments[0].size, u64(1 << 33))
	testing.expect_value(t, got.attachments[1].name, "setup.exe")
	testing.expect_value(t, got.attachments[1].blob, Blob_Id(12))

	// The most a message can carry fits in MESSAGE_MAX_SIZE.
	name := strings.repeat("n", MAX_FILE_NAME, context.temp_allocator)
	m.text = strings.repeat("t", MAX_CHAT_SIZE, context.temp_allocator)
	m.attachment_count = MAX_ATTACHMENTS
	for &a in m.attachments {
		a = {
			blob = 1,
			size = 1,
			name = name,
		}
	}
	testing.expect(t, encode_message(buf[:], m) != nil)

	// The flag without files, or with too many, isn't a message.
	m.attachment_count = 0
	testing.expect(t, encode_message(buf[:], m) == nil)
	m.attachment_count = 1
	body = encode_message(buf[:], m)
	body[8 + 4 + 4 + 8 + 1 + 1 + 8 + 8 + 2 + MAX_CHAT_SIZE] = MAX_ATTACHMENTS + 1
	_, ok = decode_message(body)
	testing.expect(t, !ok)

	// Posting names the uploads.
	post_buf: [MSG_POST_MAX_SIZE]u8
	p := Msg_Post {
		conv             = 3,
		nonce            = 9,
		kind             = .Text,
		text             = strings.repeat("x", MAX_CHAT_SIZE, context.temp_allocator),
		attachment_count = MAX_ATTACHMENTS,
	}
	for &u, i in p.uploads {
		u = u64(100 + i)
	}
	post := encode_msg_post(post_buf[:], p)
	testing.expect(t, post != nil)
	back, post_ok := decode_msg_post(post)
	testing.expect(t, post_ok)
	testing.expect_value(t, back.attachment_count, MAX_ATTACHMENTS)
	testing.expect_value(t, back.uploads[9], 109)
}

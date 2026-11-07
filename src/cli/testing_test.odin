package main

import "core:strings"

import "client:conn"
import "common:proto"

// Helpers for the tests: a View filled in by hand, and rows as plain text.

// 2023-11-14 22:13:20 UTC, a Tuesday.
T0 :: proto.Unix_Ms(1_700_000_000_000)
MINUTE :: proto.Unix_Ms(60_000)

test_view :: proc() -> conn.View {
	v: conn.View
	conn.view_init(&v)
	v.server = strings.clone("example.org:7777")
	v.status = .Connected
	v.me = 1
	return v
}

add_account :: proc(v: ^conn.View, id: proto.Account_Id, name: string) {
	v.accounts[id] = conn.View_Account {
		username = strings.clone(name),
		display  = strings.clone(name),
	}
}

add_channel :: proc(v: ^conn.View, id: proto.Conv_Id, name: string, unread := 0, mentions := 0) {
	append(
		&v.channels,
		conn.View_Channel{id = id, name = strings.clone(name), unread = unread, mentions = mentions},
	)
}

// timeline_of gives the window of a conversation, made if there was none.
timeline_of :: proc(v: ^conn.View, conv: proto.Conv_Id, root := proto.Msg_Id(0)) -> ^conn.View_Timeline {
	key := conn.Timeline_Key{conv, root}
	if key not_in v.timelines {
		v.timelines[key] = {}
	}
	tl := &v.timelines[key]
	tl.have_oldest, tl.have_newest = true, true
	return tl
}

add_message :: proc(
	v: ^conn.View,
	conv: proto.Conv_Id,
	id: proto.Msg_Id,
	sender: proto.Account_Id,
	time: proto.Unix_Ms,
	text: string,
) -> ^conn.View_Message {
	tl := timeline_of(v, conv)
	append(&tl.messages, conn.View_Message{id = id, sender = sender, time = time, text = strings.clone(text)})
	tl.revision += 1
	return &tl.messages[len(tl.messages) - 1]
}

row_text :: proc(r: Row) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	for s in r.segs {
		strings.write_string(&b, s.text)
	}
	return strings.to_string(b)
}

rows_text :: proc(l: ^Timeline_Layout) -> []string {
	out := make([]string, len(l.rows), context.temp_allocator)
	for r, i in l.rows {
		out[i] = row_text(r)
	}
	return out
}

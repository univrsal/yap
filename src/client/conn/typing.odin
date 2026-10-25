package conn

import "core:time"

import "common:proto"

// Typing notices: the one we send while writing, and the ones that arrive.

// Typing notices are sent at most this often while typing, and are shown for
// TYPING_SHOW after the last one arrives.
TYPING_SEND_INTERVAL :: 3 * time.Second
TYPING_SHOW :: 5 * time.Second

// Reports that we are typing in the conversation we are looking at, or in a
// thread.
Typing_Command :: struct {
	thread: Timeline_Key,
}

// chat_typing tells the conversation we are looking at (or with `thread`, that
// thread) that we are typing, unless we did so recently.
chat_typing :: proc(c: ^Server_Conn, thread := Timeline_Key{}) {
	mc := &c.msgs
	to := thread if thread.root != 0 else Timeline_Key{c.convs.viewing, 0}
	if !c.has_current || to.conv == 0 {
		return
	}
	if mc.typing_to == to &&
	   mc.last_typing != {} &&
	   time.tick_since(mc.last_typing) < TYPING_SEND_INTERVAL {
		return
	}
	mc.last_typing, mc.typing_to = time.tick_now(), to
	buf: [proto.TYPING_UP_SIZE]u8
	send_data(c, proto.encode_typing_up(&buf, to.conv, to.root))
}

handle_typing :: proc(c: ^Server_Conn, pt: []u8) {
	if len(pt) != proto.TYPING_DOWN_SIZE {
		return
	}
	conv, root, account := proto.decode_typing_down(pt)
	if account == c.auth.me || conv not_in c.convs.convs {
		return
	}
	publish_typing(c, {conv, root}, account)
	report_typing(c, conv, root, account)
}

View_Typing :: struct {
	to: Timeline_Key, // where: the conversation, or one of its threads
	at: time.Tick,
}

@(private = "file")
publish_typing :: proc(c: ^Server_Conn, to: Timeline_Key, account: proto.Account_Id) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	v.typing[account] = {to, time.tick_now()}
}

// publish_typing_done clears an account's typing notice once it has posted,
// since it is done typing that message.
publish_typing_done :: proc(c: ^Server_Conn, to: Timeline_Key, account: proto.Account_Id) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	if t, ok := v.typing[account]; ok && t.to == to {
		delete_key(&v.typing, account)
	}
}

// is_typing reports whether an account recently told us that it is typing in a
// conversation (or with `root`, in that thread of it). Call with the mutex
// held.
is_typing :: proc(
	v: ^View,
	account: proto.Account_Id,
	conv: proto.Conv_Id,
	root: proto.Msg_Id = 0,
) -> bool {
	t, ok := v.typing[account]
	return ok && t.to == {conv, root} && time.tick_since(t.at) < TYPING_SHOW
}

// typing_until returns when the first typing notice that is still shown will
// disappear, unless another one arrives; zero if none is shown. Call with the
// mutex held.
typing_until :: proc(v: ^View) -> (until: time.Tick) {
	for _, t in v.typing {
		if time.tick_since(t.at) < TYPING_SHOW {
			end := time.tick_add(t.at, TYPING_SHOW)
			if until == {} || time.tick_diff(end, until) > 0 {
				until = end
			}
		}
	}
	return
}

// is_typing_in_thread reports whether an account recently told us that it is
// typing in one of a conversation's threads. Call with the mutex held.
is_typing_in_thread :: proc(v: ^View, account: proto.Account_Id, conv: proto.Conv_Id) -> bool {
	t, ok := v.typing[account]
	return ok && t.to.conv == conv && t.to.root != 0 && time.tick_since(t.at) < TYPING_SHOW
}

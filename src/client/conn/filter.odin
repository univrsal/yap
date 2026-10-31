package conn

import "common:proto"

// A script's say over what an incoming message looks like on this client
// (client/script, docs/design/scripting.md). The hook is called on the network
// thread, for each message as it is turned into what the UI shows: when it
// arrives, in a page of history, in a thread, when it is edited. Only the
// display changes; the server and the other clients are not told.
//
// Messages of our own, files, system messages and deleted messages are not
// offered. A message that is hidden is shown as HIDDEN_TEXT (the window of
// messages is by id, so it has to stay), and makes no sound and no
// notification.

HIDDEN_TEXT :: "[hidden by a script]"

Filter_Result :: struct {
	hide: bool,
	// What to show instead of the text, if `replaced`. In the temp allocator.
	text:     string,
	replaced: bool,
}

Message_Filter :: struct {
	data:     rawptr,
	// Looks at a message (its strings are in the temp allocator). It must be quick:
	// the network loop is waiting.
	incoming: proc(data: rawptr, c: ^Server_Conn, info: Event_Message) -> Filter_Result,
}

// filter_message returns `m` as it is to be shown. Its text is in the temp
// allocator, and msg_of copies it.
filter_message :: proc(c: ^Server_Conn, m: proto.Message) -> (out: proto.Message, hidden: bool) {
	out = m
	f := c.filter
	if f == nil ||
	   f.incoming == nil ||
	   m.sender == c.auth.me ||
	   m.kind != .Text ||
	   .Deleted in m.flags {
		return
	}
	r := f.incoming(f.data, c, message_info(c, m))
	switch {
	case r.hide:
		out.text, hidden = HIDDEN_TEXT, true
	case r.replaced:
		out.text = r.text[:min(len(r.text), proto.MAX_CHAT_SIZE)]
	}
	return
}

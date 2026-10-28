package server

import "core:log"
import "core:strings"

import "common:proto"

// System messages about channels and the server (proto.Conv_System). yap posts
// them as things happen, so that a channel's history says who joined, left,
// was added or taken out, and how the channel changed, the same way that
// Mattermost's history does once it is imported. They count as neither unread
// nor mentions (Msg_Unread and the digest leave them out, as the clients do)
// and notify nobody.
//
// Not posted: joining and leaving the home channel, which everyone is in, and
// joining the default channels that a new account is put in. A new account
// (but not a bot) instead says that it joined the server, in the home channel,
// once it is visible to everyone (verify.odin). A deleted one says that it left.

#assert(proto.CONV_SYSTEM_FIRST == 16) // COUNTS_UNREAD in db.odin says 16

// system_post posts a system message to a conversation's members: `what` was
// done by `sender` (to `arg`, an account, if it is about one), and `text` is
// what changed (see system_change_text).
system_post :: proc(
	s: ^Server,
	conv: ^Conv,
	sender: proto.Account_Id,
	what: proto.Conv_System,
	arg: proto.Account_Id = 0,
	text := "",
) {
	m := proto.Message {
		conv       = conv.id,
		sender     = sender,
		kind       = .System,
		system     = u8(what),
		system_arg = u32(arg),
		text       = text,
	}
	if !msg_store(s, conv, &m, 0) {
		log.errorf("could not store a system message (%v) in %q", what, conv.name)
		return
	}
	msg_deliver(s, conv, m)
}

// system_change_text is the text of a system message about a change from `old`
// to `new`, which are a line each (names and topics have no line breaks).
system_change_text :: proc(old, new: string) -> string {
	return strings.concatenate({old, "\n", new}, context.temp_allocator)
}

// account_joined says in the home channel that an account has joined the
// server. Bots don't.
account_joined :: proc(s: ^Server, acc: ^Account) {
	if .Bot not_in acc.flags && s.convs.home != nil {
		system_post(s, s.convs.home, acc.id, .Joined_Server)
	}
}

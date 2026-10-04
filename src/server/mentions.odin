package server

import "core:log"
import "core:slice"
import "core:strings"

import "common:proto"

/*
Mentions (src/common/proto/mentions.odin): who a message names with its
tokens, recorded so it counts as a mention for them (Conv.mentions,
Read_Changed).

A token counts for an account that exists, isn't the poster, and may
read the message: a member of the conversation. In a public channel an
account that isn't subscribed is subscribed by being mentioned (D19), and
told of the channel. <@everyone> is every other member, from an account
with Mention_Everyone; from anyone else it's kept as the plain text
"@everyone". Other tokens are kept as they were written, and count for
nobody.

The rows are written when a message is posted, written again when it's
edited, and go when it's deleted. A member whose count that changes, by
an edit or a deletion, is told (Read_Changed); a new message is counted
by the clients themselves.
*/

/*
mentions_resolve is who `text`, by `u` in `conv`, mentions, and the text
as it's to be kept. Somebody it subscribes has read up to `read_upto`
(for a new message: what was there before it).
*/
mentions_resolve :: proc(
	s: ^Server,
	u: ^Conn,
	conv: ^Conv,
	text: string,
	read_upto: proto.Msg_Id,
) -> (
	kept: string,
	accounts: []proto.Account_Id,
) {
	kept = text
	list := make([dynamic]proto.Account_Id, context.temp_allocator)
	add :: proc(list: ^[dynamic]proto.Account_Id, a: proto.Account_Id) {
		if !slice.contains(list[:], a) {
			append(list, a)
		}
	}
	sender := u.account.id
	everyone := false
	at := 0
	for {
		m, ok := proto.next_mention(kept, at)
		if !ok {
			break
		}
		at = m.end
		if m.everyone {
			if !can(u.account, .Mention_Everyone) {
				// Not ours to use: it says what was meant, and nothing more.
				kept = strings.concatenate(
					{kept[:m.start], "@", proto.MENTION_EVERYONE, kept[m.end:]},
					context.temp_allocator,
				)
				at = m.start + 1 + len(proto.MENTION_EVERYONE)
				continue
			}
			everyone = true
			continue
		}
		acc := account_by_id(&s.accounts, m.account)
		if acc == nil || acc.id == sender {
			continue
		}
		if !conv_is_member(conv, acc.id) {
			// A public channel takes in whoever is mentioned there; nothing
			// else does.
			if conv.kind != .Channel || .Private in conv.flags {
				continue
			}
			if !conv_member_add(&s.convs, conv, acc.id, read_upto) {
				continue
			}
			log.infof("%s was subscribed to %q by a mention", acc.username, conv.name)
			send_conv_to_account(s, acc.id, conv)
		}
		add(&list, acc.id)
	}
	if everyone {
		for member in conv.members {
			if member != sender {
				add(&list, member)
			}
		}
	}
	return kept, list[:]
}

// mentions_store records who message `id` mentions, in place of what was
// recorded for it before. False if the database failed.
mentions_store :: proc(
	s: ^Server,
	conv: ^Conv,
	id: proto.Msg_Id,
	accounts: []proto.Account_Id,
) -> bool {
	mentions_clear(s, id) or_return
	for a in accounts {
		q := db_stmt(&s.db, .Mention_Add)
		db_bind_int(q, 1, i64(a))
		db_bind_int(q, 2, i64(conv.id))
		db_bind_int(q, 3, i64(id))
		db_run(&s.db, q) or_return
	}
	return true
}

mentions_clear :: proc(s: ^Server, id: proto.Msg_Id) -> bool {
	q := db_stmt(&s.db, .Mention_Clear)
	db_bind_int(q, 1, i64(id))
	return db_run(&s.db, q)
}

// mentioned_in is who message `id` is recorded as mentioning, in the temp
// allocator.
mentioned_in :: proc(s: ^Server, id: proto.Msg_Id) -> []proto.Account_Id {
	list := make([dynamic]proto.Account_Id, context.temp_allocator)
	q := db_stmt(&s.db, .Mentioned_In)
	db_bind_int(q, 1, i64(id))
	for {
		row, ok := db_step(&s.db, q)
		if !ok || !row {
			break
		}
		append(&list, proto.Account_Id(db_col_int(q, 0)))
	}
	return list[:]
}

// mentions_changed tells the members among `accounts`, for whom message
// `id` of `conv` stopped or started being a mention, what that does to
// their counts: if they haven't read it yet, it does something.
mentions_changed :: proc(s: ^Server, conv: ^Conv, id: proto.Msg_Id, accounts: []proto.Account_Id) {
	for a in accounts {
		m, member := conv.reads[a]
		acc := account_by_id(&s.accounts, a)
		if member && acc != nil && m.read < id {
			send_read(s, acc, conv)
		}
	}
}

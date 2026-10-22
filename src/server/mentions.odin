package server

import "core:log"
import "core:slice"
import "core:strings"

import "common:proto"

// Mentions (see src/common/proto/mentions.odin) are tokens in a message
// text that name an account. They are recorded so that the message counts as
// a mention for that account (Conv.mentions, Read_Changed).
//
// A token counts for an account that exists, isn't the poster and may read
// the message, i.e. is a member of the conversation. In a public channel,
// an account that isn't subscribed gets subscribed when it is mentioned
// (D19) and is told about the channel. <@everyone> mentions every other
// member if the poster has the Mention_Everyone permission. Otherwise it is
// kept as the plain text "@everyone". A role's token mentions every other
// member who has the role, if the role is Mentionable. Otherwise it is kept
// as the plain text "@name". A role mention never subscribes anybody, so
// accounts that aren't members aren't notified. Any other token is kept as
// written and doesn't count as a mention for anybody.
//
// The rows are written when a message is posted, rewritten when it is
// edited and removed when it is deleted. Members whose mention count is
// changed by an edit or a deletion are notified (Read_Changed). A new
// message is counted by the clients themselves.

// mentions_resolve returns the accounts that `text` mentions, where `text`
// was posted by `u` in `conv`, and the text as it should be stored. An
// account that is subscribed by the mention starts out having read up to
// `read_upto` (for a new message that is the last message before it).
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
				// The poster isn't allowed to use it, so keep it as plain text.
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
		if m.role != 0 {
			r := s.accounts.roles[m.role] or_else nil
			if r == nil || r.id == proto.EVERYONE_ROLE {
				continue
			}
			if .Mentionable not_in r.flags {
				kept = strings.concatenate(
					{kept[:m.start], "@", r.name, kept[m.end:]},
					context.temp_allocator,
				)
				at = m.start + 1 + len(r.name)
				continue
			}
			for member in conv.members {
				acc := account_live(&s.accounts, member)
				if acc != nil &&
				   acc.id != sender &&
				   slice.contains(acc.roles[:], r.id) &&
				   conv_reader(conv, acc) {
					add(&list, acc.id)
				}
			}
			continue
		}
		acc := account_live(&s.accounts, m.account)
		if acc == nil || acc.id == sender {
			continue
		}
		if .See not_in conv_rights(conv, acc) {
			// Nobody is told about a channel they may not see.
			continue
		}
		if !conv_is_member(conv, acc.id) {
			// Only public channels subscribe an account that is mentioned there.
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
			if member != sender && conv_reader(conv, account_by_id(&s.accounts, member)) {
				add(&list, member)
			}
		}
	}
	return kept, list[:]
}

// mentions_store records which accounts message `id` mentions, replacing
// what was recorded before. Returns false if the database failed.
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

// mentioned_in returns the accounts that message `id` is recorded as
// mentioning, allocated with the temp allocator.
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

// mentions_changed notifies the members among `accounts`, for whom message
// `id` of `conv` stopped or started being a mention, that their counts
// changed. This only matters if they haven't read the message yet.
mentions_changed :: proc(s: ^Server, conv: ^Conv, id: proto.Msg_Id, accounts: []proto.Account_Id) {
	for a in accounts {
		m, member := conv.reads[a]
		acc := account_by_id(&s.accounts, a)
		if member && acc != nil && m.read < id {
			send_read(s, acc, conv)
		}
	}
}

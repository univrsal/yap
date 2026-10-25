package server

import "core:log"
import "core:strings"

import "common:proto"
import "sqlite"

// Reactions (see src/common/proto/messages.odin) are emojis that an account
// adds to a message. Anyone who may read a message may react to it, either
// with a Unicode emoji (from the table in proto/emoji_table.odin) or with
// one of the server's custom emojis (`:name:`, see emoji.odin). An account
// can use each emoji only once per message, and a message can have at most
// proto.MAX_REACTIONS different emojis. A deleted message has no reactions
// and can't get new ones.
//
// Each change is sent to every connection of every member of the
// conversation as Reaction_Changed, including the new count for that emoji.
// Every message read from the database carries its reactions, and the ones
// made by the account that asked are marked as theirs. The list of accounts
// that used a given emoji is only requested when a client wants to show it,
// one emoji at a time (Reactors_Get).

// attach_reactions stores the reactions of a message in its record, using
// the temp allocator. The reactions made by `asker` are marked as theirs
// (use 0 for no asker).
attach_reactions :: proc(s: ^Server, m: ^proto.Message, asker: proto.Account_Id) {
	if .Deleted in m.flags {
		return
	}
	list := make([dynamic]proto.Reaction, 0, 4, context.temp_allocator)
	q := db_stmt(&s.db, .Reactions_Of)
	db_bind_int(q, 1, i64(m.id))
	db_bind_int(q, 2, i64(asker))
	for {
		row, ok := db_step(&s.db, q)
		if !ok || !row {
			break
		}
		if len(list) == proto.MAX_REACTIONS {
			sqlite.reset(q)
			break
		}
		append(
			&list,
			proto.Reaction {
				db_col_text(q, 0),
				int(db_col_int(q, 1)),
				asker != 0 && db_col_int(q, 2) != 0,
			},
		)
	}
	if len(list) > 0 {
		proto.set_reactions(m, list[:])
	}
}

// reaction_allowed returns whether `emoji` can be used as a reaction on this
// server, i.e. it is either a Unicode emoji or one of the server's custom emojis.
reaction_allowed :: proc(s: ^Server, emoji: string) -> bool {
	if !proto.is_emoji(emoji) {
		return false
	}
	if strings.has_prefix(emoji, ":") {
		return emoji_known(s, emoji[1:len(emoji) - 1])
	}
	return true
}

// reactors_get answers with the accounts that reacted to a message with an
// emoji, earliest first. Anyone who may read the message may ask for this.
reactors_get :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	msg_id, emoji, ok := proto.decode_reactors_get(body)
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	m, found := msg_by_id(s, msg_id)
	conv := conv_by_id(&s.convs, m.conv) if found else nil
	if conv == nil || !conv_reader(conv, u.account) {
		respond(u, id, .Not_Found)
		return
	}
	accounts := make([dynamic]proto.Account_Id, 0, proto.MAX_REACTORS, context.temp_allocator)
	total := 0
	if .Deleted not_in m.flags {
		q := db_stmt(&s.db, .Reactors_Of)
		db_bind_int(q, 1, i64(m.id))
		db_bind_text(q, 2, emoji)
		db_bind_int(q, 3, proto.MAX_REACTORS)
		for {
			row, stepped := db_step(&s.db, q)
			if !stepped {
				respond(u, id, .Internal)
				return
			}
			if !row {
				break
			}
			append(&accounts, proto.Account_Id(db_col_int(q, 0)))
		}
		total = len(accounts)
		if total == proto.MAX_REACTORS {
			q = db_stmt(&s.db, .React_Count)
			db_bind_int(q, 1, i64(m.id))
			db_bind_text(q, 2, emoji)
			if row, stepped := db_step(&s.db, q); stepped && row {
				total = int(db_col_int(q, 0))
				sqlite.reset(q)
			}
		}
	}
	buf: [proto.REACTORS_MAX_SIZE]u8
	respond(u, id, .Ok, proto.encode_reactors(&buf, total, accounts[:]))
}

msg_react :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	msg_id, emoji, on, ok := proto.decode_msg_react(body)
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	m, found := msg_by_id(s, msg_id)
	conv := conv_by_id(&s.convs, m.conv) if found else nil
	if conv == nil || !conv_reader(conv, u.account) || .Deleted in u.account.flags {
		respond(u, id, .Not_Found)
		return
	}
	if .React not_in conv_rights(conv, u.account) {
		respond(u, id, .Denied)
		return
	}
	if .Deleted in m.flags || (on && !reaction_allowed(s, emoji)) {
		respond(u, id, .Invalid)
		return
	}
	count_of :: proc(s: ^Server, stmt: Stmt, id: proto.Msg_Id, emoji: string) -> int {
		q := db_stmt(&s.db, stmt)
		db_bind_int(q, 1, i64(id))
		if stmt == .React_Count {
			db_bind_text(q, 2, emoji)
		}
		row, stepped := db_step(&s.db, q)
		if !stepped || !row {
			return 0
		}
		n := int(db_col_int(q, 0))
		sqlite.reset(q)
		return n
	}
	before := count_of(s, .React_Count, m.id, emoji)
	if on && before == 0 && count_of(s, .React_Kinds, m.id, "") >= proto.MAX_REACTIONS {
		respond(u, id, .Too_Large)
		return
	}
	q := db_stmt(&s.db, .React_Add if on else .React_Remove)
	db_bind_int(q, 1, i64(m.id))
	db_bind_text(q, 2, emoji)
	db_bind_int(q, 3, i64(u.account.id))
	if on {
		db_bind_int(q, 4, unix_ms())
	}
	if !db_run(&s.db, q) {
		respond(u, id, .Internal)
		return
	}
	respond(u, id, .Ok)
	after := count_of(s, .React_Count, m.id, emoji)
	if after == before {
		return // nothing changed, so there is nothing to announce
	}
	log.debugf(
		"%s %s %s on message %d",
		conn_label(u),
		"reacted with" if on else "took back",
		emoji,
		m.id,
	)
	buf: [proto.REACTION_CHANGED_MAX_SIZE]u8
	event := proto.encode_reaction_changed(&buf, {m.id, conv.id, emoji, after, u.account.id, on})
	for member in conv.members {
		if acc := account_by_id(&s.accounts, member); conv_reader(conv, acc) {
			for c in acc.conns {
				send_event(c, .Reaction_Changed, event)
			}
		}
	}
}

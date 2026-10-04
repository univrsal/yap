package server

import "core:log"
import "core:slice"
import "core:strings"

import "common:proto"
import "sqlite"

/*
Conversations (src/common/proto/convs.odin): the channels there are and
who is a member of each, as the database keeps them and as the server
works from them. Like the accounts they're few, and all read into
memory when the server starts.

Channels used to be a list in the config. That list is still read, once:
a database that has no channels yet gets the config's, the first of them
as the home channel, which every account is a member of. After that the
channels are the database's, and made by whoever may (conv_requests.odin).

A direct message is a conversation too, of two accounts, `a` < `b`, both
members for good. There's at most one for each pair (dm_find), made
the first time either of them opens it (dm_add).

This is only where they're kept; what clients ask about them is in
conv_requests.odin.
*/

Conv :: struct {
	id:         proto.Conv_Id,
	kind:       proto.Conv_Kind,
	flags:      proto.Conv_Flags,
	name:       string, // owned
	topic:      string, // owned
	position:   int, // where it goes in a list, before its id
	created:    i64, // Unix milliseconds
	created_by: proto.Account_Id, // 0 for one that came from the config
	last_msg:   proto.Msg_Id, // the newest message, 0 for none (messages.odin)
	// A DM's two accounts, the lower first; 0 for a channel. And whether
	// each has posted there yet, and whether the database has been asked
	// (dm_posted); posting keeps it up to date after that.
	a, b:       proto.Account_Id,
	posted:     [2]bool,
	checked:    [2]bool,
	// The accounts that are members: for a channel, its subscribers. And
	// what each has read of it and wants to hear of it.
	members:    [dynamic]proto.Account_Id,
	reads:      map[proto.Account_Id]Membership,
}

// Membership is what a member has of a conversation of its own.
Membership :: struct {
	read:   proto.Msg_Id, // the newest message it has read
	notify: proto.Notify_Level,
}

Convs :: struct {
	db:    ^DB,
	by_id: map[proto.Conv_Id]^Conv,
	home:  ^Conv,
	// The DMs, by their two accounts, the lower first.
	dms:   map[[2]proto.Account_Id]^Conv,
}

/*
convs_load reads the conversations and their members from the database.
A database without channels gets `seed`, the config's; and every account
that isn't in the home channel is put there, which is how accounts made
before there were channels, or from the command line, come to be in it.
*/
@(require_results)
convs_load :: proc(c: ^Convs, db: ^DB, seed: []string, accounts: ^Accounts) -> bool {
	c.db = db
	q := db_stmt(db, .Conv_All)
	for {
		row, ok := db_step(db, q)
		if !ok {
			return false
		}
		if !row {
			break
		}
		conv := new(Conv)
		conv.id = proto.Conv_Id(db_col_int(q, 0))
		conv.kind = proto.Conv_Kind(db_col_int(q, 1))
		conv.flags = transmute(proto.Conv_Flags)u8(db_col_int(q, 2))
		conv.name = db_col_text(q, 3, context.allocator)
		conv.topic = db_col_text(q, 4, context.allocator)
		conv.position = int(db_col_int(q, 5))
		conv.created = db_col_int(q, 6)
		conv.created_by = proto.Account_Id(db_col_int(q, 7))
		conv.last_msg = proto.Msg_Id(db_col_int(q, 8))
		conv.a = proto.Account_Id(db_col_int(q, 9))
		conv.b = proto.Account_Id(db_col_int(q, 10))
		c.by_id[conv.id] = conv
		if conv.kind == .DM {
			c.dms[{conv.a, conv.b}] = conv
		}
		if .Home in conv.flags {
			c.home = conv
		}
	}

	q = db_stmt(db, .Member_All)
	for {
		row, ok := db_step(db, q)
		if !ok {
			return false
		}
		if !row {
			break
		}
		if conv := c.by_id[proto.Conv_Id(db_col_int(q, 0))] or_else nil; conv != nil {
			account := proto.Account_Id(db_col_int(q, 1))
			append(&conv.members, account)
			conv.reads[account] = {
				read   = proto.Msg_Id(db_col_int(q, 2)),
				notify = proto.Notify_Level(
					clamp(db_col_int(q, 3), 0, i64(max(proto.Notify_Level))),
				),
			}
		}
	}

	if len(c.by_id) == 0 {
		for name, i in seed {
			flags: proto.Conv_Flags = {.Home} if i == 0 else {}
			if conv_add(c, name, "", flags, 0, i) == nil {
				return false
			}
		}
		log.infof("took %d channels over from the config", len(seed))
	}
	if c.home == nil {
		log.error("the database has channels, but none of them is the home channel")
		return false
	}
	for id in accounts.by_id {
		if !conv_member_add(c, c.home, id) {
			return false
		}
	}
	return true
}

convs_destroy :: proc(c: ^Convs) {
	for _, conv in c.by_id {
		delete(conv.name)
		delete(conv.topic)
		delete(conv.members)
		delete(conv.reads)
		free(conv)
	}
	delete(c.by_id)
	delete(c.dms)
	c^ = {}
}

/*
conv_add makes a channel. The name has to be sanitized, not empty and
not another channel's (conv_by_name); nil if the database won't have it.
*/
@(require_results)
conv_add :: proc(
	c: ^Convs,
	name, topic: string,
	flags: proto.Conv_Flags,
	by: proto.Account_Id,
	position := 0,
) -> ^Conv {
	now := unix_ms()
	q := db_stmt(c.db, .Conv_Add)
	db_bind_int(q, 1, i64(proto.Conv_Kind.Channel))
	db_bind_int(q, 2, i64(transmute(u8)flags))
	db_bind_text(q, 3, name)
	db_bind_text(q, 4, topic)
	db_bind_int(q, 5, i64(position))
	db_bind_int(q, 6, now)
	if by != 0 {
		db_bind_int(q, 7, i64(by))
	} else {
		db_bind_null(q, 7)
	}
	if !db_run(c.db, q) {
		return nil
	}
	conv := new(Conv)
	conv.id = proto.Conv_Id(db_last_id(c.db))
	conv.kind = .Channel
	conv.flags = flags
	conv.name = strings.clone(name)
	conv.topic = strings.clone(topic)
	conv.position = position
	conv.created = now
	conv.created_by = by
	c.by_id[conv.id] = conv
	if .Home in flags {
		c.home = conv
	}
	return conv
}

// dm_find is the DM between two accounts, in either order; nil if they
// have none.
dm_find :: proc(c: ^Convs, x, y: proto.Account_Id) -> ^Conv {
	return c.dms[{min(x, y), max(x, y)}] or_else nil
}

/*
dm_add makes the DM between two accounts, opened by `by`, with both of
them members; nil if the database won't have it. There mustn't be one
already (dm_find).
*/
@(require_results)
dm_add :: proc(c: ^Convs, x, y: proto.Account_Id, by: proto.Account_Id) -> ^Conv {
	a, b := min(x, y), max(x, y)
	now := unix_ms()
	q := db_stmt(c.db, .Conv_Add_DM)
	db_bind_int(q, 1, i64(a))
	db_bind_int(q, 2, i64(b))
	db_bind_int(q, 3, now)
	db_bind_int(q, 4, i64(by))
	if !db_run(c.db, q) {
		return nil
	}
	conv := new(Conv)
	conv.id = proto.Conv_Id(db_last_id(c.db))
	conv.kind = .DM
	conv.created = now
	conv.created_by = by
	conv.a, conv.b = a, b
	c.by_id[conv.id] = conv
	c.dms[{a, b}] = conv
	if !conv_member_add(c, conv, a) || !conv_member_add(c, conv, b) {
		return nil
	}
	return conv
}

// dm_other is the account a DM is with, for one of its two.
dm_other :: proc(conv: ^Conv, account: proto.Account_Id) -> proto.Account_Id {
	return conv.b if account == conv.a else conv.a
}

/*
dm_posted is whether `account`, one of a DM's two, has posted in it.
The database is asked once: the query reads the DM's messages until it
finds one of theirs, all of them if there's none, so the answer is kept
either way, and msg_store sets it when they post. One that has posted
stays so, even once a purge has taken their messages.
*/
dm_posted :: proc(c: ^Convs, conv: ^Conv, account: proto.Account_Id) -> bool {
	side := 0 if account == conv.a else 1
	if conv.posted[side] || conv.checked[side] || conv.last_msg == 0 {
		return conv.posted[side]
	}
	q := db_stmt(c.db, .Msg_Posted_In)
	db_bind_int(q, 1, i64(conv.id))
	db_bind_int(q, 2, i64(account))
	row, ok := db_step(c.db, q)
	if row {
		sqlite.reset(q)
		conv.posted[side] = true
	}
	conv.checked[side] = ok
	return conv.posted[side]
}

// conv_shown is whether an account is told of a conversation it's a
// member of: always for a channel; for a DM, once there's a message in
// it, or if it's the one that opened it.
conv_shown :: proc(conv: ^Conv, account: proto.Account_Id) -> bool {
	if .Archived in conv.flags || !conv_is_member(conv, account) {
		return false
	}
	return conv.kind != .DM || conv.last_msg != 0 || conv.created_by == account
}

conv_by_id :: proc(c: ^Convs, id: proto.Conv_Id) -> ^Conv {
	return c.by_id[id] or_else nil
}

// conv_by_name is the channel called `name`, whatever the case; nil if
// there's none (an archived one's name is free).
conv_by_name :: proc(c: ^Convs, name: string) -> ^Conv {
	for _, conv in c.by_id {
		if conv.kind == .Channel &&
		   .Archived not_in conv.flags &&
		   strings.equal_fold(conv.name, name) {
			return conv
		}
	}
	return nil
}

// channel_count is how many channels there are.
channel_count :: proc(c: ^Convs) -> (n: int) {
	for _, conv in c.by_id {
		if conv.kind == .Channel && .Archived not_in conv.flags {
			n += 1
		}
	}
	return
}

conv_is_member :: proc(conv: ^Conv, account: proto.Account_Id) -> bool {
	return slice.contains(conv.members[:], account)
}

// conv_visible is whether an account may know a conversation is there:
// it's a member, or it's a channel anyone may subscribe to.
conv_visible :: proc(conv: ^Conv, account: proto.Account_Id) -> bool {
	if .Archived in conv.flags {
		return false
	}
	return conv_is_member(conv, account) || (conv.kind == .Channel && .Private not_in conv.flags)
}

// conv_member_add makes an account a member; one that is already stays
// one. A new member has read what's there already, up to `read_upto` at
// most: it isn't news to someone who has only just come. False only if
// the database failed.
conv_member_add :: proc(
	c: ^Convs,
	conv: ^Conv,
	account: proto.Account_Id,
	read_upto := max(proto.Msg_Id),
) -> bool {
	if conv_is_member(conv, account) {
		return true
	}
	read := min(conv.last_msg, read_upto)
	q := db_stmt(c.db, .Member_Add)
	db_bind_int(q, 1, i64(conv.id))
	db_bind_int(q, 2, i64(account))
	db_bind_int(q, 3, unix_ms())
	db_bind_int(q, 4, i64(read))
	db_run(c.db, q) or_return
	append(&conv.members, account)
	conv.reads[account] = {
		read = read,
	}
	return true
}

/*
conv_set_read moves what a member has read up to `id`, which can't be
past the conversation's last message. It only moves forward: true if it
did.
*/
conv_set_read :: proc(
	c: ^Convs,
	conv: ^Conv,
	account: proto.Account_Id,
	id: proto.Msg_Id,
) -> bool {
	m, ok := &conv.reads[account]
	upto := min(id, conv.last_msg)
	if !ok || upto <= m.read {
		return false
	}
	q := db_stmt(c.db, .Member_Set_Read)
	db_bind_int(q, 1, i64(conv.id))
	db_bind_int(q, 2, i64(account))
	db_bind_int(q, 3, i64(upto))
	db_run(c.db, q) or_return
	m.read = upto
	return true
}

// conv_set_notify sets how much a conversation may interrupt a member.
conv_set_notify :: proc(
	c: ^Convs,
	conv: ^Conv,
	account: proto.Account_Id,
	notify: proto.Notify_Level,
) -> bool {
	m, ok := &conv.reads[account]
	if !ok {
		return false
	}
	q := db_stmt(c.db, .Member_Set_Notify)
	db_bind_int(q, 1, i64(conv.id))
	db_bind_int(q, 2, i64(account))
	db_bind_int(q, 3, i64(notify))
	db_run(c.db, q) or_return
	m.notify = notify
	return true
}

// conv_unread is how many messages of a conversation after `read` aren't
// `account`'s, up to proto.UNREAD_CAP: the database stops counting
// there, so a conversation not looked at for a year costs no more than
// one read yesterday.
conv_unread :: proc(c: ^Convs, conv: ^Conv, account: proto.Account_Id, read: proto.Msg_Id) -> int {
	if read >= conv.last_msg {
		return 0
	}
	q := db_stmt(c.db, .Msg_Unread)
	db_bind_int(q, 1, i64(conv.id))
	db_bind_int(q, 2, i64(read))
	db_bind_int(q, 3, i64(account))
	row, ok := db_step(c.db, q)
	if !ok || !row {
		return 0
	}
	n := int(db_col_int(q, 0))
	sqlite.reset(q)
	return n
}

// conv_read_state is where a member stands with a conversation.
conv_read_state :: proc(c: ^Convs, conv: ^Conv, account: proto.Account_Id) -> proto.Read_State {
	m := conv.reads[account]
	return {
		conv = conv.id,
		read = m.read,
		unread = conv_unread(c, conv, account, m.read),
		mentions = conv_mentions(c, conv, account, m.read),
	}
}

// conv_mentions is how many messages after `read` mention `account`, up
// to proto.UNREAD_CAP.
conv_mentions :: proc(
	c: ^Convs,
	conv: ^Conv,
	account: proto.Account_Id,
	read: proto.Msg_Id,
) -> int {
	if read >= conv.last_msg {
		return 0
	}
	q := db_stmt(c.db, .Mention_Count)
	db_bind_int(q, 1, i64(account))
	db_bind_int(q, 2, i64(conv.id))
	db_bind_int(q, 3, i64(read))
	row, ok := db_step(c.db, q)
	if !ok || !row {
		return 0
	}
	n := int(db_col_int(q, 0))
	sqlite.reset(q)
	return n
}

// conv_member_remove takes an account out. False if it wasn't in, or
// the database failed.
conv_member_remove :: proc(c: ^Convs, conv: ^Conv, account: proto.Account_Id) -> bool {
	i, found := slice.linear_search(conv.members[:], account)
	if !found {
		return false
	}
	q := db_stmt(c.db, .Member_Remove)
	db_bind_int(q, 1, i64(conv.id))
	db_bind_int(q, 2, i64(account))
	db_run(c.db, q) or_return
	ordered_remove(&conv.members, i)
	delete_key(&conv.reads, account)
	return true
}

// convs_sorted is every conversation in the order a list shows them:
// the home channel, then by position, then as they were made. In the
// temp allocator.
convs_sorted :: proc(c: ^Convs) -> []^Conv {
	list := make([dynamic]^Conv, 0, len(c.by_id), context.temp_allocator)
	for _, conv in c.by_id {
		append(&list, conv)
	}
	slice.sort_by(list[:], proc(a, b: ^Conv) -> bool {
		if (.Home in a.flags) != (.Home in b.flags) {
			return .Home in a.flags
		}
		if a.position != b.position {
			return a.position < b.position
		}
		return a.id < b.id
	})
	return list[:]
}

// conv_record is a conversation as an account is told about it: with,
// for a member, what it has read there.
conv_record :: proc(c: ^Convs, conv: ^Conv, account: proto.Account_Id) -> proto.Conv {
	record := proto.Conv {
		id       = conv.id,
		kind     = conv.kind,
		flags    = conv.flags,
		name     = conv.name,
		topic    = conv.topic,
		member   = conv_is_member(conv, account),
		last     = conv.last_msg,
		a        = conv.a,
		b        = conv.b,
		position = conv.position,
	}
	if record.member {
		state := conv_read_state(c, conv, account)
		m := conv.reads[account]
		record.read, record.unread, record.mentions, record.notify =
			state.read, state.unread, state.mentions, m.notify
	}
	return record
}

// conv_update changes a channel's name (sanitized, not empty, not
// another's), topic and place in the lists.
conv_update :: proc(c: ^Convs, conv: ^Conv, name, topic: string, position: int) -> bool {
	q := db_stmt(c.db, .Conv_Update)
	db_bind_int(q, 1, i64(conv.id))
	db_bind_text(q, 2, name)
	db_bind_text(q, 3, topic)
	db_bind_int(q, 4, i64(position))
	db_run(c.db, q) or_return
	if name != conv.name {
		delete(conv.name)
		conv.name = strings.clone(name)
	}
	if topic != conv.topic {
		delete(conv.topic)
		conv.topic = strings.clone(topic)
	}
	conv.position = position
	return true
}

conv_set_flags :: proc(c: ^Convs, conv: ^Conv, flags: proto.Conv_Flags) -> bool {
	q := db_stmt(c.db, .Conv_Set_Flags)
	db_bind_int(q, 1, i64(conv.id))
	db_bind_int(q, 2, i64(transmute(u8)flags))
	db_run(c.db, q) or_return
	conv.flags = flags
	return true
}

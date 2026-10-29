package server

import "core:log"
import "core:slice"
import "core:strings"

import "common:proto"
import "sqlite"

// Conversations (see src/common/proto/convs.odin): the channels that exist and
// who is a member of each, as the database stores them and as the server works
// with them. Like accounts, they are few, so they are all read into memory when
// the server starts.
//
// Channels used to be a list in the config. That list is still read, but only
// once: a database that has no channels yet gets the config's channels, with
// the first one as the home channel, which every account is a member of. After
// that, the channels belong to the database and are created by whoever is
// allowed to (see conv_requests.odin).
//
// A direct message is also a conversation, between two accounts `a` and `b`
// with a <= b, who both stay members permanently. There is at most one for each
// pair (see dm_find), and it is created the first time either of them opens it
// (see dm_add). In a DM with oneself, a and b are the same account, which is
// its only member.
//
// A group is like a DM between 3 to proto.MAX_GROUP_MEMBERS accounts, which are
// its members and never change, not even when one of them is deleted (see
// account_delete.odin). There is at most one for each set of accounts (see
// group_find), created the first time one of them opens it (see group_add).
//
// This file only keeps track of conversations. What clients ask about them is
// handled in conv_requests.odin.

Conv :: struct {
	id:         proto.Conv_Id,
	kind:       proto.Conv_Kind,
	flags:      proto.Conv_Flags,
	name:       string, // owned
	topic:      string, // owned
	position:   int, // where it goes in a list, ahead of its id
	created:    i64, // Unix milliseconds
	created_by: proto.Account_Id, // 0 for a channel that came from the config
	last_msg:   proto.Msg_Id, // the newest message, or 0 for none (see messages.odin)
	last_time:  proto.Unix_Ms, // when it was posted
	// A DM's two accounts, the lower id first, and 0 for a channel. Also
	// whether each has posted there yet and whether the database has been
	// asked about it (see dm_posted). Posting keeps it up to date after that.
	a, b:       proto.Account_Id,
	posted:     [2]bool,
	checked:    [2]bool,
	// The accounts that are members, which for a channel are its
	// subscribers, and what each of them has read and wants to be notified
	// about.
	members:    [dynamic]proto.Account_Id,
	reads:      map[proto.Account_Id]Membership,
	// A channel's rights map: what each role may do there (see conv_rights).
	// A role that isn't in it has no rights there.
	rights:     map[proto.Role_Id]proto.Conv_Rights,
}

// Membership is the state that each member has for a conversation.
Membership :: struct {
	read:   proto.Msg_Id, // the newest message the member has read
	notify: proto.Notify_Level,
	admin:  bool, // one of a channel's admins
}

Convs :: struct {
	db:     ^DB,
	by_id:  map[proto.Conv_Id]^Conv,
	home:   ^Conv,
	// The DMs, keyed by their two accounts with the lower id first.
	dms:    map[[2]proto.Account_Id]^Conv,
	// The groups, keyed by their members (see group_key).
	groups: map[Group_Key]^Conv,
}

// Group_Key is a group's members in ascending order, followed by zeros.
Group_Key :: [proto.MAX_GROUP_MEMBERS]proto.Account_Id

// group_key returns the key of the group of `accounts`, which may be in any
// order and must be at most proto.MAX_GROUP_MEMBERS.
group_key :: proc(accounts: []proto.Account_Id) -> (key: Group_Key) {
	n := copy(key[:], accounts)
	slice.sort(key[:n])
	return
}

// convs_load reads the conversations and their members from the database.
// A database without channels gets the channels named in `seed` (the server
// passes only the one called DEFAULT_CHANNEL_NAME). Every account that isn't in
// the home channel is added to it, which is how accounts created before
// channels existed, or from the command line, end up in it.
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
		conv.last_time = proto.Unix_Ms(db_col_int(q, 11))
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
				admin  = conv.kind == .Channel && db_col_int(q, 4) != 0,
			}
		}
	}
	for _, conv in c.by_id {
		if conv.kind == .Group && len(conv.members) <= proto.MAX_GROUP_MEMBERS {
			c.groups[group_key(conv.members[:])] = conv
		}
	}

	q = db_stmt(db, .Conv_Rights_All)
	for {
		row, ok := db_step(db, q)
		if !ok {
			return false
		}
		if !row {
			break
		}
		if conv := c.by_id[proto.Conv_Id(db_col_int(q, 0))] or_else nil; conv != nil {
			role := proto.Role_Id(db_col_int(q, 1))
			conv.rights[role] = transmute(proto.Conv_Rights)u16(db_col_int(q, 2))
		}
	}

	if len(c.by_id) == 0 {
		for name, i in seed {
			flags: proto.Conv_Flags = {.Home} if i == 0 else {}
			if conv_add(c, name, "", flags, 0, i) == nil {
				return false
			}
		}
		log.infof("took %d channels from the config", len(seed))
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
		delete(conv.rights)
		free(conv)
	}
	delete(c.by_id)
	delete(c.dms)
	delete(c.groups)
	c^ = {}
}

// conv_add creates a channel. The name has to be sanitized, not empty, and not
// the name of another channel (see conv_by_name). It returns nil if the database
// refuses it.
@(require_results)
conv_add :: proc(
	c: ^Convs,
	name, topic: string,
	flags: proto.Conv_Flags,
	by: proto.Account_Id,
	position := 0,
) -> ^Conv {
	now := unix_ms()
	q := db_query(
		c.db,
		.Conv_Add,
		i64(proto.Conv_Kind.Channel),
		i64(transmute(u8)flags),
		name,
		topic,
		i64(position),
		now,
	)
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
	// Everyone may do everything in a new channel.
	everyone := []proto.Role_Rights{{proto.EVERYONE_ROLE, proto.CONV_RIGHTS_ALL}}
	if !conv_rights_set(c, conv, everyone) {
		return nil
	}
	return conv
}

// account_join_defaults makes a new account a member of the home channel and of
// every Default channel it may see. Unlike the home channel, it may leave those.
account_join_defaults :: proc(c: ^Convs, acc: ^Account) -> bool {
	conv_member_add(c, c.home, acc.id) or_return
	for conv in convs_sorted(c) {
		if conv.kind == .Channel && .Default in conv.flags && .See in conv_rights(conv, acc) {
			conv_member_add(c, conv, acc.id) or_return
		}
	}
	return true
}

// conv_rights_set replaces a channel's rights map, in the database and in
// memory. The roles must exist.
conv_rights_set :: proc(c: ^Convs, conv: ^Conv, entries: []proto.Role_Rights) -> bool {
	q := db_query(c.db, .Conv_Rights_Clear, i64(conv.id))
	db_run(c.db, q) or_return
	clear(&conv.rights)
	for e in entries {
		q = db_query(
			c.db,
			.Conv_Rights_Add,
			i64(conv.id),
			i64(e.role),
			i64(transmute(u16)(e.rights & proto.CONV_RIGHTS_ALL)),
		)
		db_run(c.db, q) or_return
		conv.rights[e.role] = e.rights & proto.CONV_RIGHTS_ALL
	}
	return true
}

// conv_rights_role_gone removes a deleted role from every channel's rights map.
conv_rights_role_gone :: proc(c: ^Convs, role: proto.Role_Id) -> bool {
	db_write(c.db, .Conv_Rights_Drop_Role, i64(role)) or_return
	for _, conv in c.by_id {
		delete_key(&conv.rights, role)
	}
	return true
}

// conv_rights returns what an account may do in a conversation, whether or not
// it is a member (proto.Conv_Right). For a channel these are the rights of the
// account's roles there, and every right for the owner and those with
// Manage_Channels, settled by proto.conv_rights_settle. A private channel gives
// no rights to someone who isn't in it, whoever they are. Both accounts of a DM
// may do everything but Voice, and nobody else anything, and so may the members
// of a group. In the home channel, everyone can always see.
conv_rights :: proc(conv: ^Conv, acc: ^Account) -> proto.Conv_Rights {
	if acc == nil || .Archived in conv.flags {
		return {}
	}
	if conv.kind != .Channel {
		if !conv_is_member(conv, acc.id) {
			return {}
		}
		return proto.conv_rights_default(conv.kind, conv.flags)
	}
	if .Private in conv.flags && !conv_is_member(conv, acc.id) {
		return {}
	}
	return conv_role_rights(conv, acc)
}

// conv_role_rights returns the rights that a channel's map gives an account's
// roles, settled, whether or not it is a member (see conv_rights, which also
// asks that for a private channel).
conv_role_rights :: proc(conv: ^Conv, acc: ^Account) -> proto.Conv_Rights {
	rights: proto.Conv_Rights
	if can(acc, .Manage_Channels) {
		rights = proto.CONV_RIGHTS_ALL
	} else {
		rights = conv.rights[proto.EVERYONE_ROLE] or_else {}
		for role in acc.roles {
			rights += conv.rights[role] or_else {}
		}
	}
	if .Home in conv.flags {
		rights += {.See}
	}
	return proto.conv_rights_settle(rights, conv.flags)
}

// dm_find returns the DM between two accounts, given in either order, or nil if
// they have none.
dm_find :: proc(c: ^Convs, x, y: proto.Account_Id) -> ^Conv {
	return c.dms[{min(x, y), max(x, y)}] or_else nil
}

// dm_add creates the DM between two accounts, opened by `by`, with both of them
// as members. It returns nil if the database refuses it. There must not be a DM
// between them already (see dm_find).
@(require_results)
dm_add :: proc(c: ^Convs, x, y: proto.Account_Id, by: proto.Account_Id) -> ^Conv {
	a, b := min(x, y), max(x, y)
	now := unix_ms()
	if !db_write(c.db, .Conv_Add_DM, i64(a), i64(b), now, i64(by)) {
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

// group_find returns the group of exactly `accounts`, given in any order, or nil
// if there is none.
group_find :: proc(c: ^Convs, accounts: []proto.Account_Id) -> ^Conv {
	if len(accounts) > proto.MAX_GROUP_MEMBERS {
		return nil
	}
	return c.groups[group_key(accounts)] or_else nil
}

// group_add creates the group of `accounts` (3 to proto.MAX_GROUP_MEMBERS of
// them, in any order), opened by `by`, with all of them as members. It returns
// nil if the database refuses it, in which case nothing was created. There must
// not be a group of them already (see group_find).
@(require_results)
group_add :: proc(c: ^Convs, accounts: []proto.Account_Id, by: proto.Account_Id) -> ^Conv {
	now := unix_ms()
	db_begin(c.db)
	if !db_exec(c.db, "SAVEPOINT group_add") {
		return nil
	}
	ok := false
	defer if !ok {
		db_exec(c.db, "ROLLBACK TO group_add")
		db_exec(c.db, "RELEASE group_add")
	}
	if !db_write(c.db, .Conv_Add_Group, now, i64(by)) {
		return nil
	}
	id := proto.Conv_Id(db_last_id(c.db))
	for account in accounts {
		if !db_write(c.db, .Member_Add, i64(id), i64(account), now, 0) {
			return nil
		}
	}
	if !db_exec(c.db, "RELEASE group_add") {
		return nil
	}
	ok = true

	conv := new(Conv)
	conv.id = id
	conv.kind = .Group
	conv.created = now
	conv.created_by = by
	for account in accounts {
		append(&conv.members, account)
		conv.reads[account] = {}
	}
	slice.sort(conv.members[:])
	c.by_id[conv.id] = conv
	c.groups[group_key(accounts)] = conv
	return conv
}

// dm_other returns the other account of a DM, given one of its two accounts.
// In a DM with oneself that is the same account.
dm_other :: proc(conv: ^Conv, account: proto.Account_Id) -> proto.Account_Id {
	return conv.b if account == conv.a else conv.a
}

// dm_posted returns whether `account`, one of a DM's two accounts, has posted in
// it. The database is only asked once: the query reads the DM's messages until
// it finds one from that account (or all of them if there is none), so the
// answer is cached either way, and msg_store updates it when the account posts.
// Once an account has posted, it stays that way even after a purge has removed
// its messages.
dm_posted :: proc(c: ^Convs, conv: ^Conv, account: proto.Account_Id) -> bool {
	side := 0 if account == conv.a else 1
	if conv.posted[side] || conv.checked[side] || conv.last_msg == 0 {
		return conv.posted[side]
	}
	q := db_query(c.db, .Msg_Posted_In, i64(conv.id), i64(account))
	row, ok := db_step(c.db, q)
	if row {
		sqlite.reset(q)
		conv.posted[side] = true
	}
	conv.checked[side] = ok
	return conv.posted[side]
}

// conv_shown returns whether an account is told about a conversation it is a
// member of. This is the case for a channel it may see (see conv_rights). For a
// DM or a group it is the case once it has a message, or if the account is the
// one that opened it.
conv_shown :: proc(conv: ^Conv, acc: ^Account) -> bool {
	if !conv_reader(conv, acc) {
		return false
	}
	return conv.kind == .Channel || conv.last_msg != 0 || conv.created_by == acc.id
}

// conv_reader returns whether an account is a member of a conversation that it
// may see, which is who reads it, is sent what happens there and is notified.
// A member who lost See stays a member, but not a reader, until it gets it back.
conv_reader :: proc(conv: ^Conv, acc: ^Account) -> bool {
	return acc != nil && conv_is_member(conv, acc.id) && .See in conv_rights(conv, acc)
}

conv_by_id :: proc(c: ^Convs, id: proto.Conv_Id) -> ^Conv {
	return c.by_id[id] or_else nil
}

// conv_by_name returns the channel called `name`, ignoring case, or nil if there
// is none. The name of an archived channel is free to use again.
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

// channel_count returns the number of channels that aren't archived.
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

// conv_visible returns whether an account may know that a conversation exists:
// whether it has See there (see conv_rights). That takes being a member for a DM
// or a private channel, and the right roles for a channel that limits who sees
// it.
conv_visible :: proc(conv: ^Conv, acc: ^Account) -> bool {
	return .See in conv_rights(conv, acc)
}

// conv_manageable returns whether an account may manage a channel: rename it,
// delete it, see and remove its members. Besides the channels it may see, those
// who manage channels may manage the private ones they aren't in. Being able to
// manage one doesn't make it possible to read it, join it or talk in it.
conv_manageable :: proc(conv: ^Conv, acc: ^Account) -> bool {
	if conv.kind != .Channel || .Archived in conv.flags {
		return false
	}
	return conv_visible(conv, acc) || can(acc, .Manage_Channels)
}

// conv_member_add makes an account a member, and does nothing if it already is
// one. A new member counts as having read everything that is already there, up
// to `read_upto` at most, because it isn't news to someone who has only just
// joined. It returns false only if the database failed.
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
	db_write(c.db, .Member_Add, i64(conv.id), i64(account), unix_ms(), i64(read)) or_return
	append(&conv.members, account)
	conv.reads[account] = {
		read = read,
	}
	return true
}

// conv_set_read moves a member's read position up to `id`, which can't be past
// the conversation's last message. It only ever moves forward, and returns true
// if it did.
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
	db_write(c.db, .Member_Set_Read, i64(conv.id), i64(account), i64(upto)) or_return
	m.read = upto
	return true
}

// conv_set_notify sets how much notification a conversation may cause for a
// member.
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
	db_write(c.db, .Member_Set_Notify, i64(conv.id), i64(account), i64(notify)) or_return
	m.notify = notify
	return true
}

// conv_set_admin makes a member of a channel one of its admins, or no longer
// one. It returns false if the account isn't a member or the database failed.
conv_set_admin :: proc(c: ^Convs, conv: ^Conv, account: proto.Account_Id, on: bool) -> bool {
	m, ok := &conv.reads[account]
	if !ok || conv.kind != .Channel {
		return false
	}
	db_write(c.db, .Member_Set_Admin, i64(conv.id), i64(account), i64(on)) or_return
	m.admin = on
	return true
}

// conv_admin says whether an account is one of a channel's admins.
conv_admin :: proc(conv: ^Conv, account: proto.Account_Id) -> bool {
	m, ok := conv.reads[account]
	return ok && m.admin
}

// conv_admins returns a channel's admins, allocated with the temp allocator.
conv_admins :: proc(conv: ^Conv) -> []proto.Account_Id {
	list := make([dynamic]proto.Account_Id, context.temp_allocator)
	for a in conv.members {
		if conv_admin(conv, a) {
			append(&list, a)
		}
	}
	return list[:]
}

// conv_unread returns the number of messages in a conversation after `read` that
// aren't from `account`, up to proto.UNREAD_CAP. The database stops counting
// there, so a conversation that wasn't opened for a year costs no more than one
// that was read yesterday.
conv_unread :: proc(c: ^Convs, conv: ^Conv, account: proto.Account_Id, read: proto.Msg_Id) -> int {
	if read >= conv.last_msg {
		return 0
	}
	q := db_query(c.db, .Msg_Unread, i64(conv.id), i64(read), i64(account))
	row, ok := db_step(c.db, q)
	if !ok || !row {
		return 0
	}
	n := int(db_col_int(q, 0))
	sqlite.reset(q)
	return n
}

// conv_read_state returns how far a member has read a conversation and how many
// unread messages and mentions it has.
conv_read_state :: proc(c: ^Convs, conv: ^Conv, account: proto.Account_Id) -> proto.Read_State {
	m := conv.reads[account]
	return {
		conv = conv.id,
		read = m.read,
		unread = conv_unread(c, conv, account, m.read),
		mentions = conv_mentions(c, conv, account, m.read),
	}
}

// conv_mentions returns the number of messages after `read` that mention
// `account`, up to proto.UNREAD_CAP.
conv_mentions :: proc(
	c: ^Convs,
	conv: ^Conv,
	account: proto.Account_Id,
	read: proto.Msg_Id,
) -> int {
	if read >= conv.last_msg {
		return 0
	}
	q := db_query(c.db, .Mention_Count, i64(account), i64(conv.id), i64(read))
	row, ok := db_step(c.db, q)
	if !ok || !row {
		return 0
	}
	n := int(db_col_int(q, 0))
	sqlite.reset(q)
	return n
}

// conv_member_remove removes an account from a conversation. It returns false if
// the account wasn't a member or the database failed.
conv_member_remove :: proc(c: ^Convs, conv: ^Conv, account: proto.Account_Id) -> bool {
	i, found := slice.linear_search(conv.members[:], account)
	if !found {
		return false
	}
	db_write(c.db, .Member_Remove, i64(conv.id), i64(account)) or_return
	ordered_remove(&conv.members, i)
	delete_key(&conv.reads, account)
	return true
}

// convs_sorted returns every conversation in the order a list shows them: the
// home channel first, then by position, then by creation order. The result is
// allocated with the temp allocator.
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

// conv_record returns a conversation as an account is told about it, which for
// a member includes how far it has read.
conv_record :: proc(c: ^Convs, conv: ^Conv, account: proto.Account_Id) -> proto.Conv {
	record := proto.Conv {
		id       = conv.id,
		kind     = conv.kind,
		flags    = conv.flags,
		name     = conv.name,
		topic    = conv.topic,
		member   = conv_is_member(conv, account),
		admin    = conv_admin(conv, account),
		last     = conv.last_msg,
		position = conv.position,
	}
	switch conv.kind {
	case .Channel:
	case .DM:
		proto.conv_set_accounts(&record, {conv.a, conv.b})
	case .Group:
		proto.conv_set_accounts(&record, conv.members[:])
	}
	if conv.last_msg != 0 {
		record.last_time = conv.last_time
	}
	if record.member {
		state := conv_read_state(c, conv, account)
		m := conv.reads[account]
		record.read, record.unread, record.mentions, record.notify =
			state.read, state.unread, state.mentions, m.notify
	}
	return record
}

// conv_update changes a channel's name (which must be sanitized, not empty and
// not the name of another channel), topic and position in the lists.
conv_update :: proc(c: ^Convs, conv: ^Conv, name, topic: string, position: int) -> bool {
	db_write(c.db, .Conv_Update, i64(conv.id), name, topic, i64(position)) or_return
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
	db_write(c.db, .Conv_Set_Flags, i64(conv.id), i64(transmute(u8)flags)) or_return
	conv.flags = flags
	return true
}

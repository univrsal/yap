package proto

import "core:slice"

// Conversations: the things that messages are posted to. These are channels,
// direct messages between two accounts, and groups of a few accounts.
//
// An account is a member of the conversations it takes part in. For a channel,
// membership is a subscription: the account's channel list consists of the
// channels it has subscribed to plus the server's home channel, which
// everyone is in and nobody can leave.
//
// Reading a channel and talking in its voice room are separate things. A
// channel has a voice room, which a connection joins and leaves independently
// (Voice_Join). The snapshot says which room each connection is in
// (datagrams.odin), and a connection starts out in no room. A Room is 0 for
// none or the channel's id. The top bit is reserved for rooms that don't
// belong to a channel.
//
// Everything here travels as requests and events (rpc.odin):
//
// 	Conv_Create     [name str8][topic str8][private u8][flags u8]  ->  [conv u32]
// 	                `flags` is optional and may have Default and Text_Only
// 	Conv_Update     [conv u32][mask u8][name str8][topic str8][position u32]
// 	                [flags u8]
// 	                changes the fields that the mask names (CONV_UPDATE_*).
// 	                `flags` is only there with CONV_UPDATE_FLAGS, and sets
// 	                Default and Text_Only.
// 	Conv_Rights_Get [conv u32]  ->  rights map
// 	Conv_Rights_Set [conv u32] rights map   replaces a channel's rights map
// 	                (both for Manage_Channels only)
// 	Conv_Delete     [conv u32]   archive a channel, which removes it from every list
// 	Conv_Member_Set [conv u32][account u32][on u8]   add someone to a
// 	                channel (as if they had subscribed), or remove them from
// 	                a private one
// 	Conv_Admin_Set  [conv u32][account u32][on u8]   make a member of a
// 	                channel one of its admins, or no longer one
// 	Conv_Browse     [query str8][offset u16][limit u16]
// 	                ->  [more u8][count u16] conversations: the channels
// 	                that can be subscribed to and whose name or topic
// 	                contains the query (ignoring case; "" matches all), in
// 	                the order that a list shows them. The answer has `limit`
// 	                of them (at most MAX_BROWSE_LIMIT), starting at the
// 	                `offset`th. `more` says whether there are more after
// 	                them. An empty body asks for the first BROWSE_PAGE of
// 	                all channels. An optional [flags u8] may follow:
// 	                BROWSE_ALL (only for Manage_Channels) lists every
// 	                channel instead, including the ones we are in and the
// 	                private ones we aren't (for managing them). A server
// 	                that doesn't know the flags ignores them.
// 	Conv_Subscribe  [conv u32][on u8]
// 	Conv_Members    [conv u32]  ->  [count u16][account u32]...
// 	                [admins u16][account u32]...: the members, and which
// 	                of them are the channel's admins
// 	Voice_Join      [room u32]   0 leaves the room we're in
// 	Mark_Read       [conv u32][id u64]   everything up to and including message `id` is read
// 	Conv_Notify     [conv u32][notify u8]
// 	DM_Open         [account u32]  ->  [conv u32]
// 	Group_Open      [count u8][account u32]...  ->  [conv u32]   the others
//
// 	Conv_Changed    a conversation we're a member of that is new or has changed
// 	Conv_Removed    [conv u32]: we are no longer a member of it
// 	Voice_Moved     [room u32][by u32][name str8]: we were moved to that
// 	                room, or out of ours (room 0): another of our account's
// 	                connections joined a room (by 0), we lost the right to
// 	                be in it (by 0), or a moderator moved us (by: who, and
// 	                the room's name, moderation.odin). Older servers send
// 	                only the room.
// 	Read_Changed    [conv u32][read u64][unread u16][mentions u16]: what
// 	                our account has read there, and therefore what it hasn't
//
// 	conversation  [id u32][kind u8][flags u8][name str8][topic str8]
// 	              [count u8][account u32]...[last message u64][member u8]
// 	              [read u64][unread u16][mentions u16][notify u8]
// 	              [position u32][last time u64][rights u16]
// 	rights map    [count u8]([role u32][rights u16])...
//
// A private channel (flag Private) is only for those who were added to it.
// Nobody else is told about it, can find it or can join its room. An archived
// channel (Archived, set by Conv_Delete) no longer belongs to anyone. New
// accounts are subscribed to a Default channel, but may leave it. A Text_Only
// channel has no voice room.
//
// `member` is 1 if the receiver is a member, plus 2 if it is also one of the
// channel's admins.
//
// A channel's admins are members who manage that one channel (any number of
// them; whoever creates a channel is its first). An admin may add members and
// remove them from a private channel, make other members admins and stop
// being one, and change the channel's name and topic (Conv_Update with only
// CONV_UPDATE_NAME and CONV_UPDATE_TOPIC). Everything else about a channel,
// its position, flags and rights map and archiving it, needs Manage_Channels,
// which also allows all that an admin may do, including making an admin no
// longer one. Leaving a channel ends being its admin. DMs and groups have
// none.
//
// What an account may do in a channel (Conv_Right) is given by the channel's
// rights map: the rights each role has there. An account has the rights of all
// its roles, the everyone role included, and none without See. Edit, Delete
// and Attach also need Write, Speak and Video need Voice, and there is no
// Voice in a Text_Only channel. Whoever is in a voice room without Speak only
// listens; Video is turning on one's camera or sharing one's screen there.
// Someone a moderator moved to a room (moderation.odin) may speak there
// whatever their rights, but not use video without the right.
// Attaching files also takes the Attach_Files permission. The owner and
// those with Manage_Channels have every right everywhere. A new channel's map
// gives everyone every right. Deleting a role removes it from every map.
//
// The `rights` that end a conversation are what the receiver may do there. They
// are only sent with Conv_Changed, never in a list such as a Conv_Browse page,
// and a record without them (from an older server) means every right (see
// conv_rights_default). In a DM both accounts have every right but those of
// voice.
//
// When a connection logs in, it is told about every conversation that its
// account is a member of, between Sync_Begin and Sync_End (accounts.odin).
//
// A conversation's last message is the id of the newest message posted to it
// (messages.odin), or 0 for none. `last time` is the time at which that message
// was posted, in Unix milliseconds (0 for none). It is used to order a list of
// DMs from many servers, because ids from different servers can't be compared.
//
// The accounts in a conversation record are the people a DM or a group is
// between, in ascending order, and none for a channel.
//
// A direct message (DM) is a conversation between two accounts, who both
// remain members permanently. There is one DM for each pair of accounts: DM_Open finds it or creates it and
// answers with its id. Anyone may message anyone. The account that opens the DM
// is told about it (Conv_Changed) immediately. The other account is only told
// once a message is posted there, so a conversation that was opened and left
// empty doesn't show up on its side. Messages, reading and typing work in a DM
// like in a channel. A DM has no voice room and cannot be subscribed to.
//
// An account may also have a DM with itself, for its own notes: DM_Open with
// its own id. Both of the record's accounts are then that account. Nobody else
// is told about it, mentioning someone there notifies nobody, and files can't
// be offered there (attachments can be).
//
// A group is like a DM between 3 to MAX_GROUP_MEMBERS accounts, which never
// change: nobody joins or leaves a group, and a different set of accounts is a
// different group. Group_Open names the others (the asker is one of the
// members) and finds or creates the group of exactly those accounts. As with a
// DM, the opener is told about it at once and the others once a message is
// posted. A group has no name of its own, no voice room and no file offers,
// and bots can't be in one.
//
// What an account has read is tracked per conversation and is the same on all
// its devices. It consists of the newest message it has read (`read`), the
// number of messages since then that are from someone else (`unread`, at most
// UNREAD_CAP) and how many of those mention it (`mentions`, counted from the
// first mention). `read` only moves forward. Posting a message marks
// everything up to that message as read, and subscribing marks everything as
// read. Mark_Read moves it forward, and the account's connections are told
// with Read_Changed. A new message only arrives as itself (Msg_New), and each
// client counts it.
//
// `notify` says how much a conversation may interrupt: for every message, for
// mentions only, or never.

Conv_Id :: distinct u32

// The room that voice goes to: 0 for none, or a channel's Conv_Id.
Room :: distinct u32

Conv_Kind :: enum u8 {
	Channel = 0,
	DM      = 1,
	Group   = 2,
}

// The most accounts in a group, its opener included.
MAX_GROUP_MEMBERS :: 8

Conv_Flag :: enum u8 {
	Home, // the channel that everyone is in
	Private, // only for those who were added to it
	Archived, // deleted as far as anyone can tell
	Default, // new accounts are subscribed to it
	Text_Only, // it has no voice room
}
Conv_Flags :: distinct bit_set[Conv_Flag;u8]

// The flags that Conv_Create and Conv_Update set besides Private.
CONV_SETTABLE_FLAGS :: Conv_Flags{.Default, .Text_Only}

// What an account may do in a channel.
Conv_Right :: enum u8 {
	See, // find it, subscribe, read it, be notified, see who is in its voice room
	Write, // post, reply in threads, forward to it, type
	React, // add and remove one's reactions
	Edit, // edit one's own messages
	Delete, // delete one's own messages
	Voice, // join its voice room
	Attach, // post messages with files, forward such messages to it
	Speak, // be heard in its voice room
	Video, // turn on one's camera or share one's screen in its voice room
}
Conv_Rights :: distinct bit_set[Conv_Right;u16]

CONV_RIGHTS_ALL :: Conv_Rights {
	.See,
	.Write,
	.React,
	.Edit,
	.Delete,
	.Voice,
	.Attach,
	.Speak,
	.Video,
}

// conv_rights_settle applies the rules between rights: nothing without See,
// Edit, Delete and Attach only with Write, Speak and Video only with Voice, and
// no Voice in a Text_Only channel.
conv_rights_settle :: proc(given: Conv_Rights, flags: Conv_Flags) -> Conv_Rights {
	rights := given & CONV_RIGHTS_ALL
	if .See not_in rights {
		return {}
	}
	if .Write not_in rights {
		rights -= {.Edit, .Delete, .Attach}
	}
	if .Text_Only in flags {
		rights -= {.Voice}
	}
	if .Voice not_in rights {
		rights -= {.Speak, .Video}
	}
	return rights
}

// conv_rights_default is what a conversation record that doesn't say means:
// every right there can be.
conv_rights_default :: proc(kind: Conv_Kind, flags: Conv_Flags) -> Conv_Rights {
	rights := CONV_RIGHTS_ALL
	if kind != .Channel {
		rights -= {.Voice, .Speak, .Video}
	}
	return conv_rights_settle(rights, flags)
}

// One role's rights in a channel, an entry of a rights map.
Role_Rights :: struct {
	role:   Role_Id,
	rights: Conv_Rights,
}

// Bytes of UTF-8: a Mattermost channel header, 1024 characters at up to 4 bytes
// each.
MAX_TOPIC_SIZE :: 4 * 1024

// Unread counts stop at this value. A client shows larger counts as "99+".
UNREAD_CAP :: 100

Notify_Level :: enum u8 {
	All      = 0,
	Mentions = 1,
	None     = 2,
}

Conv :: struct {
	id:            Conv_Id,
	kind:          Conv_Kind,
	flags:         Conv_Flags,
	name:          string, // sanitized and never empty for a channel
	topic:         string,
	member:        bool, // whether the receiver of this is a member
	admin:         bool, // ... and one of the channel's admins
	last:          Msg_Id, // the newest message, or 0 for none
	// The following belong to the receiver of this, as a member:
	read:          Msg_Id, // the newest message that it has read
	unread:        int, // messages since then that aren't its own, at most UNREAD_CAP
	mentions:      int, // ... that mention it
	notify:        Notify_Level,
	// Whom a DM or a group is between, in ascending order (none for a
	// channel); see conv_accounts.
	accounts:      [MAX_GROUP_MEMBERS]Account_Id,
	account_count: int,
	// A channel's place in a list: ordered by position, then by id.
	position:      int,
	// The time at which the newest message was posted, or 0 for none.
	last_time:     Unix_Ms,
	// What the receiver may do there (only sent in Conv_Changed).
	rights:        Conv_Rights,
}

CONV_MAX_SIZE ::
	4 +
	1 +
	1 +
	(2 + MAX_CHANNEL_NAME_SIZE) +
	(2 + MAX_TOPIC_SIZE) +
	(1 + 4 * MAX_GROUP_MEMBERS) +
	8 +
	1 +
	8 +
	2 +
	2 +
	1 +
	4 +
	8 +
	2

@(private = "file")
put_conv :: proc(w: ^Writer, c: Conv) {
	put_u32(w, u32(c.id))
	put_u8(w, u8(c.kind))
	put_u8(w, transmute(u8)c.flags)
	put_str16(w, c.name)
	put_str16(w, c.topic)
	count := clamp(c.account_count, 0, MAX_GROUP_MEMBERS)
	put_u8(w, u8(count))
	for i in 0 ..< count {
		put_u32(w, u32(c.accounts[i]))
	}
	put_u64(w, u64(c.last))
	put_u8(w, u8(c.member) | u8(c.member && c.admin) << 1)
	put_u64(w, u64(c.read))
	put_u16(w, u16(clamp(c.unread, 0, UNREAD_CAP)))
	put_u16(w, u16(clamp(c.mentions, 0, UNREAD_CAP)))
	put_u8(w, u8(c.notify))
	put_u32(w, u32(c.position))
	put_u64(w, u64(c.last_time))
}

@(private = "file")
get_conv :: proc(r: ^Reader) -> (c: Conv) {
	c.id = Conv_Id(get_u32(r))
	c.kind = Conv_Kind(get_u8(r))
	c.flags = transmute(Conv_Flags)get_u8(r)
	c.name = get_str16(r)
	c.topic = get_str16(r)
	c.account_count = int(get_u8(r))
	if c.account_count > MAX_GROUP_MEMBERS {
		r.overflow = true
		return
	}
	for &a in c.accounts[:c.account_count] {
		a = Account_Id(get_u32(r))
	}
	c.last = Msg_Id(get_u64(r))
	member := get_u8(r)
	c.member, c.admin = member & 1 != 0, member & 2 != 0
	c.read = Msg_Id(get_u64(r))
	c.unread = int(get_u16(r))
	c.mentions = int(get_u16(r))
	c.notify = Notify_Level(get_u8(r))
	if c.notify > max(Notify_Level) {
		c.notify = .All // a level that is only known to a newer server
	}
	c.position = int(get_u32(r))
	c.last_time = Unix_Ms(get_u64(r))
	return
}

// conv_accounts returns whom a DM or a group is between, which is nobody for a
// channel.
conv_accounts :: proc(c: ^Conv) -> []Account_Id {
	return c.accounts[:clamp(c.account_count, 0, MAX_GROUP_MEMBERS)]
}

// conv_set_accounts sets whom a DM or a group is between, in ascending order. At
// most MAX_GROUP_MEMBERS are kept.
conv_set_accounts :: proc(c: ^Conv, accounts: []Account_Id) {
	c.account_count = min(len(accounts), MAX_GROUP_MEMBERS)
	copy(c.accounts[:], accounts[:c.account_count])
	slice.sort(c.accounts[:c.account_count])
}

// encode_conv writes one conversation as it is sent in Conv_Changed, with the
// receiver's rights. It returns nil if it doesn't fit in `out` (CONV_MAX_SIZE
// is enough for any conversation).
encode_conv :: proc(out: []u8, c: Conv) -> []u8 {
	w := Writer {
		buf = out,
	}
	put_conv(&w, c)
	put_u16(&w, transmute(u16)c.rights)
	return written(&w)
}

// decode_conv reads a conversation. Its strings point into `body`.
decode_conv :: proc(body: []u8) -> (c: Conv, ok: bool) {
	r := Reader {
		buf = body,
	}
	c = get_conv(&r)
	if r.overflow || c.id == 0 {
		return {}, false
	}
	if has_more(&r) {
		c.rights = conv_rights_settle(transmute(Conv_Rights)get_u16(&r), c.flags)
	} else {
		c.rights = conv_rights_default(c.kind, c.flags)
	}
	return c, true
}

// The number of conversations that Conv_Browse answers with at a time.
BROWSE_PAGE :: 50
MAX_BROWSE_LIMIT :: 100
MAX_BROWSE_QUERY :: MAX_CHANNEL_NAME_SIZE
CONV_BROWSE_MAX_SIZE :: 2 + MAX_BROWSE_QUERY + 2 + 2 + 1

// Conv_Browse's flags.
BROWSE_ALL :: 1

Browse :: struct {
	query:  string,
	offset: int,
	limit:  int,
	flags:  u8,
}

encode_conv_browse :: proc(out: ^[CONV_BROWSE_MAX_SIZE]u8, b: Browse) -> []u8 {
	w := Writer {
		buf = out[:],
	}
	put_str16(&w, b.query[:min(len(b.query), MAX_BROWSE_QUERY)])
	put_u16(&w, u16(clamp(b.offset, 0, int(max(u16)))))
	put_u16(&w, u16(clamp(b.limit, 0, MAX_BROWSE_LIMIT)))
	// Left out when there are none, so that the request is the same as before
	// there were flags.
	if b.flags != 0 {
		put_u8(&w, b.flags)
	}
	return out[:w.pos]
}

// decode_conv_browse reads a Conv_Browse request. An empty one asks for the
// first page of all channels.
decode_conv_browse :: proc(body: []u8) -> (b: Browse, ok: bool) {
	if len(body) == 0 {
		return {limit = BROWSE_PAGE}, true
	}
	r := Reader {
		buf = body,
	}
	b.query = get_str16(&r)
	b.offset = int(get_u16(&r))
	b.limit = int(get_u16(&r))
	if r.pos < len(body) {
		b.flags = get_u8(&r)
	}
	if r.overflow ||
	   len(b.query) > MAX_BROWSE_QUERY ||
	   b.limit == 0 ||
	   b.limit > MAX_BROWSE_LIMIT {
		return {}, false
	}
	return b, true
}

// encode_browse_page writes a Conv_Browse response. It consists of whether
// there are more conversations and as many of `convs` as fit in `out`. If not
// all of them fit, there are more.
encode_browse_page :: proc(out: []u8, more: bool, convs: []Conv) -> []u8 {
	if len(out) < 1 {
		return nil
	}
	list := encode_conv_list(out[1:], convs)
	if list == nil {
		return nil
	}
	written := int(list[0]) | int(list[1]) << 8
	out[0] = u8(more || written < len(convs))
	return out[:1 + len(list)]
}

decode_browse_page :: proc(
	body: []u8,
	convs_buf: []Conv,
) -> (
	more: bool,
	convs: []Conv,
	ok: bool,
) {
	if len(body) < 1 {
		return
	}
	convs, ok = decode_conv_list(body[1:], convs_buf)
	return body[0] != 0, convs, ok
}

// encode_conv_list writes a list of conversations with as many of `convs` as
// fit in `out`.
encode_conv_list :: proc(out: []u8, convs: []Conv) -> []u8 {
	w := Writer {
		buf = out,
	}
	put_u16(&w, 0)
	count := 0
	for c in convs {
		if w.pos + CONV_MAX_SIZE > len(out) || count == int(max(u16)) {
			break
		}
		put_conv(&w, c)
		count += 1
	}
	if w.overflow {
		return nil
	}
	out[0], out[1] = u8(count), u8(count >> 8)
	return out[:w.pos]
}

// decode_conv_list reads a list of conversations into `convs_buf`.
decode_conv_list :: proc(body: []u8, convs_buf: []Conv) -> (convs: []Conv, ok: bool) {
	r := Reader {
		buf = body,
	}
	count := int(get_u16(&r))
	if r.overflow || count > len(convs_buf) {
		return
	}
	for &c in convs_buf[:count] {
		c = get_conv(&r)
		c.rights = conv_rights_default(c.kind, c.flags)
	}
	if r.overflow {
		return
	}
	return convs_buf[:count], true
}

CONV_CREATE_MAX_SIZE :: (2 + MAX_CHANNEL_NAME_SIZE) + (2 + MAX_TOPIC_SIZE) + 1 + 1

// encode_conv_create writes a Conv_Create request. `flags` may have Default
// and Text_Only, and is left out when it has neither, so that an older server
// understands it.
encode_conv_create :: proc(
	out: []u8,
	name, topic: string,
	private: bool,
	flags := Conv_Flags{},
) -> []u8 {
	w := Writer {
		buf = out,
	}
	put_str16(&w, name)
	put_str16(&w, topic)
	put_u8(&w, u8(private))
	if flags & CONV_SETTABLE_FLAGS != {} {
		put_u8(&w, transmute(u8)(flags & CONV_SETTABLE_FLAGS))
	}
	return written(&w)
}

// decode_conv_create reads a Conv_Create request. `flags` has Private if the
// channel is to be private, and whichever of CONV_SETTABLE_FLAGS were asked for.
decode_conv_create :: proc(body: []u8) -> (name, topic: string, flags: Conv_Flags, ok: bool) {
	r := Reader {
		buf = body,
	}
	name = get_str16(&r)
	topic = get_str16(&r)
	if get_u8(&r) != 0 {
		flags += {.Private}
	}
	if has_more(&r) {
		flags += transmute(Conv_Flags)get_u8(&r) & CONV_SETTABLE_FLAGS
	}
	return name, topic, flags, !r.overflow
}

// A body that consists of one conversation's id, such as Conv_Members,
// Conv_Removed and the response to Conv_Create.
encode_conv_id :: proc(out: ^[4]u8, conv: Conv_Id) -> []u8 {
	return id_put(out[:], conv)
}

decode_conv_id :: proc(body: []u8) -> (conv: Conv_Id, ok: bool) {
	return id_get(Conv_Id, body)
}

// A body that consists of a room, such as Voice_Join.
encode_room :: proc(out: ^[4]u8, room: Room) -> []u8 {
	return id_put(out[:], room)
}

decode_room :: proc(body: []u8) -> (room: Room, ok: bool) {
	return id_get(Room, body)
}

CONV_SUBSCRIBE_SIZE :: 4 + 1

encode_conv_subscribe :: proc(out: ^[CONV_SUBSCRIBE_SIZE]u8, conv: Conv_Id, on: bool) -> []u8 {
	w := Writer {
		buf = out[:],
	}
	put_u32(&w, u32(conv))
	put_u8(&w, u8(on))
	return out[:]
}

decode_conv_subscribe :: proc(body: []u8) -> (conv: Conv_Id, on: bool, ok: bool) {
	r := Reader {
		buf = body,
	}
	conv = Conv_Id(get_u32(&r))
	on = get_u8(&r) != 0
	return conv, on, !r.overflow
}

GROUP_OPEN_MAX_SIZE :: 1 + 4 * (MAX_GROUP_MEMBERS - 1)

// encode_group_open writes a Group_Open request for the group of the asker and
// `others`. It returns nil for fewer than 2 or more than MAX_GROUP_MEMBERS - 1
// others.
encode_group_open :: proc(out: ^[GROUP_OPEN_MAX_SIZE]u8, others: []Account_Id) -> []u8 {
	if len(others) < 2 || len(others) > MAX_GROUP_MEMBERS - 1 {
		return nil
	}
	w := Writer {
		buf = out[:],
	}
	put_u8(&w, u8(len(others)))
	for a in others {
		put_u32(&w, u32(a))
	}
	return written(&w)
}

// decode_group_open reads a Group_Open request into `buf`. It accepts 2 to
// MAX_GROUP_MEMBERS - 1 accounts, none of them 0 and none twice; whether the
// asker is among them is for the server to see.
decode_group_open :: proc(
	body: []u8,
	buf: ^[MAX_GROUP_MEMBERS - 1]Account_Id,
) -> (
	others: []Account_Id,
	ok: bool,
) {
	r := Reader {
		buf = body,
	}
	count := int(get_u8(&r))
	if r.overflow || count < 2 || count > len(buf) {
		return
	}
	for &a in buf[:count] {
		a = Account_Id(get_u32(&r))
	}
	if r.overflow || r.pos != len(body) {
		return
	}
	others = buf[:count]
	for a, i in others {
		if a == 0 || slice.contains(others[:i], a) {
			return nil, false
		}
	}
	return others, true
}

// encode_conv_members writes a Conv_Members response with as many of
// `accounts` as fit in `out`, followed by the `admins` among them if there is
// room for all of them.
encode_conv_members :: proc(out: []u8, accounts: []Account_Id, admins: []Account_Id = nil) -> []u8 {
	w := Writer {
		buf = out,
	}
	count := min(len(accounts), (len(out) - 2) / 4, int(max(u16)))
	put_u16(&w, u16(count))
	for a in accounts[:count] {
		put_u32(&w, u32(a))
	}
	if len(out) - w.pos >= 2 + len(admins) * 4 && len(admins) <= int(max(u16)) {
		put_u16(&w, u16(len(admins)))
		for a in admins {
			put_u32(&w, u32(a))
		}
	}
	return written(&w)
}

// decode_conv_admins reads which members a Conv_Members response says are
// the channel's admins (none if it doesn't say).
decode_conv_admins :: proc(body: []u8, buf: []Account_Id) -> (admins: []Account_Id, ok: bool) {
	r := Reader {
		buf = body,
	}
	count := int(get_u16(&r))
	if r.overflow || len(body) < 2 + count * 4 {
		return
	}
	r.pos = 2 + count * 4
	if r.pos == len(body) {
		return buf[:0], true
	}
	n := int(get_u16(&r))
	if r.overflow || n > len(buf) {
		return
	}
	for &a in buf[:n] {
		a = Account_Id(get_u32(&r))
	}
	if r.overflow {
		return
	}
	return buf[:n], true
}

decode_conv_members :: proc(
	body: []u8,
	accounts_buf: []Account_Id,
) -> (
	accounts: []Account_Id,
	ok: bool,
) {
	r := Reader {
		buf = body,
	}
	count := int(get_u16(&r))
	if r.overflow || count > len(accounts_buf) {
		return
	}
	for &a in accounts_buf[:count] {
		a = Account_Id(get_u32(&r))
	}
	if r.overflow {
		return
	}
	return accounts_buf[:count], true
}

MARK_READ_SIZE :: 4 + 8
CONV_NOTIFY_SIZE :: 4 + 1
READ_CHANGED_SIZE :: 4 + 8 + 2 + 2

encode_mark_read :: proc(out: ^[MARK_READ_SIZE]u8, conv: Conv_Id, id: Msg_Id) -> []u8 {
	w := Writer {
		buf = out[:],
	}
	put_u32(&w, u32(conv))
	put_u64(&w, u64(id))
	return out[:]
}

decode_mark_read :: proc(body: []u8) -> (conv: Conv_Id, id: Msg_Id, ok: bool) {
	if len(body) != MARK_READ_SIZE {
		return
	}
	r := Reader {
		buf = body,
	}
	conv = Conv_Id(get_u32(&r))
	id = Msg_Id(get_u64(&r))
	return conv, id, true
}

encode_conv_notify :: proc(
	out: ^[CONV_NOTIFY_SIZE]u8,
	conv: Conv_Id,
	notify: Notify_Level,
) -> []u8 {
	w := Writer {
		buf = out[:],
	}
	put_u32(&w, u32(conv))
	put_u8(&w, u8(notify))
	return out[:]
}

decode_conv_notify :: proc(body: []u8) -> (conv: Conv_Id, notify: Notify_Level, ok: bool) {
	if len(body) != CONV_NOTIFY_SIZE || body[4] > u8(max(Notify_Level)) {
		return
	}
	r := Reader {
		buf = body,
	}
	conv = Conv_Id(get_u32(&r))
	notify = Notify_Level(get_u8(&r))
	return conv, notify, true
}

Read_State :: struct {
	conv:     Conv_Id,
	read:     Msg_Id,
	unread:   int,
	mentions: int,
}

encode_read_changed :: proc(out: ^[READ_CHANGED_SIZE]u8, s: Read_State) -> []u8 {
	w := Writer {
		buf = out[:],
	}
	put_u32(&w, u32(s.conv))
	put_u64(&w, u64(s.read))
	put_u16(&w, u16(clamp(s.unread, 0, UNREAD_CAP)))
	put_u16(&w, u16(clamp(s.mentions, 0, UNREAD_CAP)))
	return out[:]
}

decode_read_changed :: proc(body: []u8) -> (s: Read_State, ok: bool) {
	if len(body) != READ_CHANGED_SIZE {
		return
	}
	r := Reader {
		buf = body,
	}
	s = {
		conv     = Conv_Id(get_u32(&r)),
		read     = Msg_Id(get_u64(&r)),
		unread   = int(get_u16(&r)),
		mentions = int(get_u16(&r)),
	}
	return s, true
}

// The bits of Conv_Update's mask.
CONV_UPDATE_NAME :: 1 << 0
CONV_UPDATE_TOPIC :: 1 << 1
CONV_UPDATE_POSITION :: 1 << 2
CONV_UPDATE_FLAGS :: 1 << 3
CONV_UPDATE_ALL :: CONV_UPDATE_NAME | CONV_UPDATE_TOPIC | CONV_UPDATE_POSITION | CONV_UPDATE_FLAGS

Conv_Update :: struct {
	conv:     Conv_Id,
	mask:     u8,
	name:     string,
	topic:    string,
	position: int,
	flags:    Conv_Flags, // with CONV_UPDATE_FLAGS: which of CONV_SETTABLE_FLAGS it has
}

CONV_UPDATE_MAX_SIZE :: 4 + 1 + (2 + MAX_CHANNEL_NAME_SIZE) + (2 + MAX_TOPIC_SIZE) + 4 + 1

encode_conv_update :: proc(out: []u8, u: Conv_Update) -> []u8 {
	w := Writer {
		buf = out,
	}
	put_u32(&w, u32(u.conv))
	put_u8(&w, u.mask)
	put_str16(&w, u.name)
	put_str16(&w, u.topic)
	put_u32(&w, u32(u.position))
	if u.mask & CONV_UPDATE_FLAGS != 0 {
		put_u8(&w, transmute(u8)(u.flags & CONV_SETTABLE_FLAGS))
	}
	return written(&w)
}

decode_conv_update :: proc(body: []u8) -> (u: Conv_Update, ok: bool) {
	r := Reader {
		buf = body,
	}
	u.conv = Conv_Id(get_u32(&r))
	u.mask = get_u8(&r)
	u.name = get_str16(&r)
	u.topic = get_str16(&r)
	u.position = int(get_u32(&r))
	if u.mask & CONV_UPDATE_FLAGS != 0 {
		u.flags = transmute(Conv_Flags)get_u8(&r) & CONV_SETTABLE_FLAGS
	}
	return u, !r.overflow && u.mask & ~u8(CONV_UPDATE_ALL) == 0
}

CONV_MEMBER_SET_SIZE :: 4 + 4 + 1

encode_conv_member_set :: proc(
	out: ^[CONV_MEMBER_SET_SIZE]u8,
	conv: Conv_Id,
	account: Account_Id,
	on: bool,
) -> []u8 {
	w := Writer {
		buf = out[:],
	}
	put_u32(&w, u32(conv))
	put_u32(&w, u32(account))
	put_u8(&w, u8(on))
	return out[:]
}

decode_conv_member_set :: proc(
	body: []u8,
) -> (
	conv: Conv_Id,
	account: Account_Id,
	on: bool,
	ok: bool,
) {
	r := Reader {
		buf = body,
	}
	conv = Conv_Id(get_u32(&r))
	account = Account_Id(get_u32(&r))
	on = get_u8(&r) != 0
	return conv, account, on, !r.overflow
}

// A rights map has at most one entry per role.
RIGHTS_MAP_MAX_SIZE :: 1 + (4 + 2) * MAX_ROLES
CONV_RIGHTS_SET_MAX_SIZE :: 4 + RIGHTS_MAP_MAX_SIZE

@(private = "file")
put_rights_map :: proc(w: ^Writer, entries: []Role_Rights) {
	put_u8(w, u8(min(len(entries), 255)))
	for e in entries {
		put_u32(w, u32(e.role))
		put_u16(w, transmute(u16)(e.rights & CONV_RIGHTS_ALL))
	}
}

@(private = "file")
get_rights_map :: proc(r: ^Reader, buf: []Role_Rights) -> (entries: []Role_Rights, ok: bool) {
	count := int(get_u8(r))
	if r.overflow || count > len(buf) {
		return
	}
	for &e in buf[:count] {
		e.role = Role_Id(get_u32(r))
		e.rights = transmute(Conv_Rights)get_u16(r) & CONV_RIGHTS_ALL
	}
	return buf[:count], !r.overflow
}

// encode_rights_map writes the answer to Conv_Rights_Get.
encode_rights_map :: proc(out: []u8, entries: []Role_Rights) -> []u8 {
	w := Writer {
		buf = out,
	}
	put_rights_map(&w, entries)
	return nil if w.overflow || len(entries) > MAX_ROLES else out[:w.pos]
}

// decode_rights_map reads the answer to Conv_Rights_Get into `buf`.
decode_rights_map :: proc(body: []u8, buf: []Role_Rights) -> (entries: []Role_Rights, ok: bool) {
	r := Reader {
		buf = body,
	}
	entries, ok = get_rights_map(&r, buf)
	return entries, ok && r.pos == len(body)
}

encode_conv_rights_set :: proc(out: []u8, conv: Conv_Id, entries: []Role_Rights) -> []u8 {
	w := Writer {
		buf = out,
	}
	put_u32(&w, u32(conv))
	put_rights_map(&w, entries)
	return nil if w.overflow || len(entries) > MAX_ROLES else out[:w.pos]
}

// decode_conv_rights_set reads a Conv_Rights_Set request. The entries are
// written to `buf`.
decode_conv_rights_set :: proc(
	body: []u8,
	buf: []Role_Rights,
) -> (
	conv: Conv_Id,
	entries: []Role_Rights,
	ok: bool,
) {
	r := Reader {
		buf = body,
	}
	conv = Conv_Id(get_u32(&r))
	entries, ok = get_rights_map(&r, buf)
	return conv, entries, ok && r.pos == len(body)
}

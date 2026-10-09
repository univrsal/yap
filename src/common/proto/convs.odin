package proto

/*
Conversations: what messages are posted to: channels, and direct
messages between two accounts.

An account is a member of the conversations it takes part in. For a
channel that's a subscription: the account's channel list is the
channels it has subscribed to, plus the server's home channel, which
everyone is in and nobody can leave.

Looking at a channel and talking in it are separate things. A channel
has a voice room, which a connection joins and leaves on its own
(Voice_Join); which room each connection is in is part of the snapshot
(messages.odin), and a connection starts out in none. A Room is 0 for
none or the channel's id; the top bit is kept for rooms that aren't a
channel's.

Everything here travels as requests and events (rpc.odin):

	Conv_Create     [name str8][topic str8][private u8]  ->  [conv u32]
	Conv_Update     [conv u32][mask u8][name str8][topic str8][position u32]
	                change what the mask names (CONV_UPDATE_*)
	Conv_Delete     [conv u32]   archive a channel: gone from every list
	Conv_Member_Set [conv u32][account u32][on u8]   add someone to a
	                channel (as if they'd subscribed), or take them out of
	                a private one
	Conv_Browse     [query str8][offset u16][limit u16]
	                ->  [more u8][count u16] conversations: the channels
	                there are to subscribe to whose name or topic has the
	                query in it (ignoring case; "" for all), in the order
	                a list shows them, `limit` of them (at most
	                MAX_BROWSE_LIMIT) from the `offset`th; `more` says
	                there are more after them. An empty body is the first
	                BROWSE_PAGE of all of them.
	Conv_Subscribe  [conv u32][on u8]
	Conv_Members    [conv u32]  ->  [count u16][account u32]...
	Voice_Join      [room u32]   0 leaves the room we're in
	Mark_Read       [conv u32][id u64]   read up to and with message `id`
	Conv_Notify     [conv u32][notify u8]
	DM_Open         [account u32]  ->  [conv u32]

	Conv_Changed    a conversation we're a member of, new or changed
	Conv_Removed    [conv u32]: we aren't a member of it any more
	Voice_Moved     [room u32]: another of our account's connections
	                joined a room, which took this one out of its own
	Read_Changed    [conv u32][read u64][unread u16][mentions u16]: what
	                our account has read there, and so what it hasn't

	conversation  [id u32][kind u8][flags u8][name str8][topic str8]
	              [a u32][b u32][last message u64][member u8]
	              [read u64][unread u16][mentions u16][notify u8]
	              [position u32][last time u64]

A private channel (flag Private) is only for those added to it: nobody
else is told of it, can find it or join its room. An archived one
(Archived, by Conv_Delete) is nobody's any more.

When a connection logs in it's told of every conversation its account
is a member of, between Sync_Begin and Sync_End (accounts.odin).

A conversation's last message is the id of the newest message posted
to it (msgs.odin), 0 for none, and `last time` when it was posted, in
Unix milliseconds (0 for none): what a list of DMs from many servers is
put in order by, as ids from different servers can't be compared.

A direct message (DM) is a conversation of two accounts, `a` and `b`
(a < b), both members for good; for a channel they're 0. There's one
for each pair: DM_Open finds it, or makes it, and answers with its id.
Anyone may message anyone. The account that opens it is told of it
(Conv_Changed) straight away; the other only once a message is posted
there, so a conversation opened and left empty doesn't show on its
side. Everything about messages, reading and typing works on a DM as
on a channel; it has no voice room, and isn't subscribed to.

What an account has read is per conversation, and the same on all its
devices: the newest message it has read (`read`), and from that how
many messages since are someone else's (`unread`, at most UNREAD_CAP)
and how many of those mention it (`mentions`, from when there are
mentions). `read` only moves forward. Posting reads everything up to
the post, and subscribing everything there is. Mark_Read moves it on,
and the account's connections are told with Read_Changed; a new
message only arrives as itself (Msg_New), which each client counts.

`notify` is how much a conversation may interrupt: every message,
mentions only, or nothing.
*/

Conv_Id :: distinct u32

// Where voice goes: 0 for nowhere, or a channel's Conv_Id.
Room :: distinct u32

Conv_Kind :: enum u8 {
	Channel = 0,
	DM      = 1,
}

Conv_Flag :: enum u8 {
	Home, // the channel everyone is in
	Private, // only for those added to it
	Archived, // deleted, as far as anyone can tell
}
Conv_Flags :: distinct bit_set[Conv_Flag;u8]

MAX_TOPIC_SIZE :: 128 // bytes of UTF-8

// Unread counts stop here; a client shows more as "99+".
UNREAD_CAP :: 100

Notify_Level :: enum u8 {
	All      = 0,
	Mentions = 1,
	None     = 2,
}

Conv :: struct {
	id:        Conv_Id,
	kind:      Conv_Kind,
	flags:     Conv_Flags,
	name:      string, // sanitized; never empty for a channel
	topic:     string,
	member:    bool, // whether whoever is told this is one
	last:      Msg_Id, // the newest message, 0 for none
	// Of whoever is told this, as a member:
	read:      Msg_Id, // what it has read up to
	unread:    int, // messages since that aren't its own, at most UNREAD_CAP
	mentions:  int, // ... that mention it
	notify:    Notify_Level,
	// A DM's two accounts, the lower first; 0 for a channel.
	a, b:      Account_Id,
	// Where a channel goes in a list: by position, then by id.
	position:  int,
	// When the newest message was posted, 0 for none.
	last_time: Unix_Ms,
}

CONV_MAX_SIZE ::
	4 +
	1 +
	1 +
	(1 + MAX_CHANNEL_NAME_SIZE) +
	(1 + MAX_TOPIC_SIZE) +
	4 +
	4 +
	8 +
	1 +
	8 +
	2 +
	2 +
	1 +
	4 +
	8

@(private = "file")
put_conv :: proc(w: ^Writer, c: Conv) {
	put_u32(w, u32(c.id))
	put_u8(w, u8(c.kind))
	put_u8(w, transmute(u8)c.flags)
	put_str8(w, c.name)
	put_str8(w, c.topic)
	put_u32(w, u32(c.a))
	put_u32(w, u32(c.b))
	put_u64(w, u64(c.last))
	put_u8(w, u8(c.member))
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
	c.name = get_str8(r)
	c.topic = get_str8(r)
	c.a = Account_Id(get_u32(r))
	c.b = Account_Id(get_u32(r))
	c.last = Msg_Id(get_u64(r))
	c.member = get_u8(r) != 0
	c.read = Msg_Id(get_u64(r))
	c.unread = int(get_u16(r))
	c.mentions = int(get_u16(r))
	c.notify = Notify_Level(get_u8(r))
	if c.notify > max(Notify_Level) {
		c.notify = .All // a level from a newer server
	}
	c.position = int(get_u32(r))
	c.last_time = Unix_Ms(get_u64(r))
	return
}

// encode_conv writes one conversation, as in Conv_Changed; nil if it
// doesn't fit in `out` (CONV_MAX_SIZE holds any).
encode_conv :: proc(out: []u8, c: Conv) -> []u8 {
	w := Writer {
		buf = out,
	}
	put_conv(&w, c)
	return nil if w.overflow else out[:w.pos]
}

// decode_conv reads one; its strings point into `body`.
decode_conv :: proc(body: []u8) -> (c: Conv, ok: bool) {
	r := Reader {
		buf = body,
	}
	c = get_conv(&r)
	if r.overflow || c.id == 0 {
		return {}, false
	}
	return c, true
}

// What Conv_Browse answers with at a time.
BROWSE_PAGE :: 50
MAX_BROWSE_LIMIT :: 100
MAX_BROWSE_QUERY :: MAX_CHANNEL_NAME_SIZE
CONV_BROWSE_MAX_SIZE :: 1 + MAX_BROWSE_QUERY + 2 + 2

Browse :: struct {
	query:  string,
	offset: int,
	limit:  int,
}

encode_conv_browse :: proc(out: ^[CONV_BROWSE_MAX_SIZE]u8, b: Browse) -> []u8 {
	w := Writer {
		buf = out[:],
	}
	put_str8(&w, b.query[:min(len(b.query), MAX_BROWSE_QUERY)])
	put_u16(&w, u16(clamp(b.offset, 0, int(max(u16)))))
	put_u16(&w, u16(clamp(b.limit, 0, MAX_BROWSE_LIMIT)))
	return out[:w.pos]
}

// decode_conv_browse reads a Conv_Browse request; an empty one is the
// first page of everything.
decode_conv_browse :: proc(body: []u8) -> (b: Browse, ok: bool) {
	if len(body) == 0 {
		return {limit = BROWSE_PAGE}, true
	}
	r := Reader {
		buf = body,
	}
	b.query = get_str8(&r)
	b.offset = int(get_u16(&r))
	b.limit = int(get_u16(&r))
	if r.overflow ||
	   len(b.query) > MAX_BROWSE_QUERY ||
	   b.limit == 0 ||
	   b.limit > MAX_BROWSE_LIMIT {
		return {}, false
	}
	return b, true
}

// encode_browse_page writes a Conv_Browse response: whether there are
// more, and as many of `convs` as fit in `out` (and if not all of them
// do, there are more).
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

// encode_conv_list writes a list of conversations: as many of `convs` as
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

// decode_conv_list reads one into `convs_buf`.
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
	}
	if r.overflow {
		return
	}
	return convs_buf[:count], true
}

CONV_CREATE_MAX_SIZE :: (1 + 255) + (1 + 255) + 1

encode_conv_create :: proc(out: []u8, name, topic: string, private: bool) -> []u8 {
	w := Writer {
		buf = out,
	}
	put_str8(&w, name)
	put_str8(&w, topic)
	put_u8(&w, u8(private))
	return nil if w.overflow else out[:w.pos]
}

decode_conv_create :: proc(body: []u8) -> (name, topic: string, private: bool, ok: bool) {
	r := Reader {
		buf = body,
	}
	name = get_str8(&r)
	topic = get_str8(&r)
	private = get_u8(&r) != 0
	return name, topic, private, !r.overflow
}

// A body that is one conversation's id: Conv_Members,
// Conv_Removed, the response to Conv_Create.
encode_conv_id :: proc(out: ^[4]u8, conv: Conv_Id) -> []u8 {
	w := Writer {
		buf = out[:],
	}
	put_u32(&w, u32(conv))
	return out[:]
}

decode_conv_id :: proc(body: []u8) -> (conv: Conv_Id, ok: bool) {
	r := Reader {
		buf = body,
	}
	conv = Conv_Id(get_u32(&r))
	return conv, !r.overflow
}

// A body that is a room: Voice_Join, Voice_Moved.
encode_room :: proc(out: ^[4]u8, room: Room) -> []u8 {
	w := Writer {
		buf = out[:],
	}
	put_u32(&w, u32(room))
	return out[:]
}

decode_room :: proc(body: []u8) -> (room: Room, ok: bool) {
	r := Reader {
		buf = body,
	}
	room = Room(get_u32(&r))
	return room, !r.overflow
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

// encode_conv_members writes a Conv_Members response: as many of
// `accounts` as fit in `out`.
encode_conv_members :: proc(out: []u8, accounts: []Account_Id) -> []u8 {
	w := Writer {
		buf = out,
	}
	count := min(len(accounts), (len(out) - 2) / 4, int(max(u16)))
	put_u16(&w, u16(count))
	for a in accounts[:count] {
		put_u32(&w, u32(a))
	}
	return nil if w.overflow else out[:w.pos]
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

// Conv_Update's mask.
CONV_UPDATE_NAME :: 1 << 0
CONV_UPDATE_TOPIC :: 1 << 1
CONV_UPDATE_POSITION :: 1 << 2
CONV_UPDATE_ALL :: CONV_UPDATE_NAME | CONV_UPDATE_TOPIC | CONV_UPDATE_POSITION

Conv_Update :: struct {
	conv:     Conv_Id,
	mask:     u8,
	name:     string,
	topic:    string,
	position: int,
}

CONV_UPDATE_MAX_SIZE :: 4 + 1 + (1 + 255) + (1 + 255) + 4

encode_conv_update :: proc(out: []u8, u: Conv_Update) -> []u8 {
	w := Writer {
		buf = out,
	}
	put_u32(&w, u32(u.conv))
	put_u8(&w, u.mask)
	put_str8(&w, u.name)
	put_str8(&w, u.topic)
	put_u32(&w, u32(u.position))
	return nil if w.overflow else out[:w.pos]
}

decode_conv_update :: proc(body: []u8) -> (u: Conv_Update, ok: bool) {
	r := Reader {
		buf = body,
	}
	u.conv = Conv_Id(get_u32(&r))
	u.mask = get_u8(&r)
	u.name = get_str8(&r)
	u.topic = get_str8(&r)
	u.position = int(get_u32(&r))
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

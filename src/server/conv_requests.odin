package server

import "core:log"
import "core:strings"

import "common:proto"

/*
What clients ask about conversations and voice rooms
(src/common/proto/convs.odin), and what they're told.

A connection is told of the conversations its account is a member of
when it logs in (directory.odin), and of each change to that after: a
channel subscribed to on one device appears on the account's others.

A connection's voice room is its own, and none until it joins one. An
account is in a room on one connection at a time: joining on a second
takes the first out, and tells it.

A DM is opened with DM_Open, which makes it the first time. The account
that opened it is told of it then; the other one when the first message
is posted (messages.odin), so a DM opened and left empty doesn't show
on its side.
*/

// conv_request handles a request about conversations or rooms; false if
// `op` isn't one.
conv_request :: proc(s: ^Server, u: ^Conn, id: u32, op: proto.Request_Op, body: []u8) -> bool {
	#partial switch op {
	case .Conv_Create:
		conv_create(s, u, id, body)
	case .Conv_Update:
		conv_update_request(s, u, id, body)
	case .Conv_Delete:
		conv_delete(s, u, id, body)
	case .Conv_Member_Set:
		conv_member_set(s, u, id, body)
	case .Conv_Browse:
		conv_browse(s, u, id, body)
	case .Conv_Subscribe:
		conv_subscribe(s, u, id, body)
	case .Conv_Members:
		conv_members(s, u, id, body)
	case .Voice_Join:
		voice_join(s, u, id, body)
	case .Mark_Read:
		mark_read(s, u, id, body)
	case .Conv_Notify:
		conv_notify(s, u, id, body)
	case .DM_Open:
		dm_open(s, u, id, body)
	case:
		return false
	}
	return true
}

// send_conv tells a connection about a conversation, as its account
// sees it.
send_conv :: proc(s: ^Server, u: ^Conn, conv: ^Conv) {
	buf: [proto.CONV_MAX_SIZE]u8
	send_event(
		u,
		.Conv_Changed,
		proto.encode_conv(buf[:], conv_record(&s.convs, conv, u.account.id)),
	)
}

// send_read tells every connection of an account what it has read of a
// conversation.
send_read :: proc(s: ^Server, acc: ^Account, conv: ^Conv) {
	buf: [proto.READ_CHANGED_SIZE]u8
	body := proto.encode_read_changed(&buf, conv_read_state(&s.convs, conv, acc.id))
	for u in acc.conns {
		send_event(u, .Read_Changed, body)
	}
}

// send_convs tells a connection of every conversation its account is
// told of (conv_shown), in the order a list shows them.
send_convs :: proc(s: ^Server, u: ^Conn) {
	for conv in convs_sorted(&s.convs) {
		if conv_shown(conv, u.account.id) {
			send_conv(s, u, conv)
		}
	}
}

// send_conv_to_account tells every connection of an account about a
// conversation.
send_conv_to_account :: proc(s: ^Server, account: proto.Account_Id, conv: ^Conv) {
	if acc := account_by_id(&s.accounts, account); acc != nil {
		for u in acc.conns {
			send_conv(s, u, conv)
		}
	}
}

/*
dm_open answers with the DM between the connection's account and
another, making it if there's none: anyone may message anyone. The
account's connections are told of it before the answer comes, so it's
known by the time the answer is.
*/
@(private = "file")
dm_open :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	other, ok := proto.decode_account_id(body)
	me := u.account.id
	switch {
	case !ok || other == me:
		respond(u, id, .Invalid)
		return
	case account_by_id(&s.accounts, other) == nil:
		respond(u, id, .Not_Found)
		return
	}
	conv := dm_find(&s.convs, me, other)
	if conv == nil {
		conv = dm_add(&s.convs, me, other, me)
		if conv == nil {
			respond(u, id, .Internal)
			return
		}
		log.debugf("%s opened a DM with account %d", conn_label(u), other)
	}
	// A DM the other opened, and nothing's been said in yet, is new
	// to us, as one we've just made is.
	send_conv_to_account(s, me, conv)
	buf: [4]u8
	respond(u, id, .Ok, proto.encode_conv_id(&buf, conv.id))
}

@(private = "file")
conv_create :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	raw_name, raw_topic, private, ok := proto.decode_conv_create(body)
	name_buf: [proto.MAX_CHANNEL_NAME_SIZE]u8
	topic_buf: [proto.MAX_TOPIC_SIZE]u8
	name := proto.sanitize_text(raw_name, name_buf[:])
	topic := proto.sanitize_text(raw_topic, topic_buf[:])
	switch {
	case !can(u.account, .Create_Channels):
		respond(u, id, .Denied)
		return
	case !ok || name == "":
		respond(u, id, .Invalid)
		return
	case conv_by_name(&s.convs, name) != nil:
		respond(u, id, .Conflict)
		return
	case channel_count(&s.convs) >= proto.MAX_CHANNELS:
		respond(u, id, .Too_Large)
		return
	}
	// After the ones there are.
	position := 0
	for _, other in s.convs.by_id {
		position = max(position, other.position + 1)
	}
	conv := conv_add(&s.convs, name, topic, {.Private} if private else {}, u.account.id, position)
	// Whoever makes a channel is in it.
	if conv == nil || !conv_member_add(&s.convs, conv, u.account.id) {
		respond(u, id, .Internal)
		return
	}
	log.infof("%s made the %schannel %q", conn_label(u), "private " if private else "", conv.name)
	buf: [4]u8
	respond(u, id, .Ok, proto.encode_conv_id(&buf, conv.id))
	for other in u.account.conns {
		send_conv(s, other, conv)
	}
}

// The channels an account could subscribe to: those it may see and
// isn't in.
@(private = "file")
/*
conv_browse answers with a page of the channels the connection's account
could subscribe to: those it isn't in, and can see, whose name or topic
has the query in it, ignoring case. The channels are in memory, so
it's a loop over them, however many pages back.
*/
conv_browse :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	b, ok := proto.decode_conv_browse(body)
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	query := strings.to_lower(b.query, context.temp_allocator)
	records := make([dynamic]proto.Conv, 0, b.limit, context.temp_allocator)
	matched := 0
	more := false
	for conv in convs_sorted(&s.convs) {
		if conv.kind != .Channel ||
		   !conv_visible(conv, u.account.id) ||
		   conv_is_member(conv, u.account.id) {
			continue
		}
		if query != "" &&
		   !strings.contains(strings.to_lower(conv.name, context.temp_allocator), query) &&
		   !strings.contains(strings.to_lower(conv.topic, context.temp_allocator), query) {
			continue
		}
		matched += 1
		if matched <= b.offset {
			continue
		}
		if len(records) == b.limit {
			more = true
			break
		}
		append(&records, conv_record(&s.convs, conv, u.account.id))
	}
	out := make([]u8, 1 + 2 + len(records) * proto.CONV_MAX_SIZE, context.temp_allocator)
	respond(u, id, .Ok, proto.encode_browse_page(out, more, records[:]))
}

@(private = "file")
conv_subscribe :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	conv_id, on, ok := proto.decode_conv_subscribe(body)
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	acc := u.account
	conv := conv_by_id(&s.convs, conv_id)
	if conv == nil || conv.kind != .Channel || !conv_visible(conv, acc.id) {
		respond(u, id, .Not_Found)
		return
	}
	if on {
		if !conv_is_member(conv, acc.id) {
			if !conv_member_add(&s.convs, conv, acc.id) {
				respond(u, id, .Internal)
				return
			}
			log.infof("%s subscribed to %q", conn_label(u), conv.name)
			for other in acc.conns {
				send_conv(s, other, conv)
			}
		}
		respond(u, id, .Ok)
		return
	}

	switch {
	case .Home in conv.flags:
		// Everyone is in it, and stays in it.
		respond(u, id, .Denied)
		return
	case conv_is_member(conv, acc.id):
		if !conv_member_remove(&s.convs, conv, acc.id) {
			respond(u, id, .Internal)
			return
		}
		log.infof("%s unsubscribed from %q", conn_label(u), conv.name)
		member_gone(s, conv, acc.id)
	}
	respond(u, id, .Ok)
}

@(private = "file")
conv_members :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	conv_id, ok := proto.decode_conv_id(body)
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	conv := conv_by_id(&s.convs, conv_id)
	if conv == nil || !conv_visible(conv, u.account.id) {
		respond(u, id, .Not_Found)
		return
	}
	out := make([]u8, 2 + len(conv.members) * 4, context.temp_allocator)
	respond(u, id, .Ok, proto.encode_conv_members(out, conv.members[:]))
}

/*
voice_join puts a connection in a channel's voice room, or with room 0
takes it out of the one it's in. Anyone who may see the channel may be
in its room, subscribed or not.
*/
@(private = "file")
voice_join :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	room, ok := proto.decode_room(body)
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	if room != 0 {
		conv := conv_by_id(&s.convs, proto.Conv_Id(room))
		if conv == nil || conv.kind != .Channel || !conv_visible(conv, u.account.id) {
			respond(u, id, .Not_Found)
			return
		}
		// One connection of an account talks at a time: another that was
		// in a room is out of it now, and told where its account went.
		for other in u.account.conns {
			if other != u && other.room != 0 {
				conn_set_room(s, other, 0)
				buf: [4]u8
				send_event(other, .Voice_Moved, proto.encode_room(&buf, room))
			}
		}
	}
	conn_set_room(s, u, room)
	respond(u, id, .Ok)
}

// conn_set_room moves a connection's voice, and lets everyone see it.
conn_set_room :: proc(s: ^Server, u: ^Conn, room: proto.Room) {
	if u.room == room {
		return
	}
	// Out of a call's room, the call is over (calls.odin).
	calls_room_left(s, u, room)
	if proto.room_call(room) != 0 {
		log.infof("%s is in call %d", conn_label(u), proto.room_call(room))
	} else if conv := conv_by_id(&s.convs, proto.Conv_Id(room)); conv != nil {
		log.infof("%s joined the voice of %q", conn_label(u), conv.name)
	} else {
		log.infof("%s left voice", conn_label(u))
	}
	u.room = room
	bump_version(s)
}

// The conversation `conv_id` if the connection's account is a member,
// else why not.
@(private = "file")
member_conv :: proc(s: ^Server, u: ^Conn, conv_id: proto.Conv_Id) -> (^Conv, proto.Status) {
	conv := conv_by_id(&s.convs, conv_id)
	if conv == nil || !conv_visible(conv, u.account.id) {
		return nil, .Not_Found
	}
	if !conv_is_member(conv, u.account.id) {
		return nil, .Denied
	}
	return conv, .Ok
}

/*
mark_read is the account having read a conversation up to a message.
What's read only moves forward, and every connection of the account is
told, so the others stop showing it as unread.
*/
@(private = "file")
mark_read :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	conv_id, msg, ok := proto.decode_mark_read(body)
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	conv, status := member_conv(s, u, conv_id)
	if conv == nil {
		respond(u, id, status)
		return
	}
	respond(u, id, .Ok)
	if conv_set_read(&s.convs, conv, u.account.id, msg) {
		send_read(s, u.account, conv)
	}
}

// conv_notify sets how much a conversation may interrupt the account.
@(private = "file")
conv_notify :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	conv_id, notify, ok := proto.decode_conv_notify(body)
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	conv, status := member_conv(s, u, conv_id)
	if conv == nil {
		respond(u, id, status)
		return
	}
	if !conv_set_notify(&s.convs, conv, u.account.id, notify) {
		respond(u, id, .Internal)
		return
	}
	respond(u, id, .Ok)
	for other in u.account.conns {
		send_conv(s, other, conv)
	}
}

/*
Managing channels (phase 13): renaming one, its topic and place in the
lists (Manage_Channels); archiving one, which is as good as deleting it
(the same); and adding somebody to one, which is as if they had
subscribed (Invite, and being in it), or taking somebody out of a
private one (Manage_Channels).

A private channel's voice room is its members' only: whoever is taken
out of it, or leaves it, is taken out of its room too; and nobody else
is told who is in it (sync_state).
*/

@(private = "file")
conv_update_request :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	up, ok := proto.decode_conv_update(body)
	conv := conv_by_id(&s.convs, up.conv)
	switch {
	case !can(u.account, .Manage_Channels):
		respond(u, id, .Denied)
		return
	case !ok:
		respond(u, id, .Invalid)
		return
	case conv == nil || conv.kind != .Channel || !conv_visible(conv, u.account.id):
		respond(u, id, .Not_Found)
		return
	}
	name, topic, position := conv.name, conv.topic, conv.position
	name_buf: [proto.MAX_CHANNEL_NAME_SIZE]u8
	topic_buf: [proto.MAX_TOPIC_SIZE]u8
	if up.mask & proto.CONV_UPDATE_NAME != 0 {
		name = proto.sanitize_text(up.name, name_buf[:])
		if name == "" {
			respond(u, id, .Invalid)
			return
		}
		if other := conv_by_name(&s.convs, name); other != nil && other != conv {
			respond(u, id, .Conflict)
			return
		}
	}
	if up.mask & proto.CONV_UPDATE_TOPIC != 0 {
		topic = proto.sanitize_text(up.topic, topic_buf[:])
	}
	if up.mask & proto.CONV_UPDATE_POSITION != 0 {
		position = up.position
	}
	if !conv_update(&s.convs, conv, name, topic, position) {
		respond(u, id, .Internal)
		return
	}
	log.infof("%s changed the channel %q", conn_label(u), conv.name)
	respond(u, id, .Ok)
	for m in conv.members {
		send_conv_to_account(s, m, conv)
	}
}

@(private = "file")
conv_delete :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	conv_id, ok := proto.decode_conv_id(body)
	conv := conv_by_id(&s.convs, conv_id)
	switch {
	case !can(u.account, .Manage_Channels):
		respond(u, id, .Denied)
		return
	case !ok:
		respond(u, id, .Invalid)
		return
	case conv == nil || conv.kind != .Channel || !conv_visible(conv, u.account.id):
		respond(u, id, .Not_Found)
		return
	case .Home in conv.flags:
		respond(u, id, .Invalid)
		return
	}
	if !conv_set_flags(&s.convs, conv, conv.flags + {.Archived}) {
		respond(u, id, .Internal)
		return
	}
	log.infof("%s archived the channel %q", conn_label(u), conv.name)
	respond(u, id, .Ok)
	buf: [4]u8
	gone := proto.encode_conv_id(&buf, conv.id)
	for m in conv.members {
		if acc := account_by_id(&s.accounts, m); acc != nil {
			for other in acc.conns {
				send_event(other, .Conv_Removed, gone)
			}
		}
	}
	room_check(s, conv)
}

@(private = "file")
conv_member_set :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	conv_id, account, on, ok := proto.decode_conv_member_set(body)
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	conv := conv_by_id(&s.convs, conv_id)
	target := account_by_id(&s.accounts, account)
	switch {
	case conv == nil || conv.kind != .Channel || !conv_visible(conv, u.account.id):
		respond(u, id, .Not_Found)
		return
	case on && !(can(u.account, .Invite) && conv_is_member(conv, u.account.id)):
		respond(u, id, .Denied)
		return
	case !on && !can(u.account, .Manage_Channels):
		respond(u, id, .Denied)
		return
	case target == nil:
		respond(u, id, .Not_Found)
		return
	case !on && (.Private not_in conv.flags || .Home in conv.flags):
		// Out of a public channel isn't a thing: they'd subscribe again.
		respond(u, id, .Invalid)
		return
	case !on && target != u.account && !outranks(u.account, permissions(target)):
		// Nor out of a private one for someone who may do more.
		respond(u, id, .Denied)
		return
	}
	if on {
		if !conv_is_member(conv, account) {
			// What's there is read: it's no news to someone just come.
			if !conv_member_add(&s.convs, conv, account) {
				respond(u, id, .Internal)
				return
			}
			log.infof("%s added %s to %q", conn_label(u), target.username, conv.name)
			send_conv_to_account(s, account, conv)
			if .Private in conv.flags {
				bump_version(s) // who is in its room is theirs to see now
			}
		}
		respond(u, id, .Ok)
		return
	}
	if conv_is_member(conv, account) {
		if !conv_member_remove(&s.convs, conv, account) {
			respond(u, id, .Internal)
			return
		}
		log.infof("%s took %s out of %q", conn_label(u), target.username, conv.name)
		member_gone(s, conv, account)
	}
	respond(u, id, .Ok)
}

// member_gone tells an account's connections that a conversation isn't
// theirs any more, and takes them out of its room if they may not be in
// it now.
member_gone :: proc(s: ^Server, conv: ^Conv, account: proto.Account_Id) {
	buf: [4]u8
	gone := proto.encode_conv_id(&buf, conv.id)
	if acc := account_by_id(&s.accounts, account); acc != nil {
		for other in acc.conns {
			send_event(other, .Conv_Removed, gone)
		}
	}
	room_check(s, conv)
}

// room_check takes whoever may not see a channel any more out of its
// voice room, and tells them, as Voice_Moved to no room.
room_check :: proc(s: ^Server, conv: ^Conv) {
	changed := .Private in conv.flags
	for _, other in s.conns {
		if other.account == nil ||
		   other.room != proto.Room(conv.id) ||
		   conv_visible(conv, other.account.id) {
			continue
		}
		conn_set_room(s, other, 0)
		buf: [4]u8
		send_event(other, .Voice_Moved, proto.encode_room(&buf, 0))
		changed = true
	}
	if changed {
		bump_version(s)
	}
}

// room_hidden is whether who is in a room is not for an account to know:
// a private channel's it isn't in.
room_hidden :: proc(s: ^Server, room: proto.Room, account: proto.Account_Id) -> bool {
	if room == 0 {
		return false
	}
	if proto.room_call(room) != 0 {
		return !call_room_member(s, room, account)
	}
	conv := conv_by_id(&s.convs, proto.Conv_Id(room))
	return conv != nil && !conv_visible(conv, account)
}

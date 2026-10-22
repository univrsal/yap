package server

import "core:log"
import "core:strings"

import "common:proto"

// This file handles what clients ask about conversations and voice rooms (see
// src/common/proto/convs.odin) and what they are told about them.
//
// A connection is told about the conversations its account is a member of when
// it logs in (see directory.odin), and about each later change to them. For
// example, a channel subscribed to on one device appears on the account's other
// devices as well.
//
// A connection's voice room belongs to that connection alone, and it has none
// until it joins one. An account can be in a room on only one connection at a
// time: joining on a second connection removes the first one from its room and
// tells it.
//
// A DM is opened with DM_Open, which creates it the first time. The account that
// opened it is told about it immediately, while the other account is told when
// the first message is posted (see messages.odin). This way a DM that was opened
// but left empty doesn't show up on the other side.

// conv_request handles a request about conversations or rooms. It returns false
// if `op` isn't one.
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

// send_conv tells a connection about a conversation as its account sees it.
send_conv :: proc(s: ^Server, u: ^Conn, conv: ^Conv) {
	buf: [proto.CONV_MAX_SIZE]u8
	send_event(
		u,
		.Conv_Changed,
		proto.encode_conv(buf[:], conv_record(&s.convs, conv, u.account.id)),
	)
}

// send_read tells every connection of an account how far it has read in a
// conversation.
send_read :: proc(s: ^Server, acc: ^Account, conv: ^Conv) {
	buf: [proto.READ_CHANGED_SIZE]u8
	body := proto.encode_read_changed(&buf, conv_read_state(&s.convs, conv, acc.id))
	for u in acc.conns {
		send_event(u, .Read_Changed, body)
	}
}

// send_convs tells a connection about every conversation its account is told
// about (see conv_shown), in the order they appear in a list.
send_convs :: proc(s: ^Server, u: ^Conn) {
	for conv in convs_sorted(&s.convs) {
		if conv_shown(conv, u.account.id) {
			send_conv(s, u, conv)
		}
	}
}

// send_conv_to_account tells every connection of an account about a conversation.
send_conv_to_account :: proc(s: ^Server, account: proto.Account_Id, conv: ^Conv) {
	if acc := account_by_id(&s.accounts, account); acc != nil {
		for u in acc.conns {
			send_conv(s, u, conv)
		}
	}
}

// dm_open answers with the DM between the connection's account and another
// account, creating it if it doesn't exist yet, since anyone may message anyone.
// The account's connections are told about the DM before the answer is sent, so
// they already know about it by the time the answer arrives.
@(private = "file")
dm_open :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	other, ok := proto.decode_account_id(body)
	me := u.account.id
	switch {
	case !ok || other == me:
		respond(u, id, .Invalid)
		return
	case account_live(&s.accounts, other) == nil:
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
	// A DM that the other account opened and that has no messages yet is
	// new to this account, just like a DM that was created right now.
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
	// Place the new channel after all existing ones.
	position := 0
	for _, other in s.convs.by_id {
		position = max(position, other.position + 1)
	}
	conv := conv_add(&s.convs, name, topic, {.Private} if private else {}, u.account.id, position)
	// The creator of a channel is always a member of it.
	if conv == nil || !conv_member_add(&s.convs, conv, u.account.id) {
		respond(u, id, .Internal)
		return
	}
	log.infof(
		"%s created the %schannel %q",
		conn_label(u),
		"private " if private else "",
		conv.name,
	)
	buf: [4]u8
	respond(u, id, .Ok, proto.encode_conv_id(&buf, conv.id))
	for other in u.account.conns {
		send_conv(s, other, conv)
	}
}

@(private = "file")
// conv_browse answers with a page of the channels that the connection's account
// could subscribe to. These are the channels it isn't in but can see, and whose
// name or topic contains the query (ignoring case). With BROWSE_ALL, which is for
// managing channels, they are all the channels it may manage instead (see
// conv_manageable). The channels are kept in memory, so this loops over all of
// them, however far into the list the page is.
conv_browse :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	b, ok := proto.decode_conv_browse(body)
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	all := b.flags & proto.BROWSE_ALL != 0
	if all && !can(u.account, .Manage_Channels) {
		respond(u, id, .Denied)
		return
	}
	query := strings.to_lower(b.query, context.temp_allocator)
	records := make([dynamic]proto.Conv, 0, b.limit, context.temp_allocator)
	matched := 0
	more := false
	for conv in convs_sorted(&s.convs) {
		if all {
			if !conv_manageable(conv, u.account) {
				continue
			}
		} else if conv.kind != .Channel ||
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
	if conv == nil || (!conv_visible(conv, u.account.id) && !conv_manageable(conv, u.account)) {
		respond(u, id, .Not_Found)
		return
	}
	out := make([]u8, 2 + len(conv.members) * 4, context.temp_allocator)
	respond(u, id, .Ok, proto.encode_conv_members(out, conv.members[:]))
}

// voice_join puts a connection in a channel's voice room, or takes it out of its
// current room if the room is 0. Anyone who may see the channel may be in its
// room, whether or not they are subscribed to the channel.
@(private = "file")
voice_join :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	room, ok := proto.decode_room(body)
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	if room != 0 {
		// Bots can't use voice (see proto/bots.odin).
		if .Bot in u.account.flags {
			respond(u, id, .Denied)
			return
		}
		conv := conv_by_id(&s.convs, proto.Conv_Id(room))
		if conv == nil || conv.kind != .Channel || !conv_visible(conv, u.account.id) {
			respond(u, id, .Not_Found)
			return
		}
		// Only one connection of an account can be in a room at a time, so
		// any other connection that was in a room is removed from it and
		// told which room its account moved to.
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

// conn_set_room moves a connection to a voice room and makes the change visible
// to everyone. A camera that is on stays on in the new room only if that room
// has room for it (camera_allowed).
conn_set_room :: proc(s: ^Server, u: ^Conn, room: proto.Room) {
	if u.room == room {
		return
	}
	// Leaving a call's room ends the call (see calls.odin).
	calls_room_left(s, u, room)
	if proto.room_call(room) != 0 {
		log.infof("%s is in call %d", conn_label(u), proto.room_call(room))
	} else if conv := conv_by_id(&s.convs, proto.Conv_Id(room)); conv != nil {
		log.infof("%s joined the voice of %q", conn_label(u), conv.name)
	} else {
		log.infof("%s left voice", conn_label(u))
	}
	u.room = room
	if .Camera in u.flags && !camera_allowed(s, u) {
		u.flags -= {.Camera}
	}
	bump_version(s)
}

// member_conv returns the conversation `conv_id` if the connection's account is a
// member of it, and otherwise the status explaining why not.
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

// mark_read records that the account has read a conversation up to a message.
// The read position only ever moves forward. Every connection of the account is
// told about it so that the others stop showing the conversation as unread.
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

// conv_notify sets how much notification a conversation may cause for the account.
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

// Managing channels (phase 13): renaming a channel and changing its topic and
// its position in the lists (Manage_Channels), archiving a channel, which is as
// good as deleting it (also Manage_Channels), adding somebody to a channel, which
// is as if they had subscribed (requires Invite and being in it), and removing
// somebody from a private channel (Manage_Channels). Those who manage channels
// may do this to the private channels they aren't in as well (conv_manageable),
// which they find with Conv_Browse's BROWSE_ALL.
//
// The voice room of a private channel is only for its members. Whoever is
// removed from the channel or leaves it is removed from its room as well, and
// nobody else is told who is in the room (see sync_state).

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
	case conv == nil || !conv_manageable(conv, u.account):
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
	case conv == nil || !conv_manageable(conv, u.account):
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
	target := account_live(&s.accounts, account)
	switch {
	// Those who manage channels may remove members from a private channel they
	// aren't in, but adding someone requires being in it.
	case conv == nil ||
	     conv.kind != .Channel ||
	     (!conv_visible(conv, u.account.id) && (on || !conv_manageable(conv, u.account))):
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
		// Removing someone from a public channel makes no sense, since they
		// could just subscribe again.
		respond(u, id, .Invalid)
		return
	case !on && target != u.account && !outranks(u.account, permissions(target)):
		// Someone can't remove a member from a private channel if that member
		// has more permissions.
		respond(u, id, .Denied)
		return
	}
	if on {
		if !conv_is_member(conv, account) {
			// Everything already in the channel counts as read for a newly added
			// member.
			if !conv_member_add(&s.convs, conv, account) {
				respond(u, id, .Internal)
				return
			}
			log.infof("%s added %s to %q", conn_label(u), target.username, conv.name)
			send_conv_to_account(s, account, conv)
			if .Private in conv.flags {
				bump_version(s) // the new member can now see who is in the room
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

// member_gone tells an account's connections that they are no longer part of a
// conversation, and removes them from its voice room if they may no longer be
// in it.
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

// room_check removes everyone who may no longer see a channel from its voice
// room and tells them with a Voice_Moved event to no room.
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

// room_hidden returns whether an account isn't allowed to know who is in a room.
// This is the case for the room of a private channel the account isn't in.
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

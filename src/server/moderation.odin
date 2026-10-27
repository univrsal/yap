package server

import "core:log"

import "common:proto"

// Moderation (src/common/proto/moderation.odin, docs/design/moderation.md):
// moving people between voice rooms or out of them, muting them for
// everyone, and banning them (bans.odin).
//
// Each needs its permission, and works only on accounts the asker outranks
// (roles.odin), never on the asker or the owner.
//
// Moving goes by account: an account is in a room on at most one connection
// (voice_join), and that connection is moved. Someone in a call can't be
// moved, and neither can someone whose room the mover can't see. The mover
// needs See and Voice in the target room; what the person moved may do there
// isn't asked (D5). The connection's guest_room keeps them there whatever
// their rights (room_check), lets them see who is in it (room_hidden) and
// speak there, though not use video without Video (room_right), until they go
// anywhere else.
//
// A mute is the account flag Server_Muted, kept in the database, so it lasts
// across rooms and logins until it is lifted. relay_voice drops the voice of
// a muted account.

// moderation_request handles a moderation request. It returns false if `op`
// isn't one.
moderation_request :: proc(
	s: ^Server,
	u: ^Conn,
	id: u32,
	op: proto.Request_Op,
	body: []u8,
) -> bool {
	#partial switch op {
	case .Voice_Move:
		voice_move(s, u, id, body)
	case .Voice_Mute:
		voice_mute(s, u, id, body)
	case .Ban_Set:
		ban_set(s, u, id, body)
	case .Ban_List:
		ban_list(s, u, id)
	case:
		return false
	}
	return true
}

// moderation_target returns the account that `u` wants to act on with
// `perm`, or the status that says why it may not.
moderation_target :: proc(
	s: ^Server,
	u: ^Conn,
	account: proto.Account_Id,
	perm: proto.Permission,
) -> (
	^Account,
	proto.Status,
) {
	if !can(u.account, perm) {
		return nil, .Denied
	}
	target := account_live(&s.accounts, account)
	switch {
	case target == nil:
		return nil, .Not_Found
	case target == u.account || .Owner in target.flags:
		return nil, .Invalid
	case !outranks(u.account, permissions(target)):
		return nil, .Denied
	}
	return target, .Ok
}

// voice_move moves an account's connection that is in a channel's voice room
// to another room, or out of voice (room 0), and tells it who did.
@(private = "file")
voice_move :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	account, room, ok := proto.decode_voice_move(body)
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	target, status := moderation_target(s, u, account, .Move_Members)
	if target == nil {
		respond(u, id, status)
		return
	}
	// Its connection in a room, which must be one we may know about.
	moved: ^Conn
	for c in target.conns {
		if c.room != 0 {
			moved = c
		}
	}
	if moved == nil ||
	   proto.room_call(moved.room) != 0 ||
	   room_hidden(s, moved.room, u.account.id) {
		respond(u, id, .Not_Found)
		return
	}
	to: ^Conv
	if room != 0 {
		to = conv_by_id(&s.convs, proto.Conv_Id(room))
		if to == nil || to.kind != .Channel || !conv_visible(to, u.account) {
			respond(u, id, .Not_Found)
			return
		}
		// Somewhere we could talk ourselves: not text only, and with Voice.
		if .Voice not_in conv_rights(to, u.account) {
			respond(u, id, .Denied)
			return
		}
	}
	respond(u, id, .Ok)
	if moved.room == room {
		return
	}
	if to != nil {
		log.infof("%s moved %s to the voice of %q", conn_label(u), target.username, to.name)
	} else {
		log.infof("%s disconnected %s from voice", conn_label(u), target.username)
	}
	conn_set_room(s, moved, room)
	// It stays there, rights or not, until it goes elsewhere (D5).
	moved.guest_room = room
	buf: [proto.VOICE_MOVED_MAX_SIZE]u8
	name := to.name if to != nil else ""
	send_event(moved, .Voice_Moved, proto.encode_voice_moved(&buf, room, u.account.id, name))
}

// voice_mute mutes an account for everyone, or lifts that.
@(private = "file")
voice_mute :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	account, on, ok := proto.decode_voice_mute(body)
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	target, status := moderation_target(s, u, account, .Mute_Members)
	if target == nil {
		respond(u, id, status)
		return
	}
	if (.Server_Muted in target.flags) == on {
		respond(u, id, .Ok)
		return
	}
	flags := target.flags + {.Server_Muted} if on else target.flags - {.Server_Muted}
	if !account_set_flags(&s.accounts, target, flags) {
		respond(u, id, .Internal)
		return
	}
	log.infof("%s %s %s", conn_label(u), "muted" if on else "unmuted", target.username)
	respond(u, id, .Ok)
	account_changed(s, target)
}

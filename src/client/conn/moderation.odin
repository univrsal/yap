package conn

import log "common:wlog"
import "core:fmt"
import "core:strings"

import "common:proto"

// Moderation (src/common/proto/moderation.odin): moving people between voice
// rooms or out of them and muting them for everyone, and being on the other
// end of that ourselves.
//
// Someone moved into a room is told who did it and the room's name, which
// matters for a room in a channel we don't have (one we couldn't see or join
// on our own): its name is kept as the guest room's until we leave it.
//
// Being muted by a moderator is our account's Server_Muted flag. While it is
// set, nothing we say is sent to this server (capture_loop), whatever the
// microphone button says, since the server would drop it anyway.

// Move someone's voice to another room, or out of voice (room 0). Headless,
// by the account's and the channel's names instead (channel "" for none).
Voice_Move_Command :: struct {
	account: proto.Account_Id,
	room:    proto.Room,
	name:    string, // owned by the command; headless
	channel: string, // owned by the command; headless
}

// Mute someone for everyone, or lift that. Headless, by name.
Voice_Mute_Command :: struct {
	account: proto.Account_Id,
	on:      bool,
	name:    string, // owned by the command; headless
}

voice_move :: proc(c: ^Server_Conn, cmd: Voice_Move_Command) {
	account := cmd.account if cmd.account != 0 else account_named(c, cmd.name)
	if account == 0 {
		log.warnf("there's nobody called %q here", cmd.name)
		return
	}
	room := cmd.room
	if room == 0 && cmd.channel != "" {
		room = proto.Room(conv_by_name(c, cmd.channel))
		if room == 0 {
			log.warnf(
				"there's no channel called %q among yours (/channels lists them)",
				cmd.channel,
			)
			return
		}
	}
	buf: [proto.VOICE_MOVE_SIZE]u8
	request(c, .Voice_Move, proto.encode_voice_move(&buf, account, room), moderation_done)
}

voice_mute :: proc(c: ^Server_Conn, cmd: Voice_Mute_Command) {
	account := cmd.account if cmd.account != 0 else account_named(c, cmd.name)
	if account == 0 {
		log.warnf("there's nobody called %q here", cmd.name)
		return
	}
	buf: [proto.VOICE_MUTE_SIZE]u8
	request(c, .Voice_Mute, proto.encode_voice_mute(&buf, account, cmd.on), moderation_done)
}

@(private = "file")
moderation_done :: proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
	#partial switch status {
	case .Ok, .Reset:
		if c.view == nil && status == .Ok {
			log.info("[moderation] done")
		}
	case .Not_Found:
		notify(c, false, "They aren't in a voice room you can see.")
	case .Invalid:
		notify(c, false, "That can't be done to them.")
	case .Denied:
		notify(c, false, "You aren't allowed to do that to them, or there.")
	case:
		notify(c, false, status_text(status))
	}
}

// voice_moved takes Voice_Moved: our voice is in another room now, or in none.
voice_moved :: proc(c: ^Server_Conn, body: []u8) {
	room, by, name, ok := proto.decode_voice_moved(body)
	if !ok {
		return
	}
	if by == 0 {
		if room != 0 {
			log.infof(
				"another of your devices joined the voice of %q, which took this one out",
				room_name(c, room),
			)
		} else {
			log.info("you may no longer talk in that channel's voice room")
		}
		return
	}
	who := account_display(c, by)
	if who == "" {
		who = "A moderator"
	}
	if room == 0 {
		notify(c, true, fmt.tprintf("%s disconnected you from voice.", who))
		return
	}
	cv := &c.convs
	delete(cv.guest_name)
	cv.guest_room, cv.guest_name = room, strings.clone(name)
	notify(c, true, fmt.tprintf("%s moved you to # %s.", who, room_name(c, room)))
}

// guest_left forgets the guest room once a snapshot shows that we have left
// it (Voice_Moved comes on the stream and the snapshot separately, so a
// snapshot that doesn't have us there yet says nothing).
guest_left :: proc(c: ^Server_Conn, old_room, room: proto.Room) {
	cv := &c.convs
	if cv.guest_room != 0 && old_room == cv.guest_room && room != old_room {
		guest_forget(cv)
	}
}

guest_forget :: proc(cv: ^Conv_Client) {
	delete(cv.guest_name)
	cv.guest_room, cv.guest_name = 0, ""
}

// server_muted returns whether a moderator has muted our account here.
server_muted :: proc(c: ^Server_Conn) -> bool {
	acc, ok := c.auth.accounts[c.auth.me]
	return ok && .Server_Muted in acc.flags
}

// server_mute_changed tells us when a moderator mutes us or lifts it
// (Account_Changed about our own account).
server_mute_changed :: proc(c: ^Server_Conn, was, now: bool) {
	if was == now {
		return
	}
	if now {
		notify(c, false, "A moderator muted you on this server. Nobody here hears you.")
	} else {
		notify(c, true, "A moderator lifted your mute on this server.")
	}
}

// Ban someone, or lift their ban, perhaps removing their messages in
// channels too (`purge`). Headless, by name.
Ban_Command :: struct {
	account: proto.Account_Id,
	on:      bool,
	reason:  string, // owned by the command
	purge:   proto.Ban_Purge,
	name:    string, // owned by the command; headless
}

// Ask for the bans (Ban_Members).
Bans_Command :: struct {}

// The bans as of the last time they were asked for, newest first. The reasons
// are owned.
View_Bans :: struct {
	list:  [dynamic]proto.Ban,
	count: int, // incremented each time the list arrives
}

view_clear_bans :: proc(v: ^View) {
	for b in v.bans.list {
		delete(b.reason)
	}
	clear(&v.bans.list)
}

ban_set :: proc(c: ^Server_Conn, cmd: Ban_Command) {
	account := cmd.account if cmd.account != 0 else account_named(c, cmd.name)
	if account == 0 {
		log.warnf("there's nobody called %q here", cmd.name)
		return
	}
	buf: [proto.BAN_SET_MAX_SIZE]u8
	body := proto.encode_ban_set(
		&buf,
		{account = account, on = cmd.on, reason = cmd.reason, purge = cmd.purge},
	)
	if body == nil {
		notify(c, false, "The reason is too long.")
		return
	}
	request(c, .Ban_Set, body, proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
		#partial switch status {
		case .Ok:
			if c.view == nil {
				log.info("[moderation] done")
			}
			bans_list(c)
		case .Reset:
		case .Not_Found:
			notify(c, false, "They aren't banned, or no longer exist.")
		case .Invalid:
			notify(c, false, "They can't be banned.")
		case .Denied:
			notify(c, false, "You aren't allowed to ban them.")
		case .Conflict:
			notify(
				c,
				false,
				"A purge is running, so their messages can't be removed now. Nothing was done.",
			)
		case:
			notify(c, false, status_text(status))
		}
	})
}

bans_list :: proc(c: ^Server_Conn) {
	if .Ban_Members not_in c.auth.permissions {
		return
	}
	request(c, .Ban_List, nil, proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
		if status != .Ok {
			return
		}
		bans, ok := proto.decode_bans(body)
		if !ok {
			return
		}
		v := c.view
		if v == nil {
			for b in bans {
				log.infof(
					"banned: %s by %s: %q",
					account_display(c, b.account),
					account_display(c, b.by),
					b.reason,
				)
			}
			return
		}
		view_write(v)
		view_clear_bans(v)
		for b in bans {
			b := b
			b.reason = strings.clone(b.reason)
			append(&v.bans.list, b)
		}
		v.bans.count += 1
	})
}

// told_banned keeps why our account is banned, as the server just told us
// (a login answered Banned, or Logged_Out). The login screen shows it.
told_banned :: proc(c: ^Server_Conn, reason: string) {
	a := &c.auth
	delete(a.ban_reason)
	a.banned, a.ban_reason = true, strings.clone(reason)
	a.ban_count += 1
	log.warnf(
		"%s: this account is banned: %s",
		c.server_addr,
		reason if reason != "" else "no reason was given",
	)
}

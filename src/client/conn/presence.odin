package conn

import log "common:wlog"
import "core:slice"
import "core:strings"
import "core:time"

import "client:audio"
import "common:proto"


// Channel_Client is the client's copy of who is here: the snapshot
// (src/common/proto/datagrams.odin) of every logged-in connection, who each one
// belongs to, and which voice room it is in. The channels themselves, and which
// of them we look at and talk in, are in convs.odin.
Channel_Client :: struct {
	assembler:       proto.State_Assembler,

	// The applied snapshot; `state` points into the buffer below.
	state:           proto.Presence,
	have_state:      bool,
	applied_version: u32,
	users_buf:       [proto.MAX_STATE_USERS]proto.User_Info,

	// What we have switched off for ourselves, which others can see. It is
	// sent with Sound until a snapshot shows that the server has it.
	sound:           proto.User_Flags,
	// Whether we are talking on another server (In_Voice or In_Call), which
	// is sent with Sound as well (see Voice_Elsewhere_Command).
	talking:         proto.User_Flags,
	last_sound_sent: time.Tick,
}

// my_num returns the server's number for us, or 0 before the first snapshot.
my_num :: proc(c: ^Server_Conn) -> proto.User_Num {
	return c.channels.state.your_user if c.channels.have_state else 0
}

// my_room returns the voice room the server has us in, or 0 if we are in none.
my_room :: proc(c: ^Server_Conn) -> proto.Room {
	ch := &c.channels
	if !ch.have_state {
		return 0
	}
	me := proto.find_user(&ch.state, ch.state.your_user)
	return me.room if me != nil else 0
}

// room_members returns who is in a voice room, allocated in the temp allocator.
// Nobody is in room 0.
room_members :: proc(c: ^Server_Conn, room: proto.Room) -> []proto.User_Num {
	members := make([dynamic]proto.User_Num, context.temp_allocator)
	if room != 0 && c.channels.have_state {
		for u in c.channels.state.users {
			if u.room == room {
				append(&members, u.num)
			}
		}
	}
	slice.sort(members[:])
	return members[:]
}

// channels_restart forgets who is here. It is used when the server has made a
// new connection for us (see handle_welcome) or logged us out, because the
// snapshot versions then count from the start again.
channels_restart :: proc(c: ^Server_Conn) {
	ch := &c.channels
	ch.have_state = false
	ch.state = {}
	ch.applied_version = 0
	ch.assembler.count = 0
	ch.last_sound_sent = {}
}

// sound_flags returns the flags a client publishes when it is muted or deafened
// as given.
sound_flags :: proc(muted, deafened: bool) -> (flags: proto.User_Flags) {
	if muted {
		flags += {.Muted}
	}
	if deafened {
		flags += {.Deafened}
	}
	return
}

// set_sound tells the others what we have switched off for ourselves. Muting
// somebody else for our own ears is nobody's business but ours and is never
// sent. This is only about our own microphone and speakers.
set_sound :: proc(c: ^Server_Conn, flag: proto.User_Flag, on: bool) {
	if on {
		c.channels.sound += {flag}
	} else {
		c.channels.sound -= {flag}
	}
	c.channels.last_sound_sent = {}
}

// drive_sound resends Sound while the server shows different flags than it
// would with ours. Sending it is idempotent, so repeats and reordering are
// harmless.
drive_sound :: proc(c: ^Server_Conn) {
	ch := &c.channels
	if !ch.have_state ||
	   !c.has_current ||
	   time.tick_since(ch.last_sound_sent) < proto.CONTROL_RESEND {
		return
	}
	me := proto.find_user(&ch.state, ch.state.your_user)
	flags := ch.sound + ch.talking
	if me == nil || me.flags == shown_flags(c, me.room, flags) {
		return
	}
	buf: [proto.SOUND_SIZE]byte
	send_data(c, proto.encode_sound(&buf, flags))
	ch.last_sound_sent = time.tick_now()
	log.debugf("sending sound state %v", flags)
}

// shown_flags returns the flags the server shows for us once it has the ones
// we send (server/server.odin, presence_list): whether we are talking is its
// to say while we are in one of its rooms, and nobody is told if we chose not
// to show it.
@(private = "file")
shown_flags :: proc(
	c: ^Server_Conn,
	room: proto.Room,
	sent: proto.User_Flags,
) -> proto.User_Flags {
	flags := sent - proto.TALKING
	switch {
	case (c.profiles.shared[proto.SETTING_VOICE_SHOWN] or_else "") == proto.VOICE_SHOWN_HIDDEN:
	case room != 0:
		flags += {.In_Call} if proto.room_call(room) != 0 else {.In_Voice}
	case .In_Call in sent:
		flags += {.In_Call}
	case:
		flags += sent & {.In_Voice}
	}
	return flags
}

handle_state_message :: proc(c: ^Server_Conn, pt: []byte) {
	ch := &c.channels
	// Who is here only means something once we know who everyone is, which the
	// server tells us first (see auth.odin). A snapshot that arrives before that
	// is left unacknowledged, so the server sends it again.
	if c.auth.state != .Done {
		return
	}
	version := proto.state_message_version(pt)
	if ch.have_state && !proto.serial_newer(version, ch.applied_version) {
		// The server resends what we already have when our ack was lost or after a
		// rekey. Acknowledge it again so the server stops.
		if version == ch.applied_version {
			send_state_ack(c, version)
		}
		return
	}

	v, body, complete := proto.assembler_add(
		&ch.assembler,
		pt,
		ch.applied_version if ch.have_state else 0,
	)
	if complete {
		apply_state(c, v, body)
	}
}

apply_state :: proc(c: ^Server_Conn, version: u32, body: []byte) {
	ch := &c.channels

	// Validate into scratch space first, so that an invalid snapshot cannot
	// overwrite the one we have.
	scratch_users := make([]proto.User_Info, len(ch.users_buf), context.temp_allocator)
	if _, ok := proto.decode_state(body, scratch_users); !ok {
		log.warnf("ignoring invalid snapshot v%d from the server", version)
		return
	}

	had_state := ch.have_state
	old_room := my_room(c)
	old_members := room_members(c, old_room)

	ch.state, _ = proto.decode_state(body, ch.users_buf[:])
	ch.have_state = true
	ch.applied_version = version
	send_state_ack(c, version)
	log.debugf("applied snapshot v%d", version)

	// The mixer looks up the gain of each user by account.
	clear(&c.voice.user_accounts)
	for &u in ch.state.users {
		c.voice.user_accounts[u.num] = u.account
	}

	// The sounds and the log are about the room our voice is in, meaning who
	// joined it and who left, including ourselves.
	room := my_room(c)
	members := room_members(c, room)
	guest_left(c, old_room, room)
	switch {
	case room != old_room:
		if room != 0 {
			// Play only one arrival sound, for ourselves, and not one for everybody who
			// was already there.
			audio.voice_notification_play(&c.voice, .Join)
			log.infof("in the voice of %q with %s", room_name(c, room), members_string(c, members))
		} else if had_state {
			audio.voice_notification_play(&c.voice, .Leave)
			log.info("left voice")
		}
	case room != 0 && !slice.equal(old_members, members):
		for member in members {
			if !slice.contains(old_members, member) {
				audio.voice_notification_play(&c.voice, .Join)
			}
		}
		for member in old_members {
			if !slice.contains(members, member) {
				audio.voice_notification_play(&c.voice, .Leave)
			}
		}
		log.infof("the voice of %q now has %s", room_name(c, room), members_string(c, members))
	}
	publish_channels(c)
}

// in_room reports whether our voice is going anywhere, which is when we are in
// a room and not in the middle of changing it. Otherwise voice is neither sent
// nor played.
in_room :: proc(c: ^Server_Conn) -> bool {
	return my_room(c) != 0 && !c.convs.voice_pending
}

// room_right says whether we may use `right` (Speak or Video) in the voice
// room we are in, as the server's room_right does: both of a call may do both,
// and where a moderator moved us we may speak. In a channel that isn't one of
// ours, video is left to the server to judge, except as such a guest.
room_right :: proc(c: ^Server_Conn, right: proto.Conv_Right) -> bool {
	room := my_room(c)
	guest := room == c.convs.guest_room
	switch {
	case room == 0:
		return false
	case proto.room_call(room) != 0 || (right == .Speak && guest):
		return true
	}
	info, ok := c.convs.convs[proto.Conv_Id(room)]
	return right in info.rights if ok else !guest
}

send_state_ack :: proc(c: ^Server_Conn, version: u32) {
	buf: [proto.STATE_ACK_SIZE]byte
	send_data(c, proto.encode_state_ack(&buf, version))
}

members_string :: proc(c: ^Server_Conn, members: []proto.User_Num) -> string {
	if len(members) == 0 {
		return "nobody"
	}
	b := strings.builder_make(context.temp_allocator)
	for m, i in members {
		if i > 0 {
			strings.write_string(&b, ", ")
		}
		strings.write_string(&b, display_name(c, m))
		if m == my_num(c) {
			strings.write_string(&b, " (you)")
		}
		// What they have switched off for themselves. Anyone we muted for our own
		// ears is our business only and isn't shown here.
		if u := proto.find_user(&c.channels.state, m); u != nil {
			switch {
			case .Deafened in u.flags:
				strings.write_string(&b, " [deafened]")
			case .Muted in u.flags:
				strings.write_string(&b, " [muted]")
			}
			if .Sharing in u.flags {
				strings.write_string(&b, " [sharing]")
			}
		}
	}
	return strings.to_string(b)
}

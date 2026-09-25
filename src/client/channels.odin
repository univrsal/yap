package client

import log "../common/wlog"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"

import "../proto"

// Channel_Client is the client's copy of the channel state, plus any Join
// or name change still waiting to be acknowledged.
Channel_Client :: struct {
	assembler:       proto.State_Assembler,

	// The applied snapshot; `state` points into the buffers below.
	state:           proto.Channel_State,
	have_state:      bool,
	applied_version: u32,
	body:            [proto.MAX_STATE_SIZE]byte,
	users_buf:       [proto.MAX_STATE_USERS]proto.User_Info,
	channels_buf:    [proto.MAX_CHANNELS]proto.Channel_Info,
	members_buf:     [proto.MAX_STATE_SIZE / 4]proto.User_Num,

	// Channel to join as soon as the first snapshot arrives.
	wanted:          string,
	last_request:    u32, // newest Join request id used
	join_pending:    bool,
	join_channel:    u16,
	last_join_sent:  time.Tick,

	// Our name (sanitized, owned). Sent in the handshake, and with Set_Name
	// until a snapshot shows the server has it.
	name:            string,
	last_name_sent:  time.Tick,

	// What we've switched off for ourselves, for the others to see. Sent
	// with Sound until a snapshot shows the server has it.
	sound:           proto.User_Flags,
	last_sound_sent: time.Tick,
}

// my_num is the server's number for us, or 0 before the first snapshot.
my_num :: proc(c: ^Voice_Client) -> proto.User_Num {
	return c.channels.state.your_user if c.channels.have_state else 0
}

// set_name changes the name we go by; it's sent on the next drive_name.
set_name :: proc(c: ^Voice_Client, name: string) {
	buf: [proto.MAX_NAME_SIZE]u8
	delete(c.channels.name)
	c.channels.name = strings.clone(proto.sanitize_name(name, &buf))
	c.channels.last_name_sent = {}
}

// sound_flags is what a client muted or deafened like this publishes.
sound_flags :: proc(muted, deafened: bool) -> (flags: proto.User_Flags) {
	if muted {
		flags += {.Muted}
	}
	if deafened {
		flags += {.Deafened}
	}
	return
}

/*
set_sound tells the others what we've switched off for ourselves. Muting
somebody else for our own ears is nobody's business but ours and never
goes out; this is only ever about our own microphone and speakers.
*/
set_sound :: proc(c: ^Voice_Client, flag: proto.User_Flag, on: bool) {
	if on {
		c.channels.sound += {flag}
	} else {
		c.channels.sound -= {flag}
	}
	c.channels.last_sound_sent = {}
}

// drive_sound resends Sound while the server shows different flags,
// the same way drive_name does with the name.
drive_sound :: proc(c: ^Voice_Client) {
	ch := &c.channels
	if !ch.have_state ||
	   !c.has_current ||
	   time.tick_since(ch.last_sound_sent) < proto.CONTROL_RESEND {
		return
	}
	me := proto.find_user(&ch.state, ch.state.your_user)
	if me == nil || me.flags == ch.sound {
		return
	}
	buf: [proto.SOUND_SIZE]byte
	send_data(c, proto.encode_sound(&buf, ch.sound))
	ch.last_sound_sent = time.tick_now()
	log.debugf("sending sound state %v", ch.sound)
}

// drive_name resends Set_Name while the server shows a different name.
// It's idempotent, so repeats and reordering are harmless.
drive_name :: proc(c: ^Voice_Client) {
	ch := &c.channels
	if !ch.have_state ||
	   !c.has_current ||
	   time.tick_since(ch.last_name_sent) < proto.CONTROL_RESEND {
		return
	}
	me := proto.find_user(&ch.state, ch.state.your_user)
	if me == nil || me.name == ch.name {
		return
	}
	buf: [proto.SET_NAME_MAX_SIZE]byte
	send_data(c, proto.encode_set_name(&buf, ch.name))
	ch.last_name_sent = time.tick_now()
	log.debugf("sending name %q", ch.name)
}

handle_state_message :: proc(c: ^Voice_Client, pt: []byte) {
	ch := &c.channels
	version := proto.state_message_version(pt)
	if ch.have_state && !proto.serial_newer(version, ch.applied_version) {
		// The server resends what we already have when our ack got lost,
		// or after a rekey. Ack again so it stops.
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

apply_state :: proc(c: ^Voice_Client, version: u32, body: []byte) {
	ch := &c.channels

	// Validate into scratch space first, so a bad snapshot can't clobber
	// the one we have.
	{
		scratch_users := make([]proto.User_Info, len(ch.users_buf), context.temp_allocator)
		scratch_channels := make([]proto.Channel_Info, proto.MAX_CHANNELS, context.temp_allocator)
		scratch_members := make([]proto.User_Num, len(ch.members_buf), context.temp_allocator)
		if _, ok := proto.decode_state(body, scratch_users, scratch_channels, scratch_members);
		   !ok {
			log.warnf("ignoring invalid channel state v%d from the server", version)
			return
		}
	}

	had_state := ch.have_state
	old_channel := ch.state.your_channel
	old_members: []proto.User_Num
	if had_state {
		old_members = slice.clone(ch.state.channels[old_channel].members, context.temp_allocator)
	}

	copy(ch.body[:], body)
	ch.state, _ = proto.decode_state(
		ch.body[:len(body)],
		ch.users_buf[:],
		ch.channels_buf[:],
		ch.members_buf[:],
	)
	ch.have_state = true
	ch.applied_version = version
	send_state_ack(c, version)
	log.debugf("applied channel state v%d", version)

	state := &ch.state
	// The mixer looks up per-user gains by key.
	clear(&c.voice.user_keys)
	for &u in state.users {
		c.voice.user_keys[u.num] = u.key
	}
	if !had_state {
		// Continue from the server's numbering: a restarted client's
		// counter would otherwise look like old retransmits.
		ch.last_request = state.join_ack
	}
	if ch.join_pending && !proto.serial_newer(ch.last_request, state.join_ack) {
		ch.join_pending = false
		if state.your_channel != ch.join_channel && int(ch.join_channel) < len(state.channels) {
			log.warnf("the server didn't move us to %q", state.channels[ch.join_channel].name)
		}
	}

	if had_state && state.your_channel != old_channel {
		chat_channel_changed(c)
	}

	current := state.channels[state.your_channel]
	if had_state {
		if state.your_channel != old_channel {
			// A channel move is one local departure and arrival, not a join
			// from every member already in the destination channel.
			voice_notification_play(&c.voice, .Join)
		} else {
			for member in current.members {
				if !member_present(old_members, member) {
					voice_notification_play(&c.voice, .Join)
				}
			}
			for member in old_members {
				if !member_present(current.members, member) {
					voice_notification_play(&c.voice, .Leave)
				}
			}
		}
	}
	switch {
	case !had_state || state.your_channel != old_channel:
		log.infof("in channel %q with %s", current.name, members_string(c, current.members))
	case !slice.equal(old_members, current.members):
		log.infof("%q now has %s", current.name, members_string(c, current.members))
	}

	if ch.wanted != "" {
		wanted := ch.wanted
		ch.wanted = ""
		request_join(c, wanted)
		delete(wanted)
	}
	publish_channels(c)
}

@(private = "file")
member_present :: proc(members: []proto.User_Num, wanted: proto.User_Num) -> bool {
	for member in members {
		if member == wanted {
			return true
		}
	}
	return false
}

// in_settled_channel is false until we know which channel we're in, and
// while a move is pending. Voice is neither sent nor played then, so
// nothing leaks into a channel we're only passing through (e.g. the
// default channel, before a -channel request takes effect).
in_settled_channel :: proc(c: ^Voice_Client) -> bool {
	return c.channels.have_state && !c.channels.join_pending && c.channels.wanted == ""
}

// request_join asks the server to move us to the channel called `name`.
request_join :: proc(c: ^Voice_Client, name: string) {
	ch := &c.channels
	if !ch.have_state {
		delete(ch.wanted)
		ch.wanted = strings.clone(name)
		log.infof("will join %q once connected", name)
		return
	}

	idx := -1
	for info, i in ch.state.channels {
		if info.name == name {
			idx = i
			break
		}
	}
	switch {
	case idx < 0:
		log.warnf("there's no channel called %q (/channels lists them)", name)
		return
	case idx == int(ch.state.your_channel) && !ch.join_pending:
		log.infof("already in %q", name)
		return
	}

	ch.last_request += 1
	ch.join_pending = true
	ch.join_channel = u16(idx)
	send_join(c)
	publish_channels(c)
}

// drive_join resends an unacknowledged Join request.
drive_join :: proc(c: ^Voice_Client) {
	ch := &c.channels
	if ch.join_pending &&
	   c.has_current &&
	   time.tick_since(ch.last_join_sent) >= proto.CONTROL_RESEND {
		log.debug("resending join request")
		send_join(c)
	}
}

send_join :: proc(c: ^Voice_Client) {
	buf: [proto.JOIN_SIZE]byte
	send_data(c, proto.encode_join(&buf, c.channels.last_request, c.channels.join_channel))
	c.channels.last_join_sent = time.tick_now()
}

send_state_ack :: proc(c: ^Voice_Client, version: u32) {
	buf: [proto.STATE_ACK_SIZE]byte
	send_data(c, proto.encode_state_ack(&buf, version))
}

list_channels :: proc(c: ^Voice_Client) {
	ch := &c.channels
	if !ch.have_state {
		log.info("not connected yet")
		return
	}
	for info, i in ch.state.channels {
		marker := i == int(ch.state.your_channel) ? "*" : " "
		log.infof("%s %s: %s", marker, info.name, members_string(c, info.members))
	}
}

members_string :: proc(c: ^Voice_Client, members: []proto.User_Num) -> string {
	if len(members) == 0 {
		return "nobody"
	}
	b := strings.builder_make(context.temp_allocator)
	for m, i in members {
		if i > 0 {
			strings.write_string(&b, ", ")
		}
		strings.write_string(&b, display_name(c.channels.state.users, m))
		if m == my_num(c) {
			strings.write_string(&b, " (you)")
		}
		// What they've switched off for themselves. Anyone we've muted
		// for our own ears is our business and isn't shown here.
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

/*
Commands for the network loop, from the UI or (headless) from stdin.
The queue is the only part of a Voice_Client other threads may touch.
*/
Join_Command :: struct {
	channel: string, // owned by the command
}
List_Command :: struct {}
Mute_Command :: struct {
	muted: bool,
}
// Deafen: stop playing anyone else's voice. Local only; the server and
// the other clients don't know about it.
Deafen_Command :: struct {
	deafened: bool,
}
Noise_Command :: struct {
	enabled: bool,
}
// How loud to play a user: 1 is unchanged, 0 is muted.
Gain_Command :: struct {
	key:  [proto.KEY_SIZE]u8,
	gain: f32,
}
Poke_Command :: struct {
	target_uid: proto.User_Num, // or 0, and the user is looked up by name
	name:       string, // owned by the command
	message:    string, // owned by the command
}
Name_Command :: struct {
	name: string, // owned by the command
}
// An image to post to the channel's chat; the JPEG is owned by the
// command until the client takes it.
Chat_Image_Command :: struct {
	image: Chat_Image,
}
Listen_Command :: struct {
	on: bool,
}
// Post a message to our channel's chat.
Chat_Command :: struct {
	text: string, // owned by the command
}
// We're typing in the chat box.
Typing_Command :: struct {}
Quality_Command :: struct {
	quality: Quality,
}
Gate_Command :: struct {
	enabled:           bool,
	open_db, close_db: f32,
}
Notification_Volume_Command :: struct {
	volume: f32,
}

Command :: union {
	Join_Command,
	List_Command,
	Mute_Command,
	Deafen_Command,
	Noise_Command,
	Gain_Command,
	Name_Command,
	Gate_Command,
	Listen_Command,
	Quality_Command,
	Notification_Volume_Command,
	Chat_Command,
	Poke_Command,
	Chat_Image_Command,
	Typing_Command,
	Watch_Command,
}

Command_Queue :: struct {
	mutex:    sync.Mutex,
	commands: [dynamic]Command,
}

push_command :: proc(q: ^Command_Queue, cmd: Command) {
	sync.guard(&q.mutex)
	append(&q.commands, cmd)
}

commands_destroy :: proc(q: ^Command_Queue) {
	sync.guard(&q.mutex)
	for cmd in q.commands {
		command_destroy(cmd)
	}
	delete(q.commands)
	q.commands = nil
}

@(private = "file")
command_destroy :: proc(cmd: Command) {
	#partial switch v in cmd {
	case Join_Command:
		delete(v.channel)
	case Name_Command:
		delete(v.name)
	case Chat_Command:
		delete(v.text)
	case Poke_Command:
		delete(v.name)
		delete(v.message)
	case Chat_Image_Command:
		image := v.image
		chat_image_destroy(&image)
	}
}

process_commands :: proc(c: ^Voice_Client) {
	commands: [dynamic]Command
	{
		sync.guard(&c.commands.mutex)
		commands, c.commands.commands = c.commands.commands, {}
	}
	defer {
		for cmd in commands {
			command_destroy(cmd)
		}
		delete(commands)
	}

	for &cmd in commands {
		switch &v in cmd {
		case Join_Command:
			request_join(c, v.channel)
		case List_Command:
			list_channels(c)
		case Mute_Command:
			c.voice.muted = v.muted
			set_sound(c, .Muted, v.muted)
			log.infof("voice %s", "muted" if v.muted else "unmuted")
		case Deafen_Command:
			c.voice.deafened = v.deafened
			set_sound(c, .Deafened, v.deafened)
			log.infof("audio %s", "deafened" if v.deafened else "undeafened")
		case Noise_Command:
			c.voice.denoise = v.enabled
			log.infof("noise suppression %s", "on" if v.enabled else "off")
		case Gain_Command:
			if v.gain == 1 {
				delete_key(&c.voice.gains, v.key)
			} else {
				c.voice.gains[v.key] = v.gain
			}
		case Quality_Command:
			if v.quality != c.voice.quality && encoder_setup(&c.voice, v.quality) {
				log.infof(
					"quality: %s (%s)",
					QUALITY_PRESETS[v.quality].label,
					QUALITY_PRESETS[v.quality].description,
				)
			}
		case Listen_Command:
			c.voice.listen = v.on
			log.infof("listen back %s", "on" if v.on else "off")
		case Gate_Command:
			g := &c.voice.gate
			g.enabled, g.open_db, g.close_db = v.enabled, v.open_db, v.close_db
		case Notification_Volume_Command:
			c.voice.notifications.volume = clamp(v.volume, 0, MAX_USER_VOLUME)
			log.infof("notification volume: %.0f%%", c.voice.notifications.volume * 100)
		case Name_Command:
			set_name(c, v.name)
			log.infof("name: %q", c.channels.name)
		case Chat_Command:
			chat_send(c, v.text)
		case Poke_Command:
			poke_send(c, v.target_uid, v.name, v.message)
		case Chat_Image_Command:
			// The client takes the JPEG over, so it isn't freed twice.
			chat_send_image(c, v.image.jpeg, v.image.width, v.image.height)
			v.image = {}
		case Typing_Command:
			chat_typing(c)
		case Watch_Command:
			video_watch(c, v.user)
		}
	}
}

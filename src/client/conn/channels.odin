package conn

import log "common:wlog"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"

import "client:audio"
import "client:settings"
import "common:proto"

/*
Channel_Client is the client's copy of who is here: the snapshot
(src/common/proto/messages.odin) of every connection that's logged in,
whose it is, and which voice room it's in. The channels themselves, and
which of them we look at and talk in, are in convs.odin.
*/
Channel_Client :: struct {
	assembler:       proto.State_Assembler,

	// The applied snapshot; `state` points into the buffer below.
	state:           proto.Presence,
	have_state:      bool,
	applied_version: u32,
	users_buf:       [proto.MAX_STATE_USERS]proto.User_Info,

	// What we've switched off for ourselves, for the others to see. Sent
	// with Sound until a snapshot shows the server has it.
	sound:           proto.User_Flags,
	last_sound_sent: time.Tick,
}

// my_num is the server's number for us, or 0 before the first snapshot.
my_num :: proc(c: ^Voice_Client) -> proto.User_Num {
	return c.channels.state.your_user if c.channels.have_state else 0
}

// my_room is the voice room the server has us in, or 0 for none.
my_room :: proc(c: ^Voice_Client) -> proto.Room {
	ch := &c.channels
	if !ch.have_state {
		return 0
	}
	me := proto.find_user(&ch.state, ch.state.your_user)
	return me.room if me != nil else 0
}

// room_members is who is in a voice room, in the temp allocator; nobody
// is in room 0.
room_members :: proc(c: ^Voice_Client, room: proto.Room) -> []proto.User_Num {
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

/*
channels_restart forgets who is here, for a connection the server has
made anew (see handle_welcome) or logged out: its snapshots count from
the start again.
*/
channels_restart :: proc(c: ^Voice_Client) {
	ch := &c.channels
	ch.have_state = false
	ch.state = {}
	ch.applied_version = 0
	ch.assembler.count = 0
	ch.last_sound_sent = {}
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

// drive_sound resends Sound while the server shows different flags.
// It's idempotent, so repeats and reordering are harmless.
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

handle_state_message :: proc(c: ^Voice_Client, pt: []byte) {
	ch := &c.channels
	// Who is here only means something once we know who everyone is,
	// which the server says first (auth.odin). A snapshot that gets here
	// before that is left unacknowledged, and so comes again.
	if c.auth.state != .Done {
		return
	}
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

	// The mixer looks up per-user gains by account.
	clear(&c.voice.user_accounts)
	for &u in ch.state.users {
		c.voice.user_accounts[u.num] = u.account
	}

	// The sounds and the log are about the room our voice is in: who
	// came into it and who left, ourselves included.
	room := my_room(c)
	members := room_members(c, room)
	switch {
	case room != old_room:
		if room != 0 {
			// One arrival, ours: not one for everybody who was there.
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

/*
in_room is whether our voice is going anywhere: we're in a room, and not
in the middle of changing it. Voice is neither sent nor played
otherwise.
*/
in_room :: proc(c: ^Voice_Client) -> bool {
	return my_room(c) != 0 && !c.convs.voice_pending
}

send_state_ack :: proc(c: ^Voice_Client, version: u32) {
	buf: [proto.STATE_ACK_SIZE]byte
	send_data(c, proto.encode_state_ack(&buf, version))
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
		strings.write_string(&b, display_name(c, m))
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
List_Command :: struct {}
// With `feedback`, the muted/unmuted sound plays for it. Deafening
// mutes as well (see set_deafened), and only the deafen plays its sound,
// so the two don't play one after the other.
Mute_Command :: struct {
	muted:    bool,
	feedback: bool,
}
// Deafen: stop playing anyone else's voice. Local only; the server and
// the other clients don't know about it.
Deafen_Command :: struct {
	deafened: bool,
	feedback: bool,
}
Noise_Command :: struct {
	enabled: bool,
}
// How loud to play an account's connections: 1 is unchanged, 0 is
// muted.
Gain_Command :: struct {
	account: proto.Account_Id,
	gain:    f32,
}
Poke_Command :: struct {
	target_uid: proto.User_Num, // or 0, and the user is looked up by name
	name:       string, // owned by the command
	message:    string, // owned by the command
}
// An image to post where a Chat_Command would go; the JPEG is owned by
// the command until the client takes it.
Chat_Image_Command :: struct {
	image: Chat_Image,
	dm_to: proto.Account_Id,
}
Listen_Command :: struct {
	on: bool,
}
Quality_Command :: struct {
	quality: audio.Quality,
}
Gate_Command :: struct {
	enabled:           bool,
	open_db, close_db: f32,
}
Notification_Volume_Command :: struct {
	volume: f32,
}
// How to send a shared application (ui_app_audio_native.odin): how loud,
// and whether muting the microphone mutes it too.
App_Audio_Command :: struct {
	volume:        f32,
	mute_with_mic: bool,
}

// gate_command is the voice gate as configured in `s`.
gate_command :: proc(s: ^settings.Settings) -> Gate_Command {
	open := clamp(s.gate_open_db, audio.MIN_LEVEL_DB, 0)
	return {s.voice_gate, open, clamp(s.gate_close_db, audio.MIN_LEVEL_DB, open)}
}

// app_audio_command is how a shared application is sent, as configured
// in `s`.
app_audio_command :: proc(s: ^settings.Settings) -> App_Audio_Command {
	return {volume = settings.app_audio_gain(s), mute_with_mic = s.mute_app_audio_with_mic}
}

Command :: union {
	List_Command,
	Mute_Command,
	Deafen_Command,
	Noise_Command,
	Gain_Command,
	Gate_Command,
	Listen_Command,
	Quality_Command,
	Notification_Volume_Command,
	App_Audio_Command,
	Chat_Command,
	Poke_Command,
	Chat_Image_Command,
	Typing_Command,
	Watch_Command,
	Send_File_Command,
	Attach_Send_Command,
	Attach_Cancel_Command,
	Attach_Save_Command,
	Attach_Preview_Command,
	File_Action_Command,
	Transfer_Limits_Command,
	// Buddies and DMs, see buddies.odin.
	DM_Command,
	Buddy_Command,
	Buddies_Command,
	Last_Seen_Command,
	// Accounts, see auth.odin.
	Login_Command,
	Register_Command,
	Logout_Command,
	Password_Command,
	Display_Command,
	Email_Command,
	Devices_Command,
	// Invite codes, see invites.odin.
	Invite_Create_Command,
	Invites_Command,
	Invite_Revoke_Command,
	Invite_Of_Command,
	Revoke_Command,
	Account_Create_Command,
	Account_Password_Command,
	// Channels and voice rooms, see convs.odin.
	View_Command,
	Voice_Command,
	Browse_Command,
	Subscribe_Command,
	Create_Channel_Command,
	Reading_Command,
	Notify_Command,
	// Messages, see messages.odin.
	History_Command,
	Edit_Command,
	Delete_Command,
	Pin_Command,
	Pins_Command,
	Jump_Command,
	React_Command,
	Reactors_Command,
	Forward_Command,
	Search_Command,
	Thread_Command,
	Root_Command,
	// Profiles and settings, see profiles.odin.
	Status_Command,
	Avatar_Command,
	Avatar_Want_Command,
	Setting_Command,
	Members_Command,
	// Roles and managing the server, see roles.odin.
	Role_Set_Command,
	Role_Delete_Command,
	Account_Roles_Command,
	Account_Disable_Command,
	Account_Delete_Command,
	Role_Order_Command,
	Conv_Update_Command,
	Conv_Delete_Command,
	Conv_Member_Command,
	Roles_Command,
	// Calls, see calls.odin.
	Call_Command,
	Call_Answer_Command,
	Call_Hangup_Command,
	// Purging, see purge.odin.
	Purge_Command,
	// Online, away, busy or offline, see activity.odin.
	Activity_Command,
	Idle_Command,
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
	case View_Command:
		delete(v.name)
	case Voice_Command:
		delete(v.name)
	case Subscribe_Command:
		delete(v.name)
	case Browse_Command:
		delete(v.query)
	case Create_Channel_Command:
		delete(v.name)
		delete(v.topic)
	case Notify_Command:
		delete(v.name)
	case Chat_Command:
		delete(v.text)
	case Status_Command:
		delete(v.text)
	case Avatar_Command:
		image := v.image
		chat_image_destroy(&image)
	case Setting_Command:
		delete(v.key)
		delete(v.value)
	case Role_Set_Command:
		delete(v.name)
	case Role_Delete_Command:
		delete(v.name)
	case Account_Roles_Command:
		delete(v.name)
		delete(v.role_names)
	case Account_Disable_Command:
		delete(v.name)
	case Account_Delete_Command:
		delete(v.name)
		delete(v.password)
	case Conv_Update_Command:
		delete(v.name)
		delete(v.topic)
	case Conv_Member_Command:
		delete(v.name)
	case Call_Command:
		delete(v.name)
	case Edit_Command:
		delete(v.text)
	case React_Command:
		delete(v.emoji)
	case Reactors_Command:
		delete(v.emoji)
	case Forward_Command:
		delete(v.name)
	case Search_Command:
		delete(v.query)
	case Login_Command:
		delete(v.username)
		delete(v.password)
		delete(v.device)
	case Register_Command:
		delete(v.username)
		delete(v.password)
		delete(v.device)
		delete(v.email)
		delete(v.invite)
	case Invite_Revoke_Command:
		delete(v.code)
	case Password_Command:
		delete(v.old)
		delete(v.new)
	case Display_Command:
		delete(v.name)
	case Email_Command:
		delete(v.email)
	case Account_Create_Command:
		delete(v.username)
		delete(v.password)
		delete(v.display)
	case Account_Password_Command:
		delete(v.username)
		delete(v.password)
	case Poke_Command:
		delete(v.name)
		delete(v.message)
	case Chat_Image_Command:
		image := v.image
		chat_image_destroy(&image)
	case DM_Command:
		delete(v.name)
		delete(v.text)
	case Buddy_Command:
		delete(v.name)
	case Last_Seen_Command:
		delete(v.name)
	case Send_File_Command:
		delete(v.name)
		delete(v.path)
		delete(v.web_name)
	case Attach_Send_Command:
		cmd := v
		attach_command_destroy(&cmd)
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
		case View_Command:
			conv_view_command(c, v)
		case Voice_Command:
			voice_command(c, v)
		case Browse_Command:
			conv_browse(c, v.query, v.more)
		case Subscribe_Command:
			conv_subscribe_command(c, v)
		case Create_Channel_Command:
			conv_create(c, v.name, v.topic, v.private)
		case Reading_Command:
			conv_reading(c, v.conv)
		case Notify_Command:
			conv_notify(c, v)
		case History_Command:
			messages_more(c, {v.conv if v.conv != 0 else c.convs.viewing, v.root}, v.newer)
		case Edit_Command:
			msg_edit(c, v.id, typed_text(c, v.text) if v.typed else v.text)
		case Delete_Command:
			msg_delete(c, v.id)
		case Pin_Command:
			msg_pin(c, v.id, v.on)
		case Pins_Command:
			pins_fetch(c, v.conv if v.conv != 0 else c.convs.viewing)
		case Jump_Command:
			messages_jump_to(c, v.id)
		case React_Command:
			msg_react(c, v)
		case Reactors_Command:
			reactors_fetch(c, v.id, v.emoji)
		case Forward_Command:
			msg_forward(c, v)
		case Search_Command:
			search_start(c, v)
		case Thread_Command:
			v.thread.conv = v.thread.conv if v.thread.conv != 0 else c.convs.viewing
			if v.open {
				thread_open(c, v.thread)
			} else {
				thread_close(c, v.thread)
			}
		case Root_Command:
			root_want(c, v.conv, v.root)
		case Status_Command:
			status_set(c, v.text, v.until)
		case Avatar_Command:
			// The client takes the JPEG over, so it isn't freed twice.
			avatar_set(c, v.image, v.remove)
			v.image = {}
		case Avatar_Want_Command:
			blob_want(c, {blob = v.blob}, keep = true)
		case Setting_Command:
			setting_put(c, v.key, v.value)
		case Role_Set_Command:
			role_set(c, v)
		case Role_Delete_Command:
			role_delete(c, v)
		case Account_Roles_Command:
			account_roles_set(c, v)
		case Account_Disable_Command:
			account_disable(c, v)
		case Account_Delete_Command:
			account_delete(c, v)
		case Role_Order_Command:
			role_order(c, v)
		case Conv_Update_Command:
			conv_update(c, v)
		case Conv_Delete_Command:
			conv_delete(c, v.conv)
		case Conv_Member_Command:
			conv_member_set(c, v)
		case Roles_Command:
			roles_list(c)
		case Call_Command:
			call_start(c, v)
		case Call_Answer_Command:
			call_answer(c)
		case Call_Hangup_Command:
			call_hangup(c)
		case Purge_Command:
			purge_start(c, v)
		case Activity_Command:
			activity_set(c, v.activity)
		case Idle_Command:
			idle_set(c, v.idle)
		case Members_Command:
			members_fetch(c, v.conv if v.conv != 0 else c.convs.viewing)
		case List_Command:
			list_channels(c)
		case Mute_Command:
			if v.feedback && v.muted != c.voice.muted {
				audio.voice_feedback_play(&c.voice, v.muted)
			}
			c.voice.muted = v.muted
			set_sound(c, .Muted, v.muted)
			log.infof("voice %s", "muted" if v.muted else "unmuted")
		case Deafen_Command:
			if v.feedback && v.deafened != c.voice.deafened {
				audio.voice_feedback_play(&c.voice, v.deafened)
			}
			c.voice.deafened = v.deafened
			set_sound(c, .Deafened, v.deafened)
			log.infof("audio %s", "deafened" if v.deafened else "undeafened")
		case Noise_Command:
			c.voice.denoise = v.enabled
			log.infof("noise suppression %s", "on" if v.enabled else "off")
		case Gain_Command:
			if v.gain == 1 {
				delete_key(&c.voice.gains, v.account)
			} else {
				c.voice.gains[v.account] = v.gain
			}
		case Quality_Command:
			if v.quality != c.voice.quality && audio.encoder_setup(&c.voice, v.quality) {
				log.infof(
					"quality: %s (%s)",
					audio.QUALITY_PRESETS[v.quality].label,
					audio.QUALITY_PRESETS[v.quality].description,
				)
			}
		case Listen_Command:
			c.voice.listen = v.on
			log.infof("listen back %s", "on" if v.on else "off")
		case Gate_Command:
			g := &c.voice.gate
			g.enabled, g.open_db, g.close_db = v.enabled, v.open_db, v.close_db
		case Notification_Volume_Command:
			c.voice.notifications.volume = clamp(v.volume, 0, settings.MAX_USER_VOLUME)
			log.infof("notification volume: %.0f%%", c.voice.notifications.volume * 100)
		case App_Audio_Command:
			c.voice.app_volume = clamp(v.volume, 0, settings.MAX_USER_VOLUME)
			c.voice.app_mute_with_mic = v.mute_with_mic
		case Chat_Command:
			if v.thread.root != 0 && v.thread.conv == 0 {
				v.thread.conv = c.convs.viewing
			}
			chat_send(c, typed_text(c, v.text) if v.typed else v.text, v.dm_to, v.thread)
		case Poke_Command:
			poke_send(c, v.target_uid, v.name, v.message)
		case Chat_Image_Command:
			// The client takes the JPEG over, so it isn't freed twice.
			chat_send_image(c, v.image.jpeg, v.image.width, v.image.height, v.dm_to)
			v.image = {}
		case Typing_Command:
			if v.thread.root != 0 && v.thread.conv == 0 {
				v.thread.conv = c.convs.viewing
			}
			chat_typing(c, v.thread)
		case Watch_Command:
			video_watch(c, v.user)
		case DM_Command:
			dm_command(c, v)
		case Buddy_Command:
			buddy_command(c, v)
		case Buddies_Command:
			list_buddies(c)
		case Send_File_Command:
			send_file(c, v)
		case Attach_Send_Command:
			if v.thread.root != 0 && v.thread.conv == 0 {
				v.thread.conv = c.convs.viewing
			}
			attach_send(c, v)
		case Attach_Cancel_Command:
			attach_cancel(c, v.nonce)
		case Attach_Save_Command:
			attach_save(c, v)
		case Attach_Preview_Command:
			attach_preview(c, v)
		case File_Action_Command:
			file_action(c, v.id, v.action)
		case Transfer_Limits_Command:
			c.files.upload_limit, c.files.download_limit = v.upload, v.download
		case Last_Seen_Command:
			last_seen_command(c, v)
		case Login_Command:
			auth_login(c, v)
		case Register_Command:
			auth_register(c, v)
		case Invite_Create_Command:
			invite_create(c, v)
		case Invites_Command:
			invites_list(c)
		case Invite_Revoke_Command:
			invite_revoke(c, v.code)
		case Invite_Of_Command:
			invite_of(c, v.account)
		case Logout_Command:
			auth_logout(c)
		case Password_Command:
			auth_password(c, v)
		case Display_Command:
			auth_display(c, v.name)
		case Email_Command:
			auth_email(c, v.email)
		case Devices_Command:
			auth_devices(c)
		case Revoke_Command:
			auth_revoke(c, v.key)
		case Account_Create_Command:
			auth_account_create(c, v)
		case Account_Password_Command:
			auth_account_password(c, v)
		}
	}
}

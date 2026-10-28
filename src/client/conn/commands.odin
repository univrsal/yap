package conn

import log "common:wlog"
import "core:sync"
import "core:time"

import "client:audio"
import "client:settings"
import "common:proto"

// The commands the UI and the command line queue for the connection, and the
// procedure that carries them out.

// Commands for the network loop, sent from the UI or (headless) from stdin.
// The queue is the only part of a Server_Conn that other threads may touch.
List_Command :: struct {}
// With `feedback`, the muted/unmuted sound is played. Deafening mutes as well
// (see set_deafened), and only the deafen sound is played, so the two sounds
// don't play one after the other.
Mute_Command :: struct {
	muted:    bool,
	feedback: bool,
}

// Deafen: stop playing anyone else's voice. This is local only, and the server
// and the other clients don't know about it.
Deafen_Command :: struct {
	deafened: bool,
	feedback: bool,
}

Noise_Command :: struct {
	enabled: bool,
}

// How loud to play an account's connections. 1 means unchanged and 0 means
// muted.
Gain_Command :: struct {
	account: proto.Account_Id,
	gain:    f32,
}

Listen_Command :: struct {
	on: bool,
}

// Try a server that has become unreachable again right now, instead of waiting
// for the next scheduled attempt (see connection_lost).
Reconnect_Command :: struct {}
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

// How to send a shared application's audio (see ui_app_audio_native.odin): how
// loud it is, and whether muting the microphone mutes it too.
App_Audio_Command :: struct {
	volume:        f32,
	mute_with_mic: bool,
}

// gate_command returns the voice gate as configured in `s`.
gate_command :: proc(s: ^settings.Settings) -> Gate_Command {
	open := clamp(s.gate_open_db, audio.MIN_LEVEL_DB, 0)
	return {s.voice_gate, open, clamp(s.gate_close_db, audio.MIN_LEVEL_DB, open)}
}

// app_audio_command returns how a shared application's audio is sent, as
// configured in `s`.
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
	Reconnect_Command,
	Quality_Command,
	Notification_Volume_Command,
	Sound_Command,
	Voice_Elsewhere_Command,
	App_Audio_Command,
	Chat_Command,
	Typing_Command,
	Watch_Command,
	Watch_Cameras_Command,
	Watch_Camera_Names_Command,
	Send_File_Command,
	Attach_Send_Command,
	Attach_Cancel_Command,
	Attach_Save_Command,
	Attach_Preview_Command,
	File_Action_Command,
	Transfer_Limits_Command,
	// Buddies, DMs and groups, see buddies.odin.
	DM_Command,
	Notes_Command,
	Group_Command,
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
	// Bot accounts, see bots.odin.
	Bot_Create_Command,
	Bot_Token_Command,
	Bot_Token_Forget_Command,
	// Channels and voice rooms, see convs.odin.
	View_Command,
	Voice_Command,
	Browse_Command,
	All_Channels_Command,
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
	Bookmark_Command,
	Bookmarks_Command,
	Thread_Command,
	Root_Command,
	// Profiles and settings, see profiles.odin.
	Status_Command,
	Avatar_Command,
	Avatar_Want_Command,
	Setting_Command,
	Members_Command,
	// What the server says about itself, see server_info.odin.
	Server_Info_Command,
	Server_Memory_Command,
	// Roles and managing the server, see roles.odin.
	Role_Set_Command,
	Role_Delete_Command,
	Account_Roles_Command,
	Account_Disable_Command,
	Account_Delete_Command,
	Role_Order_Command,
	// Moderation, see moderation.odin.
	Voice_Move_Command,
	Voice_Mute_Command,
	Ban_Command,
	Bans_Command,
	Conv_Update_Command,
	Conv_Rights_Get_Command,
	Conv_Rights_Set_Command,
	Conv_Rights_Text_Command,
	Conv_Flag_Command,
	Conv_Delete_Command,
	Conv_Member_Command,
	Roles_Command,
	// Calls, see calls.odin.
	Call_Command,
	Call_Answer_Command,
	Call_Hangup_Command,
	// Purging, see purge.odin.
	Purge_Command,
	// Online, away, busy or offline (see activity.odin).
	Activity_Command,
	Idle_Command,
	// Web Push, see push.odin.
	Push_Subscribe_Command,
	Push_Unsubscribe_Command,
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
	case Server_Info_Command:
		delete(v.name)
		delete(v.description)
		image := v.image
		chat_image_destroy(&image)
	case Setting_Command:
		delete(v.key)
		delete(v.value)
	case Push_Subscribe_Command:
		delete(v.sub.endpoint)
	case Role_Set_Command:
		delete(v.name)
	case Role_Delete_Command:
		delete(v.name)
	case Account_Roles_Command:
		delete(v.name)
		delete(v.role_names)
	case Account_Disable_Command:
		delete(v.name)
	case Voice_Move_Command:
		delete(v.name)
		delete(v.channel)
	case Voice_Mute_Command:
		delete(v.name)
	case Ban_Command:
		delete(v.name)
		delete(v.reason)
	case Purge_Command:
		delete(v.name)
	case Account_Delete_Command:
		delete(v.name)
		delete(v.password)
	case Conv_Update_Command:
		delete(v.name)
		delete(v.topic)
	case Conv_Rights_Set_Command:
		delete(v.entries)
	case Conv_Rights_Text_Command:
		delete(v.text)
	case Conv_Member_Command:
		delete(v.name)
	case Call_Command:
		delete(v.name)
	case Watch_Camera_Names_Command:
		delete(v.names)
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
	case Bot_Create_Command:
		delete(v.username)
		delete(v.display)
	case DM_Command:
		delete(v.name)
		delete(v.text)
	case Group_Command:
		delete(v.names)
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

process_commands :: proc(c: ^Server_Conn) {
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
			conv_browse(c, v)
		case All_Channels_Command:
			fetch_all_channels(c)
		case Subscribe_Command:
			conv_subscribe_command(c, v)
		case Create_Channel_Command:
			conv_create(c, v.name, v.topic, v.private, v.flags)
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
		case Bookmark_Command:
			bookmark_set(c, v.id, v.on)
		case Bookmarks_Command:
			bookmarks_command(c, v)
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
			status_set(c, v.text, v.until, v.at)
		case Avatar_Command:
			// The client takes over the JPEG, so it must not be freed twice.
			avatar_set(c, v.image, v.remove)
			v.image = {}
		case Avatar_Want_Command:
			blob_want(c, {blob = v.blob}, keep = true)
		case Server_Info_Command:
			// The client takes over the strings and the JPEG.
			server_info_set(c, v)
			v.name, v.description, v.image = "", "", {}
		case Server_Memory_Command:
			server_memory(c)
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
		case Voice_Move_Command:
			voice_move(c, v)
		case Voice_Mute_Command:
			voice_mute(c, v)
		case Ban_Command:
			ban_set(c, v)
		case Bans_Command:
			bans_list(c)
		case Account_Delete_Command:
			account_delete(c, v)
		case Role_Order_Command:
			role_order(c, v)
		case Conv_Update_Command:
			conv_update(c, v)
		case Conv_Rights_Get_Command:
			conv_rights_fetch(c, v.conv if v.conv != 0 else c.convs.viewing)
		case Conv_Rights_Set_Command:
			conv_rights_set(c, v)
		case Conv_Rights_Text_Command:
			conv_rights_text_set(c, v)
		case Conv_Flag_Command:
			conv_flag_set(c, v)
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
			activity_set(c, v.activity, v.at)
		case Idle_Command:
			idle_set(c, v.idle, v.hidden)
		case Push_Subscribe_Command:
			push_subscribe(c, v.sub)
		case Push_Unsubscribe_Command:
			push_unsubscribe(c)
		case Members_Command:
			members_fetch(c, v.conv if v.conv != 0 else c.convs.viewing)
		case List_Command:
			list_channels(c)
		case Mute_Command:
			if v.feedback && v.muted != c.voice.muted {
				audio.voice_feedback_play(&c.voice, .Muted if v.muted else .Unmuted)
			}
			c.voice.muted = v.muted
			set_sound(c, .Muted, v.muted)
			log.infof("voice %s", "muted" if v.muted else "unmuted")
		case Deafen_Command:
			if v.feedback && v.deafened != c.voice.deafened {
				audio.voice_feedback_play(&c.voice, .Deafened if v.deafened else .Undeafened)
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
		case Reconnect_Command:
			if c.lost && c.handshake.state == .Idle {
				c.retry_at = time.tick_now()
			}
		case Gate_Command:
			g := &c.voice.gate
			g.enabled, g.open_db, g.close_db = v.enabled, v.open_db, v.close_db
		case Notification_Volume_Command:
			c.voice.notifications.volume = clamp(v.volume, 0, settings.MAX_USER_VOLUME)
			log.infof("notification volume: %.0f%%", c.voice.notifications.volume * 100)
		case Sound_Command:
			sound_command_apply(c, &v)
		case Voice_Elsewhere_Command:
			if c.voice_elsewhere != v.busy {
				c.voice_elsewhere = v.busy
				loop_sounds(c)
			}
			if talking := v.talking & proto.TALKING; c.channels.talking != talking {
				c.channels.talking = talking
				c.channels.last_sound_sent = {}
			}
		case App_Audio_Command:
			c.voice.app_volume = clamp(v.volume, 0, settings.MAX_USER_VOLUME)
			c.voice.app_mute_with_mic = v.mute_with_mic
		case Chat_Command:
			if v.thread.root != 0 && v.thread.conv == 0 {
				v.thread.conv = c.convs.viewing
			}
			chat_send(c, typed_text(c, v.text) if v.typed else v.text, v.dm_to, v.thread)
		case Typing_Command:
			if v.thread.root != 0 && v.thread.conv == 0 {
				v.thread.conv = c.convs.viewing
			}
			chat_typing(c, v.thread)
		case Watch_Command:
			video_watch(c, v.user)
		case Watch_Cameras_Command:
			users, tiles := v.users, v.tiles
			n := clamp(v.count, 0, len(users))
			video_watch_cameras(c, users[:n], tiles[:n])
		case Watch_Camera_Names_Command:
			video_watch_camera_names(c, v.names)
		case DM_Command:
			dm_command(c, v)
		case Notes_Command:
			notes_command(c)
		case Group_Command:
			group_command(c, v)
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
			auth_devices(c, v.account)
		case Revoke_Command:
			auth_revoke(c, v.key)
		case Account_Create_Command:
			auth_account_create(c, v)
		case Account_Password_Command:
			auth_account_password(c, v)
		case Bot_Create_Command:
			auth_bot_create(c, v)
		case Bot_Token_Command:
			auth_bot_token(c, v.account)
		case Bot_Token_Forget_Command:
			auth_bot_token_forget(c)
		}
	}
}

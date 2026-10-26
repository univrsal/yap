#+build !wasi
package headless

import "client:conn"
import "client:imaging"
import "client:platform"
import "common:."
import "common:memtrack"
import "common:proto"
import log "common:wlog"
import "core:bufio"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:thread"
import "core:time"

// Headless mode reads commands from stdin on a separate thread, so the
// network loop never blocks on input.
//
//	/channels        list your channels, what is unread in them and who is
//	                 talking in them (the channel being looked at counts as read)
//	/notify <channel> all|mentions|none   how much a channel may interrupt you
//	/view <channel>  look at a channel: its chat is the one shown and the
//	                 one that /say posts to
//	/join <channel>  join a channel's voice room
//	/leave           leave the voice room
//	/browse [text]   list the channels you can subscribe to (optionally only
//	                 those with that text in their name or topic);
//	                 /browse more lists the next page
//	/subscribe <channel>, /unsubscribe <channel>
//	/create <channel> [topic]   create a channel (if you have permission)
//	/name <name>     change your account's display name
//	/email [address] set your account's email address (without an address: remove it)
//	/digest none|missed|mentions   what the server emails you about what you missed
//	/login <username> <password>   log in, if the server asks for it
//	/register <username> <password> [email] [invite]   create an account, if
//	                 the server allows it, and log in to it
//	/invite [uses] [days]   create an invite code (uses 0: unlimited uses; days 0:
//	                 never expires), if you have permission
//	/invites         list the invite codes; /uninvite <code> revokes one
//	/memory          log where this client's memory goes (see common/memtrack)
//	/server-memory   the same for the server (server owner only)
//	/logout          log this device out
//	/passwd <old> <new>   change your password
//	/devices         list your account's devices
//	/revoke <key>    log out one of those devices (the 64 hex digits shown by /devices)
//	/adduser <username> <password> [name]   create an account (admins)
//	/setpass <username> <password>          set a new password for an account (admins)
//	/addbot <username> [name]   create a bot; its token is logged once (admins)
//	/bottoken <account>         create another token for a bot, given its account id (admins)
//	/tokens <account>           list a bot's tokens, given its account id (admins)
//	/mute, /unmute   stop or resume sending voice
//	/deafen, /undeafen  stop or resume playing everyone else's voice
//	/listen, /unlisten  hear your own processed voice (listen back)
//	/say <text>      post to the conversation being looked at (@username
//	                 mentions someone), with the attached files, if any;
//	                 in a message's text (/say, /reply, /edit, /dm), \n
//	                 starts a new line
//	/attach <file>   attach a file to the next /say (up to 10);
//	                 /unattach removes them again
//	/save <id> <n>   save file n of a message to the downloads folder
//	/older, /newer   fetch the page of messages before (or after) those
//	                 fetched so far
//	/edit <id> <text>  change one of your messages (ids are shown in the log as #id)
//	/delete <id>     delete a message (yours, or anyone's if you have permission)
//	/pin <id>, /unpin <id>  pin or unpin a message
//	/pins            list the pinned messages of the conversation
//	/jump <id>       fetch the page of messages around a message
//	/react <id> <emoji>, /unreact <id> <emoji>   add or remove a reaction to a
//	                 message (the emoji can be a character, :shortcode: or :name:)
//	/thread <id>, /unthread <id>  open a message's thread (its replies are
//	                 fetched and shown as they arrive) or close it
//	/reply <id> <text>  reply in a message's thread (when replying to a reply,
//	                 the reply goes to the thread of its root message)
//	/status [minutes] [text]  set your status, which expires after that many
//	                 minutes (0 or none: never); /status alone clears it
//	/avatar <file>   use an image file as your profile picture; /noavatar removes it
//	/set <key> <value>, /unset <key>  change one of your account's settings
//	/members         list the members of the conversation being looked at
//	/roles           list the server's roles and who has them
//	/mkrole <name> [perm,...], /setrole <name> [perm,...], /delrole <name>
//	                 create, change or delete a role (permissions by name, e.g.
//	                 Invite,Pin_Messages)
//	/assign <name> [role,...]  give someone exactly these roles
//	/disable <name>, /enable <name>  prevent someone from logging in, or allow it again
//	/voicemove <name> <channel>, /voicekick <name>   move someone's voice to
//	                 another channel's room, or out of voice
//	/servermute <name>, /serverunmute <name>   mute someone for everyone on
//	                 the server, or lift that
//	/ban <name> [reason], /unban <name>, /bans   ban someone (they are told
//	                 the reason), lift it, or list the bans
//	/banpurge <name> hour|day|week|all [reason]   ban someone and remove
//	                 their messages in channels of that time
//	/purgeuser <name> [days]   remove someone's messages everywhere, of the
//	                 last few days or all of them
//	/deluser <name>  delete someone's account; /deleteme <password> deletes your own
//	/private <name>  create a private channel
//	/rename <name>, /topic <text>, /move <position>, /archive   change or
//	                 archive the channel being looked at
//	/default on|off, /textonly on|off   whether new members join the channel
//	                 being looked at, and whether it has a voice room
//	/rights          show what each role may do in the channel being looked at;
//	/rights <role>=<right,...> ...  replace that, e.g. /rights
//	                 everyone=see,react writers=see,write,edit,delete
//	                 (rights: see, write, attach, react, edit, delete, voice, none)
//	/invite <name>, /kick <name>  add someone to the channel being looked
//	                 at, or remove them from a private one
//	/call <name>     call someone; /answer accepts an incoming call; /hangup ends
//	                 the call (or cancels or declines it)
//	/cameras [names] watch the cameras of these accounts in our room (none:
//	                 stop); only the figures in the debug log show them
//	/activity online|away|busy|offline   set your activity on all your devices
//	/forward <id> <channel>   forward a message to one of your channels
//	/search [all] <words>     search the conversation being looked at (or all
//	                 of your conversations); /search more shows the next page
//	/purge here|all <days> [files]   permanently remove the messages (or
//	                 only their files) older than that many days, in the
//	                 conversation being looked at or in all of them (if you have permission)
//	/typing [id]     tell the conversation (or the thread) that you are typing
//	/dm <name> [text]       look at the DMs with someone (by username or
//	                        display name) and write to them first if there is text;
//	                        /say, /older and /newer then apply to that DM
//	                        until you use /view
//	/buddies                list your buddies and your DMs
//	/buddy <name>, /unbuddy <name>   add or remove a buddy
//	/file <name> <file>     offer a file in a DM (archives, pictures and
//	                        videos; the other person has to be online)
//	/accept, /decline       answer every file offer that is waiting for an answer
//	/cancel                 stop every file transfer
//	/seen <name>            ask when someone was last on the server
start_command_reader :: proc(q: ^conn.Command_Queue) {
	thread.create_and_start_with_poly_data(
		q,
		read_commands,
		init_context = context,
		self_cleanup = true,
	)
}

@(private = "file")
read_commands :: proc(q: ^conn.Command_Queue) {
	sc: bufio.Scanner
	bufio.scanner_init(&sc, os.to_reader(os.stdin))
	defer bufio.scanner_destroy(&sc)
	// Files attached for the next /say. Owned by this procedure.
	attached: [dynamic]string
	defer {
		for path in attached {
			delete(path)
		}
		delete(attached)
	}
	for bufio.scanner_scan(&sc) {
		line := strings.trim_space(bufio.scanner_text(&sc))
		switch {
		case line == "":
		case line == "/channels":
			conn.push_command(q, conn.List_Command{})
		case strings.has_prefix(line, "/name "):
			conn.push_command(
				q,
				conn.Display_Command{strings.clone(strings.trim_space(line[len("/name "):]))},
			)
		case line == "/email" || strings.has_prefix(line, "/email "):
			conn.push_command(
				q,
				conn.Email_Command{strings.clone(strings.trim_space(line[len("/email"):]))},
			)
		case strings.has_prefix(line, "/digest "):
			value := strings.trim_space(line[len("/digest "):])
			if _, ok := proto.email_digest_parse(value); !ok || value == "" {
				log.warn("/digest none|missed|mentions")
				break
			}
			conn.push_command(
				q,
				conn.Setting_Command {
					key = strings.clone(proto.SETTING_EMAIL_DIGEST),
					value = strings.clone("" if value == "none" else value),
				},
			)
		case strings.has_prefix(line, "/login "):
			username, _, password := strings.partition(
				strings.trim_space(line[len("/login "):]),
				" ",
			)
			conn.push_command(
				q,
				conn.Login_Command {
					username = strings.clone(username),
					password = strings.clone(password),
					device = strings.clone(platform.default_name()),
				},
			)
		case strings.has_prefix(line, "/register "):
			fields := strings.fields(line[len("/register "):], context.temp_allocator)
			if len(fields) < 2 {
				log.warn("/register <username> <password> [email] [invite]")
				break
			}
			email, invite := "", ""
			for f in fields[2:] {
				if strings.contains_rune(f, '@') {
					email = f
				} else {
					invite = f
				}
			}
			conn.push_command(
				q,
				conn.Register_Command {
					username = strings.clone(fields[0]),
					password = strings.clone(fields[1]),
					device = strings.clone(platform.default_name()),
					email = strings.clone(email),
					invite = strings.clone(invite),
				},
			)
		case line == "/invite" || strings.has_prefix(line, "/invite "):
			fields := strings.fields(line[len("/invite"):], context.temp_allocator)
			uses, days := 1, 0
			if len(fields) > 0 {
				uses, _ = strconv.parse_int(fields[0])
			}
			if len(fields) > 1 {
				days, _ = strconv.parse_int(fields[1])
			}
			expires: proto.Unix_Ms
			if days > 0 {
				expires =
					proto.Unix_Ms(time.time_to_unix_nano(time.now()) / 1e6) +
					proto.Unix_Ms(days * 24 * 60 * 60 * 1000)
			}
			conn.push_command(
				q,
				conn.Invite_Create_Command {
					max_uses = u16(clamp(uses, 0, proto.MAX_INVITE_USES)),
					expires = expires,
				},
			)
		case line == "/invites":
			conn.push_command(q, conn.Invites_Command{})
		case line == "/memory":
			log.infof("memory:\n%s", memtrack.log_text(memtrack.report(), context.temp_allocator))
		case line == "/server-memory":
			conn.push_command(q, conn.Server_Memory_Command{})
		case strings.has_prefix(line, "/uninvite "):
			conn.push_command(
				q,
				conn.Invite_Revoke_Command {
					strings.clone(strings.trim_space(line[len("/uninvite "):])),
				},
			)
		case line == "/logout":
			conn.push_command(q, conn.Logout_Command{})
		case strings.has_prefix(line, "/passwd "):
			old, _, new := strings.partition(strings.trim_space(line[len("/passwd "):]), " ")
			conn.push_command(
				q,
				conn.Password_Command{old = strings.clone(old), new = strings.clone(new)},
			)
		case line == "/devices":
			conn.push_command(q, conn.Devices_Command{})
		case strings.has_prefix(line, "/revoke "):
			if key, ok := common.parse_key_hex(strings.trim_space(line[len("/revoke "):])); ok {
				conn.push_command(q, conn.Revoke_Command{key})
			} else {
				log.warn("/revoke takes a device's key (64 hex digits)")
			}
		case strings.has_prefix(line, "/adduser "):
			username, _, rest := strings.partition(
				strings.trim_space(line[len("/adduser "):]),
				" ",
			)
			password, _, display := strings.partition(rest, " ")
			conn.push_command(
				q,
				conn.Account_Create_Command {
					username = strings.clone(username),
					password = strings.clone(password),
					display = strings.clone(display),
				},
			)
		case strings.has_prefix(line, "/addbot "):
			username, _, display := strings.partition(
				strings.trim_space(line[len("/addbot "):]),
				" ",
			)
			conn.push_command(
				q,
				conn.Bot_Create_Command {
					username = strings.clone(username),
					display = strings.clone(display),
				},
			)
		case strings.has_prefix(line, "/bottoken "), strings.has_prefix(line, "/tokens "):
			_, _, rest := strings.partition(line, " ")
			id, ok := strconv.parse_uint(strings.trim_space(rest), 10)
			switch {
			case !ok || id == 0 || id > uint(max(u32)):
				log.warn("give the bot's account by its id")
			case strings.has_prefix(line, "/bottoken "):
				conn.push_command(q, conn.Bot_Token_Command{proto.Account_Id(id)})
			case:
				conn.push_command(q, conn.Devices_Command{proto.Account_Id(id)})
			}
		case strings.has_prefix(line, "/setpass "):
			username, _, password := strings.partition(
				strings.trim_space(line[len("/setpass "):]),
				" ",
			)
			conn.push_command(
				q,
				conn.Account_Password_Command {
					username = strings.clone(username),
					password = strings.clone(password),
				},
			)
		case line == "/listen" || line == "/unlisten":
			conn.push_command(q, conn.Listen_Command{line == "/listen"})
		case line == "/mute" || line == "/unmute":
			conn.push_command(q, conn.Mute_Command{muted = line == "/mute", feedback = true})
		case line == "/deafen" || line == "/undeafen":
			conn.push_command(
				q,
				conn.Deafen_Command{deafened = line == "/deafen", feedback = true},
			)
		case line == "/typing":
			conn.push_command(q, conn.Typing_Command{})
		case line == "/status", strings.has_prefix(line, "/status "):
			rest := strings.trim_space(line[len("/status"):])
			first, _, text := strings.partition(rest, " ")
			until: proto.Unix_Ms
			if minutes, ok := strconv.parse_u64(first); ok {
				if minutes > 0 {
					until =
						proto.Unix_Ms(time.time_to_unix_nano(time.now()) / 1e6) +
						proto.Unix_Ms(minutes * 60 * 1000)
				}
			} else {
				text = rest
			}
			conn.push_command(
				q,
				conn.Status_Command{text = strings.clone(strings.trim_space(text)), until = until},
			)
		case strings.has_prefix(line, "/avatar "):
			if img, ok := imaging.avatar_load(strings.trim_space(line[len("/avatar "):])); ok {
				conn.push_command(q, conn.Avatar_Command{image = img})
			}
		case line == "/noavatar":
			conn.push_command(q, conn.Avatar_Command{remove = true})
		case strings.has_prefix(line, "/set "):
			key, _, value := strings.partition(strings.trim_space(line[len("/set "):]), " ")
			conn.push_command(
				q,
				conn.Setting_Command{key = strings.clone(key), value = strings.clone(value)},
			)
		case strings.has_prefix(line, "/unset "):
			conn.push_command(
				q,
				conn.Setting_Command {
					key = strings.clone(strings.trim_space(line[len("/unset "):])),
				},
			)
		case line == "/members":
			conn.push_command(q, conn.Members_Command{})
		case strings.has_prefix(line, "/call "):
			conn.push_command(
				q,
				conn.Call_Command{name = strings.clone(strings.trim_space(line[len("/call "):]))},
			)
		case line == "/answer":
			conn.push_command(q, conn.Call_Answer_Command{})
		case line == "/hangup":
			conn.push_command(q, conn.Call_Hangup_Command{})
		case line == "/cameras" || strings.has_prefix(line, "/cameras "):
			// Watching the cameras of these accounts (none: stop), for testing:
			// what arrives shows in the debug log's figures.
			conn.push_command(
				q,
				conn.Watch_Camera_Names_Command {
					names = strings.clone(strings.trim_space(line[len("/cameras"):])),
				},
			)
		case line == "/search more":
			conn.push_command(q, conn.Search_Command{more = true})
		case strings.has_prefix(line, "/search "):
			words := strings.trim_space(line[len("/search "):])
			all := strings.has_prefix(words, "all ")
			if all {
				words = strings.trim_space(words[len("all "):])
			}
			conn.push_command(q, conn.Search_Command{query = strings.clone(words), all = all})
		case strings.has_prefix(line, "/forward "):
			id_text, _, name := strings.partition(strings.trim_space(line[len("/forward "):]), " ")
			if id, ok := strconv.parse_u64(id_text); ok && strings.trim_space(name) != "" {
				conn.push_command(
					q,
					conn.Forward_Command {
						msg = proto.Msg_Id(id),
						name = strings.clone(strings.trim_space(name)),
					},
				)
			} else {
				log.warn("/forward <id> <channel>")
			}
		case strings.has_prefix(line, "/activity "):
			switch strings.trim_space(line[len("/activity "):]) {
			case "online":
				conn.push_command(q, conn.Activity_Command{activity = .Online})
			case "away":
				conn.push_command(q, conn.Activity_Command{activity = .Away})
			case "busy":
				conn.push_command(q, conn.Activity_Command{activity = .Busy})
			case "offline":
				conn.push_command(q, conn.Activity_Command{activity = .Offline})
			case:
				log.warn("/activity online|away|busy|offline")
			}
		case strings.has_prefix(line, "/purge "):
			fields := strings.fields(line[len("/purge "):], context.temp_allocator)
			days: f64
			days_ok: bool
			if len(fields) >= 2 {
				days, days_ok = strconv.parse_f64(fields[1])
			}
			if !days_ok || days < 0 || (fields[0] != "here" && fields[0] != "all") {
				log.warn("usage: /purge here|all <days> [pictures]")
				break
			}
			now := time.time_to_unix_nano(time.now()) / 1e6
			conn.push_command(
				q,
				conn.Purge_Command {
					all = fields[0] == "all",
					here = fields[0] == "here",
					before = proto.Unix_Ms(now - i64(days * 24 * 60 * 60 * 1000)),
					what = .Files if len(fields) > 2 && fields[2] == "files" else .Messages,
				},
			)
		case line == "/roles":
			conn.push_command(q, conn.Roles_Command{})
		case strings.has_prefix(line, "/mkrole "), strings.has_prefix(line, "/setrole "):
			_, _, rest := strings.partition(line, " ")
			name, _, perms := strings.partition(strings.trim_space(rest), " ")
			conn.push_command(
				q,
				conn.Role_Set_Command {
					name = strings.clone(name),
					perms = parse_perms(perms),
					by_name = strings.has_prefix(line, "/setrole "),
				},
			)
		case strings.has_prefix(line, "/delrole "):
			conn.push_command(
				q,
				conn.Role_Delete_Command {
					name = strings.clone(strings.trim_space(line[len("/delrole "):])),
				},
			)
		case strings.has_prefix(line, "/assign "):
			name, _, roles := strings.partition(strings.trim_space(line[len("/assign "):]), " ")
			conn.push_command(
				q,
				conn.Account_Roles_Command {
					name = strings.clone(name),
					role_names = strings.clone(roles),
				},
			)
		case strings.has_prefix(line, "/disable "), strings.has_prefix(line, "/enable "):
			_, _, name := strings.partition(line, " ")
			conn.push_command(
				q,
				conn.Account_Disable_Command {
					name = strings.clone(strings.trim_space(name)),
					on = strings.has_prefix(line, "/disable "),
				},
			)
		case strings.has_prefix(line, "/voicemove "):
			name, _, channel := strings.partition(
				strings.trim_space(line[len("/voicemove "):]),
				" ",
			)
			conn.push_command(
				q,
				conn.Voice_Move_Command {
					name = strings.clone(name),
					channel = strings.clone(strings.trim_space(channel)),
				},
			)
		case strings.has_prefix(line, "/voicekick "):
			conn.push_command(
				q,
				conn.Voice_Move_Command {
					name = strings.clone(strings.trim_space(line[len("/voicekick "):])),
				},
			)
		case strings.has_prefix(line, "/servermute "), strings.has_prefix(line, "/serverunmute "):
			_, _, name := strings.partition(line, " ")
			conn.push_command(
				q,
				conn.Voice_Mute_Command {
					name = strings.clone(strings.trim_space(name)),
					on = strings.has_prefix(line, "/servermute "),
				},
			)
		case strings.has_prefix(line, "/ban "):
			name, _, reason := strings.partition(strings.trim_space(line[len("/ban "):]), " ")
			conn.push_command(
				q,
				conn.Ban_Command {
					name = strings.clone(name),
					on = true,
					reason = strings.clone(strings.trim_space(reason)),
				},
			)
		case strings.has_prefix(line, "/banpurge "):
			fields := strings.fields(line[len("/banpurge "):], context.temp_allocator)
			purge := proto.Ban_Purge.None
			if len(fields) >= 2 {
				switch fields[1] {
				case "hour":
					purge = .Hour
				case "day":
					purge = .Day
				case "week":
					purge = .Week
				case "all":
					purge = .All
				}
			}
			if purge == .None {
				log.warn("usage: /banpurge <name> hour|day|week|all [reason]")
				break
			}
			_, _, rest := strings.partition(strings.trim_space(line[len("/banpurge "):]), " ")
			_, _, reason := strings.partition(strings.trim_space(rest), " ")
			conn.push_command(
				q,
				conn.Ban_Command {
					name = strings.clone(fields[0]),
					on = true,
					purge = purge,
					reason = strings.clone(strings.trim_space(reason)),
				},
			)
		case strings.has_prefix(line, "/purgeuser "):
			fields := strings.fields(line[len("/purgeuser "):], context.temp_allocator)
			days := 0
			days_ok := true
			if len(fields) > 1 {
				days, days_ok = strconv.parse_int(fields[1], 10)
			}
			if len(fields) == 0 || !days_ok || days < 0 {
				log.warn("usage: /purgeuser <name> [days]")
				break
			}
			since: proto.Unix_Ms
			if days > 0 {
				now := time.time_to_unix_nano(time.now()) / 1e6
				since = proto.Unix_Ms(now - i64(days * 24 * 60 * 60 * 1000))
			}
			conn.push_command(
				q,
				conn.Purge_Command{all = true, name = strings.clone(fields[0]), since = since},
			)
		case strings.has_prefix(line, "/unban "):
			conn.push_command(
				q,
				conn.Ban_Command{name = strings.clone(strings.trim_space(line[len("/unban "):]))},
			)
		case line == "/bans":
			conn.push_command(q, conn.Bans_Command{})
		case strings.has_prefix(line, "/deluser "):
			conn.push_command(
				q,
				conn.Account_Delete_Command {
					name = strings.clone(strings.trim_space(line[len("/deluser "):])),
				},
			)
		case strings.has_prefix(line, "/deleteme "):
			conn.push_command(
				q,
				conn.Account_Delete_Command {
					own = true,
					password = strings.clone(strings.trim_space(line[len("/deleteme "):])),
				},
			)
		case strings.has_prefix(line, "/private "):
			conn.push_command(
				q,
				conn.Create_Channel_Command {
					name = strings.clone(strings.trim_space(line[len("/private "):])),
					private = true,
				},
			)
		case strings.has_prefix(line, "/rename "):
			conn.push_command(
				q,
				conn.Conv_Update_Command {
					mask = proto.CONV_UPDATE_NAME,
					name = strings.clone(strings.trim_space(line[len("/rename "):])),
				},
			)
		case strings.has_prefix(line, "/topic "):
			conn.push_command(
				q,
				conn.Conv_Update_Command {
					mask = proto.CONV_UPDATE_TOPIC,
					topic = strings.clone(strings.trim_space(line[len("/topic "):])),
				},
			)
		case strings.has_prefix(line, "/move "):
			if n, ok := strconv.parse_int(strings.trim_space(line[len("/move "):])); ok {
				conn.push_command(
					q,
					conn.Conv_Update_Command{mask = proto.CONV_UPDATE_POSITION, position = n},
				)
			}
		case line == "/archive":
			conn.push_command(q, conn.Conv_Delete_Command{})
		case strings.has_prefix(line, "/default "), strings.has_prefix(line, "/textonly "):
			cmd, _, value := strings.partition(line, " ")
			value = strings.trim_space(value)
			if value != "on" && value != "off" {
				log.warnf("%s on|off", cmd)
				break
			}
			conn.push_command(
				q,
				conn.Conv_Flag_Command {
					flag = .Default if cmd == "/default" else .Text_Only,
					on = value == "on",
				},
			)
		case line == "/rights":
			conn.push_command(q, conn.Conv_Rights_Get_Command{})
		case strings.has_prefix(line, "/rights "):
			conn.push_command(
				q,
				conn.Conv_Rights_Text_Command {
					text = strings.clone(strings.trim_space(line[len("/rights "):])),
				},
			)
		case strings.has_prefix(line, "/invite "), strings.has_prefix(line, "/kick "):
			_, _, name := strings.partition(line, " ")
			conn.push_command(
				q,
				conn.Conv_Member_Command {
					name = strings.clone(strings.trim_space(name)),
					on = strings.has_prefix(line, "/invite "),
				},
			)
		case strings.has_prefix(line, "/typing "):
			if n, ok := strconv.parse_u64(strings.trim_space(line[len("/typing "):])); ok {
				conn.push_command(q, conn.Typing_Command{thread = {root = proto.Msg_Id(n)}})
			}
		case strings.has_prefix(line, "/thread "), strings.has_prefix(line, "/unthread "):
			_, _, id := strings.partition(line, " ")
			if n, ok := strconv.parse_u64(strings.trim_space(id)); ok {
				conn.push_command(
					q,
					conn.Thread_Command {
						thread = {root = proto.Msg_Id(n)},
						open = strings.has_prefix(line, "/thread "),
					},
				)
			}
		case strings.has_prefix(line, "/reply "):
			id, _, text := strings.partition(strings.trim_space(line[len("/reply "):]), " ")
			if n, ok := strconv.parse_u64(id); ok {
				conn.push_command(
					q,
					conn.Chat_Command {
						text = typed_lines(text),
						thread = {root = proto.Msg_Id(n)},
						typed = true,
					},
				)
			}
		case strings.has_prefix(line, "/file "):
			rest := strings.trim_space(line[len("/file "):])
			to, _, path := strings.partition(rest, " ")
			conn.push_command(
				q,
				conn.Send_File_Command {
					name = strings.clone(to),
					path = strings.clone(strings.trim_space(path)),
				},
			)
		case line == "/accept" || line == "/decline" || line == "/cancel":
			// The network loop answers this because it has the offers. An id
			// of 0 means all of them.
			action := conn.File_Action.Accept
			switch line {
			case "/decline":
				action = .Decline
			case "/cancel":
				action = .Cancel
			}
			conn.push_command(q, conn.File_Action_Command{action = action})
		case strings.has_prefix(line, "/seen "):
			conn.push_command(
				q,
				conn.Last_Seen_Command {
					name = strings.clone(strings.trim_space(line[len("/seen "):])),
				},
			)
		case line == "/buddies":
			conn.push_command(q, conn.Buddies_Command{})
		case strings.has_prefix(line, "/buddy "), strings.has_prefix(line, "/unbuddy "):
			_, _, name := strings.partition(line, " ")
			conn.push_command(
				q,
				conn.Buddy_Command {
					name = strings.clone(strings.trim_space(name)),
					on = strings.has_prefix(line, "/buddy "),
				},
			)
		case strings.has_prefix(line, "/dm "):
			to, _, text := strings.partition(strings.trim_space(line[len("/dm "):]), " ")
			conn.push_command(
				q,
				conn.DM_Command{name = strings.clone(to), text = typed_lines(text)},
			)
		case strings.has_prefix(line, "/say "):
			text := line[len("/say "):]
			if len(attached) == 0 {
				conn.push_command(q, conn.Chat_Command{text = typed_lines(text), typed = true})
				break
			}
			files := make([]conn.Attach_File, len(attached))
			for path, i in attached {
				files[i] = {
					path = path,
				}
			}
			clear(&attached)
			conn.push_command(
				q,
				conn.Attach_Send_Command{text = typed_lines(text), files = files, typed = true},
			)
		case strings.has_prefix(line, "/attach "):
			path := strings.trim_space(line[len("/attach "):])
			if len(attached) >= proto.MAX_ATTACHMENTS {
				log.warn("a message can carry at most 10 files")
				break
			}
			append(&attached, strings.clone(path))
			log.infof("%d file(s) attached to the next /say", len(attached))
		case line == "/unattach":
			for path in attached {
				delete(path)
			}
			clear(&attached)
		case strings.has_prefix(line, "/save "):
			id, _, n := strings.partition(strings.trim_space(line[len("/save "):]), " ")
			msg, id_ok := strconv.parse_u64(id)
			index, n_ok := strconv.parse_int(strings.trim_space(n))
			if id_ok && n_ok && index >= 1 {
				conn.push_command(
					q,
					conn.Attach_Save_Command{msg = proto.Msg_Id(msg), index = index - 1},
				)
			}
		case strings.has_prefix(line, "/edit "):
			id, _, text := strings.partition(strings.trim_space(line[len("/edit "):]), " ")
			if n, ok := strconv.parse_u64(id); ok {
				conn.push_command(
					q,
					conn.Edit_Command {
						id = proto.Msg_Id(n),
						text = typed_lines(text),
						typed = true,
					},
				)
			}
		case strings.has_prefix(line, "/delete "):
			if n, ok := strconv.parse_u64(strings.trim_space(line[len("/delete "):])); ok {
				conn.push_command(q, conn.Delete_Command{id = proto.Msg_Id(n)})
			}
		case strings.has_prefix(line, "/pin "), strings.has_prefix(line, "/unpin "):
			_, _, id := strings.partition(line, " ")
			if n, ok := strconv.parse_u64(strings.trim_space(id)); ok {
				conn.push_command(
					q,
					conn.Pin_Command{id = proto.Msg_Id(n), on = strings.has_prefix(line, "/pin ")},
				)
			}
		case strings.has_prefix(line, "/react "), strings.has_prefix(line, "/unreact "):
			_, _, rest := strings.partition(line, " ")
			id, _, emoji := strings.partition(strings.trim_space(rest), " ")
			if n, ok := strconv.parse_u64(id); ok {
				conn.push_command(
					q,
					conn.React_Command {
						id = proto.Msg_Id(n),
						emoji = strings.clone(strings.trim_space(emoji)),
						on = strings.has_prefix(line, "/react "),
						typed = true,
					},
				)
			}
		case line == "/pins":
			conn.push_command(q, conn.Pins_Command{})
		case strings.has_prefix(line, "/jump "):
			if n, ok := strconv.parse_u64(strings.trim_space(line[len("/jump "):])); ok {
				conn.push_command(q, conn.Jump_Command{id = proto.Msg_Id(n)})
			}
		case line == "/older" || line == "/newer":
			conn.push_command(q, conn.History_Command{newer = line == "/newer"})
		case strings.has_prefix(line, "/join "):
			conn.push_command(
				q,
				conn.Voice_Command{name = strings.clone(strings.trim_space(line[len("/join "):]))},
			)
		case line == "/leave":
			conn.push_command(q, conn.Voice_Command{})
		case strings.has_prefix(line, "/view "):
			conn.push_command(
				q,
				conn.View_Command{name = strings.clone(strings.trim_space(line[len("/view "):]))},
			)
		case strings.has_prefix(line, "/notify "):
			name, _, level := strings.partition(strings.trim_space(line[len("/notify "):]), " ")
			notify: proto.Notify_Level
			switch strings.trim_space(level) {
			case "all":
				notify = .All
			case "mentions":
				notify = .Mentions
			case "none":
				notify = .None
			case:
				log.warn("/notify <channel> all|mentions|none")
				continue
			}
			conn.push_command(q, conn.Notify_Command{name = strings.clone(name), notify = notify})
		case line == "/browse more":
			conn.push_command(q, conn.Browse_Command{more = true})
		case line == "/browse", strings.has_prefix(line, "/browse "):
			conn.push_command(
				q,
				conn.Browse_Command {
					query = strings.clone(strings.trim_space(line[len("/browse"):])),
				},
			)
		case strings.has_prefix(line, "/subscribe "), strings.has_prefix(line, "/unsubscribe "):
			_, _, name := strings.partition(line, " ")
			conn.push_command(
				q,
				conn.Subscribe_Command {
					name = strings.clone(strings.trim_space(name)),
					on = strings.has_prefix(line, "/subscribe "),
				},
			)
		case strings.has_prefix(line, "/create "):
			name, _, topic := strings.partition(strings.trim_space(line[len("/create "):]), " ")
			conn.push_command(
				q,
				conn.Create_Channel_Command {
					name = strings.clone(name),
					topic = strings.clone(topic),
				},
			)
		case:
			log.warn(
				"commands: /channels, /notify <channel> all|mentions|none, /view <channel>, /join <channel>, /leave, /browse, /subscribe <channel>, /unsubscribe <channel>, /create <channel> [topic], /default on|off, /textonly on|off, /rights [<role>=<right,...> ...], /name <name>, /login <username> <password>, /logout, /passwd <old> <new>, /devices, /revoke <key>, /adduser <username> <password> [name], /setpass <username> <password>, /addbot <username> [name], /bottoken <account>, /tokens <account>, /mute, /unmute, /deafen, /undeafen, /listen, /unlisten, /say <text>, /attach <file>, /unattach, /save <id> <n>, /older, /newer, /edit <id> <text>, /delete <id>, /pin <id>, /unpin <id>, /pins, /jump <id>, /react <id> <emoji>, /unreact <id> <emoji>, /typing, /dm <name> [text], /buddies, /buddy <name>, /unbuddy <name>, /file <name> <file>, /accept, /decline, /cancel, /seen <name>",
			)
		}
	}
}

// typed_lines returns a copy of a message's text with each literal `\n`
// replaced by a newline, so the message can be typed on one line.
@(private = "file")
typed_lines :: proc(text: string) -> string {
	out, allocated := strings.replace_all(text, "\\n", "\n")
	return out if allocated else strings.clone(text)
}

// parse_perms parses a comma-separated list of permission names, as taken by
// /mkrole. Unknown names are logged as warnings and left out.
@(private = "file")
parse_perms :: proc(text: string) -> (perms: proto.Permissions) {
	rest := text
	outer: for raw in strings.split_iterator(&rest, ",") {
		name := strings.trim_space(raw)
		if name == "" {
			continue
		}
		for p in proto.Permission {
			if strings.equal_fold(fmt.tprint(p), name) {
				perms += {p}
				continue outer
			}
		}
		log.warnf("there is no permission called %q", name)
	}
	return
}

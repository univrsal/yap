#+build !wasi
package client

import log "common:wlog"
import "core:bufio"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:thread"
import "core:time"
import "client:settings"
import "client:conn"
import "client:platform"
import "common:proto"

/*
Headless mode reads commands from stdin on a separate thread, so the
network loop never blocks on input.

	/channels        list your channels, what's unread in them, and who is
	                 talking in them (the channel being looked at is read)
	/notify <channel> all|mentions|none   how much a channel may interrupt
	/view <channel>  look at a channel: its chat is the one shown, and
	                 where /say goes
	/join <channel>  join a channel's voice room
	/leave           leave the voice room
	/browse [text]   list the channels there are to subscribe to (with
	                 that in their name or topic); /browse more lists
	                 the next page
	/subscribe <channel>, /unsubscribe <channel>
	/create <channel> [topic]   make a channel (for who may)
	/name <name>     change what your account is called
	/login <username> <password>   log in, if the server asks for it
	/logout          log this device out
	/passwd <old> <new>   change your password
	/devices         list your account's devices
	/revoke <key>    log one of them out (64 hex digits, as /devices shows)
	/adduser <username> <password> [name]   make an account (admins)
	/setpass <username> <password>          give one a new password (admins)
	/mute, /unmute   stop or resume sending voice
	/deafen, /undeafen  stop or resume playing everyone else
	/listen, /unlisten  hear your own processed voice (listen back)
	/say <text>      post to the conversation being looked at (@username
	                 mentions someone)
	/older, /newer   fetch the page of its messages before (or after) those
	                 fetched so far
	/edit <id> <text>  change a message of yours (ids are in the log: #id)
	/delete <id>     delete a message (yours, or anyone's if you may)
	/pin <id>, /unpin <id>  pin or unpin a message
	/pins            list the pinned messages of the conversation
	/jump <id>       fetch the page around a message
	/react <id> <emoji>, /unreact <id> <emoji>   react to a message with an
	                 emoji (a character, :shortcode: or :name:), or take it back
	/thread <id>, /unthread <id>  open a message's thread (its replies are
	                 fetched, and shown as they come), or close it
	/reply <id> <text>  reply in a message's thread (to a reply: its root's)
	/status [minutes] [text]  set your status, ending after that many
	                 minutes (0 or none: it doesn't); /status alone clears it
	/avatar <file>   make your picture of an image file; /noavatar removes it
	/set <key> <value>, /unset <key>  change one of your account's settings
	/members         list the members of the conversation being looked at
	/roles           list the server's roles and who has them
	/mkrole <name> [perm,...], /setrole <name> [perm,...], /delrole <name>
	                 make, change or delete a role (perms by name, e.g.
	                 Invite,Pin_Messages)
	/assign <name> [role,...]  give someone exactly these roles
	/disable <name>, /enable <name>  stop someone logging in, or let them
	/private <name>  make a private channel
	/rename <name>, /topic <text>, /move <position>, /archive   change or
	                 delete the channel being looked at
	/invite <name>, /kick <name>  add someone to the channel being looked
	                 at, or take them out of a private one
	/call <name>     call someone; /answer a call ringing in; /hangup ends
	                 (or cancels, or declines) the call
	/activity online|away|busy|offline   what to be, on all your devices
	/forward <id> <channel>   forward a message to one of your channels
	/search [all] <words>     search the conversation looked at (or all
	                 of yours); /search more for the next page
	/purge here|all <days> [pictures]   remove for good the messages (or
	                 only the pictures) older than that many days, of the
	                 conversation being looked at or of all (for who may)
	/send <file>     post an image file (scaled and compressed first)
	/typing [id]     tell the conversation (or the thread) you're typing
	/poke <name> [message]  poke someone (see src/common/proto/poke.odin)
	/dm <name> [text]       look at the DMs with someone (their username or
	                        name), writing to them first if there's text;
	                        /say, /send, /older and /newer go there then,
	                        until /view
	/buddies                list your buddies and your DMs
	/buddy <name>, /unbuddy <name>   add or remove a buddy
	/file <name> <file>     offer a file in a DM (archives, pictures and
	                        videos; they have to be here)
	/accept, /decline       answer every file offer waiting for an answer
	/cancel                 stop every file transfer
	/seen <name>            ask when someone was last on the server
*/
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
	for bufio.scanner_scan(&sc) {
		line := strings.trim_space(bufio.scanner_text(&sc))
		switch {
		case line == "":
		case line == "/channels":
			conn.push_command(q, conn.List_Command{})
		case strings.has_prefix(line, "/name "):
			conn.push_command(q, conn.Display_Command{strings.clone(strings.trim_space(line[len("/name "):]))})
		case strings.has_prefix(line, "/login "):
			username, _, password := strings.partition(strings.trim_space(line[len("/login "):]), " ")
			conn.push_command(
				q,
				conn.Login_Command {
					username = strings.clone(username),
					password = strings.clone(password),
					device = strings.clone(platform.default_name()),
				},
			)
		case line == "/logout":
			conn.push_command(q, conn.Logout_Command{})
		case strings.has_prefix(line, "/passwd "):
			old, _, new := strings.partition(strings.trim_space(line[len("/passwd "):]), " ")
			conn.push_command(q, conn.Password_Command{old = strings.clone(old), new = strings.clone(new)})
		case line == "/devices":
			conn.push_command(q, conn.Devices_Command{})
		case strings.has_prefix(line, "/revoke "):
			if key, ok := settings.parse_key_hex(strings.trim_space(line[len("/revoke "):])); ok {
				conn.push_command(q, conn.Revoke_Command{key})
			} else {
				log.warn("/revoke takes a device's key (64 hex digits)")
			}
		case strings.has_prefix(line, "/adduser "):
			username, _, rest := strings.partition(strings.trim_space(line[len("/adduser "):]), " ")
			password, _, display := strings.partition(rest, " ")
			conn.push_command(
				q,
				conn.Account_Create_Command {
					username = strings.clone(username),
					password = strings.clone(password),
					display = strings.clone(display),
				},
			)
		case strings.has_prefix(line, "/setpass "):
			username, _, password := strings.partition(strings.trim_space(line[len("/setpass "):]), " ")
			conn.push_command(
				q,
				conn.Account_Password_Command{username = strings.clone(username), password = strings.clone(password)},
			)
		case line == "/listen" || line == "/unlisten":
			conn.push_command(q, conn.Listen_Command{line == "/listen"})
		case line == "/mute" || line == "/unmute":
			conn.push_command(q, conn.Mute_Command{muted = line == "/mute", feedback = true})
		case line == "/deafen" || line == "/undeafen":
			conn.push_command(q, conn.Deafen_Command{deafened = line == "/deafen", feedback = true})
		case line == "/typing":
			conn.push_command(q, conn.Typing_Command{})
		case line == "/status", strings.has_prefix(line, "/status "):
			rest := strings.trim_space(line[len("/status"):])
			first, _, text := strings.partition(rest, " ")
			until: proto.Unix_Ms
			if minutes, ok := strconv.parse_u64(first); ok {
				if minutes > 0 {
					until = proto.Unix_Ms(time.time_to_unix_nano(time.now()) / 1e6) + proto.Unix_Ms(minutes * 60 * 1000)
				}
			} else {
				text = rest
			}
			conn.push_command(q, conn.Status_Command{text = strings.clone(strings.trim_space(text)), until = until})
		case strings.has_prefix(line, "/avatar "):
			if image, ok := avatar_load(strings.trim_space(line[len("/avatar "):])); ok {
				conn.push_command(q, conn.Avatar_Command{image = image})
			}
		case line == "/noavatar":
			conn.push_command(q, conn.Avatar_Command{remove = true})
		case strings.has_prefix(line, "/set "):
			key, _, value := strings.partition(strings.trim_space(line[len("/set "):]), " ")
			conn.push_command(q, conn.Setting_Command{key = strings.clone(key), value = strings.clone(value)})
		case strings.has_prefix(line, "/unset "):
			conn.push_command(q, conn.Setting_Command{key = strings.clone(strings.trim_space(line[len("/unset "):]))})
		case line == "/members":
			conn.push_command(q, conn.Members_Command{})
		case strings.has_prefix(line, "/call "):
			conn.push_command(q, conn.Call_Command{name = strings.clone(strings.trim_space(line[len("/call "):]))})
		case line == "/answer":
			conn.push_command(q, conn.Call_Answer_Command{})
		case line == "/hangup":
			conn.push_command(q, conn.Call_Hangup_Command{})
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
				conn.push_command(q, conn.Forward_Command{msg = proto.Msg_Id(id), name = strings.clone(strings.trim_space(name))})
			} else {
				log.warn("/forward <id> <channel>")
			}
		case strings.has_prefix(line, "/activity "):
			switch strings.trim_space(line[len("/activity "):]) {
			case "online":
				conn.push_command(q, conn.Activity_Command{.Online})
			case "away":
				conn.push_command(q, conn.Activity_Command{.Away})
			case "busy":
				conn.push_command(q, conn.Activity_Command{.Busy})
			case "offline":
				conn.push_command(q, conn.Activity_Command{.Offline})
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
			conn.push_command(q, conn.Purge_Command{
				all    = fields[0] == "all",
				here   = fields[0] == "here",
				before = proto.Unix_Ms(now - i64(days * 24 * 60 * 60 * 1000)),
				what   = .Images if len(fields) > 2 && fields[2] == "pictures" else .Messages,
			})
		case line == "/roles":
			conn.push_command(q, conn.Roles_Command{})
		case strings.has_prefix(line, "/mkrole "), strings.has_prefix(line, "/setrole "):
			_, _, rest := strings.partition(line, " ")
			name, _, perms := strings.partition(strings.trim_space(rest), " ")
			conn.push_command(q, conn.Role_Set_Command{name = strings.clone(name), perms = parse_perms(perms), by_name = strings.has_prefix(line, "/setrole ")})
		case strings.has_prefix(line, "/delrole "):
			conn.push_command(q, conn.Role_Delete_Command{name = strings.clone(strings.trim_space(line[len("/delrole "):]))})
		case strings.has_prefix(line, "/assign "):
			name, _, roles := strings.partition(strings.trim_space(line[len("/assign "):]), " ")
			conn.push_command(q, conn.Account_Roles_Command{name = strings.clone(name), role_names = strings.clone(roles)})
		case strings.has_prefix(line, "/disable "), strings.has_prefix(line, "/enable "):
			_, _, name := strings.partition(line, " ")
			conn.push_command(q, conn.Account_Disable_Command{name = strings.clone(strings.trim_space(name)), on = strings.has_prefix(line, "/disable ")})
		case strings.has_prefix(line, "/private "):
			conn.push_command(q, conn.Create_Channel_Command{name = strings.clone(strings.trim_space(line[len("/private "):])), private = true})
		case strings.has_prefix(line, "/rename "):
			conn.push_command(q, conn.Conv_Update_Command{mask = proto.CONV_UPDATE_NAME, name = strings.clone(strings.trim_space(line[len("/rename "):]))})
		case strings.has_prefix(line, "/topic "):
			conn.push_command(q, conn.Conv_Update_Command{mask = proto.CONV_UPDATE_TOPIC, topic = strings.clone(strings.trim_space(line[len("/topic "):]))})
		case strings.has_prefix(line, "/move "):
			if n, ok := strconv.parse_int(strings.trim_space(line[len("/move "):])); ok {
				conn.push_command(q, conn.Conv_Update_Command{mask = proto.CONV_UPDATE_POSITION, position = n})
			}
		case line == "/archive":
			conn.push_command(q, conn.Conv_Delete_Command{})
		case strings.has_prefix(line, "/invite "), strings.has_prefix(line, "/kick "):
			_, _, name := strings.partition(line, " ")
			conn.push_command(q, conn.Conv_Member_Command{name = strings.clone(strings.trim_space(name)), on = strings.has_prefix(line, "/invite ")})
		case strings.has_prefix(line, "/typing "):
			if n, ok := strconv.parse_u64(strings.trim_space(line[len("/typing "):])); ok {
				conn.push_command(q, conn.Typing_Command{thread = {root = proto.Msg_Id(n)}})
			}
		case strings.has_prefix(line, "/thread "), strings.has_prefix(line, "/unthread "):
			_, _, id := strings.partition(line, " ")
			if n, ok := strconv.parse_u64(strings.trim_space(id)); ok {
				conn.push_command(q, conn.Thread_Command{thread = {root = proto.Msg_Id(n)}, open = strings.has_prefix(line, "/thread ")})
			}
		case strings.has_prefix(line, "/reply "):
			id, _, text := strings.partition(strings.trim_space(line[len("/reply "):]), " ")
			if n, ok := strconv.parse_u64(id); ok {
				conn.push_command(q, conn.Chat_Command{text = strings.clone(text), thread = {root = proto.Msg_Id(n)}, typed = true})
			}
		case strings.has_prefix(line, "/send "):
			// Scaling and compressing happens here rather than on the
			// network loop, which has voice to carry.
			path := strings.trim_space(line[len("/send "):])
			if image, ok := image_load(path); ok {
				conn.push_command(q, conn.Chat_Image_Command{image = image})
			}
		case strings.has_prefix(line, "/poke "):
			rest := strings.trim_space(line[len("/poke "):])
			name, _, message := strings.partition(rest, " ")
			conn.push_command(
				q,
				conn.Poke_Command{name = strings.clone(name), message = strings.clone(message)},
			)
		case strings.has_prefix(line, "/file "):
			rest := strings.trim_space(line[len("/file "):])
			to, _, path := strings.partition(rest, " ")
			conn.push_command(
				q,
				conn.Send_File_Command{name = strings.clone(to), path = strings.clone(strings.trim_space(path))},
			)
		case line == "/accept" || line == "/decline" || line == "/cancel":
			// Answered on the network loop, which has the offers: an id
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
			conn.push_command(q, conn.Last_Seen_Command{name = strings.clone(strings.trim_space(line[len("/seen "):]))})
		case line == "/buddies":
			conn.push_command(q, conn.Buddies_Command{})
		case strings.has_prefix(line, "/buddy "), strings.has_prefix(line, "/unbuddy "):
			_, _, name := strings.partition(line, " ")
			conn.push_command(
				q,
				conn.Buddy_Command{name = strings.clone(strings.trim_space(name)), on = strings.has_prefix(line, "/buddy ")},
			)
		case strings.has_prefix(line, "/dm "):
			to, _, text := strings.partition(strings.trim_space(line[len("/dm "):]), " ")
			conn.push_command(q, conn.DM_Command{name = strings.clone(to), text = strings.clone(text)})
		case strings.has_prefix(line, "/say "):
			conn.push_command(q, conn.Chat_Command{text = strings.clone(line[len("/say "):]), typed = true})
		case strings.has_prefix(line, "/edit "):
			id, _, text := strings.partition(strings.trim_space(line[len("/edit "):]), " ")
			if n, ok := strconv.parse_u64(id); ok {
				conn.push_command(q, conn.Edit_Command{id = proto.Msg_Id(n), text = strings.clone(text), typed = true})
			}
		case strings.has_prefix(line, "/delete "):
			if n, ok := strconv.parse_u64(strings.trim_space(line[len("/delete "):])); ok {
				conn.push_command(q, conn.Delete_Command{id = proto.Msg_Id(n)})
			}
		case strings.has_prefix(line, "/pin "), strings.has_prefix(line, "/unpin "):
			_, _, id := strings.partition(line, " ")
			if n, ok := strconv.parse_u64(strings.trim_space(id)); ok {
				conn.push_command(q, conn.Pin_Command{id = proto.Msg_Id(n), on = strings.has_prefix(line, "/pin ")})
			}
		case strings.has_prefix(line, "/react "), strings.has_prefix(line, "/unreact "):
			_, _, rest := strings.partition(line, " ")
			id, _, emoji := strings.partition(strings.trim_space(rest), " ")
			if n, ok := strconv.parse_u64(id); ok {
				conn.push_command(q, conn.React_Command{id = proto.Msg_Id(n), emoji = strings.clone(strings.trim_space(emoji)), on = strings.has_prefix(line, "/react "), typed = true})
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
			conn.push_command(q, conn.Voice_Command{name = strings.clone(strings.trim_space(line[len("/join "):]))})
		case line == "/leave":
			conn.push_command(q, conn.Voice_Command{})
		case strings.has_prefix(line, "/view "):
			conn.push_command(q, conn.View_Command{name = strings.clone(strings.trim_space(line[len("/view "):]))})
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
			conn.push_command(q, conn.Browse_Command{query = strings.clone(strings.trim_space(line[len("/browse"):]))})
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
				conn.Create_Channel_Command{name = strings.clone(name), topic = strings.clone(topic)},
			)
		case:
			log.warn(
				"commands: /channels, /notify <channel> all|mentions|none, /view <channel>, /join <channel>, /leave, /browse, /subscribe <channel>, /unsubscribe <channel>, /create <channel> [topic], /name <name>, /login <username> <password>, /logout, /passwd <old> <new>, /devices, /revoke <key>, /adduser <username> <password> [name], /setpass <username> <password>, /mute, /unmute, /deafen, /undeafen, /listen, /unlisten, /say <text>, /older, /newer, /edit <id> <text>, /delete <id>, /pin <id>, /unpin <id>, /pins, /jump <id>, /react <id> <emoji>, /unreact <id> <emoji>, /send <file>, /typing, /poke <name> [message], /dm <name> [text], /buddies, /buddy <name>, /unbuddy <name>, /file <name> <file>, /accept, /decline, /cancel, /seen <name>",
			)
		}
	}
}

// parse_perms is permissions by name, comma separated, as /mkrole takes
// them; names that aren't one are warned of and left out.
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
		log.warnf("there's no permission called %q", name)
	}
	return
}

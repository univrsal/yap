#+build !wasi
package client

import "core:bufio"
import log "../common/wlog"
import "core:os"
import "core:strings"
import "core:thread"

/*
Headless mode reads commands from stdin on a separate thread, so the
network loop never blocks on input.

	/channels        list channels and who is in them
	/join <channel>  move to another channel
	/name <name>     change your name
	/mute, /unmute   stop or resume sending voice
	/deafen, /undeafen  stop or resume playing everyone else
	/listen, /unlisten  hear your own processed voice (listen back)
	/say <text>      post to the channel's text chat
	/send <file>     post an image file (scaled and compressed first)
	/typing          tell the channel you're typing
	/poke <name> [message]  poke someone (see src/proto/poke.odin)
	/dm <name|key> <text>   send a direct message: to someone online by
	                        name, or to anyone by their key (64 hex digits)
	/dmimage <name|key> <file>  send an image file in a direct message
	                        (they have to be online)
	/file <name|key> <file>  offer a file in a direct message (archives,
	                        pictures and videos; they have to be online)
	/accept, /decline       answer every file offer waiting for an answer
	/cancel                 stop every file transfer
	/seen <key>             ask when someone was last on the server
*/
start_command_reader :: proc(q: ^Command_Queue) {
	thread.create_and_start_with_poly_data(
		q,
		read_commands,
		init_context = context,
		self_cleanup = true,
	)
}

@(private = "file")
read_commands :: proc(q: ^Command_Queue) {
	sc: bufio.Scanner
	bufio.scanner_init(&sc, os.to_reader(os.stdin))
	defer bufio.scanner_destroy(&sc)
	for bufio.scanner_scan(&sc) {
		line := strings.trim_space(bufio.scanner_text(&sc))
		switch {
		case line == "":
		case line == "/channels":
			push_command(q, List_Command{})
		case strings.has_prefix(line, "/name "):
			push_command(q, Name_Command{strings.clone(strings.trim_space(line[len("/name "):]))})
		case line == "/listen" || line == "/unlisten":
			push_command(q, Listen_Command{line == "/listen"})
		case line == "/mute" || line == "/unmute":
			push_command(q, Mute_Command{muted = line == "/mute", feedback = true})
		case line == "/deafen" || line == "/undeafen":
			push_command(q, Deafen_Command{deafened = line == "/deafen", feedback = true})
		case line == "/typing":
			push_command(q, Typing_Command{})
		case strings.has_prefix(line, "/send "):
			// Scaling and compressing happens here rather than on the
			// network loop, which has voice to carry.
			path := strings.trim_space(line[len("/send "):])
			if image, ok := image_load(path); ok {
				push_command(q, Chat_Image_Command{image})
			}
		case strings.has_prefix(line, "/poke "):
			rest := strings.trim_space(line[len("/poke "):])
			name, _, message := strings.partition(rest, " ")
			push_command(q, Poke_Command{name = strings.clone(name), message = strings.clone(message)})
		case strings.has_prefix(line, "/file "):
			rest := strings.trim_space(line[len("/file "):])
			to, _, path := strings.partition(rest, " ")
			cmd := Send_File_Command {
				path = strings.clone(strings.trim_space(path)),
			}
			if key, is_key := parse_user_key(to); is_key {
				cmd.to = key
			} else {
				cmd.name = strings.clone(to)
			}
			push_command(q, cmd)
		case line == "/accept" || line == "/decline" || line == "/cancel":
			// Answered on the network loop, which has the offers: an id
			// of 0 means all of them.
			action := File_Action.Accept
			switch line {
			case "/decline":
				action = .Decline
			case "/cancel":
				action = .Cancel
			}
			push_command(q, File_Action_Command{action = action})
		case strings.has_prefix(line, "/seen "):
			if key, ok := parse_user_key(strings.trim_space(line[len("/seen "):])); ok {
				cmd := Last_Seen_Command {
					count = 1,
				}
				cmd.keys[0] = key
				push_command(q, cmd)
			} else {
				log.warn("/seen takes a key (64 hex digits)")
			}
		case strings.has_prefix(line, "/dmimage "):
			rest := strings.trim_space(line[len("/dmimage "):])
			to, _, path := strings.partition(rest, " ")
			image, ok := image_load(strings.trim_space(path))
			if !ok {
				continue
			}
			cmd := DM_Image_Command {
				image = image,
			}
			if key, is_key := parse_user_key(to); is_key {
				cmd.to = key
			} else {
				cmd.name = strings.clone(to)
			}
			push_command(q, cmd)
		case strings.has_prefix(line, "/dm "):
			rest := strings.trim_space(line[len("/dm "):])
			to, _, text := strings.partition(rest, " ")
			cmd := DM_Command {
				text = strings.clone(text),
			}
			if key, is_key := parse_user_key(to); is_key {
				cmd.to = key
			} else {
				cmd.name = strings.clone(to)
			}
			push_command(q, cmd)
		case strings.has_prefix(line, "/say "):
			push_command(q, Chat_Command{strings.clone(line[len("/say "):])})
		case strings.has_prefix(line, "/join "):
			push_command(q, Join_Command{strings.clone(strings.trim_space(line[len("/join "):]))})
		case:
			log.warn("commands: /channels, /join <channel>, /name <name>, /mute, /unmute, /deafen, /undeafen, /listen, /unlisten, /say <text>, /send <file>, /typing, /poke <name> [message], /dm <name|key> <text>, /dmimage <name|key> <file>, /file <name|key> <file>, /accept, /decline, /cancel, /seen <key>")
		}
	}
}

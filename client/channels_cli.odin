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
	/poke <name> [message]  poke someone (see proto/poke.odin)
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
			push_command(q, Mute_Command{line == "/mute"})
		case line == "/deafen" || line == "/undeafen":
			push_command(q, Deafen_Command{line == "/deafen"})
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
		case strings.has_prefix(line, "/say "):
			push_command(q, Chat_Command{strings.clone(line[len("/say "):])})
		case strings.has_prefix(line, "/join "):
			push_command(q, Join_Command{strings.clone(strings.trim_space(line[len("/join "):]))})
		case:
			log.warn("commands: /channels, /join <channel>, /name <name>, /mute, /unmute, /deafen, /undeafen, /listen, /unlisten, /say <text>, /send <file>, /typing, /poke <name> [message]")
		}
	}
}

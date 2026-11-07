package main

import "core:strconv"
import "core:strings"
import "core:sync"

import "client:conn"
import "client:script"
import "tui"

// The commands typed in the message box.

run_command :: proc(a: ^App, line: string) {
	name, _, rest := strings.partition(line[1:], " ")
	rest = strings.trim_space(rest)
	switch strings.to_lower(name, context.temp_allocator) {
	case "quit", "q", "exit":
		a.quit = true
	case "help", "h", "?":
		switch what := strings.trim_left(strings.to_lower(rest, context.temp_allocator), "/"); what {
		case "":
			dialog_close(a)
			a.dialog.kind = .Help
		case "commands", "all":
			show_output(a, commands_help())
		case:
			if d, ok := command_doc(what); ok {
				show_output(a, command_help(d^))
			} else {
				say(a, strings.concatenate({"There is no command /", what, ". /help commands lists them."}, context.temp_allocator), true)
			}
		}
	case "emoji":
		open_emoji_insert(a)
	case "settings":
		open_settings(a)
	case "call":
		if rest == "" {
			say(a, "Whom? /call <name>, or click someone in the member list or the Call button of a DM.", true)
			return
		}
		run_headless_command(a, line)
	case "mute":
		set_muted(a, true)
	case "unmute":
		set_muted(a, false)
	case "deafen":
		set_deafened(a, true)
	case "undeafen":
		set_deafened(a, false)
	case "voice":
		if rest == "" {
			toggle_voice(a)
		} else {
			leave_voice_elsewhere(a)
			push(a, conn.Voice_Command{name = strings.clone(strings.trim_left(rest, "#"))})
		}
	case "novoice":
		leave_voice(a)
	case "servers":
		show_output(a, servers_text(a))
	case "server":
		switch_to_server(a, rest)
	case "connect":
		address, _, password := strings.partition(rest, " ")
		if address == "" {
			say(a, "Which server? /connect host[:port] [password]", true)
			return
		}
		password = strings.trim_space(password)
		remember_server(a, address, password)
		append(&a.requests, Server_Request{kind = .Connect, address = strings.clone(address), password = strings.clone(password)})
	case "disconnect":
		index := a.cur
		if rest != "" {
			if i, ok := find_server(a, rest); ok {
				index = i
			} else {
				say(a, strings.concatenate({"There is no server ", rest, ". /servers lists them."}, context.temp_allocator), true)
				return
			}
		}
		disconnect_server(a, index)
	case "roles":
		open_info(a, .Roles)
	case "bans":
		open_info(a, .Bans)
	case "invites":
		open_info(a, .Invites)
	case "devices":
		open_info(a, .Devices)
	case "pins":
		open_list(a, .Pins)
	case "bookmarks":
		open_list(a, .Bookmarks)
	case "search", "s", "find":
		query, all := rest, false
		if strings.has_prefix(rest, "all ") || rest == "all" {
			query, all = strings.trim_space(rest[3:]), true
		}
		open_list(a, .Search)
		a.dialog.all = all
		tui.editor_set(&a.dialog.fields[0], query)
		run_search(a)
	case "join", "j", "channel":
		if rest == "" {
			say(a, "Which channel? /join <name>", true)
			return
		}
		push(a, conn.View_Command{name = strings.clone(strings.trim_left(rest, "#"))})
	case:
		// A /command that a script registered, else the headless client's.
		if a.scripts != nil && script.runtime_run_command(a.scripts, a.client, line, viewed_channel_name(a)) {
			return
		}
		if d, ok := command_doc(strings.to_lower(name, context.temp_allocator)); ok && missing_args(d^, rest) {
			say(a, strings.concatenate({"Usage: ", usage_line(d^), "  (/help ", d.name, " tells more)"}, context.temp_allocator), true)
			return
		}
		run_headless_command(a, line)
	}
}

// find_server finds a server by its number in /servers, or by (a part of) its name.
find_server :: proc(a: ^App, what: string) -> (int, bool) {
	if n, ok := strconv.parse_int(what); ok {
		return n - 1, n >= 1 && n <= len(a.servers)
	}
	lower := strings.to_lower(what, context.temp_allocator)
	for s, i in a.servers {
		name := server_name(a.view) if i == a.cur else s.target.server
		if i != a.cur {
			sync.mutex_lock(&s.view.mutex)
			name = strings.clone(server_name(s.view), context.temp_allocator)
			sync.mutex_unlock(&s.view.mutex)
		}
		if strings.contains(strings.to_lower(name, context.temp_allocator), lower) {
			return i, true
		}
	}
	return 0, false
}

@(private = "file")
switch_to_server :: proc(a: ^App, what: string) {
	if what == "" {
		show_output(a, servers_text(a))
		return
	}
	if i, ok := find_server(a, what); ok {
		app_switch(a, i)
	} else {
		say(a, strings.concatenate({"There is no server ", what, ". /servers lists them."}, context.temp_allocator), true)
	}
}


// disconnect_server leaves a server and forgets it, so that it is not connected
// to again at the next start.
disconnect_server :: proc(a: ^App, index: int) {
	if index < 0 || index >= len(a.servers) {
		return
	}
	forget_server(a, a.servers[index].target.server)
	append(&a.requests, Server_Request{kind = .Disconnect, index = index})
}

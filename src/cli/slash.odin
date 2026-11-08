package main

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"

import "client:conn"
import "client:script"
import "common:proto"
import "tui"

// The commands typed in the message box.

run_command :: proc(a: ^App, line: string) {
	name, _, rest := strings.partition(line[1:], " ")
	rest = strings.trim_space(rest)
	switch strings.to_lower(name, context.temp_allocator) {
	case "quit", "q", "exit":
		a.quit = true
	case "help", "h", "?":
		switch what := strings.trim_left(
			strings.to_lower(rest, context.temp_allocator),
			"/",
		); what {
		case "":
			dialog_close(a)
			a.dialog.kind = .Help
		case "commands", "all":
			show_output(a, commands_help())
		case:
			if d, ok := command_doc(what); ok {
				show_output(a, command_help(d^))
			} else {
				say(
					a,
					strings.concatenate(
						{"There is no command /", what, ". /help commands lists them."},
						context.temp_allocator,
					),
					true,
				)
			}
		}
	case "emoji":
		open_emoji_insert(a)
	case "settings":
		open_settings(a)
	case "call":
		if rest == "" {
			say(
				a,
				"Whom? /call <name>, or click someone in the member list or the Call button of a DM.",
				true,
			)
			return
		}
		run_headless_command(a, line)
	case "notify":
		run_notify(a, rest)
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
		append(
			&a.requests,
			Server_Request {
				kind = .Connect,
				address = strings.clone(address),
				password = strings.clone(password),
			},
		)
	case "disconnect":
		index := a.cur
		if rest != "" {
			if i, ok := find_server(a, rest); ok {
				index = i
			} else {
				say(
					a,
					strings.concatenate(
						{"There is no server ", rest, ". /servers lists them."},
						context.temp_allocator,
					),
					true,
				)
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
		if a.scripts != nil &&
		   script.runtime_run_command(a.scripts, a.client, line, viewed_channel_name(a)) {
			return
		}
		lower := strings.to_lower(name, context.temp_allocator)
		if !command_known(a, lower) {
			text := strings.concatenate(
				{"There is no command /", name, "."},
				context.temp_allocator,
			)
			if near, ok := closest_command(lower); ok {
				text = strings.concatenate(
					{text, " Did you mean /", near, "?"},
					context.temp_allocator,
				)
			}
			say(
				a,
				strings.concatenate({text, " /help commands lists them."}, context.temp_allocator),
				true,
			)
			return
		}
		if _, ours := command_doc(lower); !ours && is_bot_command(a, lower) {
			// (The headless client would add its list of commands to the answer.)
			push(a, conn.Bot_Run_Command{line = strings.clone(line), silent = true})
			return
		}
		if d, ok := command_doc(lower); ok && missing_args(d^, rest) {
			say(
				a,
				strings.concatenate(
					{"Usage: ", usage_line(d^), "  (/help ", d.name, " tells more)"},
					context.temp_allocator,
				),
				true,
			)
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
		say(
			a,
			strings.concatenate(
				{"There is no server ", what, ". /servers lists them."},
				context.temp_allocator,
			),
			true,
		)
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


// run_notify handles /notify: how much the conversation being looked at (or the
// channel that is named) may interrupt.
//
//	/notify                      say what it is now
//	/notify mentions             change it here
//	/notify general mentions     change it for another channel
@(private = "file")
run_notify :: proc(a: ^App, rest: string) {
	v := a.view
	words := strings.fields(rest, context.temp_allocator)
	here := viewed_name(a)
	switch len(words) {
	case 0:
		if v.viewing == 0 {
			say(a, "Look at a channel first, or: /notify <channel> all|mentions|none", true)
			return
		}
		say(
			a,
			fmt.tprintf(
				"Notifications for %s: %s. /notify all|mentions|none changes that.",
				here,
				notify_text(viewed_notify(v)),
			),
		)
	case 1:
		if level, ok := parse_notify(words[0]); ok {
			if v.viewing == 0 {
				say(a, "Look at a channel first, or: /notify <channel> all|mentions|none", true)
				return
			}
			push(a, conn.Notify_Command{conv = v.viewing, notify = level})
			say(a, fmt.tprintf("Notifications for %s: %s.", here, notify_text(level)))
		} else {
			say(
				a,
				fmt.tprintf("Usage: /notify [channel] all|mentions|none — not \"%s\"", words[0]),
				true,
			)
		}
	case:
		level, ok := parse_notify(words[len(words) - 1])
		if !ok {
			say(a, "Usage: /notify [channel] all|mentions|none", true)
			return
		}
		name := strings.trim_left(
			strings.join(words[:len(words) - 1], " ", context.temp_allocator),
			"#",
		)
		push(a, conn.Notify_Command{name = strings.clone(name), notify = level})
		say(a, fmt.tprintf("Notifications for #%s: %s.", name, notify_text(level)))
	}
}

@(private = "file")
parse_notify :: proc(word: string) -> (level: proto.Notify_Level, ok: bool) {
	switch strings.to_lower(word, context.temp_allocator) {
	case "all", "everything", "on":
		return .All, true
	case "mentions", "mention", "@":
		return .Mentions, true
	case "none", "off", "mute", "nothing":
		return .None, true
	}
	return
}

notify_text :: proc(level: proto.Notify_Level) -> string {
	switch level {
	case .All:
		return "every message"
	case .Mentions:
		return "only mentions of you"
	case .None:
		return "nothing"
	}
	return ""
}

// viewed_name is what the conversation being looked at is called: #general, or
// the person it is with.
viewed_name :: proc(a: ^App) -> string {
	if ch := conn.viewed_channel(a.view); ch != nil {
		return strings.concatenate({"#", ch.name}, context.temp_allocator)
	}
	if dm := viewed_dm(a.view); dm != nil {
		return conn.dm_name(a.view, dm)
	}
	return "this conversation"
}

// viewed_notify is the level set for the conversation being looked at.
viewed_notify :: proc(v: ^conn.View) -> proto.Notify_Level {
	if ch := conn.viewed_channel(v); ch != nil {
		return ch.notify
	}
	if dm := viewed_dm(v); dm != nil {
		return dm.notify
	}
	return .All
}

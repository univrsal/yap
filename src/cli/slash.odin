package main

import "core:strconv"
import "core:strings"
import "core:sync"

import "client:conn"
import "tui"

// The commands typed in the message box.

run_command :: proc(a: ^App, line: string) {
	name, _, rest := strings.partition(line[1:], " ")
	rest = strings.trim_space(rest)
	switch strings.to_lower(name, context.temp_allocator) {
	case "quit", "q", "exit":
		a.quit = true
	case "help", "h", "?":
		dialog_close(a)
		a.dialog.kind = .Help
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
		append(
			&a.requests,
			Server_Request{kind = .Connect, address = strings.clone(address), password = strings.clone(strings.trim_space(password))},
		)
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
		append(&a.requests, Server_Request{kind = .Disconnect, index = index})
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

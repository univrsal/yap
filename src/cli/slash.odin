package main

import "core:strings"

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

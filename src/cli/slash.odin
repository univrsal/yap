package main

import "core:strings"

import "client:conn"

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

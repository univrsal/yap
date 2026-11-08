package main

import "core:strings"

import "client:conn"
import "client:settings"

// Which servers the client connects to when it starts without one on the command
// line: those joined in the window client (its settings.json, only read), except
// those taken away here, and those added here with /connect. The additions and
// removals are in cli.json, so taking a server away does not change the window
// client, and the window client's list does not have to be edited to get rid of one.

// same_server says whether two addresses are the same server ("example.org" and
// "example.org:7777" are).
same_server :: proc(a, b: string) -> bool {
	return conn.with_default_port(a) == conn.with_default_port(b)
}

// merge_servers is the servers to connect to: the window client's joined ones
// that are not hidden, then the ones added here (that the window client does not
// have). The strings are in the temp allocator.
merge_servers :: proc(
	joined: []settings.Joined_Server,
	added: []Saved_Server,
	hidden: []string,
) -> []Saved_Server {
	out := make([dynamic]Saved_Server, context.temp_allocator)
	is_hidden :: proc(address: string, hidden: []string) -> bool {
		for h in hidden {
			if same_server(h, address) {
				return true
			}
		}
		return false
	}
	has :: proc(out: []Saved_Server, address: string) -> bool {
		for s in out {
			if same_server(s.address, address) {
				return true
			}
		}
		return false
	}
	for j in joined {
		if !is_hidden(j.address, hidden) && !has(out[:], j.address) {
			append(&out, Saved_Server{j.address, j.password, j.channel})
		}
	}
	for s in added {
		if !has(out[:], s.address) {
			append(&out, s)
		}
	}
	return out[:]
}

// remember_server adds a server to those connected to at the next start (and
// brings back one that was taken away), and saves.
remember_server :: proc(a: ^App, address, password: string) {
	for h, i in a.hidden {
		if same_server(h, address) {
			delete(h)
			ordered_remove(&a.hidden, i)
			break
		}
	}
	for &s in a.saved_servers {
		if same_server(s.address, address) {
			delete(s.password)
			s.password = strings.clone(password)
			cli_save_servers(a)
			return
		}
	}
	append(&a.saved_servers, Saved_Server{strings.clone(address), strings.clone(password), ""})
	cli_save_servers(a)
}

// forget_server takes a server away for good: from those added here, and if the
// window client has it, hides it. (It does not change the window client's list.)
forget_server :: proc(a: ^App, address: string) {
	for s, i in a.saved_servers {
		if same_server(s.address, address) {
			delete(s.address)
			delete(s.password)
			delete(s.channel)
			ordered_remove(&a.saved_servers, i)
			break
		}
	}
	for g in a.gui_joined {
		if same_server(g, address) {
			already := false
			for h in a.hidden {
				already ||= same_server(h, address)
			}
			if !already {
				append(&a.hidden, strings.clone(address))
			}
			break
		}
	}
	cli_save_servers(a)
}

// cli_save_servers writes the additions and removals to cli.json.
cli_save_servers :: proc(a: ^App) {
	if a.cli_path == "" {
		return
	}
	file := cli_file_load(a.cli_path)
	defer cli_file_destroy(&file)
	for s in file.servers {
		delete(s.address)
		delete(s.password)
		delete(s.channel)
	}
	clear(&file.servers)
	for s in a.saved_servers {
		append(
			&file.servers,
			Saved_Server {
				strings.clone(s.address),
				strings.clone(s.password),
				strings.clone(s.channel),
			},
		)
	}
	for h in file.hidden {
		delete(h)
	}
	clear(&file.hidden)
	for h in a.hidden {
		append(&file.hidden, strings.clone(h))
	}
	if !cli_file_save(a.cli_path, file) {
		say(a, "Could not save the list of servers.", true)
	}
}

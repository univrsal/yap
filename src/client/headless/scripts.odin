#+build !wasi
package headless

import "core:fmt"
import "core:strconv"
import "core:strings"

import "client:script"
import log "common:wlog"

// /script, the headless client's version of the Scripts page (see
// client/script). Scripts are approved with the permissions they ask for, and the
// command says what those are.
//
//	/script                      list the scripts
//	/script on <file>            switch a script on, allowing what it asks for
//	/script off <file>
//	/script reload               read the scripts again
//	/script settings <file>      a script's settings and their values
//	/script set <file> <key> <value>
//	/script servers <file> all|<address> ...   the servers it runs for
script_command :: proc(rt: ^script.Runtime, line: string) {
	args := strings.fields(line, context.temp_allocator)
	if len(args) == 1 {
		script_list(rt)
		return
	}
	switch args[1] {
	case "list":
		script_list(rt)
	case "reload":
		script.runtime_reload(rt)
		script_list(rt)
	case "on":
		if len(args) != 3 {
			log.warn("usage: /script on <file>")
			return
		}
		v, ok := script_view(rt, args[2])
		if !ok {
			log.warnf("there is no script %s", args[2])
			return
		}
		if err := script.runtime_set_enabled(rt, args[2], true, v.requested); err != "" {
			log.warnf("%s: %s", args[2], err)
		} else {
			log.infof("%s: on, allowed to: %s", args[2], permissions_text(v.requested))
		}
	case "off":
		if len(args) != 3 {
			log.warn("usage: /script off <file>")
			return
		}
		script.runtime_set_enabled(rt, args[2], false)
		log.infof("%s: off", args[2])
	case "settings":
		if len(args) != 3 {
			log.warn("usage: /script settings <file>")
			return
		}
		v, ok := script_view(rt, args[2])
		if !ok {
			log.warnf("there is no script %s", args[2])
			return
		}
		for s in v.settings {
			log.infof("%s: %s = %v (%v, %s)", v.file, s.def.key, s.value, s.def.type, s.def.label)
		}
	case "set":
		if len(args) < 5 {
			log.warn("usage: /script set <file> <key> <value>")
			return
		}
		v, ok := script_view(rt, args[2])
		if !ok {
			log.warnf("there is no script %s", args[2])
			return
		}
		text := strings.trim_space(line[strings.index(line, args[3]) + len(args[3]):])
		value: script.Value = text
		for s in v.settings {
			if s.def.key != args[3] {
				continue
			}
			switch s.def.type {
			case .Bool:
				value = text == "true" || text == "on" || text == "yes" || text == "1"
			case .Int:
				if n, parsed := strconv.parse_i64(text); parsed {
					value = n
				}
			case .Number:
				if n, parsed := strconv.parse_f64(text); parsed {
					value = n
				}
			case .String, .Choice:
			}
		}
		if err := script.runtime_set_value(rt, args[2], args[3], value); err != "" {
			log.warnf("%s: %s", args[2], err)
		} else {
			log.infof("%s: %s set", args[2], args[3])
		}
	case "servers":
		if len(args) < 4 {
			log.warn("usage: /script servers <file> all|<address> ...")
			return
		}
		if args[3] == "all" {
			script.runtime_set_scope(rt, args[2], true, nil)
		} else {
			script.runtime_set_scope(rt, args[2], false, args[3:])
		}
		log.infof("%s: runs for %s", args[2], "every server" if args[3] == "all" else strings.join(args[3:], ", ", context.temp_allocator))
	case:
		log.warn("commands: /script, /script on|off <file>, /script reload, /script settings <file>, /script set <file> <key> <value>, /script servers <file> all|<address> ...")
	}
}

@(private = "file")
script_view :: proc(rt: ^script.Runtime, file: string) -> (script.Item_View, bool) {
	for v in script.runtime_snapshot(rt) {
		if v.file == file {
			return v, true
		}
	}
	return {}, false
}

@(private = "file")
permissions_text :: proc(p: script.Permissions) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	if .Send in p {
		append(&parts, "send")
	}
	if .Notify in p {
		append(&parts, "notify")
	}
	if .Net in p {
		append(&parts, "net")
	}
	if len(parts) == 0 {
		return "nothing extra"
	}
	return strings.join(parts[:], ", ", context.temp_allocator)
}

@(private = "file")
script_list :: proc(rt: ^script.Runtime) {
	if ok, how := script.runtime_http_status(rt); ok {
		log.infof("web requests: available (%s)", how)
	} else {
		log.warnf("web requests: not available (%s)", how)
	}
	views := script.runtime_snapshot(rt)
	if len(views) == 0 {
		log.info("no scripts")
		return
	}
	for v in views {
		state := "off"
		switch {
		case v.running:
			state = "running"
		case v.changed:
			state = "changed since it was approved"
		case v.problem != "":
			state = fmt.tprintf("can't run: %s", v.problem)
		}
		log.infof("%s (%s): %s; asks for: %s", v.file, v.name, state, permissions_text(v.requested))
	}
}

package script

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"

import "client:conn"
import "common:."
import log "common:wlog"

// The scripts that run in the client, and what connects them to the servers:
// the connections attached to the runtime tell it what happens (conn/events.odin),
// and it starts the handlers of the scripts that run for that server, and does
// what the scripts ask of one (yap.send). It all happens in runtime_step, which
// the client calls once a frame (or once a turn of its loop when headless), on
// the thread that owns the runtime; nothing here waits for a script.
//
// Which scripts run, with what permissions and for which servers, is in
// <dir>/config.json:
//
//	{ "scripts": { "away.lua": { "enabled": true,
//	                             "permissions": ["send", "notify"],
//	                             "servers": ["chat.example.com:7777"] } } }
//
// "servers" are addresses as the client has them or server keys (hex); it
// is the user's choice, not the script's, and left out it means every server.
// A script that is not in the file does not run. <dir>/<name> is the script.

CONFIG_FILE :: "config.json"

// How long a script's own code may take to run when it is loaded, in all, and
// how often its store is saved if it has changed.
LOAD_TIME :: time.Second
SAVE_EVERY :: 5 * time.Second

Script_Config :: struct {
	enabled:     bool,
	permissions: []string,
	servers:     []string,
}

Config :: struct {
	scripts: map[string]Script_Config,
}

// A connection scripts hear from.
@(private)
Attached :: struct {
	id:   Server_Id,
	c:    ^conn.Server_Conn,
	sink: conn.Event_Sink,
}

@(private)
Entry :: struct {
	file:        string, // owned; also the script's name
	script:      ^Script,
	all_servers: bool,
	servers:     []string, // owned; the addresses or keys it runs for
	store_path:  string, // owned; "" if it isn't kept
	saved:       time.Tick,
}

Runtime :: struct {
	dir:      string, // owned
	host:     Host,
	attached: [dynamic]^Attached,
	entries:  [dynamic]Entry,
	next_id:  Server_Id,
	results:  [dynamic]Result,
	// For what is made while stepping, which is emptied at the start of the next.
	scratch:  runtime.Arena,
}

runtime_create :: proc(dir: string) -> ^Runtime {
	rt := new(Runtime)
	rt.dir = strings.clone(dir)
	rt.next_id = 1
	rt.host = Host {
		data          = rt,
		log           = host_log,
		send          = host_send,
		notify        = host_notify,
		server_by_key = host_server_by_key,
	}
	_ = runtime.arena_init(&rt.scratch, 256 * 1024, context.allocator)
	return rt
}

runtime_destroy :: proc(rt: ^Runtime) {
	if rt == nil {
		return
	}
	for &e in rt.entries {
		entry_save(&e, force = true)
		entry_destroy(&e)
	}
	delete(rt.entries)
	for a in rt.attached {
		a.c.events = nil
		conn.sink_destroy(&a.sink)
		free(a)
	}
	delete(rt.attached)
	results_clear(&rt.results)
	delete(rt.results)
	runtime.arena_destroy(&rt.scratch)
	delete(rt.dir)
	free(rt)
}

@(private)
entry_destroy :: proc(e: ^Entry) {
	destroy(e.script)
	delete(e.file)
	for s in e.servers {
		delete(s)
	}
	delete(e.servers)
	delete(e.store_path)
}

// runtime_load reads the config and starts the scripts it enables. It is
// quiet when there is no config (there are no scripts then).
runtime_load :: proc(rt: ^Runtime) {
	path := fmt.tprintf("%s/%s", rt.dir, CONFIG_FILE)
	if !common.store_exists(path) {
		return
	}
	text, ok := common.store_read(path, context.temp_allocator)
	if !ok {
		return
	}
	cfg: Config
	if err := json.unmarshal(transmute([]u8)text, &cfg); err != nil {
		log.warnf("script: %s is not valid: %v", path, err)
		return
	}
	defer {
		for name, c in cfg.scripts {
			delete(name)
			for p in c.permissions {delete(p)}
			delete(c.permissions)
			for sv in c.servers {delete(sv)}
			delete(c.servers)
		}
		delete(cfg.scripts)
	}
	for file, c in cfg.scripts {
		if !c.enabled {
			continue
		}
		source, read := common.store_read(fmt.tprintf("%s/%s", rt.dir, file), context.temp_allocator)
		if !read {
			log.warnf("script %s: could not be read", file)
			continue
		}
		runtime_add(rt, file, source, c)
	}
}

// runtime_add starts a script, running its own code to the end first so that
// its handlers exist when the first event comes. It is false if it could not
// be started.
runtime_add :: proc(rt: ^Runtime, file, source: string, cfg: Script_Config) -> bool {
	s := create(file)
	if s == nil {
		log.warnf("script %s: out of memory", file)
		return false
	}
	s.host = &rt.host
	for p in cfg.permissions {
		switch p {
		case "send":
			s.perms += {.Send}
		case "notify":
			s.perms += {.Notify}
		case:
			log.warnf("script %s: no permission called %q", file, p)
		}
	}
	e := Entry {
		file        = strings.clone(file),
		script      = s,
		all_servers = len(cfg.servers) == 0,
		servers     = make([]string, len(cfg.servers)),
	}
	for sv, i in cfg.servers {
		e.servers[i] = strings.clone(sv)
	}
	e.store_path = fmt.aprintf("%s/data/%s.json", rt.dir, file)
	store_read_file(s, e.store_path)
	e.saved = time.tick_now()

	if err, ok := run_source(s, source); !ok {
		log.warnf("script %s: %s", file, err)
		entry_destroy(&e)
		return false
	}
	results: [dynamic]Result
	defer {
		report(rt, &results)
		delete(results)
	}
	began := time.tick_now()
	for pending(s) > 0 && time.tick_since(began) < LOAD_TIME {
		step(s, 5 * time.Millisecond, &results)
	}
	if pending(s) > 0 {
		log.warnf("script %s: its own code took too long", file)
		entry_destroy(&e)
		return false
	}
	for r in results {
		if r.status != .Finished {
			entry_destroy(&e)
			return false
		}
	}
	append(&rt.entries, e)
	log.infof("script %s: running", file)
	return true
}

// runtime_attach lets the runtime hear from a connection, which stays attached
// until runtime_detach (before the connection goes away).
runtime_attach :: proc(rt: ^Runtime, c: ^conn.Server_Conn) -> Server_Id {
	a := new(Attached)
	a.id = rt.next_id
	rt.next_id += 1
	a.c = c
	c.events = &a.sink
	append(&rt.attached, a)
	return a.id
}

runtime_detach :: proc(rt: ^Runtime, c: ^conn.Server_Conn) {
	for a, i in rt.attached {
		if a.c != c {
			continue
		}
		c.events = nil
		for &e in rt.entries {
			forget_server(e.script, a.id)
		}
		conn.sink_destroy(&a.sink)
		free(a)
		ordered_remove(&rt.attached, i)
		return
	}
}

// runtime_step tells the scripts what has happened since the last time, and
// runs them for about `budget`.
runtime_step :: proc(rt: ^Runtime, budget: time.Duration) {
	if len(rt.entries) == 0 {
		// Nobody listens: the events are not kept.
		for a in rt.attached {
			drain(a)
		}
		return
	}
	context.temp_allocator = runtime.arena_allocator(&rt.scratch)
	free_all(context.temp_allocator)

	for a in rt.attached {
		events := conn.sink_take(&a.sink, context.temp_allocator)
		for &ev in events {
			deliver(rt, a, ev)
			conn.event_destroy(&ev)
		}
	}
	each := budget / time.Duration(len(rt.entries))
	for &e in rt.entries {
		step(e.script, each, &rt.results)
		entry_save(&e)
	}
	report(rt, &rt.results)
}

@(private = "file")
drain :: proc(a: ^Attached) {
	events := conn.sink_take(&a.sink, context.temp_allocator)
	for &ev in events {
		conn.event_destroy(&ev)
	}
}

// report logs the handlers that went wrong, and forgets the results.
@(private = "file")
report :: proc(rt: ^Runtime, results: ^[dynamic]Result) {
	for r in results {
		switch r.status {
		case .Finished:
		case .Error:
			log.warnf("script: %s: %s", r.name, r.message)
		case .Killed:
			log.warnf("script: %s %s (after %v)", r.name, r.message, r.spent)
		}
	}
	results_clear(results)
}

@(private = "file")
deliver :: proc(rt: ^Runtime, a: ^Attached, ev: conn.Event) {
	handler: string
	value: Value
	switch e in ev {
	case conn.Event_Connected:
		handler = "on_connect"
		value = map_of({"server", server_value(a)})
	case conn.Event_Disconnected:
		handler = "on_disconnect"
		value = map_of({"server", server_value(a)}, {"why", e.why})
	case conn.Event_Message:
		handler = "on_message"
		value = message_value(a, e)
	case conn.Event_Presence:
		handler = "on_presence"
		value = map_of(
			{"server", server_value(a)},
			{"user", e.name},
			{"username", e.username},
			{"account", fmt.tprint(u64(e.account))},
			{"state", enum_name(e.activity)},
			{"was", enum_name(e.was)},
		)
	}
	for &entry in rt.entries {
		if in_scope(&entry, a) {
			call(entry.script, handler, value, a.id)
		}
	}
}

@(private = "file")
enum_name :: proc(v: $T) -> string {
	return strings.to_lower(fmt.tprint(v), context.temp_allocator)
}

@(private = "file")
server_value :: proc(a: ^Attached) -> Value {
	return map_of({"key", server_key(a)}, {"address", a.c.server_addr})
}

@(private = "file")
server_key :: proc(a: ^Attached) -> string {
	return common.key_hex(a.c.server_key)
}

@(private = "file")
message_value :: proc(a: ^Attached, m: conn.Event_Message) -> Value {
	thread: Value
	if m.thread_root != 0 {
		thread = fmt.tprint(u64(m.thread_root))
	}
	return map_of(
		{"server", server_value(a)},
		{"id", fmt.tprint(u64(m.id))},
		{"channel", m.channel},
		{"kind", enum_name(m.kind)},
		{"type", enum_name(m.msg_kind)},
		{"author", m.author_name},
		{"username", m.username},
		{"author_id", fmt.tprint(u64(m.author))},
		{"text", m.text},
		{"thread", thread},
		{"time", i64(m.time)},
		{"mine", m.mine},
		{"mentions_me", m.mentions_me},
	)
}

// in_scope reports whether the script runs for the server.
@(private = "file")
in_scope :: proc(e: ^Entry, a: ^Attached) -> bool {
	if e.all_servers {
		return true
	}
	key := server_key(a)
	for s in e.servers {
		if strings.equal_fold(s, a.c.server_addr) || strings.equal_fold(s, key) {
			return true
		}
	}
	return false
}

@(private = "file")
entry_of :: proc(rt: ^Runtime, s: ^Script) -> ^Entry {
	for &e in rt.entries {
		if e.script == s {
			return &e
		}
	}
	return nil
}

@(private = "file")
attached_of :: proc(rt: ^Runtime, id: Server_Id) -> ^Attached {
	for a in rt.attached {
		if a.id == id {
			return a
		}
	}
	return nil
}

@(private = "file")
host_log :: proc(host: ^Host, s: ^Script, text: string) {
	log.infof("[%s] %s", s.name, text)
}

@(private = "file")
host_send :: proc(host: ^Host, s: ^Script, server: Server_Id, channel, text: string) -> string {
	rt := (^Runtime)(host.data)
	a := attached_of(rt, server)
	if a == nil {
		return "the server is gone"
	}
	conn.push_command(
		&a.c.commands,
		conn.Chat_Command{text = strings.clone(text), channel = strings.clone(channel)},
	)
	return ""
}

@(private = "file")
host_notify :: proc(host: ^Host, s: ^Script, server: Server_Id, title, text: string) -> string {
	rt := (^Runtime)(host.data)
	shown := fmt.tprintf("%s: %s", title, text) if text != "" else title
	a := attached_of(rt, server)
	if a == nil || a.c.view == nil {
		log.infof("[%s] notice: %s", s.name, shown)
		return ""
	}
	conn.view_notice(a.c.view, true, shown)
	return ""
}

@(private = "file")
host_server_by_key :: proc(host: ^Host, s: ^Script, key: string) -> Server_Id {
	rt := (^Runtime)(host.data)
	e := entry_of(rt, s)
	for a in rt.attached {
		if (e == nil || in_scope(e, a)) &&
		   (strings.equal_fold(key, a.c.server_addr) || strings.equal_fold(key, server_key(a))) {
			return a.id
		}
	}
	return 0
}

// forget_server drops the timers of a server that is gone.
@(private = "file")
forget_server :: proc(s: ^Script, id: Server_Id) {
	for i := 0; i < len(s.timers); {
		if s.timers[i].server == id {
			delete(s.timers[i].name, s.allocator)
			unordered_remove(&s.timers, i)
		} else {
			i += 1
		}
	}
}

// The store as a file: a JSON object of the values.
@(private = "file")
store_read_file :: proc(s: ^Script, path: string) {
	if !common.store_exists(path) {
		return
	}
	text, ok := common.store_read(path, context.temp_allocator)
	if !ok {
		return
	}
	parsed, err := json.parse(transmute([]u8)text, parse_integers = true, allocator = context.temp_allocator)
	obj, is_object := parsed.(json.Object)
	if err != nil || !is_object {
		log.warnf("script %s: its saved store is unreadable and is ignored", s.name)
		return
	}
	values := make(map[string]Value, context.temp_allocator)
	for k, v in obj {
		switch x in v {
		case json.Boolean:
			values[k] = bool(x)
		case json.Integer:
			values[k] = i64(x)
		case json.Float:
			values[k] = f64(x)
		case json.String:
			values[k] = string(x)
		case json.Null, json.Array, json.Object:
		}
	}
	store_load(s, values)
}

@(private = "file")
entry_save :: proc(e: ^Entry, force := false) {
	s := e.script
	if !s.store_dirty || e.store_path == "" {
		return
	}
	if !force && time.tick_since(e.saved) < SAVE_EVERY {
		return
	}
	e.saved = time.tick_now()
	s.store_dirty = false
	obj := make(json.Object, context.temp_allocator)
	for k, v in s.store {
		switch x in v {
		case bool:
			obj[k] = json.Boolean(x)
		case i64:
			obj[k] = json.Integer(x)
		case f64:
			obj[k] = json.Float(x)
		case string:
			obj[k] = json.String(x)
		case List, Map:
		}
	}
	data, err := json.marshal(obj, {pretty = true, use_spaces = true, spaces = 2}, context.temp_allocator)
	if err != nil {
		log.warnf("script %s: could not encode its store: %v", s.name, err)
		return
	}
	common.store_write(e.store_path, string(data), private = true)
}

// runtime_scripts is how many scripts are running.
runtime_scripts :: proc(rt: ^Runtime) -> int {
	return len(rt.entries)
}

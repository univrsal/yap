package script

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"

import "client:conn"
import "common:."
import "common:proto"
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

// A connection scripts hear from.
@(private)
Attached :: struct {
	id:     Server_Id,
	rt:     ^Runtime,
	c:      ^conn.Server_Conn,
	sink:   conn.Event_Sink,
	filter: conn.Message_Filter,
}

// A script that is running.
@(private)
Entry :: struct {
	item:       ^Item,
	script:     ^Script,
	store_path: string, // owned; "" if it isn't kept
	saved:      time.Tick,
}

// Everything that runs Lua, or changes what runs it, holds `mutex`: the step,
// the calls from the UI, and the filters the network thread asks for
// (filter_incoming). The network thread only waits a moment for it (FILTER_WAIT)
// and shows a message as it is if it can't have it.
FILTER_WAIT :: 5 * time.Millisecond

Runtime :: struct {
	mutex:               sync.Mutex,
	dir:                 string, // owned
	host:                Host,
	attached:            [dynamic]^Attached,
	items:               [dynamic]^Item, // the scripts it knows of (items.odin)
	http:                Http_Transport, // web requests (http_native.odin, http_web.odin)
	entries:             [dynamic]Entry, // those that are running
	next_id:             Server_Id,
	results:             [dynamic]Result,
	// Command lines typed on another thread (runtime_queue_command), run by
	// the next runtime_step.
	queue_mutex:         sync.Mutex,
	queued:              [dynamic]Queued,
	// The connections are driven by the thread that steps the runtime, so that
	// it may look at their state (headless mode).
	inline_conns:        bool,
	// The desktop notifications scripts have asked for, for the UI to show
	// (runtime_take_notifications); without a UI they are written to the log.
	notifications:       [dynamic]Notification,
	notifications_to_ui: bool,
	// For what is made while stepping, which is emptied at the start of the next.
	scratch:             runtime.Arena,
}

runtime_create :: proc(dir: string) -> ^Runtime {
	rt := new(Runtime)
	rt.dir = strings.clone(dir)
	rt.next_id = 1
	rt.host = Host {
		data           = rt,
		log            = host_log,
		send           = host_send,
		notify         = host_notify,
		status         = host_status,
		server_by_key  = host_server_by_key,
		http_available = host_http_available,
		http_begin     = host_http_begin,
		http_cancel    = host_http_cancel,
	}
	http_start(rt)
	_ = runtime.arena_init(&rt.scratch, 256 * 1024, context.allocator)
	return rt
}

runtime_destroy :: proc(rt: ^Runtime) {
	if rt == nil {
		return
	}
	for q in rt.queued {
		delete(q.line)
	}
	delete(rt.queued)
	for n in rt.notifications {
		notification_destroy(n)
	}
	delete(rt.notifications)
	for &e in rt.entries {
		entry_save(&e, force = true)
		entry_destroy(&e)
	}
	delete(rt.entries)
	for it in rt.items {
		item_destroy(it)
	}
	delete(rt.items)
	http_stop(rt)
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
	if h := e.script.host; h != nil && h.http_cancel != nil {
		h.http_cancel(h, e.script) // its requests are no longer wanted
	}
	destroy(e.script)
	delete(e.store_path)
}

// runtime_add starts a script from its text, with the choices in `cfg`, as if it
// were in the config. It is false if it could not be started. (For tests, and for
// anything that has a script in hand.)
runtime_add :: proc(rt: ^Runtime, file, source: string, cfg: Script_Config) -> bool {
	sync.guard(&rt.mutex)
	cfg := cfg
	cfg.enabled = true
	it := item_load(rt, file, cfg, source)
	if it.problem != "" {
		return false
	}
	return item_start(rt, it)
}

// runtime_attach lets the runtime hear from a connection, which stays attached
// until runtime_detach (before the connection goes away).
runtime_attach :: proc(rt: ^Runtime, c: ^conn.Server_Conn) -> Server_Id {
	sync.guard(&rt.mutex)
	a := new(Attached)
	a.id = rt.next_id
	rt.next_id += 1
	a.rt = rt
	a.c = c
	a.filter = {
		data     = a,
		incoming = filter_incoming,
	}
	c.events = &a.sink
	c.filter = &a.filter
	append(&rt.attached, a)
	return a.id
}

runtime_detach :: proc(rt: ^Runtime, c: ^conn.Server_Conn) {
	sync.guard(&rt.mutex)
	for a, i in rt.attached {
		if a.c != c {
			continue
		}
		c.events = nil
		c.filter = nil
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
	sync.guard(&rt.mutex)
	if len(rt.entries) == 0 {
		// Nobody listens: the events are not kept.
		for a in rt.attached {
			drain(a)
		}
		return
	}
	context.temp_allocator = runtime.arena_allocator(&rt.scratch)
	free_all(context.temp_allocator)

	run_queued(rt)
	http_poll(rt)
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
@(private)
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
	if e.item.all_servers {
		return true
	}
	key := server_key(a)
	for s in e.item.servers {
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
		// `typed`: @username in the text is a mention, as it is when it is typed.
		conn.Chat_Command {
			text = strings.clone(text),
			channel = strings.clone(channel),
			typed = true,
		},
	)
	return ""
}

// A desktop notification a script asked for.
Notification :: struct {
	title:  string, // owned
	text:   string, // owned
	server: string, // owned; the address of the server it was for, "" for none
	script: string, // owned; the script's file name
}

@(private = "file")
notification_destroy :: proc(n: Notification) {
	delete(n.title)
	delete(n.text)
	delete(n.server)
	delete(n.script)
}

// How many are kept for a UI that doesn't take them (the oldest go).
MAX_QUEUED_NOTIFICATIONS :: 50

// runtime_notifications_to_ui says that the UI shows the notifications, taking
// them with runtime_take_notifications; otherwise they are written to the log.
runtime_notifications_to_ui :: proc(rt: ^Runtime) {
	rt.notifications_to_ui = true
}

// runtime_take_notifications hands over the notifications asked for since the last
// time, oldest first, in the temp allocator.
runtime_take_notifications :: proc(rt: ^Runtime) -> []Notification {
	sync.guard(&rt.mutex)
	if len(rt.notifications) == 0 {
		return nil
	}
	taken := make([]Notification, len(rt.notifications), context.temp_allocator)
	for n, i in rt.notifications {
		taken[i] = {
			title  = strings.clone(n.title, context.temp_allocator),
			text   = strings.clone(n.text, context.temp_allocator),
			server = strings.clone(n.server, context.temp_allocator),
			script = strings.clone(n.script, context.temp_allocator),
		}
		notification_destroy(n)
	}
	clear(&rt.notifications)
	return taken
}

@(private = "file")
host_notify :: proc(host: ^Host, s: ^Script, server: Server_Id, title, text: string) -> string {
	rt := (^Runtime)(host.data)
	a := attached_of(rt, server)
	if !rt.notifications_to_ui {
		log.infof("[%s] notification: %s%s%s", s.name, title, ": " if text != "" else "", text)
		return ""
	}
	if len(rt.notifications) >= MAX_QUEUED_NOTIFICATIONS {
		notification_destroy(rt.notifications[0])
		ordered_remove(&rt.notifications, 0)
	}
	append(
		&rt.notifications,
		Notification {
			title = strings.clone(title),
			text = strings.clone(text),
			server = strings.clone(a.c.server_addr if a != nil else ""),
			script = strings.clone(s.name),
		},
	)
	return ""
}

@(private = "file")
host_status :: proc(host: ^Host, s: ^Script, server: Server_Id, text: string) -> string {
	rt := (^Runtime)(host.data)
	a := attached_of(rt, server)
	if a == nil || a.c.view == nil {
		log.infof("[%s] status: %s", s.name, text)
		return ""
	}
	conn.view_notice(a.c.view, true, text)
	return ""
}

@(private = "file")
host_http_available :: proc(host: ^Host) -> bool {
	return http_ready((^Runtime)(host.data))
}

@(private = "file")
host_http_begin :: proc(host: ^Host, s: ^Script, id: u64, req: Http_Request) -> string {
	return http_begin((^Runtime)(host.data), s, id, req)
}

@(private = "file")
host_http_cancel :: proc(host: ^Host, s: ^Script) {
	http_cancel_script((^Runtime)(host.data), s)
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
@(private)
store_read_file :: proc(s: ^Script, path: string) {
	if !common.store_exists(path) {
		return
	}
	text, ok := common.store_read(path, context.temp_allocator)
	if !ok {
		return
	}
	parsed, err := json.parse(
		transmute([]u8)text,
		parse_integers = true,
		allocator = context.temp_allocator,
	)
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

@(private)
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
		case List, Map, Function:
		}
	}
	data, err := json.marshal(
		obj,
		{pretty = true, use_spaces = true, spaces = 2},
		context.temp_allocator,
	)
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

// A /command a script registered, for lists and completion.
Command_Info :: struct {
	script: string, // the script's file name
	name:   string, // without the slash
	help:   string,
}

// runtime_commands lists the /commands of the scripts that run for the
// connection, by name. The slice is in `allocator`; the strings belong to the
// scripts and stay as they are until the next runtime_step.
runtime_commands :: proc(
	rt: ^Runtime,
	c: ^conn.Server_Conn,
	allocator := context.temp_allocator,
) -> []Command_Info {
	sync.guard(&rt.mutex)
	list := make([dynamic]Command_Info, allocator)
	a := attached_for(rt, c)
	if a == nil {
		return list[:]
	}
	for &e in rt.entries {
		if !in_scope(&e, a) {
			continue
		}
		for cmd in e.script.commands {
			append(&list, Command_Info{script = e.item.file, name = cmd.name, help = cmd.help})
		}
	}
	slice.sort_by(list[:], proc(x, y: Command_Info) -> bool {return x.name < y.name})
	return list[:]
}

// runtime_run_command runs the /command in `line` ("/roll 2d6") if a script
// that runs for the connection has registered it. `channel` is the name of the
// conversation it was typed in. It is false if there is no such command (the
// line is then for the caller to treat as it likes). The command runs like an
// event handler, on the next runtime_step.
runtime_run_command :: proc(rt: ^Runtime, c: ^conn.Server_Conn, line, channel: string) -> bool {
	sync.guard(&rt.mutex)
	return run_command(rt, c, line, channel)
}

@(private = "file")
run_command :: proc(rt: ^Runtime, c: ^conn.Server_Conn, line, channel: string) -> bool {
	text := strings.trim_space(line)
	if !strings.has_prefix(text, "/") {
		return false
	}
	a := attached_for(rt, c)
	if a == nil {
		return false
	}
	context.temp_allocator = runtime.arena_allocator(&rt.scratch)
	free_all(context.temp_allocator)
	name, args := text[1:], ""
	if i := strings.index_any(name, " \t"); i >= 0 {
		name, args = name[:i], strings.trim_space(name[i:])
	}
	name = strings.to_lower(name, context.temp_allocator)

	words := strings.fields(args, context.temp_allocator)
	argv := make([]Value, len(words), context.temp_allocator)
	for w, i in words {
		argv[i] = w
	}
	event := map_of(
		{"name", name},
		{"args", args},
		{"argv", List(argv)},
		{"channel", channel},
		{"server", server_value(a)},
	)
	for &e in rt.entries {
		if !in_scope(&e, a) {
			continue
		}
		if err, ok := call_command(e.script, name, event, a.id); ok {
			return true
		} else if err != "" {
			log.warnf("script %s: /%s: %s", e.item.file, name, err)
			return true
		}
	}
	return false
}

@(private = "file")
attached_for :: proc(rt: ^Runtime, c: ^conn.Server_Conn) -> ^Attached {
	for a in rt.attached {
		if a.c == c {
			return a
		}
	}
	return nil
}

// A command line typed somewhere else than where the runtime is stepped.
@(private)
Queued :: struct {
	c:    ^conn.Server_Conn,
	line: string, // owned
	say:  bool, // a message to post (runtime_queue_say), else a command line
}

// runtime_queue_command has the next runtime_step run the /command in `line`
// for the connection, from any thread. A line that no script knows is logged.
runtime_queue_command :: proc(rt: ^Runtime, c: ^conn.Server_Conn, line: string) {
	sync.guard(&rt.queue_mutex)
	append(&rt.queued, Queued{c = c, line = strings.clone(line)})
}

// runtime_queue_say has the next runtime_step pass a message the user typed
// (headless mode) by the scripts' on_send before it is posted to the channel
// being looked at, from any thread.
runtime_queue_say :: proc(rt: ^Runtime, c: ^conn.Server_Conn, text: string) {
	sync.guard(&rt.queue_mutex)
	append(&rt.queued, Queued{c = c, line = strings.clone(text), say = true})
}

@(private = "file")
run_queued :: proc(rt: ^Runtime) {
	sync.lock(&rt.queue_mutex)
	lines := rt.queued
	rt.queued = nil
	sync.unlock(&rt.queue_mutex)
	for q in lines {
		channel := ""
		if rt.inline_conns {
			channel = conn.room_name(q.c, proto.Room(q.c.convs.viewing))
		}
		switch {
		case q.say:
			// Not runtime_filter_send, which would take the lock the step holds.
			text, cancel, by := filter_send(rt, q.c, channel, q.line)
			if cancel {
				log.warnf("%s stopped the message from being sent", by)
			} else {
				conn.push_command(
					&q.c.commands,
					conn.Chat_Command{text = strings.clone(text), typed = true},
				)
			}
		case !run_command(rt, q.c, q.line, channel):
			word, _, _ := strings.partition(q.line, " ")
			log.warnf("no command %s (no script has registered it)", word)
		}
		delete(q.line)
	}
	delete(lines)
}

// runtime_inline_conns says that the connections are driven by the thread that
// steps the runtime (headless mode), so that it may look at their state.
runtime_inline_conns :: proc(rt: ^Runtime) {
	rt.inline_conns = true
}

// filter_incoming is what the network thread calls for a message on its way to
// the screen (conn/filter.odin): the scripts that run for the server and have
// an on_incoming are asked in turn, each seeing what the one before made of it.
@(private = "file")
filter_incoming :: proc(
	data: rawptr,
	c: ^conn.Server_Conn,
	info: conn.Event_Message,
) -> (
	r: conn.Filter_Result,
) {
	a := (^Attached)(data)
	rt := a.rt
	if !lock_for(rt, FILTER_WAIT) {
		return
	}
	defer sync.mutex_unlock(&rt.mutex)
	info := info
	for &e in rt.entries {
		if e.script.filters_off || !in_scope(&e, a) {
			continue
		}
		outcome, text, err := filter(e.script, "on_incoming", message_value(a, info), a.id)
		if err != "" {
			log.warnf("script %s: %s", e.item.file, err)
		}
		switch outcome {
		case .Unchanged:
		case .Hide:
			return {hide = true}
		case .Replace:
			info.text = text
			r = {
				text     = text,
				replaced = true,
			}
		}
	}
	return
}

// lock_for takes the runtime's mutex, waiting at most `wait` for it.
@(private = "file")
lock_for :: proc(rt: ^Runtime, wait: time.Duration) -> bool {
	when ODIN_OS == .WASI {
		// A page has one thread, so nobody else can be holding it.
		return sync.mutex_try_lock(&rt.mutex)
	} else {
		began := time.tick_now()
		for !sync.mutex_try_lock(&rt.mutex) {
			if time.tick_since(began) > wait {
				return false
			}
			time.sleep(50 * time.Microsecond)
		}
		return true
	}
}

// runtime_filter_send lets the scripts that run for the connection look at a
// message the user is about to send (on_send, called with the channel it is for
// and the text as typed). `cancel` says one of them stopped it, `by` which; else
// `text` is what to send, in the temp allocator.
runtime_filter_send :: proc(
	rt: ^Runtime,
	c: ^conn.Server_Conn,
	channel, text: string,
) -> (
	out: string,
	cancel: bool,
	by: string,
) {
	sync.guard(&rt.mutex)
	return filter_send(rt, c, channel, text)
}

@(private = "file")
filter_send :: proc(
	rt: ^Runtime,
	c: ^conn.Server_Conn,
	channel, text: string,
) -> (
	out: string,
	cancel: bool,
	by: string,
) {
	out = text
	a := attached_for(rt, c)
	if a == nil {
		return
	}
	for &e in rt.entries {
		if e.script.filters_off || !in_scope(&e, a) {
			continue
		}
		event := map_of({"server", server_value(a)}, {"channel", channel}, {"text", out})
		outcome, replaced, err := filter(e.script, "on_send", event, a.id)
		if err != "" {
			log.warnf("script %s: %s", e.item.file, err)
		}
		switch outcome {
		case .Unchanged:
		case .Hide:
			return out, true, e.item.file
		case .Replace:
			out = replaced
		}
	}
	return
}

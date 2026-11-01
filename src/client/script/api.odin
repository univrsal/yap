package script

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:time"

// The yap.* functions a script calls. yap_lua.c has them call host_call below
// with the position of the function in OP_NAMES. What each is for is in
// docs/design/scripting.md.

Op :: enum c.int {
	Log, // yap._log, which yap.log is made from
	Send,
	Notify,
	Timer,
	Cancel,
	Store_Get,
	Store_Set,
	Store_Delete,
	Register_Command,
	Unregister_Command,
	Setting,
	Http_Available,
	Http_Get,
	Http_Post,
	Status,
}

// The names the functions get in the yap table. Op is the index.
@(private)
OP_NAMES := [?]cstring {
	int(Op.Log)          = "_log",
	int(Op.Send)         = "send",
	int(Op.Notify)       = "notify",
	int(Op.Timer)        = "timer",
	int(Op.Cancel)       = "cancel",
	int(Op.Store_Get)    = "store.get",
	int(Op.Store_Set)    = "store.set",
	int(Op.Store_Delete) = "store.delete",
	int(Op.Register_Command) = "register_command",
	int(Op.Unregister_Command) = "unregister_command",
	int(Op.Setting) = "setting",
	int(Op.Http_Available) = "http_available",
	int(Op.Http_Get) = "http_get",
	int(Op.Http_Post) = "http_post",
	int(Op.Status) = "status",
}

// Limits on what a script may hold or ask for.
MAX_TIMERS :: 64
MAX_NAME :: 64
MAX_STORE_KEY :: 128
MAX_STORE_BYTES :: 256 * 1024
MAX_TEXT :: 16 * 1024
MAX_COMMANDS :: 32
MAX_COMMAND_NAME :: 32
MAX_HELP :: 200
MIN_TIMER :: 50 * time.Millisecond
// A script may send this many messages in this long.
MAX_SENDS :: 20
SEND_WINDOW :: 10 * time.Second
// ... and this many desktop notifications in this long.
MAX_NOTIFICATIONS :: 10
NOTIFY_WINDOW :: 10 * time.Second

@(private)
register_api :: proc(s: ^Script) -> bool {
	return register(s.state, raw_data(OP_NAMES[:]), c.int(len(OP_NAMES))) == 0
}

// host_call is what C calls when a script calls a yap.* function.
@(private)
host_call :: proc "c" (ud: rawptr, op: c.int, args: [^]C_Value, nargs: c.int, ret: ^C_Value) -> c.int {
	s := (^Script)(ud)
	context = s.ctx
	context.allocator = s.allocator
	scratch := runtime.arena_allocator(&s.scratch)
	context.temp_allocator = scratch
	free_all(scratch)
	s.keep_arg = -1

	values := make([]Value, nargs, scratch)
	for i in 0 ..< int(nargs) {
		values[i] = from_c(args[i], scratch)
	}
	result, err := dispatch(s, Op(op), values)
	if message, failed := err.?; failed {
		ret^ = to_c(message, scratch)
		return 1
	}
	if s.keep_arg >= 0 && s.keep_arg < len(values) {
		args[s.keep_arg].type = C_NIL // the host keeps that function
	}
	ret^ = to_c(result, scratch)
	return 0
}

// What the parts of the arguments a function takes look like when they are
// not what it takes. In the message the Lua call is named the way the script
// wrote it.
@(private)
Args :: struct {
	name:   string,
	values: []Value,
}

@(private)
arg_string :: proc(a: Args, i: int, max: int, optional := false) -> (text: string, err: Maybe(string)) {
	if i >= len(a.values) || a.values[i] == nil {
		if optional {
			return "", nil
		}
		return "", error_of("yap.%s: argument #%d is missing", a.name, i + 1)
	}
	text, _ = a.values[i].(string)
	if _, is_string := a.values[i].(string); !is_string {
		return "", error_of("yap.%s: argument #%d must be a string", a.name, i + 1)
	}
	if len(text) > max {
		return "", error_of("yap.%s: argument #%d is too long (at most %d bytes)", a.name, i + 1, max)
	}
	return text, nil
}

@(private)
error_of :: proc(format: string, args: ..any) -> string {
	return fmt.tprintf(format, ..args)
}

@(private)
dispatch :: proc(s: ^Script, op: Op, values: []Value) -> (result: Value, err: Maybe(string)) {
	a := Args {
		name   = string(OP_NAMES[int(op)]),
		values = values,
	}
	if a.name == "_log" {
		a.name = "log"
	}
	server := s.run.server
	if s.meta {
		return nil, nil
	}
	switch op {
	case .Log:
		text := arg_string(a, 0, MAX_TEXT, true) or_return
		if s.host != nil && s.host.log != nil {
			s.host.log(s.host, s, text)
		}
	case .Send:
		if .Send not_in s.perms {
			return nil, "yap.send needs the 'send' permission"
		}
		channel := arg_string(a, 0, MAX_NAME) or_return
		text := arg_string(a, 1, MAX_TEXT) or_return
		key := arg_string(a, 2, MAX_TEXT, true) or_return
		server = pick_server(s, key, server) or_return
		if s.host == nil || s.host.send == nil {
			return nil, "yap.send is not available"
		}
		now := time.tick_now()
		if s.sent == 0 || time.tick_diff(s.send_window, now) > SEND_WINDOW {
			s.send_window, s.sent = now, 0
		}
		if s.sent >= MAX_SENDS {
			return nil, error_of("yap.send: sending too fast (at most %d messages in %v)", MAX_SENDS, SEND_WINDOW)
		}
		s.sent += 1
		if e := s.host.send(s.host, s, server, channel, text); e != "" {
			return nil, e
		}
	case .Notify:
		if .Notify not_in s.perms {
			return nil, "yap.notify needs the 'notify' permission"
		}
		title := arg_string(a, 0, MAX_NAME) or_return
		text := arg_string(a, 1, MAX_TEXT, true) or_return
		if s.host == nil || s.host.notify == nil {
			return nil, "yap.notify is not available"
		}
		now := time.tick_now()
		if s.notified == 0 || time.tick_diff(s.notify_window, now) > NOTIFY_WINDOW {
			s.notify_window, s.notified = now, 0
		}
		if s.notified >= MAX_NOTIFICATIONS {
			return nil, error_of("yap.notify: too many notifications (at most %d in %v)", MAX_NOTIFICATIONS, NOTIFY_WINDOW)
		}
		s.notified += 1
		if e := s.host.notify(s.host, s, server, title, text); e != "" {
			return nil, e
		}
	case .Status:
		if .Notify not_in s.perms {
			return nil, "yap.status needs the 'notify' permission"
		}
		text := arg_string(a, 0, MAX_TEXT) or_return
		if s.host == nil || s.host.status == nil {
			return nil, "yap.status is not available"
		}
		if e := s.host.status(s.host, s, server, text); e != "" {
			return nil, e
		}
	case .Timer:
		name := arg_string(a, 0, MAX_NAME) or_return
		if name == "" {
			return nil, "yap.timer: the name is empty"
		}
		seconds: f64
		#partial switch x in values[1] if len(values) > 1 else nil {
		case i64:
			seconds = f64(x)
		case f64:
			seconds = x
		case:
			return nil, "yap.timer: argument #2 must be a number of seconds"
		}
		if !(seconds >= 0 && seconds <= 366 * 86400) {
			return nil, "yap.timer: the time is out of range"
		}
		again := false
		if len(values) > 2 {
			again = truthy(values[2])
		}
		delay := max(time.Duration(seconds * f64(time.Second)), MIN_TIMER)
		timer_set(s, name, delay, again, server) or_return
	case .Cancel:
		name := arg_string(a, 0, MAX_NAME) or_return
		timer_cancel(s, name)
	case .Store_Get:
		key := arg_string(a, 0, MAX_STORE_KEY) or_return
		if v, ok := s.store[key]; ok {
			result = v
			if str, is_string := v.(string); is_string {
				result = str
			}
		}
	case .Store_Set:
		key := arg_string(a, 0, MAX_STORE_KEY) or_return
		if len(values) < 2 || values[1] == nil {
			store_delete(s, key)
			return
		}
		switch x in values[1] {
		case bool, i64, f64, string:
		case List, Map, Function:
			return nil, "yap.store.set: only booleans, numbers and strings can be stored"
		}
		store_set(s, key, values[1]) or_return
	case .Store_Delete:
		key := arg_string(a, 0, MAX_STORE_KEY) or_return
		store_delete(s, key)
	case .Register_Command:
		// (name, fn) or (name, help, fn)
		last := values[len(values) - 1] if len(values) > 0 else nil
		fn, is_fn := last.(Function)
		if len(values) < 2 || !is_fn {
			return nil, "yap.register_command: the last argument must be the function to run"
		}
		name := arg_string(a, 0, MAX_COMMAND_NAME) or_return
		help := ""
		if len(values) > 2 {
			help = arg_string(a, 1, MAX_HELP) or_return
		}
		command_register(s, name, help, c.int(fn)) or_return
		s.keep_arg = len(values) - 1
	case .Http_Available:
		result = s.host != nil && s.host.http_available != nil && s.host.http_available(s.host)
	case .Http_Get, .Http_Post:
		if .Net not_in s.perms {
			return nil, "yap.http_get and yap.http_post need the 'net' permission"
		}
		req, fn, fn_index := request_make(s, a, op == .Http_Post) or_return
		request_start(s, req, fn, server) or_return
		s.keep_arg = fn_index
	case .Setting:
		key := arg_string(a, 0, MAX_SETTING_KEY) or_return
		result = s.settings[key] or_else nil
	case .Unregister_Command:
		name := arg_string(a, 0, MAX_COMMAND_NAME) or_return
		command_unregister(s, strings.to_lower(name, context.temp_allocator))
	}
	return
}

// command_name_ok says whether a name can be typed after a slash: lower case
// letters, digits, - and _, and not empty.
@(private = "file")
command_name_ok :: proc(name: string) -> bool {
	if name == "" {
		return false
	}
	for r in name {
		if !(r >= 'a' && r <= 'z') && !(r >= '0' && r <= '9') && r != '-' && r != '_' {
			return false
		}
	}
	return true
}

@(private = "file")
command_register :: proc(s: ^Script, name, help: string, fn: c.int) -> (err: Maybe(string)) {
	lower := strings.to_lower(name, context.temp_allocator)
	if !command_name_ok(lower) {
		return error_of("yap.register_command: %q is not a command name (letters, digits, - and _)", name)
	}
	command_unregister(s, lower) // registering again replaces it
	if len(s.commands) >= MAX_COMMANDS {
		return error_of("yap.register_command: at most %d commands", MAX_COMMANDS)
	}
	append(
		&s.commands,
		Command{name = strings.clone(lower, s.allocator), help = strings.clone(help, s.allocator), fn = fn},
	)
	return nil
}

@(private = "file")
command_unregister :: proc(s: ^Script, name: string) {
	for cmd, i in s.commands {
		if cmd.name == name {
			release(s.state, cmd.fn)
			delete(cmd.name, s.allocator)
			delete(cmd.help, s.allocator)
			unordered_remove(&s.commands, i)
			return
		}
	}
}

@(private = "file")
truthy :: proc(v: Value) -> bool {
	switch x in v {
	case nil:
		return false
	case bool:
		return x
	case i64, f64, string, List, Map, Function:
		return true
	}
	return false
}

// pick_server returns the server an action is about: the one named by the
// script, if it did, otherwise the one the handler is running for.
@(private = "file")
pick_server :: proc(s: ^Script, key: string, current: Server_Id) -> (server: Server_Id, err: Maybe(string)) {
	if key != "" {
		if s.host == nil || s.host.server_by_key == nil {
			return 0, "there are no servers"
		}
		server = s.host.server_by_key(s.host, s, key)
		if server == 0 {
			return 0, error_of("this script has no server %q", key)
		}
		return server, nil
	}
	if current == 0 {
		return 0, "no server: name one, or call this from an event handler or a timer"
	}
	return current, nil
}

@(private = "file")
timer_set :: proc(s: ^Script, name: string, delay: time.Duration, again: bool, server: Server_Id) -> (err: Maybe(string)) {
	timer_cancel(s, name)
	if len(s.timers) >= MAX_TIMERS {
		return error_of("yap.timer: at most %d timers", MAX_TIMERS)
	}
	append(
		&s.timers,
		Timer {
			name = strings.clone(name, s.allocator),
			due = time.tick_add(time.tick_now(), delay),
			interval = delay if again else 0,
			server = server,
		},
	)
	return nil
}

@(private = "file")
timer_cancel :: proc(s: ^Script, name: string) {
	for t, i in s.timers {
		if t.name == name {
			delete(t.name, s.allocator)
			unordered_remove(&s.timers, i)
			return
		}
	}
}

// fire_timers starts on_timer for each timer that is due.
@(private)
fire_timers :: proc(s: ^Script) {
	if len(s.timers) == 0 {
		return
	}
	now := time.tick_now()
	for i := 0; i < len(s.timers); {
		t := &s.timers[i]
		if time.tick_diff(t.due, now) < 0 {
			i += 1
			continue
		}
		name, server := t.name, t.server
		once := t.interval == 0
		if !once {
			// From when it was due, not from now, so that it doesn't drift; but
			// never a burst to catch up after a stall.
			t.due = time.tick_add(t.due, t.interval)
			if time.tick_diff(t.due, now) >= 0 {
				t.due = time.tick_add(now, t.interval)
			}
			i += 1
		} else {
			unordered_remove(&s.timers, i)
		}
		call(s, "on_timer", Map([]Pair{{"name", name}}), server)
		if once {
			delete(name, s.allocator)
		}
	}
}

@(private = "file")
store_set :: proc(s: ^Script, key: string, v: Value) -> (err: Maybe(string)) {
	old_size := 0
	if old, ok := s.store[key]; ok {
		old_size = value_size(key, old)
	}
	size := value_size(key, v)
	if s.store_size - old_size + size > MAX_STORE_BYTES {
		return error_of("yap.store.set: the store is full (at most %d bytes)", MAX_STORE_BYTES)
	}
	stored := v
	if str, is_string := v.(string); is_string {
		stored = strings.clone(str, s.allocator)
	}
	if old, ok := s.store[key]; ok {
		if str, is_string := old.(string); is_string {
			delete(str, s.allocator)
		}
		s.store[key] = stored
	} else {
		s.store[strings.clone(key, s.allocator)] = stored
	}
	s.store_size += size - old_size
	s.store_dirty = true
	return nil
}

@(private = "file")
store_delete :: proc(s: ^Script, key: string) {
	v, found := s.store[key]
	if !found {
		return
	}
	k, _ := delete_key(&s.store, key)
	s.store_size -= value_size(k, v)
	if str, is_string := v.(string); is_string {
		delete(str, s.allocator)
	}
	delete(k, s.allocator)
	s.store_dirty = true
}

@(private = "file")
value_size :: proc(key: string, v: Value) -> int {
	n := len(key) + 16
	if str, is_string := v.(string); is_string {
		n += len(str)
	}
	return n
}

// store_clear forgets everything in the store.
@(private)
store_clear :: proc(s: ^Script) {
	for k, v in s.store {
		if str, is_string := v.(string); is_string {
			delete(str, s.allocator)
		}
		delete(k, s.allocator)
	}
	clear(&s.store)
	s.store_size = 0
}

// store_load puts `values` (scalars) into the store, which is empty: the
// runtime does this after reading what was saved.
store_load :: proc(s: ^Script, values: map[string]Value) {
	store_clear(s)
	for k, v in values {
		store_set(s, k, v)
	}
	s.store_dirty = false
}

// settings_clear forgets the values of the settings.
@(private)
settings_clear :: proc(s: ^Script) {
	for k, v in s.settings {
		if str, is_string := v.(string); is_string {
			delete(str, s.allocator)
		}
		delete(k, s.allocator)
	}
	clear(&s.settings)
}

// setting_set gives the script a setting's value (a scalar).
setting_set :: proc(s: ^Script, key: string, v: Value) {
	stored := v
	if str, is_string := v.(string); is_string {
		stored = strings.clone(str, s.allocator)
	}
	if old, ok := s.settings[key]; ok {
		if str, is_string := old.(string); is_string {
			delete(str, s.allocator)
		}
		s.settings[key] = stored
		return
	}
	s.settings[strings.clone(key, s.allocator)] = stored
}

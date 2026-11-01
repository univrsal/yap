package script

import "base:runtime"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"

import "common:."
import log "common:wlog"

// The scripts the runtime knows of, running or not, with what the user has
// chosen for each (docs/design/scripting.md). What a script says about itself is
// its Info (info.odin); what the user chose is in config.json (whether it runs,
// what it may do, for which servers) and, for its settings, in
// <dir>/data/<file>.settings.json. A script's approval is for the text that was
// approved (its hash): a script that has changed since asks again.

MAX_SCRIPTS :: 64
// The longest a script may be, so that it can be kept in the browser's storage.
MAX_SCRIPT_SIZE :: 60 * 1024

@(private)
Item :: struct {
	file:        string, // owned; the script's name
	hash:        u64,
	info:        Info, // owned; empty without `has_info`
	has_info:    bool,
	// Why it can't run, or didn't (owned); "" if nothing is wrong.
	problem:     string,
	// What the user chose.
	enabled:     bool,
	granted:     Permissions,
	pinned:      bool, // the approval is for a particular text (see changed)
	changed:     bool, // pinned, but the text is no longer the one that was approved
	all_servers: bool,
	servers:     []string, // owned
	values:      map[string]Value, // the settings' values, all of them; owned
	running:     bool,
	// A script that was handed over as text (runtime_add) rather than read from
	// where scripts are kept; owned. "" for the rest.
	inline:      string,
}

// What the settings page shows of a script.
Item_View :: struct {
	file:        string,
	name:        string, // the file's name if the script has none
	description: string,
	version:     string,
	author:      string,
	problem:     string, // why it doesn't run: it can't be read, or it has changed
	problems:    []string, // what's wrong with its get_info
	changed:     bool,
	enabled:     bool,
	running:     bool,
	requested:   Permissions,
	granted:     Permissions,
	all_servers: bool,
	servers:     []string,
	settings:    []Setting_View,
}

Setting_View :: struct {
	def:   Setting_Def,
	value: Value,
}

Script_Config :: struct {
	enabled:     bool,
	permissions: []string `json:"permissions,omitempty"`,
	servers:     []string `json:"servers,omitempty"`,
	// Only for the servers listed, even if there are none (the page's "all
	// servers" unticked with nothing picked). A list that isn't empty means the
	// same, so a config written by hand needs neither.
	scoped:      bool `json:"scoped,omitempty"`,
	// The text that was approved (hex). A script written by hand into the
	// config may leave it out, and then it is not tied to one.
	hash:        string `json:"hash,omitempty"`,
}

Config :: struct {
	scripts: map[string]Script_Config,
}

@(private)
permission_names :: proc(p: Permissions) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	if .Send in p {
		append(&names, "send")
	}
	if .Notify in p {
		append(&names, "notify")
	}
	if .Net in p {
		append(&names, "net")
	}
	return names[:]
}

@(private)
permissions_of :: proc(names: []string, file: string) -> (p: Permissions) {
	for n in names {
		switch n {
		case "send":
			p += {.Send}
		case "notify":
			p += {.Notify}
		case "net":
			p += {.Net}
		case:
			log.warnf("script %s: no permission called %q", file, n)
		}
	}
	return
}

@(private)
hash_text :: proc(h: u64) -> string {
	buf: [8]u8
	for i in 0 ..< 8 {
		buf[i] = u8(h >> (8 * uint(7 - i)))
	}
	return string(hex.encode(buf[:], context.temp_allocator))
}

@(private)
item_destroy :: proc(it: ^Item) {
	delete(it.file)
	delete(it.inline)
	info_destroy(&it.info)
	delete(it.problem)
	for s in it.servers {
		delete(s)
	}
	delete(it.servers)
	for k, v in it.values {
		if str, ok := v.(string); ok {
			delete(str)
		}
		delete(k)
	}
	delete(it.values)
	free(it)
}

@(private)
item_set_problem :: proc(it: ^Item, text: string) {
	delete(it.problem)
	it.problem = strings.clone(text)
}

@(private)
item_of :: proc(rt: ^Runtime, file: string) -> ^Item {
	for it in rt.items {
		if it.file == file {
			return it
		}
	}
	return nil
}

@(private)
script_path :: proc(rt: ^Runtime, file: string) -> string {
	return fmt.tprintf("%s/%s", rt.dir, file)
}

@(private)
settings_path :: proc(rt: ^Runtime, file: string) -> string {
	return fmt.tprintf("%s/data/%s.settings.json", rt.dir, file)
}

// runtime_load finds the scripts, reads what they say about themselves, and
// starts the ones the user has switched on. It is quiet when there are none.
runtime_load :: proc(rt: ^Runtime) {
	sync.guard(&rt.mutex)
	load_all(rt)
}

@(private)
load_all :: proc(rt: ^Runtime) {
	cfg := config_read(rt)
	defer config_destroy(&cfg)

	names := list_script_files(rt)
	// What the config names is listed even if the file is gone, with the reason.
	for file in cfg.scripts {
		if !slice.contains(names[:], file) {
			append(&names, strings.clone(file, context.temp_allocator))
		}
	}
	slice.sort(names[:])
	for file in names {
		if len(rt.items) >= MAX_SCRIPTS {
			log.warnf("script: at most %d scripts are used", MAX_SCRIPTS)
			break
		}
		c, configured := cfg.scripts[file]
		it := item_load(rt, file, c if configured else Script_Config{})
		if it.enabled && it.problem == "" {
			item_start(rt, it)
		}
	}
}

// item_load reads a script's text and what it says about itself, and makes its
// Item, with the user's choices from `cfg`.
@(private)
item_load :: proc(rt: ^Runtime, file: string, cfg: Script_Config, inline := "") -> ^Item {
	it := new(Item)
	it.file = strings.clone(file)
	it.all_servers = !cfg.scoped && len(cfg.servers) == 0
	it.servers = make([]string, len(cfg.servers))
	for sv, i in cfg.servers {
		it.servers[i] = strings.clone(sv)
	}
	append(&rt.items, it)

	source := inline
	if inline != "" {
		it.inline = strings.clone(inline)
	} else {
		text, ok := common.store_read(script_path(rt, file), context.temp_allocator)
		if !ok {
			item_set_problem(it, "The script can't be read (is the file gone?)")
			return it
		}
		source = text
	}
	it.hash = source_hash(source)
	info, has, err := read_info(file, source)
	if err != "" {
		item_set_problem(it, err)
	}
	it.info, it.has_info = info, has

	it.enabled = cfg.enabled
	it.granted = permissions_of(cfg.permissions, file)
	if cfg.hash != "" {
		it.pinned = true
		if cfg.hash != hash_text(it.hash) {
			// It is not the script that was approved.
			it.changed, it.enabled, it.granted = true, false, {}
			if err == "" {
				item_set_problem(it, "This script has changed since you approved it. Look at what it asks for, and switch it on again.")
			}
		}
	}
	values_load(rt, it)
	return it
}

// values_load fills in the values of the script's settings: the saved ones that
// are still good, the defaults for the rest.
@(private)
values_load :: proc(rt: ^Runtime, it: ^Item) {
	saved := make(map[string]Value, context.temp_allocator)
	path := settings_path(rt, it.file)
	if common.store_exists(path) {
		if text, ok := common.store_read(path, context.temp_allocator); ok {
			parsed, err := json.parse(transmute([]u8)text, parse_integers = true, allocator = context.temp_allocator)
			if obj, is_object := parsed.(json.Object); err == nil && is_object {
				for k, v in obj {
					switch x in v {
					case json.Boolean:
						saved[k] = bool(x)
					case json.Integer:
						saved[k] = i64(x)
					case json.Float:
						saved[k] = f64(x)
					case json.String:
						saved[k] = string(x)
					case json.Null, json.Array, json.Object:
					}
				}
			}
		}
	}
	for &def in it.info.settings {
		v := def.default
		if s, ok := saved[def.key]; ok {
			if checked, valid := setting_value(&def, s); valid {
				v = checked
			}
		}
		value_put(it, def.key, v)
	}
}

@(private)
value_put :: proc(it: ^Item, key: string, v: Value) {
	stored := v
	if str, ok := v.(string); ok {
		stored = strings.clone(str)
	}
	if old, ok := it.values[key]; ok {
		if str, is_string := old.(string); is_string {
			delete(str)
		}
		it.values[key] = stored
		return
	}
	it.values[strings.clone(key)] = stored
}

@(private)
values_save :: proc(rt: ^Runtime, it: ^Item) {
	obj := make(json.Object, context.temp_allocator)
	for k, v in it.values {
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
	data, err := json.marshal(obj, {pretty = true, use_spaces = true, spaces = 2}, context.temp_allocator)
	if err == nil {
		common.store_write(settings_path(rt, it.file), string(data), private = true)
	}
}

@(private)
config_read :: proc(rt: ^Runtime) -> (cfg: Config) {
	path := fmt.tprintf("%s/%s", rt.dir, CONFIG_FILE)
	if !common.store_exists(path) {
		return
	}
	text, ok := common.store_read(path, context.temp_allocator)
	if !ok {
		return
	}
	if err := json.unmarshal(transmute([]u8)text, &cfg); err != nil {
		log.warnf("script: %s is not valid: %v", path, err)
		config_destroy(&cfg)
	}
	return
}

@(private)
config_destroy :: proc(cfg: ^Config) {
	for name, c in cfg.scripts {
		delete(name)
		for p in c.permissions {delete(p)}
		delete(c.permissions)
		for sv in c.servers {delete(sv)}
		delete(c.servers)
		delete(c.hash)
	}
	delete(cfg.scripts)
	cfg^ = {}
}

// config_save writes what the user chose.
@(private)
config_save :: proc(rt: ^Runtime) {
	cfg: Config
	cfg.scripts = make(map[string]Script_Config, context.temp_allocator)
	for it in rt.items {
		c := Script_Config {
			enabled     = it.enabled,
			permissions = permission_names(it.granted),
		}
		if !it.all_servers {
			c.servers = it.servers
			c.scoped = true
		}
		if it.pinned && !it.changed {
			c.hash = hash_text(it.hash)
		}
		cfg.scripts[it.file] = c
	}
	data, err := json.marshal(cfg, {pretty = true, use_spaces = true, spaces = 2}, context.temp_allocator)
	if err != nil {
		log.warnf("script: could not encode the config: %v", err)
		return
	}
	common.store_write(fmt.tprintf("%s/%s", rt.dir, CONFIG_FILE), string(data), private = true)
}

// item_start runs the script: its own code to the end first, so that its
// handlers exist when the first event comes, and then on_load.
@(private)
item_start :: proc(rt: ^Runtime, it: ^Item) -> bool {
	if it.running {
		return true
	}
	source := it.inline
	if source == "" {
		text, ok := common.store_read(script_path(rt, it.file), context.temp_allocator)
		if !ok {
			item_set_problem(it, "The script can't be read (is the file gone?)")
			return false
		}
		source = text
	}
	s := create(it.file)
	if s == nil {
		item_set_problem(it, "Out of memory")
		return false
	}
	s.host = &rt.host
	s.perms = it.granted
	for k, v in it.values {
		setting_set(s, k, v)
	}
	e := Entry {
		item       = it,
		script     = s,
		store_path = fmt.aprintf("%s/data/%s.json", rt.dir, it.file),
		saved      = time.tick_now(),
	}
	store_read_file(s, e.store_path)

	fail :: proc(rt: ^Runtime, it: ^Item, e: ^Entry, why: string) -> bool {
		log.warnf("script %s: %s", it.file, why)
		item_set_problem(it, why)
		entry_destroy(e)
		return false
	}
	if err, started := run_source(s, source); !started {
		return fail(rt, it, &e, err)
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
		return fail(rt, it, &e, "Its own code took too long to run")
	}
	for r in results {
		if r.status != .Finished {
			return fail(rt, it, &e, r.message if r.message != "" else "It failed when it was loaded")
		}
	}
	append(&rt.entries, e)
	it.running = true
	item_set_problem(it, "")
	log.infof("script %s: running", it.file)
	_, _ = call(s, "on_load", map_of({"settings", values_map(it)}))
	return true
}

// values_map is the settings' values as the Lua table on_load gets. In the temp
// allocator.
@(private)
values_map :: proc(it: ^Item) -> Value {
	pairs := make([dynamic]Pair, context.temp_allocator)
	for k, v in it.values {
		append(&pairs, Pair{k, v})
	}
	return Map(pairs[:])
}

// item_stop ends a running script, keeping what it stored.
@(private)
item_stop :: proc(rt: ^Runtime, it: ^Item) {
	for &e, i in rt.entries {
		if e.item != it {
			continue
		}
		entry_save(&e, force = true)
		entry_destroy(&e)
		ordered_remove(&rt.entries, i)
		break
	}
	it.running = false
}

// runtime_set_enabled switches a script on, with the permissions the user
// approved for it (and for the text it has now), or off. It returns what is wrong
// if the script can't be started.
runtime_set_enabled :: proc(rt: ^Runtime, file: string, on: bool, granted: Permissions = {}) -> (err: string) {
	sync.guard(&rt.mutex)
	it := item_of(rt, file)
	if it == nil {
		return "there is no such script"
	}
	if !on {
		item_stop(rt, it)
		it.enabled = false
		config_save(rt)
		return ""
	}
	if it.problem != "" && !it.changed {
		return it.problem
	}
	item_stop(rt, it)
	it.enabled, it.granted, it.pinned, it.changed = true, granted, true, false
	item_set_problem(it, "")
	started := item_start(rt, it)
	if !started {
		it.enabled = false
	}
	config_save(rt)
	return "" if started else it.problem
}

// runtime_set_scope chooses the servers a script runs for: all of them, or only
// those (addresses, or server keys in hex), which may be none.
runtime_set_scope :: proc(rt: ^Runtime, file: string, all: bool, servers: []string) {
	sync.guard(&rt.mutex)
	it := item_of(rt, file)
	if it == nil {
		return
	}
	for s in it.servers {
		delete(s)
	}
	delete(it.servers)
	it.all_servers = all
	it.servers = make([]string, len(servers))
	for s, i in servers {
		it.servers[i] = strings.clone(s)
	}
	config_save(rt)
}

// runtime_set_value sets one of a script's settings, if the value fits it (see
// setting_value), and tells the script. It returns what is wrong if it doesn't.
runtime_set_value :: proc(rt: ^Runtime, file, key: string, v: Value) -> (err: string) {
	sync.guard(&rt.mutex)
	it := item_of(rt, file)
	if it == nil {
		return "there is no such script"
	}
	for &def in it.info.settings {
		if def.key != key {
			continue
		}
		checked, ok := setting_value(&def, v)
		if !ok {
			return fmt.tprintf("%q doesn't fit the setting %s", v, def.label)
		}
		value_put(it, key, checked)
		values_save(rt, it)
		for &e in rt.entries {
			if e.item == it {
				setting_set(e.script, key, checked)
				_, _ = call(e.script, "on_setting", map_of({"key", key}, {"value", checked}))
			}
		}
		return ""
	}
	return fmt.tprintf("the script has no setting %s", key)
}

// runtime_reload stops every script and reads them all again, as when the client
// starts.
runtime_reload :: proc(rt: ^Runtime) {
	sync.guard(&rt.mutex)
	for &e in rt.entries {
		entry_save(&e, force = true)
		entry_destroy(&e)
	}
	clear(&rt.entries)
	for it in rt.items {
		item_destroy(it)
	}
	clear(&rt.items)
	load_all(rt)
}

// runtime_snapshot describes the scripts for the settings page: in `allocator`,
// by file name. It is a copy, so the page can use it while the scripts go on.
runtime_snapshot :: proc(rt: ^Runtime, allocator := context.temp_allocator) -> []Item_View {
	sync.guard(&rt.mutex)
	views := make([]Item_View, len(rt.items), allocator)
	copy_of :: proc(text: string, allocator: runtime.Allocator) -> string {
		return strings.clone(text, allocator)
	}
	for it, i in rt.items {
		v := Item_View {
			file        = copy_of(it.file, allocator),
			name        = copy_of(it.info.name if it.info.name != "" else it.file, allocator),
			description = copy_of(it.info.description, allocator),
			version     = copy_of(it.info.version, allocator),
			author      = copy_of(it.info.author, allocator),
			problem     = copy_of(it.problem, allocator),
			changed     = it.changed,
			enabled     = it.enabled,
			running     = it.running,
			requested   = it.info.permissions,
			granted     = it.granted,
			all_servers = it.all_servers,
		}
		v.problems = make([]string, len(it.info.problems), allocator)
		for p, k in it.info.problems {
			v.problems[k] = copy_of(p, allocator)
		}
		v.servers = make([]string, len(it.servers), allocator)
		for p, k in it.servers {
			v.servers[k] = copy_of(p, allocator)
		}
		v.settings = make([]Setting_View, len(it.info.settings), allocator)
		for def, k in it.info.settings {
			d := def
			d.key, d.label, d.description = copy_of(def.key, allocator), copy_of(def.label, allocator), copy_of(def.description, allocator)
			d.choices = make([]string, len(def.choices), allocator)
			for c, j in def.choices {
				d.choices[j] = copy_of(c, allocator)
			}
			value := it.values[def.key] or_else def.default
			if str, is_string := value.(string); is_string {
				value = copy_of(str, allocator)
			}
			if str, is_string := d.default.(string); is_string {
				d.default = copy_of(str, allocator)
			}
			v.settings[k] = {d, value}
		}
		views[i] = v
	}
	return views
}

// script_name_ok says whether a file name can be a script's: letters, digits,
// _ - and . only, ending in .lua, not too long. Nothing that could reach out of
// the scripts' folder.
script_name_ok :: proc(name: string) -> bool {
	if len(name) < 5 || len(name) > 48 || !strings.has_suffix(name, ".lua") || name[0] == '.' {
		return false
	}
	for r in name {
		if !(r >= 'a' && r <= 'z') && !(r >= 'A' && r <= 'Z') && !(r >= '0' && r <= '9') && r != '_' && r != '-' && r != '.' {
			return false
		}
	}
	return !strings.contains(name, "..")
}

// runtime_add_source keeps a script's text under `file` and makes it known (it is
// not switched on). It replaces a script of that name, which stops. The text is
// what the user pasted or picked, so it is checked only for its size.
runtime_add_source :: proc(rt: ^Runtime, file, text: string) -> (err: string) {
	sync.guard(&rt.mutex)
	if !script_name_ok(file) {
		return "A script's name is letters, digits, _ and -, and ends in .lua"
	}
	if len(text) > MAX_SCRIPT_SIZE {
		return fmt.tprintf("A script can be at most %d KiB", MAX_SCRIPT_SIZE / 1024)
	}
	if existing := item_of(rt, file); existing == nil && len(rt.items) >= MAX_SCRIPTS {
		return fmt.tprintf("At most %d scripts are used", MAX_SCRIPTS)
	}
	if !common.store_write(script_path(rt, file), text) {
		return "The script could not be saved"
	}
	source_added(rt, file)
	cfg := Script_Config{}
	if old := item_of(rt, file); old != nil {
		// A new text for a name that is known: its choices stay, but not its
		// approval, since it is not the text that was approved.
		item_stop(rt, old)
		cfg.servers = slice.clone(old.servers, context.temp_allocator)
		i, _ := slice.linear_search(rt.items[:], old)
		item_destroy(old)
		ordered_remove(&rt.items, i)
	}
	it := item_load(rt, file, cfg)
	_ = it
	config_save(rt)
	return ""
}

// runtime_remove_source forgets a script and deletes its text, its settings and
// what it stored.
runtime_remove_source :: proc(rt: ^Runtime, file: string) {
	sync.guard(&rt.mutex)
	it := item_of(rt, file)
	if it == nil {
		return
	}
	item_stop(rt, it)
	i, _ := slice.linear_search(rt.items[:], it)
	item_destroy(it)
	ordered_remove(&rt.items, i)
	common.store_remove(script_path(rt, file))
	common.store_remove(settings_path(rt, file))
	common.store_remove(fmt.tprintf("%s/data/%s.json", rt.dir, file))
	source_removed(rt, file)
	config_save(rt)
}

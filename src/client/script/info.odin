package script

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strings"

// What a script says about itself with its global function get_info(), which
// returns a table (docs/design/scripting.md):
//
//	function get_info()
//	  return {
//	    name = "Keyword highlight", description = "...", version = "1.2",
//	    author = "someone", permissions = { "notify" },
//	    settings = {
//	      { key = "words", label = "Keywords", type = "string", default = "yap" },
//	      { key = "volume", type = "number", default = 0.5, min = 0, max = 1 },
//	      { key = "where", type = "choice", default = "all", choices = { "all", "dms" } },
//	    },
//	  }
//	end
//
// The table comes from the script, so none of it is trusted: parse_info makes
// the Info out of it, with limits on everything and what can't be used left out
// (and said so in `problems`), and a setting's value is validated by
// setting_value whenever it is set.

MAX_INFO_NAME :: 64
MAX_INFO_DESCRIPTION :: 300
MAX_INFO_VERSION :: 32
MAX_SETTINGS :: 32
MAX_SETTING_KEY :: 48
MAX_SETTING_LABEL :: 64
MAX_SETTING_STRING :: 1024
DEFAULT_SETTING_STRING :: 256
MAX_CHOICES :: 32
MAX_CHOICE :: 48

Setting_Type :: enum {
	Bool,
	Int,
	Number,
	String,
	Choice,
}

Setting_Def :: struct {
	key:         string, // owned, as is all the text
	label:       string,
	description: string,
	type:        Setting_Type,
	default:     Value, // bool, i64, f64 or string, according to `type`
	min, max:    f64, // Int, Number
	has_min:     bool,
	has_max:     bool,
	max_len:     int, // String
	choices:     []string, // Choice
	secret:      bool, // String: shown masked
}

Info :: struct {
	name:        string,
	description: string,
	version:     string,
	author:      string,
	permissions: Permissions, // what it asks for
	settings:    []Setting_Def,
	servers:     []string, // what it was written for: the choice to start with
	// What was wrong with the table, in words for the person who wrote the script.
	problems:    []string,
}

info_destroy :: proc(info: ^Info, allocator := context.allocator) {
	delete(info.name, allocator)
	delete(info.description, allocator)
	delete(info.version, allocator)
	delete(info.author, allocator)
	for &d in info.settings {
		delete(d.key, allocator)
		delete(d.label, allocator)
		delete(d.description, allocator)
		if s, ok := d.default.(string); ok {
			delete(s, allocator)
		}
		for ch in d.choices {
			delete(ch, allocator)
		}
		delete(d.choices, allocator)
	}
	delete(info.settings, allocator)
	for s in info.servers {
		delete(s, allocator)
	}
	delete(info.servers, allocator)
	for p in info.problems {
		delete(p, allocator)
	}
	delete(info.problems, allocator)
	info^ = {}
}

// parse_info reads the table get_info returned. It never fails: a field that is
// missing or no good is left out, and noted in `problems`. Everything is copied
// into `allocator`.
parse_info :: proc(v: Value, allocator := context.allocator) -> (info: Info) {
	problems := make([dynamic]string, allocator)
	defs := make([dynamic]Setting_Def, allocator)
	parse_into(&info, v, &problems, &defs, allocator)
	info.problems = problems[:]
	info.settings = defs[:]
	return
}

@(private = "file")
parse_into :: proc(
	info: ^Info,
	v: Value,
	problems_out: ^[dynamic]string,
	defs_out: ^[dynamic]Setting_Def,
	allocator: runtime.Allocator,
) {
	problems := problems_out
	defs := defs_out
	note :: proc(
		problems: ^[dynamic]string,
		allocator: runtime.Allocator,
		format: string,
		args: ..any,
	) {
		append(problems, strings.clone(fmt.tprintf(format, ..args), allocator))
	}

	table, is_map := v.(Map)
	if !is_map {
		note(problems, allocator, "get_info must return a table")
		return
	}
	info.name = text_field(table, "name", MAX_INFO_NAME, problems, allocator, "name")
	info.description = text_field(
		table,
		"description",
		MAX_INFO_DESCRIPTION,
		problems,
		allocator,
		"description",
	)
	info.version = text_field(table, "version", MAX_INFO_VERSION, problems, allocator, "version")
	info.author = text_field(table, "author", MAX_INFO_NAME, problems, allocator, "author")

	if list, ok := field(table, "permissions").(List); ok {
		for p in list {
			name, is_text := p.(string)
			switch {
			case !is_text:
				note(problems, allocator, "permissions: only names are allowed")
			case name == "send":
				info.permissions += {.Send}
			case name == "notify":
				info.permissions += {.Notify}
			case name == "net":
				info.permissions += {.Net}
			case:
				note(problems, allocator, "permissions: there is no permission called %q", name)
			}
		}
	} else if field(table, "permissions") != nil {
		note(problems, allocator, "permissions must be a list of names")
	}

	if list, ok := field(table, "servers").(List); ok {
		servers := make([dynamic]string, allocator)
		for s in list {
			if name, is_text := s.(string);
			   is_text && name != "" && len(name) <= 256 && len(servers) < 16 {
				append(&servers, strings.clone(name, allocator))
			}
		}
		info.servers = servers[:]
	}

	list, has_settings := field(table, "settings").(List)
	if !has_settings {
		if field(table, "settings") != nil {
			note(problems, allocator, "settings must be a list")
		}
		return
	}
	for entry, i in list {
		if len(defs^) >= MAX_SETTINGS {
			note(problems, allocator, "at most %d settings are used", MAX_SETTINGS)
			break
		}
		def, ok := parse_setting(entry, i + 1, defs[:], problems, allocator)
		if ok {
			append(defs, def)
		}
	}
	return
}

@(private = "file")
field :: proc(m: Map, key: string) -> Value {
	for p in m {
		if p.key == key {
			return p.value
		}
	}
	return nil
}

// text_field returns a string field cut to `max` bytes (at a character
// boundary), "" if there is none.
@(private = "file")
text_field :: proc(
	m: Map,
	key: string,
	max: int,
	problems: ^[dynamic]string,
	allocator: runtime.Allocator,
	what: string,
) -> string {
	v := field(m, key)
	if v == nil {
		return ""
	}
	text, ok := v.(string)
	if !ok {
		append(problems, strings.clone(fmt.tprintf("%s must be text", what), allocator))
		return ""
	}
	return strings.clone(cut(text, max), allocator)
}

// cut shortens text to at most `max` bytes without cutting a character in two.
@(private = "file")
cut :: proc(text: string, max: int) -> string {
	if len(text) <= max {
		return text
	}
	n := max
	for n > 0 && (text[n] & 0xC0) == 0x80 {
		n -= 1
	}
	return text[:n]
}

@(private = "file")
key_ok :: proc(key: string) -> bool {
	if key == "" || len(key) > MAX_SETTING_KEY {
		return false
	}
	for r in key {
		if !(r >= 'a' && r <= 'z') &&
		   !(r >= 'A' && r <= 'Z') &&
		   !(r >= '0' && r <= '9') &&
		   r != '_' &&
		   r != '-' &&
		   r != '.' {
			return false
		}
	}
	return true
}

@(private)
number_of :: proc(v: Value) -> (f64, bool) {
	#partial switch x in v {
	case i64:
		return f64(x), true
	case f64:
		return x, !math.is_nan(x) && !math.is_inf(x)
	}
	return 0, false
}

@(private = "file")
parse_setting :: proc(
	entry: Value,
	n: int,
	existing: []Setting_Def,
	problems: ^[dynamic]string,
	allocator: runtime.Allocator,
) -> (
	def: Setting_Def,
	ok: bool,
) {
	bad :: proc(
		problems: ^[dynamic]string,
		allocator: runtime.Allocator,
		n: int,
		format: string,
		args: ..any,
	) {
		append(
			problems,
			strings.clone(
				fmt.tprintf("setting %d: %s", n, fmt.tprintf(format, ..args)),
				allocator,
			),
		)
	}
	m, is_map := entry.(Map)
	if !is_map {
		bad(problems, allocator, n, "must be a table")
		return
	}
	key, _ := field(m, "key").(string)
	if !key_ok(key) {
		bad(
			problems,
			allocator,
			n,
			"the key must be 1 to %d letters, digits, _ - or .",
			MAX_SETTING_KEY,
		)
		return
	}
	for d in existing {
		if d.key == key {
			bad(problems, allocator, n, "the key %q is used twice", key)
			return
		}
	}
	type_name, _ := field(m, "type").(string)
	switch type_name {
	case "bool":
		def.type = .Bool
	case "int":
		def.type = .Int
	case "number":
		def.type = .Number
	case "string":
		def.type = .String
	case "choice":
		def.type = .Choice
	case:
		bad(
			problems,
			allocator,
			n,
			"%q is not a type (bool, int, number, string, choice)",
			type_name,
		)
		return
	}
	label, _ := field(m, "label").(string)
	description, _ := field(m, "description").(string)
	if label == "" {
		label = key
	}
	def.key = strings.clone(key, allocator)
	def.label = strings.clone(cut(label, MAX_SETTING_LABEL), allocator)
	def.description = strings.clone(cut(description, MAX_INFO_DESCRIPTION), allocator)
	def.secret, _ = field(m, "secret").(bool)

	if def.type == .Int || def.type == .Number {
		if v, has := number_of(field(m, "min")); has {
			def.min, def.has_min = v, true
		}
		if v, has := number_of(field(m, "max")); has {
			def.max, def.has_max = v, true
		}
		if def.has_min && def.has_max && def.min > def.max {
			bad(problems, allocator, n, "min is more than max")
			def.has_min, def.has_max = false, false
		}
	}
	if def.type == .String {
		def.max_len = DEFAULT_SETTING_STRING
		if v, has := number_of(field(m, "max_length")); has && v >= 1 {
			def.max_len = min(int(v), MAX_SETTING_STRING)
		}
	}
	if def.type == .Choice {
		choices := make([dynamic]string, allocator)
		if list, has := field(m, "choices").(List); has {
			for c in list {
				if text, is_text := c.(string);
				   is_text && text != "" && len(choices) < MAX_CHOICES {
					append(&choices, strings.clone(cut(text, MAX_CHOICE), allocator))
				}
			}
		}
		def.choices = choices[:]
		if len(def.choices) == 0 {
			bad(problems, allocator, n, "a choice needs a list of choices")
			setting_def_destroy(&def, allocator)
			return {}, false
		}
	}
	// The default, or what stands in for it when it is missing or no good.
	fallback: Value
	switch def.type {
	case .Bool:
		fallback = false
	case .Int:
		fallback = i64(clamp_to(&def, 0))
	case .Number:
		fallback = clamp_to(&def, 0)
	case .String:
		fallback = ""
	case .Choice:
		fallback = def.choices[0]
	}
	given := field(m, "default")
	value, valid := fallback, true
	if given != nil {
		value, valid = setting_value(&def, given)
	}
	if !valid {
		bad(problems, allocator, n, "the default doesn't fit its type")
		value = fallback
	}
	if s, is_text := value.(string); is_text {
		value = strings.clone(s, allocator)
	}
	def.default = value
	return def, true
}

@(private = "file")
setting_def_destroy :: proc(d: ^Setting_Def, allocator: runtime.Allocator) {
	delete(d.key, allocator)
	delete(d.label, allocator)
	delete(d.description, allocator)
	for ch in d.choices {
		delete(ch, allocator)
	}
	delete(d.choices, allocator)
}

@(private = "file")
clamp_to :: proc(d: ^Setting_Def, v: f64) -> f64 {
	out := v
	if d.has_min {
		out = max(out, d.min)
	}
	if d.has_max {
		out = min(out, d.max)
	}
	return out
}

// setting_value checks a value for a setting and returns it as the setting holds
// it: a number is clamped to the range, an int is whole, a string is cut to the
// length it may have, a choice must be one of the choices. ok is false if it
// can't be made to fit. A string it returns is a slice of the one it was given.
setting_value :: proc(d: ^Setting_Def, v: Value) -> (out: Value, ok: bool) {
	switch d.type {
	case .Bool:
		b, is_bool := v.(bool)
		return b, is_bool
	case .Int:
		n, is_number := number_of(v)
		if !is_number || n != math.floor(n) || abs(n) > 9e15 {
			return nil, false
		}
		return i64(clamp_to(d, n)), true
	case .Number:
		n, is_number := number_of(v)
		if !is_number {
			return nil, false
		}
		return clamp_to(d, n), true
	case .String:
		text, is_text := v.(string)
		if !is_text {
			return nil, false
		}
		limit := d.max_len if d.max_len > 0 else DEFAULT_SETTING_STRING
		return cut(text, limit), true
	case .Choice:
		text, is_text := v.(string)
		if !is_text {
			return nil, false
		}
		for c in d.choices {
			if c == text {
				return text, true
			}
		}
		return nil, false
	}
	return nil, false
}

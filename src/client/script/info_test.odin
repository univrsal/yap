#+build !wasi
package script

import "core:strings"
import "core:testing"

@(test)
test_call_sync_returns_tables :: proc(t: ^testing.T) {
	s := new_script(t)
	defer destroy(s)
	load(
		t,
		s,
		`
		function t() return { name = "n", list = {1, 2.5, "x", true}, nested = { a = { b = 1 } }, empty = {}, f = print } end
		function holes() return { [1] = "a", [3] = "c" } end
		function mixed() return { "a", b = 1 } end
		function deep() local t = {} local c = t for i = 1, 20 do c.x = {} c = c.x end return t end
		function num() return 7 end
		function nothing() end
		`,
	)
	v, found, err := call_sync(s, "t", nil)
	testing.expect(t, found)
	testing.expect_value(t, err, "")
	m, is_map := v.(Map)
	testing.expect(t, is_map)
	get :: proc(m: Map, key: string) -> Value {
		for p in m {
			if p.key == key {
				return p.value
			}
		}
		return nil
	}
	testing.expect_value(t, get(m, "name").(string), "n")
	list, is_list := get(m, "list").(List)
	testing.expect(t, is_list)
	testing.expect_value(t, len(list), 4)
	if len(list) == 4 {
		testing.expect_value(t, list[0].(i64), 1)
		testing.expect_value(t, list[1].(f64), 2.5)
		testing.expect_value(t, list[2].(string), "x")
		testing.expect_value(t, list[3].(bool), true)
	}
	inner, _ := get(get(m, "nested").(Map), "a").(Map)
	testing.expect_value(t, get(inner, "b").(i64), 1)
	empty, empty_is_list := get(m, "empty").(List)
	testing.expect(t, empty_is_list && len(empty) == 0)
	testing.expect(t, get(m, "f") == nil) // a function isn't a value

	// What can't be read is nil.
	for name in ([]string{"holes", "mixed", "deep"}) {
		v, found, err = call_sync(s, name, nil)
		testing.expect(t, found)
		testing.expect_value(t, err, "")
		testing.expect(t, v == nil, name)
	}
	v, _, _ = call_sync(s, "num", nil)
	testing.expect_value(t, v.(i64), 7)
	v, found, _ = call_sync(s, "nothing", nil)
	testing.expect(t, found && v == nil)
	_, found, _ = call_sync(s, "nope", nil)
	testing.expect(t, !found)
}

@(test)
test_read_info :: proc(t: ^testing.T) {
	source := `
		yap.register_command("hi", function() end) -- harmless while being read
		yap.send("general", "not sent")
		function get_info()
			return {
				name = "Keywords", description = "Tells you.", version = "1.2", author = "me",
				permissions = { "notify", "send", "nonsense" },
				servers = { "chat.example.com:7777" },
				settings = {
					{ key = "words", label = "Keywords", type = "string", default = "yap", description = "Comma separated" },
					{ key = "volume", type = "number", default = 5, min = 0, max = 1 },
					{ key = "count", type = "int", default = 3.5, min = 1, max = 10 },
					{ key = "loud", type = "bool" },
					{ key = "where", type = "choice", default = "dms", choices = { "all", "dms" } },
					{ key = "token", type = "string", secret = true },
					{ key = "words", type = "string" },
					{ key = "bad key", type = "string" },
					{ key = "x", type = "color" },
					{ key = "c", type = "choice" },
					"not a table",
				},
			}
		end`
	info, has, err := read_info("keywords.lua", source)
	defer info_destroy(&info)
	testing.expect(t, has)
	testing.expect_value(t, err, "")
	testing.expect_value(t, info.name, "Keywords")
	testing.expect_value(t, info.description, "Tells you.")
	testing.expect_value(t, info.version, "1.2")
	testing.expect_value(t, info.author, "me")
	testing.expect_value(t, info.permissions, Permissions{.Send, .Notify})
	testing.expect_value(t, len(info.servers), 1)
	// The six good settings. A note for each of the five that were not, for the
	// permission, and for the int default 3.5 that is not whole.
	testing.expect_value(t, len(info.settings), 6)
	testing.expect_value(t, len(info.problems), 7)
	if len(info.settings) == 6 {
		words, volume, count, loud, place, token := info.settings[0], info.settings[1], info.settings[2], info.settings[3], info.settings[4], info.settings[5]
		testing.expect_value(t, words.default.(string), "yap")
		testing.expect_value(t, volume.default.(f64), 1) // clamped to the range
		testing.expect_value(t, count.default.(i64), 1) // an int doesn't take 3.5: the least it may be
		testing.expect_value(t, loud.default.(bool), false)
		testing.expect_value(t, place.default.(string), "dms")
		testing.expect_value(t, token.default.(string), "")
		testing.expect(t, token.secret)
		testing.expect_value(t, words.label, "Keywords")
		testing.expect_value(t, token.label, "token") // the key, without a label
	}
}

@(test)
test_read_info_without_get_info_or_with_trouble :: proc(t: ^testing.T) {
	info, has, err := read_info("plain.lua", "function on_message() end")
	testing.expect(t, !has)
	testing.expect_value(t, err, "")
	info_destroy(&info)

	for source in ([]string{"function (", "error('boom')", "while true do end", "function get_info() error('oops') end", "function get_info() while true do end end"}) {
		info, has, err = read_info("bad.lua", source)
		testing.expect(t, !has, source)
		testing.expectf(t, err != "", "no error for %q", source)
		info_destroy(&info)
	}

	// get_info that doesn't return a table is a problem, not a failure.
	info, has, err = read_info("odd.lua", "function get_info() return 5 end")
	testing.expect(t, has)
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(info.problems), 1)
	info_destroy(&info)
}

@(test)
test_setting_values_are_checked :: proc(t: ^testing.T) {
	choices := []string{"a", "b"}
	def :: proc(type: Setting_Type, choices: []string) -> Setting_Def {
		return Setting_Def{type = type, max_len = 5, choices = choices}
	}
	check :: proc(t: ^testing.T, d: ^Setting_Def, v: Value, want: Value, ok: bool, loc := #caller_location) {
		got, valid := setting_value(d, v)
		testing.expect_value(t, valid, ok, loc = loc)
		if ok {
			switch w in want {
			case bool:
				testing.expect_value(t, got.(bool), w, loc = loc)
			case i64:
				testing.expect_value(t, got.(i64), w, loc = loc)
			case f64:
				testing.expect_value(t, got.(f64), w, loc = loc)
			case string:
				testing.expect_value(t, got.(string), w, loc = loc)
			case List, Map, Function:
			}
		}
	}
	b := def(.Bool, choices)
	check(t, &b, true, true, true)
	check(t, &b, "true", nil, false)
	check(t, &b, i64(1), nil, false)

	i := def(.Int, choices)
	i.min, i.max, i.has_min, i.has_max = 1, 10, true, true
	check(t, &i, i64(5), i64(5), true)
	check(t, &i, i64(50), i64(10), true)
	check(t, &i, i64(-3), i64(1), true)
	check(t, &i, 4.0, i64(4), true) // whole, so it is fine
	check(t, &i, 4.5, nil, false)
	check(t, &i, "4", nil, false)
	check(t, &i, 1e300, nil, false)

	n := def(.Number, choices)
	n.min, n.has_min = 0, true
	check(t, &n, 0.25, 0.25, true)
	check(t, &n, i64(-4), f64(0), true)
	huge: f64 = 1e308
	check(t, &n, huge * 10, nil, false) // infinity

	s := def(.String, choices)
	check(t, &s, "abc", "abc", true)
	check(t, &s, "abcdefgh", "abcde", true) // cut
	check(t, &s, "aé", "aé", true)
	check(t, &s, "ééé", "éé", true) // not in the middle of a character
	check(t, &s, i64(5), nil, false)

	c := def(.Choice, choices)
	check(t, &c, "a", "a", true)
	check(t, &c, "z", nil, false)
	check(t, &c, i64(1), nil, false)
}

_ :: strings.contains

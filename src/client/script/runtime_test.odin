#+build !wasi
package script

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

import "client:conn"
import "common:proto"

@(private)
Rig :: struct {
	rt: ^Runtime,
	a:  ^conn.Server_Conn,
	b:  ^conn.Server_Conn,
}

@(private)
rig_new :: proc(dir := "") -> (r: Rig) {
	r.rt = runtime_create(dir)
	r.a = new(conn.Server_Conn)
	r.b = new(conn.Server_Conn)
	r.a.server_addr = "a.example:7777"
	r.a.server_key[0] = 0xaa
	r.b.server_addr = "b.example:7777"
	r.b.server_key[0] = 0xbb
	runtime_attach(r.rt, r.a)
	runtime_attach(r.rt, r.b)
	return
}

@(private)
rig_destroy :: proc(r: ^Rig) {
	runtime_detach(r.rt, r.a)
	runtime_detach(r.rt, r.b)
	runtime_destroy(r.rt)
	conn.commands_destroy(&r.a.commands)
	conn.commands_destroy(&r.b.commands)
	free(r.a)
	free(r.b)
}

// The chat commands queued for a connection.
@(private)
posted :: proc(c: ^Server_Conn_Alias) -> (texts: [dynamic]string) {
	for cmd in c.commands.commands {
		if chat, ok := cmd.(conn.Chat_Command); ok {
			append(&texts, fmt.tprintf("%s: %s", chat.channel, chat.text))
		}
	}
	return
}

@(private = "file")
Server_Conn_Alias :: conn.Server_Conn

@(private)
message :: proc(text: string, mentions_me := false) -> conn.Event {
	return conn.Event_Message {
		id = 41,
		conv = 3,
		channel = strings.clone("general"),
		kind = .Channel,
		msg_kind = .Text,
		author = 9,
		author_name = strings.clone("Ann"),
		username = strings.clone("ann"),
		text = strings.clone(text),
		time = 1700000000000,
		mentions_me = mentions_me,
	}
}

@(private)
emit :: proc(c: ^conn.Server_Conn, e: conn.Event) {
	sync_append(c, e)
}

@(private)
sync_append :: proc(c: ^conn.Server_Conn, e: conn.Event) {
	conn.sink_put_for_test(c, e)
}

@(test)
test_message_reaches_script_and_reply_is_queued :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_destroy(&r)
	ok := runtime_add(
		r.rt,
		"echo.lua",
		`
		function on_message(ev)
			if ev.mine then return end
			assert(ev.server.address == "a.example:7777", ev.server.address)
			assert(ev.server.key:sub(1, 2) == "aa" and #ev.server.key == 64)
			assert(ev.kind == "channel" and ev.type == "text" and ev.channel == "general")
			assert(ev.id == "41" and ev.author == "Ann" and ev.username == "ann" and ev.author_id == "9")
			assert(ev.thread == nil and ev.time == 1700000000000 and ev.mentions_me == true)
			yap.send(ev.channel, "echo: " .. ev.text)
		end
		`,
		Script_Config{enabled = true, permissions = {"send"}},
	)
	testing.expect(t, ok)
	emit(r.a, message("hello", true))
	runtime_step(r.rt, 5 * time.Millisecond)
	texts := posted(r.a)
	defer delete(texts)
	testing.expect_value(t, len(texts), 1)
	if len(texts) == 1 {
		testing.expect_value(t, texts[0], "general: echo: hello")
	}
	// It was for the server the message came from.
	other := posted(r.b)
	defer delete(other)
	testing.expect_value(t, len(other), 0)
}

@(test)
test_scripts_only_run_for_their_servers :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_destroy(&r)
	source := `function on_message(ev) yap.send("c", ev.server.address) end`
	// By address, ignoring case; by key; and for all of them.
	testing.expect(t, runtime_add(r.rt, "by_address.lua", source, Script_Config{permissions = {"send"}, servers = {"A.EXAMPLE:7777"}}))
	key_b := fmt.tprintf("bb%s", strings.repeat("0", 62, context.temp_allocator))
	testing.expect(t, runtime_add(r.rt, "by_key.lua", source, Script_Config{permissions = {"send"}, servers = {key_b}}))
	testing.expect(t, runtime_add(r.rt, "all.lua", source, Script_Config{permissions = {"send"}}))

	emit(r.a, message("x"))
	emit(r.b, message("x"))
	runtime_step(r.rt, 10 * time.Millisecond)
	a := posted(r.a)
	b := posted(r.b)
	defer delete(a)
	defer delete(b)
	// On a: by_address and all. On b: by_key and all.
	testing.expect_value(t, len(a), 2)
	testing.expect_value(t, len(b), 2)
}

@(test)
test_connect_and_presence_events :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_destroy(&r)
	testing.expect(
		t,
		runtime_add(
			r.rt,
			"watch.lua",
			`
			function on_connect(ev) yap.send("log", "connected " .. ev.server.address) end
			function on_disconnect(ev) yap.send("log", "disconnected " .. ev.why) end
			function on_presence(ev) yap.send("log", ev.user .. " " .. ev.was .. " -> " .. ev.state) end
			`,
			Script_Config{permissions = {"send"}},
		),
	)
	emit(r.a, conn.Event_Connected{})
	emit(r.a, conn.Event_Presence{account = 4, name = strings.clone("Bob"), username = strings.clone("bob"), activity = .Away, was = .Online})
	emit(r.a, conn.Event_Disconnected{why = strings.clone("timeout")})
	runtime_step(r.rt, 10 * time.Millisecond)
	texts := posted(r.a)
	defer delete(texts)
	testing.expect_value(t, len(texts), 3)
	if len(texts) == 3 {
		testing.expect_value(t, texts[0], "log: connected a.example:7777")
		testing.expect_value(t, texts[1], "log: Bob online -> away")
		testing.expect_value(t, texts[2], "log: disconnected timeout")
	}
}

@(test)
test_a_failing_handler_does_not_stop_the_others :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_destroy(&r)
	testing.expect(t, runtime_add(r.rt, "bad.lua", `function on_message(ev) error("oops") end`, Script_Config{}))
	testing.expect(t, runtime_add(r.rt, "loop.lua", `function on_message(ev) while true do end end`, Script_Config{}))
	testing.expect(t, runtime_add(r.rt, "good.lua", `function on_message(ev) yap.send("c", "fine") end`, Script_Config{permissions = {"send"}}))
	emit(r.a, message("x"))
	// Until every script is done, however long a sleep takes on this system.
	busy :: proc(r: ^Rig) -> bool {
		for e in r.rt.entries {
			if pending(e.script) > 0 {
				return true
			}
		}
		return false
	}
	began := time.tick_now()
	for time.tick_since(began) < 5 * time.Second {
		runtime_step(r.rt, 2 * time.Millisecond)
		if !busy(&r) {
			break
		}
	}
	testing.expect(t, !busy(&r), "the scripts did not finish")
	testing.expectf(t, time.tick_since(began) < 3 * time.Second, "took %v", time.tick_since(began))
	texts := posted(r.a)
	defer delete(texts)
	testing.expect_value(t, len(texts), 1)
}

@(test)
test_a_script_that_does_not_load_is_not_run :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_destroy(&r)
	testing.expect(t, !runtime_add(r.rt, "syntax.lua", "function (", Script_Config{}))
	testing.expect(t, !runtime_add(r.rt, "throws.lua", "error('no')", Script_Config{}))
	testing.expect(t, !runtime_add(r.rt, "spins.lua", "while true do end", Script_Config{}))
	testing.expect_value(t, len(r.rt.entries), 0)
}

@(test)
test_load_from_config_and_keep_the_store :: proc(t: ^testing.T) {
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	dir := fmt.aprintf("%s/yap-script-test-%d", tmp if tmp != "" else "/tmp", time.tick_now()._nsec)
	defer delete(dir)
	defer os.remove_all(dir)
	{
		config := `{"scripts": {"count.lua": {"enabled": true, "permissions": ["send"], "servers": ["a.example:7777"]}, "off.lua": {"enabled": false}}}`
		script := `
			function on_message(ev)
				local n = (yap.store.get("n") or 0) + 1
				yap.store.set("n", n)
				yap.store.set("who", ev.author)
				yap.send("c", "message " .. n)
			end`
		os.make_directory_all(dir)
		_ = os.write_entire_file(fmt.tprintf("%s/config.json", dir), transmute([]u8)config)
		_ = os.write_entire_file(fmt.tprintf("%s/count.lua", dir), transmute([]u8)script)
		_ = os.write_entire_file(fmt.tprintf("%s/off.lua", dir), transmute([]u8)string("syntax error here"))
	}

	for run in 1 ..= 2 {
		r := rig_new(dir)
		runtime_load(r.rt)
		testing.expect_value(t, len(r.rt.entries), 1) // the one that is on
		emit(r.a, message("x"))
		emit(r.b, message("x")) // not its server
		runtime_step(r.rt, 10 * time.Millisecond)
		texts := posted(r.a)
		testing.expect_value(t, len(texts), 1)
		if len(texts) == 1 {
			// The second time, it goes on from what the first run kept.
			testing.expect_value(t, texts[0], fmt.tprintf("c: message %d", run))
		}
		other := posted(r.b)
		testing.expect_value(t, len(other), 0)
		delete(texts)
		delete(other)
		rig_destroy(&r) // saves the store
	}
	saved, ok := os.read_entire_file(fmt.tprintf("%s/data/count.lua.json", dir), context.temp_allocator)
	testing.expect(t, ok == nil)
	testing.expectf(t, strings.contains(string(saved), `"who": "Ann"`), "saved: %s", saved)
}

@(test)
test_events_are_dropped_when_nobody_listens :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_destroy(&r)
	emit(r.a, message("x"))
	runtime_step(r.rt, time.Millisecond)
	events := conn.sink_take(r.a.events)
	testing.expect_value(t, len(events), 0)
}

_ :: proto.Account_Id

@(test)
test_script_commands_run_for_their_servers :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_destroy(&r)
	src := `
		yap.register_command("roll", "Roll dice, like /roll 2d6", function(ev)
			assert(ev.name == "roll" and ev.args == "2d6 x" and ev.argv[1] == "2d6" and #ev.argv == 2)
			assert(ev.channel == "general" and ev.server.address)
			yap.send(ev.channel, "rolled " .. ev.args .. " on " .. ev.server.address)
		end)`
	testing.expect(t, runtime_add(r.rt, "dice.lua", src, Script_Config{permissions = {"send"}, servers = {"a.example:7777"}}))
	testing.expect(t, runtime_add(r.rt, "all.lua", `yap.register_command("hello", "Say hello", function() end)`, Script_Config{}))

	list_a := runtime_commands(r.rt, r.a)
	list_b := runtime_commands(r.rt, r.b)
	testing.expect_value(t, len(list_a), 2)
	testing.expect_value(t, len(list_b), 1) // not the one for the other server
	if len(list_a) == 2 {
		testing.expect_value(t, list_a[0].name, "hello") // by name
		testing.expect_value(t, list_a[1].name, "roll")
		testing.expect_value(t, list_a[1].help, "Roll dice, like /roll 2d6")
		testing.expect_value(t, list_a[1].script, "dice.lua")
	}

	testing.expect(t, !runtime_run_command(r.rt, r.b, "/roll 2d6 x", "general")) // not its server
	testing.expect(t, !runtime_run_command(r.rt, r.a, "/nothing", "general"))
	testing.expect(t, !runtime_run_command(r.rt, r.a, "roll 2d6", "general")) // no slash
	testing.expect(t, runtime_run_command(r.rt, r.a, "  /ROLL   2d6 x ", "general"))
	runtime_step(r.rt, 10 * time.Millisecond)
	texts := posted(r.a)
	defer delete(texts)
	testing.expect_value(t, len(texts), 1)
	if len(texts) == 1 {
		testing.expect_value(t, texts[0], "general: rolled 2d6 x on a.example:7777")
	}
}

@(private = "file")
incoming :: proc(c: ^conn.Server_Conn, text: string, sender := proto.Account_Id(9)) -> (shown: string, hidden: bool) {
	out, hide := conn.filter_message(c, proto.Message{id = 5, conv = 3, sender = sender, kind = .Text, text = text})
	return out.text, hide
}

@(test)
test_incoming_filters :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_destroy(&r)
	r.a.auth.me = 1
	r.b.auth.me = 1
	testing.expect(
		t,
		runtime_add(
			r.rt,
			"filter.lua",
			`
			function on_incoming(ev)
				assert(ev.server.address and ev.id == "5" and ev.kind == "channel" and ev.mine == false)
				if ev.text:find("buy pills") then return false end
				if ev.text:find("darn") then return (ev.text:gsub("darn", "****")) end
			end`,
			Script_Config{servers = {"a.example:7777"}},
		),
	)
	// A second script sees what the first made of it.
	testing.expect(
		t,
		runtime_add(
			r.rt,
			"second.lua",
			`function on_incoming(ev) if ev.text:find("%*%*%*%*") then return ev.text .. " (censored)" end end`,
			Script_Config{},
		),
	)
	shown, hidden := incoming(r.a, "hello")
	testing.expect_value(t, shown, "hello")
	testing.expect(t, !hidden)
	shown, hidden = incoming(r.a, "well darn it")
	testing.expect_value(t, shown, "well **** it (censored)")
	testing.expect(t, !hidden)
	shown, hidden = incoming(r.a, "buy pills now")
	testing.expect_value(t, shown, conn.HIDDEN_TEXT)
	testing.expect(t, hidden)

	// The first only runs for server a.
	shown, hidden = incoming(r.b, "buy pills now")
	testing.expect_value(t, shown, "buy pills now")
	testing.expect(t, !hidden)

	// Nor does it touch what we sent ourselves.
	shown, hidden = incoming(r.a, "buy pills now", sender = 1)
	testing.expect_value(t, shown, "buy pills now")
	testing.expect(t, !hidden)
}

@(test)
test_incoming_filter_does_not_wait_for_a_busy_runtime :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_destroy(&r)
	testing.expect(t, runtime_add(r.rt, "f.lua", `function on_incoming(ev) return false end`, Script_Config{}))
	sync.mutex_lock(&r.rt.mutex) // as if a step were running
	began := time.tick_now()
	shown, hidden := incoming(r.a, "hello")
	took := time.tick_since(began)
	sync.mutex_unlock(&r.rt.mutex)
	testing.expect_value(t, shown, "hello") // shown as it is
	testing.expect(t, !hidden)
	testing.expectf(t, took < 50 * time.Millisecond, "waited %v", took)
	shown, hidden = incoming(r.a, "hello")
	testing.expect(t, hidden)
}

@(test)
test_a_bad_incoming_filter_is_switched_off :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_destroy(&r)
	testing.expect(t, runtime_add(r.rt, "bad.lua", `function on_incoming(ev) while true do end end`, Script_Config{}))
	began := time.tick_now()
	for _ in 0 ..< 10 {
		shown, hidden := incoming(r.a, "hello")
		testing.expect_value(t, shown, "hello")
		testing.expect(t, !hidden)
	}
	// Three that took the filter's limit, and the other seven nothing.
	testing.expectf(t, time.tick_since(began) < 100 * time.Millisecond, "took %v", time.tick_since(began))
	testing.expect(t, r.rt.entries[0].script.filters_off)
}

@(test)
test_send_filters :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_destroy(&r)
	testing.expect(
		t,
		runtime_add(
			r.rt,
			"send.lua",
			`
			function on_send(ev)
				assert(ev.channel == "general" and ev.server.address == "a.example:7777")
				if ev.text:find("password") then return false end
				if ev.text:sub(1, 1) == "!" then return "[bot] " .. ev.text:sub(2) end
			end`,
			Script_Config{servers = {"a.example:7777"}},
		),
	)
	text, cancel, by := runtime_filter_send(r.rt, r.a, "general", "hi")
	testing.expect_value(t, text, "hi")
	testing.expect(t, !cancel)
	text, cancel, by = runtime_filter_send(r.rt, r.a, "general", "!status")
	testing.expect_value(t, text, "[bot] status")
	testing.expect(t, !cancel)
	text, cancel, by = runtime_filter_send(r.rt, r.a, "general", "my password is x")
	testing.expect(t, cancel)
	testing.expect_value(t, by, "send.lua")
	// Not for the other server.
	text, cancel, by = runtime_filter_send(r.rt, r.b, "general", "my password is x")
	testing.expect(t, !cancel)
}

// A folder of scripts for a test, removed at its end.
@(private)
File :: struct {
	name, text: string,
}

@(private)
Folder :: struct {
	dir: string,
}

@(private)
folder_make :: proc(files: ..File) -> (f: Folder) {
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	f.dir = fmt.aprintf("%s/yap-script-test-%d", tmp if tmp != "" else "/tmp", time.tick_now()._nsec)
	_ = os.make_directory_all(f.dir)
	for file in files {
		_ = os.write_entire_file(fmt.tprintf("%s/%s", f.dir, file.name), transmute([]u8)file.text)
	}
	return
}

@(private)
folder_destroy :: proc(f: ^Folder) {
	os.remove_all(f.dir)
	delete(f.dir)
}

@(private = "file")
view_of :: proc(rt: ^Runtime, file: string) -> (v: Item_View, ok: bool) {
	for x in runtime_snapshot(rt) {
		if x.file == file {
			return x, true
		}
	}
	return {}, false
}

KEYWORDS :: `
function get_info()
	return {
		name = "Keywords", description = "Tells you.", version = "1.0",
		permissions = { "send" },
		settings = {
			{ key = "word", type = "string", default = "yap" },
			{ key = "count", type = "int", default = 2, min = 1, max = 5 },
		},
	}
end
seen = {}
function on_load(ev) yap.send("c", "loaded with " .. ev.settings.word .. " " .. ev.settings.count, "a.example:7777") end
function on_setting(ev) yap.send("c", "changed " .. ev.key .. " to " .. tostring(ev.value), "a.example:7777") end
function on_message(ev) yap.send("c", "word is " .. yap.setting("word") .. ", " .. tostring(yap.setting("count")) .. ", " .. tostring(yap.setting("nothing"))) end
`

@(test)
test_scripts_are_found_but_do_not_run_until_approved :: proc(t: ^testing.T) {
	f := folder_make(File{"keywords.lua", KEYWORDS}, File{"plain.lua", "function on_message() end"}, File{"notes.txt", "not a script"}, File{"broken.lua", "function ("})
	defer folder_destroy(&f)
	r := rig_new(f.dir)
	defer rig_destroy(&r)
	runtime_load(r.rt)
	testing.expect_value(t, runtime_scripts(r.rt), 0) // nothing is running

	views := runtime_snapshot(r.rt)
	testing.expect_value(t, len(views), 3) // the three .lua files, by name
	v, ok := view_of(r.rt, "keywords.lua")
	testing.expect(t, ok)
	testing.expect_value(t, v.name, "Keywords")
	testing.expect_value(t, v.requested, Permissions{.Send})
	testing.expect(t, !v.enabled && !v.running)
	testing.expect_value(t, len(v.settings), 2)
	testing.expect_value(t, v.settings[0].value.(string), "yap")
	plain, _ := view_of(r.rt, "plain.lua")
	testing.expect_value(t, plain.name, "plain.lua") // no name of its own
	broken, _ := view_of(r.rt, "broken.lua")
	testing.expect(t, broken.problem != "")

	// Approving it starts it, with what it was approved for.
	testing.expect_value(t, runtime_set_enabled(r.rt, "keywords.lua", true, {.Send}), "")
	testing.expect_value(t, runtime_scripts(r.rt), 1)
	runtime_step(r.rt, 10 * time.Millisecond)
	texts := posted(r.a)
	defer delete(texts)
	testing.expect_value(t, len(texts), 1)
	if len(texts) == 1 {
		testing.expect_value(t, texts[0], "c: loaded with yap 2") // on_load got the settings
	}
	// A script that can't be read can't be switched on.
	testing.expect(t, runtime_set_enabled(r.rt, "broken.lua", true, {}) != "")
	testing.expect_value(t, runtime_set_enabled(r.rt, "nothing.lua", true, {}), "there is no such script")
}

@(test)
test_approval_is_for_the_text_that_was_approved :: proc(t: ^testing.T) {
	f := folder_make(File{"keywords.lua", KEYWORDS})
	defer folder_destroy(&f)
	{
		r := rig_new(f.dir)
		runtime_load(r.rt)
		testing.expect_value(t, runtime_set_enabled(r.rt, "keywords.lua", true, {.Send}), "")
		rig_destroy(&r)
	}
	// A new run starts it by itself, as it was approved.
	{
		r := rig_new(f.dir)
		runtime_load(r.rt)
		testing.expect_value(t, runtime_scripts(r.rt), 1)
		v, _ := view_of(r.rt, "keywords.lua")
		testing.expect(t, v.enabled && v.running && !v.changed)
		testing.expect_value(t, v.granted, Permissions{.Send})
		rig_destroy(&r)
	}
	// Changed, it is not: it asks again, and gets nothing until it is.
	_ = os.write_entire_file(fmt.tprintf("%s/keywords.lua", f.dir), transmute([]u8)string(KEYWORDS + "\n-- now it does something else\n"))
	{
		r := rig_new(f.dir)
		runtime_load(r.rt)
		testing.expect_value(t, runtime_scripts(r.rt), 0)
		v, _ := view_of(r.rt, "keywords.lua")
		testing.expect(t, v.changed && !v.enabled && !v.running)
		testing.expect(t, v.problem != "")
		testing.expect_value(t, v.granted, Permissions{})
		// Switching it on again approves the new text, with whatever is granted now.
		testing.expect_value(t, runtime_set_enabled(r.rt, "keywords.lua", true, {}), "")
		v, _ = view_of(r.rt, "keywords.lua")
		testing.expect(t, v.running && !v.changed)
		testing.expect_value(t, v.granted, Permissions{})
		rig_destroy(&r)
	}
	// And that is kept.
	{
		r := rig_new(f.dir)
		runtime_load(r.rt)
		testing.expect_value(t, runtime_scripts(r.rt), 1)
		rig_destroy(&r)
	}
}

@(test)
test_settings_are_checked_kept_and_told_to_the_script :: proc(t: ^testing.T) {
	f := folder_make(File{"keywords.lua", KEYWORDS})
	defer folder_destroy(&f)
	for run in 1 ..= 2 {
		r := rig_new(f.dir)
		runtime_load(r.rt)
		if run == 1 {
			testing.expect_value(t, runtime_set_enabled(r.rt, "keywords.lua", true, {.Send}), "")
			testing.expect_value(t, runtime_set_value(r.rt, "keywords.lua", "word", "tea"), "")
			testing.expect_value(t, runtime_set_value(r.rt, "keywords.lua", "count", i64(99)), "") // clamped
			testing.expect(t, runtime_set_value(r.rt, "keywords.lua", "count", "many") != "")
			testing.expect(t, runtime_set_value(r.rt, "keywords.lua", "nothing", i64(1)) != "")
			runtime_step(r.rt, 10 * time.Millisecond)
			texts := posted(r.a)
			// on_load with the defaults, and a on_setting for each of the two changes.
			testing.expect_value(t, len(texts), 3)
			if len(texts) == 3 {
				testing.expect_value(t, texts[0], "c: loaded with yap 2")
				testing.expect_value(t, texts[1], "c: changed word to tea")
				testing.expect_value(t, texts[2], "c: changed count to 5")
			}
			delete(texts)
		} else {
			// Kept: the script starts with them.
			runtime_step(r.rt, 10 * time.Millisecond)
			texts := posted(r.a)
			testing.expect_value(t, len(texts), 1)
			if len(texts) == 1 {
				testing.expect_value(t, texts[0], "c: loaded with tea 5")
			}
			delete(texts)
			emit(r.a, message("x"))
			runtime_step(r.rt, 10 * time.Millisecond)
			texts = posted(r.a)
			testing.expect_value(t, len(texts), 2)
			if len(texts) == 2 {
				testing.expect_value(t, texts[1], "c: word is tea, 5, nil")
			}
			delete(texts)
		}
		rig_destroy(&r)
	}
}

@(test)
test_scope_is_kept :: proc(t: ^testing.T) {
	f := folder_make(File{"plain.lua", "function on_message() end"})
	defer folder_destroy(&f)
	{
		r := rig_new(f.dir)
		runtime_load(r.rt)
		runtime_set_scope(r.rt, "plain.lua", false, {"a.example:7777"})
		testing.expect_value(t, runtime_set_enabled(r.rt, "plain.lua", true, {}), "")
		rig_destroy(&r)
	}
	r := rig_new(f.dir)
	defer rig_destroy(&r)
	runtime_load(r.rt)
	v, _ := view_of(r.rt, "plain.lua")
	testing.expect(t, !v.all_servers)
	testing.expect_value(t, len(v.servers), 1)
	list_a := runtime_commands(r.rt, r.a)
	_ = list_a
	runtime_set_scope(r.rt, "plain.lua", true, nil)
	v, _ = view_of(r.rt, "plain.lua")
	testing.expect(t, v.all_servers)
}

@(test)
test_adding_removing_and_reloading :: proc(t: ^testing.T) {
	f := folder_make()
	defer folder_destroy(&f)
	r := rig_new(f.dir)
	defer rig_destroy(&r)
	runtime_load(r.rt)
	testing.expect_value(t, len(runtime_snapshot(r.rt)), 0)

	testing.expect(t, runtime_add_source(r.rt, "../escape.lua", "x") != "")
	testing.expect(t, runtime_add_source(r.rt, "noext", "x") != "")
	testing.expect(t, runtime_add_source(r.rt, "big.lua", strings.repeat("x", MAX_SCRIPT_SIZE + 1, context.temp_allocator)) != "")
	testing.expect_value(t, runtime_add_source(r.rt, "new.lua", `function get_info() return { name = "New" } end`), "")
	v, ok := view_of(r.rt, "new.lua")
	testing.expect(t, ok)
	testing.expect_value(t, v.name, "New")
	testing.expect(t, !v.enabled)

	// A file put in the folder by hand is found by a reload.
	_ = os.write_entire_file(fmt.tprintf("%s/hand.lua", f.dir), transmute([]u8)string("x = 1"))
	testing.expect_value(t, len(runtime_snapshot(r.rt)), 1)
	runtime_reload(r.rt)
	testing.expect_value(t, len(runtime_snapshot(r.rt)), 2)

	testing.expect_value(t, runtime_set_enabled(r.rt, "new.lua", true, {}), "")
	testing.expect_value(t, runtime_scripts(r.rt), 1)
	runtime_remove_source(r.rt, "new.lua")
	testing.expect_value(t, runtime_scripts(r.rt), 0)
	testing.expect_value(t, len(runtime_snapshot(r.rt)), 1)
	runtime_reload(r.rt)
	testing.expect_value(t, len(runtime_snapshot(r.rt)), 1) // it is gone for good
}

// The example script in docs/examples/scripts, which people try the Scripts page
// with: it has to work.
SHOWCASE :: #load("../../../docs/examples/scripts/showcase.lua", string)

@(test)
test_the_showcase_example :: proc(t: ^testing.T) {
	info, has, err := read_info("showcase.lua", SHOWCASE)
	defer info_destroy(&info)
	testing.expect(t, has)
	testing.expect_value(t, err, "")
	testing.expect_value(t, info.name, "Showcase")
	testing.expect_value(t, info.permissions, Permissions{.Send, .Notify})
	testing.expect_value(t, len(info.settings), 8)
	testing.expect_value(t, len(info.problems), 0)
	types: [Setting_Type]int
	for d in info.settings {
		types[d.type] += 1
	}
	// Every kind of setting is there, and a number with and without a range.
	testing.expect_value(t, types[.Bool], 2)
	testing.expect_value(t, types[.Int], 1)
	testing.expect_value(t, types[.Number], 2)
	testing.expect_value(t, types[.String], 2)
	testing.expect_value(t, types[.Choice], 1)

	f := folder_make()
	defer folder_destroy(&f)
	r := rig_new(f.dir)
	defer rig_destroy(&r)
	v := notices_on(r.a)
	defer notices_off(r.a, v)
	runtime_notifications_to_ui(r.rt)
	testing.expect(t, runtime_add(r.rt, "showcase.lua", SHOWCASE, Script_Config{permissions = {"send", "notify"}}))
	cmds := runtime_commands(r.rt, r.a)
	testing.expect_value(t, len(cmds), 3)
	if len(cmds) == 3 {
		testing.expect_value(t, cmds[0].name, "hello")
		testing.expect_value(t, cmds[1].name, "remind")
		testing.expect_value(t, cmds[2].name, "roll")
	}

	// /roll posts to the channel; bad dice, or too many sides, don't.
	testing.expect(t, runtime_run_command(r.rt, r.a, "/roll 2d6", "general"))
	testing.expect(t, runtime_run_command(r.rt, r.a, "/roll nonsense", "general"))
	testing.expect(t, runtime_run_command(r.rt, r.a, "/roll 1d500", "general"))
	testing.expect(t, runtime_run_command(r.rt, r.a, "/hello Ann", "general"))
	runtime_step(r.rt, 20 * time.Millisecond)
	// Answers to commands are status text, not desktop notifications.
	testing.expect_value(t, v.notice.text, "Hello, Ann. (calm, a.example:7777)")
	testing.expect_value(t, len(notified(&r)), 0)
	texts := posted(r.a)
	testing.expect_value(t, len(texts), 1)
	if len(texts) == 1 {
		testing.expectf(t, strings.has_prefix(texts[0], "general: 2d6: ") && strings.contains(texts[0], " = "), "%q", texts[0])
	}
	delete(texts)
	// The largest die is a setting.
	testing.expect_value(t, runtime_set_value(r.rt, "showcase.lua", "dice", i64(4)), "")
	testing.expect(t, runtime_run_command(r.rt, r.a, "/roll 1d6", "general"))
	runtime_step(r.rt, 20 * time.Millisecond)
	texts = posted(r.a)
	testing.expect_value(t, len(texts), 1) // still only the first
	delete(texts)

	// /remind keeps the reminder and sets a timer for it.
	testing.expect(t, runtime_run_command(r.rt, r.a, "/remind 5 tea", "general"))
	runtime_step(r.rt, 20 * time.Millisecond)
	s := r.rt.entries[0].script
	testing.expect_value(t, s.store["reminder"].(string), "tea")
	testing.expect_value(t, len(s.timers), 1)

	// What others send.
	r.a.auth.me = 1
	shown, hidden := incoming(r.a, "well, darn it")
	testing.expect_value(t, shown, "well, **** it")
	testing.expect(t, !hidden)
	shown, hidden = incoming(r.a, "Darn!")
	testing.expect_value(t, shown, "****!")
	_, hidden = incoming(r.a, "buy now !spam")
	testing.expect(t, hidden)
	shown, hidden = incoming(r.a, "hello")
	testing.expect_value(t, shown, "hello")
	testing.expect(t, !hidden)
	testing.expect_value(t, runtime_set_value(r.rt, "showcase.lua", "censor", false), "")
	shown, _ = incoming(r.a, "darn")
	testing.expect_value(t, shown, "darn") // switched off

	// And what is sent.
	text, cancel, _ := runtime_filter_send(r.rt, r.a, "general", "!shout hello there")
	testing.expect_value(t, text, "HELLO THERE")
	testing.expect(t, !cancel)
	by: string
	_, cancel, by = runtime_filter_send(r.rt, r.a, "general", "my secret plan")
	testing.expect(t, cancel)
	testing.expect_value(t, by, "showcase.lua")
	text, cancel, _ = runtime_filter_send(r.rt, r.a, "general", "just a message")
	testing.expect_value(t, text, "just a message")
	testing.expect(t, !cancel)

	// A mention is a desktop notification.
	emit(r.a, message("hey @you", true))
	runtime_step(r.rt, 20 * time.Millisecond)
	got := notified(&r)
	testing.expect_value(t, len(got), 1)
	if len(got) == 1 {
		testing.expect_value(t, got[0].title, "Mentioned by Ann in general")
		testing.expect_value(t, got[0].text, "hey @you")
	}
}

@(test)
test_a_script_can_run_for_no_server :: proc(t: ^testing.T) {
	f := folder_make(File{"echo.lua", `function on_message(ev) yap.send("c", "got it") end`})
	defer folder_destroy(&f)
	{
		r := rig_new(f.dir)
		runtime_load(r.rt)
		runtime_set_scope(r.rt, "echo.lua", false, nil) // "all servers" unticked, none picked
		v, _ := view_of(r.rt, "echo.lua")
		testing.expect(t, !v.all_servers)
		testing.expect_value(t, len(v.servers), 0)
		testing.expect_value(t, runtime_set_enabled(r.rt, "echo.lua", true, {.Send}), "")
		emit(r.a, message("x"))
		runtime_step(r.rt, 10 * time.Millisecond)
		texts := posted(r.a)
		testing.expect_value(t, len(texts), 0) // it runs for nothing
		delete(texts)
		// Ticking one server makes it run for that one.
		runtime_set_scope(r.rt, "echo.lua", false, {"a.example:7777"})
		emit(r.a, message("x"))
		runtime_step(r.rt, 10 * time.Millisecond)
		texts = posted(r.a)
		testing.expect_value(t, len(texts), 1)
		delete(texts)
		runtime_set_scope(r.rt, "echo.lua", false, nil)
		rig_destroy(&r)
	}
	// It stays so after a restart; it is not "all" again.
	r := rig_new(f.dir)
	defer rig_destroy(&r)
	runtime_load(r.rt)
	v, _ := view_of(r.rt, "echo.lua")
	testing.expect(t, !v.all_servers)
	testing.expect_value(t, len(v.servers), 0)
	runtime_set_scope(r.rt, "echo.lua", true, nil)
	v, _ = view_of(r.rt, "echo.lua")
	testing.expect(t, v.all_servers)
}

// A View on a connection, to read the notices a script shows.
@(private = "file")
notices_on :: proc(c: ^conn.Server_Conn) -> ^conn.View {
	v := new(conn.View)
	conn.view_init(v)
	c.view = v
	return v
}

@(private = "file")
notices_off :: proc(c: ^conn.Server_Conn, v: ^conn.View) {
	c.view = nil
	conn.view_destroy(v)
	free(v)
}

@(private = "file")
dm_message :: proc(text: string) -> conn.Event {
	e := message(text).(conn.Event_Message)
	e.kind = .DM
	return e
}

EXAMPLES :: "../../../docs/examples/scripts/"
KEYWORDS_EXAMPLE :: #load(EXAMPLES + "keywords.lua", string)
PRESENCE_EXAMPLE :: #load(EXAMPLES + "presence.lua", string)
WEBHOOK_EXAMPLE :: #load(EXAMPLES + "webhook.lua", string)
AWAY_EXAMPLE :: #load(EXAMPLES + "away.lua", string)

// Every example describes itself without trouble.
@(test)
test_the_examples_describe_themselves :: proc(t: ^testing.T) {
	Case :: struct {
		file, source: string,
		settings:     int,
		permissions:  Permissions,
	}
	for c in ([]Case{
			{"keywords.lua", KEYWORDS_EXAMPLE, 2, {.Notify}},
			{"presence.lua", PRESENCE_EXAMPLE, 2, {.Notify}},
			{"webhook.lua", WEBHOOK_EXAMPLE, 1, {.Net}},
			{"away.lua", AWAY_EXAMPLE, 3, {.Send}},
		}) {
		info, has, err := read_info(c.file, c.source)
		testing.expect(t, has, c.file)
		testing.expect_value(t, err, "")
		testing.expect_value(t, len(info.problems), 0)
		testing.expect_value(t, len(info.settings), c.settings)
		testing.expect_value(t, info.permissions, c.permissions)
		testing.expect(t, info.name != "" && info.description != "" && info.version != "", c.file)
		info_destroy(&info)
	}
}

// The notifications scripts have asked for since the last look.
@(private = "file")
notified :: proc(r: ^Rig) -> []Notification {
	return runtime_take_notifications(r.rt)
}

@(test)
test_the_keywords_example :: proc(t: ^testing.T) {
	f := folder_make()
	defer folder_destroy(&f)
	r := rig_new(f.dir)
	defer rig_destroy(&r)
	runtime_notifications_to_ui(r.rt)
	testing.expect(t, runtime_add(r.rt, "keywords.lua", KEYWORDS_EXAMPLE, Script_Config{permissions = {"notify"}}))

	say :: proc(r: ^Rig, e: conn.Event) -> []Notification {
		emit(r.a, e)
		runtime_step(r.rt, 10 * time.Millisecond)
		return runtime_take_notifications(r.rt)
	}
	got := say(&r, message("I love Lua"))
	testing.expect_value(t, len(got), 1)
	if len(got) == 1 {
		testing.expect_value(t, got[0].title, `Ann said "lua" in general`)
		testing.expect_value(t, got[0].text, "I love Lua")
		testing.expect_value(t, got[0].server, "a.example:7777")
		testing.expect_value(t, got[0].script, "keywords.lua")
	}
	testing.expect_value(t, len(say(&r, message("nothing of interest"))), 0)
	mine := message("yap yap").(conn.Event_Message)
	mine.mine = true
	testing.expect_value(t, len(say(&r, mine)), 0) // not our own

	// Different words, and only in direct messages.
	testing.expect_value(t, runtime_set_value(r.rt, "keywords.lua", "words", " Tea ,, coffee "), "")
	got = say(&r, message("lua and Coffee"))
	testing.expect_value(t, len(got), 1)
	if len(got) == 1 {
		testing.expect_value(t, got[0].title, `Ann said "coffee" in general`)
	}
	testing.expect_value(t, runtime_set_value(r.rt, "keywords.lua", "where", "direct messages only"), "")
	testing.expect_value(t, len(say(&r, message("tea time"))), 0) // a channel
	testing.expect_value(t, len(say(&r, dm_message("tea time"))), 1)
}

@(test)
test_the_presence_example :: proc(t: ^testing.T) {
	f := folder_make()
	defer folder_destroy(&f)
	r := rig_new(f.dir)
	defer rig_destroy(&r)
	runtime_notifications_to_ui(r.rt)
	testing.expect(t, runtime_add(r.rt, "presence.lua", PRESENCE_EXAMPLE, Script_Config{permissions = {"notify"}}))
	change :: proc(r: ^Rig, username: string, was, now: proto.Activity) -> []Notification {
		emit(r.a, conn.Event_Presence{account = 4, name = strings.clone("Bob"), username = strings.clone(username), activity = now, was = was})
		runtime_step(r.rt, 10 * time.Millisecond)
		return runtime_take_notifications(r.rt)
	}
	got := change(&r, "bob", .Offline, .Online)
	testing.expect_value(t, len(got), 1)
	if len(got) == 1 {
		testing.expect_value(t, got[0].title, "Bob is online")
		testing.expect_value(t, got[0].text, "on a.example:7777")
	}
	testing.expect_value(t, len(change(&r, "bob", .Away, .Online)), 0) // back from away: not news
	testing.expect_value(t, len(change(&r, "bob", .Online, .Offline)), 0) // and going isn't wanted

	testing.expect_value(t, runtime_set_value(r.rt, "presence.lua", "people", "Alice, carol"), "")
	testing.expect_value(t, len(change(&r, "bob", .Offline, .Online)), 0) // not on the list
	testing.expect_value(t, len(change(&r, "CAROL", .Offline, .Online)), 1)
	testing.expect_value(t, runtime_set_value(r.rt, "presence.lua", "goes", true), "")
	got = change(&r, "alice", .Online, .Offline)
	testing.expect_value(t, len(got), 1)
	if len(got) == 1 {
		testing.expect_value(t, got[0].title, "Bob went offline")
	}
}

@(test)
test_notifications_and_status_text :: proc(t: ^testing.T) {
	f := folder_make()
	defer folder_destroy(&f)
	r := rig_new(f.dir)
	defer rig_destroy(&r)
	v := notices_on(r.a)
	defer notices_off(r.a, v)
	runtime_notifications_to_ui(r.rt)
	testing.expect(
		t,
		runtime_add(
			r.rt,
			"both.lua",
			`
			function on_message(ev)
				yap.notify("Title", "text of it")
				yap.notify("Only a title")
				yap.status("Status text")
			end`,
			Script_Config{permissions = {"notify"}},
		),
	)
	emit(r.a, message("x"))
	runtime_step(r.rt, 10 * time.Millisecond)
	// A notification is queued for the UI, with the server it was for...
	got := notified(&r)
	testing.expect_value(t, len(got), 2)
	if len(got) == 2 {
		testing.expect_value(t, got[0].title, "Title")
		testing.expect_value(t, got[0].text, "text of it")
		testing.expect_value(t, got[0].server, "a.example:7777")
		testing.expect_value(t, got[1].title, "Only a title")
		testing.expect_value(t, got[1].text, "")
	}
	testing.expect_value(t, len(notified(&r)), 0) // taken once
	// ... and status text is the client's status line, not a notification.
	testing.expect_value(t, v.notice.text, "Status text")
}

@(test)
test_notifications_without_a_ui_go_to_the_log :: proc(t: ^testing.T) {
	f := folder_make()
	defer folder_destroy(&f)
	r := rig_new(f.dir)
	defer rig_destroy(&r)
	// No runtime_notifications_to_ui: as in the headless client.
	testing.expect(t, runtime_add(r.rt, "n.lua", `function on_message(ev) yap.notify("Title", "text") end`, Script_Config{permissions = {"notify"}}))
	emit(r.a, message("x"))
	runtime_step(r.rt, 10 * time.Millisecond)
	testing.expect_value(t, len(notified(&r)), 0)
}

@(test)
test_the_away_example :: proc(t: ^testing.T) {
	f := folder_make()
	defer folder_destroy(&f)
	r := rig_new(f.dir)
	defer rig_destroy(&r)
	testing.expect(t, runtime_add(r.rt, "away.lua", AWAY_EXAMPLE, Script_Config{permissions = {"send"}}))
	mention :: proc(r: ^Rig, author: proto.Account_Id, mine := false) {
		e := message("hey @me", true).(conn.Event_Message)
		delete(e.username)
		e.author, e.username, e.mine = author, strings.clone(fmt.tprintf("user%d", author)), mine
		emit(r.a, e)
		runtime_step(r.rt, 10 * time.Millisecond)
	}
	sent :: proc(r: ^Rig) -> int {
		texts := posted(r.a)
		defer delete(texts)
		return len(texts)
	}
	mention(&r, 9)
	testing.expect_value(t, sent(&r), 0) // not away
	testing.expect_value(t, runtime_set_value(r.rt, "away.lua", "away", true), "")
	mention(&r, 9)
	texts := posted(r.a)
	testing.expect_value(t, len(texts), 1)
	if len(texts) == 1 {
		testing.expect_value(t, texts[0], "general: @user9 I am away right now and will answer later.")
	}
	delete(texts)
	mention(&r, 9) // the same person, soon again
	testing.expect_value(t, sent(&r), 1)
	mention(&r, 10) // somebody else
	testing.expect_value(t, sent(&r), 2)
	mention(&r, 11, mine = true)
	testing.expect_value(t, sent(&r), 2)
	// It remembers who it answered.
	testing.expect(t, r.rt.entries[0].script.store_size > 0)
}

SCRIPTING_DOC :: #load("../../../docs/Scripting.md", string)

// The Lua in docs/Scripting.md is a script, or part of one: every block has to
// load, and the one in the quick start has to do what the text says.
@(test)
test_the_documentation_code_works :: proc(t: ^testing.T) {
	blocks := make([dynamic]string, context.temp_allocator)
	in_block := false
	current := strings.builder_make(context.temp_allocator)
	doc := SCRIPTING_DOC
	for line in strings.split_lines_iterator(&doc) {
		trimmed := strings.trim_space(line)
		switch {
		case !in_block && trimmed == "```lua":
			in_block = true
			strings.builder_reset(&current)
		case in_block && trimmed == "```":
			in_block = false
			append(&blocks, strings.clone(strings.to_string(current), context.temp_allocator))
		case in_block:
			// The lines of a block are indented with the list or text around them.
			strings.write_string(&current, strings.trim_left(line, " "))
			strings.write_byte(&current, '\n')
		}
	}
	testing.expectf(t, len(blocks) >= 6, "only %d Lua blocks were found", len(blocks))
	for block, i in blocks {
		info, _, err := read_info(fmt.tprintf("doc%d.lua", i), block)
		testing.expectf(t, err == "", "block %d does not load: %s\n%s", i, err, block)
		info_destroy(&info)
	}

	// The quick start: the first block.
	f := folder_make()
	defer folder_destroy(&f)
	r := rig_new(f.dir)
	defer rig_destroy(&r)
	if len(blocks) == 0 {
		return
	}
	testing.expect(t, runtime_add(r.rt, "hello.lua", blocks[0], Script_Config{permissions = {"send"}}))
	view, found := view_of(r.rt, "hello.lua")
	testing.expect(t, found)
	testing.expect_value(t, view.name, "Hello")
	emit(r.a, message("!ping"))
	mine := message("!ping").(conn.Event_Message)
	mine.mine = true
	emit(r.a, mine)
	emit(r.a, message("something else"))
	runtime_step(r.rt, 10 * time.Millisecond)
	texts := posted(r.a)
	defer delete(texts)
	testing.expect_value(t, len(texts), 1)
	if len(texts) == 1 {
		testing.expect_value(t, texts[0], "general: pong")
	}
}

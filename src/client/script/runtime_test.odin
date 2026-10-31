#+build !wasi
package script

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "client:conn"
import "common:proto"

@(private = "file")
Rig :: struct {
	rt: ^Runtime,
	a:  ^conn.Server_Conn,
	b:  ^conn.Server_Conn,
}

@(private = "file")
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

@(private = "file")
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
@(private = "file")
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

@(private = "file")
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

@(private = "file")
emit :: proc(c: ^conn.Server_Conn, e: conn.Event) {
	sync_append(c, e)
}

@(private = "file")
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
	began := time.tick_now()
	for _ in 0 ..< 400 {
		runtime_step(r.rt, 2 * time.Millisecond)
		time.sleep(time.Millisecond)
	}
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

#+build !wasi
package headless

import "core:log"
import "core:testing"
import "core:time"

import "client:conn"
import "common:proto"

// Tests of reading the commands typed in headless mode (commands.odin): which
// command each line is queued as, how its arguments are read, and lines that
// are not queued at all because they can't be read.

@(private = "file")
Typing :: struct {
	c:        conn.Server_Conn,
	reader:   Reader,
	attached: [dynamic]string,
	taken:    [dynamic]conn.Command,
}

@(private = "file")
typing_destroy :: proc(ty: ^Typing) {
	for cmd in ty.taken {
		conn.command_destroy(cmd)
	}
	delete(ty.taken)
	for path in ty.attached {
		delete(path)
	}
	delete(ty.attached)
	conn.commands_destroy(&ty.c.commands)
}

// type_line hands `line` to the reader and returns what it queued.
@(private = "file")
type_line :: proc(ty: ^Typing, line: string) -> []conn.Command {
	ty.reader.c = &ty.c
	handle_line(&ty.reader, line, &ty.attached)
	q := &ty.c.commands
	got := q.commands[:]
	start := len(ty.taken)
	append(&ty.taken, ..got)
	clear(&q.commands)
	return ty.taken[start:]
}

// one returns the command a line was queued as, which must be of type T.
@(private = "file")
one :: proc(t: ^testing.T, ty: ^Typing, line: string, $T: typeid, loc := #caller_location) -> (cmd: T, ok: bool) {
	got := type_line(ty, line)
	if len(got) != 1 {
		testing.expectf(t, false, "%q: expected one command, got %d", line, len(got), loc = loc)
		return
	}
	cmd, ok = got[0].(T)
	testing.expectf(t, ok, "%q: expected a %v, got %v", line, typeid_of(T), got[0], loc = loc)
	return
}

// none checks that a line queued nothing.
@(private = "file")
none :: proc(t: ^testing.T, ty: ^Typing, line: string, loc := #caller_location) {
	got := type_line(ty, line)
	testing.expectf(t, len(got) == 0, "%q: expected nothing, got %v", line, got, loc = loc)
}

@(private = "file")
now_ms :: proc() -> proto.Unix_Ms {
	return proto.Unix_Ms(time.time_to_unix_nano(time.now()) / 1e6)
}

@(test)
test_invite_codes_and_members :: proc(t: ^testing.T) {
	ty: Typing
	defer typing_destroy(&ty)

	code, ok := one(t, &ty, "/invite", conn.Invite_Create_Command)
	testing.expect(t, ok && code.max_uses == 1 && code.expires == 0)
	code, ok = one(t, &ty, "/invite 0 7", conn.Invite_Create_Command)
	if ok {
		testing.expect_value(t, code.max_uses, 0)
		week := proto.Unix_Ms(7 * 24 * 60 * 60 * 1000)
		testing.expect(t, abs(code.expires - (now_ms() + week)) < 60_000)
	}
	code, ok = one(t, &ty, "/invite 99999", conn.Invite_Create_Command)
	testing.expect(t, ok && code.max_uses == proto.MAX_INVITE_USES)

	// With a name it adds someone to the channel instead of making a code.
	member: conn.Conv_Member_Command
	member, ok = one(t, &ty, "/invite alice", conn.Conv_Member_Command)
	testing.expect(t, ok && member.name == "alice" && member.on)
	member, ok = one(t, &ty, "/kick  alice ", conn.Conv_Member_Command)
	testing.expect(t, ok && member.name == "alice" && !member.on)
}

@(test)
test_register :: proc(t: ^testing.T) {
	ty: Typing
	defer typing_destroy(&ty)
	context.logger = log.nil_logger()

	r, ok := one(t, &ty, "/register bob secret", conn.Register_Command)
	if ok {
		testing.expect_value(t, r.username, "bob")
		testing.expect_value(t, r.password, "secret")
		testing.expect_value(t, r.email, "")
		testing.expect_value(t, r.invite, "")
		testing.expect(t, r.device != "")
	}
	// The email is told from the invite code by its @, in either order.
	r, ok = one(t, &ty, "/register bob secret CODE42 bob@example.com", conn.Register_Command)
	if ok {
		testing.expect_value(t, r.email, "bob@example.com")
		testing.expect_value(t, r.invite, "CODE42")
	}
	none(t, &ty, "/register bob")

	l: conn.Login_Command
	l, ok = one(t, &ty, "/login bob two words", conn.Login_Command)
	testing.expect(t, ok && l.username == "bob" && l.password == "two words")
}

@(test)
test_roles_and_perms :: proc(t: ^testing.T) {
	ty: Typing
	defer typing_destroy(&ty)
	context.logger = log.nil_logger() // unknown permissions are warned about

	testing.expect_value(t, parse_perms(""), proto.Permissions{})
	testing.expect_value(t, parse_perms(" , ,"), proto.Permissions{})
	testing.expect_value(t, parse_perms("invite, PIN_MESSAGES"), proto.Permissions{.Invite, .Pin_Messages})
	// An unknown one is left out; the rest still count.
	testing.expect_value(t, parse_perms("Invite,fly"), proto.Permissions{.Invite})

	r, ok := one(t, &ty, "/mkrole Helpers Invite,Pin_Messages", conn.Role_Set_Command)
	if ok {
		testing.expect_value(t, r.name, "Helpers")
		testing.expect_value(t, r.perms, proto.Permissions{.Invite, .Pin_Messages})
		testing.expect(t, !r.by_name)
	}
	r, ok = one(t, &ty, "/setrole Helpers", conn.Role_Set_Command)
	testing.expect(t, ok && r.by_name && r.perms == {})

	a: conn.Account_Roles_Command
	a, ok = one(t, &ty, "/assign alice mods, helpers", conn.Account_Roles_Command)
	testing.expect(t, ok && a.name == "alice" && a.role_names == "mods, helpers")
}

@(test)
test_say_and_attach :: proc(t: ^testing.T) {
	ty: Typing
	defer typing_destroy(&ty)
	context.logger = log.nil_logger()

	// \n typed in a message is a new line, and blanks are kept.
	say, ok := one(t, &ty, `/say  two\nlines`, conn.Chat_Command)
	if ok {
		testing.expect_value(t, say.text, " two\nlines")
		testing.expect(t, say.typed)
	}
	reply: conn.Chat_Command
	reply, ok = one(t, &ty, `/reply 12 yes\nno`, conn.Chat_Command)
	testing.expect(t, ok && reply.thread.root == 12 && reply.text == "yes\nno")
	none(t, &ty, "/reply twelve yes")

	// Attached files go with the next /say, and only with it.
	none(t, &ty, "/attach a.txt")
	none(t, &ty, "/attach  b.png ")
	send: conn.Attach_Send_Command
	send, ok = one(t, &ty, "/say here", conn.Attach_Send_Command)
	if ok && testing.expect_value(t, len(send.files), 2) {
		testing.expect_value(t, send.files[0].path, "a.txt")
		testing.expect_value(t, send.files[1].path, "b.png")
		testing.expect_value(t, send.text, "here")
	}
	_, ok = one(t, &ty, "/say plain", conn.Chat_Command)
	testing.expect(t, ok)

	// At most MAX_ATTACHMENTS, and /unattach takes them back.
	for _ in 0 ..< proto.MAX_ATTACHMENTS + 2 {
		none(t, &ty, "/attach x")
	}
	testing.expect_value(t, len(ty.attached), proto.MAX_ATTACHMENTS)
	none(t, &ty, "/unattach")
	testing.expect_value(t, len(ty.attached), 0)
	_, ok = one(t, &ty, "/say again", conn.Chat_Command)
	testing.expect(t, ok)

	_, ok = one(t, &ty, `/dm alice hi\nthere`, conn.DM_Command)
	testing.expect(t, ok)
}

@(test)
test_message_ids :: proc(t: ^testing.T) {
	ty: Typing
	defer typing_destroy(&ty)

	edit, ok := one(t, &ty, "/edit 7 fixed", conn.Edit_Command)
	testing.expect(t, ok && edit.id == 7 && edit.text == "fixed")
	none(t, &ty, "/edit seven fixed")
	react: conn.React_Command
	react, ok = one(t, &ty, "/react 7  :tada: ", conn.React_Command)
	testing.expect(t, ok && react.id == 7 && react.emoji == ":tada:" && react.on)
	react, ok = one(t, &ty, "/unreact 7 :tada:", conn.React_Command)
	testing.expect(t, ok && !react.on)
	pin: conn.Pin_Command
	pin, ok = one(t, &ty, "/unpin 9", conn.Pin_Command)
	testing.expect(t, ok && pin.id == 9 && !pin.on)

	// Files are counted from 1.
	save: conn.Attach_Save_Command
	save, ok = one(t, &ty, "/save 12 2", conn.Attach_Save_Command)
	testing.expect(t, ok && save.msg == 12 && save.index == 1)
	none(t, &ty, "/save 12 0")
	none(t, &ty, "/save 12")

	forward: conn.Forward_Command
	forward, ok = one(t, &ty, "/forward 5 off topic", conn.Forward_Command)
	testing.expect(t, ok && forward.msg == 5 && forward.name == "off topic")
	context.logger = log.nil_logger()
	none(t, &ty, "/forward 5")
	none(t, &ty, "/forward x lobby")
}

@(test)
test_moderation_lines :: proc(t: ^testing.T) {
	ty: Typing
	defer typing_destroy(&ty)
	context.logger = log.nil_logger()

	ban, ok := one(t, &ty, "/ban alice too  loud ", conn.Ban_Command)
	testing.expect(t, ok && ban.name == "alice" && ban.on && ban.reason == "too  loud")
	ban, ok = one(t, &ty, "/banpurge alice day spam here", conn.Ban_Command)
	if ok {
		testing.expect_value(t, ban.name, "alice")
		testing.expect_value(t, ban.purge, proto.Ban_Purge.Day)
		testing.expect_value(t, ban.reason, "spam here")
	}
	none(t, &ty, "/banpurge alice")
	none(t, &ty, "/banpurge alice fortnight")
	ban, ok = one(t, &ty, "/unban alice", conn.Ban_Command)
	testing.expect(t, ok && !ban.on)

	purge: conn.Purge_Command
	purge, ok = one(t, &ty, "/purge here 2 files", conn.Purge_Command)
	if ok {
		testing.expect(t, purge.here && !purge.all)
		testing.expect_value(t, purge.what, proto.Purge_What.Files)
		two_days := proto.Unix_Ms(2 * 24 * 60 * 60 * 1000)
		testing.expect(t, abs(purge.before - (now_ms() - two_days)) < 60_000)
	}
	purge, ok = one(t, &ty, "/purge all 0.5", conn.Purge_Command)
	testing.expect(t, ok && purge.all && purge.what == .Messages)
	none(t, &ty, "/purge everywhere 2")
	none(t, &ty, "/purge here -1")
	none(t, &ty, "/purge here")

	purge, ok = one(t, &ty, "/purgeuser alice", conn.Purge_Command)
	testing.expect(t, ok && purge.name == "alice" && purge.since == 0)
	purge, ok = one(t, &ty, "/purgeuser alice 3", conn.Purge_Command)
	testing.expect(t, ok && purge.since > 0)
	none(t, &ty, "/purgeuser alice soon")

	tokens: conn.Devices_Command
	tokens, ok = one(t, &ty, "/tokens 5", conn.Devices_Command)
	testing.expect(t, ok && tokens.account == 5)
	none(t, &ty, "/bottoken 0")
	none(t, &ty, "/bottoken 99999999999")
	none(t, &ty, "/revoke not-a-key")

	move: conn.Voice_Move_Command
	move, ok = one(t, &ty, "/voicemove alice  Gaming room", conn.Voice_Move_Command)
	testing.expect(t, ok && move.name == "alice" && move.channel == "Gaming room")
	move, ok = one(t, &ty, "/voicekick alice", conn.Voice_Move_Command)
	testing.expect(t, ok && move.channel == "")
}

@(test)
test_settings_lines :: proc(t: ^testing.T) {
	ty: Typing
	defer typing_destroy(&ty)
	context.logger = log.nil_logger()

	notify, ok := one(t, &ty, "/notify lobby mentions", conn.Notify_Command)
	testing.expect(t, ok && notify.name == "lobby" && notify.notify == .Mentions)
	none(t, &ty, "/notify lobby loudly")

	setting: conn.Setting_Command
	setting, ok = one(t, &ty, "/digest none", conn.Setting_Command)
	testing.expect(t, ok && setting.key == proto.SETTING_EMAIL_DIGEST && setting.value == "")
	setting, ok = one(t, &ty, "/digest missed", conn.Setting_Command)
	testing.expect(t, ok && setting.value == "missed")
	none(t, &ty, "/digest weekly")

	flag: conn.Conv_Flag_Command
	flag, ok = one(t, &ty, "/textonly on", conn.Conv_Flag_Command)
	testing.expect(t, ok && flag.flag == .Text_Only && flag.on)
	flag, ok = one(t, &ty, "/default off", conn.Conv_Flag_Command)
	testing.expect(t, ok && flag.flag == .Default && !flag.on)
	none(t, &ty, "/default maybe")

	status: conn.Status_Command
	status, ok = one(t, &ty, "/status 30 at lunch", conn.Status_Command)
	if ok {
		testing.expect_value(t, status.text, "at lunch")
		testing.expect(t, abs(status.until - (now_ms() + 30 * 60_000)) < 60_000)
	}
	status, ok = one(t, &ty, "/status out of office", conn.Status_Command)
	testing.expect(t, ok && status.text == "out of office" && status.until == 0)
	status, ok = one(t, &ty, "/status", conn.Status_Command)
	testing.expect(t, ok && status.text == "" && status.until == 0)

	activity: conn.Activity_Command
	activity, ok = one(t, &ty, "/activity away", conn.Activity_Command)
	testing.expect(t, ok && activity.activity == .Away)
	none(t, &ty, "/activity sleeping")

	search: conn.Search_Command
	search, ok = one(t, &ty, "/search all  big news", conn.Search_Command)
	testing.expect(t, ok && search.all && search.query == "big news")
	search, ok = one(t, &ty, "/search more", conn.Search_Command)
	testing.expect(t, ok && search.more)
}

// A line that is no command of ours may be one of a bot's. Without scripts
// running it is sent to the bots, and the help is logged too, in case none
// of them has it.
@(test)
test_unknown_lines :: proc(t: ^testing.T) {
	ty: Typing
	defer typing_destroy(&ty)
	context.logger = log.nil_logger()

	run, ok := one(t, &ty, "/weather Berlin", conn.Bot_Run_Command)
	testing.expect(t, ok && run.line == "/weather Berlin" && run.silent)
	none(t, &ty, "")
	none(t, &ty, "/")
	none(t, &ty, "hello")
}

@(test)
test_typed_lines :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, typed, want: string, loc := #caller_location) {
		got := typed_lines(typed)
		defer delete(got)
		testing.expect_value(t, got, want, loc = loc)
	}
	check(t, "plain", "plain")
	check(t, `a\nb\n`, "a\nb\n")
	check(t, `back\\slash`, `back\\slash`)
	check(t, "", "")
}

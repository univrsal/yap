package main

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "client:conn"
import "common:proto"
import "tui"

// A screen of a given size with a View and a command queue behind it.
@(private = "file")
Fixture :: struct {
	v:   conn.View,
	c:   ^conn.Server_Conn,
	app: App,
	buf: tui.Buffer,
}

@(private = "file")
fixture :: proc(f: ^Fixture, w := 80, h := 20) {
	f.v = test_view()
	f.v.my_name = strings.clone("me")
	add_account(&f.v, 1, "me")
	add_account(&f.v, 2, "anna")
	add_channel(&f.v, 1, "general")
	add_channel(&f.v, 2, "dev", unread = 3)
	add_channel(&f.v, 3, "ops", unread = 1, mentions = 1)
	f.v.channels[0].topic = strings.clone("Welcome to yap")
	f.v.channels[0].rights = proto.CONV_RIGHTS_ALL
	f.v.viewing = 1
	f.c = new(conn.Server_Conn)
	app_init(&f.app, &f.v, f.c)
	f.buf = tui.buffer_make(w, h)
}

@(private = "file")
fixture_destroy :: proc(f: ^Fixture) {
	tui.buffer_destroy(&f.buf)
	app_destroy(&f.app)
	conn.commands_destroy(&f.c.commands)
	free(f.c)
	conn.view_destroy(&f.v)
}

@(private = "file")
frame :: proc(f: ^Fixture) {
	app_frame(&f.app, &f.buf)
}

@(private = "file")
screen :: proc(f: ^Fixture) -> []string {
	out := make([]string, f.buf.h, context.temp_allocator)
	for y in 0 ..< f.buf.h {
		out[y] = tui.buffer_row_text(&f.buf, y)
	}
	return out
}

@(private = "file")
screen_has :: proc(f: ^Fixture, text: string) -> bool {
	for row in screen(f) {
		if strings.contains(row, text) {
			return true
		}
	}
	return false
}

// take gives the commands queued so far and empties the queue.
@(private = "file")
take :: proc(f: ^Fixture) -> [dynamic]conn.Command {
	out := make([dynamic]conn.Command, context.temp_allocator)
	append(&out, ..f.c.commands.commands[:])
	clear(&f.c.commands.commands)
	return out
}

@(private = "file")
discard :: proc(f: ^Fixture) {
	for c in take(f) {
		conn.command_destroy(c)
	}
}

// find_chat is the Chat_Command among commands, if one.
@(private = "file")
find_cmd :: proc($T: typeid, cmds: [dynamic]conn.Command) -> (found: T, ok: bool) {
	for c in cmds {
		if v, is := c.(T); is {
			return v, true
		}
	}
	return
}

@(private = "file")
type_text :: proc(f: ^Fixture, s: string) {
	for r in s {
		app_event(&f.app, tui.Key_Event{key = .Rune, rune = r})
	}
}

@(private = "file")
press :: proc(f: ^Fixture, k: tui.Key, mods := tui.Mods{}) {
	app_event(&f.app, tui.Key_Event{key = k, mods = mods})
}

@(private = "file")
click :: proc(f: ^Fixture, x, y: int, button := tui.Mouse_Button.Left) {
	app_event(&f.app, tui.Mouse_Event{kind = .Press, button = button, x = x, y = y})
	app_event(&f.app, tui.Mouse_Event{kind = .Release, button = button, x = x, y = y})
}

// some_chat fills the conversation with a few messages.
@(private = "file")
some_chat :: proc(f: ^Fixture) {
	add_message(&f.v, 1, 10, 2, T0, "hello there")
	add_message(&f.v, 1, 11, 1, T0 + 2 * MINUTE, "hi anna")
	add_message(&f.v, 1, 12, 2, T0 + 4 * MINUTE, "how are you")
}

// row_of is the screen row that contains the text, or -1.
@(private = "file")
row_of :: proc(f: ^Fixture, text: string) -> int {
	for row, y in screen(f) {
		if strings.contains(row, text) {
			return y
		}
	}
	return -1
}

@(test)
test_screen_shows_channels_title_and_status :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	frame(&f)
	rows := screen(&f)
	testing.expect(t, strings.contains(rows[0], "example.org:7777"), rows[0])
	testing.expect(t, strings.contains(rows[0], "# general"), rows[0])
	testing.expect(t, strings.contains(rows[0], "Welcome to yap"), rows[0])
	testing.expect(t, strings.contains(rows[2], "# general"), rows[2])
	testing.expect(t, strings.contains(rows[3], "# dev") && strings.contains(rows[3], "3"), rows[3])
	testing.expect(t, strings.contains(rows[4], "# ops") && strings.contains(rows[4], "@1"), rows[4])
	testing.expect(t, strings.contains(rows[len(rows) - 1], "me"), rows[len(rows) - 1])
	testing.expect(t, strings.contains(rows[len(rows) - 1], "4 unread (1 @)"), rows[len(rows) - 1])
	// The conversation being viewed is picked out.
	testing.expect(t, tui.cell_at(&f.buf, 5, 2).style == theme.selected)
	// And the cursor is in the message box.
	testing.expect(t, f.app.cursor_shown)
	testing.expect_value(t, f.app.cursor.y, 18)
}

@(test)
test_messages_sit_at_the_bottom :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	some_chat(&f)
	frame(&f)
	rows := screen(&f)
	// The newest message is right above the info line and the message box.
	y := row_of(&f, "how are you")
	testing.expect_value(t, y, 16)
	testing.expect(t, strings.contains(rows[y], "22:17 anna"), rows[y])
	testing.expect(t, strings.contains(rows[y - 1], "hi anna"), rows[y - 1])
	testing.expect(t, strings.contains(rows[y - 2], "hello there"), rows[y - 2])
}

@(test)
test_a_narrow_terminal_hides_the_channel_list :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f, 50, 12)
	defer fixture_destroy(&f)
	some_chat(&f)
	frame(&f)
	testing.expect(t, !screen_has(&f, "# dev"))
	testing.expect(t, screen_has(&f, "hello there"))
}

@(test)
test_clicking_a_channel_switches_to_it :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	frame(&f)
	click(&f, 6, 3) // "# dev"
	cmds := take(&f)
	vc, ok := find_cmd(conn.View_Command, cmds)
	testing.expect(t, ok)
	testing.expect_value(t, vc.conv, 2)
	// Clicking the message area does nothing like that.
	click(&f, 40, 5)
	testing.expect_value(t, len(take(&f)), 0)
}

@(test)
test_sending_a_message :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	frame(&f)
	discard(&f)
	type_text(&f, "hello @anna")
	frame(&f)
	testing.expect(t, screen_has(&f, "> hello @anna"))
	press(&f, .Enter)
	cmds := take(&f)
	chat, ok := find_cmd(conn.Chat_Command, cmds)
	testing.expect(t, ok)
	testing.expect_value(t, chat.text, "hello @anna")
	testing.expect(t, chat.typed)
	testing.expect_value(t, chat.thread, conn.Timeline_Key{})
	for c in cmds {
		conn.command_destroy(c)
	}
	testing.expect_value(t, tui.editor_text(&f.app.editor), "")
	// An empty box sends nothing.
	press(&f, .Enter)
	testing.expect_value(t, len(take(&f)), 0)
}

@(test)
test_typing_tells_the_others :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	frame(&f)
	discard(&f)
	type_text(&f, "h")
	cmds := take(&f)
	_, ok := find_cmd(conn.Typing_Command, cmds)
	testing.expect(t, ok)
	// Not for commands.
	clear(&f.app.editor.text)
	f.app.editor.cursor = 0
	type_text(&f, "/")
	testing.expect_value(t, len(take(&f)), 0)
}

@(test)
test_multiple_lines_and_paste :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	frame(&f)
	discard(&f)
	type_text(&f, "one")
	press(&f, .Enter, {.Alt})
	type_text(&f, "two")
	frame(&f)
	// The box grew by a line.
	testing.expect(t, screen_has(&f, "> one"))
	testing.expect(t, strings.contains(screen(&f)[len(screen(&f)) - 2], "two"))
	app_event(&f.app, tui.Paste_Event{"\r\nthree\r\nfour\x07\tx"})
	testing.expect_value(t, tui.editor_text(&f.app.editor), "one\ntwo\nthree\nfour    x")
}

@(test)
test_slash_commands :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	frame(&f)
	discard(&f)
	type_text(&f, "/join #dev")
	press(&f, .Enter)
	cmds := take(&f)
	vc, ok := find_cmd(conn.View_Command, cmds)
	testing.expect(t, ok)
	testing.expect_value(t, vc.name, "dev")
	conn.command_destroy(cmds[0])

	// What isn't ours is the headless client's: an unknown one is tried as a bot's
	// command and then answered with the list of commands.
	type_text(&f, "/nonsense")
	press(&f, .Enter)
	cmds = take(&f)
	bot, is_bot := find_cmd(conn.Bot_Run_Command, cmds)
	testing.expect(t, is_bot)
	testing.expect_value(t, bot.line, "/nonsense")
	for c in cmds {
		conn.command_destroy(c)
	}
	testing.expect_value(t, f.app.dialog.kind, Dialog_Kind.Output)
	frame(&f)
	testing.expect(t, screen_has(&f, "commands: /channels"))
	press(&f, .Escape)
	testing.expect_value(t, f.app.dialog.kind, Dialog_Kind.None)

	type_text(&f, "/help")
	press(&f, .Enter)
	frame(&f)
	testing.expect(t, screen_has(&f, "send the message"))
	press(&f, .Escape) // any key closes it
	testing.expect_value(t, f.app.dialog.kind, Dialog_Kind.None)

	type_text(&f, "/quit")
	testing.expect(t, !f.app.quit)
	press(&f, .Enter)
	testing.expect(t, f.app.quit)
}

@(test)
test_a_slash_can_be_written_with_two :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	frame(&f)
	discard(&f)
	type_text(&f, "//shrug")
	press(&f, .Enter)
	cmds := take(&f)
	chat, ok := find_cmd(conn.Chat_Command, cmds)
	testing.expect(t, ok)
	testing.expect_value(t, chat.text, "/shrug")
	conn.command_destroy(cmds[0])
}

@(test)
test_ctrl_c_quits :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	press(&f, .Rune, {.Ctrl})
	testing.expect(t, !f.app.quit)
	app_event(&f.app, tui.Key_Event{key = .Rune, rune = 'c', mods = {.Ctrl}})
	testing.expect(t, f.app.quit)
}

@(test)
test_clicking_a_message_opens_its_menu :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	some_chat(&f)
	frame(&f)
	click(&f, 40, row_of(&f, "hello there")) // anna's message
	frame(&f)
	testing.expect(t, f.app.menu.open)
	testing.expect(t, screen_has(&f, "Reply"))
	testing.expect(t, screen_has(&f, "Copy text"))
	// Not ours, so it can't be edited or (without permission) deleted.
	testing.expect(t, !screen_has(&f, "Edit"))
	testing.expect(t, !screen_has(&f, "Delete"))
	// Elsewhere closes it.
	click(&f, 40, 2)
	testing.expect(t, !f.app.menu.open)
}

@(test)
test_the_menu_of_our_message_has_edit_and_delete :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	some_chat(&f)
	frame(&f)
	click(&f, 40, row_of(&f, "hi anna"))
	frame(&f)
	testing.expect(t, screen_has(&f, "Edit"))
	testing.expect(t, screen_has(&f, "Delete"))
}

@(test)
test_replying :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	some_chat(&f)
	frame(&f)
	discard(&f)
	click(&f, 40, row_of(&f, "hello there"))
	frame(&f)
	click(&f, f.app.menu.at.x + 3, f.app.menu.at.y) // Reply is the first item
	testing.expect_value(t, f.app.reply_to, 10)
	frame(&f)
	testing.expect(t, screen_has(&f, "Replying to anna"))
	type_text(&f, "good")
	press(&f, .Enter)
	cmds := take(&f)
	chat, ok := find_cmd(conn.Chat_Command, cmds)
	testing.expect(t, ok)
	testing.expect_value(t, chat.text, "good")
	testing.expect_value(t, chat.thread, conn.Timeline_Key{1, 10})
	for c in cmds {
		conn.command_destroy(c)
	}
	testing.expect_value(t, f.app.reply_to, 0)
}

@(test)
test_replying_to_a_reply_goes_to_the_root :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	m := add_message(&f.v, 1, 20, 2, T0, "a reply")
	m.thread_root = 10
	frame(&f)
	click(&f, 40, row_of(&f, "a reply"))
	press(&f, .Enter) // Reply is the first item
	testing.expect_value(t, f.app.reply_to, 10)
}

@(test)
test_up_edits_the_last_message_of_ours :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	some_chat(&f)
	frame(&f)
	discard(&f)
	press(&f, .Up)
	testing.expect_value(t, f.app.editing, 11)
	testing.expect_value(t, tui.editor_text(&f.app.editor), "hi anna")
	frame(&f)
	testing.expect(t, screen_has(&f, "Editing your message"))
	type_text(&f, "!")
	press(&f, .Enter)
	cmds := take(&f)
	ed, ok := find_cmd(conn.Edit_Command, cmds)
	testing.expect(t, ok)
	testing.expect_value(t, ed.id, 11)
	testing.expect_value(t, ed.text, "hi anna!")
	conn.command_destroy(cmds[0])
	testing.expect_value(t, f.app.editing, 0)
	testing.expect_value(t, tui.editor_text(&f.app.editor), "")
}

@(test)
test_escape_cancels_an_edit :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	some_chat(&f)
	frame(&f)
	press(&f, .Up)
	testing.expect_value(t, f.app.editing, 11)
	press(&f, .Escape)
	testing.expect_value(t, f.app.editing, 0)
	testing.expect_value(t, tui.editor_text(&f.app.editor), "")
}

@(test)
test_up_does_nothing_without_a_message_of_ours :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	add_message(&f.v, 1, 10, 2, T0, "anna's")
	frame(&f)
	press(&f, .Up)
	testing.expect_value(t, f.app.editing, 0)
}

@(test)
test_editing_shows_mentions_as_typed :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	add_message(&f.v, 1, 10, 1, T0, "ask <@2> please")
	frame(&f)
	press(&f, .Up)
	testing.expect_value(t, tui.editor_text(&f.app.editor), "ask @anna please")
}

@(test)
test_deleting_asks_first :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	some_chat(&f)
	frame(&f)
	discard(&f)
	click(&f, 40, row_of(&f, "hi anna"))
	frame(&f)
	// Delete is the last item of the menu.
	last := len(f.app.menu.items) - 1
	testing.expect_value(t, f.app.menu.items[last].action, Menu_Action.Delete)
	click(&f, f.app.menu.at.x + 3, f.app.menu.at.y + last)
	testing.expect_value(t, f.app.dialog.kind, Dialog_Kind.Confirm_Delete)
	frame(&f)
	testing.expect(t, screen_has(&f, "Delete this message"))
	// No: nothing is sent.
	type_text(&f, "n")
	testing.expect_value(t, f.app.dialog.kind, Dialog_Kind.None)
	testing.expect_value(t, len(take(&f)), 0)
	// Yes.
	click(&f, 40, row_of(&f, "hi anna"))
	frame(&f)
	click(&f, f.app.menu.at.x + 3, f.app.menu.at.y + last)
	type_text(&f, "y")
	cmds := take(&f)
	del, ok := find_cmd(conn.Delete_Command, cmds)
	testing.expect(t, ok)
	testing.expect_value(t, del.id, 11)
}

@(test)
test_rights_decide_what_the_menu_offers :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	some_chat(&f)
	f.v.channels[0].rights = {.See, .Write}
	frame(&f)
	click(&f, 40, row_of(&f, "hi anna"))
	frame(&f)
	testing.expect(t, !screen_has(&f, "Edit"))
	testing.expect(t, !screen_has(&f, "Delete"))
	click(&f, 40, 2)
	// Moderators may delete what others wrote.
	f.v.permissions += {.Manage_Messages}
	f.v.channels[0].rights = proto.CONV_RIGHTS_ALL
	frame(&f)
	click(&f, 40, row_of(&f, "hello there"))
	frame(&f)
	testing.expect(t, screen_has(&f, "Delete"))
	testing.expect(t, !screen_has(&f, "Edit"))
	click(&f, 40, 2)
	// And with no right to write, there is no reply.
	f.v.channels[0].rights = {.See}
	frame(&f)
	click(&f, 40, row_of(&f, "hello there"))
	frame(&f)
	testing.expect(t, !screen_has(&f, "Reply"))
}

@(test)
test_picking_messages_with_the_keys :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	some_chat(&f)
	frame(&f)
	discard(&f)
	press(&f, .Tab)
	testing.expect_value(t, f.app.focus, Focus.Timeline)
	testing.expect_value(t, f.app.cursor_msg, 12) // the newest
	press(&f, .Up)
	testing.expect_value(t, f.app.cursor_msg, 11)
	press(&f, .Up)
	testing.expect_value(t, f.app.cursor_msg, 10)
	press(&f, .Up) // there is nothing before
	testing.expect_value(t, f.app.cursor_msg, 10)
	press(&f, .Down)
	testing.expect_value(t, f.app.cursor_msg, 11)
	frame(&f)
	testing.expect(t, tui.cell_at(&f.buf, 40, row_of(&f, "hi anna")).style.bg == theme.selected.bg)
	// r replies, and goes back to the message box.
	type_text(&f, "r")
	testing.expect_value(t, f.app.reply_to, 11)
	testing.expect_value(t, f.app.focus, Focus.Composer)
	// e on one that isn't ours does nothing.
	press(&f, .Escape)
	press(&f, .Tab)
	press(&f, .Up)
	press(&f, .Up)
	type_text(&f, "e")
	testing.expect_value(t, f.app.editing, 0)
	type_text(&f, "y")
	testing.expect_value(t, f.app.clipboard, "hello there")
	press(&f, .Escape)
	testing.expect_value(t, f.app.focus, Focus.Composer)
	testing.expect_value(t, f.app.cursor_msg, 0)
}

@(test)
test_enter_on_a_picked_message_opens_the_menu :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	some_chat(&f)
	frame(&f)
	press(&f, .Tab)
	press(&f, .Enter)
	testing.expect(t, f.app.menu.open)
	frame(&f)
	testing.expect(t, screen_has(&f, "Reply"))
	// Letters pick items.
	press(&f, .Rune)
	type_text(&f, "c")
	testing.expect(t, !f.app.menu.open)
	testing.expect_value(t, f.app.clipboard, "how are you")
}

@(test)
test_scrolling_and_reading :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f, 80, 12)
	defer fixture_destroy(&f)
	for i in 0 ..< 30 {
		add_message(&f.v, 1, proto.Msg_Id(10 + i), 2, T0 + proto.Unix_Ms(i) * MINUTE, "line of chat")
	}
	frame(&f)
	cmds := take(&f)
	rd, ok := find_cmd(conn.Reading_Command, cmds)
	testing.expect(t, ok) // the conversation is being read
	testing.expect_value(t, rd.conv, 1)
	testing.expect_value(t, f.app.scroll, 0)

	press(&f, .Page_Up)
	frame(&f)
	testing.expect(t, f.app.scroll > 0)
	cmds = take(&f)
	rd, ok = find_cmd(conn.Reading_Command, cmds) // no longer
	testing.expect(t, ok)
	testing.expect_value(t, rd.conv, 0)
	testing.expect(t, screen_has(&f, "older messages"))

	press(&f, .Page_Down)
	press(&f, .Page_Down)
	press(&f, .Page_Down)
	frame(&f)
	testing.expect_value(t, f.app.scroll, 0)
	cmds = take(&f)
	rd, ok = find_cmd(conn.Reading_Command, cmds)
	testing.expect(t, ok)
	testing.expect_value(t, rd.conv, 1)

	// The wheel does it too, and Escape goes back to the newest.
	app_event(&f.app, tui.Mouse_Event{kind = .Wheel_Up, x = 40, y = 5})
	testing.expect_value(t, f.app.scroll, SCROLL_STEP)
	app_event(&f.app, tui.Mouse_Event{kind = .Wheel_Down, x = 40, y = 5})
	testing.expect_value(t, f.app.scroll, 0)
	app_event(&f.app, tui.Mouse_Event{kind = .Wheel_Up, x = 40, y = 5})
	press(&f, .Escape)
	testing.expect_value(t, f.app.scroll, 0)
}

@(test)
test_scrolling_stops_at_the_oldest_message :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f, 80, 12)
	defer fixture_destroy(&f)
	for i in 0 ..< 30 {
		add_message(&f.v, 1, proto.Msg_Id(10 + i), 2, T0, "line of chat")
	}
	frame(&f)
	for _ in 0 ..< 50 {
		press(&f, .Page_Up)
	}
	frame(&f)
	g := geometry(&f.app)
	testing.expect_value(t, f.app.scroll, len(f.app.layout.rows) - g.timeline.h)
	testing.expect(t, screen_has(&f, "start of the conversation"))
}

@(test)
test_older_messages_are_asked_for_at_the_top :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f, 80, 12)
	defer fixture_destroy(&f)
	for i in 0 ..< 30 {
		add_message(&f.v, 1, proto.Msg_Id(100 + i), 2, T0, "line of chat")
	}
	tl := timeline_of(&f.v, 1)
	tl.have_oldest = false
	frame(&f)
	discard(&f)
	for _ in 0 ..< 6 {
		press(&f, .Page_Up)
		frame(&f)
	}
	cmds := take(&f)
	hist, ok := find_cmd(conn.History_Command, cmds)
	testing.expect(t, ok)
	testing.expect_value(t, hist.conv, 1)
	testing.expect(t, !hist.newer)
	// Once for the same oldest message.
	n := 0
	for c in cmds {
		if _, is := c.(conn.History_Command); is {
			n += 1
		}
	}
	testing.expect_value(t, n, 1)
	// While it loads, nothing more; when it came, the next page.
	tl.loading = true
	tl.revision += 1
	frame(&f)
	testing.expect_value(t, len(take(&f)), 0)
}

@(test)
test_newer_messages_are_asked_for_at_the_bottom :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	some_chat(&f)
	tl := timeline_of(&f.v, 1)
	tl.have_newest = false
	frame(&f)
	cmds := take(&f)
	hist, ok := find_cmd(conn.History_Command, cmds)
	testing.expect(t, ok)
	testing.expect(t, hist.newer)
}

@(test)
test_new_messages_do_not_move_what_is_being_read :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f, 80, 12)
	defer fixture_destroy(&f)
	for i in 0 ..< 30 {
		add_message(&f.v, 1, proto.Msg_Id(10 + i), 2, T0, "line of chat")
	}
	frame(&f)
	press(&f, .Page_Up)
	frame(&f)
	before := f.app.scroll
	m := add_message(&f.v, 1, 100, 2, T0, "a new one")
	_ = m
	timeline_of(&f.v, 1).appended += 1
	frame(&f)
	testing.expect(t, f.app.scroll > before)
	// At the bottom, it stays there.
	f.app.scroll = 0
	add_message(&f.v, 1, 101, 2, T0, "another")
	timeline_of(&f.v, 1).appended += 1
	frame(&f)
	testing.expect_value(t, f.app.scroll, 0)
	testing.expect(t, screen_has(&f, "another"))
}

@(test)
test_switching_conversation_resets_the_view :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f, 80, 12)
	defer fixture_destroy(&f)
	for i in 0 ..< 30 {
		add_message(&f.v, 1, proto.Msg_Id(10 + i), 2, T0, "line of chat")
	}
	add_message(&f.v, 2, 200, 2, T0, "in dev")
	frame(&f)
	press(&f, .Page_Up)
	press(&f, .Tab)
	type_text(&f, "r")
	frame(&f)
	f.v.viewing = 2
	frame(&f)
	testing.expect_value(t, f.app.scroll, 0)
	testing.expect_value(t, f.app.reply_to, 0)
	testing.expect_value(t, f.app.cursor_msg, 0)
	testing.expect(t, screen_has(&f, "in dev"))
	testing.expect(t, screen_has(&f, "# dev"))
}

@(test)
test_the_unread_line_stays_while_reading :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	some_chat(&f)
	f.v.channels[1].id = 2
	add_message(&f.v, 2, 20, 2, T0, "old")
	add_message(&f.v, 2, 21, 2, T0 + 5 * MINUTE, "fresh")
	f.v.channels[1].unread = 1
	f.v.channels[1].read = 20
	f.v.viewing = 2
	frame(&f)
	testing.expect(t, screen_has(&f, "new messages"))
	// The server then says it was all read: the line stays where it was.
	f.v.channels[1].unread = 0
	f.v.channels[1].read = 21
	timeline_of(&f.v, 2).revision += 1
	frame(&f)
	testing.expect(t, screen_has(&f, "new messages"))
}

@(test)
test_switching_with_alt_and_numbers :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	frame(&f)
	discard(&f)
	press(&f, .Down, {.Alt})
	cmds := take(&f)
	vc, ok := find_cmd(conn.View_Command, cmds)
	testing.expect(t, ok)
	testing.expect_value(t, vc.conv, 2)
	press(&f, .Up, {.Alt}) // wraps around
	cmds = take(&f)
	vc, _ = find_cmd(conn.View_Command, cmds)
	testing.expect_value(t, vc.conv, 3)
	app_event(&f.app, tui.Key_Event{key = .Rune, rune = '3', mods = {.Alt}})
	cmds = take(&f)
	vc, _ = find_cmd(conn.View_Command, cmds)
	testing.expect_value(t, vc.conv, 3)
	// Past the last: nothing.
	app_event(&f.app, tui.Key_Event{key = .Rune, rune = '9', mods = {.Alt}})
	testing.expect_value(t, len(take(&f)), 0)
}

@(test)
test_dragging_the_border_resizes_the_list :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	frame(&f)
	testing.expect_value(t, f.app.channel_w, CHANNEL_W_DEFAULT)
	app_event(&f.app, tui.Mouse_Event{kind = .Press, button = .Left, x = CHANNEL_W_DEFAULT, y = 5})
	testing.expect_value(t, f.app.drag, Drag.Border)
	app_event(&f.app, tui.Mouse_Event{kind = .Drag, button = .Left, x = 34, y = 5})
	testing.expect_value(t, f.app.channel_w, 34)
	app_event(&f.app, tui.Mouse_Event{kind = .Drag, button = .Left, x = 2, y = 5})
	testing.expect_value(t, f.app.channel_w, CHANNEL_W_MIN)
	app_event(&f.app, tui.Mouse_Event{kind = .Release, button = .Left, x = 2, y = 5})
	testing.expect_value(t, f.app.drag, Drag.None)
	frame(&f)
	testing.expect_value(t, tui.cell_at(&f.buf, CHANNEL_W_MIN, 3).r, '│')
}

@(test)
test_typing_indicator :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	add_account(&f.v, 3, "ben")
	f.v.typing[2] = {{1, 0}, time.tick_now()}
	frame(&f)
	testing.expect(t, screen_has(&f, "anna is typing"))
	f.v.typing[3] = {{1, 0}, time.tick_now()}
	frame(&f)
	testing.expect(t, screen_has(&f, "anna and ben are typing") || screen_has(&f, "ben and anna are typing"))
	// Us, other conversations and old notices don't count.
	clear(&f.v.typing)
	f.v.typing[1] = {{1, 0}, time.tick_now()}
	f.v.typing[2] = {{2, 0}, time.tick_now()}
	frame(&f)
	testing.expect(t, !screen_has(&f, "typing"))
}

@(test)
test_login_dialog :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	f.app.device = "laptop"
	f.v.login.state = .Needed
	frame(&f)
	testing.expect_value(t, f.app.dialog.kind, Dialog_Kind.Login)
	testing.expect(t, screen_has(&f, "Log in"))
	testing.expect(t, screen_has(&f, "User name"))
	discard(&f)
	type_text(&f, "anna")
	// Enter in the first field goes to the second, which hides what is typed.
	press(&f, .Enter)
	type_text(&f, "secret")
	frame(&f)
	testing.expect(t, screen_has(&f, "••••••"))
	testing.expect(t, !screen_has(&f, "secret"))
	press(&f, .Enter)
	cmds := take(&f)
	login, ok := find_cmd(conn.Login_Command, cmds)
	testing.expect(t, ok)
	testing.expect_value(t, login.username, "anna")
	testing.expect_value(t, login.password, "secret")
	testing.expect_value(t, login.device, "laptop")
	conn.command_destroy(cmds[0])
	testing.expect_value(t, tui.editor_text(&f.app.dialog.fields[1]), "") // the password is not kept

	// The message box does not get the keys meanwhile.
	testing.expect_value(t, tui.editor_text(&f.app.editor), "")
	// When it worked, the dialog goes.
	f.v.login.state = .Done
	frame(&f)
	testing.expect_value(t, f.app.dialog.kind, Dialog_Kind.None)
}

@(test)
test_login_dialog_shows_the_error_and_needs_a_name :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	f.v.login.state = .Needed
	f.v.login.error = strings.clone("wrong password")
	frame(&f)
	testing.expect(t, screen_has(&f, "wrong password"))
	discard(&f)
	press(&f, .Enter) // to the password
	press(&f, .Enter) // no name: back to the name, nothing sent
	testing.expect_value(t, f.app.dialog.field, 0)
	testing.expect_value(t, len(take(&f)), 0)
	// Pasting into a field.
	app_event(&f.app, tui.Paste_Event{"pasted\nsecond line"})
	testing.expect_value(t, tui.editor_text(&f.app.dialog.fields[0]), "pasted")
}

@(test)
test_key_change_dialog :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	f.v.key_change = {
		changed  = true,
		server   = strings.clone("example.org:7777"),
		saved    = {0 ..< 32 = 0xaa},
		received = {0 ..< 32 = 0xbb},
	}
	frame(&f)
	testing.expect_value(t, f.app.dialog.kind, Dialog_Kind.Key_Change)
	testing.expect(t, screen_has(&f, "key has changed"))
	testing.expect(t, screen_has(&f, "aaaaaaaa"))
	testing.expect(t, screen_has(&f, "bbbbbbbb"))
	// Other keys do nothing.
	type_text(&f, "x")
	testing.expect(t, !f.app.quit && !f.app.reconnect)
	type_text(&f, "q")
	testing.expect(t, f.app.quit)
}

@(test)
test_trusting_a_new_key :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	dir, err := os.make_directory_temp("", "yap-cli-*", context.temp_allocator)
	if err != nil {
		testing.fail_now(t, "could not make a temporary directory")
	}
	defer os.remove_all(dir)
	path := strings.concatenate({dir, "/known_servers"}, context.temp_allocator)
	f.app.known_servers = path
	f.v.key_change = {
		changed  = true,
		server   = strings.clone("example.org:7777"),
		saved    = {0 ..< 32 = 0xaa},
		received = {0 ..< 32 = 0xbb},
	}
	frame(&f)
	type_text(&f, "t")
	testing.expect(t, f.app.reconnect)
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, read_err == nil)
	testing.expect(t, strings.contains(string(data), "example.org:7777"))
	testing.expect(t, strings.contains(string(data), "bbbbbbbb"))
}

@(test)
test_a_key_that_cannot_be_saved_is_not_trusted :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	f.app.known_servers = "/nonexistent-directory/known_servers"
	context.logger = log.nil_logger() // writing the file is going to complain
	f.v.key_change = {
		changed  = true,
		server   = strings.clone("example.org:7777"),
		received = {0 ..< 32 = 0xbb},
	}
	frame(&f)
	type_text(&f, "t")
	testing.expect(t, !f.app.reconnect)
	testing.expect(t, strings.contains(f.app.notice, "Could not save"))
}

@(test)
test_connection_trouble_is_shown :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	f.v.status = .Failed
	f.v.error = strings.clone("Could not reach example.org:7777.")
	f.v.retrying = true
	frame(&f)
	testing.expect(t, strings.contains(screen(&f)[0], "Could not reach"))
	testing.expect(t, strings.contains(screen(&f)[0], "trying again"))
}

@(test)
test_the_cursor_follows_the_text :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	frame(&f)
	x0 := f.app.cursor.x
	type_text(&f, "日本")
	frame(&f)
	testing.expect_value(t, f.app.cursor.x, x0 + 4)
	press(&f, .Left)
	frame(&f)
	testing.expect_value(t, f.app.cursor.x, x0 + 2)
}

@(test)
test_a_tiny_terminal_does_not_crash :: proc(t: ^testing.T) {
	for size in ([?][2]int{{1, 1}, {10, 3}, {20, 5}, {200, 2}, {0, 0}}) {
		f: Fixture
		fixture(&f, size.x, size.y)
		defer fixture_destroy(&f)
		some_chat(&f)
		f.v.login.state = .Needed
		frame(&f)
		type_text(&f, "hello")
		click(&f, 0, 0)
		frame(&f)
	}
}

@(test)
test_commands_of_the_headless_client :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	frame(&f)
	discard(&f)
	run :: proc(f: ^Fixture, line: string) -> [dynamic]conn.Command {
		type_text(f, line)
		press(f, .Enter)
		return take(f)
	}
	cmds := run(&f, "/pin 10")
	pin, ok := find_cmd(conn.Pin_Command, cmds)
	testing.expect(t, ok)
	testing.expect_value(t, pin.id, 10)
	testing.expect(t, pin.on)

	cmds = run(&f, "/react 10 :+1:")
	react, ok2 := find_cmd(conn.React_Command, cmds)
	testing.expect(t, ok2)
	testing.expect_value(t, react.id, 10)
	testing.expect_value(t, react.emoji, ":+1:")
	conn.command_destroy(react)

	cmds = run(&f, "/dm anna hello there")
	dm, ok3 := find_cmd(conn.DM_Command, cmds)
	testing.expect(t, ok3)
	testing.expect_value(t, dm.name, "anna")
	testing.expect_value(t, dm.text, "hello there")
	conn.command_destroy(dm)

	// Usage errors are shown, a line long, in the info line.
	cmds = run(&f, "/register x")
	testing.expect_value(t, len(cmds), 0)
	testing.expect(t, strings.contains(f.app.notice, "/register <username>"))
	testing.expect(t, f.app.notice_error)
	frame(&f)
	testing.expect(t, screen_has(&f, "/register <username>"))
}

@(test)
test_attaching_files_with_a_command :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	frame(&f)
	discard(&f)
	type_text(&f, "/attach /tmp/a.txt")
	press(&f, .Enter)
	testing.expect_value(t, len(f.app.attached), 1)
	testing.expect(t, strings.contains(f.app.notice, "1 file(s) attached"))
}

// add_dm adds a DM with someone to the View.
@(private = "file")
add_dm :: proc(f: ^Fixture, id: proto.Conv_Id, with: proto.Account_Id, last: proto.Msg_Id, unread := 0, last_time := T0) {
	append(&f.v.dms, conn.View_DM{id = id, with = with, last = last, unread = unread, last_time = last_time})
}

@(test)
test_direct_messages_are_listed_under_the_channels :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	add_account(&f.v, 3, "ben")
	add_account(&f.v, 4, "cy")
	add_dm(&f, 50, 2, 9, unread = 2, last_time = T0)
	add_dm(&f, 51, 3, 12, last_time = T0 + MINUTE) // newer, so first
	add_dm(&f, 52, 4, 0) // nothing said: not listed
	add_dm(&f, 53, 1, 5) // with ourselves: the notes
	f.v.users[7] = {account = 2}
	f.v.my_num = 1
	frame(&f)
	rows := screen(&f)
	testing.expect(t, strings.contains(rows[5], "Direct messages"), rows[5])
	testing.expect(t, strings.contains(rows[6], "○ ben"), rows[6]) // not online
	testing.expect(t, strings.contains(rows[7], "● anna") && strings.contains(rows[7], " 2 "), rows[7])
	testing.expect(t, !screen_has(&f, "cy"))
	testing.expect_value(t, row_text_of_list(&f, 8), "")
}

@(private = "file")
row_text_of_list :: proc(f: ^Fixture, y: int) -> string {
	row := screen(f)[y]
	if len(row) < 26 {
		return ""
	}
	return strings.trim_space(tui.cut_to_width(row, 26))
}

@(test)
test_groups_are_listed_by_their_members :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	add_account(&f.v, 3, "ben")
	add_account(&f.v, 4, "cy")
	dm := conn.View_DM{id = 60, last = 3, last_time = T0, count = 2}
	dm.members[0], dm.members[1] = 3, 4
	append(&f.v.dms, dm)
	frame(&f)
	testing.expect(t, screen_has(&f, "◆ ben, cy"))
}

@(test)
test_clicking_a_dm_and_talking_in_it :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	add_dm(&f, 50, 2, 9)
	add_message(&f.v, 50, 9, 2, T0, "psst")
	frame(&f)
	discard(&f)
	y := row_of(&f, "anna")
	click(&f, 5, y)
	cmds := take(&f)
	vc, ok := find_cmd(conn.View_Command, cmds)
	testing.expect(t, ok)
	testing.expect_value(t, vc.conv, 50)
	f.v.viewing = 50
	frame(&f)
	testing.expect(t, strings.contains(screen(&f)[0], "@ anna"), screen(&f)[0])
	testing.expect(t, screen_has(&f, "psst"))
	// What is written goes to the conversation being looked at.
	type_text(&f, "hello")
	press(&f, .Enter)
	cmds = take(&f)
	chat, is_chat := find_cmd(conn.Chat_Command, cmds)
	testing.expect(t, is_chat)
	testing.expect_value(t, chat.dm_to, 0)
	testing.expect_value(t, chat.thread, conn.Timeline_Key{})
	for c in cmds {
		conn.command_destroy(c)
	}
}

@(test)
test_keys_switch_between_channels_and_dms :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	add_dm(&f, 50, 2, 9)
	f.v.viewing = 3 // the last channel
	frame(&f)
	discard(&f)
	press(&f, .Down, {.Alt})
	cmds := take(&f)
	vc, _ := find_cmd(conn.View_Command, cmds)
	testing.expect_value(t, vc.conv, 50)
	app_event(&f.app, tui.Key_Event{key = .Rune, rune = '4', mods = {.Alt}})
	cmds = take(&f)
	vc, _ = find_cmd(conn.View_Command, cmds)
	testing.expect_value(t, vc.conv, 50)
}

@(test)
test_a_dm_with_a_deleted_account_cannot_be_written_to :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	add_dm(&f, 50, 2, 9)
	acc := f.v.accounts[2]
	acc.flags += {.Deleted}
	f.v.accounts[2] = acc
	add_message(&f.v, 50, 9, 2, T0, "bye")
	f.v.viewing = 50
	frame(&f)
	click(&f, 40, row_of(&f, "bye"))
	frame(&f)
	testing.expect(t, !screen_has(&f, "Reply"))
	testing.expect(t, screen_has(&f, "Copy text"))
}

@(test)
test_dm_unread_counts_in_the_status_bar :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	add_dm(&f, 50, 2, 9, unread = 5)
	frame(&f)
	last := screen(&f)[f.buf.h - 1]
	testing.expect(t, strings.contains(last, "9 unread"), last)
}

@(private = "file")
with_members :: proc(f: ^Fixture) {
	add_account(&f.v, 3, "ben")
	add_account(&f.v, 4, "Zoe")
	f.v.my_num = 1
	f.v.users[7] = {account = 4} // Zoe is here
	f.v.users[8] = {account = 3} // and ben
	acc := f.v.accounts[3]
	acc.activity = .Away
	f.v.accounts[3] = acc
	f.v.members = {
		conv = 1,
	}
	append(&f.v.members.accounts, 1, 2, 3, 4)
	append(&f.v.members.admins, 4)
}

@(test)
test_the_member_list_shows_who_is_here_first :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f, 120, 20)
	defer fixture_destroy(&f)
	with_members(&f)
	frame(&f)
	rows := screen(&f)
	testing.expect(t, strings.contains(rows[0], "Members  3/4"), rows[0])
	// us (always here), then the others online by name, then those away.
	testing.expect(t, strings.contains(rows[1], "● ben"), rows[1])
	testing.expect(t, strings.contains(rows[2], "● me"), rows[2])
	testing.expect(t, strings.contains(rows[3], "● Zoe ★"), rows[3])
	testing.expect(t, strings.contains(rows[4], "○ anna"), rows[4])
	// Away has its own colour, and gone is dim.
	testing.expect(t, tui.cell_at(&f.buf, 120 - MEMBERS_W + 1, 1).style != tui.cell_at(&f.buf, 120 - MEMBERS_W + 1, 2).style)
	testing.expect(t, tui.cell_at(&f.buf, 120 - MEMBERS_W + 1, 4).style == theme.dim)
	// The chat gives way to it.
	testing.expect_value(t, tui.cell_at(&f.buf, 120 - MEMBERS_W - 1, 5).r, '│')
}

@(test)
test_members_are_asked_for_once_per_conversation :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f, 120, 20)
	defer fixture_destroy(&f)
	frame(&f)
	cmds := take(&f)
	m, ok := find_cmd(conn.Members_Command, cmds)
	testing.expect(t, ok)
	testing.expect_value(t, m.conv, 1)
	for c in cmds {
		conn.command_destroy(c)
	}
	frame(&f)
	frame(&f)
	cmds = take(&f)
	_, again := find_cmd(conn.Members_Command, cmds)
	testing.expect(t, !again)
	f.v.viewing = 2
	frame(&f)
	cmds = take(&f)
	m, ok = find_cmd(conn.Members_Command, cmds)
	testing.expect(t, ok)
	testing.expect_value(t, m.conv, 2)
	// While it hasn't come, the list is empty and says so.
	testing.expect(t, screen_has(&f, "Members"))
	testing.expect(t, !screen_has(&f, "anna"))
}

@(test)
test_the_member_list_goes_with_f2_and_a_narrow_screen :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f, 120, 20)
	defer fixture_destroy(&f)
	with_members(&f)
	frame(&f)
	testing.expect(t, screen_has(&f, "Members"))
	press(&f, .F2)
	frame(&f)
	testing.expect(t, !screen_has(&f, "Members"))
	press(&f, .F2)
	frame(&f)
	testing.expect(t, screen_has(&f, "Members"))
	// Not on a screen that is too narrow for it.
	tui.buffer_resize(&f.buf, 90, 20)
	frame(&f)
	testing.expect(t, !screen_has(&f, "Members"))
}

@(test)
test_clicking_a_member_opens_their_dm :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f, 120, 20)
	defer fixture_destroy(&f)
	with_members(&f)
	frame(&f)
	discard(&f)
	click(&f, 120 - MEMBERS_W + 5, 4) // anna
	cmds := take(&f)
	dm, ok := find_cmd(conn.DM_Command, cmds)
	testing.expect(t, ok)
	testing.expect_value(t, dm.name, "anna")
	conn.command_destroy(dm)
	// Clicking oneself does nothing.
	click(&f, 120 - MEMBERS_W + 5, 2)
	testing.expect_value(t, len(take(&f)), 0)
}

@(private = "file")
react_to_first :: proc(f: ^Fixture) {
	m := add_message(&f.v, 1, 10, 2, T0, "nice")
	append(&m.reactions, conn.Reaction{emoji = strings.clone("👍"), count = 2})
	append(&m.reactions, conn.Reaction{emoji = strings.clone("❤"), count = 1, me = true})
}

@(test)
test_clicking_a_reaction_adds_or_takes_back_ours :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	react_to_first(&f)
	frame(&f)
	discard(&f)
	y := row_of(&f, "👍 2")
	g := geometry(&f.app)
	chip := f.app.layout.rows[len(f.app.layout.rows) - 1].chips
	testing.expect_value(t, len(chip), 2)
	click(&f, g.timeline.x + chip[0].start + 2, y)
	cmds := take(&f)
	rc, ok := find_cmd(conn.React_Command, cmds)
	testing.expect(t, ok)
	testing.expect_value(t, rc.id, 10)
	testing.expect_value(t, rc.emoji, "👍")
	testing.expect(t, rc.on)
	conn.command_destroy(rc)
	// Ours is taken back.
	click(&f, g.timeline.x + chip[1].start + 2, y)
	cmds = take(&f)
	rc, ok = find_cmd(conn.React_Command, cmds)
	testing.expect(t, ok)
	testing.expect_value(t, rc.emoji, "❤")
	testing.expect(t, !rc.on)
	conn.command_destroy(rc)
	// The message's menu is not what opens.
	testing.expect(t, !f.app.menu.open)
}

@(test)
test_reactions_need_the_right :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	react_to_first(&f)
	f.v.channels[0].rights = {.See, .Write}
	frame(&f)
	discard(&f)
	y := row_of(&f, "👍 2")
	click(&f, geometry(&f.app).timeline.x + f.app.layout.rows[len(f.app.layout.rows) - 1].chips[0].start + 2, y)
	testing.expect_value(t, len(take(&f)), 0)
	click(&f, 40, row_of(&f, "nice"))
	frame(&f)
	testing.expect(t, !screen_has(&f, "Add reaction"))
}

@(test)
test_the_picker_reacts_to_a_message :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	add_message(&f.v, 1, 10, 2, T0, "nice")
	frame(&f)
	discard(&f)
	click(&f, 40, row_of(&f, "nice"))
	frame(&f)
	// Add reaction is the second item of the menu, after Reply.
	testing.expect_value(t, f.app.menu.items[1].action, Menu_Action.React)
	click(&f, f.app.menu.at.x + 3, f.app.menu.at.y + 1)
	testing.expect_value(t, f.app.dialog.kind, Dialog_Kind.Picker)
	frame(&f)
	testing.expect(t, screen_has(&f, "React with"))
	testing.expect(t, screen_has(&f, "👍"))
	// With the keys: right, down, Enter picks the second row's second emoji.
	press(&f, .Right)
	press(&f, .Down)
	press(&f, .Enter)
	cmds := take(&f)
	rc, ok := find_cmd(conn.React_Command, cmds)
	testing.expect(t, ok)
	testing.expect_value(t, rc.id, 10)
	testing.expect_value(t, rc.emoji, PICKER_EMOJI[PICKER_COLUMNS + 1])
	testing.expect(t, rc.on)
	conn.command_destroy(rc)
	testing.expect_value(t, f.app.dialog.kind, Dialog_Kind.None)
}

@(test)
test_the_picker_with_the_mouse_and_escape :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	add_message(&f.v, 1, 10, 2, T0, "nice")
	frame(&f)
	press(&f, .Tab)
	type_text(&f, "a")
	testing.expect_value(t, f.app.dialog.kind, Dialog_Kind.Picker)
	frame(&f)
	discard(&f)
	press(&f, .Escape)
	testing.expect_value(t, f.app.dialog.kind, Dialog_Kind.None)
	testing.expect_value(t, len(take(&f)), 0)
	type_text(&f, "a")
	frame(&f)
	// The third emoji, by clicking it.
	var_hit: Hit
	for h in f.app.hits {
		if h.kind == .Emoji && h.id == 2 {
			var_hit = h
		}
	}
	click(&f, var_hit.rect.x + 1, var_hit.rect.y)
	cmds := take(&f)
	rc, ok := find_cmd(conn.React_Command, cmds)
	testing.expect(t, ok)
	testing.expect_value(t, rc.emoji, PICKER_EMOJI[2])
	conn.command_destroy(rc)
	// Clicking away closes it without reacting.
	type_text(&f, "a")
	frame(&f)
	click(&f, 1, 1)
	testing.expect_value(t, f.app.dialog.kind, Dialog_Kind.None)
	testing.expect_value(t, len(take(&f)), 0)
}

@(test)
test_the_picker_takes_back_our_own_reaction :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	m := add_message(&f.v, 1, 10, 2, T0, "nice")
	append(&m.reactions, conn.Reaction{emoji = strings.clone(PICKER_EMOJI[0]), count = 1, me = true})
	frame(&f)
	open_picker(&f.app, 10)
	press(&f, .Enter) // the first emoji
	cmds := take(&f)
	rc, ok := find_cmd(conn.React_Command, cmds)
	testing.expect(t, ok)
	testing.expect(t, !rc.on)
	conn.command_destroy(rc)
}

// a_thread has a root with replies, the window of the thread and the root as the
// thread's pane wants them.
@(private = "file")
a_thread :: proc(f: ^Fixture) {
	root := add_message(&f.v, 1, 10, 2, T0, "shall we ship?")
	root.flags += {.Has_Thread}
	root.reply_count = 2
	r1 := add_message(&f.v, 1, 11, 1, T0 + MINUTE, "yes")
	r1.thread_root = 10
	r2 := add_message(&f.v, 1, 12, 2, T0 + 2 * MINUTE, "ok then")
	r2.thread_root = 10
	f.v.roots[10] = {
		conv = 1,
		msg  = {id = 10, sender = 2, time = T0, text = strings.clone("shall we ship?"), reply_count = 2},
	}
	tl := timeline_of(&f.v, 1, 10)
	append(&tl.messages, conn.View_Message{id = 11, sender = 1, time = T0 + MINUTE, thread_root = 10, text = strings.clone("yes")})
	append(&tl.messages, conn.View_Message{id = 12, sender = 2, time = T0 + 2 * MINUTE, thread_root = 10, text = strings.clone("ok then")})
}

@(test)
test_clicking_the_replies_opens_the_thread :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f, 130, 20)
	defer fixture_destroy(&f)
	a_thread(&f)
	frame(&f)
	discard(&f)
	click(&f, 60, row_of(&f, "↩ 2 replies"))
	testing.expect_value(t, f.app.thread, 10)
	cmds := take(&f)
	tc, ok := find_cmd(conn.Thread_Command, cmds)
	testing.expect(t, ok)
	testing.expect(t, tc.open)
	testing.expect_value(t, tc.thread, conn.Timeline_Key{1, 10})
	frame(&f)
	// The pane is at the right, in place of the member list, with the root and its replies.
	rows := screen(&f)
	testing.expect(t, strings.contains(rows[0], "Thread"), rows[0])
	testing.expect(t, !screen_has(&f, "Members"))
	testing.expect(t, screen_has(&f, "2 replies ─"))
	testing.expect(t, screen_has(&f, "ok then"))
	// The root is in the messages, in the reply line of its first reply, and in the pane.
	count := 0
	for r in rows {
		count += 1 if strings.contains(r, "shall we ship?") else 0
	}
	testing.expect_value(t, count, 3)
}

@(test)
test_a_narrow_screen_shows_the_thread_instead :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f, 80, 20)
	defer fixture_destroy(&f)
	a_thread(&f)
	frame(&f)
	open_thread(&f.app, 10)
	frame(&f)
	count := 0
	for r in screen(&f) {
		count += 1 if strings.contains(r, "shall we ship?") else 0
	}
	testing.expect_value(t, count, 1) // the thread's root; the messages are covered
	testing.expect(t, screen_has(&f, "Thread"))
	testing.expect(t, screen_has(&f, "✕ close"))
	// The message box is still there.
	testing.expect(t, f.app.cursor_shown)
}

@(test)
test_writing_in_an_open_thread :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f, 130, 20)
	defer fixture_destroy(&f)
	a_thread(&f)
	frame(&f)
	open_thread(&f.app, 10)
	frame(&f)
	discard(&f)
	testing.expect(t, screen_has(&f, "Writing in the thread"))
	type_text(&f, "agreed")
	press(&f, .Enter)
	cmds := take(&f)
	chat, ok := find_cmd(conn.Chat_Command, cmds)
	testing.expect(t, ok)
	testing.expect_value(t, chat.thread, conn.Timeline_Key{1, 10})
	testing.expect_value(t, chat.text, "agreed")
	for c in cmds {
		conn.command_destroy(c)
	}
	testing.expect_value(t, f.app.thread, 10) // it stays open
}

@(test)
test_closing_a_thread :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f, 130, 20)
	defer fixture_destroy(&f)
	a_thread(&f)
	frame(&f)
	open_thread(&f.app, 10)
	frame(&f)
	discard(&f)
	press(&f, .Escape)
	testing.expect_value(t, f.app.thread, 0)
	cmds := take(&f)
	tc, ok := find_cmd(conn.Thread_Command, cmds)
	testing.expect(t, ok)
	testing.expect(t, !tc.open)
	frame(&f)
	testing.expect(t, screen_has(&f, "Members"))
	// With the button.
	open_thread(&f.app, 10)
	frame(&f)
	discard(&f)
	y := row_of(&f, "✕ close")
	click(&f, 130 - 4, y)
	testing.expect_value(t, f.app.thread, 0)
}

@(test)
test_the_menu_opens_threads_and_other_threads_replace :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f, 130, 20)
	defer fixture_destroy(&f)
	a_thread(&f)
	other := add_message(&f.v, 1, 20, 2, T0 + 5 * MINUTE, "another topic")
	other.flags += {.Has_Thread}
	other.reply_count = 1
	frame(&f)
	click(&f, 40, row_of(&f, "another topic"))
	frame(&f)
	found := false
	for it in f.app.menu.items {
		found ||= it.action == .Thread
	}
	testing.expect(t, found)
	// A message without replies has no thread to open.
	menu_close(&f.app)
	open_thread(&f.app, 10)
	discard(&f)
	open_thread(&f.app, 20)
	cmds := take(&f)
	testing.expect_value(t, len(cmds), 2)
	first, is_close := cmds[0].(conn.Thread_Command)
	testing.expect(t, is_close && !first.open && first.thread.root == 10)
	second, is_open := cmds[1].(conn.Thread_Command)
	testing.expect(t, is_open && second.open && second.thread.root == 20)
	testing.expect_value(t, f.app.thread, 20)
}

@(test)
test_a_reply_has_a_thread_to_open :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f)
	defer fixture_destroy(&f)
	a_thread(&f)
	frame(&f)
	click(&f, 40, row_of(&f, "ok then"))
	frame(&f)
	testing.expect(t, screen_has(&f, "Open thread"))
	press(&f, .Escape)
	press(&f, .Tab)
	// Keys: t on a reply opens its thread.
	press(&f, .Up)
	type_text(&f, "t")
	testing.expect_value(t, f.app.thread, 10)
}

@(test)
test_older_replies_are_asked_for :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f, 130, 20)
	defer fixture_destroy(&f)
	a_thread(&f)
	timeline_of(&f.v, 1, 10).have_oldest = false
	frame(&f)
	open_thread(&f.app, 10)
	discard(&f)
	frame(&f)
	cmds := take(&f)
	hist, ok := find_cmd(conn.History_Command, cmds)
	testing.expect(t, ok)
	testing.expect_value(t, hist.root, 10)
	testing.expect_value(t, hist.conv, 1)
}

@(test)
test_switching_conversation_closes_the_thread_pane :: proc(t: ^testing.T) {
	f: Fixture
	fixture(&f, 130, 20)
	defer fixture_destroy(&f)
	a_thread(&f)
	frame(&f)
	open_thread(&f.app, 10)
	frame(&f)
	f.v.viewing = 2
	frame(&f)
	testing.expect_value(t, f.app.thread, 0)
}

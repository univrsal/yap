#+build !wasi
package proto

import "core:strings"
import "core:testing"

@(test)
test_command_name_valid :: proc(t: ^testing.T) {
	for good in ([]string{"a", "roll", "my-cmd_2", strings.repeat("x", MAX_COMMAND_NAME, context.temp_allocator)}) {
		testing.expectf(t, command_name_valid(good), "%q", good)
	}
	for bad in ([]string{"", "Roll", "a b", "/roll", "bot:roll", "é", strings.repeat("x", MAX_COMMAND_NAME + 1, context.temp_allocator)}) {
		testing.expectf(t, !command_name_valid(bad), "%q", bad)
	}
}

@(test)
test_bot_commands_codec :: proc(t: ^testing.T) {
	list := []Bot_Command {
		{"weather", "Show the weather", "<city> [days]"},
		{"roll", "Roll dice", ""},
		{"ping", "", ""},
	}
	buf: [COMMANDS_CHANGED_MAX_SIZE]u8

	// Without an account (Bot_Commands_Set).
	body := encode_bot_commands(buf[:], list)
	testing.expect(t, body != nil)
	account, got, ok := decode_bot_commands(body)
	testing.expect(t, ok)
	testing.expect_value(t, account, Account_Id(0))
	testing.expect_value(t, len(got), 3)
	for c, i in got {
		testing.expect_value(t, c, list[i])
	}

	// With one (Commands_Changed).
	body = encode_bot_commands(buf[:], list, 9)
	account, got, ok = decode_bot_commands(body, true)
	testing.expect(t, ok)
	testing.expect_value(t, account, Account_Id(9))
	testing.expect_value(t, len(got), 3)

	// An empty list is how a bot's commands go away.
	body = encode_bot_commands(buf[:], nil, 9)
	account, got, ok = decode_bot_commands(body, true)
	testing.expect(t, ok && account == 9 && len(got) == 0)

	// A truncated body is refused; so is trailing... nothing, a body may grow.
	for n in 0 ..< len(body) {
		_, _, ok = decode_bot_commands(body[:n], true)
		testing.expect(t, !ok)
	}
	body = encode_bot_commands(buf[:], list)
	for n in 0 ..< len(body) {
		_, _, ok = decode_bot_commands(body[:n])
		testing.expectf(t, !ok, "%d of %d", n, len(body))
	}
	_, _, ok = decode_bot_commands(body)
	testing.expect(t, ok)
}

@(test)
test_bot_commands_limits :: proc(t: ^testing.T) {
	buf: [COMMANDS_CHANGED_MAX_SIZE]u8

	// The largest set fits the size constant.
	many := make([]Bot_Command, MAX_BOT_COMMANDS, context.temp_allocator)
	for &c, i in many {
		c.name = strings.repeat(
			string([]u8{u8('a' + i % 26)}),
			MAX_COMMAND_NAME - 2,
			context.temp_allocator,
		)
		c.name = strings.concatenate(
			{c.name, string([]u8{u8('0' + i / 10), u8('0' + i % 10)})},
			context.temp_allocator,
		)
		c.description = strings.repeat("d", MAX_COMMAND_DESCRIPTION, context.temp_allocator)
		c.usage = strings.repeat("u", MAX_COMMAND_USAGE, context.temp_allocator)
	}
	body := encode_bot_commands(buf[:], many, 1)
	testing.expect_value(t, len(body), COMMANDS_CHANGED_MAX_SIZE)
	_, got, ok := decode_bot_commands(body, true)
	testing.expect(t, ok && len(got) == MAX_BOT_COMMANDS)

	// Too many, a bad name, a text that is too long: not encoded.
	testing.expect(
		t,
		encode_bot_commands(
			buf[:],
			make([]Bot_Command, MAX_BOT_COMMANDS + 1, context.temp_allocator),
		) ==
		nil,
	)
	testing.expect(t, encode_bot_commands(buf[:], {{name = "Bad"}}) == nil)
	testing.expect(
		t,
		encode_bot_commands(
			buf[:],
			{
				{
					name = "ok",
					description = strings.repeat(
						"d",
						MAX_COMMAND_DESCRIPTION + 1,
						context.temp_allocator,
					),
				},
			},
		) ==
		nil,
	)
	testing.expect(
		t,
		encode_bot_commands(
			buf[:],
			{
				{
					name = "ok",
					usage = strings.repeat("u", MAX_COMMAND_USAGE + 1, context.temp_allocator),
				},
			},
		) ==
		nil,
	)

	// A peer that doesn't encode so carefully is dealt with by the decoder.
	w := Writer {
		buf = buf[:],
	}
	put_u8(&w, 2)
	put_str8(&w, "a")
	put_str8(&w, "x")
	put_str8(&w, "y")
	put_str8(&w, "a") // a duplicate
	put_str8(&w, "")
	put_str8(&w, "")
	_, _, ok = decode_bot_commands(written(&w))
	testing.expect(t, !ok)

	w = Writer {
		buf = buf[:],
	}
	put_u8(&w, u8(MAX_BOT_COMMANDS + 1))
	_, _, ok = decode_bot_commands(written(&w))
	testing.expect(t, !ok)

	w = Writer {
		buf = buf[:],
	}
	put_u8(&w, 1)
	put_str8(&w, "Upper")
	put_str8(&w, "")
	put_str8(&w, "")
	_, _, ok = decode_bot_commands(written(&w))
	testing.expect(t, !ok)

	// Descriptions are cleaned and cut, not refused.
	w = Writer {
		buf = buf[:],
	}
	long := strings.concatenate(
		{"  line one\nline\ttwo \x07", strings.repeat("é", 200, context.temp_allocator)},
		context.temp_allocator,
	)
	put_u8(&w, 1)
	put_str8(&w, "cmd")
	put_str8(&w, long[:min(len(long), 255)])
	put_str8(&w, "<a>\r\n")
	_, got, ok = decode_bot_commands(written(&w))
	testing.expect(t, ok && len(got) == 1)
	testing.expect(t, strings.has_prefix(got[0].description, "line one line two é"))
	testing.expect(t, len(got[0].description) <= MAX_COMMAND_DESCRIPTION)
	testing.expect(t, !strings.contains_any(got[0].description, "\n\t\x07"))
	testing.expect_value(t, got[0].usage, "<a>")
}

@(test)
test_command_run :: proc(t: ^testing.T) {
	buf: [COMMAND_RUN_MAX_SIZE]u8
	req := Command_Run_Request{3, 77, 5, "roll", "2d6"}
	body := encode_command_run(buf[:], req)
	got, ok := decode_command_run(body)
	testing.expect(t, ok)
	testing.expect_value(t, got, req)

	// The longest one fits.
	req.args = strings.repeat("x", MAX_COMMAND_ARGS, context.temp_allocator)
	req.name = strings.repeat("n", MAX_COMMAND_NAME, context.temp_allocator)
	body = encode_command_run(buf[:], req)
	testing.expect_value(t, len(body), COMMAND_RUN_MAX_SIZE)
	got, ok = decode_command_run(body)
	testing.expect(t, ok && got == req)
	req.args = strings.repeat("x", MAX_COMMAND_ARGS + 1, context.temp_allocator)
	testing.expect(t, encode_command_run(buf[:], req) == nil)

	for n in 0 ..< len(body) {
		_, ok = decode_command_run(body[:n])
		testing.expect(t, !ok)
	}

	// No conversation, no bot, a bad name.
	for bad in ([]Command_Run_Request{{0, 0, 5, "a", ""}, {3, 0, 0, "a", ""}, {3, 0, 5, "A", ""}, {3, 0, 5, "", ""}}) {
		w := Writer {
			buf = buf[:],
		}
		put_u32(&w, u32(bad.conv))
		put_u64(&w, u64(bad.thread_root))
		put_u32(&w, u32(bad.account))
		put_str8(&w, bad.name)
		put_str16(&w, bad.args)
		_, ok = decode_command_run(written(&w))
		testing.expectf(t, !ok, "%v", bad)
	}
}

@(test)
test_command_invoked :: proc(t: ^testing.T) {
	buf: [COMMAND_INVOKED_MAX_SIZE]u8
	ev := Command_Invoked_Event{9031, 7, 0, 4, "roll", "2d6"}
	body := encode_command_invoked(buf[:], ev)
	got, ok := decode_command_invoked(body)
	testing.expect(t, ok)
	testing.expect_value(t, got, ev)

	ev.thread_root = 123
	ev.args = strings.repeat("x", MAX_COMMAND_ARGS, context.temp_allocator)
	ev.name = strings.repeat("n", MAX_COMMAND_NAME, context.temp_allocator)
	body = encode_command_invoked(buf[:], ev)
	testing.expect_value(t, len(body), COMMAND_INVOKED_MAX_SIZE)
	got, ok = decode_command_invoked(body)
	testing.expect(t, ok && got == ev)

	for n in 0 ..< len(body) {
		_, ok = decode_command_invoked(body[:n])
		testing.expect(t, !ok)
	}
	testing.expect(t, encode_command_invoked(buf[:], {0, 7, 0, 4, "a", ""}) != nil) // encoding doesn't check ids
	_, ok = decode_command_invoked(encode_command_invoked(buf[:], {0, 7, 0, 4, "a", ""}))
	testing.expect(t, !ok)
}

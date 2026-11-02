package proto

import "core:strings"

// Slash commands of bots (docs/design/bot-commands.md). A bot registers
// commands such as `/weather`; clients offer them while a person types, and
// running one reaches the bot as an event instead of a message to parse.
//
// 	Bot_Commands_Set  [n u8] per command: [name str8][description str8][usage str8]
// 	                  ->  (nothing)
// 	Commands_Changed  [account u32] then the same list as Bot_Commands_Set
// 	Command_Run       [conv u32][thread_root u64][account u32][name str8][args str16]
// 	                  ->  (nothing)
// 	Command_Invoked   [id u64][conv u32][thread_root u64][invoker u32]
// 	                  [name str8][args str16]
//
// Bot_Commands_Set replaces the whole set of the bot that sends it; only an
// account with the Bot flag may (Denied otherwise). The set is kept in memory
// for as long as the bot is connected. Commands_Changed is sent to every
// connection when a bot's set changes (an empty list: it has none now), and
// in the login sync for each connected bot that has commands.
//
// Command_Run is sent by anyone: `account` is the bot whose command it is, so
// that two bots can both have a /roll, and `args` is the text after the name.
// The server answers Not_Found (the conversation is not one the account can
// see, or the bot has no such command, which is also the case once the bot
// has left), Denied (the account may not post in the conversation, or the bot
// can't see it or write there), Invalid (the thread is not one of the
// conversation) or Rate_Limited. Otherwise it sends Command_Invoked to the
// bot's connection whose commands count, with `invoker` set by the server and a number `id` that is
// unique on the server. Nothing is posted: the bot answers with Msg_Post in
// the same conversation and thread.
//
// A name is 1 to MAX_COMMAND_NAME of a-z, 0-9, `-` and `_`. A set has at most
// MAX_BOT_COMMANDS commands with different names. Descriptions and usage hints
// are text for everyone to read, so a decoder runs them through sanitize_text
// and cuts them to their limits instead of refusing the set. A decoder is
// strict about the rest: a bad name, a duplicate, too many commands or a body
// that doesn't fit is not ok.

MAX_BOT_COMMANDS :: 50
MAX_COMMAND_NAME :: 32
MAX_COMMAND_DESCRIPTION :: 100 // bytes of UTF-8
MAX_COMMAND_USAGE :: 64 // bytes of UTF-8, such as "<city> [days]"
MAX_COMMAND_ARGS :: 2000 // bytes

BOT_COMMANDS_MAX_SIZE ::
	1 + MAX_BOT_COMMANDS * ((1 + MAX_COMMAND_NAME) + (1 + MAX_COMMAND_DESCRIPTION) + (1 + MAX_COMMAND_USAGE))
COMMANDS_CHANGED_MAX_SIZE :: 4 + BOT_COMMANDS_MAX_SIZE
COMMAND_RUN_MAX_SIZE :: 4 + 8 + 4 + (1 + MAX_COMMAND_NAME) + (2 + MAX_COMMAND_ARGS)
COMMAND_INVOKED_MAX_SIZE :: 8 + 4 + 8 + 4 + (1 + MAX_COMMAND_NAME) + (2 + MAX_COMMAND_ARGS)

// A number for an invocation, unique on the server for as long as it runs.
Invocation_Id :: distinct u64

Bot_Command :: struct {
	name:        string,
	description: string,
	usage:       string,
}

// Command_Run_Request is what a Command_Run asks for.
Command_Run_Request :: struct {
	conv:        Conv_Id,
	thread_root: Msg_Id,
	account:     Account_Id,
	name:        string,
	args:        string,
}

// Command_Invoked_Event is what a bot is told when someone runs its command.
Command_Invoked_Event :: struct {
	id:          Invocation_Id,
	conv:        Conv_Id,
	thread_root: Msg_Id,
	invoker:     Account_Id,
	name:        string,
	args:        string,
}

// command_name_valid is true if `name` can be the name of a command.
command_name_valid :: proc(name: string) -> bool {
	if len(name) < 1 || len(name) > MAX_COMMAND_NAME {
		return false
	}
	for c in transmute([]u8)name {
		switch c {
		case 'a' ..= 'z', '0' ..= '9', '-', '_':
		case:
			return false
		}
	}
	return true
}

// encode_bot_commands writes a list of commands to `out` (at least
// BOT_COMMANDS_MAX_SIZE, or COMMANDS_CHANGED_MAX_SIZE with `account`).
// With `account` it is a Commands_Changed body, without (0) a
// Bot_Commands_Set body. It returns nil if the list breaks the limits.
encode_bot_commands :: proc(out: []u8, commands: []Bot_Command, account: Account_Id = 0) -> []u8 {
	if len(commands) > MAX_BOT_COMMANDS {
		return nil
	}
	w := Writer {
		buf = out,
	}
	if account != 0 {
		put_u32(&w, u32(account))
	}
	put_u8(&w, u8(len(commands)))
	for c in commands {
		if !command_name_valid(c.name) ||
		   len(c.description) > MAX_COMMAND_DESCRIPTION ||
		   len(c.usage) > MAX_COMMAND_USAGE {
			return nil
		}
		put_str8(&w, c.name)
		put_str8(&w, c.description)
		put_str8(&w, c.usage)
	}
	return written(&w)
}

// decode_bot_commands reads a Bot_Commands_Set body, or with `with_account` a
// Commands_Changed body (whose account it returns). The list and the
// descriptions and hints are allocated with `allocator`; the names point into
// `body`.
decode_bot_commands :: proc(
	body: []u8,
	with_account := false,
	allocator := context.temp_allocator,
) -> (
	account: Account_Id,
	commands: []Bot_Command,
	ok: bool,
) {
	r := Reader {
		buf = body,
	}
	if with_account {
		account = Account_Id(get_u32(&r))
		if account == 0 {
			return
		}
	}
	n := int(get_u8(&r))
	if r.overflow || n > MAX_BOT_COMMANDS {
		return
	}
	list := make([]Bot_Command, n, allocator)
	for &c in list {
		c.name = get_str8(&r)
		description := get_str8(&r)
		usage := get_str8(&r)
		if r.overflow || !command_name_valid(c.name) {
			return
		}
		buf: [MAX_COMMAND_DESCRIPTION]u8
		c.description = strings.clone(sanitize_text(description, buf[:]), allocator)
		usage_buf: [MAX_COMMAND_USAGE]u8
		c.usage = strings.clone(sanitize_text(usage, usage_buf[:]), allocator)
	}
	for c, i in list {
		for other in list[:i] {
			if other.name == c.name {
				return
			}
		}
	}
	return account, list, !r.overflow
}

encode_command_run :: proc(out: []u8, req: Command_Run_Request) -> []u8 {
	if !command_name_valid(req.name) || len(req.args) > MAX_COMMAND_ARGS {
		return nil
	}
	w := Writer {
		buf = out,
	}
	put_u32(&w, u32(req.conv))
	put_u64(&w, u64(req.thread_root))
	put_u32(&w, u32(req.account))
	put_str8(&w, req.name)
	put_str16(&w, req.args)
	return written(&w)
}

decode_command_run :: proc(body: []u8) -> (req: Command_Run_Request, ok: bool) {
	r := Reader {
		buf = body,
	}
	req.conv = Conv_Id(get_u32(&r))
	req.thread_root = Msg_Id(get_u64(&r))
	req.account = Account_Id(get_u32(&r))
	req.name = get_str8(&r)
	req.args = get_str16(&r)
	ok =
		!r.overflow &&
		req.conv != 0 &&
		req.account != 0 &&
		command_name_valid(req.name) &&
		len(req.args) <= MAX_COMMAND_ARGS
	return
}

encode_command_invoked :: proc(out: []u8, ev: Command_Invoked_Event) -> []u8 {
	if !command_name_valid(ev.name) || len(ev.args) > MAX_COMMAND_ARGS {
		return nil
	}
	w := Writer {
		buf = out,
	}
	put_u64(&w, u64(ev.id))
	put_u32(&w, u32(ev.conv))
	put_u64(&w, u64(ev.thread_root))
	put_u32(&w, u32(ev.invoker))
	put_str8(&w, ev.name)
	put_str16(&w, ev.args)
	return written(&w)
}

decode_command_invoked :: proc(body: []u8) -> (ev: Command_Invoked_Event, ok: bool) {
	r := Reader {
		buf = body,
	}
	ev.id = Invocation_Id(get_u64(&r))
	ev.conv = Conv_Id(get_u32(&r))
	ev.thread_root = Msg_Id(get_u64(&r))
	ev.invoker = Account_Id(get_u32(&r))
	ev.name = get_str8(&r)
	ev.args = get_str16(&r)
	ok =
		!r.overflow &&
		ev.id != 0 &&
		ev.conv != 0 &&
		ev.invoker != 0 &&
		command_name_valid(ev.name) &&
		len(ev.args) <= MAX_COMMAND_ARGS
	return
}

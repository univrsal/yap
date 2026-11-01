package conn

import "core:fmt"
import "core:slice"
import "core:strings"

import "common:proto"

// Slash commands of bots (src/common/proto/bot_commands.odin,
// docs/design/bot-commands.md). The server tells us which commands the bots
// that are connected have registered (Commands_Changed, also in the login
// sync), we keep them in one list sorted by name, and the UI is given a copy
// of it (View.bot_commands) to offer while someone types.
//
// Running one (Bot_Run_Command) is worked out here from the same list, in the
// network thread, which the headless client shares:
//   - `/roll 2d6` runs the /roll of the one bot that has it, among the bots
//     that could be in this conversation (see bot_commands_scope);
//   - if several bots have a /roll the command is not guessed: we say so, and
//     `/dicebot:roll 2d6` names the bot;
//   - a script's command of the same name, and the client's own commands,
//     are looked at before this is (ui_scripts.odin, ui_message_menu.odin).

// Bot_Command_Entry is one command of one bot. Whoever holds a list of them
// owns the strings.
Bot_Command_Entry :: struct {
	account:     proto.Account_Id,
	bot:         string, // the bot's username
	name:        string,
	description: string,
	usage:       string,
}

Bot_Commands_Client :: struct {
	// Sorted by name, then bot.
	entries: [dynamic]Bot_Command_Entry,
}

// Run the command in `line`, such as "/roll 2d6" or "/dicebot:roll 2d6", of
// a bot, in a conversation: `conv`, or with `dm_to` the DM with that account,
// or if both are 0 the one being looked at. `thread_root` is a message of the
// thread to run it in.
Bot_Run_Command :: struct {
	line:        string, // owned by the command
	conv:        proto.Conv_Id,
	dm_to:       proto.Account_Id,
	thread_root: proto.Msg_Id,
	// Don't complain that no bot has the command (the caller says so).
	silent:      bool,
}

// bot_command_typed is how a command is typed to name its bot: "dicebot:roll".
bot_command_typed :: proc(e: Bot_Command_Entry, allocator := context.temp_allocator) -> string {
	return strings.concatenate({e.bot, ":", e.name}, allocator)
}

// bot_commands_lookup returns the commands that `word` (what was typed after
// the slash, up to the first space) means: those called that, in any case, or
// with "bot:" in front, only the bot's. The list is in `allocator`.
bot_commands_lookup :: proc(
	list: []Bot_Command_Entry,
	word: string,
	allocator := context.temp_allocator,
) -> []Bot_Command_Entry {
	out := make([dynamic]Bot_Command_Entry, allocator)
	bot, name := "", word
	if strings.contains_rune(word, ':') {
		// "bot:name"; a name without the bot's is nothing.
		bot, _, name = strings.partition(word, ":")
		if bot == "" {
			return out[:]
		}
	}
	for e in list {
		if strings.equal_fold(e.name, name) && (bot == "" || strings.equal_fold(e.bot, bot)) {
			append(&out, e)
		}
	}
	return out[:]
}

// bot_commands_scope returns the commands of `list` that can be run in a
// conversation whose possible bots are `only`: a DM has the one it is with,
// a group its members. With `limited` false, anyone could be there (a
// channel), and it is all of them.
bot_commands_scope :: proc(
	list: []Bot_Command_Entry,
	only: []proto.Account_Id,
	limited: bool,
	allocator := context.temp_allocator,
) -> []Bot_Command_Entry {
	if !limited {
		return slice.clone(list, allocator)
	}
	out := make([dynamic]Bot_Command_Entry, allocator)
	for e in list {
		if slice.contains(only, e.account) {
			append(&out, e)
		}
	}
	return out[:]
}

// bot_command_ambiguous says whether another bot in `list` has a command with
// the same name as `e`, so that it has to be typed with its bot's name.
bot_command_ambiguous :: proc(list: []Bot_Command_Entry, e: Bot_Command_Entry) -> bool {
	for other in list {
		if other.account != e.account && strings.equal_fold(other.name, e.name) {
			return true
		}
	}
	return false
}

// command_line_split cuts "/roll 2d6" into "roll" and "2d6". The word is
// lower-case. It is false for a line that is not a command.
command_line_split :: proc(line: string) -> (word, args: string, ok: bool) {
	text := strings.trim_space(line)
	if !strings.has_prefix(text, "/") || len(text) < 2 {
		return
	}
	word = text[1:]
	if i := strings.index_any(word, " \t\n"); i >= 0 {
		word, args = word[:i], strings.trim_space(word[i:])
	}
	return strings.to_lower(word, context.temp_allocator), args, true
}

// view_bot_commands returns the commands that could be run in `conv`: those
// of the bots a DM or a group could have, or all of them in a channel. Call
// with the View locked. The list is in `allocator`.
view_bot_commands :: proc(
	v: ^View,
	conv: proto.Conv_Id,
	allocator := context.temp_allocator,
) -> []Bot_Command_Entry {
	for &dm in v.dms {
		if dm.id != conv {
			continue
		}
		if dm.with != 0 {
			return bot_commands_scope(v.bot_commands[:], {dm.with}, true, allocator)
		}
		return bot_commands_scope(v.bot_commands[:], group_members(&dm), true, allocator)
	}
	return bot_commands_scope(v.bot_commands[:], nil, false, allocator)
}

bot_commands_destroy :: proc(c: ^Server_Conn) {
	entries_free(c.bot_commands.entries[:])
	delete(c.bot_commands.entries)
}

@(private = "file")
entries_free :: proc(list: []Bot_Command_Entry) {
	for e in list {
		delete(e.bot)
		delete(e.name)
		delete(e.description)
		delete(e.usage)
	}
}

// bot_commands_begin forgets the commands, because the login sync is about to
// tell us all of them again.
bot_commands_begin :: proc(c: ^Server_Conn) {
	entries_free(c.bot_commands.entries[:])
	clear(&c.bot_commands.entries)
	publish_bot_commands(c)
}

// bot_commands_event handles an event about bots' commands. It returns false
// if `op` isn't one.
bot_commands_event :: proc(c: ^Server_Conn, op: proto.Event_Op, body: []u8) -> bool {
	#partial switch op {
	case .Commands_Changed:
		account, list, ok := proto.decode_bot_commands(body, true)
		if !ok {
			return true
		}
		entries := &c.bot_commands.entries
		for i := len(entries) - 1; i >= 0; i -= 1 {
			if entries[i].account == account {
				entries_free(entries[i:i + 1])
				ordered_remove(entries, i)
			}
		}
		bot := ""
		if acc, known := c.auth.accounts[account]; known {
			bot = acc.username
		}
		for cmd in list {
			append(
				entries,
				Bot_Command_Entry {
					account = account,
					bot = strings.clone(bot),
					name = strings.clone(cmd.name),
					description = strings.clone(cmd.description),
					usage = strings.clone(cmd.usage),
				},
			)
		}
		slice.stable_sort_by(entries[:], proc(a, b: Bot_Command_Entry) -> bool {
			if a.name != b.name {
				return a.name < b.name
			}
			return a.bot < b.bot
		})
		publish_bot_commands(c)
	case .Command_Invoked:
	// Only bots are sent this, and the clients of people never are.
	case:
		return false
	}
	return true
}

@(private = "file")
publish_bot_commands :: proc(c: ^Server_Conn) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	view_clear_bot_commands(v)
	for e in c.bot_commands.entries {
		append(
			&v.bot_commands,
			Bot_Command_Entry {
				account = e.account,
				bot = strings.clone(e.bot),
				name = strings.clone(e.name),
				description = strings.clone(e.description),
				usage = strings.clone(e.usage),
			},
		)
	}
}

// Call with the mutex held.
view_clear_bot_commands :: proc(v: ^View) {
	entries_free(v.bot_commands[:])
	clear(&v.bot_commands)
}

// bot_run carries out a Bot_Run_Command.
bot_run :: proc(c: ^Server_Conn, cmd: Bot_Run_Command) {
	word, args, ok := command_line_split(cmd.line)
	if !ok {
		return
	}
	conv := cmd.conv
	switch {
	case cmd.dm_to != 0:
		conv = dm_with(c, cmd.dm_to)
	case conv == 0:
		conv = c.convs.viewing
	}
	if conv == 0 {
		notify(c, false, "Send a message first to open this conversation, then run the command.")
		return
	}
	list := c.bot_commands.entries[:]
	if info, known := c.convs.convs[conv]; known {
		#partial switch info.kind {
		case .DM:
			list = bot_commands_scope(list, {dm_other(c, info)}, true)
		case .Group:
			list = bot_commands_scope(list, group_others(c, info), true)
		}
	}
	found := bot_commands_lookup(list, word)
	switch {
	case len(found) == 0:
		if !cmd.silent {
			notify(c, false, fmt.tprintf("There is no command /%s here.", word))
		}
		return
	case len(found) > 1:
		notify(
			c,
			false,
			fmt.tprintf("Several bots have /%s: use /%s.", word, bot_command_typed(found[0])),
		)
		return
	}
	buf: [proto.COMMAND_RUN_MAX_SIZE]u8
	body := proto.encode_command_run(
		buf[:],
		{
			conv = conv,
			thread_root = cmd.thread_root,
			account = found[0].account,
			name = found[0].name,
			args = args[:min(len(args), proto.MAX_COMMAND_ARGS)],
		},
	)
	if body == nil {
		return
	}
	request(
		c,
		.Command_Run,
		body,
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			#partial switch status {
			case .Ok, .Reset:
			case .Denied:
				notify(
					c,
					false,
					"You can't run that here: the bot isn't in this conversation, or you can't post in it.",
				)
			case .Not_Found:
				notify(c, false, "That command isn't available any more.")
			case .Rate_Limited:
				notify(c, false, "You are running commands too fast. Wait a moment.")
			case .Invalid:
				notify(c, false, "The server refused that command.")
			case:
				notify(c, false, "The command could not be run.")
			}
		},
	)
}

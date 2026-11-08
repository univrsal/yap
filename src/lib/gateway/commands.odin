package gateway

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"

import "common:proto"
import "lib:lite"

// Slash commands of bots (docs/design/bot-commands.md). The server keeps a
// bot's commands for as long as one of its connections is there, and sends
// them as Commands_Changed, which the model keeps. A bot sets its own with
// PUT /commands (every time it connects, since they go when it does), and is
// told when someone runs one with a COMMAND event.

// Command_JSON is one command.
Command_JSON :: struct {
	name:        string,
	description: string,
	usage:       string, // a hint for the arguments, like "<city> [days]"
}

// Bot_Commands_JSON is the commands of one bot.
Bot_Commands_JSON :: struct {
	bot:      Author_JSON,
	commands: []Command_JSON,
}

// Command_Event_JSON is the data of a COMMAND event: someone ran a command of
// the bot that is listening.
Command_Event_JSON :: struct {
	id:      string, // unique on the server
	conv_id: string,
	thread:  Maybe(string), // the id of the thread's root message, to answer in it
	name:    string,
	args:    string, // what was typed after the name
	user:    Author_JSON, // who ran it
}

// model_commands stores the commands in a Commands_Changed. An empty list
// means the bot has none (any more).
@(private)
model_commands :: proc(m: ^Model, body: []u8) {
	account, list, ok := proto.decode_bot_commands(body, true)
	if !ok {
		return
	}
	if old, had := m.commands[account]; had {
		commands_free(old)
		delete_key(&m.commands, account)
	}
	if len(list) == 0 {
		return
	}
	owned := make([]proto.Bot_Command, len(list))
	for c, i in list {
		owned[i] = {strings.clone(c.name), strings.clone(c.description), strings.clone(c.usage)}
	}
	m.commands[account] = owned
}

@(private)
commands_free :: proc(list: []proto.Bot_Command) {
	for c in list {
		delete(c.name)
		delete(c.description)
		delete(c.usage)
	}
	delete(list)
}

@(private)
commands_clear :: proc(m: ^Model) {
	for _, list in m.commands {
		commands_free(list)
	}
	clear(&m.commands)
}

// bot_commands_json returns one bot's commands.
@(private)
bot_commands_json :: proc(m: ^Model, account: proto.Account_Id) -> Bot_Commands_JSON {
	list := m.commands[account] or_else nil
	j := Bot_Commands_JSON {
		bot      = author_json(m, account),
		commands = make([]Command_JSON, len(list), context.temp_allocator),
	}
	for c, i in list {
		j.commands[i] = {c.name, c.description, c.usage}
	}
	return j
}

// all_commands_json returns the commands of every bot that has some, by bot.
@(private)
all_commands_json :: proc(m: ^Model) -> []Bot_Commands_JSON {
	ids, _ := slice.map_keys(m.commands, context.temp_allocator)
	slice.sort(ids)
	out := make([]Bot_Commands_JSON, len(ids), context.temp_allocator)
	for id, i in ids {
		out[i] = bot_commands_json(m, id)
	}
	return out
}

// events_commands turns Commands_Changed and Command_Invoked into events.
@(private)
events_commands :: proc(c: ^Conn, op: proto.Event_Op, body: []u8) {
	#partial switch op {
	case .Commands_Changed:
		if account, _, ok := proto.decode_bot_commands(body, true); ok {
			emit(c, "COMMANDS_UPDATE", bot_commands_json(&c.model, account))
		}
	case .Command_Invoked:
		ev, ok := proto.decode_command_invoked(body)
		if !ok {
			return
		}
		j := Command_Event_JSON {
			id      = id_string(ev.id),
			conv_id = id_string(ev.conv),
			name    = ev.name,
			args    = ev.args,
			user    = author_json(&c.model, ev.invoker),
		}
		if ev.thread_root != 0 {
			j.thread = id_string(ev.thread_root)
		}
		emit(c, "COMMAND", j)
	}
}

// GET /commands returns the commands of every bot that has some.
@(private)
commands_run :: proc(c: ^Conn, j: ^Job) {
	reply(j, json_reply(200, all_commands_json(&c.model)))
}

// PUT /commands replaces the commands of the token's bot with the ones in the
// body, a list of {name, description, usage}, and returns them. Only a bot
// account may. The commands stay until the bot's connection closes, so a bot
// sets them again whenever it connects.
@(private)
commands_set_run :: proc(c: ^Conn, j: ^Job) {
	v: json.Value
	err: json.Error
	if proto.json_nesting_ok(j.body) {
		v, err = json.parse(j.body, allocator = context.temp_allocator)
	} else {
		err = .Unexpected_Token
	}
	items, is_list := v.(json.Array)
	if err != nil || !is_list {
		reply(
			j,
			error_reply(
				400,
				"invalid",
				`The request body must be a JSON list like [{"name": "roll", "description": "Roll dice"}].`,
			),
		)
		return
	}
	if len(items) > proto.MAX_BOT_COMMANDS {
		reply(
			j,
			error_reply(
				400,
				"invalid",
				fmt.tprintf("A bot can have at most %d commands.", proto.MAX_BOT_COMMANDS),
			),
		)
		return
	}
	list := make([]proto.Bot_Command, len(items), context.temp_allocator)
	for item, i in items {
		obj, is_object := item.(json.Object)
		if !is_object {
			reply(j, error_reply(400, "invalid", "Every command must be an object."))
			return
		}
		name, name_got, name_ok := field_string(j, obj, "name")
		if !name_ok {
			return
		}
		description, _, description_ok := field_string(j, obj, "description")
		if !description_ok {
			return
		}
		usage, _, usage_ok := field_string(j, obj, "usage")
		if !usage_ok {
			return
		}
		if name_got != .Value || !proto.command_name_valid(name) {
			reply(
				j,
				error_reply(
					400,
					"invalid",
					fmt.tprintf(
						"A command's name is 1 to %d letters a-z in lower case, digits, - or _.",
						proto.MAX_COMMAND_NAME,
					),
				),
			)
			return
		}
		for other in list[:i] {
			if other.name == name {
				reply(
					j,
					error_reply(
						400,
						"invalid",
						fmt.tprintf("There are two commands called %q.", name),
					),
				)
				return
			}
		}
		// Text for everyone to read, so it is cleaned, and cut if it is long.
		description_buf := make([]u8, proto.MAX_COMMAND_DESCRIPTION, context.temp_allocator)
		usage_buf := make([]u8, proto.MAX_COMMAND_USAGE, context.temp_allocator)
		list[i] = {
			name        = name,
			description = proto.sanitize_text(description, description_buf),
			usage       = proto.sanitize_text(usage, usage_buf),
		}
	}
	buf: [proto.BOT_COMMANDS_MAX_SIZE]u8
	body := proto.encode_bot_commands(buf[:], list)
	if body == nil {
		reply(j, error_reply(400, "invalid", "The commands could not be sent."))
		return
	}
	j.answer = proc(c: ^Conn, j: ^Job, a: lite.Answer) {
		if a.status != .Ok {
			reply(j, status_reply(a.status))
			return
		}
		after_events(c, j, proc(c: ^Conn, j: ^Job) {
			reply(j, json_reply(200, bot_commands_json(&c.model, c.model.self)))
		})
	}
	ask(c, j, .Bot_Commands_Set, body)
}

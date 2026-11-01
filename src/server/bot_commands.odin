package server

import "core:slice"
import "core:strings"

import "common:proto"

// Slash commands of bots (src/common/proto/bot_commands.odin,
// docs/design/bot-commands.md). A bot registers its commands with
// Bot_Commands_Set, which replaces the set it had. The server keeps the set
// with the connection that sent it, in memory only: when the connection goes
// away so does its set, and clients are told. An account with several
// connections has the set that was registered last by one that is still
// there.
//
// Clients are told with Commands_Changed to everyone, and in the login sync
// (directory.odin) for each bot that has commands.

// bot_commands_set handles Bot_Commands_Set.
bot_commands_set :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	if .Bot not_in u.account.flags {
		respond(u, id, .Denied)
		return
	}
	_, list, ok := proto.decode_bot_commands(body)
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	bot_commands_free(u)
	u.commands = make([]proto.Bot_Command, len(list))
	for c, i in list {
		u.commands[i] = {
			name        = strings.clone(c.name),
			description = strings.clone(c.description),
			usage       = strings.clone(c.usage),
		}
	}
	s.commands_seq += 1
	u.commands_seq = s.commands_seq
	respond(u, id, .Ok)
	bot_commands_told(s, u.account)
}

// bot_commands_free forgets the commands a connection registered.
bot_commands_free :: proc(u: ^Conn) {
	for c in u.commands {
		delete(c.name)
		delete(c.description)
		delete(c.usage)
	}
	delete(u.commands)
	u.commands, u.commands_seq = nil, 0
}

// bot_commands_conn_gone ends the commands of a connection that is no longer
// one of `acc`'s, and tells everyone if it had any.
bot_commands_conn_gone :: proc(s: ^Server, u: ^Conn, acc: ^Account) {
	had := u.commands_seq != 0
	bot_commands_free(u)
	if had {
		bot_commands_told(s, acc)
	}
}

// bot_commands_of returns the commands that count for an account: those of
// its connection that registered last. It is nil if none did.
bot_commands_of :: proc(acc: ^Account) -> []proto.Bot_Command {
	best: ^Conn
	for u in acc.conns {
		if u.commands_seq != 0 && (best == nil || u.commands_seq > best.commands_seq) {
			best = u
		}
	}
	return best.commands if best != nil else nil
}

@(private = "file")
send_commands_changed :: proc(u: ^Conn, acc: ^Account) {
	buf: [proto.COMMANDS_CHANGED_MAX_SIZE]u8
	body := proto.encode_bot_commands(buf[:], bot_commands_of(acc), acc.id)
	if body != nil {
		send_event(u, .Commands_Changed, body)
	}
}

// bot_commands_told tells everyone who is logged in what an account's
// commands are now (none, if it has none).
@(private = "file")
bot_commands_told :: proc(s: ^Server, acc: ^Account) {
	for _, u in s.conns {
		send_commands_changed(u, acc)
	}
}

// send_bot_commands tells a connection that just logged in about the commands
// of every bot that has some.
send_bot_commands :: proc(s: ^Server, u: ^Conn) {
	ids, _ := slice.map_keys(s.accounts.by_id, context.temp_allocator)
	slice.sort(ids)
	for id in ids {
		acc := s.accounts.by_id[id]
		if len(bot_commands_of(acc)) > 0 {
			send_commands_changed(u, acc)
		}
	}
}

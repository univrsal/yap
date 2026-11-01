package server

import "core:slice"
import "core:strings"
import "core:time"

import "common:proto"

// Slash commands of bots (src/common/proto/bot_commands.odin,
// docs/design/bot-commands.md). A bot registers its commands with
// Bot_Commands_Set, which replaces the set it had. The server keeps the set
// with the connection that sent it, in memory only: when the connection goes
// away so does its set, and clients are told. An account with several
// connections has the set that was registered last by one that is still
// there.
//
// Running a command (Command_Run) is checked here too, and reaches the
// connection whose set counts, so that two processes of a bot don't both
// answer.
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

// bot_commands_conn returns the connection whose commands count for an
// account: the one that registered last. It is nil if none did.
bot_commands_conn :: proc(acc: ^Account) -> ^Conn {
	best: ^Conn
	for u in acc.conns {
		if u.commands_seq != 0 && (best == nil || u.commands_seq > best.commands_seq) {
			best = u
		}
	}
	return best
}

// bot_commands_of returns the commands that count for an account, or nil.
bot_commands_of :: proc(acc: ^Account) -> []proto.Bot_Command {
	if u := bot_commands_conn(acc); u != nil {
		return u.commands
	}
	return nil
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

// Each connection may run COMMAND_BURST commands at once, then COMMAND_RATE a
// second. Beyond that the answer is Rate_Limited.
COMMAND_BURST :: 10
COMMAND_RATE :: 2

// command_run handles Command_Run. The checks are in this order, so that the
// answer says nothing about a conversation the invoker can't see:
//
//  1. the invoker may post in the conversation (Not_Found if it can't see
//     it, Denied if it isn't a member or can't write there),
//  2. the thread, if any, is a thread of it (Invalid),
//  3. the bot has such a command (Not_Found), which includes a bot that has
//     left,
//  4. the bot is a member of the conversation and may see it and write there
//     (Denied), since otherwise it could not answer.
command_run :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	req, ok := proto.decode_command_run(body)
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	proto.bucket_refill(&u.command_runs, time.tick_now(), COMMAND_RATE, COMMAND_BURST)
	if !proto.bucket_take(&u.command_runs, 1) {
		respond(u, id, .Rate_Limited)
		return
	}
	conv, status := conv_of_member(s, u, req.conv)
	if conv == nil {
		respond(u, id, status)
		return
	}
	if dm_closed(s, conv) || .Write not_in conv_rights(conv, u.account) {
		respond(u, id, .Denied)
		return
	}
	root, root_ok := thread_root_of(s, conv, req.thread_root)
	if !root_ok {
		respond(u, id, .Invalid)
		return
	}
	bot := account_live(&s.accounts, req.account)
	target := bot_commands_conn(bot) if bot != nil && .Bot in bot.flags else nil
	found := false
	if target != nil {
		for c in target.commands {
			found ||= c.name == req.name
		}
	}
	if !found {
		respond(u, id, .Not_Found)
		return
	}
	if !conv_reader(conv, bot) || .Write not_in conv_rights(conv, bot) {
		respond(u, id, .Denied)
		return
	}
	s.invocations += 1
	buf: [proto.COMMAND_INVOKED_MAX_SIZE]u8
	event := proto.encode_command_invoked(
		buf[:],
		{
			id = s.invocations,
			conv = conv.id,
			thread_root = root.id,
			invoker = u.account.id,
			name = req.name,
			args = strings.trim_space(req.args),
		},
	)
	if event == nil {
		respond(u, id, .Internal)
		return
	}
	send_event(target, .Command_Invoked, event)
	respond(u, id, .Ok)
}

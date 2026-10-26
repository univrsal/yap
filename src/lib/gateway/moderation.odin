package gateway

import "common:proto"
import "lib:lite"

// Moderation (docs/design/moderation.md) for bots whose roles hold the
// permissions: moving someone's voice to another channel's room or out of
// voice (Move_Members), muting them for everyone (Mute_Members), and banning
// them, perhaps removing their messages in channels, or lifting a ban
// (Ban_Members). The bot needn't be in voice itself. The server checks
// everything, including that the bot outranks them.

// PUT /accounts/{id}/voice {conv} -> 204 moves the account's voice to that
// channel's room. DELETE /accounts/{id}/voice -> 204 takes it out of voice.
@(private)
voice_move_run :: proc(c: ^Conn, j: ^Job) {
	account, ok := param_id(j, 0)
	if !ok {
		reply(j, bad_id(j.params[0]))
		return
	}
	obj, body_ok := body_object(j)
	if !body_ok {
		return
	}
	conv, conv_ok := field_id(j, obj, "conv")
	if !conv_ok {
		return
	}
	if conv == 0 {
		reply(
			j,
			error_reply(400, "invalid", "conv is required and is the channel to move them to."),
		)
		return
	}
	voice_move(c, j, account, proto.Room(conv))
}

@(private)
voice_kick_run :: proc(c: ^Conn, j: ^Job) {
	account, ok := param_id(j, 0)
	if !ok {
		reply(j, bad_id(j.params[0]))
		return
	}
	voice_move(c, j, account, 0)
}

@(private)
voice_move :: proc(c: ^Conn, j: ^Job, account: u64, room: proto.Room) {
	j.answer = answered_empty
	buf: [proto.VOICE_MOVE_SIZE]u8
	ask(c, j, .Voice_Move, proto.encode_voice_move(&buf, proto.Account_Id(account), room))
}

// PUT and DELETE /accounts/{id}/mute -> 204 mutes the account for everyone on
// the server, or lifts that. The account's server_muted says which.
@(private)
mute_run :: proc(c: ^Conn, j: ^Job) {
	mute(c, j, true)
}

@(private)
unmute_run :: proc(c: ^Conn, j: ^Job) {
	mute(c, j, false)
}

@(private)
mute :: proc(c: ^Conn, j: ^Job, on: bool) {
	account, ok := param_id(j, 0)
	if !ok {
		reply(j, bad_id(j.params[0]))
		return
	}
	j.answer = answered_empty
	buf: [proto.VOICE_MUTE_SIZE]u8
	ask(c, j, .Voice_Mute, proto.encode_voice_mute(&buf, proto.Account_Id(account), on))
}

// PUT /accounts/{id}/ban {reason, purge} -> 204 bans the account: it is
// logged out and told the reason. `purge` (none, hour, day, week or all;
// none if left out) also removes its messages in channels from that long
// ago on. DELETE /accounts/{id}/ban -> 204 lifts the ban.
@(private)
ban_run :: proc(c: ^Conn, j: ^Job) {
	account, ok := param_id(j, 0)
	if !ok {
		reply(j, bad_id(j.params[0]))
		return
	}
	obj, body_ok := body_object(j)
	if !body_ok {
		return
	}
	reason, _, reason_ok := field_string(j, obj, "reason")
	if !reason_ok {
		return
	}
	if len(reason) > proto.MAX_BAN_REASON {
		reply(j, error_reply(400, "invalid", "The reason is too long."))
		return
	}
	purge_name, got, purge_ok := field_string(j, obj, "purge")
	if !purge_ok {
		return
	}
	purge := proto.Ban_Purge.None
	if got == .Value {
		known := false
		for p in proto.Ban_Purge {
			if enum_name(p) == purge_name {
				purge, known = p, true
			}
		}
		if !known {
			reply(
				j,
				error_reply(400, "invalid", "purge must be one of none, hour, day, week or all."),
			)
			return
		}
	}
	ban_set(c, j, {account = proto.Account_Id(account), on = true, reason = reason, purge = purge})
}

@(private)
unban_run :: proc(c: ^Conn, j: ^Job) {
	account, ok := param_id(j, 0)
	if !ok {
		reply(j, bad_id(j.params[0]))
		return
	}
	ban_set(c, j, {account = proto.Account_Id(account)})
}

@(private)
ban_set :: proc(c: ^Conn, j: ^Job, b: proto.Ban_Set) {
	j.answer = answered_empty
	buf: [proto.BAN_SET_MAX_SIZE]u8
	ask(c, j, .Ban_Set, proto.encode_ban_set(&buf, b))
}

Ban_JSON :: struct {
	account: Author_JSON,
	by:      Author_JSON,
	time:    string,
	reason:  string,
}

// GET /bans -> [ban] lists the banned accounts, newest first: who, who
// banned them, when and why.
@(private)
bans_run :: proc(c: ^Conn, j: ^Job) {
	j.answer = proc(c: ^Conn, j: ^Job, a: lite.Answer) {
		if a.status != .Ok {
			reply(j, status_reply(a.status))
			return
		}
		bans, ok := proto.decode_bans(a.body)
		if !ok {
			reply(j, status_reply(.Internal))
			return
		}
		out := make([]Ban_JSON, len(bans), context.temp_allocator)
		for b, i in bans {
			out[i] = {
				account = author_json(&c.model, b.account),
				by      = author_json(&c.model, b.by),
				time    = iso_time(b.time),
				reason  = b.reason,
			}
		}
		reply(j, json_reply(200, out))
	}
	ask(c, j, .Ban_List)
}

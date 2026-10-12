package server

import "core:log"

import "common:proto"

/*
Bot accounts and their tokens (src/common/proto/bots.odin). A bot is an
account with the Bot flag and no password; its tokens are devices whose
keys the admin's client made. Once made, a bot logs in as any known
device does (auth_known_device), and what it may do is its roles'.

What it's kept from is elsewhere, where each thing is: logging in with a
password and changing one (auth.odin), voice rooms (conv_requests.odin),
calls (calls.odin) and digests (digest.odin).
*/

// bot_request handles a request about bots; false if `op` isn't one.
bot_request :: proc(s: ^Server, u: ^Conn, id: u32, op: proto.Request_Op, body: []u8) -> bool {
	#partial switch op {
	case .Bot_Create:
		bot_create(s, u, id, body)
	case .Bot_Token_Add:
		bot_token_add(s, u, id, body)
	case:
		return false
	}
	return true
}

@(private = "file")
bot_create :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	raw_username, raw_display, key, raw_device, ok := proto.decode_bot_create(body)
	name_buf: [proto.MAX_USERNAME_SIZE]u8
	username, clean := proto.username_clean(raw_username, &name_buf)
	switch {
	case !can(u.account, .Manage_Accounts):
		respond(u, id, .Denied)
		return
	case !ok || !clean || key == {}:
		respond(u, id, .Invalid)
		return
	case account_find(&s.accounts, username) != nil, device_of(&s.accounts, key) != nil:
		respond(u, id, .Conflict)
		return
	}
	display_buf: [proto.MAX_NAME_SIZE]u8
	display := proto.sanitize_name(raw_display, &display_buf)
	// No password: a hash of nothing that nothing is checked against
	// (login in auth.odin never looks at a bot's).
	acc := account_add(&s.accounts, username, display if display != "" else username, {}, {.Bot})
	if acc == nil || !conv_member_add(&s.convs, s.convs.home, acc.id) {
		respond(u, id, .Internal)
		return
	}
	if device_link(&s.accounts, key, acc, bot_device_name(raw_device), "") == nil {
		respond(u, id, .Internal)
		return
	}
	log.infof("%s made the bot %s", conn_label(u), acc.username)
	buf: [4]u8
	respond(u, id, .Ok, proto.encode_account_id(&buf, acc.id))
	account_changed(s, acc)
}

@(private = "file")
bot_token_add :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	target_id, key, raw_device, ok := proto.decode_bot_token_add(body)
	target := account_live(&s.accounts, target_id)
	switch {
	case !can(u.account, .Manage_Accounts):
		respond(u, id, .Denied)
		return
	case !ok || key == {}:
		respond(u, id, .Invalid)
		return
	case target == nil || .Bot not_in target.flags:
		respond(u, id, .Not_Found)
		return
	case !outranks(u.account, permissions(target)):
		// Nor a bot that may do more than the asker (roles.odin).
		respond(u, id, .Denied)
		return
	case device_of(&s.accounts, key) != nil:
		respond(u, id, .Conflict)
		return
	}
	name := bot_device_name(raw_device)
	if device_link(&s.accounts, key, target, name, "") == nil {
		respond(u, id, .Internal)
		return
	}
	log.infof("%s made a token %q for the bot %s", conn_label(u), name, target.username)
	respond(u, id, .Ok)
}

// bot_device_name is what a token's device is called: as asked,
// sanitized, or BOT_DEVICE_NAME. In the temp allocator.
@(private = "file")
bot_device_name :: proc(raw: string) -> string {
	buf := make([]u8, proto.MAX_DEVICE_NAME, context.temp_allocator)
	name := proto.sanitize_text(raw, buf)
	return name if name != "" else proto.BOT_DEVICE_NAME
}

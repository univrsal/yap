package conn

import log "common:wlog"
import "core:strings"

import "common:proto"

// Bot accounts (src/common/proto/bots.odin) can be managed by users who manage
// accounts: they can create a bot and create more tokens for it. A token is
// generated here and only its public half is sent to the server. The token itself
// is handed to the UI once (View.bot_token) so it can be copied, and is
// forgotten afterwards. A bot's tokens are listed and revoked like devices
// (see auth.odin), together with the bot's account.

// Creates a bot and a first token for it.
Bot_Create_Command :: struct {
	username: string, // owned by the command
	display:  string, // owned by the command
}
// Creates another token for a bot.
Bot_Token_Command :: struct {
	account: proto.Account_Id,
}
// The shown token has been copied or is no longer needed, so forget it.
Bot_Token_Forget_Command :: struct {}

// The device name shown in the bot's device list for a token.
BOT_TOKEN_DEVICE :: "API token"

auth_bot_create :: proc(c: ^Server_Conn, cmd: Bot_Create_Command) {
	name_buf: [proto.MAX_USERNAME_SIZE]u8
	username, clean := proto.username_clean(cmd.username, &name_buf)
	if !clean {
		notify(c, false, username_rule())
		return
	}
	public, made := new_token(c)
	if !made {
		return
	}
	buf: [proto.BOT_BODY_MAX]u8
	request(
		c,
		.Bot_Create,
		proto.encode_bot_create(buf[:], username, cmd.display, public, BOT_TOKEN_DEVICE),
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			account, ok := proto.decode_account_id(body)
			if status != .Ok || !ok {
				bot_token_wipe(c)
				notify(c, false, status_text(status, "account"))
				return
			}
			publish_bot_token(c, account)
			notify(c, true, "Bot created. Copy its token now, because it will not be shown again.")
		},
	)
}

auth_bot_token :: proc(c: ^Server_Conn, account: proto.Account_Id) {
	public, made := new_token(c)
	if !made {
		return
	}
	buf: [proto.BOT_BODY_MAX]u8
	request(
		c,
		.Bot_Token_Add,
		proto.encode_bot_token_add(buf[:], account, public, BOT_TOKEN_DEVICE),
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			if status != .Ok {
				bot_token_wipe(c)
				notify(c, false, status_text(status, "account"))
				return
			}
			publish_bot_token(c, proto.Account_Id(tag))
			notify(c, true, "Token created. Copy it now, because it will not be shown again.")
			auth_devices(c, proto.Account_Id(tag))
		},
		u64(account),
	)
}

auth_bot_token_forget :: proc(c: ^Server_Conn) {
	bot_token_wipe(c)
	if v := c.view; v != nil {
		view_write(v)
		view_forget_bot_token(v)
	}
}

// new_token creates a token and keeps it until the server has accepted its
// public half. Only one token is kept at a time, so a new one replaces the old.
@(private = "file")
new_token :: proc(c: ^Server_Conn) -> (public: [proto.KEY_SIZE]u8, ok: bool) {
	bot_token_wipe(c)
	c.auth.bot_token, public, ok = proto.bot_token_make()
	if !ok {
		notify(c, false, "Failed to generate a token.")
	}
	return
}

// bot_token_wipe forgets a token that is waiting for the server's answer.
bot_token_wipe :: proc(c: ^Server_Conn) {
	wipe_string(c.auth.bot_token)
	delete(c.auth.bot_token)
	c.auth.bot_token = ""
}

// publish_bot_token hands the token the server just accepted to the UI so it
// can be shown once. Without a UI it is written to the log, which is where the
// command line client shows output.
@(private = "file")
publish_bot_token :: proc(c: ^Server_Conn, account: proto.Account_Id) {
	defer bot_token_wipe(c)
	v := c.view
	if v == nil {
		log.infof("the token for account %d (shown this once): %s", account, c.auth.bot_token)
		return
	}
	view_write(v)
	view_forget_bot_token(v)
	v.bot_token = strings.clone(c.auth.bot_token)
	v.bot_token_account = account
	v.bot_token_count += 1
}

// publish_other_devices hands the devices of another account to the UI.
publish_other_devices :: proc(
	c: ^Server_Conn,
	account: proto.Account_Id,
	devices: []proto.Device,
) {
	v := c.view
	if v == nil {
		for d in devices {
			log.infof(
				"device %s %q of account %d%s",
				fingerprint(d.key),
				d.name,
				account,
				" online" if .Online in d.flags else "",
			)
		}
		return
	}
	view_write(v)
	view_clear_other_devices(v)
	v.other_devices_of = account
	for d in devices {
		append(
			&v.other_devices,
			Dir_Device {
				key = d.key,
				name = strings.clone(d.name),
				agent = strings.clone(d.agent),
				created = d.created,
				last_seen = d.last_seen,
				flags = d.flags,
			},
		)
	}
	v.other_devices_count += 1
}

// Call with the mutex held.
view_forget_bot_token :: proc(v: ^View) {
	wipe_string(v.bot_token)
	delete(v.bot_token)
	v.bot_token, v.bot_token_account = "", 0
}

// wipe_string overwrites the contents of a string we own with zeros so a
// secret is not left behind in freed memory.
@(private = "file")
wipe_string :: proc(s: string) {
	raw := transmute([]u8)s
	for &b in raw {
		b = 0
	}
}

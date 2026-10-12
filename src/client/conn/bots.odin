package conn

import log "common:wlog"
import "core:fmt"
import "core:strings"

import "common:proto"

/*
Bot accounts (src/common/proto/bots.odin), for who manages accounts:
making one, and more tokens for one. A token is made here, and only its
public half goes to the server; the token itself is handed to the UI
once (View.bot_token) to be copied, and forgotten when it's done with.
A bot's tokens are listed and revoked as devices are (auth.odin), with
the bot's account.
*/

// Make a bot, and a first token for it.
Bot_Create_Command :: struct {
	username: string, // owned by the command
	display:  string, // owned by the command
}
// Make another token for a bot.
Bot_Token_Command :: struct {
	account: proto.Account_Id,
}
// The token shown has been copied, or wasn't wanted: forget it.
Bot_Token_Forget_Command :: struct {}

// What the device a token is made for is called in the bot's list.
BOT_TOKEN_DEVICE :: "API token"

auth_bot_create :: proc(c: ^Voice_Client, cmd: Bot_Create_Command) {
	name_buf: [proto.MAX_USERNAME_SIZE]u8
	username, clean := proto.username_clean(cmd.username, &name_buf)
	if !clean {
		notify(
			c,
			false,
			fmt.tprintf(
				"A username is %d to %d of a-z, 0-9, _ . and -",
				proto.MIN_USERNAME_SIZE,
				proto.MAX_USERNAME_SIZE,
			),
		)
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
		proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
			account, ok := proto.decode_account_id(body)
			if status != .Ok || !ok {
				bot_token_wipe(c)
				notify(c, false, status_text(status))
				return
			}
			publish_bot_token(c, account)
			notify(c, true, "Bot made. Copy its token: it isn't shown again.")
		},
	)
}

auth_bot_token :: proc(c: ^Voice_Client, account: proto.Account_Id) {
	public, made := new_token(c)
	if !made {
		return
	}
	buf: [proto.BOT_BODY_MAX]u8
	request(
		c,
		.Bot_Token_Add,
		proto.encode_bot_token_add(buf[:], account, public, BOT_TOKEN_DEVICE),
		proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
			if status != .Ok {
				bot_token_wipe(c)
				notify(c, false, status_text(status))
				return
			}
			publish_bot_token(c, proto.Account_Id(tag))
			notify(c, true, "Token made. Copy it: it isn't shown again.")
			auth_devices(c, proto.Account_Id(tag))
		},
		u64(account),
	)
}

auth_bot_token_forget :: proc(c: ^Voice_Client) {
	bot_token_wipe(c)
	if v := c.view; v != nil {
		view_write(v)
		view_forget_bot_token(v)
	}
}

// new_token makes a token, kept until the server has taken its public
// half; one at a time, so another replaces it.
@(private = "file")
new_token :: proc(c: ^Voice_Client) -> (public: [proto.KEY_SIZE]u8, ok: bool) {
	bot_token_wipe(c)
	c.auth.bot_token, public, ok = proto.bot_token_make()
	if !ok {
		notify(c, false, "No token could be made.")
	}
	return
}

// bot_token_wipe forgets a token on its way to the server.
bot_token_wipe :: proc(c: ^Voice_Client) {
	wipe_string(c.auth.bot_token)
	delete(c.auth.bot_token)
	c.auth.bot_token = ""
}

// publish_bot_token hands the token the server just took to the UI, to
// be shown once; without a UI it goes to the log, which is where the
// command line client shows things.
@(private = "file")
publish_bot_token :: proc(c: ^Voice_Client, account: proto.Account_Id) {
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

// publish_other_devices hands the UI another account's devices.
publish_other_devices :: proc(c: ^Voice_Client, account: proto.Account_Id, devices: []proto.Device) {
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

// wipe_string zeroes what a string we own holds, so a secret isn't left
// lying in freed memory.
@(private = "file")
wipe_string :: proc(s: string) {
	raw := transmute([]u8)s
	for &b in raw {
		b = 0
	}
}

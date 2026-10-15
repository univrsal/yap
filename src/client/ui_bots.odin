package client

import "core:fmt"
import mu "vendor:microui"

import "client:conn"
import "common:proto"

/*
Bot accounts (src/common/proto/bots.odin), in the settings' accounts
list for who manages accounts: a bot's tokens, a new one, and a token
just made, shown once to be copied (conn/bots.odin). Everyone sees a bot
for what it is by the small BOT tag after its name.
*/

BOT_TAG :: "BOT"

@(private = "file")
command :: proc(ui: ^UI, cmd: conn.Command) {
	if ui.session != nil {
		conn.push_command(&ui.session.client.commands, cmd)
	}
}

/*
bot_token_shown is the token just made, if there is one: whose it is,
the token, and buttons to copy it and to be done with it. Call with the
View locked, in the accounts list.
*/
bot_token_shown :: proc(ui: ^UI, v: ^conn.View) {
	if v.bot_token == "" {
		return
	}
	ctx := &ui.ctx
	whose := "the bot"
	if acc, ok := v.accounts[v.bot_token_account]; ok {
		whose = fmt.tprintf("@%s", acc.username)
	}
	mu.layout_row(ctx, {-1})
	with_text_color(
		ctx,
		theme.warning,
		fmt.tprintf(
			"The token for %s, shown this once: copy it now. Whoever has it can do all the bot may.",
			whose,
		),
		wrap_text,
	)
	mu.layout_row(ctx, {-(2 * 90 + 2 * ctx.style.spacing), 87, 87})
	mu.label(ctx, v.bot_token)
	if .SUBMIT in stable_button(ctx, "copy token", "Copy", {.ALIGN_CENTER}) {
		set_clipboard(nil, v.bot_token)
	}
	if .SUBMIT in stable_button(ctx, "token done", "Done", {.ALIGN_CENTER}) {
		command(ui, conn.Bot_Token_Forget_Command{})
	}
}

/*
bot_tokens is a bot's tokens, under its row once Tokens... was pressed:
each with when it was last used and a button to revoke it, and a button
for another. Call with the View locked.
*/
bot_tokens :: proc(ui: ^UI, v: ^conn.View, id: proto.Account_Id) {
	ctx := &ui.ctx
	if v.other_devices_of != id {
		mu.layout_row(ctx, {-1})
		with_text_color(ctx, theme.dim, "    Asking the server...", label_proc)
		return
	}
	if len(v.other_devices) == 0 {
		mu.layout_row(ctx, {-1})
		with_text_color(ctx, theme.dim, "    No tokens: it can't log in.", label_proc)
	}
	for d, i in v.other_devices {
		mu.push_id(ctx, uintptr(i))
		defer mu.pop_id(ctx)
		mu.layout_row(ctx, {-(90 + ctx.style.spacing), 87})
		seen := "connected"
		if .Online not_in d.flags {
			seen = "never used"
			// A device is seen when it's made, which for a token isn't
			// being used.
			if d.last_seen != 0 && d.last_seen != d.created {
				seen = fmt.tprintf("last used %s", ago_text(ui, i64(d.last_seen)))
			}
		}
		mu.label(ctx, fmt.tprintf("    %s  %s  -  %s", conn.fingerprint(d.key), d.name, seen))
		if .SUBMIT in stable_button(ctx, "revoke token", "Revoke", {.ALIGN_CENTER}) {
			ui.account.mistake = ""
			command(ui, conn.Revoke_Command{d.key})
		}
	}
	mu.layout_row(ctx, {-(90 + ctx.style.spacing), 87})
	with_text_color(
		ctx,
		theme.dim,
		"    A token is all a program needs to be the bot; revoking one logs it out.",
		wrap_text,
	)
	if .SUBMIT in stable_button(ctx, "new token", "New token", {.ALIGN_CENTER}) {
		ui.account.mistake = ""
		command(ui, conn.Bot_Token_Command{account = id})
	}
}

// bot_tag_width is how much room the BOT tag takes after a name, the
// gap before it included.
bot_tag_width :: proc(ctx: ^mu.Context) -> i32 {
	return 6 + ctx.text_width(ctx.style.font, BOT_TAG) + 8
}

/*
bot_tag draws the BOT tag at `x`, on a line of text whose top is `y`,
and returns the width it took (bot_tag_width), for whatever follows.
*/
bot_tag :: proc(ctx: ^mu.Context, x, y: i32) -> i32 {
	font := ctx.style.font
	w := bot_tag_width(ctx)
	h := ctx.text_height(font)
	mu.draw_rect(ctx, {x + 6, y + 1, w - 6, h - 2}, theme.muted_badge)
	mu.draw_text(ctx, font, BOT_TAG, {x + 6 + 4, y}, theme.badge_text)
	return w
}

// header_room is spaces at least `width` wide, in the temp allocator:
// where a tag is drawn over text that's drawn in one piece.
header_room :: proc(ctx: ^mu.Context, width: i32) -> string {
	space := max(ctx.text_width(ctx.style.font, " "), 1)
	n := int((width + space - 1) / space)
	room := make([]u8, n, context.temp_allocator)
	for &b in room {
		b = ' '
	}
	return string(room)
}

// is_bot is whether an account is a bot's. Call with the View locked.
is_bot :: proc(v: ^conn.View, account: proto.Account_Id) -> bool {
	acc, ok := v.accounts[account]
	return ok && .Bot in acc.flags
}

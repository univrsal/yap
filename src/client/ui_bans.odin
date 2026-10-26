package client

import "core:fmt"
import "core:strings"
import "core:time"
import mu "vendor:microui"

import "client:conn"
import "common:proto"

// Bans (conn/moderation.odin), for those with Ban_Members, and for whoever is
// banned:
//
//   - The user menu's Moderation part has Ban..., which opens a reason box,
//     which of their messages in channels go with them, and the Ban button
//     in the menu, or Unban for someone banned. With Permission.Purge it also
//     has Remove messages..., which removes theirs everywhere, of the last
//     hour, day or week or all of them.
//   - The settings' Bans page lists who is banned, by whom, when and why,
//     each with Unban. The Accounts page says "banned" instead of
//     "disabled" for them.
//   - A banned account's login screen says so, with the reason, instead of
//     the form, until it is closed (it comes back each time the server says
//     it again), with a way to take the server off the rail.

UI_Bans :: struct {
	asked:    bool, // the list was requested since the page was opened
	// The menu's ban form: open, the reason being typed, and which of their
	// messages go too.
	banning:  bool,
	reason:   Text_Field(proto.MAX_BAN_REASON),
	purge:    proto.Ban_Purge,
	// The menu's Remove messages... is open, and which of theirs go.
	removing: bool,
	remove:   proto.Ban_Purge,
	// The ban_count of the login screen's notice that was closed.
	closed:   int,
}

// ban_of returns an account's ban, as of the last list, and whether it has
// one. Call with the View locked.
ban_of :: proc(v: ^conn.View, account: proto.Account_Id) -> (proto.Ban, bool) {
	for b in v.bans.list {
		if b.account == account {
			return b, true
		}
	}
	return {}, false
}

// bans_opened is called when the Bans or Accounts page is opened.
bans_opened :: proc(ui: ^UI) {
	ui.bans.asked = false
}

// bans_ask asks for the list once after the page was opened, if we may see
// it. Call with the View locked.
bans_ask :: proc(ui: ^UI, v: ^conn.View) {
	if !ui.bans.asked && .Ban_Members in v.permissions {
		ui.bans.asked = true
		command(ui, conn.Bans_Command{})
	}
}

// ban_items is the end of the user menu's Moderation part (moderation_items):
// Ban..., which opens a reason box and the red Ban button under it, or Unban
// for someone who is banned. Returns whether the menu should close. Call with
// the View locked, inside the menu, with rows of `width`.
ban_items :: proc(ui: ^UI, account: proto.Account_Id, width: i32) -> (close: bool) {
	ctx := &ui.ctx
	v := ui.view
	b := &ui.bans
	if _, banned := ban_of(v, account); banned {
		if .SUBMIT in stable_button(ctx, "unban", "Unban") {
			command(ui, conn.Ban_Command{account = account, on = false})
			return true
		}
		return false
	}
	if .SUBMIT in stable_button(ctx, "ban?", "Ban..." if !b.banning else "Ban:") {
		b.banning = !b.banning
	}
	if !b.banning {
		return false
	}
	dim_label(ctx, "Reason (they will see it)")
	submit := .SUBMIT in text_box(ui, b.reason.buf[:], &b.reason.len)
	// Which of their messages in channels go too: a click picks the next.
	label := fmt.tprintf("Remove their messages: %s", PURGE_CHOICES[b.purge])
	if .SUBMIT in stable_button(ctx, "ban purge", label) {
		b.purge = proto.Ban_Purge((int(b.purge) + 1) % len(proto.Ban_Purge))
	}
	half := (width - ctx.style.spacing) / 2
	mu.layout_row(ctx, {half, half})
	if .SUBMIT in stable_button(ctx, "cancel ban", "Cancel") {
		b.banning = false
	}
	saved := ctx.style.colors[.TEXT]
	ctx.style.colors[.TEXT] = theme.error
	submit |= .SUBMIT in stable_button(ctx, "ban", "Ban")
	ctx.style.colors[.TEXT] = saved
	mu.layout_row(ctx, {width})
	if submit {
		command(
			ui,
			conn.Ban_Command {
				account = account,
				on = true,
				reason = strings.clone(field_text(&b.reason)),
				purge = b.purge,
			},
		)
		b.banning, b.reason.len, b.purge = false, 0, .None
		return true
	}
	return false
}

// How much of someone's messages go, as the menu says it.
@(private = "file")
PURGE_CHOICES := [proto.Ban_Purge]string {
	.None = "none",
	.Hour = "last hour",
	.Day  = "last 24 hours",
	.Week = "last 7 days",
	.All  = "all",
}

// remove_items is the menu's Remove messages... (Permission.Purge): which of
// their messages go, everywhere, and a red Remove. Returns whether the menu
// should close. Call with the View locked, inside the menu, with rows of
// `width`.
remove_items :: proc(ui: ^UI, account: proto.Account_Id, width: i32) -> (close: bool) {
	ctx := &ui.ctx
	b := &ui.bans
	if .SUBMIT in
	   stable_button(ctx, "remove?", "Remove messages..." if !b.removing else "Remove messages:") {
		b.removing = !b.removing
	}
	if !b.removing {
		return false
	}
	if b.remove == .None {
		b.remove = .Hour
	}
	// From the last hour to all of them: a click picks the next.
	if .SUBMIT in
	   stable_button(
		   ctx,
		   "remove which",
		   fmt.tprintf("  Theirs of: %s", PURGE_CHOICES[b.remove]),
	   ) {
		b.remove = .Hour if b.remove == .All else proto.Ban_Purge(int(b.remove) + 1)
	}
	dim_label(ctx, "  In every conversation, for good")
	half := (width - ctx.style.spacing) / 2
	mu.layout_row(ctx, {half, half})
	if .SUBMIT in stable_button(ctx, "cancel remove", "Cancel") {
		b.removing = false
	}
	saved := ctx.style.colors[.TEXT]
	ctx.style.colors[.TEXT] = theme.error
	remove := .SUBMIT in stable_button(ctx, "remove", "Remove")
	ctx.style.colors[.TEXT] = saved
	mu.layout_row(ctx, {width})
	if !remove {
		return false
	}
	since: proto.Unix_Ms
	now := proto.Unix_Ms(time.time_to_unix_nano(time.now()) / 1_000_000)
	#partial switch b.remove {
	case .Hour:
		since = now - 60 * 60 * 1000
	case .Day:
		since = now - 24 * 60 * 60 * 1000
	case .Week:
		since = now - 7 * 24 * 60 * 60 * 1000
	}
	command(ui, conn.Purge_Command{all = true, author = account, since = since})
	b.removing = false
	return true
}

// bans_settings is the settings' Bans page: everyone who is banned, newest
// first, with who banned them, when, why, and Unban. Call with the View
// locked.
bans_settings :: proc(ui: ^UI, v: ^conn.View) {
	ctx := &ui.ctx
	if .Ban_Members not_in v.permissions {
		return
	}
	bans_ask(ui, v)
	mu.layout_row(ctx, {-1})
	dim_note(
		ctx,
		"A banned account can't log in, and its email address can't be used to register again. It is told why when it tries.",
	)
	if len(v.bans.list) == 0 {
		mu.layout_row(ctx, {-1})
		dim_label(ctx, "Nobody is banned.")
		return
	}
	for b in v.bans.list {
		mu.push_id(ctx, uintptr(b.account))
		defer mu.pop_id(ctx)
		// In a narrow window, the name and the date on one line, the rest
		// under them.
		row := []i32{160, 220, -90, 80}
		mu.layout_row(ctx, row if row_fits(ctx, row) else {160, -1})
		mu.label(ctx, ban_name(v, b.account))
		dim_label(ctx, fmt.tprintf("by %s, %s", ban_name(v, b.by), invite_date(ui, b.time)))
		if b.reason != "" {
			mu.label(ctx, b.reason)
		} else {
			dim_label(ctx, "no reason given")
		}
		if .SUBMIT in stable_button(ctx, "unban", "Unban", {.ALIGN_CENTER}) {
			command(ui, conn.Ban_Command{account = b.account, on = false})
		}
	}
}

// ban_name is how an account is named in the list. Call with the View locked.
@(private = "file")
ban_name :: proc(v: ^conn.View, account: proto.Account_Id) -> string {
	acc, known := v.accounts[account]
	switch {
	case !known:
		return fmt.tprintf("account #%d", account)
	case acc.display != "" && acc.display != acc.username:
		return fmt.tprintf("%s (%s)", acc.display, acc.username)
	}
	return acc.username
}

// banned_notice takes the login form's place while the server says that the
// account is banned: on which server, why, and a way to leave it. Close shows
// the form again, until the server says it once more. Returns whether it was
// shown. Call with the View locked, inside the login card.
banned_notice :: proc(ui: ^UI, server: string) -> bool {
	ctx := &ui.ctx
	v := ui.view
	if !v.login.banned || v.login.ban_count <= ui.bans.closed {
		return false
	}
	mu.layout_row(ctx, {-1})
	error_note(ctx, fmt.tprintf("You were banned from %s.", server))
	if v.login.ban_reason != "" {
		mu.layout_row(ctx, {-1})
		wrap_text(ctx, fmt.tprintf("Reason: %s", v.login.ban_reason))
	} else {
		mu.layout_row(ctx, {-1})
		dim_note(ctx, "No reason was given.")
	}
	mu.layout_row(ctx, {-1}, ctx.style.spacing)
	mu.layout_next(ctx)
	half := (mu.get_layout(ctx).body.w - ctx.style.spacing) / 2
	mu.layout_row(ctx, {half, -1})
	if .SUBMIT in stable_button(ctx, "remove server", "Remove server", {.ALIGN_CENTER}) {
		ui.rail.leave, ui.rail.forget_key = ui.session, false
	}
	if .SUBMIT in stable_button(ctx, "close ban", "Close", {.ALIGN_CENTER}) {
		ui.bans.closed = v.login.ban_count
	}
	return true
}

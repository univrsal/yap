package client

import "client:conn"
import "common:proto"
import "core:fmt"
import "core:time"
import mu "vendor:microui"

/*
Invite codes in the server settings tab (conn/invites.odin): making one,
good for so many registrations until so long, and the codes there are -
ours, or with Manage_Accounts everybody's - to copy or revoke.
*/

UI_Invites :: struct {
	asked:     bool, // the list, since the settings were opened
	uses:      u16, // for the next code; 0: any number
	days:      int, // how long it's good for; 0: no end
	// The code just made was shown, and copied with the button.
	made_seen: int,
}

@(private = "file")
USES := [?]u16{1, 5, 10, 0}
@(private = "file")
DAYS := [?]int{0, 1, 7, 30}

ui_invites_opened :: proc(ui: ^UI) {
	ui.invites.asked = false
	if ui.invites.uses == 0 && ui.invites.days == 0 {
		ui.invites.uses = 1
	}
}

/*
invites_settings is the "Invite codes" part of the server tab, for who
may make codes or manage accounts. Call with the View locked.
*/
invites_settings :: proc(ui: ^UI, v: ^conn.View) {
	ctx := &ui.ctx
	st := &ui.invites
	make_codes := .Create_Invites in v.permissions
	if !make_codes && .Manage_Accounts not_in v.permissions {
		return
	}
	if .ACTIVE not_in mu.begin_treenode(ctx, "Invite codes") {
		return
	}
	defer mu.end_treenode(ctx)
	if !st.asked {
		st.asked = true
		invites_command(ui, conn.Invites_Command{})
	}

	if make_codes {
		mu.layout_row(ctx, {FORM_LABEL, 70, 70, 70, 70})
		mu.label(ctx, "Registrations")
		for uses in USES {
			label := "Any" if uses == 0 else fmt.tprint(uses)
			if choice_button(ui, fmt.tprintf("uses%d", uses), label, st.uses == uses) {
				st.uses = uses
			}
		}
		mu.label(ctx, "Good for")
		for days in DAYS {
			label := "No end"
			switch days {
			case 1:
				label = "A day"
			case 7:
				label = "A week"
			case 30:
				label = "A month"
			}
			if choice_button(ui, fmt.tprintf("days%d", days), label, st.days == days) {
				st.days = days
			}
		}
		mu.layout_row(ctx, {FORM_LABEL, 150, -1})
		mu.label(ctx, "")
		if .SUBMIT in stable_button(ctx, "make", "Make invite code") {
			expires: proto.Unix_Ms
			if st.days > 0 {
				now := time.time_to_unix_nano(time.now()) / 1_000_000
				expires = proto.Unix_Ms(now + i64(st.days) * 24 * 60 * 60 * 1000)
			}
			invites_command(ui, conn.Invite_Create_Command{max_uses = st.uses, expires = expires})
		}
		with_text_color(ctx, DIM_COLOR, "Whoever has the code can register here.", label_proc)

		if v.invites.made != "" && v.invites.made_count > st.made_seen {
			mu.layout_row(ctx, {FORM_LABEL, 150, 90, 90})
			mu.label(ctx, "New code")
			mu.label(ctx, v.invites.made)
			if .SUBMIT in stable_button(ctx, "copy_made", "Copy") {
				set_clipboard(nil, v.invites.made)
			}
			if .SUBMIT in stable_button(ctx, "done_made", "Done") {
				st.made_seen = v.invites.made_count
			}
		}
	}

	if len(v.invites.list) == 0 {
		mu.layout_row(ctx, {-1})
		with_text_color(ctx, DIM_COLOR, "No invite codes yet.", label_proc)
		return
	}
	now := proto.Unix_Ms(time.time_to_unix_nano(time.now()) / 1_000_000)
	for inv in v.invites.list {
		mu.push_id(ctx, inv.code)
		defer mu.pop_id(ctx)
		mu.layout_row(ctx, {110, 110, 170, -(2 * 80 + 2 * ctx.style.spacing), 80, 80})
		mu.label(ctx, inv.code)
		if inv.max_uses == 0 {
			mu.label(ctx, fmt.tprintf("%d used", inv.uses))
		} else {
			mu.label(ctx, fmt.tprintf("%d of %d used", inv.uses, inv.max_uses))
		}
		usable := proto.invite_usable(inv, now)
		state := ""
		switch {
		case inv.revoked:
			state = "revoked"
		case inv.max_uses != 0 && inv.uses >= inv.max_uses:
			state = "used up"
		case inv.expires != 0 && inv.expires <= now:
			state = "expired"
		case inv.expires != 0:
			state = fmt.tprintf("until %s", invite_date(ui, inv.expires))
		case:
			state = "no end"
		}
		with_text_color(ctx, ctx.style.colors[.TEXT] if usable else DIM_COLOR, state, label_proc)
		by := ""
		if inv.creator != v.me {
			if acc, known := v.accounts[inv.creator]; known {
				by = fmt.tprintf("by %s", acc.display)
			}
		}
		with_text_color(ctx, DIM_COLOR, by, label_proc)
		if usable {
			if .SUBMIT in stable_button(ctx, "copy", "Copy") {
				set_clipboard(nil, inv.code)
			}
			if inv.creator == v.me || .Manage_Accounts in v.permissions {
				if .SUBMIT in stable_button(ctx, "revoke", "Revoke") {
					invites_command(ui, conn.Invite_Revoke_Command{code = clone(inv.code)})
				}
			} else {
				mu.label(ctx, "")
			}
		}
	}
}

/*
invited_by_line is what the account menu says about how an account got
here, for whoever manages accounts: which code it registered with and
whose that was. It's asked for the first time it's wanted. Call with the
View locked.
*/
invited_by_line :: proc(ui: ^UI, v: ^conn.View, account: proto.Account_Id) -> string {
	if .Manage_Accounts not_in v.permissions {
		return ""
	}
	of, known := v.invites.of[account]
	if !known {
		// Asked again a while later: the answer goes with the connection.
		asked, before := ui.invites_asked[account]
		if !before || time.tick_since(asked) > 10 * time.Second {
			ui.invites_asked[account] = time.tick_now()
			invites_command(ui, conn.Invite_Of_Command{account = account})
		}
		return ""
	}
	if of.code == "" {
		return ""
	}
	if acc, have := v.accounts[of.creator]; have {
		return fmt.tprintf("Invited by %s (%s)", acc.display, of.code)
	}
	return fmt.tprintf("Invited with %s", of.code)
}

@(private = "file")
invite_date :: proc(ui: ^UI, ms: proto.Unix_Ms) -> string {
	dt, _ := time.time_to_datetime(time.unix(i64(ms) / 1000, 0))
	local := chat_local_time(ui, dt)
	return fmt.tprintf(
		"%d-%02d-%02d %02d:%02d",
		local.year,
		local.month,
		local.day,
		local.hour,
		local.minute,
	)
}

// choice_button is a button that's one of a set, showing whether it's
// the one chosen; it says whether it was clicked.
@(private = "file")
choice_button :: proc(ui: ^UI, id, label: string, chosen: bool) -> bool {
	text := fmt.tprintf("> %s", label) if chosen else label
	return .SUBMIT in stable_button(&ui.ctx, id, text, {.ALIGN_CENTER})
}

@(private = "file")
invites_command :: proc(ui: ^UI, cmd: conn.Command) {
	if ui.session != nil {
		conn.push_command(&ui.session.client.commands, cmd)
	}
}

@(private = "file")
clone :: proc(s: string) -> string {
	out := make([]u8, len(s))
	copy(out, s)
	return string(out)
}

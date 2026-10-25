package client

import "client:conn"
import "common:proto"
import "core:fmt"
import "core:time"
import mu "vendor:microui"


// Invite codes in the server settings tab (conn/invites.odin): creating a code
// that is valid for a number of registrations and for a period of time, and
// listing the existing codes (ours, or with Manage_Accounts everybody's) so
// they can be copied or revoked.

UI_Invites :: struct {
	asked:     bool, // the list was requested since the settings were opened
	uses:      u16, // number of registrations for the next code; 0: unlimited
	days:      int, // how many days the next code is valid; 0: forever
	// The made_count of the newly created code that was dismissed with the
	// Done button, so it is no longer shown.
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

// invites_settings draws the "Invite codes" section of the server tab, for
// users who may create codes or manage accounts. Call with the View locked.
invites_settings :: proc(ui: ^UI, v: ^conn.View) {
	ctx := &ui.ctx
	st := &ui.invites
	make_codes := .Create_Invites in v.permissions
	if !make_codes && .Manage_Accounts not_in v.permissions {
		return
	}
	if !st.asked {
		st.asked = true
		command(ui, conn.Invites_Command{})
	}

	if make_codes {
		field_row(ui, FORM_LABEL, "Registrations", {CHOICE_WIDTH})
		uses_labels: [len(USES)]string
		uses_at := -1
		for uses, i in USES {
			uses_labels[i] = "Any" if uses == 0 else fmt.tprint(uses)
			if st.uses == uses {
				uses_at = i
			}
		}
		if i, ok := choice_dropdown(ui, "uses", uses_labels[:], uses_at); ok {
			st.uses = USES[i]
		}
		field_row(ui, FORM_LABEL, "Valid for", {CHOICE_WIDTH})
		days_labels := [len(DAYS)]string{"Forever", "A day", "A week", "A month"}
		days_at := -1
		for days, i in DAYS {
			if st.days == days {
				days_at = i
			}
		}
		if i, ok := choice_dropdown(ui, "days", days_labels[:], days_at); ok {
			st.days = DAYS[i]
		}
		field_row(ui, FORM_LABEL, "", {150, -1})
		if .SUBMIT in stable_button(ctx, "make", "Make invite code") {
			expires: proto.Unix_Ms
			if st.days > 0 {
				now := time.time_to_unix_nano(time.now()) / 1_000_000
				expires = proto.Unix_Ms(now + i64(st.days) * 24 * 60 * 60 * 1000)
			}
			command(ui, conn.Invite_Create_Command{max_uses = st.uses, expires = expires})
		}
		dim_note(ctx, "Anyone with the code can register an account on this server.")

		if v.invites.made != "" && v.invites.made_count > st.made_seen {
			field_row(ui, FORM_LABEL, "New code", {150, 90, 90})
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
		dim_label(ctx, "No invite codes yet.")
		return
	}
	now := proto.Unix_Ms(time.time_to_unix_nano(time.now()) / 1_000_000)
	for inv in v.invites.list {
		mu.push_id(ctx, inv.code)
		defer mu.pop_id(ctx)
		// In a narrow window, two cells per line: the code and its uses, its
		// state and its creator, and the buttons.
		row := []i32{110, 110, 170, -(2 * 80 + 2 * ctx.style.spacing), 80, 80}
		mu.layout_row(ctx, row if row_fits(ctx, row) else {110, -1})
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
			state = "never expires"
		}
		with_text_color(ctx, ctx.style.colors[.TEXT] if usable else theme.dim, state, label_proc)
		by := ""
		if inv.creator != v.me {
			if acc, known := v.accounts[inv.creator]; known {
				by = fmt.tprintf("by %s", acc.display)
			}
		}
		dim_label(ctx, by)
		if usable {
			if .SUBMIT in stable_button(ctx, "copy", "Copy") {
				set_clipboard(nil, inv.code)
			}
			if inv.creator == v.me || .Manage_Accounts in v.permissions {
				if .SUBMIT in stable_button(ctx, "revoke", "Revoke") {
					command(ui, conn.Invite_Revoke_Command{code = clone(inv.code)})
				}
			} else {
				mu.label(ctx, "")
			}
		}
	}
}

// invited_by_line returns what the account menu says about how an account was
// created, for users who manage accounts: which code it registered with and who
// created that code. It is requested from the server the first time it is
// needed. Call with the View locked.
invited_by_line :: proc(ui: ^UI, v: ^conn.View, account: proto.Account_Id) -> string {
	if .Manage_Accounts not_in v.permissions {
		return ""
	}
	of, known := v.invites.of[account]
	if !known {
		// Ask again after a while, since the answer is lost if the connection
		// drops.
		asked, before := ui.invites_asked[account]
		if !before || time.tick_since(asked) > 10 * time.Second {
			ui.invites_asked[account] = time.tick_now()
			command(ui, conn.Invite_Of_Command{account = account})
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

@(private = "file")
clone :: proc(s: string) -> string {
	out := make([]u8, len(s))
	copy(out, s)
	return string(out)
}

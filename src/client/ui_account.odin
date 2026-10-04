package client

import "client:conn"
import "client:platform"
import "client:settings"
import "common:proto"
import "core:fmt"
import "core:strings"
import "core:sync"
import mu "vendor:microui"

/*
Accounts in the UI (conn/auth.odin is the network's end of it).

  - The login screen, shown while connected to a server that doesn't know
    this device yet: username and password, and whatever the server said
    to the last attempt.
  - The screen that follows a login with a password an admin chose: it
    has to be replaced before anything else.
  - The Account section of the settings: what we're called, our
    password, the devices logged in to the account, logging out.
  - For whoever manages accounts, an Accounts section under it: the
    accounts there are, making one, and giving one a new password.

There's no registering: accounts are made by an admin.
*/

UI_Account :: struct {
	// The login form.
	username_buf:  [proto.MAX_USERNAME_SIZE]u8,
	username_len:  int,
	password_buf:  [proto.MAX_ACCOUNT_PASSWORD]u8,
	password_len:  int,
	// Changing the password: the current one, the new one, and again.
	old_buf:       [proto.MAX_ACCOUNT_PASSWORD]u8,
	old_len:       int,
	new_buf:       [proto.MAX_ACCOUNT_PASSWORD]u8,
	new_len:       int,
	again_buf:     [proto.MAX_ACCOUNT_PASSWORD]u8,
	again_len:     int,
	revoke_others: bool,
	// What's wrong with what was typed, before the server is asked.
	mistake:       string, // static
	// The name field (ui.name_buf) has been filled with what we're
	// called, and the devices asked for, since the settings were opened.
	name_loaded:   bool,
	devices_asked: bool,
	// What the server had said by then isn't about anything asked since:
	// only a notice newer than this one (View_Notice.count) is shown.
	notice_reset:  bool,
	notice_seen:   int,
	// Making an account.
	add_user_buf:  [proto.MAX_USERNAME_SIZE]u8,
	add_user_len:  int,
	add_name_buf:  [2 * proto.MAX_NAME_SIZE]u8,
	add_name_len:  int,
	add_pass_buf:  [proto.MAX_ACCOUNT_PASSWORD]u8,
	add_pass_len:  int,
	// Giving an account a new password: whose, and the password.
	set_account:   proto.Account_Id,
	set_pass_buf:  [proto.MAX_ACCOUNT_PASSWORD]u8,
	set_pass_len:  int,
}

@(private = "file")
NOTICE_OK_COLOR :: mu.Color{120, 200, 120, 255}
@(private = "file")
WARN_COLOR :: mu.Color{230, 200, 90, 255}
FORM_LABEL :: 130
@(private = "file")
FORM_FIELD :: 220

// ui_account_opened is the settings page being opened: what it shows of
// the account is fetched anew.
ui_account_opened :: proc(ui: ^UI) {
	ui.account.name_loaded = false
	ui.account.devices_asked = false
	ui.account.mistake = ""
	ui.account.notice_reset = true
}

// wipe clears a buffer that held a password.
@(private = "file")
wipe :: proc(buf: []u8, length: ^int) {
	for &b in buf {
		b = 0
	}
	length^ = 0
}

@(private = "file")
command :: proc(ui: ^UI, cmd: conn.Command) {
	if ui.session != nil {
		conn.push_command(&ui.session.client.commands, cmd)
	}
}

/*
login_screen is what a server that doesn't know this device shows
instead of its channels. Call with the View locked.
*/
login_screen :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := &ui.view
	a := &ui.account

	title_row(ui, {-(ICON_BUTTON + 8), ICON_BUTTON})
	server := v.server_name if v.server_name != "" else v.server
	mu.label(ctx, fmt.tprintf("Log in to %s", server))
	if .SUBMIT in icon_button(ui, "disconnect", .Leave, "Disconnect", OFF_COLOR) {
		ui.action = .Disconnect
	}

	working := v.login.state != .Needed
	submit := false
	mu.layout_row(ctx, {FORM_LABEL, FORM_FIELD})
	mu.label(ctx, "Username")
	submit |= .SUBMIT in text_box(ui, a.username_buf[:], &a.username_len)
	mu.label(ctx, "Password")
	submit |= .SUBMIT in password_box(ui, a.password_buf[:], &a.password_len)
	mu.label(ctx, "")
	submit |= .SUBMIT in mu.button(ctx, "Logging in..." if working else "Log in")

	mu.layout_row(ctx, {-1})
	switch {
	case v.login.error != "":
		with_text_color(ctx, ERROR_COLOR, v.login.error, label_proc)
	case !working:
		with_text_color(
			ctx,
			DIM_COLOR,
			"This device isn't logged in here yet. Accounts are made by the server's admin.",
			label_proc,
		)
	}

	if submit && !working && a.username_len > 0 && a.password_len > 0 {
		username := string(a.username_buf[:a.username_len])
		settings.set_setting(&ui.settings.username, username)
		ui.settings_dirty = true
		command(
			ui,
			conn.Login_Command {
				username = strings.clone(username),
				password = strings.clone(string(a.password_buf[:a.password_len])),
				device = strings.clone(platform.default_name()),
			},
		)
		wipe(a.password_buf[:], &a.password_len)
	}

	mu.layout_row(ctx, {-1}, -1)
	log_panel(ui)
}

/*
password_screen is what follows a login with a password somebody else
chose: nothing else until it has been replaced. Call with the View
locked.
*/
password_screen :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := &ui.view

	title_row(ui, {-(ICON_BUTTON + 8), ICON_BUTTON})
	mu.label(ctx, fmt.tprintf("Choose a password for %s", v.login.username))
	if .SUBMIT in icon_button(ui, "disconnect", .Leave, "Disconnect", OFF_COLOR) {
		ui.action = .Disconnect
	}
	mu.layout_row(ctx, {-1})
	with_text_color(
		ctx,
		DIM_COLOR,
		"The one you logged in with was set by an admin, and is only good for getting in.",
		label_proc,
	)
	password_form(ui, v, "Password you logged in with", false)

	mu.layout_row(ctx, {-1}, -1)
	log_panel(ui)
}

// password_form is the three fields and the button that change the
// password, and what came of it.
@(private = "file")
password_form :: proc(ui: ^UI, v: ^conn.View, old_label: string, offer_revoke: bool) {
	ctx := &ui.ctx
	a := &ui.account

	submit := false
	mu.layout_row(ctx, {FORM_LABEL + 60, FORM_FIELD})
	mu.label(ctx, old_label)
	submit |= .SUBMIT in password_box(ui, a.old_buf[:], &a.old_len)
	mu.label(ctx, "New password")
	submit |= .SUBMIT in password_box(ui, a.new_buf[:], &a.new_len)
	mu.label(ctx, "New password, again")
	submit |= .SUBMIT in password_box(ui, a.again_buf[:], &a.again_len)
	if offer_revoke {
		mu.layout_row(ctx, {FORM_LABEL + 60, -1})
		mu.label(ctx, "")
		mu.checkbox(ctx, "Log my other devices out", &a.revoke_others)
	}
	mu.layout_row(ctx, {FORM_LABEL + 60, 140, -1})
	mu.label(ctx, "")
	submit |= .SUBMIT in mu.button(ctx, "Change password")
	notice_label(ui, v)

	if !submit {
		return
	}
	new := string(a.new_buf[:a.new_len])
	switch {
	case new != string(a.again_buf[:a.again_len]):
		a.mistake = "The two new passwords aren't the same."
	case !proto.account_password_ok(new):
		a.mistake = "A password has to be at least 8 characters."
	case:
		a.mistake = ""
		command(
			ui,
			conn.Password_Command {
				old = strings.clone(string(a.old_buf[:a.old_len])),
				new = strings.clone(new),
				revoke_others = offer_revoke && a.revoke_others,
			},
		)
		wipe(a.old_buf[:], &a.old_len)
		wipe(a.new_buf[:], &a.new_len)
		wipe(a.again_buf[:], &a.again_len)
	}
}

// notice_label says what's wrong with what was typed, or else what the
// server made of the last thing asked.
@(private = "file")
notice_label :: proc(ui: ^UI, v: ^conn.View) {
	ctx := &ui.ctx
	switch {
	case ui.account.mistake != "":
		with_text_color(ctx, ERROR_COLOR, ui.account.mistake, label_proc)
	case v.notice.text != "" && v.notice.count > ui.account.notice_seen:
		with_text_color(
			ctx,
			NOTICE_OK_COLOR if v.notice.ok else ERROR_COLOR,
			v.notice.text,
			label_proc,
		)
	case:
		mu.label(ctx, "")
	}
}

/*
account_settings is the settings page's part about our account, and for
who manages them, everybody's. The settings page doesn't hold the View's
lock, so it's taken here.
*/
account_settings :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := &ui.view
	a := &ui.account
	sync.guard(&v.mutex)
	if a.notice_reset {
		a.notice_reset = false
		a.notice_seen = v.notice.count
	}
	if v.status != .Connected || v.login.state != .Done {
		return
	}
	me, known := v.accounts[v.me]
	if !known {
		return
	}

	if .ACTIVE in mu.begin_treenode(ctx, fmt.tprintf("Account (%s)", me.username), {.EXPANDED}) {
		defer mu.end_treenode(ctx)

		if !a.name_loaded {
			a.name_loaded = true
			ui.name_len = copy(ui.name_buf[:], me.display)
		}
		mu.layout_row(ctx, {FORM_LABEL, FORM_FIELD, 70})
		mu.label(ctx, "Name")
		submitted := .SUBMIT in text_box(ui, ui.name_buf[:], &ui.name_len)
		if (.SUBMIT in mu.button(ctx, "Apply") || submitted) && ui.name_len > 0 {
			a.mistake = ""
			command(ui, conn.Display_Command{strings.clone(string(ui.name_buf[:ui.name_len]))})
		}
		profile_settings(ui)
		status_settings(ui)

		if .ACTIVE in mu.begin_treenode(ctx, "Password") {
			password_form(ui, v, "Current password", true)
			mu.end_treenode(ctx)
		}

		if .ACTIVE in mu.begin_treenode(ctx, "Devices") {
			if !a.devices_asked {
				a.devices_asked = true
				command(ui, conn.Devices_Command{})
			}
			devices_list(ui, v)
			mu.end_treenode(ctx)
		}

		mu.layout_row(ctx, {FORM_LABEL, 140, -1})
		mu.label(ctx, "")
		if .SUBMIT in mu.button(ctx, "Log out") {
			command(ui, conn.Logout_Command{})
			ui.page = .Main
		}
		with_text_color(ctx, DIM_COLOR, "This device has to log in again afterwards.", label_proc)
	}

	if .Manage_Roles in v.permissions {
		if .ACTIVE in mu.begin_treenode(ctx, "Roles") {
			roles_settings(ui)
			mu.end_treenode(ctx)
		}
	}
	if v.permissions & {.Manage_Accounts, .Manage_Roles} != {} {
		if .ACTIVE in mu.begin_treenode(ctx, "Accounts on this server") {
			accounts_admin(ui, v)
			mu.end_treenode(ctx)
		}
	}
	if .Purge in v.permissions {
		if .ACTIVE in mu.begin_treenode(ctx, "Purge history") {
			purge_settings(ui)
			mu.end_treenode(ctx)
		}
	}
}

@(private = "file")
devices_list :: proc(ui: ^UI, v: ^conn.View) {
	ctx := &ui.ctx
	if len(v.devices) == 0 {
		mu.layout_row(ctx, {-1})
		with_text_color(ctx, DIM_COLOR, "Asking the server...", label_proc)
		return
	}
	for d, i in v.devices {
		mu.push_id(ctx, uintptr(i))
		defer mu.pop_id(ctx)
		mu.layout_row(ctx, {-150, 140})
		what := ""
		switch {
		case .Current in d.flags:
			what = "  (this device)"
		case .Online in d.flags:
			what = "  (connected)"
		}
		mu.label(ctx, fmt.tprintf("%s  %s%s", conn.fingerprint(d.key), d.name, what))
		// This one has the button below, which says what it means here.
		if .Current in d.flags {
			mu.label(ctx, "")
		} else if .SUBMIT in stable_button(ctx, "revoke", "Log out") {
			ui.account.mistake = ""
			command(ui, conn.Revoke_Command{d.key})
		}
	}
}

@(private = "file")
accounts_admin :: proc(ui: ^UI, v: ^conn.View) {
	ctx := &ui.ctx
	a := &ui.account

	// By id: the order they were made in.
	most: proto.Account_Id
	for id in v.accounts {
		most = max(most, id)
	}
	for id in 1 ..= most {
		acc, ok := v.accounts[id]
		if !ok {
			continue
		}
		mu.push_id(ctx, uintptr(id))
		defer mu.pop_id(ctx)
		mu.layout_row(ctx, {-(140 + 2 * 90 + 3 * ctx.style.spacing), 140, 90, 90})
		what := ""
		switch {
		case .Owner in acc.flags:
			what = "  (owner)"
		case .Disabled in acc.flags:
			what = "  (disabled)"
		}
		roles := make([dynamic]string, context.temp_allocator)
		for r in acc.roles {
			for vr in v.roles {
				if vr.id == r {
					append(&roles, vr.name)
				}
			}
		}
		if len(roles) > 0 {
			what = fmt.tprintf(
				"%s  [%s]",
				what,
				strings.join(roles[:], ", ", context.temp_allocator),
			)
		}
		mu.label(ctx, fmt.tprintf("%s  %s%s", acc.username, acc.display, what))
		// The owner's password is the owner's to change, as their own.
		if .Owner in acc.flags || .Manage_Accounts not_in v.permissions || !below_us(v, acc) {
			mu.label(ctx, "")
		} else if .SUBMIT in stable_button(ctx, "setpass", "New password...") {
			a.set_account = id
			wipe(a.set_pass_buf[:], &a.set_pass_len)
		}
		account_manage(ui, id, acc)
		account_roles_editor(ui, id)
	}
	if .Manage_Accounts not_in v.permissions {
		return
	}

	if target, ok := v.accounts[a.set_account]; ok && a.set_account != 0 {
		mu.layout_row(ctx, {FORM_LABEL + 60, FORM_FIELD, 60, 70})
		mu.label(ctx, fmt.tprintf("New password for %s", target.username))
		submitted := .SUBMIT in password_box(ui, a.set_pass_buf[:], &a.set_pass_len)
		if (.SUBMIT in mu.button(ctx, "Set") || submitted) && a.set_pass_len > 0 {
			a.mistake = ""
			command(
				ui,
				conn.Account_Password_Command {
					account = a.set_account,
					password = strings.clone(string(a.set_pass_buf[:a.set_pass_len])),
				},
			)
			wipe(a.set_pass_buf[:], &a.set_pass_len)
			a.set_account = 0
		}
		if .SUBMIT in mu.button(ctx, "Cancel") {
			wipe(a.set_pass_buf[:], &a.set_pass_len)
			a.set_account = 0
		}
		mu.layout_row(ctx, {-1})
		with_text_color(
			ctx,
			WARN_COLOR,
			"  It logs their devices out, and they have to choose their own on logging in.",
			label_proc,
		)
	}

	mu.layout_row(ctx, {-1})
	mu.label(ctx, "Make an account:")
	submit := false
	mu.layout_row(ctx, {FORM_LABEL, FORM_FIELD})
	mu.label(ctx, "Username")
	submit |= .SUBMIT in text_box(ui, a.add_user_buf[:], &a.add_user_len)
	mu.label(ctx, "Name")
	submit |= .SUBMIT in text_box(ui, a.add_name_buf[:], &a.add_name_len)
	mu.label(ctx, "First password")
	submit |= .SUBMIT in password_box(ui, a.add_pass_buf[:], &a.add_pass_len)
	mu.layout_row(ctx, {FORM_LABEL, 140, -1})
	mu.label(ctx, "")
	submit |= .SUBMIT in mu.button(ctx, "Make account")
	notice_label(ui, v)
	if submit && a.add_user_len > 0 {
		a.mistake = ""
		command(
			ui,
			conn.Account_Create_Command {
				username = strings.clone(string(a.add_user_buf[:a.add_user_len])),
				password = strings.clone(string(a.add_pass_buf[:a.add_pass_len])),
				display = strings.clone(string(a.add_name_buf[:a.add_name_len])),
			},
		)
		wipe(a.add_pass_buf[:], &a.add_pass_len)
		a.add_user_len, a.add_name_len = 0, 0
	}
}

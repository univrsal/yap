package client

import "client:conn"
import "client:platform"
import "client:settings"
import "common:proto"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import mu "vendor:microui"

/*
Accounts in the UI (conn/auth.odin is the network's end of it).

  - The login screen, shown while connected to a server that doesn't know
    this device yet: username and password, and whatever the server said
    to the last attempt; or, where the server takes registrations,
    registering instead, with what it asks for.
  - The screen that follows a login with a password an admin chose: it
    has to be replaced before anything else.
  - The screen an account whose email address isn't verified yet gets
    instead of everything else: how to verify it, by mailing the server
    (proto/verify.odin).
  - The Account section of the settings: what we're called, our
    password, the devices logged in to the account, logging out.
  - For whoever manages accounts, an Accounts section under it: the
    accounts there are, making one, and giving one a new password.

Where the server doesn't take registrations, accounts are made by an
admin.
*/

UI_Account :: struct {
	// The login form.
	username_buf:  [proto.MAX_USERNAME_SIZE]u8,
	username_len:  int,
	password_buf:  [proto.MAX_ACCOUNT_PASSWORD]u8,
	password_len:  int,
	// Registering instead: the password again, the address and the
	// invite code, if the server asks for them.
	registering:   bool,
	reg_again_buf: [proto.MAX_ACCOUNT_PASSWORD]u8,
	reg_again_len: int,
	reg_email_buf: [proto.MAX_EMAIL_SIZE]u8,
	reg_email_len: int,
	invite_buf:    [proto.INVITE_CODE_SIZE + 8]u8,
	invite_len:    int,
	// Fixing the address on the page that waits for it to be verified,
	// which starts out as it is.
	verify_buf:    [proto.MAX_EMAIL_SIZE]u8,
	verify_len:    int,
	verify_loaded: string, // what it was filled with; owned
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
	// called, and the email field with our address, and the devices
	// asked for, since the settings were opened.
	name_loaded:   bool,
	email_buf:     [proto.MAX_EMAIL_SIZE]u8,
	email_len:     int,
	// The name's or the email's Apply was used: what the server made of
	// it is shown under them.
	profile_asked: bool,
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
	// Deleting our own account: the password, typed again.
	delete_buf:    [proto.MAX_ACCOUNT_PASSWORD]u8,
	delete_len:    int,
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
	ui.account.profile_asked = false
	ui.account.devices_asked = false
	ui.account.mistake = ""
	ui.account.notice_reset = true
	ui_invites_opened(ui)
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
	v := ui.view
	a := &ui.account
	open := .Open in v.registration
	if !open {
		a.registering = false
	}
	registering := a.registering

	title_row(ui, {-(ICON_BUTTON + 8), ICON_BUTTON})
	server := v.server_name if v.server_name != "" else v.server
	mu.label(ctx, fmt.tprintf("%s %s", "Register at" if registering else "Log in to", server))
	// In the + dialog, giving up joining it (ui_join.odin).
	leave := "Cancel" if ui.session != nil && ui.session.joining else "Leave this server"
	if .SUBMIT in icon_button(ui, "disconnect", .Leave, leave, OFF_COLOR) {
		ui.action = .Disconnect
	}

	working := v.login.state != .Needed
	submit := false
	mu.layout_row(ctx, {FORM_LABEL, FORM_FIELD})
	mu.label(ctx, "Username")
	submit |= .SUBMIT in text_box(ui, a.username_buf[:], &a.username_len)
	mu.label(ctx, "Password")
	submit |= .SUBMIT in password_box(ui, a.password_buf[:], &a.password_len)
	if registering {
		mu.label(ctx, "Password again")
		submit |= .SUBMIT in password_box(ui, a.reg_again_buf[:], &a.reg_again_len)
		if .Email in v.registration {
			mu.label(ctx, "Email")
			submit |= .SUBMIT in text_box(ui, a.reg_email_buf[:], &a.reg_email_len)
		}
		if .Invite in v.registration {
			mu.label(ctx, "Invite code")
			submit |= .SUBMIT in text_box(ui, a.invite_buf[:], &a.invite_len)
		}
	}
	mu.label(ctx, "")
	label := "Log in"
	switch {
	case working && registering:
		label = "Registering..."
	case working:
		label = "Logging in..."
	case registering:
		label = "Register"
	}
	submit |= .SUBMIT in mu.button(ctx, label)
	if open && !working {
		mu.label(ctx, "")
		other := "Log in to an account instead" if registering else "Register an account instead"
		if .SUBMIT in mu.button(ctx, other) {
			a.registering = !registering
			a.mistake = ""
		}
	}

	mu.layout_row(ctx, {-1})
	switch {
	case a.mistake != "":
		with_text_color(ctx, ERROR_COLOR, a.mistake, label_proc)
	case v.login.error != "":
		with_text_color(ctx, ERROR_COLOR, v.login.error, label_proc)
	case !working && !open:
		with_text_color(
			ctx,
			DIM_COLOR,
			"This device isn't logged in here yet. Accounts are made by the server's admin.",
			label_proc,
		)
	case !working && !registering:
		with_text_color(ctx, DIM_COLOR, "This device isn't logged in here yet.", label_proc)
	}

	if submit && !working && a.username_len > 0 && a.password_len > 0 {
		username := string(a.username_buf[:a.username_len])
		password := string(a.password_buf[:a.password_len])
		if registering {
			if !register_mistake(ui) {
				return
			}
		}
		settings.set_setting(&ui.settings.username, username)
		ui.settings_dirty = true
		if registering {
			command(
				ui,
				conn.Register_Command {
					username = strings.clone(username),
					password = strings.clone(password),
					device = strings.clone(platform.default_name()),
					email = strings.clone(string(a.reg_email_buf[:a.reg_email_len])),
					invite = strings.clone(string(a.invite_buf[:a.invite_len])),
				},
			)
			wipe(a.reg_again_buf[:], &a.reg_again_len)
		} else {
			command(
				ui,
				conn.Login_Command {
					username = strings.clone(username),
					password = strings.clone(password),
					device = strings.clone(platform.default_name()),
				},
			)
		}
		wipe(a.password_buf[:], &a.password_len)
	}

	mu.layout_row(ctx, {-1}, -1)
	log_panel(ui)
}

/*
register_mistake checks what was typed to register before the server is
asked, as far as it can be told here; false, with a.mistake saying why,
if it won't do.
*/
@(private = "file")
register_mistake :: proc(ui: ^UI) -> bool {
	a := &ui.account
	v := ui.view
	a.mistake = ""
	name_buf: [proto.MAX_USERNAME_SIZE]u8
	password := string(a.password_buf[:a.password_len])
	email := string(a.reg_email_buf[:a.reg_email_len])
	email_buf: [proto.MAX_EMAIL_SIZE]u8
	code_buf: [proto.INVITE_CODE_SIZE]u8
	switch {
	case !username_ok(string(a.username_buf[:a.username_len]), &name_buf):
		a.mistake = "A username is 2 to 32 of a-z 0-9 _ . - (no spaces)."
	case !proto.account_password_ok(password):
		a.mistake = "A password is 8 to 128 characters."
	case password != string(a.reg_again_buf[:a.reg_again_len]):
		a.mistake = "The two passwords aren't the same."
	case .Email in v.registration && strings.trim_space(email) == "":
		a.mistake = "This server asks for an email address."
	case strings.trim_space(email) != "" && !email_ok(email, &email_buf):
		a.mistake = "That's no email address."
	case .Invite in v.registration && a.invite_len == 0:
		a.mistake = "This server asks for an invite code."
	case a.invite_len > 0 && !invite_ok(string(a.invite_buf[:a.invite_len]), &code_buf):
		a.mistake = "That isn't an invite code: they're 10 letters and digits, as given to you."
	}
	return a.mistake == ""

	username_ok :: proc(raw: string, buf: ^[proto.MAX_USERNAME_SIZE]u8) -> bool {
		_, ok := proto.username_clean(raw, buf)
		return ok
	}
	email_ok :: proc(raw: string, buf: ^[proto.MAX_EMAIL_SIZE]u8) -> bool {
		_, ok := proto.email_clean(raw, buf)
		return ok
	}
	invite_ok :: proc(raw: string, buf: ^[proto.INVITE_CODE_SIZE]u8) -> bool {
		_, ok := proto.invite_code_clean(raw, buf)
		return ok
	}
}

/*
verify_screen is all an account whose address isn't verified gets: what
to mail where, a way to fix the address, and logging out. It goes on by
itself once the server has the mail. Call with the View locked.
*/
verify_screen :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := ui.view
	a := &ui.account
	server := v.server_name if v.server_name != "" else v.server

	title_row(ui, {-(ICON_BUTTON + 8), ICON_BUTTON})
	mu.label(ctx, fmt.tprintf("Verify your email address for %s", server))
	if .SUBMIT in icon_button(ui, "disconnect", .Leave, "Leave this server", OFF_COLOR) {
		ui.action = .Disconnect
	}
	mu.layout_row(ctx, {-1})
	mu.label(ctx, "Send a mail from your address to the server's, with the code in its subject:")

	mu.layout_row(ctx, {FORM_LABEL, FORM_FIELD + 80, 90})
	mu.label(ctx, "From")
	mu.label(ctx, v.login.email)
	mu.label(ctx, "")
	mu.label(ctx, "To")
	mu.label(ctx, v.server_email if v.server_email != "" else "(the server hasn't said)")
	if .SUBMIT in stable_button(ctx, "copy_to", "Copy") {
		set_clipboard(nil, v.server_email)
	}
	mu.label(ctx, "Subject")
	mu.label(ctx, v.login.verify_code)
	if .SUBMIT in stable_button(ctx, "copy_code", "Copy") {
		set_clipboard(nil, v.login.verify_code)
	}
	mu.label(ctx, "")
	if .SUBMIT in stable_button(ctx, "mailto", "Write it in my mail program") {
		platform.open_mailto(v.server_email, v.login.verify_code)
	}
	mu.label(ctx, "")

	mu.layout_row(ctx, {-1})
	with_text_color(
		ctx,
		DIM_COLOR,
		"The server reads its mail every minute or so; this page goes on by itself once it has yours.",
		label_proc,
	)
	if v.login.verify_by != 0 {
		dt, _ := time.time_to_datetime(time.unix(i64(v.login.verify_by) / 1000, 0))
		local := chat_local_time(ui, dt)
		with_text_color(
			ctx,
			WARN_COLOR,
			fmt.tprintf(
				"Without it, the account is deleted on %d-%02d-%02d at %02d:%02d.",
				local.year,
				local.month,
				local.day,
				local.hour,
				local.minute,
			),
			label_proc,
		)
	}

	// Mistyped? Fixed here, with a new code.
	if a.verify_loaded != v.login.email {
		delete(a.verify_loaded)
		a.verify_loaded = strings.clone(v.login.email)
		a.verify_len = copy(a.verify_buf[:], v.login.email)
	}
	mu.layout_row(ctx, {FORM_LABEL, FORM_FIELD, 70})
	mu.label(ctx, "Not your address?")
	submitted := .SUBMIT in text_box(ui, a.verify_buf[:], &a.verify_len)
	if (.SUBMIT in mu.button(ctx, "Change") || submitted) && a.verify_len > 0 {
		a.mistake = ""
		a.profile_asked = true
		command(ui, conn.Email_Command{strings.clone(string(a.verify_buf[:a.verify_len]))})
	}
	if a.profile_asked {
		mu.layout_row(ctx, {FORM_LABEL, -1})
		mu.label(ctx, "")
		notice_label(ui, v)
	}

	mu.layout_row(ctx, {FORM_LABEL, 140, -1})
	mu.label(ctx, "")
	if .SUBMIT in mu.button(ctx, "Log out") {
		command(ui, conn.Logout_Command{})
	}
	with_text_color(ctx, DIM_COLOR, "This device has to log in again afterwards.", label_proc)

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
	v := ui.view

	title_row(ui, {-(ICON_BUTTON + 8), ICON_BUTTON})
	mu.label(ctx, fmt.tprintf("Choose a password for %s", v.login.username))
	if .SUBMIT in icon_button(ui, "disconnect", .Leave, "Leave this server", OFF_COLOR) {
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
	v := ui.view
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
			a.email_len = copy(a.email_buf[:], v.login.email)
		}
		mu.layout_row(ctx, {FORM_LABEL, FORM_FIELD, 70})
		mu.label(ctx, "Name")
		submitted := .SUBMIT in text_box(ui, ui.name_buf[:], &ui.name_len)
		if (.SUBMIT in mu.button(ctx, "Apply") || submitted) && ui.name_len > 0 {
			a.mistake = ""
			a.profile_asked = true
			command(ui, conn.Display_Command{strings.clone(string(ui.name_buf[:ui.name_len]))})
		}
		// Its own id: the name's button says Apply too.
		mu.push_id(ctx, "email")
		mu.label(ctx, "Email")
		email_submitted := .SUBMIT in text_box(ui, a.email_buf[:], &a.email_len)
		if .SUBMIT in mu.button(ctx, "Apply") || email_submitted {
			a.mistake = ""
			a.profile_asked = true
			command(ui, conn.Email_Command{strings.clone(string(a.email_buf[:a.email_len]))})
		}
		mu.pop_id(ctx)
		if v.server_email != "" && .Owner not_in me.flags {
			mu.layout_row(ctx, {FORM_LABEL, -1})
			mu.label(ctx, "")
			with_text_color(
				ctx,
				DIM_COLOR,
				"A new address has to be verified by mail before you can go on.",
				label_proc,
			)
		}
		if a.profile_asked {
			mu.layout_row(ctx, {FORM_LABEL, -1})
			mu.label(ctx, "")
			notice_label(ui, v)
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

		// Not the owner's: somebody has to be.
		if .Owner not_in me.flags {
			if .ACTIVE in mu.begin_treenode(ctx, "Delete this account") {
				delete_own_account(ui, v)
				mu.end_treenode(ctx)
			}
		}
	}

	if .Manage_Roles in v.permissions {
		mu.layout_row(ctx, {FORM_LABEL, 140, -1})
		mu.label(ctx, "Roles")
		if .SUBMIT in mu.button(ctx, "Roles...") {
			open_roles(ui)
		}
		with_text_color(ctx, DIM_COLOR, "What each allows, and who has it.", label_proc)
	}
	if v.permissions & {.Manage_Accounts, .Manage_Roles} != {} {
		if .ACTIVE in mu.begin_treenode(ctx, "Accounts on this server") {
			accounts_admin(ui, v)
			mu.end_treenode(ctx)
		}
	}
	invites_settings(ui, v)
	if .Purge in v.permissions {
		if .ACTIVE in mu.begin_treenode(ctx, "Purge history") {
			purge_settings(ui)
			mu.end_treenode(ctx)
		}
	}
}

// delete_own_account is the form for deleting our own account, which
// takes its password again. Call with the View locked.
@(private = "file")
delete_own_account :: proc(ui: ^UI, v: ^conn.View) {
	ctx := &ui.ctx
	a := &ui.account
	mu.layout_row(ctx, {-1})
	with_text_color(
		ctx,
		WARNING_COLOR,
		fmt.tprintf(
			"For good: your name, picture, status, roles and devices go. What you wrote stays, under \"%s\".",
			proto.DELETED_NAME,
		),
		label_proc,
	)
	mu.layout_row(ctx, {FORM_LABEL, FORM_FIELD, 140})
	mu.label(ctx, "Password")
	submit := .SUBMIT in password_box(ui, a.delete_buf[:], &a.delete_len)
	submit |= .SUBMIT in mu.button(ctx, "Delete my account")
	if submit && a.delete_len > 0 {
		a.mistake = ""
		command(
			ui,
			conn.Account_Delete_Command {
				own = true,
				password = strings.clone(string(a.delete_buf[:a.delete_len])),
			},
		)
		wipe(a.delete_buf[:], &a.delete_len)
	}
	// A wrong password, say (afterwards it's the login screen that says
	// the account is gone).
	mu.layout_row(ctx, {FORM_LABEL, -1})
	mu.label(ctx, "")
	notice_label(ui, v)
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
		if !ok || .Deleted in acc.flags {
			continue
		}
		mu.push_id(ctx, uintptr(id))
		defer mu.pop_id(ctx)
		mu.layout_row(ctx, {-(140 + 3 * 90 + 4 * ctx.style.spacing), 140, 90, 90, 90})
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
		account_delete_confirm(ui, id, acc)
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

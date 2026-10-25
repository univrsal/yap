package client

import "client:conn"
import "client:platform"
import "client:settings"
import "common:proto"
import "core:fmt"
import "core:strings"
import "core:time"
import mu "vendor:microui"


// Accounts in the UI (conn/auth.odin is the network's end of it).
//
//   - The login screen, shown while connected to a server that doesn't know
//     this device yet: username and password, and whatever the server said
//     about the last attempt. Where the server takes registrations, it can
//     also be used to register instead, with whatever the server asks for.
//   - The screen that follows a login with a password an admin chose: the
//     password has to be replaced before anything else.
//   - The screen shown instead of everything else to an account whose email
//     address isn't verified yet: it explains how to verify it by sending an
//     email to the server (see proto/verify.odin).
//   - The Account section of the settings: our display name, our
//     password, the devices logged in to the account, and logging out.
//   - For whoever manages accounts, an Accounts section under it: the
//     existing accounts, creating one, and giving one a new password.
//
// Where the server doesn't take registrations, accounts are created by an
// admin.

UI_Account :: struct {
	// The login form, and how tall its card was in the last frame (see login_screen).
	card_h:        i32,
	username:      Text_Field(proto.MAX_USERNAME_SIZE),
	password:      Text_Field(proto.MAX_ACCOUNT_PASSWORD),
	// Registering instead: the password again, the email address and the
	// invite code, if the server asks for them.
	registering:   bool,
	reg_again:     Text_Field(proto.MAX_ACCOUNT_PASSWORD),
	reg_email:     Text_Field(proto.MAX_EMAIL_SIZE),
	invite:        Text_Field(proto.INVITE_CODE_SIZE + 8),
	// Fixing the address on the page that waits for it to be verified.
	// It starts out as the current address.
	verify:        Text_Field(proto.MAX_EMAIL_SIZE),
	verify_loaded: string, // what it was filled with; owned
	// Changing the password: the current one, the new one, and the new one again.
	old:           Text_Field(proto.MAX_ACCOUNT_PASSWORD),
	new:           Text_Field(proto.MAX_ACCOUNT_PASSWORD),
	again:         Text_Field(proto.MAX_ACCOUNT_PASSWORD),
	revoke_others: bool,
	// What is wrong with what was typed, found before the server is asked.
	mistake:       string, // static
	// Whether the name field (ui.name.buf) has been filled with our name, the
	// email field with our address, and the devices requested, since the settings
	// were opened.
	name_loaded:   bool,
	email:         Text_Field(proto.MAX_EMAIL_SIZE),
	// The name's or the email's Apply button was used. What the server made of
	// it is shown under them.
	profile_asked: bool,
	devices_asked: bool,
	// What the server had said by then isn't about anything asked since,
	// so only a notice newer than this one (View_Notice.count) is shown.
	notice:        Notice_Mark,
	// Creating an account.
	add_user:      Text_Field(proto.MAX_USERNAME_SIZE),
	add_name:      Text_Field(2 * proto.MAX_NAME_SIZE),
	add_pass:      Text_Field(proto.MAX_ACCOUNT_PASSWORD),
	// The accounts list (accounts_admin): the account picked in it (0: none),
	// whether the form to make one is showing instead, and its search.
	picked:        proto.Account_Id,
	creating:      bool,
	accounts_find: Pager,
	// The bot whose tokens are shown (see ui_bots.odin), 0 for none.
	bot_tokens:    proto.Account_Id,
	// Giving an account a new password: which account, and the password.
	set_account:   proto.Account_Id,
	set_pass:      Text_Field(proto.MAX_ACCOUNT_PASSWORD),
	// Deleting our own account: the password, typed again.
	delete:        Text_Field(proto.MAX_ACCOUNT_PASSWORD),
}

FORM_LABEL :: 130
FORM_FIELD :: 220
// The login screen's card: its width, its labels and the server's
// picture at the top.
LOGIN_CARD_WIDTH :: 400
LOGIN_LABEL :: 110
// When the space beside the label is narrower than this, a login field goes under its label.
LOGIN_FIELD_MIN :: 150
@(private = "file")
LOGIN_PICTURE :: 72

// ui_account_opened is called when the settings page is opened. It fetches
// the account's information again.
ui_account_opened :: proc(ui: ^UI) {
	ui.account.name_loaded = false
	ui.account.profile_asked = false
	ui.account.devices_asked = false
	ui.account.mistake = ""
	notice_mark_reset(&ui.account.notice)
	ui_invites_opened(ui)
	ui_memory_opened(ui)
}

// wipe clears a buffer that held a password.
wipe :: proc(buf: []u8, length: ^int) {
	for &b in buf {
		b = 0
	}
	length^ = 0
}

// login_screen is shown by a server that doesn't know this device, instead
// of its channels. Call with the View locked.
login_screen :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := ui.view
	a := &ui.account
	open := .Open in v.registration
	if !open {
		a.registering = false
	}
	registering := a.registering

	// A card in the middle: the server, as it describes itself, above the form.
	card_begin(ui, "login card", a.card_h)
	defer card_end(ui, &a.card_h)

	server := ui.session.server if ui.session != nil else v.server
	mu.layout_row(ctx, {-1}, LOGIN_PICTURE)
	pic := mu.layout_next(ctx)
	server_picture(
		ui,
		server,
		v,
		{pic.x + (pic.w - LOGIN_PICTURE) / 2, pic.y, LOGIN_PICTURE, LOGIN_PICTURE},
	)
	card_heading(ui, v.server_name if v.server_name != "" else server)
	if v.server_about != "" {
		mu.layout_row(ctx, {-1})
		with_text_color(ctx, theme.dim, v.server_about, wrap_text)
	}
	mu.layout_row(ctx, {-1}, ctx.style.spacing)
	mu.layout_next(ctx)

	working := v.login.state != .Needed
	submit := false
	// A label beside its field, or above it on a narrow phone.
	field :: proc(ui: ^UI, label: string) {
		field_row(ui, LOGIN_LABEL, label, {-1}, fill_min = LOGIN_FIELD_MIN)
	}
	field(ui, "Username")
	submit |= .SUBMIT in text_box(ui, a.username.buf[:], &a.username.len)
	field(ui, "Password")
	submit |= .SUBMIT in password_box(ui, a.password.buf[:], &a.password.len)
	if registering {
		field(ui, "Password again")
		submit |= .SUBMIT in password_box(ui, a.reg_again.buf[:], &a.reg_again.len)
		if .Email in v.registration {
			field(ui, "Email")
			submit |= .SUBMIT in text_box(ui, a.reg_email.buf[:], &a.reg_email.len)
		}
		if .Invite in v.registration {
			field(ui, "Invite code")
			submit |= .SUBMIT in text_box(ui, a.invite.buf[:], &a.invite.len)
		}
	}
	field(ui, "")
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
		field(ui, "")
		other := "Log in to an account instead" if registering else "Register an account instead"
		if .SUBMIT in mu.button(ctx, other) {
			a.registering = !registering
			a.mistake = ""
		}
	}

	mu.layout_row(ctx, {-1})
	switch {
	case a.mistake != "":
		with_text_color(ctx, theme.error, a.mistake, wrap_text)
	case v.login.error != "":
		with_text_color(ctx, theme.error, v.login.error, wrap_text)
	case !working && !open:
		with_text_color(
			ctx,
			theme.dim,
			"This server does not allow registrations. Ask an admin for an account.",
			wrap_text,
		)
	}

	if submit && !working && a.username.len > 0 && a.password.len > 0 {
		username := field_text(&a.username)
		password := field_text(&a.password)
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
					email = strings.clone(field_text(&a.reg_email)),
					invite = strings.clone(field_text(&a.invite)),
				},
			)
			wipe(a.reg_again.buf[:], &a.reg_again.len)
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
		wipe(a.password.buf[:], &a.password.len)
	}

}

// register_mistake checks what was typed for registering, before the server is
// asked, as far as that can be judged here. It returns false, with a.mistake
// saying why, if the input won't do.
@(private = "file")
register_mistake :: proc(ui: ^UI) -> bool {
	a := &ui.account
	v := ui.view
	a.mistake = ""
	name_buf: [proto.MAX_USERNAME_SIZE]u8
	password := field_text(&a.password)
	email := field_text(&a.reg_email)
	email_buf: [proto.MAX_EMAIL_SIZE]u8
	code_buf: [proto.INVITE_CODE_SIZE]u8
	switch {
	case !username_ok(field_text(&a.username), &name_buf):
		a.mistake = "A username is 2 to 32 of a-z 0-9 _ . - (no spaces)."
	case !proto.account_password_ok(password):
		a.mistake = "A password is 8 to 128 characters."
	case password != field_text(&a.reg_again):
		a.mistake = "The two passwords don't match."
	case .Email in v.registration && strings.trim_space(email) == "":
		a.mistake = "This server asks for an email address."
	case strings.trim_space(email) != "" && !email_ok(email, &email_buf):
		a.mistake = "That's no email address."
	case .Invite in v.registration && a.invite.len == 0:
		a.mistake = "This server asks for an invite code."
	case a.invite.len > 0 && !invite_ok(field_text(&a.invite), &code_buf):
		a.mistake = "That isn't a valid invite code. Invite codes consist of 10 letters and digits."
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

// verify_screen is all that an account with an unverified address gets: what
// to email to which address, a way to fix the address, and logging out. It
// continues by itself once the server has received the email. Call with the
// View locked.
verify_screen :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := ui.view
	a := &ui.account
	server := v.server_name if v.server_name != "" else v.server

	title_row(ui, {-1})
	mu.label(ctx, fmt.tprintf("Verify your email address for %s", server))
	mu.layout_row(ctx, {-1})
	wrap_text(
		ctx,
		"Send an email from your address to the server's address, with the code in the subject:",
	)

	mail_row := []i32{FORM_FIELD + 80, 90}
	field_row(ui, FORM_LABEL, "From", mail_row)
	mu.label(ctx, v.login.email)
	mu.label(ctx, "")
	field_row(ui, FORM_LABEL, "To", mail_row)
	mu.label(ctx, v.server_email if v.server_email != "" else "(the server hasn't said)")
	if .SUBMIT in stable_button(ctx, "copy_to", "Copy") {
		set_clipboard(nil, v.server_email)
	}
	field_row(ui, FORM_LABEL, "Subject", mail_row)
	mu.label(ctx, v.login.verify_code)
	if .SUBMIT in stable_button(ctx, "copy_code", "Copy") {
		set_clipboard(nil, v.login.verify_code)
	}
	field_row(ui, FORM_LABEL, "", mail_row)
	if .SUBMIT in stable_button(ctx, "mailto", "Open it in my email program") {
		platform.open_mailto(v.server_email, v.login.verify_code)
	}
	mu.label(ctx, "")

	mu.layout_row(ctx, {-1})
	with_text_color(
		ctx,
		theme.dim,
		"The server checks its mail about once a minute. This page continues by itself once your email has arrived.",
		wrap_text,
	)
	if v.login.verify_by != 0 {
		dt, _ := time.time_to_datetime(time.unix(i64(v.login.verify_by) / 1000, 0))
		local := chat_local_time(ui, dt)
		with_text_color(
			ctx,
			theme.warning,
			fmt.tprintf(
				"Without it, the account is deleted on %d-%02d-%02d at %02d:%02d.",
				local.year,
				local.month,
				local.day,
				local.hour,
				local.minute,
			),
			wrap_text,
		)
	}

	// Mistyped? Fix it here, which gives a new code.
	if a.verify_loaded != v.login.email {
		delete(a.verify_loaded)
		a.verify_loaded = strings.clone(v.login.email)
		field_set(&a.verify, v.login.email)
	}
	field_row(ui, FORM_LABEL, "Not your address?", {FORM_FIELD, 70})
	submitted := .SUBMIT in text_box(ui, a.verify.buf[:], &a.verify.len)
	if (.SUBMIT in mu.button(ctx, "Change") || submitted) && a.verify.len > 0 {
		a.mistake = ""
		a.profile_asked = true
		command(ui, conn.Email_Command{strings.clone(field_text(&a.verify))})
	}
	if a.profile_asked {
		mu.layout_row(ctx, {FORM_LABEL, -1})
		mu.label(ctx, "")
		notice_label(ui, v)
	}

	field_row(ui, FORM_LABEL, "", {140, -1})
	if .SUBMIT in mu.button(ctx, "Log out") {
		command(ui, conn.Logout_Command{})
	}
	with_text_color(ctx, theme.dim, "This device has to log in again afterwards.", wrap_text)

}

// password_screen is shown after a login with a password that somebody else
// chose. Nothing else is available until the password has been replaced. Call
// with the View locked.
password_screen :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := ui.view

	title_row(ui, {-1})
	mu.label(ctx, fmt.tprintf("Choose a password for %s", v.login.username))
	mu.layout_row(ctx, {-1})
	with_text_color(
		ctx,
		theme.dim,
		"The password you logged in with was set by an admin and can only be used to log in.",
		wrap_text,
	)
	password_form(ui, v, "Password you logged in with", false)

}

// password_form is the three fields and the button that change the
// password, and what came of it.
@(private = "file")
password_form :: proc(ui: ^UI, v: ^conn.View, old_label: string, offer_revoke: bool) {
	ctx := &ui.ctx
	a := &ui.account

	submit := false
	field_row(ui, FORM_LABEL + 60, old_label, {FORM_FIELD})
	submit |= .SUBMIT in password_box(ui, a.old.buf[:], &a.old.len)
	field_row(ui, FORM_LABEL + 60, "New password", {FORM_FIELD})
	submit |= .SUBMIT in password_box(ui, a.new.buf[:], &a.new.len)
	field_row(ui, FORM_LABEL + 60, "New password, again", {FORM_FIELD})
	submit |= .SUBMIT in password_box(ui, a.again.buf[:], &a.again.len)
	if offer_revoke {
		field_row(ui, FORM_LABEL + 60, "", {-1}, fill_min = 200)
		checkbox(ctx, "Log my other devices out", &a.revoke_others)
	}
	field_row(ui, FORM_LABEL + 60, "", {140, -1})
	submit |= .SUBMIT in mu.button(ctx, "Change password")
	notice_label(ui, v)

	if !submit {
		return
	}
	new := field_text(&a.new)
	switch {
	case new != field_text(&a.again):
		a.mistake = "The two new passwords don't match."
	case !proto.account_password_ok(new):
		a.mistake = "A password has to be at least 8 characters."
	case:
		a.mistake = ""
		command(
			ui,
			conn.Password_Command {
				old = strings.clone(field_text(&a.old)),
				new = strings.clone(new),
				revoke_others = offer_revoke && a.revoke_others,
			},
		)
		wipe(a.old.buf[:], &a.old.len)
		wipe(a.new.buf[:], &a.new.len)
		wipe(a.again.buf[:], &a.again.len)
	}
}

// notice_label shows what is wrong with what was typed or, if nothing is,
// what the server made of the last request.
notice_label :: proc(ui: ^UI, v: ^conn.View) {
	ctx := &ui.ctx
	_, _, fresh := notice_fresh(ui.account.notice, v)
	switch {
	case ui.account.mistake != "":
		with_text_color(ctx, theme.error, ui.account.mistake, label_proc)
	case fresh:
		with_text_color(
			ctx,
			theme.notice_ok if v.notice.ok else theme.error,
			v.notice.text,
			label_proc,
		)
	case:
		mu.label(ctx, "")
	}
}

SERVER_CATEGORY_NAMES := [Server_Category]string {
	.Server_Info = "Server",
	.Account     = "Account",
	.Channels    = "Channels",
	.Roles       = "Roles",
	.Accounts    = "Accounts",
	.Invites     = "Invite codes",
	.Purge       = "Purge history",
	.Memory      = "Memory",
}

// account_settings is our own account: its name, picture, status,
// password and devices, logging out and deleting it. Call with the View
// locked.
account_settings :: proc(ui: ^UI, v: ^conn.View) {
	ctx := &ui.ctx
	a := &ui.account
	me, known := v.accounts[v.me]
	if !known {
		return
	}

	mu.layout_row(ctx, {-1})
	with_text_color(ctx, theme.dim, fmt.tprintf("Logged in as %s", me.username), label_proc)

	if !a.name_loaded {
		a.name_loaded = true
		field_set(&ui.name, me.display)
		field_set(&a.email, v.login.email)
	}
	field_row(ui, FORM_LABEL, "Name", {FORM_FIELD, 70})
	submitted := .SUBMIT in text_box(ui, ui.name.buf[:], &ui.name.len)
	if (.SUBMIT in mu.button(ctx, "Apply") || submitted) && ui.name.len > 0 {
		a.mistake = ""
		a.profile_asked = true
		command(ui, conn.Display_Command{strings.clone(field_text(&ui.name))})
	}
	// It needs its own id, because the name's button also says Apply.
	mu.push_id(ctx, "email")
	field_row(ui, FORM_LABEL, "Email", {FORM_FIELD, 70})
	email_submitted := .SUBMIT in text_box(ui, a.email.buf[:], &a.email.len)
	if .SUBMIT in mu.button(ctx, "Apply") || email_submitted {
		a.mistake = ""
		a.profile_asked = true
		command(ui, conn.Email_Command{strings.clone(field_text(&a.email))})
	}
	mu.pop_id(ctx)
	if v.server_email != "" && .Owner not_in me.flags {
		mu.layout_row(ctx, {FORM_LABEL, -1})
		mu.label(ctx, "")
		with_text_color(
			ctx,
			theme.dim,
			"A new address has to be verified by mail before you can go on.",
			wrap_text,
		)
	}
	if a.profile_asked {
		mu.layout_row(ctx, {FORM_LABEL, -1})
		mu.label(ctx, "")
		notice_label(ui, v)
	}
	digest_settings(ui, v)
	push_settings(ui, v)
	profile_settings(ui)
	status_settings(ui)
	voice_shown_settings(ui, v)
	status_shared_settings(ui, v)

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

	field_row(ui, FORM_LABEL, "", {140, -1})
	if .SUBMIT in mu.button(ctx, "Log out") {
		command(ui, conn.Logout_Command{})
		ui.page = .Main
	}
	with_text_color(ctx, theme.dim, "This device has to log in again afterwards.", wrap_text)

	// Not the owner's, because somebody has to be the owner.
	if .Owner not_in me.flags {
		if .ACTIVE in mu.begin_treenode(ctx, "Delete this account") {
			delete_own_account(ui, v)
			mu.end_treenode(ctx)
		}
	}
}

@(private = "file", rodata)
DIGEST_LABELS := [proto.Email_Digest]string {
	.None     = "No emails",
	.Missed   = "Missed messages",
	.Mentions = "Mentions and direct messages",
}

// digest_settings is which emails this server sends us about what happened
// while we were away (see proto.SETTING_EMAIL_DIGEST), if it sends any. It is
// an account setting, so it is the same on all our devices, and it applies to this
// server only. Call with the View locked.
@(private = "file")
digest_settings :: proc(ui: ^UI, v: ^conn.View) {
	if !v.server_digests || !v.shared_synced {
		return
	}
	ctx := &ui.ctx
	current, _ := proto.email_digest_parse(v.shared[proto.SETTING_EMAIL_DIGEST] or_else "")
	field_row(ui, FORM_LABEL, "Email digests", {CHOICE_WIDTH})
	if choice, ok := enum_dropdown(ui, "digest", DIGEST_LABELS, current); ok {
		name := proto.EMAIL_DIGEST_NAMES[choice]
		command(
			ui,
			conn.Setting_Command {
				key = strings.clone(proto.SETTING_EMAIL_DIGEST),
				value = strings.clone("" if choice == .None else name),
			},
		)
	}
	hint := "Sent after you've been away for a while. Muted conversations are left out."
	if v.login.email == "" {
		hint = "These are sent to your email address, which you haven't set."
	}
	mu.layout_row(ctx, {FORM_LABEL, -1})
	mu.label(ctx, "")
	with_text_color(ctx, theme.dim, hint, wrap_text)
}

// voice_shown_settings is whether everyone else is shown a phone icon by our
// name while we are in a voice chat or a call (see proto.SETTING_VOICE_SHOWN).
// It is an account setting, so it is the same on all our devices, and it
// applies to this server only. Call with the View locked.
@(private = "file")
voice_shown_settings :: proc(ui: ^UI, v: ^conn.View) {
	if !v.shared_synced {
		return
	}
	ctx := &ui.ctx
	shown := (v.shared[proto.SETTING_VOICE_SHOWN] or_else "") != proto.VOICE_SHOWN_HIDDEN
	mu.layout_row(ctx, {FORM_LABEL, -1})
	mu.label(ctx, "")
	if .CHANGE in checkbox(ctx, "Show others when I'm in a voice chat or a call", &shown) {
		command(
			ui,
			conn.Setting_Command {
				key = strings.clone(proto.SETTING_VOICE_SHOWN),
				value = strings.clone("" if shown else proto.VOICE_SHOWN_HIDDEN),
			},
		)
	}
}

// status_shared_settings is whether our activity, status and talking in a
// voice chat or a call are shared between this server and our other servers
// (see conn.SETTING_STATUS_SHARED). It is an account setting, so it is the
// same on all our devices. Call with the View locked.
@(private = "file")
status_shared_settings :: proc(ui: ^UI, v: ^conn.View) {
	if !v.shared_synced {
		return
	}
	ctx := &ui.ctx
	shared := status_shared(v)
	mu.layout_row(ctx, {FORM_LABEL, -1})
	mu.label(ctx, "")
	if .CHANGE in checkbox(ctx, "Share my status with my other servers", &shared) {
		command(
			ui,
			conn.Setting_Command {
				key = strings.clone(conn.SETTING_STATUS_SHARED),
				value = strings.clone("" if shared else conn.STATUS_SHARED_OFF),
			},
		)
	}
	mu.layout_row(ctx, {FORM_LABEL, -1})
	mu.label(ctx, "")
	with_text_color(
		ctx,
		theme.dim,
		"Online, away, busy, your status text and being in a voice chat or a call are kept the same as on your other servers. Turn it off if this account has nothing to do with them.",
		wrap_text,
	)
}

// delete_own_account is the form for deleting our own account, which
// asks for the password again. Call with the View locked.
@(private = "file")
delete_own_account :: proc(ui: ^UI, v: ^conn.View) {
	ctx := &ui.ctx
	a := &ui.account
	mu.layout_row(ctx, {-1})
	with_text_color(
		ctx,
		theme.warning,
		fmt.tprintf(
			"This is permanent: your name, picture, status, roles and devices are deleted. What you wrote stays, under \"%s\".",
			proto.DELETED_NAME,
		),
		wrap_text,
	)
	field_row(ui, FORM_LABEL, "Password", {FORM_FIELD, 140})
	submit := .SUBMIT in password_box(ui, a.delete.buf[:], &a.delete.len)
	submit |= .SUBMIT in mu.button(ctx, "Delete my account")
	if submit && a.delete.len > 0 {
		a.mistake = ""
		command(
			ui,
			conn.Account_Delete_Command {
				own = true,
				password = strings.clone(field_text(&a.delete)),
			},
		)
		wipe(a.delete.buf[:], &a.delete.len)
	}
	// For example a wrong password (afterwards it is the login screen that says
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
		with_text_color(ctx, theme.dim, "Asking the server...", label_proc)
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
		// Show what it is and when it was last here. A device that is online
		// doesn't need to say so.
		detail := d.agent
		if .Online not_in d.flags && d.last_seen != 0 {
			seen := fmt.tprintf("last seen %s", ago_text(ui, i64(d.last_seen)))
			detail = fmt.tprintf("%s  -  %s", d.agent, seen) if d.agent != "" else seen
		}
		if detail != "" {
			mu.layout_row(ctx, {-1})
			with_text_color(ctx, theme.dim, detail, label_proc)
		}
	}
}

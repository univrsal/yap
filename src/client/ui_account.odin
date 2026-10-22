package client

import "client:conn"
import "client:platform"
import "client:settings"
import "common:proto"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"
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
	username_buf:  [proto.MAX_USERNAME_SIZE]u8,
	username_len:  int,
	password_buf:  [proto.MAX_ACCOUNT_PASSWORD]u8,
	password_len:  int,
	// Registering instead: the password again, the email address and the
	// invite code, if the server asks for them.
	registering:   bool,
	reg_again_buf: [proto.MAX_ACCOUNT_PASSWORD]u8,
	reg_again_len: int,
	reg_email_buf: [proto.MAX_EMAIL_SIZE]u8,
	reg_email_len: int,
	invite_buf:    [proto.INVITE_CODE_SIZE + 8]u8,
	invite_len:    int,
	// Fixing the address on the page that waits for it to be verified.
	// It starts out as the current address.
	verify_buf:    [proto.MAX_EMAIL_SIZE]u8,
	verify_len:    int,
	verify_loaded: string, // what it was filled with; owned
	// Changing the password: the current one, the new one, and the new one again.
	old_buf:       [proto.MAX_ACCOUNT_PASSWORD]u8,
	old_len:       int,
	new_buf:       [proto.MAX_ACCOUNT_PASSWORD]u8,
	new_len:       int,
	again_buf:     [proto.MAX_ACCOUNT_PASSWORD]u8,
	again_len:     int,
	revoke_others: bool,
	// What is wrong with what was typed, found before the server is asked.
	mistake:       string, // static
	// Whether the name field (ui.name_buf) has been filled with our name, the
	// email field with our address, and the devices requested, since the settings
	// were opened.
	name_loaded:   bool,
	email_buf:     [proto.MAX_EMAIL_SIZE]u8,
	email_len:     int,
	// The name's or the email's Apply button was used. What the server made of
	// it is shown under them.
	profile_asked: bool,
	devices_asked: bool,
	// What the server had said by then isn't about anything asked since,
	// so only a notice newer than this one (View_Notice.count) is shown.
	notice_reset:  bool,
	notice_seen:   int,
	// Creating an account.
	add_user_buf:  [proto.MAX_USERNAME_SIZE]u8,
	add_user_len:  int,
	add_name_buf:  [2 * proto.MAX_NAME_SIZE]u8,
	add_name_len:  int,
	add_pass_buf:  [proto.MAX_ACCOUNT_PASSWORD]u8,
	add_pass_len:  int,
	// The accounts list (accounts_admin): the account picked in it (0: none),
	// whether the form to make one is showing instead, and its search.
	picked:        proto.Account_Id,
	creating:      bool,
	accounts_find: Pager,
	// The bot whose tokens are shown (see ui_bots.odin), 0 for none.
	bot_tokens:    proto.Account_Id,
	// Giving an account a new password: which account, and the password.
	set_account:   proto.Account_Id,
	set_pass_buf:  [proto.MAX_ACCOUNT_PASSWORD]u8,
	set_pass_len:  int,
	// Deleting our own account: the password, typed again.
	delete_buf:    [proto.MAX_ACCOUNT_PASSWORD]u8,
	delete_len:    int,
}

FORM_LABEL :: 130
FORM_FIELD :: 220
// The login screen's card: its width, its labels and the server's
// picture at the top.
@(private = "file")
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
	ui.account.notice_reset = true
	ui_invites_opened(ui)
	ui_memory_opened(ui)
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

// card_begin starts a card in the middle of what is left of the main
// window, as the login screen has. It is LOGIN_CARD_WIDTH wide (or as wide as
// the space allows) and as tall as `h`, which holds its height in the last
// frame (as tall as possible the first time). It scrolls if it doesn't fit.
// card_end ends it and stores its height in `h`.
card_begin :: proc(ui: ^UI, name: string, h: i32) {
	ctx := &ui.ctx
	mu.layout_row(ctx, {-1}, -1)
	area := mu.layout_next(ctx)
	w := min(area.w, LOGIN_CARD_WIDTH)
	ch := area.h if h <= 0 else min(h, area.h)
	mu.layout_set_next(ctx, {area.x + (area.w - w) / 2, area.y + (area.h - ch) / 2, w, ch}, false)
	mu.begin_panel(ctx, name)
}

card_end :: proc(ui: ^UI, h: ^i32) {
	ctx := &ui.ctx
	cnt := mu.get_current_container(ctx)
	mu.end_panel(ctx)
	h^ = cnt.content_size.y + 2 * ctx.style.padding
}

// card_heading is a row with `text` in the middle of a card.
card_heading :: proc(ui: ^UI, text: string) {
	ctx := &ui.ctx
	mu.layout_row(ctx, {-1})
	mu.draw_control_text(ctx, text, mu.layout_next(ctx), .TEXT, {.ALIGN_CENTER})
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
	submit |= .SUBMIT in text_box(ui, a.username_buf[:], &a.username_len)
	field(ui, "Password")
	submit |= .SUBMIT in password_box(ui, a.password_buf[:], &a.password_len)
	if registering {
		field(ui, "Password again")
		submit |= .SUBMIT in password_box(ui, a.reg_again_buf[:], &a.reg_again_len)
		if .Email in v.registration {
			field(ui, "Email")
			submit |= .SUBMIT in text_box(ui, a.reg_email_buf[:], &a.reg_email_len)
		}
		if .Invite in v.registration {
			field(ui, "Invite code")
			submit |= .SUBMIT in text_box(ui, a.invite_buf[:], &a.invite_len)
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
		a.mistake = "The two passwords don't match."
	case .Email in v.registration && strings.trim_space(email) == "":
		a.mistake = "This server asks for an email address."
	case strings.trim_space(email) != "" && !email_ok(email, &email_buf):
		a.mistake = "That's no email address."
	case .Invite in v.registration && a.invite_len == 0:
		a.mistake = "This server asks for an invite code."
	case a.invite_len > 0 && !invite_ok(string(a.invite_buf[:a.invite_len]), &code_buf):
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
		a.verify_len = copy(a.verify_buf[:], v.login.email)
	}
	field_row(ui, FORM_LABEL, "Not your address?", {FORM_FIELD, 70})
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
	submit |= .SUBMIT in password_box(ui, a.old_buf[:], &a.old_len)
	field_row(ui, FORM_LABEL + 60, "New password", {FORM_FIELD})
	submit |= .SUBMIT in password_box(ui, a.new_buf[:], &a.new_len)
	field_row(ui, FORM_LABEL + 60, "New password, again", {FORM_FIELD})
	submit |= .SUBMIT in password_box(ui, a.again_buf[:], &a.again_len)
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
	new := string(a.new_buf[:a.new_len])
	switch {
	case new != string(a.again_buf[:a.again_len]):
		a.mistake = "The two new passwords don't match."
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

// notice_label shows what is wrong with what was typed or, if nothing is,
// what the server made of the last request.
notice_label :: proc(ui: ^UI, v: ^conn.View) {
	ctx := &ui.ctx
	switch {
	case ui.account.mistake != "":
		with_text_color(ctx, theme.error, ui.account.mistake, label_proc)
	case v.notice.text != "" && v.notice.count > ui.account.notice_seen:
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

// The server tab's categories, in the order they are listed.
Server_Category :: enum {
	Server_Info,
	Account,
	Channels,
	Roles,
	Accounts,
	Invites,
	Purge,
	Memory,
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

// server_settings_categories returns which of the server tab's categories
// we may see: our account, and what we may manage (the server's name and
// picture only if it's ours). Call with the View locked.
server_settings_categories :: proc(v: ^conn.View) -> (c: bit_set[Server_Category]) {
	c += {.Account}
	if me, known := v.accounts[v.me]; known && .Owner in me.flags {
		c += {.Server_Info, .Memory}
	}
	if v.permissions & {.Create_Channels, .Manage_Channels} != {} {
		c += {.Channels}
	}
	if .Manage_Roles in v.permissions {
		c += {.Roles}
	}
	if v.permissions & {.Manage_Accounts, .Manage_Roles} != {} {
		c += {.Accounts}
	}
	if v.permissions & {.Create_Invites, .Manage_Accounts} != {} {
		c += {.Invites}
	}
	if .Purge in v.permissions {
		c += {.Purge}
	}
	return
}

// server_category_opened is called when a category of the server tab
// has just been picked.
server_category_opened :: proc(ui: ^UI, c: Server_Category) {
	#partial switch c {
	case .Roles:
		ui.roles.notice_seen = -1 // taken from the View when it's next locked
	case .Channels:
		channels_category_opened(ui) // ui_channel_settings.odin
	}
}

// server_settings is the settings page's server tab, with the category `c`
// selected: our account and, for those who manage accounts, the roles, everybody's
// accounts, invite codes and purging. The settings page doesn't hold the
// View's lock, so it is taken here.
server_settings :: proc(ui: ^UI, c: Server_Category) {
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
	switch c {
	case .Server_Info:
		server_info_settings(ui, v) // ui_server_info.odin
	case .Account:
		account_settings(ui, v)
	case .Channels:
		channels_settings(ui) // ui_channel_settings.odin
	case .Roles:
		roles_settings(ui)
	case .Accounts:
		accounts_admin(ui, v)
	case .Invites:
		invites_settings(ui, v)
	case .Purge:
		purge_settings(ui)
	case .Memory:
		server_memory_settings(ui, v) // ui_memory.odin
	}
}

// account_settings is our own account: its name, picture, status,
// password and devices, logging out and deleting it. Call with the View
// locked.
@(private = "file")
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
		ui.name_len = copy(ui.name_buf[:], me.display)
		a.email_len = copy(a.email_buf[:], v.login.email)
	}
	field_row(ui, FORM_LABEL, "Name", {FORM_FIELD, 70})
	submitted := .SUBMIT in text_box(ui, ui.name_buf[:], &ui.name_len)
	if (.SUBMIT in mu.button(ctx, "Apply") || submitted) && ui.name_len > 0 {
		a.mistake = ""
		a.profile_asked = true
		command(ui, conn.Display_Command{strings.clone(string(ui.name_buf[:ui.name_len]))})
	}
	// It needs its own id, because the name's button also says Apply.
	mu.push_id(ctx, "email")
	field_row(ui, FORM_LABEL, "Email", {FORM_FIELD, 70})
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

// The Accounts category: the accounts on the left, a page at a time and narrowed
// down by name, and the one picked on the right, with what may be done to it.
// With none picked, the right-hand side is for making one.
@(private = "file")
ACCOUNTS_LIST_WIDTH :: 230
@(private = "file")
ACCOUNT_EDITOR_MIN :: 330

@(private = "file")
accounts_admin :: proc(ui: ^UI, v: ^conn.View) {
	ctx := &ui.ctx
	a := &ui.account
	if acc, ok := v.accounts[a.picked]; a.picked != 0 && (!ok || .Deleted in acc.flags) {
		a.picked = 0 // gone
	}

	// When narrow, the list and the account picked take turns, as roles do.
	if row_room(ctx) < ACCOUNTS_LIST_WIDTH + ACCOUNT_EDITOR_MIN {
		if a.picked == 0 && !a.creating {
			mu.layout_row(ctx, {-1}, -1)
			mu.begin_panel(ctx, "account list")
			accounts_list(ui, v)
			mu.end_panel(ctx)
			return
		}
		mu.layout_row(ctx, {40, -1})
		if .SUBMIT in icon_button(ui, "to account list", .Back, "Accounts") {
			account_pick(ui, 0)
		}
		mu.label(ctx, v.accounts[a.picked].username if a.picked != 0 else "New account")
		mu.layout_row(ctx, {-1}, -1)
		mu.begin_panel(ctx, "account")
		account_detail(ui, v)
		mu.end_panel(ctx)
		return
	}

	mu.layout_row(ctx, {ACCOUNTS_LIST_WIDTH, -1}, -1)
	mu.begin_panel(ctx, "account list")
	accounts_list(ui, v)
	mu.end_panel(ctx)
	mu.begin_panel(ctx, "account")
	account_detail(ui, v)
	mu.end_panel(ctx)
}

// account_pick picks an account in the list (0: none), leaving whatever was
// being done to the one before.
@(private = "file")
account_pick :: proc(ui: ^UI, id: proto.Account_Id) {
	a := &ui.account
	a.creating = false
	if a.picked == id {
		return
	}
	a.picked = id
	a.bot_tokens = 0
	if a.set_account != 0 {
		wipe(a.set_pass_buf[:], &a.set_pass_len)
		a.set_account = 0
	}
	ui.manage.account, ui.manage.delete_account = 0, 0
}

// accounts_list is the left-hand side: the accounts that match the search, by
// username, a page of them.
@(private = "file")
accounts_list :: proc(ui: ^UI, v: ^conn.View) {
	ctx := &ui.ctx
	a := &ui.account
	pager_search(ui, &a.accounts_find, "Find an account")
	query := pager_query(&a.accounts_find)
	ids := make([dynamic]proto.Account_Id, 0, len(v.accounts), context.temp_allocator)
	for id, acc in v.accounts {
		if .Deleted not_in acc.flags && pager_matches(query, acc.display, acc.username) {
			append(&ids, id)
		}
	}
	context.user_ptr = v
	slice.sort_by(ids[:], proc(x, y: proto.Account_Id) -> bool {
		v := (^conn.View)(context.user_ptr)
		a, b := v.accounts[x], v.accounts[y]
		if c := strings.compare(
			strings.to_lower(a.username, context.temp_allocator),
			strings.to_lower(b.username, context.temp_allocator),
		); c != 0 {
			return c < 0
		}
		return x < y
	})
	if len(ids) == 0 {
		mu.layout_row(ctx, {-1})
		with_text_color(ctx, theme.dim, "Nobody by that name.", label_proc)
	}
	lo, hi := pager_window(&a.accounts_find, len(ids))
	for id in ids[lo:hi] {
		acc := v.accounts[id]
		mu.push_id(ctx, uintptr(id))
		defer mu.pop_id(ctx)
		mu.layout_row(ctx, {-1})
		saved := ctx.style.colors[.TEXT]
		if .Disabled in acc.flags {
			ctx.style.colors[.TEXT] = theme.dim
		}
		if .SUBMIT in list_row(ctx, "account", account_line(acc), a.picked == id) {
			account_pick(ui, id)
		}
		ctx.style.colors[.TEXT] = saved
	}
	pager_footer(ui, &a.accounts_find, len(ids))

	if .Manage_Accounts in v.permissions {
		mu.layout_row(ctx, {-1})
		mu.label(ctx, "")
		if .SUBMIT in stable_button(ctx, "new account", "New account...", {.ALIGN_CENTER}) {
			account_pick(ui, 0)
			a.creating = true
		}
	}
}

// account_line is how an account is listed: its username, its name if that is
// different, and what kind of account it is.
@(private = "file")
account_line :: proc(acc: conn.View_Account) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, acc.username)
	if acc.display != "" && acc.display != acc.username {
		fmt.sbprintf(&b, "  %s", acc.display)
	}
	switch {
	case .Owner in acc.flags:
		strings.write_string(&b, "  (owner)")
	case .Disabled in acc.flags:
		strings.write_string(&b, "  (disabled)")
	}
	if .Bot in acc.flags {
		strings.write_string(&b, "  (bot)")
	}
	return strings.to_string(b)
}

// account_detail is the right-hand side: the account picked, or making one.
@(private = "file")
account_detail :: proc(ui: ^UI, v: ^conn.View) {
	ctx := &ui.ctx
	a := &ui.account
	// A bot's token that was just made, wherever it was made from.
	if .Manage_Accounts in v.permissions {
		bot_token_shown(ui, v)
	}
	acc, ok := v.accounts[a.picked]
	if a.picked == 0 || !ok {
		if .Manage_Accounts in v.permissions {
			account_create(ui, v)
		} else {
			mu.layout_row(ctx, {-1})
			with_text_color(
				ctx,
				theme.dim,
				"Pick an account to see and change its roles.",
				label_proc,
			)
		}
		return
	}
	id := a.picked

	mu.layout_row(ctx, {-1})
	mu.label(ctx, account_line(acc))
	roles := make([dynamic]string, context.temp_allocator)
	for r in acc.roles {
		for vr in v.roles {
			if vr.id == r {
				append(&roles, vr.name)
			}
		}
	}
	about := "No roles."
	if len(roles) > 0 {
		about = fmt.tprintf("Roles: %s", strings.join(roles[:], ", ", context.temp_allocator))
	}
	with_text_color(ctx, theme.dim, about, wrap_text)
	if invited := invited_by_line(ui, v, id); invited != "" {
		with_text_color(ctx, theme.dim, invited, wrap_text)
	}

	// Its password, or a bot's tokens. The owner's password is the owner's
	// to change, as their own.
	manage := .Manage_Accounts in v.permissions && .Owner not_in acc.flags && below_us(v, acc)
	if manage && .Bot in acc.flags {
		mu.layout_row(ctx, {-1})
		mu.label(ctx, "")
		mu.label(ctx, "Tokens")
		if a.bot_tokens != id {
			a.bot_tokens = id
			command(ui, conn.Devices_Command{account = id})
		}
		bot_tokens(ui, v, id)
	} else if manage {
		account_password(ui, id, acc)
	}

	account_roles_editor(ui, id, acc) // ui_manage.odin
	account_manage(ui, id, acc)
	account_delete_confirm(ui, id, acc)
	mu.layout_row(ctx, {-1})
	notice_label(ui, v)
}

// account_password gives an account a new password, once New password... has
// been pressed.
@(private = "file")
account_password :: proc(ui: ^UI, id: proto.Account_Id, acc: conn.View_Account) {
	ctx := &ui.ctx
	a := &ui.account
	if a.set_account != id {
		field_row(ui, FORM_LABEL, "Password", {140})
		if .SUBMIT in stable_button(ctx, "setpass", "New password...") {
			a.set_account = id
			wipe(a.set_pass_buf[:], &a.set_pass_len)
		}
		return
	}
	field_row(ui, FORM_LABEL, "New password", {FORM_FIELD, 60, 70})
	submitted := .SUBMIT in password_box(ui, a.set_pass_buf[:], &a.set_pass_len)
	if (.SUBMIT in mu.button(ctx, "Set") || submitted) && a.set_pass_len > 0 {
		a.mistake = ""
		command(
			ui,
			conn.Account_Password_Command {
				account = id,
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
		theme.warning,
		fmt.tprintf(
			"It logs %s's devices out, and they have to choose their own on logging in.",
			acc.username,
		),
		wrap_text,
	)
}

// account_create is the form for making an account, or a bot's.
@(private = "file")
account_create :: proc(ui: ^UI, v: ^conn.View) {
	ctx := &ui.ctx
	a := &ui.account
	mu.layout_row(ctx, {-1})
	mu.label(ctx, "Create an account")
	submit := false
	field_row(ui, FORM_LABEL, "Username", {FORM_FIELD})
	submit |= .SUBMIT in text_box(ui, a.add_user_buf[:], &a.add_user_len)
	field_row(ui, FORM_LABEL, "Name", {FORM_FIELD})
	submit |= .SUBMIT in text_box(ui, a.add_name_buf[:], &a.add_name_len)
	field_row(ui, FORM_LABEL, "Initial password", {FORM_FIELD})
	submit |= .SUBMIT in password_box(ui, a.add_pass_buf[:], &a.add_pass_len)
	field_row(ui, FORM_LABEL, "", {140, 140, -1})
	submit |= .SUBMIT in mu.button(ctx, "Create account")
	// A bot takes no password. It gets a token (see ui_bots.odin).
	bot := .SUBMIT in mu.button(ctx, "Create bot")
	notice_label(ui, v)
	if bot && a.add_user_len > 0 {
		a.mistake = ""
		command(
			ui,
			conn.Bot_Create_Command {
				username = strings.clone(string(a.add_user_buf[:a.add_user_len])),
				display = strings.clone(string(a.add_name_buf[:a.add_name_len])),
			},
		)
		wipe(a.add_pass_buf[:], &a.add_pass_len)
		a.add_user_len, a.add_name_len = 0, 0
	} else if submit && a.add_user_len > 0 {
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

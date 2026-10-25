package conn

import log "common:wlog"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"

import "client:platform"
import "common:proto"

// Our account on the server (src/common/proto/accounts.odin): logging in, the
// accounts the server tells us about, and what we can ask it to do with them.
//
// A connection starts out not logged in, unless the server already knows this
// device, which the Welcome message tells us. Until we are logged in, the server
// accepts nothing from us except a login, so everything else waits. No
// snapshots arrive, and anything we send is dropped.
//
// Once we are logged in, the server sends the directory: every account,
// followed by Self, which says which of the accounts is ours and what we are
// allowed to do. Self is also what finishes a login here (Login_State.Done).
//
// Names come from the directory: a connection in the snapshot says which
// account it belongs to, and the account has the name (see display_name).

Login_State :: enum {
	Unknown, // not connected far enough to know yet
	Needed, // the server doesn't know this device, so a login is needed
	Working, // a login was requested, or we are logged in and waiting to be told who we are
	Done,
}

// An account as the server told us about it.
Dir_Account :: struct {
	username:     string, // owned
	display:      string, // owned
	flags:        proto.Account_Flags,
	status:       string, // owned; "" if there is none (see profiles.odin)
	status_until: proto.Unix_Ms,
	avatar:       proto.Blob_Id,
	roles:        []proto.Role_Id, // owned; excluding the everyone role (see roles.odin)
	activity:     proto.Activity, // as everyone sees it (see activity.odin)
}

Auth_Client :: struct {
	state:       Login_State,
	error:       string, // the reason why we are not logged in, if there is one; owned
	me:          proto.Account_Id,
	permissions: proto.Permissions,
	flags:       proto.Account_Flags, // ours, as reported in Self
	// The activity we chose, as reported in Self, and whether our user is idle
	// and the client is out of sight, as last reported to the server (see
	// activity.odin).
	chosen:      proto.Activity,
	idle:        bool,
	hidden:      bool,
	// When we chose the activity and set our status, as reported in Self
	// (0 if the server doesn't say). See the UI's status_sync.
	chosen_at:   proto.Unix_Ms,
	status_at:   proto.Unix_Ms,
	email:       string, // ours, as reported in Self; owned
	// While our email address is not verified: the code that a mail to the
	// server has to contain (owned), and when the account is removed if it
	// wasn't verified.
	verify_code: string,
	verify_by:   proto.Unix_Ms,
	accounts:    map[proto.Account_Id]Dir_Account,
	roles:       map[proto.Role_Id]Dir_Role, // see roles.odin
	// What to log in with as soon as the server asks for it. These are given
	// when the client is started, or are the last ones that worked. Owned.
	username:    string,
	password:    string,
	device:      string,
	// Our account's devices as of the last time we asked.
	devices:     [dynamic]Dir_Device,
	// A bot's token that is on its way to the server (see bots.odin); owned.
	bot_token:   string,
}

Dir_Device :: struct {
	key:       [proto.KEY_SIZE]u8,
	name:      string, // owned
	agent:     string, // owned; "" if the server didn't tell us
	created:   u64,
	last_seen: u64,
	flags:     proto.Device_Flags,
}

// What the UI sees of the login.
View_Login :: struct {
	state:       Login_State,
	error:       string, // owned
	must_change: bool, // logged in, but the password has to be changed first
	username:    string, // ours, once logged in; owned
	email:       string, // ours, "" if there is none; owned
	// Our email address has not been verified yet (see proto/verify.odin), and
	// nothing else works until it is. The code that the mail has to contain
	// (owned), and when the account is deleted if it isn't verified (0 means
	// it isn't deleted).
	unverified:  bool,
	verify_code: string,
	verify_by:   proto.Unix_Ms,
}

View_Account :: struct {
	username:     string, // owned
	display:      string, // owned
	flags:        proto.Account_Flags,
	status:       string, // owned; "" if there is none
	status_until: proto.Unix_Ms,
	avatar:       proto.Blob_Id, // 0 if there is none
	roles:        []proto.Role_Id, // owned; excluding the everyone role
	activity:     proto.Activity, // as everyone sees it
}

// The result of the last request about accounts, for the UI to show.
View_Notice :: struct {
	text:  string, // owned
	ok:    bool,
	count: int, // incremented with each notice, so the UI can tell when there is a new one
	at:    time.Tick, // when the notice arrived
}

// Logs in with a username and password. `device` is the name this device gets
// in the account's device list.
Login_Command :: struct {
	username: string, // owned by the command
	password: string, // owned by the command
	device:   string, // owned by the command
}
// Creates an account (if the server accepts registrations) and logs in to it,
// like Login_Command. `email` and `invite` are "" if there is none.
Register_Command :: struct {
	username: string, // owned by the command
	password: string, // owned by the command
	device:   string, // owned by the command
	email:    string, // owned by the command
	invite:   string, // owned by the command
}
// Logs this device out, so it has to log in again.
Logout_Command :: struct {}
Password_Command :: struct {
	old:           string, // owned by the command
	new:           string, // owned by the command
	revoke_others: bool,
}
// Changes the display name of our account.
Display_Command :: struct {
	name: string, // owned by the command
}
// Changes our account's email address; "" removes it.
Email_Command :: struct {
	email: string, // owned by the command
}
// Requests our account's devices, or those of another account if one is given.
// This is only for users with permission to do so, for example to list a bot's
// tokens (see bots.odin).
Devices_Command :: struct {
	account: proto.Account_Id,
}
Revoke_Command :: struct {
	key: [proto.KEY_SIZE]u8,
}
// Creates an account (only for users with permission to do so).
Account_Create_Command :: struct {
	username: string, // owned by the command
	password: string, // owned by the command
	display:  string, // owned by the command
}
// Gives an account a new password (only for users with permission to do so).
// The account is identified by id, or by username if the id is 0.
Account_Password_Command :: struct {
	account:  proto.Account_Id,
	username: string, // owned by the command
	password: string, // owned by the command
}

auth_destroy :: proc(c: ^Server_Conn) {
	a := &c.auth
	accounts_clear(a)
	delete(a.accounts)
	roles_clear(a)
	delete(a.roles)
	devices_clear(a)
	delete(a.devices)
	bot_token_wipe(c)
	delete(a.error)
	delete(a.username)
	delete(a.email)
	delete(a.verify_code)
	forget_password(a)
	delete(a.device)
	a^ = {}
}

@(private = "file")
accounts_clear :: proc(a: ^Auth_Client) {
	for _, acc in a.accounts {
		delete(acc.username)
		delete(acc.display)
		delete(acc.status)
		delete(acc.roles)
	}
	clear(&a.accounts)
}

@(private = "file")
devices_clear :: proc(a: ^Auth_Client) {
	for d in a.devices {
		delete(d.name)
		delete(d.agent)
	}
	clear(&a.devices)
}

@(private = "file")
forget_password :: proc(a: ^Auth_Client) {
	if a.password != "" {
		// Don't leave the password behind in freed memory.
		raw := transmute([]u8)a.password
		for &b in raw {
			b = 0
		}
	}
	delete(a.password)
	a.password = ""
}

// auth_credentials sets what to log in with when the server asks for it. It is
// called before the connection is opened.
auth_credentials :: proc(c: ^Server_Conn, username, password, device: string) {
	a := &c.auth
	delete(a.username)
	forget_password(a)
	delete(a.device)
	// Normalize it the way the server expects it, if it can be a valid username at all.
	name_buf: [proto.MAX_USERNAME_SIZE]u8
	if clean, ok := proto.username_clean(username, &name_buf); ok {
		a.username = strings.clone(clean)
	} else {
		a.username = strings.clone(username)
	}
	a.password = strings.clone(password)
	a.device = strings.clone(device)
}

@(private = "file")
set_state :: proc(c: ^Server_Conn, state: Login_State, error := "") {
	a := &c.auth
	a.state = state
	delete(a.error)
	a.error = strings.clone(error)
	publish_login(c)
}

// auth_restart is called at the start of a new connection (see handle_welcome),
// because what we knew about the accounts is gone together with the old
// connection. If the server knows this device, it has logged us in and the
// directory is on its way. Otherwise we log in with the credentials we were
// given, or wait to be given some.
auth_restart :: proc(c: ^Server_Conn, logged_in: bool) {
	a := &c.auth
	accounts_clear(a)
	devices_clear(a)
	a.me, a.permissions, a.flags = 0, {}, {}
	publish_directory(c)
	switch {
	case logged_in:
		set_state(c, .Working)
	case a.username != "" && a.password != "":
		login_send(c)
	case:
		log.infof("%s wants a login", c.server_addr)
		set_state(c, .Needed)
	}
}

// auth_register creates an account and logs in to it. The credentials it was
// created with are kept like those of a login, so that if the connection
// restarts before the answer arrives, the new connection logs in with them.
auth_register :: proc(c: ^Server_Conn, cmd: Register_Command) {
	if c.auth.state != .Needed {
		return
	}
	auth_credentials(c, cmd.username, cmd.password, cmd.device)
	a := &c.auth
	buf: [proto.REGISTER_BODY_MAX]u8
	body := proto.encode_register(
		buf[:],
		{
			username = a.username,
			password = a.password,
			device = a.device,
			email = cmd.email,
			invite = cmd.invite,
			agent = platform.agent(),
		},
	)
	if body == nil {
		forget_password(a)
		set_state(c, .Needed, "One of the fields is too long.")
		return
	}
	set_state(c, .Working)
	request(c, .Register, body, register_done)
}

@(private = "file")
register_done :: proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
	a := &c.auth
	#partial switch status {
	case .Ok:
		log.infof("registered at %s as %s", c.server_addr, a.username)
		forget_password(a)
		return
	case .Reset:
		return
	case .Rate_Limited:
		forget_password(a)
		set_state(c, .Needed, "Too many registration attempts. Wait a moment and try again.")
		return
	}
	forget_password(a)
	reason, known := proto.decode_register_refusal(body)
	if !known {
		log.warnf("%s: registering failed: %v", c.server_addr, status)
		set_state(
			c,
			.Needed,
			fmt.tprintf("The server failed to register your account (%v).", status),
		)
		return
	}
	set_state(c, .Needed, register_refusal_text(reason))
}

// username_rule and password_rule say what a username and a password have to
// be, for when one isn't.
username_rule :: proc() -> string {
	return fmt.tprintf(
		"A username must be %d to %d characters long and can only contain a-z, 0-9, _, . and -.",
		proto.MIN_USERNAME_SIZE,
		proto.MAX_USERNAME_SIZE,
	)
}

password_rule :: proc() -> string {
	return fmt.tprintf(
		"A password must be %d to %d characters long.",
		proto.MIN_ACCOUNT_PASSWORD,
		proto.MAX_ACCOUNT_PASSWORD,
	)
}

register_refusal_text :: proc(reason: proto.Register_Refusal) -> string {
	switch reason {
	case .Closed:
		return "This server does not accept registrations."
	case .Username:
		return username_rule()
	case .Username_Taken:
		return "That username is already taken."
	case .Password:
		return password_rule()
	case .Email_Missing:
		return "This server requires an email address."
	case .Email:
		return "That is not a valid email address."
	case .Email_Taken:
		return "Another account already uses that email address."
	case .Invite_Missing:
		return "This server requires an invite code."
	case .Invite:
		return "That invite code is invalid. It is unknown, used up, expired or revoked."
	}
	return ""
}

// auth_login logs in with a username and password.
auth_login :: proc(c: ^Server_Conn, cmd: Login_Command) {
	if c.auth.state != .Needed {
		return
	}
	auth_credentials(c, cmd.username, cmd.password, cmd.device)
	login_send(c)
}

@(private = "file")
login_send :: proc(c: ^Server_Conn) {
	a := &c.auth
	buf: [proto.ACCOUNT_BODY_MAX]u8
	body := proto.encode_auth_login(buf[:], a.username, a.password, a.device, platform.agent())
	if body == nil {
		forget_password(a)
		set_state(c, .Needed, "The username or password is too long.")
		return
	}
	set_state(c, .Working)
	request(c, .Auth_Login, body, login_done)
}

@(private = "file")
login_done :: proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
	a := &c.auth
	#partial switch status {
	case .Ok:
		// Self, which the server sends next, tells us the rest. The password has
		// done its part, and from here on the device's key is enough.
		log.infof("logged in to %s as %s", c.server_addr, a.username)
		forget_password(a)
	case .Reset:
	// The connection restarted, and auth_restart takes it from there.
	case .Wrong_Password:
		log.warnf("%s: wrong username or password", c.server_addr)
		forget_password(a)
		set_state(c, .Needed, "Wrong username or password.")
	case .Rate_Limited:
		forget_password(a)
		set_state(c, .Needed, "Too many login attempts. Wait a moment and try again.")
	case .Denied:
		forget_password(a)
		set_state(c, .Needed, "This account is disabled.")
	case:
		log.warnf("%s: login failed: %v", c.server_addr, status)
		forget_password(a)
		set_state(c, .Needed, fmt.tprintf("The server failed to log you in (%v).", status))
	}
}

// auth_logged_out puts us back into the state where a login is needed, as it is
// on the server. We are in no channel anymore, and there is nothing to show of
// the server except the login.
@(private = "file")
auth_logged_out :: proc(c: ^Server_Conn, why: string) {
	a := &c.auth
	forget_password(a)
	accounts_clear(a)
	devices_clear(a)
	a.me, a.permissions, a.flags = 0, {}, {}
	convs_restart(c, forget = true)
	channels_restart(c)
	messages_restart(c, forget = true)
	calls_restart(c)
	buddies_begin(c)
	publish_logged_out(c)
	set_state(c, .Needed, why)
}

auth_logout :: proc(c: ^Server_Conn) {
	if c.auth.state != .Done {
		return
	}
	request(
		c,
		.Auth_Logout,
		nil,
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			if status == .Ok {
				log.info("logged out")
				auth_logged_out(c, "")
			}
		},
	)
}

// auth_event handles an event about accounts. It returns false if `op` is not
// an account event.
auth_event :: proc(c: ^Server_Conn, op: proto.Event_Op, body: []u8) -> bool {
	a := &c.auth
	#partial switch op {
	case .Sync_Begin:
		accounts_clear(a)
		roles_clear(a)
		convs_begin(c)
		buddies_begin(c)
		shared_begin(c)
	case .Account_Changed:
		record, ok := proto.decode_account(body)
		if !ok {
			log.warn("the server sent an account that could not be decoded")
			break
		}
		_, acc, _, _ := map_entry(&a.accounts, record.id)
		was_status := strings.clone(acc.status, context.temp_allocator)
		was_muted := .Server_Muted in acc.flags
		delete(acc.username)
		delete(acc.display)
		delete(acc.status)
		delete(acc.roles)
		acc^ = {
			username     = strings.clone(record.username),
			display      = strings.clone(record.display),
			flags        = record.flags,
			status       = strings.clone(record.status),
			status_until = record.status_until,
			avatar       = record.avatar,
			roles        = slice.clone(record.roles),
			activity     = record.activity,
		}
		if a.state == .Done && was_status != record.status {
			report_status(c, record.display, record.status, record.status_until)
		}
		if a.state == .Done && record.id == a.me {
			server_mute_changed(c, was_muted, .Server_Muted in record.flags)
		}
		publish_directory(c)
	case .Self:
		me, permissions, flags, ok := proto.decode_self(body)
		if !ok {
			break
		}
		a.me, a.permissions, a.flags = me, permissions, flags
		a.chosen = proto.self_activity(body)
		a.chosen_at, a.status_at = proto.self_times(body)
		delete(a.email)
		a.email = strings.clone(proto.self_email(body))
		code, by := proto.self_verify(body)
		delete(a.verify_code)
		a.verify_code, a.verify_by = strings.clone(code), by
		if .Unverified in flags && c.view == nil {
			log.warnf(
				"verify your email address: mail %s from %s with %s in the subject",
				c.rpc.server.email if c.rpc.server.email != "" else "the server",
				a.email,
				code,
			)
		}
		if a.state != .Done {
			set_state(c, .Done)
			// A new connection starts out as not idle.
			if a.idle || a.hidden {
				idle_set(c, a.idle, a.hidden)
			}
			if .Must_Change in flags && c.view == nil {
				// The UI asks for a new password. When headless, it is up to
				// whoever is typing.
				log.warn(
					"the password was set by an admin and has to be changed (/passwd <old> <new>)",
				)
			}
		} else {
			publish_login(c)
		}
	case .Role_Changed, .Role_Removed:
		roles_event(c, op, body)
	case .Sync_End:
		publish_directory(c)
		shared_end(c)
		convs_synced(c)
	case .Logged_Out:
		reason, _ := proto.decode_logged_out(body)
		why := "You have been logged out."
		#partial switch reason {
		case .Revoked:
			why = "This device was logged out from another device."
		case .Password_Changed:
			why = "The account's password was changed. Please log in again."
		case .Disabled:
			why = "The account has been disabled."
		case .Deleted:
			why = "The account has been deleted."
		}
		log.warnf("%s: %s", c.server_addr, why)
		auth_logged_out(c, why)
	case:
		return false
	}
	return true
}

// account_display returns the display name of an account, or "" if the server
// has not told us about it.
account_display :: proc(c: ^Server_Conn, id: proto.Account_Id) -> string {
	if acc, ok := c.auth.accounts[id]; ok {
		return acc.display
	}
	return ""
}

// account_by_username returns the account with this username, or 0 if there is
// none.
account_by_username :: proc(c: ^Server_Conn, username: string) -> proto.Account_Id {
	buf: [proto.MAX_USERNAME_SIZE]u8
	clean, ok := proto.username_clean(username, &buf)
	if !ok {
		return 0
	}
	for id, acc in c.auth.accounts {
		if acc.username == clean {
			return id
		}
	}
	return 0
}

status_text :: proc(status: proto.Status, what := "") -> string {
	#partial switch status {
	case .Denied:
		return "You don't have permission to do that."
	case .Wrong_Password:
		return "The current password is incorrect."
	case .Invalid:
		return "The server rejected the request because it contains invalid data."
	case .Conflict:
		return(
			"That username is already taken." if what == "account" else "That name is already taken." \
		)
	case .Not_Found:
		if what == "" {
			return "That no longer exists on the server."
		}
		return fmt.tprintf("That %s no longer exists.", what)
	case .Rate_Limited:
		return "Too many requests. Wait a moment and try again."
	case .Reset:
		return "The connection was lost before the server answered."
	case .Unauthenticated:
		return "You are not logged in."
	}
	return fmt.tprintf("The server failed to complete the request (%v).", status)
}

// notify tells the UI (and the log) the result of a request.
notify :: proc(c: ^Server_Conn, ok: bool, text: string) {
	if ok {
		log.info(text)
	} else {
		log.warn(text)
	}
	if c.view != nil {
		view_notice(c.view, ok, text)
	}
}

// view_notice puts up a notice for the UI, like notify does. The UI's own
// notices (for example a file it refuses to attach) also come this way.
view_notice :: proc(v: ^View, ok: bool, text: string) {
	view_write(v)
	delete(v.notice.text)
	v.notice.text = strings.clone(text)
	v.notice.ok = ok
	v.notice.count += 1
	v.notice.at = time.tick_now()
}

auth_password :: proc(c: ^Server_Conn, cmd: Password_Command) {
	if !proto.account_password_ok(cmd.new) {
		notify(c, false, password_rule())
		return
	}
	buf: [proto.ACCOUNT_BODY_MAX]u8
	body := proto.encode_password_change(buf[:], cmd.old, cmd.new, cmd.revoke_others)
	request(
		c,
		.Password_Change,
		body,
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			// What we would log in with on a new connection is no longer valid, but
			// this device stays logged in, so it isn't needed anyway.
			forget_password(&c.auth)
			if status == .Ok {
				notify(c, true, "Password changed.")
			} else {
				notify(c, false, status_text(status))
			}
		},
	)
}

auth_display :: proc(c: ^Server_Conn, name: string) {
	name_buf: [proto.MAX_NAME_SIZE]u8
	clean := proto.sanitize_name(name, &name_buf)
	if clean == "" {
		notify(c, false, "The name cannot be empty.")
		return
	}
	buf: [proto.ACCOUNT_BODY_MAX]u8
	request(
		c,
		.Profile_Set,
		proto.encode_profile_set(buf[:], {mask = proto.PROFILE_DISPLAY, display = clean}),
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			if status != .Ok {
				notify(c, false, status_text(status))
			}
		},
	)
}

auth_email :: proc(c: ^Server_Conn, raw: string) {
	email := ""
	if strings.trim_space(raw) != "" {
		buf: [proto.MAX_EMAIL_SIZE]u8
		ok: bool
		email, ok = proto.email_clean(raw, &buf)
		if !ok {
			notify(c, false, "That is not a valid email address.")
			return
		}
		email = strings.clone(email, context.temp_allocator)
	}
	buf: [1 + proto.MAX_EMAIL_SIZE]u8
	request(
		c,
		.Email_Set,
		proto.encode_email_set(buf[:], email),
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			#partial switch status {
			case .Ok:
				notify(c, true, "Email address saved.")
			case .Conflict:
				notify(c, false, "Another account already uses that email address.")
			case .Invalid:
				notify(c, false, "That is not a valid email address.")
			case:
				notify(c, false, status_text(status))
			}
		},
	)
}

auth_devices :: proc(c: ^Server_Conn, account: proto.Account_Id = 0) {
	id_buf: [4]u8
	request(
		c,
		.Device_List,
		nil if account == 0 else proto.encode_account_id(&id_buf, account),
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			if status != .Ok {
				if tag != 0 {
					notify(c, false, status_text(status, "account"))
				}
				return
			}
			buf: [64]proto.Device
			devices, ok := proto.decode_devices(body, buf[:])
			if !ok {
				return
			}
			if tag != 0 {
				publish_other_devices(c, proto.Account_Id(tag), devices)
				return
			}
			a := &c.auth
			devices_clear(a)
			for d in devices {
				append(
					&a.devices,
					Dir_Device {
						key = d.key,
						name = strings.clone(d.name),
						agent = strings.clone(d.agent),
						created = d.created,
						last_seen = d.last_seen,
						flags = d.flags,
					},
				)
				report_device(c, d)
			}
			publish_devices(c)
		},
		u64(account),
	)
}

auth_revoke :: proc(c: ^Server_Conn, key: [proto.KEY_SIZE]u8) {
	buf: [proto.ACCOUNT_BODY_MAX]u8
	// Whose list it is from, so that list can be requested again afterwards.
	whose := proto.Account_Id(0)
	if v := c.view; v != nil {
		view_write(v)
		for d in v.other_devices {
			if d.key == key {
				whose = v.other_devices_of
			}
		}
	}
	request(
		c,
		.Device_Revoke,
		proto.encode_device_revoke(buf[:], key),
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			if status == .Ok {
				notify(c, true, "Device logged out.")
				if c.auth.state == .Done {
					auth_devices(c, proto.Account_Id(tag))
				}
			} else {
				notify(c, false, status_text(status, "device"))
			}
		},
		u64(whose),
	)
}

auth_account_create :: proc(c: ^Server_Conn, cmd: Account_Create_Command) {
	name_buf: [proto.MAX_USERNAME_SIZE]u8
	username, clean := proto.username_clean(cmd.username, &name_buf)
	switch {
	case !clean:
		notify(c, false, username_rule())
		return
	case !proto.account_password_ok(cmd.password):
		notify(c, false, password_rule())
		return
	}
	buf: [proto.ACCOUNT_BODY_MAX]u8
	body := proto.encode_account_create(buf[:], username, cmd.password, cmd.display)
	request(
		c,
		.Account_Create,
		body,
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			if status == .Ok {
				notify(c, true, "Account created. Its password has to be changed on first login.")
			} else {
				notify(c, false, status_text(status, "account"))
			}
		},
	)
}

auth_account_password :: proc(c: ^Server_Conn, cmd: Account_Password_Command) {
	account := cmd.account
	if account == 0 {
		account = account_by_username(c, cmd.username)
	}
	switch {
	case account == 0:
		notify(c, false, "That account does not exist.")
		return
	case !proto.account_password_ok(cmd.password):
		notify(c, false, password_rule())
		return
	}
	buf: [proto.ACCOUNT_BODY_MAX]u8
	body := proto.encode_account_password_set(buf[:], account, cmd.password)
	request(
		c,
		.Account_Password_Set,
		body,
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			if status == .Ok {
				notify(
					c,
					true,
					"Password set. Their devices were logged out, and the password has to be changed on first login.",
				)
			} else {
				notify(c, false, status_text(status, "account"))
			}
		},
	)
}

publish_login :: proc(c: ^Server_Conn) {
	v := c.view
	if v == nil {
		return
	}
	a := &c.auth
	view_write(v)
	delete(v.login.error)
	delete(v.login.username)
	delete(v.login.email)
	delete(v.login.verify_code)
	v.login = {
		state       = a.state,
		error       = strings.clone(a.error),
		must_change = a.state == .Done && .Must_Change in a.flags,
		email       = strings.clone(a.email),
		unverified  = a.state == .Done && .Unverified in a.flags,
		verify_code = strings.clone(a.verify_code),
		verify_by   = a.verify_by,
	}
	if me, ok := a.accounts[a.me]; ok {
		v.login.username = strings.clone(me.username)
	}
	v.me = a.me
	v.permissions = a.permissions
	v.my_activity = a.chosen
	v.my_activity_at, v.my_status_at = a.chosen_at, a.status_at
}

// publish_directory hands the UI the accounts as we know them now, and the names
// that go with the connections, which come from the accounts.
publish_directory :: proc(c: ^Server_Conn) {
	if v := c.view; v != nil {
		a := &c.auth
		view_write(v)
		view_clear_accounts(v)
		for id, acc in a.accounts {
			v.accounts[id] = {
				username     = strings.clone(acc.username),
				display      = strings.clone(acc.display),
				flags        = acc.flags,
				status       = strings.clone(acc.status),
				status_until = acc.status_until,
				avatar       = acc.avatar,
				roles        = slice.clone(acc.roles),
				activity     = acc.activity,
			}
		}
	}
	publish_channels(c)
}

// Call with the mutex held.
view_clear_accounts :: proc(v: ^View) {
	for _, acc in v.accounts {
		delete(acc.username)
		delete(acc.display)
		delete(acc.status)
		delete(acc.roles)
	}
	clear(&v.accounts)
}

// Call with the mutex held.
view_clear_devices :: proc(v: ^View) {
	for d in v.devices {
		delete(d.name)
		delete(d.agent)
	}
	clear(&v.devices)
	view_clear_other_devices(v)
	view_forget_bot_token(v)
}

// Call with the mutex held.
view_clear_other_devices :: proc(v: ^View) {
	for d in v.other_devices {
		delete(d.name)
		delete(d.agent)
	}
	clear(&v.other_devices)
	v.other_devices_of = 0
}

publish_devices :: proc(c: ^Server_Conn) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	view_clear_devices(v)
	for d in c.auth.devices {
		d := d
		d.name = strings.clone(d.name)
		d.agent = strings.clone(d.agent)
		append(&v.devices, d)
	}
	v.devices_count += 1
}

package conn

import log "common:wlog"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"

import "common:proto"

/*
Our account on the server (src/common/proto/accounts.odin): logging in,
the accounts the server tells us about, and what we can ask it to do
with them.

A connection starts out not logged in, unless the server knows this
device, which the Welcome says. Until it is, the server takes nothing
from us but a login, so everything else waits: no snapshots come, and
what we send is dropped.

Once logged in, the server sends the directory: every account, and then
Self, which says which of them we are and what we may do. That's also
what finishes a login here (Login_State.Done).

Names come from the directory now: a connection in the snapshot says
which account it is, and the account says what it's called
(display_name).
*/

Login_State :: enum {
	Unknown, // not connected far enough to know
	Needed, // the server doesn't know this device: log in
	Working, // asked, or logged in and waiting to be told who we are
	Done,
}

// An account, as the server told us about it.
Dir_Account :: struct {
	username:     string, // owned
	display:      string, // owned
	flags:        proto.Account_Flags,
	status:       string, // owned; "" for none (profiles.odin)
	status_until: proto.Unix_Ms,
	avatar:       proto.Blob_Id,
	roles:        []proto.Role_Id, // owned; besides everyone's (roles.odin)
	activity:     proto.Activity, // as everyone sees it (activity.odin)
}

Auth_Client :: struct {
	state:       Login_State,
	error:       string, // why we aren't logged in, if there's a why; owned
	me:          proto.Account_Id,
	permissions: proto.Permissions,
	flags:       proto.Account_Flags, // ours, as in Self
	// What we chose to be, as in Self; and whether our user is idle, as
	// last told the server (activity.odin).
	chosen:      proto.Activity,
	idle:        bool,
	accounts:    map[proto.Account_Id]Dir_Account,
	roles:       map[proto.Role_Id]Dir_Role, // roles.odin
	// What to log in with as soon as the server wants it: given when
	// the client was started, or the last that worked. Owned.
	username:    string,
	password:    string,
	device:      string,
	// Our account's devices, as of the last time we asked.
	devices:     [dynamic]Dir_Device,
}

Dir_Device :: struct {
	key:       [proto.KEY_SIZE]u8,
	name:      string, // owned
	created:   u64,
	last_seen: u64,
	flags:     proto.Device_Flags,
}

// What the UI sees of all this.
View_Login :: struct {
	state:       Login_State,
	error:       string, // owned
	must_change: bool, // logged in, but the password has to be changed first
	username:    string, // ours, once logged in; owned
}

View_Account :: struct {
	username:     string, // owned
	display:      string, // owned
	flags:        proto.Account_Flags,
	status:       string, // owned; "" for none
	status_until: proto.Unix_Ms,
	avatar:       proto.Blob_Id, // 0 for none
	roles:        []proto.Role_Id, // owned; besides everyone's
	activity:     proto.Activity, // as everyone sees it
}

// What came of the last thing asked about accounts, for the UI to show.
View_Notice :: struct {
	text:  string, // owned
	ok:    bool,
	count: int, // bumped with each, so the UI can tell a new one
	at:    time.Tick, // when it came
}

// Log in with a username and password; `device` is what to call this
// device in the account's list.
Login_Command :: struct {
	username: string, // owned by the command
	password: string, // owned by the command
	device:   string, // owned by the command
}
// Log this device out: it has to log in again.
Logout_Command :: struct {}
Password_Command :: struct {
	old:           string, // owned by the command
	new:           string, // owned by the command
	revoke_others: bool,
}
// Change what our account is called.
Display_Command :: struct {
	name: string, // owned by the command
}
// Ask for our account's devices.
Devices_Command :: struct {}
Revoke_Command :: struct {
	key: [proto.KEY_SIZE]u8,
}
// Make an account (for who may).
Account_Create_Command :: struct {
	username: string, // owned by the command
	password: string, // owned by the command
	display:  string, // owned by the command
}
// Give an account a new password (for who may). By id, or by username
// if the id is 0.
Account_Password_Command :: struct {
	account:  proto.Account_Id,
	username: string, // owned by the command
	password: string, // owned by the command
}

auth_destroy :: proc(c: ^Voice_Client) {
	a := &c.auth
	accounts_clear(a)
	delete(a.accounts)
	roles_clear(a)
	delete(a.roles)
	devices_clear(a)
	delete(a.devices)
	delete(a.error)
	delete(a.username)
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
	}
	clear(&a.devices)
}

@(private = "file")
forget_password :: proc(a: ^Auth_Client) {
	if a.password != "" {
		// Not left lying in freed memory.
		raw := transmute([]u8)a.password
		for &b in raw {
			b = 0
		}
	}
	delete(a.password)
	a.password = ""
}

// auth_credentials says what to log in with when the server asks for
// it, before the connection is opened.
auth_credentials :: proc(c: ^Voice_Client, username, password, device: string) {
	a := &c.auth
	delete(a.username)
	forget_password(a)
	delete(a.device)
	// As the server will take it, where it can be one at all.
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
set_state :: proc(c: ^Voice_Client, state: Login_State, error := "") {
	a := &c.auth
	a.state = state
	delete(a.error)
	a.error = strings.clone(error)
	publish_login(c)
}

/*
auth_restart is a new connection's start (handle_welcome): what we knew
of the accounts went with the old one. If the server knows this device
it has logged us in, and the directory is on its way; if not, we log in
with what we were given, or wait to be given something.
*/
auth_restart :: proc(c: ^Voice_Client, logged_in: bool) {
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

// auth_login logs in with a username and password.
auth_login :: proc(c: ^Voice_Client, cmd: Login_Command) {
	if c.auth.state != .Needed {
		return
	}
	auth_credentials(c, cmd.username, cmd.password, cmd.device)
	login_send(c)
}

@(private = "file")
login_send :: proc(c: ^Voice_Client) {
	a := &c.auth
	buf: [proto.ACCOUNT_BODY_MAX]u8
	body := proto.encode_auth_login(buf[:], a.username, a.password, a.device)
	if body == nil {
		forget_password(a)
		set_state(c, .Needed, "That username or password is too long.")
		return
	}
	set_state(c, .Working)
	request(c, .Auth_Login, body, login_done)
}

@(private = "file")
login_done :: proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
	a := &c.auth
	#partial switch status {
	case .Ok:
		// Self, which the server sends next, says the rest. The password
		// has done its part: from here on the device's key is enough.
		log.infof("logged in to %s as %s", c.server_addr, a.username)
		forget_password(a)
	case .Reset:
	// The connection started over; auth_restart takes it from there.
	case .Wrong_Password:
		log.warnf("%s: wrong username or password", c.server_addr)
		forget_password(a)
		set_state(c, .Needed, "Wrong username or password.")
	case .Rate_Limited:
		forget_password(a)
		set_state(c, .Needed, "Too many attempts. Wait a little and try again.")
	case .Denied:
		forget_password(a)
		set_state(c, .Needed, "That account is disabled.")
	case:
		log.warnf("%s: login failed: %v", c.server_addr, status)
		forget_password(a)
		set_state(c, .Needed, fmt.tprintf("The server couldn't log you in (%v).", status))
	}
}

// auth_logged_out puts us back to where a login is needed, as the
// server has: there's no channel we're in any more, and nothing to show
// of the server but the login.
@(private = "file")
auth_logged_out :: proc(c: ^Voice_Client, why: string) {
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

auth_logout :: proc(c: ^Voice_Client) {
	if c.auth.state != .Done {
		return
	}
	request(
		c,
		.Auth_Logout,
		nil,
		proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
			if status == .Ok {
				log.info("logged out")
				auth_logged_out(c, "")
			}
		},
	)
}

// auth_event takes an event about accounts; false if `op` isn't one.
auth_event :: proc(c: ^Voice_Client, op: proto.Event_Op, body: []u8) -> bool {
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
			log.warn("the server sent an account we can't read")
			break
		}
		_, acc, _, _ := map_entry(&a.accounts, record.id)
		was_status := strings.clone(acc.status, context.temp_allocator)
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
		if c.view == nil && a.state == .Done && was_status != record.status {
			// Headless: statuses, as they change.
			if record.status == "" {
				log.infof("[status] %s has no status", record.display)
			} else {
				log.infof(
					"[status] %s: %s%s",
					record.display,
					record.status,
					" (for a while)" if record.status_until != 0 else "",
				)
			}
		}
		publish_directory(c)
	case .Self:
		me, permissions, flags, ok := proto.decode_self(body)
		if !ok {
			break
		}
		a.me, a.permissions, a.flags = me, permissions, flags
		a.chosen = proto.self_activity(body)
		if a.state != .Done {
			set_state(c, .Done)
			// A new connection starts out not idle.
			if a.idle {
				idle_set(c, true)
			}
			if .Must_Change in flags && c.view == nil {
				// The UI asks for a new one; headless, it's up to whoever
				// is typing.
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
		reason := proto.Logout_Reason(body[0]) if len(body) > 0 else proto.Logout_Reason{}
		why := "You were logged out."
		#partial switch reason {
		case .Revoked:
			why = "This device was logged out from another one."
		case .Password_Changed:
			why = "The account's password was changed. Log in again."
		case .Disabled:
			why = "The account was disabled."
		}
		log.warnf("%s: %s", c.server_addr, why)
		auth_logged_out(c, why)
	case:
		return false
	}
	return true
}

// account_display is what an account is called, or "" if we haven't
// been told of it.
account_display :: proc(c: ^Voice_Client, id: proto.Account_Id) -> string {
	if acc, ok := c.auth.accounts[id]; ok {
		return acc.display
	}
	return ""
}

// account_by_username is the account with this username, or 0.
account_by_username :: proc(c: ^Voice_Client, username: string) -> proto.Account_Id {
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

status_text :: proc(status: proto.Status) -> string {
	#partial switch status {
	case .Denied:
		return "You aren't allowed to do that."
	case .Wrong_Password:
		return "That's not the current password."
	case .Invalid:
		return "The server wouldn't take that."
	case .Conflict:
		return "That username is taken."
	case .Not_Found:
		return "There's no such account."
	case .Rate_Limited:
		return "Too much at once. Wait a little and try again."
	case .Reset:
		return "The connection was lost before the server answered."
	case .Unauthenticated:
		return "You aren't logged in."
	}
	return fmt.tprintf("The server couldn't do that (%v).", status)
}

// notify tells the UI (and the log) what came of something asked.
notify :: proc(c: ^Voice_Client, ok: bool, text: string) {
	if ok {
		log.info(text)
	} else {
		log.warn(text)
	}
	if c.view != nil {
		view_notice(c.view, ok, text)
	}
}

// view_notice puts a notice up for the UI, as notify does; the UI's own
// (a file it won't attach) come this way too.
view_notice :: proc(v: ^View, ok: bool, text: string) {
	view_write(v)
	delete(v.notice.text)
	v.notice.text = strings.clone(text)
	v.notice.ok = ok
	v.notice.count += 1
	v.notice.at = time.tick_now()
}

auth_password :: proc(c: ^Voice_Client, cmd: Password_Command) {
	if !proto.account_password_ok(cmd.new) {
		notify(
			c,
			false,
			fmt.tprintf(
				"A password has to be %d to %d characters.",
				proto.MIN_ACCOUNT_PASSWORD,
				proto.MAX_ACCOUNT_PASSWORD,
			),
		)
		return
	}
	buf: [proto.ACCOUNT_BODY_MAX]u8
	body := proto.encode_password_change(buf[:], cmd.old, cmd.new, cmd.revoke_others)
	request(
		c,
		.Password_Change,
		body,
		proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
			// What we'd log in with on a new connection is no good any more;
			// but this device stays logged in, so it isn't needed either.
			forget_password(&c.auth)
			if status == .Ok {
				notify(c, true, "Password changed.")
			} else {
				notify(c, false, status_text(status))
			}
		},
	)
}

auth_display :: proc(c: ^Voice_Client, name: string) {
	name_buf: [proto.MAX_NAME_SIZE]u8
	clean := proto.sanitize_name(name, &name_buf)
	if clean == "" {
		notify(c, false, "A name can't be empty.")
		return
	}
	buf: [proto.ACCOUNT_BODY_MAX]u8
	request(
		c,
		.Profile_Set,
		proto.encode_profile_set(buf[:], {mask = proto.PROFILE_DISPLAY, display = clean}),
		proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
			if status != .Ok {
				notify(c, false, status_text(status))
			}
		},
	)
}

auth_devices :: proc(c: ^Voice_Client) {
	request(
		c,
		.Device_List,
		nil,
		proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
			if status != .Ok {
				return
			}
			buf: [64]proto.Device
			devices, ok := proto.decode_devices(body, buf[:])
			if !ok {
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
						created = d.created,
						last_seen = d.last_seen,
						flags = d.flags,
					},
				)
				if c.view == nil {
					log.infof(
						"device %s %q%s%s",
						fingerprint(d.key),
						d.name,
						" (this one)" if .Current in d.flags else "",
						" online" if .Online in d.flags else "",
					)
				}
			}
			publish_devices(c)
		},
	)
}

auth_revoke :: proc(c: ^Voice_Client, key: [proto.KEY_SIZE]u8) {
	buf: [proto.ACCOUNT_BODY_MAX]u8
	request(
		c,
		.Device_Revoke,
		proto.encode_device_revoke(buf[:], key),
		proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
			if status == .Ok {
				notify(c, true, "Device logged out.")
				if c.auth.state == .Done {
					auth_devices(c)
				}
			} else {
				notify(c, false, status_text(status))
			}
		},
	)
}

auth_account_create :: proc(c: ^Voice_Client, cmd: Account_Create_Command) {
	name_buf: [proto.MAX_USERNAME_SIZE]u8
	username, clean := proto.username_clean(cmd.username, &name_buf)
	switch {
	case !clean:
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
	case !proto.account_password_ok(cmd.password):
		notify(
			c,
			false,
			fmt.tprintf(
				"A password has to be %d to %d characters.",
				proto.MIN_ACCOUNT_PASSWORD,
				proto.MAX_ACCOUNT_PASSWORD,
			),
		)
		return
	}
	buf: [proto.ACCOUNT_BODY_MAX]u8
	body := proto.encode_account_create(buf[:], username, cmd.password, cmd.display)
	request(
		c,
		.Account_Create,
		body,
		proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
			if status == .Ok {
				notify(c, true, "Account made. Its password has to be changed on first login.")
			} else {
				notify(c, false, status_text(status))
			}
		},
	)
}

auth_account_password :: proc(c: ^Voice_Client, cmd: Account_Password_Command) {
	account := cmd.account
	if account == 0 {
		account = account_by_username(c, cmd.username)
	}
	switch {
	case account == 0:
		notify(c, false, "There's no such account.")
		return
	case !proto.account_password_ok(cmd.password):
		notify(
			c,
			false,
			fmt.tprintf(
				"A password has to be %d to %d characters.",
				proto.MIN_ACCOUNT_PASSWORD,
				proto.MAX_ACCOUNT_PASSWORD,
			),
		)
		return
	}
	buf: [proto.ACCOUNT_BODY_MAX]u8
	body := proto.encode_account_password_set(buf[:], account, cmd.password)
	request(
		c,
		.Account_Password_Set,
		body,
		proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
			if status == .Ok {
				notify(
					c,
					true,
					"Password set. Their devices were logged out, and it has to be changed on first login.",
				)
			} else {
				notify(c, false, status_text(status))
			}
		},
	)
}

publish_login :: proc(c: ^Voice_Client) {
	v := c.view
	if v == nil {
		return
	}
	a := &c.auth
	view_write(v)
	delete(v.login.error)
	delete(v.login.username)
	v.login = {
		state       = a.state,
		error       = strings.clone(a.error),
		must_change = a.state == .Done && .Must_Change in a.flags,
	}
	if me, ok := a.accounts[a.me]; ok {
		v.login.username = strings.clone(me.username)
	}
	v.me = a.me
	v.permissions = a.permissions
	v.my_activity = a.chosen
}

// publish_directory hands the UI the accounts as we know them now, and
// the names that go with the connections, which come from them.
publish_directory :: proc(c: ^Voice_Client) {
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
	}
	clear(&v.devices)
}

publish_devices :: proc(c: ^Voice_Client) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	view_clear_devices(v)
	for d in c.auth.devices {
		d := d
		d.name = strings.clone(d.name)
		append(&v.devices, d)
	}
	v.devices_count += 1
}

package proto

// Accounts: who somebody is on a server, regardless of which device they
// connect from.
//
// An account has a username and a display name. The username is unique, in
// lower case, and is what the person logs in with. The display name is what
// others see and may be any valid name (see names.odin). Nobody creates their
// own account: an admin does, with a first password that the person then
// changes.
//
// A device is a client with its static key. It logs in once with the
// account's username and password. From then on its key is enough, because
// the server remembers which account the key belongs to.
//
// Everything here travels as requests and events (rpc.odin):
//
// 	Auth_Login            [username str8][password str8][device name str8]
//                           [agent str8]: a description of the client, see MAX_AGENT
// 	                  ->  [account u32][flags u8]
// 	Auth_Logout           (nothing): this device is no longer logged in
// 	Password_Change       [old str8][new str8][revoke others u8]
// 	Device_List           (nothing), or [account u32] for another account's
// 	                  ->  [count u16] devices...
// 	Device_Revoke         [key 32]
// 	Profile_Set           [mask u8] then, for each bit set, its field:
// 	                        bit 0  [display str8]
// 	                        bit 1  [status str8][status until u64]
// 	                        bit 2  [avatar u64]
// 	Setting_Set           [key str8][value bytes16] (settings.odin)
// 	Account_Create        [username str8][password str8][display str8]
// 	                  ->  [account u32]
// 	Account_Password_Set  [account u32][password str8]
// 	Account_Delete        [account u32][password str8]
// 	Email_Set             [email str8]: the account's own address, or ""
// 	                      for none
//
// 	Sync_Begin, Sync_End  (nothing): sent around everything that a connection
// 	                      is told when it logs in
// 	Self                  [account u32][permissions u64][flags u8][activity u8]
// 	                      [email str8][verify code str8][verify by u64]
// 	Account_Changed       an account that is new or has changed
// 	Setting_Changed       [key str8][value bytes16]: one of the account's
// 	                      settings (settings.odin)
// 	Logged_Out            [reason u8]: this device is no longer logged in
//
// 	account  [id u32][flags u8][username str8][display str8]
// 	         [status str8][status until u64][avatar u64][role count u8][role u32]...
// 	         [activity u8] (activity.odin)
// 	device   [key 32][name str8][created u64][last seen u64][flags u8]
// 	         (Device_List then adds each one's [agent str8], after the last)
//
// Device_List with an account is an admin request (Manage_Accounts, and the
// admin may do everything that account may do). It is used to list a bot's
// tokens (bots.odin). Without an account it lists the asker's own devices.
//
// Account_Create and Account_Password_Set are admin requests (Manage_Accounts).
// A password set by an admin, either for a new account or to replace a
// forgotten one, is only good for logging in once: Must_Change is set on the
// account, and the client asks for a new password right away.
//
// An account's status is a line of text (sanitized, at most MAX_STATUS_SIZE
// bytes) together with the time at which it ends by itself (0 means it never
// does). The server clears the status at that time. The avatar is a blob of
// kind Avatar (a JPEG of at most MAX_AVATAR_SIDE pixels per side and
// MAX_AVATAR_SIZE bytes), or 0 for none. Anyone who is logged in may fetch it.
// Roles are reserved for later use and are empty for now.
//
// Account_Delete deletes an account. A person may delete their own account
// with their password. Someone with Manage_Accounts may delete another
// account if they may do more than it. The owner can never be deleted.
// What remains is a tombstone, so that the messages the account wrote still
// have an author. It has the Deleted flag, the display name DELETED_NAME and
// a username that nobody can log in with. Everything else is removed: devices,
// roles, memberships, buddies, settings, status and picture. Its messages and
// reactions stay. A DM with it can still be read but not written to.
//
// An account's email address is private to it. Only its own connections are
// told the address (Self), and only the account itself can set it
// (Email_Set), in the form that email_clean produces. The address must not
// belong to another account (otherwise the answer is Conflict). It is used
// for mail sent by the server (src/server/email.odin).
//
// Times are Unix milliseconds.

Account_Id :: distinct u32

MIN_USERNAME_SIZE :: 2
MAX_USERNAME_SIZE :: 32
// The length of an account's password in bytes. The server's own password
// is limited by MAX_PASSWORD_SIZE instead.
MIN_ACCOUNT_PASSWORD :: 8
MAX_ACCOUNT_PASSWORD :: 128
MAX_DEVICE_NAME :: 32
// A description of the client that is sent at login and shown in the
// account's list of devices, such as "yap 1.2.0 on Linux" or
// "Firefox 128 on Windows". It is only meant to be read by people. Older
// clients leave it out, in which case it is "".
MAX_AGENT :: 64

Account_Flag :: enum u8 {
	Owner, // the first admin: may do everything and can't be demoted
	Disabled, // can't log in
	Must_Change, // the password was set by an admin and has to be changed
	Deleted, // a tombstone: what remains of a deleted account
	// Its email address has not been verified yet (verify.odin).
	// Until it is, the account can do nothing else.
	Unverified,
	// A program's account, not a person's (bots.odin). It is created by an
	// admin and logs in only with its tokens, never with a password.
	Bot,
}

// The display name of a deleted account.
DELETED_NAME :: "Deleted user"
Account_Flags :: distinct bit_set[Account_Flag;u8]

// What an account may do beyond what everyone may do. The numbers are stored
// in databases, so they must never be changed or reused.
Permission :: enum u8 {
	Create_Channels  = 0,
	Manage_Channels  = 1,
	Invite           = 2,
	Manage_Roles     = 3,
	Manage_Messages  = 4,
	Pin_Messages     = 5,
	Manage_Accounts  = 6,
	Mention_Everyone = 7,
	Purge            = 8,
	Attach_Files     = 9, // attachments.odin; everyone has it unless it is revoked
	Create_Invites   = 10, // register.odin
}
Permissions :: distinct bit_set[Permission;u64]

Account :: struct {
	id:           Account_Id,
	flags:        Account_Flags,
	username:     string,
	display:      string, // sanitized and never empty
	status:       string, // sanitized, or "" for none
	status_until: Unix_Ms, // when the status ends, or 0 for never
	avatar:       Blob_Id, // 0 for none
	roles:        []Role_Id, // besides the everyone role (roles.odin); decoded into the temp allocator
	activity:     Activity, // as everyone sees it (activity.odin)
}

MAX_STATUS_SIZE :: 80
MAX_AVATAR_SIDE :: 256
MAX_AVATAR_SIZE :: 64 * 1024

Device_Flag :: enum u8 {
	Current, // the device that sent the request
	Online, // connected right now
}
Device_Flags :: distinct bit_set[Device_Flag;u8]

Device :: struct {
	key:       [KEY_SIZE]u8,
	name:      string,
	created:   u64,
	last_seen: u64,
	flags:     Device_Flags,
	agent:     string,
}

// The reason why the server logged a device out.
Logout_Reason :: enum u8 {
	Revoked          = 1, // revoked from another of the account's devices or by an admin
	Password_Changed = 2,
	Disabled         = 3, // the account was disabled
	Deleted          = 4, // the account was deleted
}

// The bits of Profile_Set's mask.
PROFILE_DISPLAY :: 1 << 0
PROFILE_STATUS :: 1 << 1
PROFILE_AVATAR :: 1 << 2
PROFILE_ALL :: PROFILE_DISPLAY | PROFILE_STATUS | PROFILE_AVATAR

// A Profile_Set changes the fields that `mask` names.
Profile_Set :: struct {
	mask:         u8,
	display:      string,
	status:       string,
	status_until: Unix_Ms,
	avatar:       Blob_Id,
}

// username_clean converts `raw` to a username by making it lower case. It
// fails if the result could not be a username, which has to consist of
// MIN_USERNAME_SIZE to MAX_USERNAME_SIZE characters out of a-z 0-9 _ . -
// Client and server both run the typed name through it, so "Alice" logs in as
// "alice". The result points into `buf`.
username_clean :: proc(raw: string, buf: ^[MAX_USERNAME_SIZE]u8) -> (name: string, ok: bool) {
	if len(raw) < MIN_USERNAME_SIZE || len(raw) > MAX_USERNAME_SIZE {
		return
	}
	for i in 0 ..< len(raw) {
		ch := raw[i]
		switch ch {
		case 'A' ..= 'Z':
			ch += 'a' - 'A'
		case 'a' ..= 'z', '0' ..= '9', '_', '.', '-':
		case:
			return
		}
		buf[i] = ch
	}
	return string(buf[:len(raw)]), true
}

// The maximum length of an email address (the path limit of RFC 5321).
MAX_EMAIL_SIZE :: 254

// email_clean converts `raw` to an email address by removing the spaces
// around it and making it lower case. It fails if the result could not be an
// address, which needs a local part and a domain that contains a dot, around
// exactly one @, and nothing that would need quoting. This only catches
// typos. Whether the address actually exists can only be found out by sending
// mail to it. The result points into `buf`.
email_clean :: proc(raw: string, buf: ^[MAX_EMAIL_SIZE]u8) -> (address: string, ok: bool) {
	raw := raw
	for len(raw) > 0 && (raw[0] == ' ' || raw[0] == '\t') {
		raw = raw[1:]
	}
	for len(raw) > 0 && (raw[len(raw) - 1] == ' ' || raw[len(raw) - 1] == '\t') {
		raw = raw[:len(raw) - 1]
	}
	if len(raw) < 5 || len(raw) > MAX_EMAIL_SIZE {
		return
	}
	at := -1
	for i in 0 ..< len(raw) {
		ch := raw[i]
		switch ch {
		case 'A' ..= 'Z':
			ch += 'a' - 'A'
		case '@':
			if at >= 0 {
				return
			}
			at = i
		case 0 ..= ' ', 0x7f, '<', '>', '(', ')', '[', ']', ',', ';', ':', '"', '\\':
			return
		}
		buf[i] = ch
	}
	if at < 1 || at > 64 {
		return
	}
	domain := string(buf[at + 1:len(raw)])
	dot := -1
	for i in 0 ..< len(domain) {
		if domain[i] == '.' {
			dot = i
		}
	}
	if dot < 1 || dot == len(domain) - 1 || domain[0] == '.' {
		return
	}
	return string(buf[:len(raw)]), true
}

// account_password_ok reports whether a password has an acceptable length for an account.
account_password_ok :: proc(password: string) -> bool {
	return len(password) >= MIN_ACCOUNT_PASSWORD && len(password) <= MAX_ACCOUNT_PASSWORD
}

// The encoders below write a body into `out` and return it, or nil if it
// doesn't fit. Bodies are small, and ACCOUNT_BODY_MAX is large enough for any
// of the requests. The strings that the decoders return point into the body
// they read.

ACCOUNT_BODY_MAX :: 4 + 4 * (1 + 255) + 8

@(private = "file")
written :: proc(w: ^Writer) -> []u8 {
	return nil if w.overflow else w.buf[:w.pos]
}

// get_str8_opt is get_str8 for a trailing field that older peers leave out.
// It returns "" if the body has already ended.
@(private = "file")
get_str8_opt :: proc(r: ^Reader) -> string {
	if r.pos >= len(r.buf) {
		return ""
	}
	return get_str8(r)
}

encode_auth_login :: proc(out: []u8, username, password, device: string, agent := "") -> []u8 {
	w := Writer {
		buf = out,
	}
	put_str8(&w, username)
	put_str8(&w, password)
	put_str8(&w, device)
	put_str8(&w, agent)
	return written(&w)
}

decode_auth_login :: proc(body: []u8) -> (username, password, device, agent: string, ok: bool) {
	r := Reader {
		buf = body,
	}
	username = get_str8(&r)
	password = get_str8(&r)
	device = get_str8(&r)
	agent = get_str8_opt(&r)
	return username, password, device, agent, !r.overflow
}

AUTH_LOGIN_RESPONSE_SIZE :: 4 + 1

encode_auth_login_response :: proc(
	out: ^[AUTH_LOGIN_RESPONSE_SIZE]u8,
	account: Account_Id,
	flags: Account_Flags,
) -> []u8 {
	w := Writer {
		buf = out[:],
	}
	put_u32(&w, u32(account))
	put_u8(&w, transmute(u8)flags)
	return out[:]
}

decode_auth_login_response :: proc(
	body: []u8,
) -> (
	account: Account_Id,
	flags: Account_Flags,
	ok: bool,
) {
	r := Reader {
		buf = body,
	}
	account = Account_Id(get_u32(&r))
	flags = transmute(Account_Flags)get_u8(&r)
	return account, flags, !r.overflow
}

encode_password_change :: proc(out: []u8, old, new: string, revoke_others: bool) -> []u8 {
	w := Writer {
		buf = out,
	}
	put_str8(&w, old)
	put_str8(&w, new)
	put_u8(&w, u8(revoke_others))
	return written(&w)
}

decode_password_change :: proc(body: []u8) -> (old, new: string, revoke_others: bool, ok: bool) {
	r := Reader {
		buf = body,
	}
	old = get_str8(&r)
	new = get_str8(&r)
	revoke_others = get_u8(&r) != 0
	return old, new, revoke_others, !r.overflow
}

encode_device_revoke :: proc(out: []u8, key: [KEY_SIZE]u8) -> []u8 {
	key := key
	w := Writer {
		buf = out,
	}
	put_bytes(&w, key[:])
	return written(&w)
}

decode_device_revoke :: proc(body: []u8) -> (key: [KEY_SIZE]u8, ok: bool) {
	r := Reader {
		buf = body,
	}
	copy(key[:], get_bytes(&r, KEY_SIZE))
	return key, !r.overflow
}

// encode_profile_set writes a Profile_Set with the fields that its mask names.
encode_profile_set :: proc(out: []u8, p: Profile_Set) -> []u8 {
	w := Writer {
		buf = out,
	}
	put_u8(&w, p.mask)
	if p.mask & PROFILE_DISPLAY != 0 {
		put_str8(&w, p.display)
	}
	if p.mask & PROFILE_STATUS != 0 {
		put_str8(&w, p.status)
		put_u64(&w, u64(p.status_until))
	}
	if p.mask & PROFILE_AVATAR != 0 {
		put_u64(&w, u64(p.avatar))
	}
	return written(&w)
}

// decode_profile_set reads a Profile_Set. Its mask says which fields it
// carries. Bits that this build doesn't know make it invalid, because their
// fields can't be skipped.
decode_profile_set :: proc(body: []u8) -> (p: Profile_Set, ok: bool) {
	r := Reader {
		buf = body,
	}
	p.mask = get_u8(&r)
	if p.mask & ~u8(PROFILE_ALL) != 0 {
		return
	}
	if p.mask & PROFILE_DISPLAY != 0 {
		p.display = get_str8(&r)
	}
	if p.mask & PROFILE_STATUS != 0 {
		p.status = get_str8(&r)
		p.status_until = Unix_Ms(get_u64(&r))
	}
	if p.mask & PROFILE_AVATAR != 0 {
		p.avatar = Blob_Id(get_u64(&r))
	}
	return p, !r.overflow
}

encode_account_create :: proc(out: []u8, username, password, display: string) -> []u8 {
	w := Writer {
		buf = out,
	}
	put_str8(&w, username)
	put_str8(&w, password)
	put_str8(&w, display)
	return written(&w)
}

decode_account_create :: proc(body: []u8) -> (username, password, display: string, ok: bool) {
	r := Reader {
		buf = body,
	}
	username = get_str8(&r)
	password = get_str8(&r)
	display = get_str8(&r)
	return username, password, display, !r.overflow
}

// An Account_Create response, or any other body that consists of a single account id.
encode_account_id :: proc(out: ^[4]u8, account: Account_Id) -> []u8 {
	w := Writer {
		buf = out[:],
	}
	put_u32(&w, u32(account))
	return out[:]
}

decode_account_id :: proc(body: []u8) -> (account: Account_Id, ok: bool) {
	r := Reader {
		buf = body,
	}
	account = Account_Id(get_u32(&r))
	return account, !r.overflow
}

encode_account_password_set :: proc(out: []u8, account: Account_Id, password: string) -> []u8 {
	w := Writer {
		buf = out,
	}
	put_u32(&w, u32(account))
	put_str8(&w, password)
	return written(&w)
}

decode_account_password_set :: proc(
	body: []u8,
) -> (
	account: Account_Id,
	password: string,
	ok: bool,
) {
	r := Reader {
		buf = body,
	}
	account = Account_Id(get_u32(&r))
	password = get_str8(&r)
	return account, password, !r.overflow
}

// Account_Delete's body is the same as Account_Password_Set's: the account and
// the password, which is only needed when the asker deletes their own account
// (otherwise it is "").
encode_account_delete :: encode_account_password_set
decode_account_delete :: decode_account_password_set

ACCOUNT_MAX_SIZE ::
	4 +
	1 +
	(1 + MAX_USERNAME_SIZE) +
	(1 + MAX_NAME_SIZE) +
	(1 + MAX_STATUS_SIZE) +
	8 +
	8 +
	1 +
	4 * MAX_ACCOUNT_ROLES +
	1

// encode_account writes an account in the form that clients receive it.
encode_account :: proc(out: []u8, a: Account) -> []u8 {
	w := Writer {
		buf = out,
	}
	put_u32(&w, u32(a.id))
	put_u8(&w, transmute(u8)a.flags)
	put_str8(&w, a.username)
	put_str8(&w, a.display)
	put_str8(&w, a.status)
	put_u64(&w, u64(a.status_until))
	put_u64(&w, u64(a.avatar))
	put_u8(&w, u8(len(a.roles)))
	for role in a.roles {
		put_u32(&w, u32(role))
	}
	put_u8(&w, u8(a.activity))
	return written(&w)
}

// decode_account reads an account. Its strings point into `body` and its roles
// are allocated with the temp allocator.
decode_account :: proc(body: []u8) -> (a: Account, ok: bool) {
	r := Reader {
		buf = body,
	}
	a.id = Account_Id(get_u32(&r))
	a.flags = transmute(Account_Flags)get_u8(&r)
	a.username = get_str8(&r)
	a.display = get_str8(&r)
	a.status = get_str8(&r)
	a.status_until = Unix_Ms(get_u64(&r))
	a.avatar = Blob_Id(get_u64(&r))
	count := int(get_u8(&r))
	if !r.overflow {
		roles := make([]Role_Id, count, context.temp_allocator)
		for &role in roles {
			role = Role_Id(get_u32(&r))
		}
		a.roles = roles
	}
	if r.overflow || a.id == 0 {
		return {}, false
	}
	// The activity is Online if it is missing or not one that we know.
	if r.pos < len(body) && body[r.pos] <= u8(max(Activity)) {
		a.activity = Activity(body[r.pos])
	}
	return a, true
}

// SELF_FIXED_SIZE is the size of Self's fields before the email. SELF_SIZE is
// the maximum size of Self including the email and the data needed to verify
// it (verify.odin).
SELF_FIXED_SIZE :: 4 + 8 + 1 + 1
SELF_SIZE :: SELF_FIXED_SIZE + 1 + MAX_EMAIL_SIZE + 1 + VERIFY_CODE_SIZE + 8

encode_self :: proc(
	out: ^[SELF_SIZE]u8,
	account: Account_Id,
	permissions: Permissions,
	flags: Account_Flags,
	activity := Activity.Online, // as the account chose it (self_activity)
	email := "", // self_email
	verify_code := "", // self_verify
	verify_by := Unix_Ms(0),
) -> []u8 {
	w := Writer {
		buf = out[:],
	}
	put_u32(&w, u32(account))
	put_u64(&w, transmute(u64)permissions)
	put_u8(&w, transmute(u8)flags)
	put_u8(&w, u8(activity))
	put_str8(&w, email)
	put_str8(&w, verify_code)
	put_u64(&w, u64(verify_by))
	return written(&w)
}

// self_verify returns what is needed to verify the account's address, from the
// Self of an Unverified account. That is the code that the subject of the
// verification mail has to contain, and the time at which the account is
// deleted if no mail arrives (0 means it is never deleted).
self_verify :: proc(body: []u8) -> (code: string, by: Unix_Ms) {
	if len(body) <= SELF_FIXED_SIZE {
		return
	}
	r := Reader {
		buf = body[SELF_FIXED_SIZE:],
	}
	_ = get_str8(&r)
	code = get_str8(&r)
	by = Unix_Ms(get_u64(&r))
	if r.overflow {
		return "", 0
	}
	return
}

// self_email returns the account's email address from a Self, or "" for none.
self_email :: proc(body: []u8) -> string {
	if len(body) <= SELF_FIXED_SIZE {
		return ""
	}
	r := Reader {
		buf = body[SELF_FIXED_SIZE:],
	}
	email := get_str8(&r)
	return "" if r.overflow else email
}

encode_email_set :: proc(out: []u8, email: string) -> []u8 {
	w := Writer {
		buf = out,
	}
	put_str8(&w, email)
	return written(&w)
}

decode_email_set :: proc(body: []u8) -> (email: string, ok: bool) {
	r := Reader {
		buf = body,
	}
	email = get_str8(&r)
	return email, !r.overflow && r.pos == len(body)
}

decode_self :: proc(
	body: []u8,
) -> (
	account: Account_Id,
	permissions: Permissions,
	flags: Account_Flags,
	ok: bool,
) {
	r := Reader {
		buf = body,
	}
	account = Account_Id(get_u32(&r))
	permissions = transmute(Permissions)get_u64(&r)
	flags = transmute(Account_Flags)get_u8(&r)
	return account, permissions, flags, !r.overflow
}

DEVICE_MAX_SIZE :: KEY_SIZE + (1 + MAX_DEVICE_NAME) + 8 + 8 + 1 + (1 + MAX_AGENT)

// encode_devices writes a Device_List response with as many of `devices` as
// fit in `out`. The device records have the same layout as before agents
// existed, and the agents follow after them as one str8 per device in the same
// order. A client that predates agents reads the records and ignores the rest.
// A newer client that reads a list without agents treats all of them as "".
encode_devices :: proc(out: []u8, devices: []Device) -> []u8 {
	w := Writer {
		buf = out,
	}
	put_u16(&w, 0)
	count := 0
	for d in devices {
		// Make sure there is room for this device and for all the agents that
		// follow the records.
		if w.pos + DEVICE_MAX_SIZE + count * (1 + MAX_AGENT) > len(out) || count == int(max(u16)) {
			break
		}
		key := d.key
		put_bytes(&w, key[:])
		put_str8(&w, d.name[:min(len(d.name), MAX_DEVICE_NAME)])
		put_u64(&w, d.created)
		put_u64(&w, d.last_seen)
		put_u8(&w, transmute(u8)d.flags)
		count += 1
	}
	for d in devices[:count] {
		put_str8(&w, d.agent[:min(len(d.agent), MAX_AGENT)])
	}
	if w.overflow {
		return nil
	}
	out[0], out[1] = u8(count), u8(count >> 8)
	return out[:w.pos]
}

// decode_devices reads a Device_List response into `devices_buf`.
decode_devices :: proc(body: []u8, devices_buf: []Device) -> (devices: []Device, ok: bool) {
	r := Reader {
		buf = body,
	}
	count := int(get_u16(&r))
	if r.overflow || count > len(devices_buf) {
		return
	}
	for &d in devices_buf[:count] {
		copy(d.key[:], get_bytes(&r, KEY_SIZE))
		d.name = get_str8(&r)
		d.created = get_u64(&r)
		d.last_seen = get_u64(&r)
		d.flags = transmute(Device_Flags)get_u8(&r)
		d.agent = ""
	}
	// If the server sends agents, they follow the records.
	if r.pos < len(r.buf) {
		for &d in devices_buf[:count] {
			d.agent = get_str8(&r)
		}
	}
	if r.overflow {
		return
	}
	return devices_buf[:count], true
}

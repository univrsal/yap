package proto

/*
Accounts: who somebody is on a server, whichever of their devices they
come from.

An account has a username, which is unique, in lower case and what one
logs in with, and a display name, which is what others see and can be
anything a name could always be (see names.odin). Nobody makes their own:
an admin does, with a first password the person then changes.

A device is a client with its static key. It logs in once, with the
account's username and password, and from then on its key is enough:
the server remembers which account it belongs to.

Everything here travels as requests and events (rpc.odin):

	Auth_Login            [username str8][password str8][device name str8]
	                  ->  [account u32][flags u8]
	Auth_Logout           (nothing): this device forgets the account
	Password_Change       [old str8][new str8][revoke others u8]
	Device_List       ->  [count u16] devices...
	Device_Revoke         [key 32]
	Profile_Set           [mask u8] then, for each bit set, its field:
	                        bit 0  [display str8]
	                        bit 1  [status str8][status until u64]
	                        bit 2  [avatar u64]
	Setting_Set           [key str8][value bytes16] (settings.odin)
	Account_Create        [username str8][password str8][display str8]
	                  ->  [account u32]
	Account_Password_Set  [account u32][password str8]

	Sync_Begin, Sync_End  (nothing): around everything a connection is told
	                      when it logs in
	Self                  [account u32][permissions u64][flags u8][activity u8]
	Account_Changed       an account, new or changed
	Setting_Changed       [key str8][value bytes16]: one of the account's
	                      settings (settings.odin)
	Logged_Out            [reason u8]: this device isn't logged in any more

	account  [id u32][flags u8][username str8][display str8]
	         [status str8][status until u64][avatar u64][role count u8][role u32]...
	         [activity u8] (activity.odin)
	device   [key 32][name str8][created u64][last seen u64][flags u8]

The last two requests are an admin's (Manage_Accounts). A password an
admin sets, a new account's or one to replace a forgotten one, is only
good for getting in: Must_Change is set on the account, and the client
asks for a new one first thing.

An account's status is a line of text (sanitized, at most
MAX_STATUS_SIZE bytes) and when it ends by itself (0: it doesn't); the
server clears it then. Its avatar is a blob of kind Avatar (a JPEG at
most MAX_AVATAR_SIDE pixels a side and MAX_AVATAR_SIZE bytes), 0 for
none, which anyone logged in may fetch. Its roles are for later, and
empty for now.

Times are Unix milliseconds.
*/

Account_Id :: distinct u32

MIN_USERNAME_SIZE :: 2
MAX_USERNAME_SIZE :: 32
// An account's password, in bytes; not the server's (MAX_PASSWORD_SIZE).
MIN_ACCOUNT_PASSWORD :: 8
MAX_ACCOUNT_PASSWORD :: 128
MAX_DEVICE_NAME :: 32

Account_Flag :: enum u8 {
	Owner, // the first admin: may do everything, and can't be made less
	Disabled, // can't log in
	Must_Change, // the password was set by an admin, and has to be changed
}
Account_Flags :: distinct bit_set[Account_Flag;u8]

/*
What an account may do beyond what everyone may. The numbers are kept in
databases, so they're never changed or reused.
*/
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
}
Permissions :: distinct bit_set[Permission;u64]

Account :: struct {
	id:           Account_Id,
	flags:        Account_Flags,
	username:     string,
	display:      string, // sanitized; never empty
	status:       string, // sanitized; "" for none
	status_until: Unix_Ms, // when the status ends; 0 for never
	avatar:       Blob_Id, // 0 for none
	roles:        []Role_Id, // besides everyone's (roles.odin); decoded into the temp allocator
	activity:     Activity, // as everyone sees it (activity.odin)
}

MAX_STATUS_SIZE :: 80
MAX_AVATAR_SIDE :: 256
MAX_AVATAR_SIZE :: 64 * 1024

Device_Flag :: enum u8 {
	Current, // the one asking
	Online, // connected right now
}
Device_Flags :: distinct bit_set[Device_Flag;u8]

Device :: struct {
	key:       [KEY_SIZE]u8,
	name:      string,
	created:   u64,
	last_seen: u64,
	flags:     Device_Flags,
}

// Why a device was logged out by the server.
Logout_Reason :: enum u8 {
	Revoked          = 1, // from another of the account's devices, or by an admin
	Password_Changed = 2,
	Disabled         = 3, // the account was
}

// Profile_Set's mask.
PROFILE_DISPLAY :: 1 << 0
PROFILE_STATUS :: 1 << 1
PROFILE_AVATAR :: 1 << 2
PROFILE_ALL :: PROFILE_DISPLAY | PROFILE_STATUS | PROFILE_AVATAR

// What a Profile_Set changes: the fields `mask` names.
Profile_Set :: struct {
	mask:         u8,
	display:      string,
	status:       string,
	status_until: Unix_Ms,
	avatar:       Blob_Id,
}

/*
username_clean is `raw` as a username: in lower case, and only if it
could be one, MIN_USERNAME_SIZE to MAX_USERNAME_SIZE of a-z 0-9 _ . -
Both ends run what's typed through it, so "Alice" logs in as "alice".
The result points into `buf`.
*/
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

// account_password_ok is whether a password is one an account may have.
account_password_ok :: proc(password: string) -> bool {
	return len(password) >= MIN_ACCOUNT_PASSWORD && len(password) <= MAX_ACCOUNT_PASSWORD
}

// The encoders below write a body into `out` and return it, or nil if it
// doesn't fit; bodies are small, and ACCOUNT_BODY_MAX holds any of the
// requests'. The decoders' strings point into the body they read.

ACCOUNT_BODY_MAX :: 4 + 3 * (1 + 255) + 8

@(private = "file")
written :: proc(w: ^Writer) -> []u8 {
	return nil if w.overflow else w.buf[:w.pos]
}

encode_auth_login :: proc(out: []u8, username, password, device: string) -> []u8 {
	w := Writer {
		buf = out,
	}
	put_str8(&w, username)
	put_str8(&w, password)
	put_str8(&w, device)
	return written(&w)
}

decode_auth_login :: proc(body: []u8) -> (username, password, device: string, ok: bool) {
	r := Reader {
		buf = body,
	}
	username = get_str8(&r)
	password = get_str8(&r)
	device = get_str8(&r)
	return username, password, device, !r.overflow
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

decode_auth_login_response :: proc(body: []u8) -> (account: Account_Id, flags: Account_Flags, ok: bool) {
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

// encode_profile_set writes a Profile_Set: the fields its mask names.
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

// decode_profile_set reads a Profile_Set; its mask says which of the
// fields it carries. Bits this build doesn't know make it invalid, since
// their fields can't be skipped.
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

// An Account_Create response, or any other body that is one account's id.
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

decode_account_password_set :: proc(body: []u8) -> (account: Account_Id, password: string, ok: bool) {
	r := Reader {
		buf = body,
	}
	account = Account_Id(get_u32(&r))
	password = get_str8(&r)
	return account, password, !r.overflow
}

ACCOUNT_MAX_SIZE ::
	4 + 1 + (1 + MAX_USERNAME_SIZE) + (1 + MAX_NAME_SIZE) + (1 + MAX_STATUS_SIZE) + 8 + 8 + 1 + 4 * MAX_ACCOUNT_ROLES + 1

// encode_account writes an account as it's told to clients.
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

// decode_account reads one; its strings point into `body`, its roles are
// in the temp allocator.
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
	// Online if it isn't there, or isn't one we know.
	if r.pos < len(body) && body[r.pos] <= u8(max(Activity)) {
		a.activity = Activity(body[r.pos])
	}
	return a, true
}

SELF_SIZE :: 4 + 8 + 1 + 1

encode_self :: proc(
	out: ^[SELF_SIZE]u8,
	account: Account_Id,
	permissions: Permissions,
	flags: Account_Flags,
	activity := Activity.Online, // as the account chose it (self_activity)
) -> []u8 {
	w := Writer {
		buf = out[:],
	}
	put_u32(&w, u32(account))
	put_u64(&w, transmute(u64)permissions)
	put_u8(&w, transmute(u8)flags)
	put_u8(&w, u8(activity))
	return out[:]
}

decode_self :: proc(body: []u8) -> (account: Account_Id, permissions: Permissions, flags: Account_Flags, ok: bool) {
	r := Reader {
		buf = body,
	}
	account = Account_Id(get_u32(&r))
	permissions = transmute(Permissions)get_u64(&r)
	flags = transmute(Account_Flags)get_u8(&r)
	return account, permissions, flags, !r.overflow
}

DEVICE_MAX_SIZE :: KEY_SIZE + (1 + MAX_DEVICE_NAME) + 8 + 8 + 1

// encode_devices writes a Device_List response: as many of `devices` as
// fit in `out`.
encode_devices :: proc(out: []u8, devices: []Device) -> []u8 {
	w := Writer {
		buf = out,
	}
	put_u16(&w, 0)
	count := 0
	for d in devices {
		if w.pos + DEVICE_MAX_SIZE > len(out) || count == int(max(u16)) {
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
	if w.overflow {
		return nil
	}
	out[0], out[1] = u8(count), u8(count >> 8)
	return out[:w.pos]
}

// decode_devices reads one into `devices_buf`.
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
	}
	if r.overflow {
		return
	}
	return devices_buf[:count], true
}

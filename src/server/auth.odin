package server

import "core:crypto"
import "core:log"
import "core:strings"
import "core:time"

import "common:."
import "common:proto"

// Logging in and the other requests from clients that are about accounts
// (src/common/proto/accounts.odin).
//
// A connection from an unknown device can only ask to log in. After a
// successful login with the right username and password, the device's key
// is stored with the account (accounts.odin). From then on the handshake
// logs the device in by itself with auth_known_device, which is called
// for every new connection.
//
// Anything that involves a password takes two turns. The request hands
// the password to the hashing thread (hash_worker.odin) and records what
// it was for in `pending`. When the thread is done, auth_sync picks up
// the result and finishes what the request started. A connection can
// only have one such request in progress at a time.
//
// Guessing passwords is slowed down in four ways. Hashing is slow, only
// a limited number of hashes can be waiting (HASH_QUEUE_MOST), and an
// account that has had AUTH_FREE_FAILURES wrong passwords in a row
// rejects further attempts for a while, with the wait doubling each time
// up to AUTH_LOCK_MOST. Attempts that are still being hashed count towards
// AUTH_FREE_FAILURES already, so that many can't be sent at once to get
// around it. And each address may only make LOGINS_PER_ADDRESS logins and
// registrations at once, then one every LOGIN_EVERY, so that one address
// can't keep the hashing queue full and everybody else out of it. A wrong username takes as long to be refused as
// a wrong password, so it's not possible to find out from outside which
// usernames exist.
//
// The question of who may do what is answered in one place: can, in
// accounts.odin.

// The number of wrong passwords in a row an account accepts before it
// starts making whoever is guessing wait, and how long they wait.
AUTH_FREE_FAILURES :: 5
AUTH_LOCK_FIRST :: time.Second
AUTH_LOCK_MOST :: time.Minute
LOGINS_PER_ADDRESS :: 10
LOGIN_EVERY :: 6 * time.Second

// The username of the first admin, and the length of generated passwords.
FIRST_ADMIN :: "admin"
GENERATED_PASSWORD_SIZE :: 16

Pending_Kind :: enum {
	Login,
	Register, // register.odin
	Password_Change,
	Account_Create,
	Account_Password_Set,
	Account_Delete,
}

// Pending describes what a job for the hashing thread is for.
Pending :: struct {
	kind:          Pending_Kind,
	// Who asked: the connection, if it's still the same one by then.
	key:           [proto.KEY_SIZE]u8,
	instance:      u64,
	request:       u32,
	// Whose password it's about, or 0 for a login with a username that
	// doesn't belong to any account.
	account:       proto.Account_Id,
	username:      string, // Account_Create; owned
	display:       string, // Account_Create; owned
	device:        string, // Login, Register: the device's name; owned
	agent:         string, // Login, Register: the client's user agent; owned
	email:         string, // Register; owned
	invite:        string, // Register; owned
	revoke_others: bool, // Password_Change
}

Auth :: struct {
	// The parameter set new passwords are hashed with (HASH_PARAMS_NOW,
	// except in tests).
	params:  int,
	pending: map[u64]Pending, // by the job's id
	// Logins and registrations by address (LOGINS_PER_ADDRESS).
	logins:  Addr_Buckets,
}

auth_destroy :: proc(a: ^Auth) {
	for _, p in a.pending {
		pending_destroy(p)
	}
	delete(a.pending)
	addr_buckets_destroy(&a.logins)
	a^ = {}
}

pending_destroy :: proc(p: Pending) {
	delete(p.username)
	delete(p.display)
	delete(p.device)
	delete(p.agent)
	delete(p.email)
	delete(p.invite)
}

// generated_password returns a random password of letters and digits,
// leaving out characters that are easily mistaken for each other when
// read off a screen.
generated_password :: proc(out: ^[GENERATED_PASSWORD_SIZE]u8) -> string {
	alphabet := "abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	for &ch in out {
		for {
			r: [1]u8
			crypto.rand_bytes(r[:])
			// Reject the few values that would make some characters more
			// likely than others.
			if int(r[0]) < 256 - 256 % len(alphabet) {
				ch = alphabet[int(r[0]) % len(alphabet)]
				break
			}
		}
	}
	return string(out[:])
}

// ensure_first_admin creates the account a new server starts with. If
// there are no accounts at all, it creates one named FIRST_ADMIN that
// owns the server. Its password is generated here and written to the log
// once. Whoever runs the server logs in with it and creates the other
// accounts.
@(require_results)
ensure_first_admin :: proc(
	a: ^Accounts,
	params := HASH_PARAMS_NOW,
	initial_password := "",
) -> bool {
	if len(a.by_id) > 0 {
		return true
	}
	if initial_password != "" {
		if !proto.account_password_ok(initial_password) {
			log.error("the initial admin password has an invalid length")
			return false
		}
		password := password_of(initial_password)
		defer crypto.zero_explicit(&password, size_of(password))
		secret, hashed := secret_make(&password, params)
		if !hashed || account_add(a, FIRST_ADMIN, FIRST_ADMIN, secret, {.Owner}) == nil {
			log.error("could not make the first admin account")
			return false
		}
		log.warnf(
			"this server has no accounts yet, so an initial %q owner account was made",
			FIRST_ADMIN,
		)
		return true
	}
	buf: [GENERATED_PASSWORD_SIZE]u8
	text := generated_password(&buf)
	password := password_of(text)
	defer crypto.zero_explicit(&password, size_of(password))
	secret, hashed := secret_make(&password, params)
	if !hashed || account_add(a, FIRST_ADMIN, FIRST_ADMIN, secret, {.Owner, .Must_Change}) == nil {
		log.error("could not make the first admin account")
		return false
	}
	log.warnf(
		"this server has no accounts yet, so one was made: log in as %q with the password %s (it's shown this once, and has to be changed on first login)",
		FIRST_ADMIN,
		text,
	)
	return true
}

// auth_known_device logs a new connection in if its device has logged in
// before. The handshake has already proved that the device holds the key.
auth_known_device :: proc(s: ^Server, u: ^Conn) {
	d := device_of(&s.accounts, u.key)
	if d == nil {
		return
	}
	acc := account_by_id(&s.accounts, d.account)
	if acc == nil || .Disabled in acc.flags || .Deleted in acc.flags {
		return
	}
	device_seen(&s.accounts, d)
	conn_login(s, u, acc)
}

// auth_request handles a request about accounts. It returns false if
// `op` isn't one.
auth_request :: proc(s: ^Server, u: ^Conn, id: u32, op: proto.Request_Op, body: []u8) -> bool {
	#partial switch op {
	case .Auth_Login:
		login(s, u, id, body)
	case .Auth_Logout:
		device_unlink(&s.accounts, u.key)
		respond(u, id, .Ok)
		conn_logout(s, u)
	case .Password_Change:
		password_change(s, u, id, body)
	case .Device_List:
		device_list(s, u, id, body)
	case .Device_Revoke:
		device_revoke(s, u, id, body)
	case .Profile_Set:
		profile_set(s, u, id, body)
	case .Setting_Set:
		setting_set(s, u, id, body)
	case .Activity_Set:
		activity_set(s, u, id, body)
	case .Idle_Set:
		idle_set(s, u, id, body)
	case .Account_Create:
		account_create(s, u, id, body)
	case .Account_Password_Set:
		account_password_set(s, u, id, body)
	case .Account_Delete:
		account_delete(s, u, id, body)
	case .Email_Set:
		email_set(s, u, id, body)
	case .Register:
		register(s, u, id, body)
	case .Invite_Create:
		invite_create(s, u, id, body)
	case .Invite_List:
		invite_list(s, u, id)
	case .Invite_Revoke:
		invite_revoke(s, u, id, body)
	case .Invite_Of:
		invite_of(s, u, id, body)
	case:
		return false
	}
	return true
}

// submit hands a job for a request to the hashing thread. The request is
// answered with Rate_Limited if the thread already has too much to do.
submit :: proc(s: ^Server, u: ^Conn, id: u32, job: ^Hash_Job, p: Pending) {
	p := p
	defer crypto.zero_explicit(job, size_of(job^))
	job_id, ok := hash_submit(&s.hasher, job)
	if !ok {
		log.warnf("%s: too many passwords waiting to be hashed", conn_label(u))
		pending_destroy(p)
		respond(u, id, .Rate_Limited)
		return
	}
	p.key, p.instance, p.request = u.key, u.instance, id
	s.auth.pending[job_id] = p
	u.auth_busy = true
}

@(private = "file")
login :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	raw_username, password, raw_device, raw_agent, ok := proto.decode_auth_login(body)
	switch {
	case !ok:
		respond(u, id, .Invalid)
		return
	case u.account != nil:
		respond(u, id, .Conflict) // already logged in
		return
	case u.auth_busy, !login_allowed(s, u):
		respond(u, id, .Rate_Limited)
		return
	}

	// A username or password that can't belong to any account is still
	// checked, against nothing, and refused like a wrong password. That
	// way the time the answer takes doesn't reveal what exists.
	name_buf: [proto.MAX_USERNAME_SIZE]u8
	username, clean := proto.username_clean(raw_username, &name_buf)
	acc := account_find(&s.accounts, username) if clean else nil
	if acc != nil &&
	   (time.tick_diff(time.tick_now(), acc.locked_until) > 0 ||
			   acc.checking > 0 && acc.failures + acc.checking >= AUTH_FREE_FAILURES) {
		log.infof(
			"%s: too many wrong passwords for %s, rejecting further attempts for now",
			conn_label(u),
			acc.username,
		)
		respond(u, id, .Rate_Limited)
		return
	}

	job := Hash_Job {
		check = true,
		against = {params = s.auth.params},
	}
	if len(password) <= proto.MAX_ACCOUNT_PASSWORD {
		job.given = password_of(password)
	}
	p := Pending {
		kind = .Login,
	}
	// A bot has no password, so a login for it is also checked against
	// nothing and refused as if the password were wrong (bots.odin).
	if acc != nil && .Bot in acc.flags {
		log.infof("%s tried a password for the bot %s", conn_label(u), acc.username)
	} else if acc != nil && len(password) <= proto.MAX_ACCOUNT_PASSWORD {
		if secret, found := account_secret(&s.accounts, acc); found {
			job.against = secret
			p.account = acc.id
			acc.checking += 1 // until auth_sync
		}
	}
	device_buf: [proto.MAX_DEVICE_NAME]u8
	device := proto.sanitize_text(raw_device, device_buf[:])
	p.device = strings.clone(device if device != "" else "device")
	agent_buf: [proto.MAX_AGENT]u8
	p.agent = strings.clone(proto.sanitize_text(raw_agent, agent_buf[:]))
	submit(s, u, id, &job, p)
}

@(private = "file")
password_change :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	old, new, revoke_others, ok := proto.decode_password_change(body)
	switch {
	case .Bot in u.account.flags:
		// A bot has no password to change (bots.odin).
		respond(u, id, .Denied)
		return
	case !ok || !proto.account_password_ok(new):
		respond(u, id, .Invalid)
		return
	case u.auth_busy:
		respond(u, id, .Rate_Limited)
		return
	}
	secret, found := account_secret(&s.accounts, u.account)
	if !found {
		respond(u, id, .Internal)
		return
	}
	job := Hash_Job {
		check   = true,
		against = secret,
		create  = true,
		wanted  = password_of(new),
		params  = s.auth.params,
	}
	if len(old) <= proto.MAX_ACCOUNT_PASSWORD {
		job.given = password_of(old)
	}
	submit(
		s,
		u,
		id,
		&job,
		{kind = .Password_Change, account = u.account.id, revoke_others = revoke_others},
	)
}

@(private = "file")
account_create :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	raw_username, password, raw_display, ok := proto.decode_account_create(body)
	name_buf: [proto.MAX_USERNAME_SIZE]u8
	username, clean := proto.username_clean(raw_username, &name_buf)
	switch {
	case !can(u.account, .Manage_Accounts):
		respond(u, id, .Denied)
		return
	case !ok || !clean || !proto.account_password_ok(password):
		respond(u, id, .Invalid)
		return
	case account_find(&s.accounts, username) != nil:
		respond(u, id, .Conflict)
		return
	case u.auth_busy:
		respond(u, id, .Rate_Limited)
		return
	}
	display_buf: [proto.MAX_NAME_SIZE]u8
	display := proto.sanitize_name(raw_display, &display_buf)
	job := Hash_Job {
		create = true,
		wanted = password_of(password),
		params = s.auth.params,
	}
	submit(
		s,
		u,
		id,
		&job,
		{
			kind = .Account_Create,
			username = strings.clone(username),
			display = strings.clone(display if display != "" else username),
		},
	)
}

@(private = "file")
account_password_set :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	target_id, password, ok := proto.decode_account_password_set(body)
	target := account_live(&s.accounts, target_id)
	switch {
	case !can(u.account, .Manage_Accounts):
		respond(u, id, .Denied)
		return
	case !ok || !proto.account_password_ok(password):
		respond(u, id, .Invalid)
		return
	case target == nil:
		respond(u, id, .Not_Found)
		return
	case .Bot in target.flags:
		// A bot logs in with its tokens and never with a password
		// (bots.odin).
		respond(u, id, .Invalid)
		return
	case .Owner in target.flags && target != u.account:
		// Only the owner may change the owner's password.
		respond(u, id, .Denied)
		return
	case !outranks(u.account, permissions(target)):
		// An account can't change the password of anyone who may do more
		// than it may itself (roles.odin).
		respond(u, id, .Denied)
		return
	case u.auth_busy:
		respond(u, id, .Rate_Limited)
		return
	}
	job := Hash_Job {
		create = true,
		wanted = password_of(password),
		params = s.auth.params,
	}
	submit(s, u, id, &job, {kind = .Account_Password_Set, account = target.id})
}

// account_delete deletes an account (account_delete.odin). An account
// can delete itself once its password has been checked. An account with
// Manage_Accounts can delete accounts that may do less than it may. The
// owner can never be deleted.
@(private = "file")
account_delete :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	target_id, password, ok := proto.decode_account_delete(body)
	target := account_by_id(&s.accounts, target_id)
	switch {
	case !ok:
		respond(u, id, .Invalid)
		return
	case target == nil || .Deleted in target.flags:
		respond(u, id, .Not_Found)
		return
	case .Owner in target.flags:
		respond(u, id, .Invalid)
		return
	case target == u.account && .Bot in target.flags:
		// A bot has no password to prove the request is its own. An admin
		// has to delete it.
		respond(u, id, .Denied)
		return
	case target == u.account:
		if u.auth_busy {
			respond(u, id, .Rate_Limited)
			return
		}
		secret, found := account_secret(&s.accounts, target)
		if !found {
			respond(u, id, .Internal)
			return
		}
		job := Hash_Job {
			check   = true,
			against = secret,
		}
		if len(password) <= proto.MAX_ACCOUNT_PASSWORD {
			job.given = password_of(password)
		}
		submit(s, u, id, &job, {kind = .Account_Delete, account = target.id})
		return
	case !can(u.account, .Manage_Accounts):
		respond(u, id, .Denied)
		return
	case !outranks(u.account, permissions(target)):
		respond(u, id, .Denied)
		return
	}
	if !account_erase(s, target) {
		respond(u, id, .Internal)
		return
	}
	log.infof("%s deleted the account %d", conn_label(u), target.id)
	respond(u, id, .Ok)
}

// auth_sync finishes the requests whose passwords the hashing thread has
// finished hashing.
auth_sync :: proc(s: ^Server) {
	for {
		result, any := hash_poll(&s.hasher)
		if !any {
			break
		}
		p, known := s.auth.pending[result.id]
		if !known {
			continue
		}
		delete_key(&s.auth.pending, result.id)
		defer pending_destroy(p)
		if p.kind == .Login {
			if acc := account_by_id(&s.accounts, p.account); acc != nil {
				acc.checking = max(acc.checking - 1, 0)
			}
		}

		// The requester may have disconnected in the meantime. In that
		// case nobody is waiting for the answer and nothing is changed on
		// their behalf.
		u := conn_of(s, p.key)
		if u == nil || u.instance != p.instance {
			continue
		}
		u.auth_busy = false
		if !result.ok {
			respond(u, p.request, .Internal)
			continue
		}
		switch p.kind {
		case .Login:
			login_finish(s, u, p, result)
		case .Register:
			register_finish(s, u, p, result)
		case .Password_Change:
			password_change_finish(s, u, p, result)
		case .Account_Create:
			account_create_finish(s, u, p, result)
		case .Account_Password_Set:
			account_password_set_finish(s, u, p, result)
		case .Account_Delete:
			account_delete_finish(s, u, p, result)
		}
	}
}

// login_allowed takes one of the logins (or registrations) the address of
// `u` may make (LOGINS_PER_ADDRESS).
login_allowed :: proc(s: ^Server, u: ^Conn) -> bool {
	c := sending_session(s, u)
	if c == nil {
		return true // only in tests: a connection always has a session
	}
	s.auth.logins.burst = LOGINS_PER_ADDRESS
	s.auth.logins.every = LOGIN_EVERY
	if !addr_take(&s.auth.logins, c.endpoint) {
		log.infof("%s: too many logins from its address, refused one", conn_label(u))
		return false
	}
	return true
}

// wrong_password counts a wrong password against an account and makes
// whoever is guessing wait once there have been too many.
@(private = "file")
wrong_password :: proc(acc: ^Account) {
	acc.failures += 1
	over := acc.failures - AUTH_FREE_FAILURES
	if over < 0 {
		return
	}
	wait := min(AUTH_LOCK_FIRST << uint(min(over, 10)), AUTH_LOCK_MOST)
	acc.locked_until = time.tick_add(time.tick_now(), wait)
}

@(private = "file")
login_finish :: proc(s: ^Server, u: ^Conn, p: Pending, result: Hash_Result) {
	acc := account_by_id(&s.accounts, p.account)
	switch {
	case u.account != nil:
		respond(u, p.request, .Conflict)
		return
	case acc == nil || !result.matched:
		if acc != nil {
			wrong_password(acc)
			log.infof(
				"%s: wrong password for %s (%d in a row)",
				conn_label(u),
				acc.username,
				acc.failures,
			)
		} else {
			log.infof("%s: tried to log in to an account that doesn't exist", conn_label(u))
		}
		respond(u, p.request, .Wrong_Password)
		return
	case .Disabled in acc.flags, .Deleted in acc.flags:
		respond(u, p.request, .Denied)
		return
	}
	acc.failures, acc.locked_until = 0, {}
	if device_link(&s.accounts, u.key, acc, p.device, p.agent) == nil {
		respond(u, p.request, .Internal)
		return
	}
	buf: [proto.AUTH_LOGIN_RESPONSE_SIZE]u8
	respond(u, p.request, .Ok, proto.encode_auth_login_response(&buf, acc.id, acc.flags))
	conn_login(s, u, acc)
}

@(private = "file")
password_change_finish :: proc(s: ^Server, u: ^Conn, p: Pending, result: Hash_Result) {
	acc := u.account
	switch {
	case acc == nil || acc.id != p.account:
		respond(u, p.request, .Unauthenticated)
		return
	case !result.matched:
		wrong_password(acc)
		respond(u, p.request, .Wrong_Password)
		return
	case !account_set_password(&s.accounts, acc, result.made, false):
		respond(u, p.request, .Internal)
		return
	}
	log.infof("%s changed their password", conn_label(u))
	if p.revoke_others {
		revoke_devices(s, acc, .Password_Changed, u.key)
	}
	respond(u, p.request, .Ok)
	account_changed(s, acc)
}

@(private = "file")
account_create_finish :: proc(s: ^Server, u: ^Conn, p: Pending, result: Hash_Result) {
	switch {
	case !can(u.account, .Manage_Accounts):
		respond(u, p.request, .Denied)
		return
	case account_find(&s.accounts, p.username) != nil:
		respond(u, p.request, .Conflict)
		return
	}
	acc := account_add(&s.accounts, p.username, p.display, result.made, {.Must_Change})
	// Everyone is a member of the home channel, and starts in the default ones.
	if acc == nil || !account_join_defaults(&s.convs, acc) {
		respond(u, p.request, .Internal)
		return
	}
	log.infof("%s made the account %s", conn_label(u), acc.username)
	buf: [4]u8
	respond(u, p.request, .Ok, proto.encode_account_id(&buf, acc.id))
	account_changed(s, acc)
}

@(private = "file")
account_password_set_finish :: proc(s: ^Server, u: ^Conn, p: Pending, result: Hash_Result) {
	target := account_by_id(&s.accounts, p.account)
	switch {
	case !can(u.account, .Manage_Accounts):
		respond(u, p.request, .Denied)
		return
	case target == nil:
		respond(u, p.request, .Not_Found)
		return
	// The target's roles may have changed while the password was hashed.
	case !outranks(u.account, permissions(target)):
		respond(u, p.request, .Denied)
		return
	case !account_set_password(&s.accounts, target, result.made, true):
		respond(u, p.request, .Internal)
		return
	}
	log.infof("%s set a new password for %s", conn_label(u), target.username)
	// Log out everyone who knew the old password, except the connection
	// making this change.
	revoke_devices(s, target, .Password_Changed, u.key)
	respond(u, p.request, .Ok)
	account_changed(s, target)
}

@(private = "file")
account_delete_finish :: proc(s: ^Server, u: ^Conn, p: Pending, result: Hash_Result) {
	acc := u.account
	switch {
	case acc == nil || acc.id != p.account:
		respond(u, p.request, .Unauthenticated)
		return
	case !result.matched:
		wrong_password(acc)
		respond(u, p.request, .Wrong_Password)
		return
	case .Owner in acc.flags:
		respond(u, p.request, .Invalid)
		return
	}
	log.infof("%s deleted their account", conn_label(u))
	if !account_erase(s, acc) {
		respond(u, p.request, .Internal)
		return
	}
	// The connection is logged out by now but still connected, so the
	// answer still reaches it.
	respond(u, p.request, .Ok)
}

// revoke_devices permanently logs out every device of an account except
// the one with the key `keep`. The connected ones are told why, and all
// of them have to log in again.
@(private = "file")
revoke_devices :: proc(
	s: ^Server,
	acc: ^Account,
	reason: proto.Logout_Reason,
	keep: [proto.KEY_SIZE]u8,
) {
	for d in devices_of(&s.accounts, acc) {
		if d.key == keep {
			continue
		}
		key := d.key
		device_unlink(&s.accounts, key)
		if other := s.conns[key] or_else nil; other != nil {
			conn_logout(s, other, reason)
		}
	}
}

// device_list responds with an account's devices. By default these are
// the requester's own. If the body contains an account, an admin gets
// that account's devices instead (for example a bot's tokens).
@(private = "file")
device_list :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	target := u.account
	if len(body) > 0 {
		target_id, ok := proto.decode_account_id(body)
		if !ok {
			respond(u, id, .Invalid)
			return
		}
		target = account_live(&s.accounts, target_id)
		switch {
		case target == nil:
			respond(u, id, .Not_Found)
			return
		case target != u.account &&
		     (!can(u.account, .Manage_Accounts) || !outranks(u.account, permissions(target))):
			respond(u, id, .Denied)
			return
		}
	}
	devices := devices_of(&s.accounts, target)
	records := make([]proto.Device, len(devices), context.temp_allocator)
	for d, i in devices {
		records[i] = {
			key       = d.key,
			name      = d.name,
			agent     = d.agent,
			created   = u64(d.created),
			last_seen = u64(d.last_seen),
		}
		if d.key == u.key {
			records[i].flags += {.Current}
		}
		if d.key in s.conns {
			records[i].flags += {.Online}
		}
	}
	out := make([]u8, 2 + len(records) * proto.DEVICE_MAX_SIZE, context.temp_allocator)
	respond(u, id, .Ok, proto.encode_devices(out, records))
}

@(private = "file")
device_revoke :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	key, ok := proto.decode_device_revoke(body)
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	d := device_of(&s.accounts, key)
	// An account may revoke its own devices. An account that manages
	// accounts may also revoke the devices of accounts that may do no
	// more than it may.
	if d == nil || (d.account != u.account.id && !can(u.account, .Manage_Accounts)) {
		respond(u, id, .Not_Found)
		return
	}
	if owner := account_by_id(&s.accounts, d.account);
	   owner != nil && owner != u.account && !outranks(u.account, permissions(owner)) {
		respond(u, id, .Denied)
		return
	}
	log.infof("%s revoked the device %q (%08x)", conn_label(u), d.name, common.key_id(key))
	device_unlink(&s.accounts, key)
	respond(u, id, .Ok)
	if other := s.conns[key] or_else nil; other != nil {
		// Revoking one's own device is a logout like any other.
		// Somebody else's device is told it was revoked.
		conn_logout(s, other, {} if other == u else proto.Logout_Reason.Revoked)
	}
}

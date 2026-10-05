package server

import "core:crypto"
import "core:log"
import "core:strings"
import "core:time"

import "common:proto"

/*
Logging in, and the rest of what clients ask about accounts
(src/common/proto/accounts.odin).

A device that isn't known has a connection that can do nothing but ask
to log in. With the right username and password its key is kept with
the account (accounts.odin), and from then on the handshake logs it in:
auth_known_device, called for every new connection.

Anything that involves a password takes two turns. The request hands the
password to the hashing thread (hash_worker.odin) and leaves a note of
what it was for in `pending`; when the thread is done, auth_sync picks
the result up and finishes what the request started. A connection has
one such request under way at a time.

Guessing at passwords is slowed down three ways: the hashing is slow,
only so many hashes can be waiting (HASH_QUEUE_MOST), and an account
that's been given AUTH_FREE_FAILURES wrong passwords in a row takes no
more for a while, twice as long each time up to AUTH_LOCK_MOST.
A wrong username takes as long to refuse as a wrong password, so that
which usernames exist can't be told from outside.

Who may do what is one question asked in one place: can, in
accounts.odin.
*/

// Wrong passwords in a row an account takes before it starts making
// whoever is guessing wait, and how long.
AUTH_FREE_FAILURES :: 5
AUTH_LOCK_FIRST :: time.Second
AUTH_LOCK_MOST :: time.Minute

// What the first admin is called, and how long generated passwords are.
FIRST_ADMIN :: "admin"
GENERATED_PASSWORD_SIZE :: 16

@(private = "file")
Pending_Kind :: enum {
	Login,
	Password_Change,
	Account_Create,
	Account_Password_Set,
}

// What a job with the hashing thread is for.
@(private = "file")
Pending :: struct {
	kind:          Pending_Kind,
	// Who asked: the connection, if it's still the same one by then.
	key:           [proto.KEY_SIZE]u8,
	instance:      u64,
	request:       u32,
	// Whose password it's about; 0 for a login with a username there
	// isn't an account for.
	account:       proto.Account_Id,
	username:      string, // Account_Create; owned
	display:       string, // Account_Create; owned
	device:        string, // Login: what the device calls itself; owned
	revoke_others: bool, // Password_Change
}

Auth :: struct {
	// The parameter set new passwords are hashed with (HASH_PARAMS_NOW,
	// but for tests).
	params:  int,
	pending: map[u64]Pending, // by the job's id
}

auth_destroy :: proc(a: ^Auth) {
	for _, p in a.pending {
		pending_destroy(p)
	}
	delete(a.pending)
	a^ = {}
}

@(private = "file")
pending_destroy :: proc(p: Pending) {
	delete(p.username)
	delete(p.display)
	delete(p.device)
}

// generated_password is a random password of letters and digits that
// can't be taken for one another when read off a screen.
generated_password :: proc(out: ^[GENERATED_PASSWORD_SIZE]u8) -> string {
	alphabet := "abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	for &ch in out {
		for {
			r: [1]u8
			crypto.rand_bytes(r[:])
			// Without the few values that would make some letters
			// likelier than others.
			if int(r[0]) < 256 - 256 % len(alphabet) {
				ch = alphabet[int(r[0]) % len(alphabet)]
				break
			}
		}
	}
	return string(out[:])
}

/*
ensure_first_admin makes the account a new server is set up with: if
there are no accounts at all, one called FIRST_ADMIN that owns the
server, with a password made up here and written to the log this once.
Whoever runs the server logs in with it and makes the others.
*/
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
			log.error("the initial admin password isn't a valid length")
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

/*
auth_known_device logs a new connection in if its device has logged in
before: the handshake has proved it holds the key.
*/
auth_known_device :: proc(s: ^Server, u: ^Conn) {
	d := device_of(&s.accounts, u.key)
	if d == nil {
		return
	}
	acc := account_by_id(&s.accounts, d.account)
	if acc == nil || .Disabled in acc.flags {
		return
	}
	device_seen(&s.accounts, d)
	conn_login(s, u, acc)
}

// auth_request handles a request about accounts; false if `op` isn't
// one.
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
		device_list(s, u, id)
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
	case:
		return false
	}
	return true
}

// submit hands a job to the hashing thread for a request, which is
// answered Rate_Limited if the thread has too much to do already.
@(private = "file")
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
	raw_username, password, raw_device, ok := proto.decode_auth_login(body)
	switch {
	case !ok:
		respond(u, id, .Invalid)
		return
	case u.account != nil:
		respond(u, id, .Conflict) // logged in already
		return
	case u.auth_busy:
		respond(u, id, .Rate_Limited)
		return
	}

	// A username or password that couldn't be anybody's is checked all
	// the same, against nothing, and refused like a wrong password: how
	// long the answer takes then says nothing about what exists.
	name_buf: [proto.MAX_USERNAME_SIZE]u8
	username, clean := proto.username_clean(raw_username, &name_buf)
	acc := account_find(&s.accounts, username) if clean else nil
	if acc != nil && time.tick_diff(time.tick_now(), acc.locked_until) > 0 {
		log.infof(
			"%s: too many wrong passwords for %s, not taking more yet",
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
	if acc != nil && len(password) <= proto.MAX_ACCOUNT_PASSWORD {
		if secret, found := account_secret(&s.accounts, acc); found {
			job.against = secret
			p.account = acc.id
		}
	}
	device_buf: [proto.MAX_DEVICE_NAME]u8
	device := proto.sanitize_text(raw_device, device_buf[:])
	p.device = strings.clone(device if device != "" else "device")
	submit(s, u, id, &job, p)
}

@(private = "file")
password_change :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	old, new, revoke_others, ok := proto.decode_password_change(body)
	switch {
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
	target := account_by_id(&s.accounts, target_id)
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
	case .Owner in target.flags && target != u.account:
		// The owner's password is the owner's to change.
		respond(u, id, .Denied)
		return
	case !outranks(u.account, permissions(target)):
		// Nor anyone's who may do more than the asker (roles.odin).
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

// auth_sync finishes the requests whose passwords the hashing thread
// is done with.
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

		// Whoever asked may have gone meanwhile, and then nobody is
		// waiting for the answer; nothing is changed on their behalf.
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
		case .Password_Change:
			password_change_finish(s, u, p, result)
		case .Account_Create:
			account_create_finish(s, u, p, result)
		case .Account_Password_Set:
			account_password_set_finish(s, u, p, result)
		}
	}
}

// wrong_password counts one against an account, and makes whoever is
// guessing wait once there have been too many.
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
			log.infof("%s: tried to log in to an account there isn't", conn_label(u))
		}
		respond(u, p.request, .Wrong_Password)
		return
	case .Disabled in acc.flags:
		respond(u, p.request, .Denied)
		return
	}
	acc.failures, acc.locked_until = 0, {}
	if device_link(&s.accounts, u.key, acc, p.device) == nil {
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
	// Everyone is in the home channel.
	if acc == nil || !conv_member_add(&s.convs, s.convs.home, acc.id) {
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
	case !account_set_password(&s.accounts, target, result.made, true):
		respond(u, p.request, .Internal)
		return
	}
	log.infof("%s set a new password for %s", conn_label(u), target.username)
	// Whoever had the old one is out, except the one doing this.
	revoke_devices(s, target, .Password_Changed, u.key)
	respond(u, p.request, .Ok)
	account_changed(s, target)
}

/*
revoke_devices logs every device of an account out for good, except the
one with the key `keep`: those that are connected are told why, and all
of them have to log in again.
*/
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

@(private = "file")
device_list :: proc(s: ^Server, u: ^Conn, id: u32) {
	devices := devices_of(&s.accounts, u.account)
	records := make([]proto.Device, len(devices), context.temp_allocator)
	for d, i in devices {
		records[i] = {
			key       = d.key,
			name      = d.name,
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
	// One's own devices, or anybody's for who manages accounts and may
	// do all its account may.
	if d == nil || (d.account != u.account.id && !can(u.account, .Manage_Accounts)) {
		respond(u, id, .Not_Found)
		return
	}
	if owner := account_by_id(&s.accounts, d.account);
	   owner != nil && owner != u.account && !outranks(u.account, permissions(owner)) {
		respond(u, id, .Denied)
		return
	}
	log.infof("%s revoked the device %q (%08x)", conn_label(u), d.name, key_id_of(key))
	device_unlink(&s.accounts, key)
	respond(u, id, .Ok)
	if other := s.conns[key] or_else nil; other != nil {
		// Its own, and it's a logout like any other; somebody else's is
		// told.
		conn_logout(s, other, {} if other == u else proto.Logout_Reason.Revoked)
	}
}

@(private = "file")
key_id_of :: proc(key: [proto.KEY_SIZE]u8) -> u32 {
	return u32(key[0]) << 24 | u32(key[1]) << 16 | u32(key[2]) << 8 | u32(key[3])
}

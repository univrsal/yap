package server

import "core:crypto"
import "core:log"
import "core:strings"
import "core:time"

import "common:proto"

/*
Registering: people making their own accounts, when the config's
"registration" lets them (config.odin; proto/register.odin has the
wire). Otherwise accounts are made by an admin (Account_Create).

A Register is checked, its password hashed on the hashing thread as for
an admin's Account_Create (auth.odin), and checked again when that's
done - somebody may have taken the name, the address or the invite's
last use meanwhile - before the account is made, with the address and
the invite it came with, and the asking device logged in to it.

Besides the hashing (one request a connection at a time, HASH_QUEUE_MOST
waiting), registrations are limited server-wide to REGISTER_BURST at
once and one every REGISTER_EVERY after that, so a script can't fill
the server with accounts. Open servers that want more of a say use
invite codes (invites.odin).

With verify_email the new account starts Unverified, and is deleted if
its address isn't verified in unverified_hours (verify.odin).
*/

REGISTER_BURST :: 10
REGISTER_EVERY :: 10 * time.Second

Register_Rate :: struct {
	tokens: f64,
	last:   time.Tick,
}

// registration_flags is what Server_Info says about registering.
registration_flags :: proc(s: ^Server) -> (flags: proto.Registration_Flags) {
	r := s.registration
	if !r.open {
		return
	}
	flags += {.Open}
	if r.require_email || r.verify_email {
		flags += {.Email}
	}
	if r.require_invite {
		flags += {.Invite}
	}
	return
}

@(private = "file")
refuse_register :: proc(u: ^Conn, id: u32, reason: proto.Register_Refusal) {
	status := proto.Status.Invalid
	#partial switch reason {
	case .Closed:
		status = .Denied
	case .Username_Taken, .Email_Taken:
		status = .Conflict
	}
	body := [1]u8{u8(reason)}
	respond(u, id, status, body[:])
}

// register_take spends one of the registrations the rate allows; false
// if there's none to spend.
@(private = "file")
register_take :: proc(s: ^Server) -> bool {
	r := &s.register_rate
	now := time.tick_now()
	if r.last == {} {
		r.tokens = REGISTER_BURST
	} else {
		elapsed := time.duration_seconds(time.tick_diff(r.last, now))
		r.tokens = min(
			f64(REGISTER_BURST),
			r.tokens + elapsed / time.duration_seconds(REGISTER_EVERY),
		)
	}
	r.last = now
	if r.tokens < 1 {
		return false
	}
	r.tokens -= 1
	return true
}

/*
register_checks is what a registration has to pass, both when it's asked
and once its password is hashed: `username` and `email` are clean, and
`invite` is clean or "". Ok if it may go ahead.
*/
@(private = "file")
register_checks :: proc(
	s: ^Server,
	username, email, invite: string,
) -> (
	reason: proto.Register_Refusal,
	ok: bool,
) {
	r := s.registration
	switch {
	case !r.open:
		return .Closed, false
	case account_find(&s.accounts, username) != nil:
		return .Username_Taken, false
	case email == "" && (r.require_email || r.verify_email):
		return .Email_Missing, false
	case account_by_email(&s.accounts, email) != nil:
		return .Email_Taken, false
	case invite == "" && r.require_invite:
		return .Invite_Missing, false
	}
	if invite != "" {
		inv, found := invite_get(&s.db, invite)
		if !found || !proto.invite_usable(inv, proto.Unix_Ms(unix_ms())) {
			return .Invite, false
		}
	}
	return {}, true
}

register :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	req, decoded := proto.decode_register(body)
	switch {
	case !decoded:
		respond(u, id, .Invalid)
		return
	case u.account != nil:
		respond(u, id, .Conflict) // logged in already
		return
	case u.auth_busy:
		respond(u, id, .Rate_Limited)
		return
	case !s.registration.open:
		refuse_register(u, id, .Closed)
		return
	}
	name_buf: [proto.MAX_USERNAME_SIZE]u8
	username, name_ok := proto.username_clean(req.username, &name_buf)
	if !name_ok {
		refuse_register(u, id, .Username)
		return
	}
	if !proto.account_password_ok(req.password) {
		refuse_register(u, id, .Password)
		return
	}
	email := ""
	if req.email != "" {
		email_buf: [proto.MAX_EMAIL_SIZE]u8
		clean, email_ok := proto.email_clean(req.email, &email_buf)
		if !email_ok {
			refuse_register(u, id, .Email)
			return
		}
		email = strings.clone(clean, context.temp_allocator)
	}
	invite := ""
	if req.invite != "" {
		code_buf: [proto.INVITE_CODE_SIZE]u8
		clean, code_ok := proto.invite_code_clean(req.invite, &code_buf)
		if !code_ok {
			refuse_register(u, id, .Invite)
			return
		}
		invite = strings.clone(clean, context.temp_allocator)
	}
	if reason, ok := register_checks(s, username, email, invite); !ok {
		refuse_register(u, id, reason)
		return
	}
	if !register_take(s) {
		log.warnf("%s: registrations are coming too fast, refused one", conn_label(u))
		respond(u, id, .Rate_Limited)
		return
	}

	device_buf: [proto.MAX_DEVICE_NAME]u8
	device := proto.sanitize_text(req.device, device_buf[:])
	job := Hash_Job {
		create = true,
		wanted = password_of(req.password),
		params = s.auth.params,
	}
	submit(
		s,
		u,
		id,
		&job,
		{
			kind = .Register,
			username = strings.clone(username),
			display = strings.clone(username),
			device = strings.clone(device if device != "" else "device"),
			email = strings.clone(email),
			invite = strings.clone(invite),
		},
	)
}

register_finish :: proc(s: ^Server, u: ^Conn, p: Pending, result: Hash_Result) {
	if u.account != nil {
		respond(u, p.request, .Conflict)
		return
	}
	// What the name, the address or the invite were then, they may not be
	// now.
	if reason, ok := register_checks(s, p.username, p.email, p.invite); !ok {
		refuse_register(u, p.request, reason)
		return
	}
	acc := account_add(&s.accounts, p.username, p.display, result.made, {})
	if acc == nil ||
	   (p.email != "" && !account_set_email(&s.accounts, acc, p.email)) ||
	   !conv_member_add(&s.convs, s.convs.home, acc.id) {
		respond(u, p.request, .Internal)
		return
	}
	if p.invite != "" && !invite_use(&s.db, p.invite, acc.id) {
		respond(u, p.request, .Internal)
		return
	}
	// Verifying the address comes first, if it has to be: until it's
	// done the account is out of sight (verify.odin).
	if verify_on(s) {
		hours := i64(s.registration.unverified_hours)
		if !account_unverify(s, acc, unix_ms() + hours * 60 * 60 * 1000) {
			respond(u, p.request, .Internal)
			return
		}
	}
	if device_link(&s.accounts, u.key, acc, p.device) == nil {
		respond(u, p.request, .Internal)
		return
	}
	if p.invite != "" {
		log.infof(
			"%s registered the account %s with invite %s",
			conn_label(u),
			acc.username,
			p.invite,
		)
	} else {
		log.infof("%s registered the account %s", conn_label(u), acc.username)
	}
	// Everyone else hears of it, once it's verified if it has to be; the
	// device itself is told everything as it logs in.
	if .Unverified not_in acc.flags {
		account_changed(s, acc)
	}
	buf: [proto.AUTH_LOGIN_RESPONSE_SIZE]u8
	respond(u, p.request, .Ok, proto.encode_auth_login_response(&buf, acc.id, acc.flags))
	conn_login(s, u, acc)
}

// invite_code_new is a new random invite code.
invite_code_new :: proc(out: ^[proto.INVITE_CODE_SIZE]u8) -> string {
	alphabet := proto.INVITE_ALPHABET
	for &ch in out {
		ch = alphabet[random_below(len(alphabet))]
	}
	return string(out[:])
}

// random_below is a random number from 0 up to `n` (at most 256), each
// as likely as the others.
random_below :: proc(n: int) -> int {
	for {
		r: [1]u8
		crypto.rand_bytes(r[:])
		// Without the few values that would make some likelier.
		if int(r[0]) < 256 - 256 % n {
			return int(r[0]) % n
		}
	}
}

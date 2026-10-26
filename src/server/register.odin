package server

import "core:crypto"
import "core:log"
import "core:strings"
import "core:time"

import "common:proto"

// Registration lets people create their own accounts, if the "registration"
// setting in the config allows it (see config.odin, and proto/register.odin
// for the wire format). Otherwise accounts can only be created by an admin
// (Account_Create).
//
// A Register request is validated first. Then its password is hashed on the
// hashing thread, like for Account_Create by an admin (see auth.odin).
// When the hashing is done the request is validated again, because in the
// meantime somebody may have taken the name or the email address, or the
// last use of the invite. Only then the account is created, with the email
// address and invite from the request, and the requesting device is logged
// in to it.
//
// Besides the limit on hashing (one request per connection at a time and at
// most HASH_QUEUE_MOST waiting), registrations are limited server-wide to
// REGISTER_BURST at once and one every REGISTER_EVERY after that, so a
// script can't fill the server with accounts, nor use the refusals to find
// out which usernames and email addresses have accounts. Open servers that want more
// control can require invite codes (see invites.odin).
//
// With verify_email the new account starts out Unverified and is deleted if
// its email address isn't verified within unverified_hours (see verify.odin).

REGISTER_BURST :: 10
REGISTER_EVERY :: 10 * time.Second

// registration_flags returns the registration settings that are reported in Server_Info.
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

// register_take uses up one of the registrations that the rate limit allows.
// It returns false if none are left.
@(private = "file")
register_take :: proc(s: ^Server) -> bool {
	rate := 1 / time.duration_seconds(REGISTER_EVERY)
	proto.bucket_refill(&s.register_rate, time.tick_now(), rate, REGISTER_BURST)
	return proto.bucket_take(&s.register_rate, 1)
}

// register_checks validates a registration, both when it is requested and
// again after its password has been hashed. `username` and `email` must
// already be cleaned, and `invite` must be cleaned or empty. It returns ok
// if the registration may go ahead.
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
	// A banned account's address gets the same answer (bans.odin).
	case account_by_email(&s.accounts, email) != nil || email_banned(&s.accounts, email):
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
		respond(u, id, .Conflict) // the connection is already logged in
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
	// The limits come before the checks, since their answers say whether a
	// username, an email address or an invite code is known to the server.
	// Otherwise anyone could ask about as many as they like.
	if !login_allowed(s, u) {
		respond(u, id, .Rate_Limited)
		return
	}
	if !register_take(s) {
		log.warnf("%s: too many registrations in a short time, refused one", conn_label(u))
		respond(u, id, .Rate_Limited)
		return
	}
	if reason, ok := register_checks(s, username, email, invite); !ok {
		refuse_register(u, id, reason)
		return
	}

	device_buf: [proto.MAX_DEVICE_NAME]u8
	device := proto.sanitize_text(req.device, device_buf[:])
	agent_buf: [proto.MAX_AGENT]u8
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
			agent = strings.clone(proto.sanitize_text(req.agent, agent_buf[:])),
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
	// The username, email address or invite may have been taken or used up
	// while the password was being hashed, so check them again.
	if reason, ok := register_checks(s, p.username, p.email, p.invite); !ok {
		refuse_register(u, p.request, reason)
		return
	}
	acc := account_add(&s.accounts, p.username, p.display, result.made, {})
	if acc == nil ||
	   (p.email != "" && !account_set_email(&s.accounts, acc, p.email)) ||
	   !account_join_defaults(&s.convs, acc) {
		respond(u, p.request, .Internal)
		return
	}
	if p.invite != "" && !invite_use(&s.db, p.invite, acc.id) {
		respond(u, p.request, .Internal)
		return
	}
	// If the email address has to be verified, that comes first. Until it
	// is verified the account is hidden from everyone else (see verify.odin).
	if verify_on(s) {
		hours := i64(s.registration.unverified_hours)
		if !account_unverify(s, acc, unix_ms() + hours * 60 * 60 * 1000) {
			respond(u, p.request, .Internal)
			return
		}
	}
	if device_link(&s.accounts, u.key, acc, p.device, p.agent) == nil {
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
	// Everyone else is told about the new account, but only once it is
	// verified if verification is required. The registering device is told
	// everything when it logs in.
	if .Unverified not_in acc.flags {
		account_changed(s, acc)
	}
	buf: [proto.AUTH_LOGIN_RESPONSE_SIZE]u8
	respond(u, p.request, .Ok, proto.encode_auth_login_response(&buf, acc.id, acc.flags))
	conn_login(s, u, acc)
}

// invite_code_new generates a new random invite code.
invite_code_new :: proc(out: ^[proto.INVITE_CODE_SIZE]u8) -> string {
	alphabet := proto.INVITE_ALPHABET
	for &ch in out {
		ch = alphabet[random_below(len(alphabet))]
	}
	return string(out[:])
}

// random_below returns a random number from 0 up to but not including `n`
// (at most 256), with every value equally likely.
random_below :: proc(n: int) -> int {
	for {
		r: [1]u8
		crypto.rand_bytes(r[:])
		// Reject the few top values that would make some results more likely.
		if int(r[0]) < 256 - 256 % n {
			return int(r[0]) % n
		}
	}
}

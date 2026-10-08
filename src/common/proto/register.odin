package proto

/*
Registering an account, and invite codes (src/server/register.odin,
src/server/invites.odin).

Whether a server takes registrations is its config's; a client learns
it from Server_Info's `registration` (rpc.odin), before logging in:

	Open    anyone may register an account
	Email   with an email address
	Invite  with an invite code

	Register       [username str8][password str8][device str8][email str8][invite str8]
	           ->  [account u32][flags u8], as Auth_Login's
	               or, refused, [reason u8] (Register_Refusal)
	Invite_Create  [max uses u16][expires u64]  ->  [code str8]
	Invite_List    (nothing)  ->  [count u16] invites...
	Invite_Revoke  [code str8]
	Invite_Of      [account u32]  ->  [code str8][creator u32]

	invite  [code str8][creator u32][created u64][max uses u16][uses u16]
	        [expires u64][revoked u8]

Register may be asked by a connection that isn't logged in, like
Auth_Login, and is answered like it: the device is the new account's,
and logged in. The username is as Auth_Login takes it (username_clean)
and must be no other account's, a deleted one's included; email and
invite are "" for none. An invite code is good while it isn't revoked,
hasn't expired and has uses left; one given when none is asked for
still counts, and is kept with the account.

An invite code is INVITE_CODE_SIZE characters of INVITE_ALPHABET, which
has none that are easily taken for another; it's read in any case.
`max uses` 0 is any number, `expires` 0 never (Unix milliseconds).
Making them takes Create_Invites; Invite_List lists one's own, or with
Manage_Accounts everybody's; Invite_Revoke is for the code's creator
and Manage_Accounts. Invite_Of, Manage_Accounts' too, is the code an
account registered with (Not_Found if none).
*/

Registration_Flag :: enum u8 {
	Open,
	Email,
	Invite,
}
Registration_Flags :: distinct bit_set[Registration_Flag;u8]

// Why a Register was refused, in its response's body.
Register_Refusal :: enum u8 {
	Closed         = 1, // the server takes no registrations (Denied)
	Username       = 2, // that can't be a username (Invalid)
	Username_Taken = 3, // (Conflict)
	Password       = 4, // too short or too long (Invalid)
	Email_Missing  = 5, // one is asked for (Invalid)
	Email          = 6, // that's no address (Invalid)
	Email_Taken    = 7, // another account has it (Conflict)
	Invite_Missing = 8, // one is asked for (Invalid)
	Invite         = 9, // unknown, revoked, expired or used up (Invalid)
}

INVITE_CODE_SIZE :: 10
INVITE_ALPHABET :: "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
MAX_INVITE_USES :: 1000
// The most invites an Invite_List holds: the newest.
MAX_INVITES_LISTED :: 500
INVITE_MAX_SIZE :: 1 + INVITE_CODE_SIZE + 4 + 8 + 2 + 2 + 8 + 1

REGISTER_BODY_MAX ::
	5 +
	MAX_USERNAME_SIZE +
	MAX_ACCOUNT_PASSWORD +
	MAX_DEVICE_NAME +
	MAX_EMAIL_SIZE +
	INVITE_CODE_SIZE

Register :: struct {
	username: string,
	password: string,
	device:   string,
	email:    string,
	invite:   string,
}

Invite :: struct {
	code:     string,
	creator:  Account_Id,
	created:  Unix_Ms,
	max_uses: u16, // 0: any number
	uses:     u16,
	expires:  Unix_Ms, // 0: never
	revoked:  bool,
}

/*
invite_code_clean is `raw` as an invite code, in upper case, if it could
be one. The result points into `buf`.
*/
invite_code_clean :: proc(raw: string, buf: ^[INVITE_CODE_SIZE]u8) -> (code: string, ok: bool) {
	raw := raw
	for len(raw) > 0 && raw[0] == ' ' {
		raw = raw[1:]
	}
	for len(raw) > 0 && raw[len(raw) - 1] == ' ' {
		raw = raw[:len(raw) - 1]
	}
	if len(raw) != INVITE_CODE_SIZE {
		return
	}
	alphabet := INVITE_ALPHABET
	for i in 0 ..< len(raw) {
		ch := raw[i]
		if ch >= 'a' && ch <= 'z' {
			ch -= 'a' - 'A'
		}
		found := false
		for j in 0 ..< len(alphabet) {
			if alphabet[j] == ch {
				found = true
				break
			}
		}
		if !found {
			return
		}
		buf[i] = ch
	}
	return string(buf[:]), true
}

// invite_usable is whether an invite still lets somebody register at
// `now`.
invite_usable :: proc(inv: Invite, now: Unix_Ms) -> bool {
	return(
		!inv.revoked &&
		(inv.max_uses == 0 || inv.uses < inv.max_uses) &&
		(inv.expires == 0 || inv.expires > now) \
	)
}

encode_register :: proc(out: []u8, r: Register) -> []u8 {
	w := Writer {
		buf = out,
	}
	put_str8(&w, r.username)
	put_str8(&w, r.password)
	put_str8(&w, r.device)
	put_str8(&w, r.email)
	put_str8(&w, r.invite)
	return nil if w.overflow else out[:w.pos]
}

decode_register :: proc(body: []u8) -> (r: Register, ok: bool) {
	rd := Reader {
		buf = body,
	}
	r.username = get_str8(&rd)
	r.password = get_str8(&rd)
	r.device = get_str8(&rd)
	r.email = get_str8(&rd)
	r.invite = get_str8(&rd)
	return r, !rd.overflow
}

// decode_register_refusal reads why a Register was refused; ok false
// for a body without a reason this build knows.
decode_register_refusal :: proc(body: []u8) -> (reason: Register_Refusal, ok: bool) {
	if len(body) < 1 ||
	   body[0] < u8(min(Register_Refusal)) ||
	   body[0] > u8(max(Register_Refusal)) {
		return
	}
	return Register_Refusal(body[0]), true
}

INVITE_CREATE_SIZE :: 2 + 8

encode_invite_create :: proc(
	out: ^[INVITE_CREATE_SIZE]u8,
	max_uses: u16,
	expires: Unix_Ms,
) -> []u8 {
	w := Writer {
		buf = out[:],
	}
	put_u16(&w, max_uses)
	put_u64(&w, u64(expires))
	return out[:]
}

decode_invite_create :: proc(body: []u8) -> (max_uses: u16, expires: Unix_Ms, ok: bool) {
	r := Reader {
		buf = body,
	}
	max_uses = get_u16(&r)
	expires = Unix_Ms(get_u64(&r))
	return max_uses, expires, !r.overflow
}

// An invite code on its own: Invite_Create's answer, Invite_Revoke's
// request.
encode_invite_code :: proc(out: ^[1 + INVITE_CODE_SIZE]u8, code: string) -> []u8 {
	w := Writer {
		buf = out[:],
	}
	put_str8(&w, code)
	return nil if w.overflow else out[:w.pos]
}

decode_invite_code :: proc(body: []u8) -> (code: string, ok: bool) {
	r := Reader {
		buf = body,
	}
	code = get_str8(&r)
	return code, !r.overflow
}

// encode_invites writes an Invite_List response: as many of `invites`
// as fit in `out`.
encode_invites :: proc(out: []u8, invites: []Invite) -> []u8 {
	w := Writer {
		buf = out,
	}
	put_u16(&w, 0)
	count := 0
	for inv in invites {
		before := w.pos
		put_str8(&w, inv.code)
		put_u32(&w, u32(inv.creator))
		put_u64(&w, u64(inv.created))
		put_u16(&w, inv.max_uses)
		put_u16(&w, inv.uses)
		put_u64(&w, u64(inv.expires))
		put_u8(&w, 1 if inv.revoked else 0)
		if w.overflow {
			w.pos, w.overflow = before, false
			break
		}
		count += 1
	}
	out[0], out[1] = u8(count), u8(count >> 8)
	return out[:w.pos]
}

// decode_invites reads an Invite_List response, into `allocator`; the
// codes point into `body`.
decode_invites :: proc(
	body: []u8,
	allocator := context.temp_allocator,
) -> (
	invites: []Invite,
	ok: bool,
) {
	r := Reader {
		buf = body,
	}
	count := int(get_u16(&r))
	if r.overflow || count > MAX_INVITES_LISTED {
		return
	}
	invites = make([]Invite, count, allocator)
	for &inv in invites {
		inv.code = get_str8(&r)
		inv.creator = Account_Id(get_u32(&r))
		inv.created = Unix_Ms(get_u64(&r))
		inv.max_uses = get_u16(&r)
		inv.uses = get_u16(&r)
		inv.expires = Unix_Ms(get_u64(&r))
		inv.revoked = get_u8(&r) != 0
	}
	if r.overflow {
		delete(invites, allocator)
		return nil, false
	}
	return invites, true
}

INVITE_OF_SIZE :: 1 + INVITE_CODE_SIZE + 4

encode_invite_of :: proc(out: ^[INVITE_OF_SIZE]u8, code: string, creator: Account_Id) -> []u8 {
	w := Writer {
		buf = out[:],
	}
	put_str8(&w, code)
	put_u32(&w, u32(creator))
	return nil if w.overflow else out[:w.pos]
}

decode_invite_of :: proc(body: []u8) -> (code: string, creator: Account_Id, ok: bool) {
	r := Reader {
		buf = body,
	}
	code = get_str8(&r)
	creator = Account_Id(get_u32(&r))
	return code, creator, !r.overflow
}

package proto

// Moderation: moving, muting and disconnecting people in voice rooms, and
// banning accounts (docs/design/moderation.md).
//
//	Voice_Move  [account u32][room u32]  move the account's connection that
//	            is in a room to another room, or out of it (room 0)
//	Voice_Mute  [account u32][on u8]  mute the account for everyone, or
//	            lift that
//	Ban_Set     [account u32][on u8][reason str8][purge u8]  ban the
//	            account, or unban it (the rest is then ignored)
//	Ban_List    (nothing)  ->  [count u16] bans...
//
//	Voice_Moved [room u32][by u32]  (convs.odin) `by` is the account that
//	            moved us, or 0 (or missing) if it wasn't a person
//
//	ban  [account u32][by u32][time u64][reason str8]
//
// They need the permissions Move_Members, Mute_Members and Ban_Members
// (accounts.odin). Nobody can act on themselves, on the owner, or on an
// account with a permission they lack themselves (as for managing accounts,
// roles.odin).
//
// Voice_Move only moves someone who is in a channel's voice room on this
// server, never someone in a call. The mover must have See and Voice in the
// target room (convs.odin); what the person moved may do there isn't asked.
// They may rejoin their old room on their own afterwards.
//
// A muted account has Account_Flag.Server_Muted, which everyone sees in its
// account record. It lasts until it is lifted, across rooms and logins, and
// the server drops the account's voice meanwhile. Screen sharing and the
// camera aren't affected.
//
// A banned account is disabled (Account_Flag.Disabled) and logged out, with
// Logout_Reason.Banned and the ban's reason (Logged_Out, accounts.odin). It
// is told the same whenever one of its devices connects again, and a login
// with its password is answered Status.Banned with the reason. Registering
// with the email address it had when it was banned is refused while the
// ban lasts. Unbanning, or enabling the account with Account_Disable, ends
// the ban. `purge` also removes the account's messages in channels, from
// the given time on (Ban_Purge).
//
// Ban_List answers with the newest bans that fit in a body (at least 290 of
// them), newest first.
//
// Times are Unix milliseconds.

// The maximum length of a ban's reason in bytes.
MAX_BAN_REASON :: 200
// The maximum number of bans a Ban_List holds.
MAX_BANS_LISTED :: 1000

// How much of a banned account's messages Ban_Set removes: none, those of the
// last hour, day or week, or all of them.
Ban_Purge :: enum u8 {
	None = 0,
	Hour = 1,
	Day  = 2,
	Week = 3,
	All  = 4,
}

Ban :: struct {
	account: Account_Id,
	by:      Account_Id,
	time:    Unix_Ms,
	reason:  string,
}

Ban_Set :: struct {
	account: Account_Id,
	on:      bool,
	reason:  string,
	purge:   Ban_Purge,
}

VOICE_MOVE_SIZE :: 4 + 4
VOICE_MUTE_SIZE :: 4 + 1
VOICE_MOVED_SIZE :: 4 + 4
BAN_SET_MAX_SIZE :: 4 + 1 + 1 + MAX_BAN_REASON + 1
BAN_MAX_SIZE :: 4 + 4 + 8 + 1 + MAX_BAN_REASON
BANNED_MAX_SIZE :: 1 + MAX_BAN_REASON

encode_voice_move :: proc(out: ^[VOICE_MOVE_SIZE]u8, account: Account_Id, room: Room) -> []u8 {
	w := Writer {
		buf = out[:],
	}
	put_u32(&w, u32(account))
	put_u32(&w, u32(room))
	return out[:]
}

decode_voice_move :: proc(body: []u8) -> (account: Account_Id, room: Room, ok: bool) {
	r := Reader {
		buf = body,
	}
	account = Account_Id(get_u32(&r))
	room = Room(get_u32(&r))
	return account, room, !r.overflow
}

encode_voice_mute :: proc(out: ^[VOICE_MUTE_SIZE]u8, account: Account_Id, on: bool) -> []u8 {
	w := Writer {
		buf = out[:],
	}
	put_u32(&w, u32(account))
	put_u8(&w, u8(on))
	return out[:]
}

decode_voice_mute :: proc(body: []u8) -> (account: Account_Id, on: bool, ok: bool) {
	r := Reader {
		buf = body,
	}
	account = Account_Id(get_u32(&r))
	on = get_u8(&r) != 0
	return account, on, !r.overflow
}

encode_voice_moved :: proc(out: ^[VOICE_MOVED_SIZE]u8, room: Room, by: Account_Id) -> []u8 {
	w := Writer {
		buf = out[:],
	}
	put_u32(&w, u32(room))
	put_u32(&w, u32(by))
	return out[:]
}

// decode_voice_moved reads a Voice_Moved event. Older servers send only the
// room, so `by` is 0 then.
decode_voice_moved :: proc(body: []u8) -> (room: Room, by: Account_Id, ok: bool) {
	r := Reader {
		buf = body,
	}
	room = Room(get_u32(&r))
	if r.overflow {
		return
	}
	if has_more(&r) {
		by = Account_Id(get_u32(&r))
	}
	return room, by, !r.overflow
}

// encode_ban_set writes a Ban_Set request. It returns nil if the reason is
// longer than MAX_BAN_REASON.
encode_ban_set :: proc(out: ^[BAN_SET_MAX_SIZE]u8, b: Ban_Set) -> []u8 {
	if len(b.reason) > MAX_BAN_REASON {
		return nil
	}
	w := Writer {
		buf = out[:],
	}
	put_u32(&w, u32(b.account))
	put_u8(&w, u8(b.on))
	put_str8(&w, b.reason)
	put_u8(&w, u8(b.purge))
	return written(&w)
}

// decode_ban_set reads a Ban_Set request. The reason points into `body` and
// still has to be sanitized.
decode_ban_set :: proc(body: []u8) -> (b: Ban_Set, ok: bool) {
	r := Reader {
		buf = body,
	}
	b.account = Account_Id(get_u32(&r))
	b.on = get_u8(&r) != 0
	b.reason = get_str8(&r)
	purge := get_u8(&r)
	if r.overflow || len(b.reason) > MAX_BAN_REASON || purge > u8(max(Ban_Purge)) {
		return {}, false
	}
	b.purge = Ban_Purge(purge)
	return b, true
}

// encode_bans writes a Ban_List response containing as many of `bans` as fit
// in `out`.
encode_bans :: proc(out: []u8, bans: []Ban) -> []u8 {
	w := Writer {
		buf = out,
	}
	put_u16(&w, 0)
	count := 0
	for b in bans[:min(len(bans), MAX_BANS_LISTED)] {
		before := w.pos
		put_u32(&w, u32(b.account))
		put_u32(&w, u32(b.by))
		put_u64(&w, u64(b.time))
		put_str8(&w, b.reason)
		if w.overflow {
			w.pos, w.overflow = before, false
			break
		}
		count += 1
	}
	if w.overflow {
		return nil
	}
	out[0], out[1] = u8(count), u8(count >> 8)
	return out[:w.pos]
}

// decode_bans reads a Ban_List response into `allocator`. The reasons point
// into `body`.
decode_bans :: proc(body: []u8, allocator := context.temp_allocator) -> (bans: []Ban, ok: bool) {
	r := Reader {
		buf = body,
	}
	count := int(get_u16(&r))
	if r.overflow || count > MAX_BANS_LISTED {
		return
	}
	bans = make([]Ban, count, allocator)
	for &b in bans {
		b.account = Account_Id(get_u32(&r))
		b.by = Account_Id(get_u32(&r))
		b.time = Unix_Ms(get_u64(&r))
		b.reason = get_str8(&r)
	}
	if r.overflow {
		delete(bans, allocator)
		return nil, false
	}
	return bans, true
}

// encode_banned writes the body of a Status.Banned response: the ban's reason.
encode_banned :: proc(out: ^[BANNED_MAX_SIZE]u8, reason: string) -> []u8 {
	if len(reason) > MAX_BAN_REASON {
		return nil
	}
	w := Writer {
		buf = out[:],
	}
	put_str8(&w, reason)
	return written(&w)
}

// decode_banned reads the reason from a Status.Banned response's body. It
// is "" if the body has none. The reason points into `body`.
decode_banned :: proc(body: []u8) -> string {
	r := Reader {
		buf = body,
	}
	return get_str8_opt(&r)
}

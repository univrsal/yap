package proto

/*
Calls: two accounts talking to each other outside any channel. A call is
a voice room of its own, whose Room is the call's id with the top bit set
(CALL_ROOM); voice and screens are relayed in it as in a channel's.

	Call_Start    [account u32]  ->  [call u32]: ring that account
	Call_Accept   [call u32]: this connection answers, and is in the call
	Call_End      [call u32]: hang up, cancel or decline

	Call_Ring     [call u32][from u32]: somebody is calling; to every
	              connection of the account called
	Call_Changed  [call u32][state u8][reason u8][caller u32][callee u32]:
	              to every connection of both accounts, whenever the
	              call's state changes

A call rings for CALL_RING_TIME; answered on one of the callee's
connections, that one and the caller's are put in its room, and the
others stop ringing (Call_Changed, Active). It ends when either hangs up,
leaves its room (for a channel's, or by going), or nobody answers, and
leaves a system message in their DM: a missed call, a declined one, or
how long it lasted (Call_System).

Calling an account that isn't here posts a missed call and is answered
Closed; one that's in a call, or calling, Conflict. Calling someone who is
calling us answers their call.
*/

Call_Id :: distinct u32

// A call's room: its id with this bit set, apart from channels'.
CALL_ROOM :: Room(1 << 31)
// How long a call rings before it's missed.
CALL_RING_SECONDS :: 30

Call_State :: enum u8 {
	Ringing = 0,
	Active  = 1,
	Ended   = 2,
}

// Why a call ended.
Call_End_Reason :: enum u8 {
	None       = 0,
	Hung_Up    = 1, // by either, while it was on
	Cancelled  = 2, // by the caller, while it rang
	Declined   = 3, // by the callee
	Unanswered = 4,
	Left       = 5, // one of them left its room, or went
}

// What a call's system message in a DM says (Message.system); its
// system_arg is how many seconds the call lasted, for Call_Ended.
Call_System :: enum u8 {
	Missed   = 1,
	Declined = 2,
	Ended    = 3,
}

call_room :: proc(id: Call_Id) -> Room {
	return CALL_ROOM | Room(id)
}

// room_call is the call a room is, 0 for a channel's or none.
room_call :: proc(room: Room) -> Call_Id {
	return Call_Id(room & ~CALL_ROOM) if room & CALL_ROOM != 0 else 0
}

encode_call_id :: proc(out: ^[4]u8, id: Call_Id) -> []u8 {
	return encode_account_id(out, Account_Id(id))
}

decode_call_id :: proc(body: []u8) -> (Call_Id, bool) {
	id, ok := decode_account_id(body)
	return Call_Id(id), ok
}

CALL_RING_SIZE :: 4 + 4

encode_call_ring :: proc(out: ^[CALL_RING_SIZE]u8, id: Call_Id, from: Account_Id) -> []u8 {
	w := Writer {
		buf = out[:],
	}
	put_u32(&w, u32(id))
	put_u32(&w, u32(from))
	return out[:]
}

decode_call_ring :: proc(body: []u8) -> (id: Call_Id, from: Account_Id, ok: bool) {
	r := Reader {
		buf = body,
	}
	id = Call_Id(get_u32(&r))
	from = Account_Id(get_u32(&r))
	return id, from, !r.overflow
}

Call_Change :: struct {
	id:     Call_Id,
	state:  Call_State,
	reason: Call_End_Reason,
	caller: Account_Id,
	callee: Account_Id,
}

CALL_CHANGED_SIZE :: 4 + 1 + 1 + 4 + 4

encode_call_changed :: proc(out: ^[CALL_CHANGED_SIZE]u8, c: Call_Change) -> []u8 {
	w := Writer {
		buf = out[:],
	}
	put_u32(&w, u32(c.id))
	put_u8(&w, u8(c.state))
	put_u8(&w, u8(c.reason))
	put_u32(&w, u32(c.caller))
	put_u32(&w, u32(c.callee))
	return out[:]
}

decode_call_changed :: proc(body: []u8) -> (c: Call_Change, ok: bool) {
	r := Reader {
		buf = body,
	}
	c.id = Call_Id(get_u32(&r))
	c.state = Call_State(get_u8(&r))
	c.reason = Call_End_Reason(get_u8(&r))
	c.caller = Account_Id(get_u32(&r))
	c.callee = Account_Id(get_u32(&r))
	if c.state > max(Call_State) || c.reason > max(Call_End_Reason) {
		return {}, false
	}
	return c, !r.overflow
}

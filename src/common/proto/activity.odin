package proto

/*
Activity: whether somebody is online, away, busy or offline, as a dot
by their picture (polish 11).

	Activity_Set  [activity u8]: what the account chooses to be, on all
	              its devices: Online (and away by itself), Away, Busy,
	              or Offline (appear offline); kept by the server
	Idle_Set      [idle u8]: this connection's user has (or hasn't) been
	              idle for a while

	in an account's record:  [activity u8] as everyone sees it
	in Self:                 [activity u8] as the account chose it

What everyone sees is worked out by the server: Offline for an account
with no connection or that chose to appear offline; Busy or Away if
chosen; else Away if every one of its connections is idle, Online if
not. An account that appears offline is left out of who is here (the
snapshot) for everyone else, but for while its voice is in a room they
can see.

Busy asks the account's own clients to keep quiet: no sound or desktop
notice for messages, but for mentions and calls.
*/

Activity :: enum u8 {
	Online  = 0,
	Away    = 1,
	Busy    = 2,
	Offline = 3,
}

ACTIVITY_SET_SIZE :: 1

encode_activity :: proc(out: ^[ACTIVITY_SET_SIZE]u8, a: Activity) -> []u8 {
	out[0] = u8(a)
	return out[:]
}

decode_activity :: proc(body: []u8) -> (a: Activity, ok: bool) {
	if len(body) < 1 || body[0] > u8(max(Activity)) {
		return
	}
	return Activity(body[0]), true
}

// An Idle_Set body: whether this connection's user is idle.
encode_idle :: proc(out: ^[1]u8, idle: bool) -> []u8 {
	out[0] = u8(idle)
	return out[:]
}

decode_idle :: proc(body: []u8) -> (idle: bool, ok: bool) {
	if len(body) < 1 {
		return
	}
	return body[0] != 0, true
}

// self_activity is what a Self event says the account chose; Online if
// it doesn't say.
self_activity :: proc(body: []u8) -> Activity {
	if len(body) < SELF_SIZE || body[SELF_SIZE - 1] > u8(max(Activity)) {
		return .Online
	}
	return Activity(body[SELF_SIZE - 1])
}

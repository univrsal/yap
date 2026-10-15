package proto

// Activity: whether somebody is online, away, busy or offline. It is shown as
// a dot next to their picture (polish 11).
//
// 	Activity_Set  [activity u8]: what the account chooses to be, on all
// 	              its devices: Online (and away by itself), Away, Busy,
// 	              or Offline (appear offline); kept by the server
// 	Idle_Set      [flags u8]: bit 0, whether this connection's user has
// 	              been idle for a while; bit 1, whether the client is out
// 	              of sight (a hidden browser tab, a phone's browser in the
// 	              background). Being out of sight doesn't make anyone away,
// 	              but makes the server send push notifications (push.odin).
// 	              A server that doesn't know bit 1 treats it as idle.
//
// 	in an account's record:  [activity u8] as everyone sees it
// 	in Self:                 [activity u8] as the account chose it
//
// What everyone sees is determined by the server. An account is Offline if it
// has no connection or chose to appear offline. It is Busy or Away if it
// chose so. Otherwise it is Away if all of its connections are idle, and
// Online if not. An account that appears offline is left out of the list of
// who is here (the snapshot) for everyone else, except while its voice is in
// a room that they can see.
//
// Busy asks the account's own clients to keep quiet: no sound or desktop
// notification for messages, except for mentions and calls.

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

// An Idle_Set body, which says whether this connection's user is idle and
// whether the client is out of sight.
encode_idle :: proc(out: ^[1]u8, idle: bool, hidden := false) -> []u8 {
	out[0] = u8(idle) | u8(hidden) << 1
	return out[:]
}

decode_idle :: proc(body: []u8) -> (idle: bool, hidden: bool, ok: bool) {
	if len(body) < 1 {
		return
	}
	return body[0] & 1 != 0, body[0] & 2 != 0, true
}

// self_activity returns the activity that the account chose, as stated by a
// Self event. It is Online if the event doesn't say.
self_activity :: proc(body: []u8) -> Activity {
	if len(body) < SELF_FIXED_SIZE || body[SELF_FIXED_SIZE - 1] > u8(max(Activity)) {
		return .Online
	}
	return Activity(body[SELF_FIXED_SIZE - 1])
}

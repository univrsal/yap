package conn

import "core:fmt"

import "common:proto"

/*
Activity (src/common/proto/activity.odin): what we choose to be (online,
away, busy, offline: kept by the server for every device of ours), and
whether whoever uses this client is idle, which the UI works out from
its input and this connection tells the server. Everyone's, as the
server works it out, is in their account's record (View_Account); ours as
chosen is View.my_activity.

While we're busy, messages and pokes make no sound; mentions and calls
still do.
*/

// Choose what to be.
Activity_Command :: struct {
	activity: proto.Activity,
}
// Whoever uses this client has been idle for a while, or is back.
Idle_Command :: struct {
	idle: bool,
}

activity_set :: proc(c: ^Voice_Client, activity: proto.Activity) {
	buf: [proto.ACTIVITY_SET_SIZE]u8
	request(
		c,
		.Activity_Set,
		proto.encode_activity(&buf, activity),
		proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
			if status != .Ok && status != .Reset {
				notify(c, false, fmt.tprintf("The server wouldn't change that (%v).", status))
			}
		},
	)
}

// idle_set tells the server whether this client's user is idle; it's
// told again after the connection starts over (on login, auth.odin).
idle_set :: proc(c: ^Voice_Client, idle: bool) {
	c.auth.idle = idle
	if c.auth.state != .Done {
		return
	}
	buf: [1]u8
	request(
		c,
		.Idle_Set,
		proto.encode_idle(&buf, idle),
		proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {},
	)
}

// quiet is whether we chose to be busy: no sounds but for mentions and
// calls.
quiet :: proc(c: ^Voice_Client) -> bool {
	return c.auth.chosen == .Busy
}

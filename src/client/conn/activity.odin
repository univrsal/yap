package conn

import "core:fmt"

import "common:proto"

// Activity (src/common/proto/activity.odin) covers two things:
//   - The activity the user chose for themselves (online, away, busy or
//     offline). The server stores it and applies it to all of the user's devices.
//   - Whether the person using this client is idle. The UI works that out
//     from user input, and this connection reports it to the server.
// The activity of every account, as the server resolves it, is in the account's
// record (View_Account). The activity we chose ourselves is View.my_activity.
//
// While we're busy, messages make no sound, but mentions and calls still do.

// Sets the activity the user chose: now, or with `at`, the activity chosen
// then on another server.
Activity_Command :: struct {
	activity: proto.Activity,
	at:       proto.Unix_Ms,
}
// Reports that the user of this client has become idle, or is back, and
// whether the client is hidden (e.g. a web client in a background tab).
Idle_Command :: struct {
	idle:   bool,
	hidden: bool,
}

activity_set :: proc(c: ^Voice_Client, activity: proto.Activity, at: proto.Unix_Ms) {
	buf: [proto.ACTIVITY_SET_SIZE]u8
	request(
		c,
		.Activity_Set,
		proto.encode_activity(&buf, activity, at),
		proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
			if status != .Ok && status != .Reset {
				notify(
					c,
					false,
					fmt.tprintf("The server failed to change your activity (%v).", status),
				)
			}
		},
	)
}

// idle_set tells the server whether this client's user is idle and whether
// the client is out of sight. The server is told again after the connection
// restarts (on login, see auth.odin).
idle_set :: proc(c: ^Voice_Client, idle: bool, hidden: bool) {
	c.auth.idle, c.auth.hidden = idle, hidden
	if c.auth.state != .Done {
		return
	}
	buf: [1]u8
	request(
		c,
		.Idle_Set,
		proto.encode_idle(&buf, idle, hidden),
		proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {},
	)
}

// quiet reports whether the user chose to be busy, in which case only
// mentions and calls make a sound.
quiet :: proc(c: ^Voice_Client) -> bool {
	return c.auth.chosen == .Busy
}

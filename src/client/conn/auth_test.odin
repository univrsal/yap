#+build !wasi
package conn

import "core:testing"

import "common:proto"

@(test)
test_status_text :: proc(t: ^testing.T) {
	// What a request was about decides the answers that depend on it.
	testing.expect_value(t, status_text(.Not_Found, "invite"), "That invite no longer exists.")
	testing.expect_value(t, status_text(.Not_Found), "That no longer exists on the server.")
	testing.expect_value(t, status_text(.Conflict, "account"), "That username is already taken.")
	testing.expect_value(
		t,
		status_text(.Conflict, "role, account or channel"),
		"That name is already taken.",
	)
	testing.expect_value(
		t,
		status_text(.Denied, "invite"),
		"You don't have permission to do that.",
	)
	testing.expect_value(
		t,
		status_text(proto.Status.Internal),
		"The server failed to complete the request (Internal).",
	)
}

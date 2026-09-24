#+build !wasi
package client

import "core:fmt"
import "core:testing"

@(test)
test_recent_servers :: proc(t: ^testing.T) {
	s: Settings
	defer settings_destroy(&s)

	remember_recent_server(&s, "a:1", "")
	remember_recent_server(&s, "b:1", "pw")
	testing.expect_value(t, len(s.recent_servers), 2)
	testing.expect_value(t, s.recent_servers[0].address, "b:1") // newest first
	testing.expect_value(t, recent_password(&s, "b:1"), "pw")
	testing.expect_value(t, recent_password(&s, "c:1"), "")

	// Connecting again moves it to the top, with the new password,
	// rather than listing it twice.
	remember_recent_server(&s, "a:1", "new")
	testing.expect_value(t, len(s.recent_servers), 2)
	testing.expect_value(t, s.recent_servers[0].address, "a:1")
	testing.expect_value(t, recent_password(&s, "a:1"), "new")

	// What the connect screen does on a click: the entry is its own
	// argument.
	remember_recent_server(&s, s.recent_servers[1].address, s.recent_servers[1].password)
	testing.expect_value(t, s.recent_servers[0].address, "b:1")
	testing.expect_value(t, s.recent_servers[0].password, "pw")

	for i in 0 ..< 2 * MAX_RECENT_SERVERS {
		remember_recent_server(&s, fmt.tprintf("host%d:1", i), "")
	}
	testing.expect_value(t, len(s.recent_servers), MAX_RECENT_SERVERS)
	testing.expect_value(
		t,
		s.recent_servers[0].address,
		fmt.tprintf("host%d:1", 2 * MAX_RECENT_SERVERS - 1),
	)

	forget_recent_server(&s, s.recent_servers[0].address)
	testing.expect_value(t, len(s.recent_servers), MAX_RECENT_SERVERS - 1)
}

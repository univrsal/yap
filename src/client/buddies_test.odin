#+build !wasi
package client

import "core:testing"

import "common:proto"
import "client:settings"

@(test)
test_buddy_list_order :: proc(t: ^testing.T) {
	a, b, c: [proto.KEY_SIZE]u8
	a[0], b[0], c[0] = 1, 2, 3

	s: settings.Settings
	defer settings.settings_destroy(&s)
	settings.add_buddy(&s, a, "zed")
	settings.add_buddy(&s, b, "Amy")
	settings.add_buddy(&s, c, "bob")

	v: View
	defer delete(v.users)
	v.my_num = 1
	v.users[7] = {
		key  = a,
		name = "zed",
	} 	// online, so first

	list := buddy_list(&s, &v)
	testing.expect_value(t, len(list), 3)
	testing.expect_value(t, list[0].name, "zed")
	testing.expect_value(t, list[0].online, proto.User_Num(7))
	testing.expect_value(t, list[1].name, "Amy")
	testing.expect_value(t, list[2].name, "bob")
}

#+build !wasi
package client

import "core:testing"

import "common:proto"
import "client:settings"
import "client:conn"

@(test)
test_buddy_list :: proc(t: ^testing.T) {
	s: settings.Settings
	defer settings.settings_destroy(&s)
	v: conn.View
	defer {
		delete(v.users)
		delete(v.accounts)
		delete(v.buddies)
		delete(v.dms)
	}
	v.me = 1
	v.my_num = 1
	v.server_key[0] = 9
	v.accounts[2] = {display = "zed"}
	v.accounts[3] = {display = "Amy"}
	v.accounts[4] = {display = "bob"}
	v.accounts[5] = {display = "carol"}
	append(&v.buddies, 2, 3, 4)
	v.users[7] = {account = 2} // online, so first
	// A DM with a buddy shows once; one with somebody else shows too,
	// unless it was hidden and nothing's been said since.
	append(&v.dms, conn.View_DM{id = 10, with = 3, last = 100, unread = 2})
	append(&v.dms, conn.View_DM{id = 11, with = 5, last = 200})

	list := buddy_list(&s, &v)
	testing.expect_value(t, len(list), 4)
	names := [4]string{"zed", "Amy", "bob", "carol"}
	for e, i in list {
		testing.expect_value(t, e.name, names[i])
	}
	testing.expect(t, list[0].online && !list[1].online)
	testing.expect_value(t, list[1].conv, proto.Conv_Id(10))
	testing.expect_value(t, list[1].unread, 2)
	testing.expect(t, !list[3].buddy)

	settings.hide_dm(&s, v.server_key, 11, 200)
	testing.expect_value(t, len(buddy_list(&s, &v)), 3)
	v.dms[1].last = 201
	testing.expect_value(t, len(buddy_list(&s, &v)), 4)
}

#+build !wasi
package client

import "core:testing"

import "client:conn"
import "client:settings"
import "common:proto"

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
	v.accounts[2] = {
		display = "zed",
	}
	v.accounts[3] = {
		display = "Amy",
	}
	v.accounts[4] = {
		display = "bob",
	}
	v.accounts[5] = {
		display = "carol",
	}
	append(&v.buddies, 2, 3, 4)
	v.users[7] = {
		account = 2,
	} // online, so listed first
	// A DM with a buddy is listed only once (as the buddy); a DM with someone
	// else is listed too, unless it was hidden and no message has arrived since.
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

	// Within each section the most recent conversation comes first, even before
	// users who are online.
	v.dms[0].last_time = 5000
	list = buddy_list(&s, &v)
	testing.expect_value(t, list[0].name, "Amy")
	testing.expect_value(t, list[1].name, "zed")
	testing.expect_value(t, list[3].name, "carol")
	v.dms[0].last_time = 0

	settings.hide_dm(&s, v.server_key, 11, 200)
	testing.expect_value(t, len(buddy_list(&s, &v)), 3)
	v.dms[1].last = 201
	testing.expect_value(t, len(buddy_list(&s, &v)), 4)

	// Our notes, the DM with ourselves, aren't listed.
	append(&v.dms, conn.View_DM{id = 12, with = 1, last = 300})
	testing.expect_value(t, len(buddy_list(&s, &v)), 4)
	testing.expect_value(t, notes_conv(&v), proto.Conv_Id(12))
}

// A DM hidden up to a message newer than its newest is hidden from before the
// server's database was started over: it is shown again, while a DM hidden up
// to its newest message (or an empty one) stays hidden.
@(test)
test_unhide_stale :: proc(t: ^testing.T) {
	ui := new(UI)
	defer free(ui)
	defer settings.settings_destroy(&ui.settings)
	v: conn.View
	defer delete(v.dms)
	v.me = 1
	v.server_key[0] = 9
	append(&v.dms, conn.View_DM{id = 1, with = 2, last = 50, unread = 1})
	append(&v.dms, conn.View_DM{id = 2, with = 3, last = 60})
	append(&v.dms, conn.View_DM{id = 3, with = 4})
	settings.hide_dm(&ui.settings, v.server_key, 1, 1000)
	settings.hide_dm(&ui.settings, v.server_key, 2, 60)
	settings.hide_dm(&ui.settings, v.server_key, 3, 1)
	testing.expect_value(t, len(buddy_list(&ui.settings, &v)), 0)

	unhide_stale(ui, nil, &v)
	list := buddy_list(&ui.settings, &v)
	testing.expect_value(t, len(list), 1)
	testing.expect_value(t, list[0].conv, proto.Conv_Id(1))
	testing.expect(t, ui.settings_dirty)
	// Hidden again later, it stays hidden until something new is said.
	settings.hide_dm(&ui.settings, v.server_key, 1, 50)
	unhide_stale(ui, nil, &v)
	testing.expect_value(t, len(buddy_list(&ui.settings, &v)), 0)
}

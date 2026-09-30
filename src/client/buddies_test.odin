#+build !wasi
package client

import "core:os"
import "core:path/filepath"
import "core:testing"

import "common:proto"

@(test)
test_buddies_saved_and_loaded :: proc(t: ^testing.T) {
	alice, bob: [proto.KEY_SIZE]u8
	alice[0], bob[0] = 1, 2

	s := DEFAULT_SETTINGS
	testing.expect(t, add_buddy(&s, alice, "alice"))
	testing.expect(t, add_buddy(&s, bob, ""))
	testing.expect(t, !add_buddy(&s, alice, "alice"), "adding again changed something")
	testing.expect(t, add_buddy(&s, alice, "alice2"), "a new name wasn't kept")

	dir := os.get_env("TMPDIR", context.temp_allocator)
	if dir == "" {
		dir = "/tmp"
	}
	path, _ := filepath.join({dir, "yap-buddies-test.json"}, context.temp_allocator)
	defer os.remove(path)
	settings_save(path, s)
	settings_destroy(&s)

	loaded := settings_load(path)
	defer settings_destroy(&loaded)
	testing.expect(t, is_buddy(&loaded, alice))
	testing.expect(t, is_buddy(&loaded, bob))
	testing.expect_value(t, loaded.buddies[user_key(alice)].name, "alice2")

	testing.expect(t, remove_buddy(&loaded, bob))
	testing.expect(t, !remove_buddy(&loaded, bob))
	testing.expect(t, !is_buddy(&loaded, bob))
}

@(test)
test_buddy_list_order :: proc(t: ^testing.T) {
	a, b, c: [proto.KEY_SIZE]u8
	a[0], b[0], c[0] = 1, 2, 3

	s: Settings
	defer settings_destroy(&s)
	add_buddy(&s, a, "zed")
	add_buddy(&s, b, "Amy")
	add_buddy(&s, c, "bob")

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

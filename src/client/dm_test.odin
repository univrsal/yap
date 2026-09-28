#+build !wasi
package client

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "../common"
import "../proto"

// Deleting a conversation takes it off the screen, out of the index and
// off the disk, and leaves the others as they were.
@(test)
test_dm_delete :: proc(t: ^testing.T) {
	alice, bob: [proto.KEY_SIZE]u8
	alice[0], bob[0] = 1, 2

	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" {
		tmp = "/tmp"
	}
	dir, _ := filepath.join(
		{tmp, fmt.tprintf("yap-dm-test-%d", os.get_pid())},
		context.temp_allocator,
	)
	defer os.remove_all(dir)
	key_path, _ := filepath.join({dir, "client.key"}, context.temp_allocator)

	view: View
	view_init(&view)
	defer view_destroy(&view)
	c := new(Voice_Client, context.temp_allocator)
	c.view = &view
	dm_open(c, key_path)
	for key, i in ([][proto.KEY_SIZE]u8{alice, bob}) {
		conv := dm_conversation(c, key)
		add_message(conv, {id = u64(i + 1), text = strings.clone("hello"), state = .Received})
		dm_save(c, conv)
		publish_dm_conversation(c, conv, unread = true)
	}
	alice_file := strings.concatenate({c.dms.dir, "/", user_key(alice), ".json"}, context.temp_allocator)
	testing.expect(t, common.store_exists(alice_file))

	dm_delete(c, alice)
	testing.expect(t, alice not_in c.dms.conversations)
	testing.expect(t, bob in c.dms.conversations)
	testing.expect(t, alice not_in view.dms)
	testing.expect(t, bob in view.dms)
	testing.expect_value(t, dm_unread(&view), 1)
	testing.expect(t, !common.store_exists(alice_file))
	dm_delete(c, alice) // already gone: nothing to do
	dm_destroy(c)

	// What a restart finds: only bob.
	again := new(Voice_Client, context.temp_allocator)
	dm_open(again, key_path)
	defer dm_destroy(again)
	testing.expect_value(t, len(again.dms.conversations), 1)
	testing.expect(t, bob in again.dms.conversations)
}

#+build !wasi
package conn

import "core:log"
import "core:os"
import "core:testing"

import "common:proto"

@(test)
test_known_servers :: proc(t: ^testing.T) {
	path := "known_servers_test.tmp"
	os.remove(path)
	defer os.remove(path)

	a, b, c: [proto.KEY_SIZE]byte
	a[0], b[0], c[0] = 1, 2, 3

	trust, _ := check_server_key(path, "a:1", a)
	testing.expect_value(t, trust, Trust.New)
	testing.expect(t, remember_server_key(path, "a:1", a))
	testing.expect(t, remember_server_key(path, "b:1", b))

	trust, _ = check_server_key(path, "a:1", a)
	testing.expect_value(t, trust, Trust.Known)
	saved: [proto.KEY_SIZE]byte
	trust, saved = check_server_key(path, "a:1", c)
	testing.expect_value(t, trust, Trust.Mismatch)
	testing.expect_value(t, saved, a)

	// Trusting the new key replaces the old one and leaves the other entries unchanged.
	testing.expect(t, replace_server_key(path, "a:1", c))
	trust, _ = check_server_key(path, "a:1", c)
	testing.expect_value(t, trust, Trust.Known)
	trust, _ = check_server_key(path, "b:1", b)
	testing.expect_value(t, trust, Trust.Known)

	list := list_known_servers(path, context.temp_allocator)
	testing.expect_value(t, len(list), 2)
	if len(list) == 2 {
		testing.expect_value(t, list[0].addr, "b:1")
		testing.expect_value(t, list[1].addr, "a:1")
		testing.expect_value(t, list[1].key, c)
	}

	// After the key was forgotten, the next key is trusted as on a first connection.
	testing.expect(t, forget_server_key(path, "a:1"))
	trust, _ = check_server_key(path, "a:1", a)
	testing.expect_value(t, trust, Trust.New)
	testing.expect_value(t, len(list_known_servers(path, context.temp_allocator)), 1)

	// Addresses are the same regardless of case: a host name typed
	// differently is still the same server, not a new one.
	trust, _ = check_server_key(path, "B:1", c)
	testing.expect_value(t, trust, Trust.Mismatch)
	testing.expect(t, forget_server_key(path, "B:1"))
	testing.expect_value(t, len(list_known_servers(path, context.temp_allocator)), 0)
}

@(test)
test_known_servers_unreadable :: proc(t: ^testing.T) {
	// A file that's there but can't be read (here it's a folder) trusts
	// nothing, and isn't overwritten.
	path := "known_servers_unreadable.tmp"
	os.remove(path)
	testing.expect_value(t, os.make_directory(path), nil)
	defer os.remove(path)
	a: [proto.KEY_SIZE]byte
	a[0] = 1
	context.logger = log.nil_logger() // the failed reads are logged as errors
	trust, _ := check_server_key(path, "a:1", a)
	testing.expect_value(t, trust, Trust.Unreadable)
	testing.expect(t, !remember_server_key(path, "a:1", a))
}

#+build !wasi
package conn

import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"

import "client:settings"
import "common:proto"

@(test)
test_image_cache :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "yap-image-cache-*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)

	a, b: [proto.KEY_SIZE]u8
	a[0], b[0] = 1, 2
	big := make([]u8, 600)
	defer delete(big)
	for &x, i in big {
		x = u8(i)
	}

	ic: Image_Cache
	testing.expect(t, image_cache_open(&ic, dir, 1000))
	image_cache_store(&ic, a, 7, big[:300])
	image_cache_store(&ic, b, 7, big[:400])
	bytes, count := image_cache_usage(&ic)
	testing.expect_value(t, bytes, 700)
	testing.expect_value(t, count, 2)

	// Each server has its own 7.
	got, ok := image_cache_load(&ic, a, 7)
	testing.expect(t, ok)
	testing.expect_value(t, len(got), 300)
	testing.expect_value(t, got[299], u8(299 % 256))
	delete(got)
	_, ok = image_cache_load(&ic, a, 8)
	testing.expect(t, !ok)

	// Asked for, it's there the first time it's looked for; one it
	// hasn't got isn't asked for at all.
	testing.expect_value(t, image_cache_request(&ic, a, 8), Cache_Request(0))
	req := image_cache_request(&ic, b, 7)
	testing.expect(t, req != 0)
	state: Cache_Poll
	got, state = image_cache_poll(&ic, req)
	testing.expect_value(t, state, Cache_Poll.Done)
	testing.expect_value(t, len(got), 400)
	delete(got)
	_, state = image_cache_poll(&ic, req)
	testing.expect_value(t, state, Cache_Poll.Failed)
	req = image_cache_request(&ic, b, 7)
	image_cache_cancel(&ic, req)
	_, state = image_cache_poll(&ic, req)
	testing.expect_value(t, state, Cache_Poll.Failed)
	// a's 7 is used again, so b's is the oldest.
	got, _ = image_cache_load(&ic, a, 7)
	delete(got)

	// Past the maximum the one used longest ago goes: b's, as a's was
	// just loaded.
	time.sleep(10 * time.Millisecond)
	image_cache_store(&ic, a, 9, big[:500])
	_, ok = image_cache_load(&ic, b, 7)
	testing.expect(t, !ok)
	bytes, count = image_cache_usage(&ic)
	testing.expect_value(t, bytes, 800)
	testing.expect_value(t, count, 2)

	// Too big to keep at all.
	image_cache_store(&ic, a, 10, make([]u8, 2000, context.temp_allocator))
	_, count = image_cache_usage(&ic)
	testing.expect_value(t, count, 2)

	// Opened again, it finds what it kept, and clears out a half-written
	// file.
	part, _ := filepath.join({dir, settings.key_hex(a), "11.part"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(part, big[:10]) == nil)
	image_cache_destroy(&ic)
	ic = {}
	testing.expect(t, image_cache_open(&ic, dir, 1000))
	bytes, count = image_cache_usage(&ic)
	testing.expect_value(t, bytes, 800)
	testing.expect_value(t, count, 2)
	testing.expect(t, !os.exists(part))
	got, ok = image_cache_load(&ic, a, 9)
	testing.expect(t, ok)
	testing.expect_value(t, len(got), 500)
	delete(got)

	// A smaller maximum drops what's over it.
	image_cache_set_max(&ic, 600)
	bytes, count = image_cache_usage(&ic)
	testing.expect_value(t, bytes, 500)
	testing.expect_value(t, count, 1)

	// Clearing deletes the pictures and nothing else.
	other, _ := filepath.join({dir, "keep-me"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(other, big[:1]) == nil)
	image_cache_clear(&ic)
	bytes, count = image_cache_usage(&ic)
	testing.expect_value(t, bytes, 0)
	testing.expect_value(t, count, 0)
	testing.expect(t, os.exists(other))
	server_dir, _ := filepath.join({dir, settings.key_hex(a)}, context.temp_allocator)
	testing.expect(t, !os.exists(server_dir))
	image_cache_destroy(&ic)
}

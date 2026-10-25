#+build !wasi
package conn

import "core:testing"

// A picture's bytes are shared with the View rather than copied, and outlive
// whichever of the two lets go of them first.
@(test)
test_blob_bytes_shared :: proc(t: ^testing.T) {
	c := new(Server_Conn)
	defer free(c)
	v := new(View)
	defer free(v)
	view_init(v)
	defer view_destroy(v)
	c.view = v

	data := make([]u8, 1000)
	data[0] = 42
	blob_have(c, 7, data, 10, 10)
	img := v.blobs[7]
	testing.expect_value(t, img.state, Image_State.Ready)
	testing.expect(t, raw_data(img.jpeg) == raw_data(c.blobs.cache[7].data), "the View has a copy")
	testing.expect_value(t, img.shared.refs, 2)

	// The cache lets go of it (as when it is trimmed); the View still reads it.
	blobs_destroy(c)
	testing.expect_value(t, v.blobs[7].shared.refs, 1)
	testing.expect_value(t, v.blobs[7].jpeg[0], 42)
	// view_destroy frees it, which the test's allocator checks.
}

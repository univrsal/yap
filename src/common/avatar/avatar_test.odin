#+build !wasi
package avatar

import "core:os"
import "core:testing"
import stbi "vendor:stb/image"

import "common:proto"

// The pictures of the sample export of tools/mattermost.
SAMPLE_PICTURES :: #directory + "../../../tools/mattermost/sample/data/users"

@(test)
test_from_bytes :: proc(t: ^testing.T) {
	dir, err := os.read_all_directory_by_path(SAMPLE_PICTURES, context.temp_allocator)
	testing.expect(t, err == nil && len(dir) > 0)
	for entry in dir {
		data, read_err := os.read_entire_file(
			os.join_path(
				{SAMPLE_PICTURES, entry.name, "profile.png"}, // users/<id>/profile.png
				context.temp_allocator,
			) or_else "",
			context.temp_allocator,
		)
		testing.expect(t, read_err == nil)
		jpeg, side, ok := from_bytes(data, context.temp_allocator)
		testing.expectf(t, ok, "%s", entry.name)
		testing.expect(t, side > 0 && side <= proto.MAX_AVATAR_SIDE)
		testing.expect(t, len(jpeg) <= proto.MAX_AVATAR_SIZE)
		// A JPEG of that size, which is what the server checks for.
		w, h, comp: i32
		testing.expect(
			t,
			stbi.info_from_memory(raw_data(jpeg), i32(len(jpeg)), &w, &h, &comp) == 1,
		)
		testing.expect_value(t, int(w), side)
		testing.expect_value(t, int(h), side)
	}
}

@(test)
test_prepare :: proc(t: ^testing.T) {
	// A wide, transparent picture: the centre square is taken, scaled down to
	// the limit, and the transparency is white.
	width, height := 600, 400
	pixels := make([]u8, width * height * 4, context.temp_allocator)
	jpeg, side, ok := prepare(width, height, pixels, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, side, 256) // not 400
	w, h, comp: i32
	testing.expect(t, stbi.info_from_memory(raw_data(jpeg), i32(len(jpeg)), &w, &h, &comp) == 1)
	testing.expect_value(t, w, 256)
	got_w, got_h, got_pixels, decoded := decode(jpeg)
	testing.expect(t, decoded)
	defer stbi.image_free(raw_data(got_pixels))
	testing.expect_value(t, got_w, 256)
	testing.expect_value(t, got_h, 256)
	testing.expect(t, got_pixels[0] >= 250 && got_pixels[1] >= 250 && got_pixels[2] >= 250)

	// Small pictures are not scaled up, and nonsense is refused.
	small := make([]u8, 40 * 40 * 4, context.temp_allocator)
	_, side, ok = prepare(40, 40, small, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, side, 40)
	_, _, ok = prepare(0, 0, nil, context.temp_allocator)
	testing.expect(t, !ok)
	_, _, ok = from_bytes(transmute([]u8)string("not a picture"), context.temp_allocator)
	testing.expect(t, !ok)
}

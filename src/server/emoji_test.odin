package server

import "core:bytes"
import "core:encoding/endian"
import "core:hash"
import "core:image/qoi"
import "core:os"
import "core:testing"

import "common:proto"

// test_png is a PNG of one colour, uncompressed: enough for the emoji to
// read.
@(private = "file")
test_png :: proc(width, height: int, rgba: [4]u8) -> []u8 {
	rgba := rgba
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A)
	chunk :: proc(out: ^[dynamic]u8, kind: string, data: []u8) {
		n: [4]u8
		endian.unchecked_put_u32be(n[:], u32(len(data)))
		append(out, ..n[:])
		start := len(out)
		append(out, kind)
		append(out, ..data)
		endian.unchecked_put_u32be(n[:], hash.crc32(out[start:]))
		append(out, ..n[:])
	}
	ihdr: [13]u8
	endian.unchecked_put_u32be(ihdr[0:], u32(width))
	endian.unchecked_put_u32be(ihdr[4:], u32(height))
	ihdr[8], ihdr[9] = 8, 6 // 8 bits, RGBA
	chunk(&out, "IHDR", ihdr[:])

	raw := make([dynamic]u8, context.temp_allocator)
	for _ in 0 ..< height {
		append(&raw, 0) // no filter
		for _ in 0 ..< width {
			append(&raw, ..rgba[:])
		}
	}
	// zlib, stored blocks.
	z := make([dynamic]u8, context.temp_allocator)
	append(&z, 0x78, 0x01)
	for at := 0; at < len(raw); at += 65535 {
		n := min(65535, len(raw) - at)
		append(&z, 1 if at + n == len(raw) else 0, u8(n), u8(n >> 8), ~u8(n), ~u8(n >> 8))
		append(&z, ..raw[at:at + n])
	}
	a: [4]u8
	endian.unchecked_put_u32be(a[:], hash.adler32(raw[:]))
	append(&z, ..a[:])
	chunk(&out, "IDAT", z[:])
	chunk(&out, "IEND", nil)
	return out[:]
}

@(test)
test_emoji_sheet :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "yap-test-*", context.temp_allocator)
	defer remove_tree(dir)
	path :: proc(dir, name: string) -> string {
		p, _ := os.join_path({dir, name}, context.temp_allocator)
		return p
	}

	// No folder: no emoji, and nothing wrong.
	none := build_sheet(path(dir, "emoji"))
	testing.expect(t, none.ok)
	testing.expect_value(t, len(none.names), 0)
	built_sheet_destroy(&none)

	emoji := path(dir, "emoji")
	testing.expect(t, os.make_directory(emoji) == nil)
	testing.expect(
		t,
		os.write_entire_file(path(emoji, "party.png"), test_png(64, 32, {255, 0, 0, 255})) == nil,
	)
	testing.expect(
		t,
		os.write_entire_file(path(emoji, "ok_2.png"), test_png(8, 8, {0, 255, 0, 128})) == nil,
	)
	testing.expect(
		t,
		os.write_entire_file(path(emoji, "Bad Name.png"), test_png(8, 8, {0, 0, 255, 255})) == nil,
	)
	testing.expect(t, os.write_entire_file(path(emoji, "fake.png"), "not a picture") == nil)
	testing.expect(t, os.write_entire_file(path(emoji, "notes.txt"), "hello") == nil)

	sheet := build_sheet(emoji)
	defer built_sheet_destroy(&sheet)
	testing.expect(t, sheet.ok)
	testing.expect_value(t, len(sheet.names), 2)
	if len(sheet.names) == 2 {
		testing.expect_value(t, sheet.names[0], "ok_2")
		testing.expect_value(t, sheet.names[1], "party")
	}
	img, err := qoi.load_from_bytes(sheet.qoi, {}, context.temp_allocator)
	testing.expect(t, err == nil && img != nil)
	if img != nil {
		testing.expect_value(t, img.width, EMOJI_COLUMNS * EMOJI_CELL)
		testing.expect_value(t, img.height, EMOJI_CELL)
		px := bytes.buffer_to_bytes(&img.pixels)
		// The second cell: party, 64 by 32, scaled to 32 by 16 and
		// centred, red; transparent above and below.
		at :: proc(px: []u8, x, y: int) -> [4]u8 {
			i := (y * EMOJI_COLUMNS * EMOJI_CELL + x) * 4
			return {px[i], px[i + 1], px[i + 2], px[i + 3]}
		}
		testing.expect_value(t, at(px, EMOJI_CELL + 16, 16), [4]u8{255, 0, 0, 255})
		testing.expect_value(t, at(px, EMOJI_CELL + 16, 2)[3], 0)
		testing.expect_value(t, at(px, 16, 16), [4]u8{0, 255, 0, 128})
	}

	// The same folder makes the same sheet.
	again := build_sheet(emoji)
	defer built_sheet_destroy(&again)
	testing.expect(t, string(again.qoi) == string(sheet.qoi))
	testing.expect(t, proto.custom_emoji_name_ok("ok_2"))
}

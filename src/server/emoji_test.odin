package server

import "core:bytes"
import "core:encoding/endian"
import "core:fmt"
import "core:hash"
import "core:image/qoi"
import "core:os"
import "core:testing"

import "common:proto"
import "common:webp"

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
		testing.expect_value(t, img.width, EMOJI_COLUMNS * EMOJI_STRIDE)
		testing.expect_value(t, img.height, EMOJI_STRIDE)
		px := bytes.buffer_to_bytes(&img.pixels)
		// The second cell: party, 64 by 32, scaled to 32 by 16 and
		// centred, red; transparent above and below.
		at :: proc(px: []u8, x, y: int) -> [4]u8 {
			i := (y * EMOJI_COLUMNS * EMOJI_STRIDE + x) * 4
			return {px[i], px[i + 1], px[i + 2], px[i + 3]}
		}
		testing.expect_value(t, at(px, EMOJI_STRIDE + 16, 16), [4]u8{255, 0, 0, 255})
		testing.expect_value(t, at(px, EMOJI_STRIDE + 16, 2)[3], 0)
		testing.expect_value(t, at(px, 16, 16), [4]u8{0, 255, 0, 128})
		// The gap after a cell is transparent.
		testing.expect_value(t, at(px, EMOJI_CELL, 16)[3], 0)
		testing.expect_value(t, at(px, EMOJI_STRIDE + 16, EMOJI_CELL)[3], 0)
	}

	// The same folder makes the same sheet.
	again := build_sheet(emoji)
	defer built_sheet_destroy(&again)
	testing.expect(t, string(again.qoi) == string(sheet.qoi))
	testing.expect(t, proto.custom_emoji_name_ok("ok_2"))
	testing.expect_value(t, len(sheet.anims), 0)
}

// The emoji that move are kept as blobs, which purging leaves alone
// (also without the server: it goes by the meta rows), and anyone may
// fetch; when they're gone from the folder, so are their meta rows.
@(test)
test_emoji_frames_kept :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "yap-test-*", context.temp_allocator)
	defer remove_tree(dir)
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	testing.expect(t, blob_store_open(&s.blobs, &s.db, dir))
	emoji, _ := os.join_path({dir, "emoji"}, context.temp_allocator)
	testing.expect(t, os.make_directory(emoji) == nil)
	spin, _ := os.join_path({emoji, "spin.gif"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(spin, ANIM_GIF) == nil)

	emoji_open(s, emoji)
	defer emoji_close(s)
	testing.expect_value(t, len(s.emoji.animated), 1)
	if len(s.emoji.animated) != 1 {
		return
	}
	frames := s.emoji.animated[0].blob
	testing.expect(t, emoji_frames_known(s, frames))
	testing.expect(t, !emoji_frames_known(s, s.emoji.blob))
	key := fmt.tprintf("%s%d", EMOJI_FRAMES_META, frames)
	kept, found := db_meta(&s.db, key)
	testing.expect(t, found && Blob_Id(kept) == frames)

	// Everything old enough to go, and one blob nothing uses.
	orphan, _ := blob_put(&s.blobs, .File, []u8{1, 2, 3})
	for id in ([]Blob_Id{frames, s.emoji.blob, orphan}) {
		q := db_stmt(&s.db, .Blob_Touch)
		db_bind_int(q, 1, i64(id))
		db_bind_int(q, 2, 0)
		testing.expect(t, db_run(&s.db, q))
	}
	append(&s.retention.steps, Purge_Step{kind = .Collect})
	_, collected := retention_drain(&s.retention, &s.blobs)
	testing.expect_value(t, collected, 1)
	_, found = blob_get(&s.blobs, frames)
	testing.expect(t, found, "the frames went")
	_, found = blob_get(&s.blobs, s.emoji.blob)
	testing.expect(t, found, "the sheet went")
	_, found = blob_get(&s.blobs, orphan)
	testing.expect(t, !found, "the unused blob stayed")

	// Taken out of the folder: still, and its meta row gone.
	testing.expect(t, os.remove(spin) == nil)
	still, _ := os.join_path({emoji, "spin.png"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(still, test_png(8, 8, {0, 0, 255, 255})) == nil)
	sheet := build_sheet(emoji)
	emoji_take_for_test(s, &sheet)
	built_sheet_destroy(&sheet)
	testing.expect_value(t, len(s.emoji.animated), 0)
	_, found = db_meta(&s.db, key)
	testing.expect(t, !found)
}

// 6x4: red for 50 ms, green for 100, then blue (half transparent in the
// WebP), 5 ms in the WebP and 0 in the GIF.
@(private = "file")
ANIM_WEBP := #load("../common/webp/testdata/anim.webp")
@(private = "file")
ANIM_GIF := #load("../common/gif/testdata/anim.gif")
@(private = "file")
STILL_WEBP := #load("../common/webp/testdata/still.webp")
// 100 frames of 20 ms.
@(private = "file")
GIF_100 := #load("../common/gif/testdata/anim_100.gif")

@(test)
test_emoji_animated :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "yap-test-*", context.temp_allocator)
	defer remove_tree(dir)
	write :: proc(t: ^testing.T, dir, name: string, data: []u8) {
		p, _ := os.join_path({dir, name}, context.temp_allocator)
		testing.expect(t, os.write_entire_file(p, data) == nil)
	}
	write(t, dir, "spin.gif", ANIM_GIF)
	write(t, dir, "wave.webp", ANIM_WEBP)
	write(t, dir, "calm.webp", STILL_WEBP)
	write(t, dir, "many.gif", GIF_100)
	// Two of the same name: the PNG is the one.
	write(t, dir, "twice.png", test_png(8, 8, {0, 0, 255, 255}))
	write(t, dir, "twice.gif", ANIM_GIF)

	sheet := build_sheet(dir)
	defer built_sheet_destroy(&sheet)
	testing.expect(t, sheet.ok)
	testing.expect_value(t, len(sheet.names), 5)
	if len(sheet.names) == 5 {
		testing.expect_value(t, sheet.names[0], "calm")
		testing.expect_value(t, sheet.names[1], "many")
		testing.expect_value(t, sheet.names[2], "spin")
		testing.expect_value(t, sheet.names[3], "twice")
		testing.expect_value(t, sheet.names[4], "wave")
	}
	// Those that move: many, spin and wave, in order of their cells.
	testing.expect_value(t, len(sheet.anims), 3)
	if len(sheet.anims) != 3 {
		return
	}
	testing.expect_value(t, sheet.anims[0].index, 1)
	testing.expect_value(t, sheet.anims[1].index, 2)
	testing.expect_value(t, sheet.anims[2].index, 4)

	// Their frames, timed as clients show them (0 and 5 ms are 100).
	for a in sheet.anims[1:] {
		f, ok := proto.decode_emoji_frames(a.data)
		testing.expect(t, ok)
		testing.expect_value(t, len(f.durations), 3)
		testing.expect_value(t, f.columns, 2)
		if len(f.durations) == 3 {
			testing.expect_value(t, f.durations[0], 50)
			testing.expect_value(t, f.durations[1], 100)
			testing.expect_value(t, f.durations[2], 100)
		}
		w, h, read := webp.size(f.image)
		testing.expect(t, read)
		testing.expect_value(t, w, 2 * EMOJI_STRIDE)
		testing.expect_value(t, h, 2 * EMOJI_STRIDE)
		testing.expect_value(t, a.width, w)
		testing.expect_value(t, a.height, h)
		if read {
			// The second frame, green, in the second cell.
			px := make([]u8, w * h * 4, context.temp_allocator)
			testing.expect(t, webp.decode_into(f.image, px, w))
			i := (32 * w + EMOJI_STRIDE + 32) * 4
			testing.expect(t, px[i] < 40 && px[i + 1] > 200 && px[i + 3] == 255)
		}
	}

	// A hundred frames come down to 64, at the same speed: 2 s in all.
	f, ok := proto.decode_emoji_frames(sheet.anims[0].data)
	testing.expect(t, ok)
	testing.expect_value(t, len(f.durations), proto.MAX_EMOJI_FRAMES)
	testing.expect_value(t, f.columns, 8)
	total := 0
	for d in f.durations {
		total += int(d)
		testing.expect(t, d == 20 || d == 40)
	}
	testing.expect_value(t, total, 2000)

	// The sheet's cells are the first frames: spin's is red.
	img, err := qoi.load_from_bytes(sheet.qoi, {}, context.temp_allocator)
	testing.expect(t, err == nil && img != nil)
	if img != nil {
		px := bytes.buffer_to_bytes(&img.pixels)
		i := (32 * EMOJI_COLUMNS * EMOJI_STRIDE + 2 * EMOJI_STRIDE + 32) * 4
		testing.expect_value(t, [4]u8{px[i], px[i + 1], px[i + 2], px[i + 3]}, [4]u8{255, 0, 0, 255})
	}
}

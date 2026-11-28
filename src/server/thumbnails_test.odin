package server

import "core:os"
import "core:testing"
import "core:time"

import "common:webp"

// Tests of thumbnails (thumbnails.odin).

// test_bmp is an uncompressed 24-bit BMP of a gradient with some noise, which
// stb_image reads and which is large and compresses well, like a screenshot.
test_bmp :: proc(w, h: int) -> []u8 {
	row := (w * 3 + 3) / 4 * 4
	b := make([]u8, 54 + row * h, context.temp_allocator)
	put32 :: proc(b: []u8, at: int, v: int) {
		for i in 0 ..< 4 {
			b[at + i] = u8(v >> uint(8 * i))
		}
	}
	b[0], b[1] = 'B', 'M'
	put32(b, 2, len(b))
	put32(b, 10, 54)
	put32(b, 14, 40)
	put32(b, 18, w)
	put32(b, 22, h)
	b[26] = 1
	b[28] = 24
	put32(b, 34, row * h)
	for y in 0 ..< h {
		for x in 0 ..< w {
			p := 54 + y * row + x * 3
			b[p] = u8(x * 255 / w)
			b[p + 1] = u8(y * 255 / h)
			b[p + 2] = u8((x * 7 + y * 13) % 64)
		}
	}
	return b
}

@(private = "file")
write_file :: proc(t: ^testing.T, dir, name: string, data: []u8) -> string {
	path := file_in(dir, name)
	testing.expect(t, os.write_entire_file(path, data) == nil)
	return path
}

@(test)
test_make_thumbnail :: proc(t: ^testing.T) {
	dir := test_dir(t)
	defer remove_tree(dir)

	// A large picture is scaled to fit, keeping its shape, and is smaller.
	big := test_bmp(1200, 800)
	path := write_file(t, dir, "big.bmp", big)
	data, w, h := make_thumbnail(path, len(big), 512, 65, 64 * 1024, 64_000_000)
	defer delete(data)
	testing.expect(t, len(data) > 0)
	testing.expect_value(t, w, 512)
	testing.expect_value(t, h, 341)
	testing.expect(t, len(data) < len(big) / 10)
	dw, dh, ok := webp.size(data)
	testing.expect(t, ok)
	testing.expect_value(t, dw, 512)
	testing.expect_value(t, dh, 341)

	// A picture that is small in bytes and in pixels gets none.
	small := test_bmp(100, 60)
	path = write_file(t, dir, "small.bmp", small)
	data2, _, _ := make_thumbnail(path, len(small), 512, 65, 64 * 1024, 64_000_000)
	testing.expect_value(t, len(data2), 0)

	// Small in bytes but longer than a thumbnail is, gets one.
	wide := test_bmp(600, 20)
	path = write_file(t, dir, "wide.bmp", wide)
	data3, w3, h3 := make_thumbnail(path, len(wide), 512, 65, 1024 * 1024, 64_000_000)
	defer delete(data3)
	testing.expect(t, len(data3) > 0)
	testing.expect_value(t, w3, 512)
	testing.expect_value(t, h3, 17)

	// More pixels than the limit, and something that isn't a picture.
	path = write_file(t, dir, "big.bmp", big)
	data4, _, _ := make_thumbnail(path, len(big), 512, 65, 64 * 1024, 500_000)
	testing.expect_value(t, len(data4), 0)
	text := transmute([]u8)string("not a picture, just words")
	path = write_file(t, dir, "x.txt", text)
	data5, _, _ := make_thumbnail(path, len(text), 512, 65, 0, 64_000_000)
	testing.expect_value(t, len(data5), 0)

	// A file that is cut short, or that has changed size, gets none.
	path = write_file(t, dir, "cut.bmp", big[:len(big) / 2])
	data6, _, _ := make_thumbnail(path, len(big), 512, 65, 64 * 1024, 64_000_000)
	testing.expect_value(t, len(data6), 0)
}

// await_thumbnails collects finished thumbnails until none are pending.
@(private = "file")
await_thumbnails :: proc(t: ^testing.T, s: ^Server) {
	for _ in 0 ..< 1000 {
		thumbnails_sync(s)
		if thumbnails_pending(s) == 0 {
			return
		}
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, false, "the thumbnails never finished")
}

@(test)
test_thumbnails_store :: proc(t: ^testing.T) {
	dir := test_dir(t)
	defer remove_tree(dir)
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	testing.expect(t, blob_store_open(&s.blobs, &s.db, dir))
	thumbnails_open(s, {thumbnails = true})
	defer thumbnails_close(s)

	bmp := test_bmp(1024, 768)
	pic, ok := blob_put(&s.blobs, .File, bmp, 1024, 768)
	testing.expect(t, ok)
	text := transmute([]u8)string("just some text")
	other, ok2 := blob_put(&s.blobs, .File, text)
	testing.expect(t, ok2)

	thumbnails_submit(s, pic)
	thumbnails_submit(s, other)
	await_thumbnails(t, s)

	// The picture names a thumbnail of its own kind and shape, and the text
	// is marked as having none.
	b, _ := blob_get(&s.blobs, pic)
	testing.expect(t, b.thumb > 0)
	thumb, found := blob_get(&s.blobs, Blob_Id(b.thumb))
	testing.expect(t, found)
	testing.expect_value(t, thumb.kind, Blob_Kind.Thumbnail)
	testing.expect_value(t, thumb.width, 512)
	testing.expect_value(t, thumb.height, 384)
	o, _ := blob_get(&s.blobs, other)
	testing.expect_value(t, o.thumb, i64(-1))

	// The same picture again is not looked at twice.
	thumbnails_submit(s, pic)
	testing.expect_value(t, thumbnails_pending(s), 0)

	// Garbage collection leaves a thumbnail while its picture exists, and
	// takes it with the picture.
	q := db_query(&s.db, .Blob_Scan, i64(0), unix_ms() + 1, i64(0), i64(100))
	kept := 0
	for {
		row, more := db_step(&s.db, q)
		if !more || !row {
			break
		}
		if Blob_Id(db_col_int(q, 0)) == Blob_Id(b.thumb) {
			testing.expect_value(t, db_col_int(q, 2), i64(0))
			kept += 1
		}
	}
	testing.expect_value(t, kept, 1)
}

@(test)
test_make_thumbnail_jpeg :: proc(t: ^testing.T) {
	dir := test_dir(t)
	defer remove_tree(dir)
	jpeg := #load("../common/imagekind/testdata/turned.jpg")
	path := write_file(t, dir, "turned.jpg", jpeg)
	// Forced by a small side, since the picture is small itself. It is stored sideways
	// and says it is turned, so the thumbnail is upright: taller than wide.
	data, w, h := make_thumbnail(path, len(jpeg), 32, 65, 0, 64_000_000)
	defer delete(data)
	testing.expect(t, len(data) > 0)
	testing.expect(t, max(w, h) == 32 && w < h)
	dw, dh, ok := webp.size(data)
	testing.expect(t, ok && dw == w && dh == h)
}

@(test)
test_thumbnails_sweep :: proc(t: ^testing.T) {
	dir := test_dir(t)
	defer remove_tree(dir)
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	testing.expect(t, blob_store_open(&s.blobs, &s.db, dir))
	thumbnails_open(s, {thumbnails = true})
	defer thumbnails_close(s)
	s.thumbs.sweep_every = 0

	// Pictures that messages carry and that nobody has looked at, one that no
	// message carries, and a file that isn't a picture.
	pictures: [6]Blob_Id
	for &id, i in pictures {
		bmp := test_bmp(700 + i * 10, 500)
		ok: bool
		id, ok = blob_put(&s.blobs, .File, bmp, 700 + i * 10, 500)
		testing.expect(t, ok)
		testing.expect(
			t,
			db_write(&s.db, .Attach_Add, i64(100 + i), i64(0), i64(id), "a.bmp", i64(len(bmp))),
		)
	}
	orphan_bmp := test_bmp(640, 480)
	orphan, _ := blob_put(&s.blobs, .File, orphan_bmp, 640, 480)
	text := transmute([]u8)string("not a picture")
	notes, _ := blob_put(&s.blobs, .File, text)
	testing.expect(
		t,
		db_write(&s.db, .Attach_Add, i64(200), i64(0), i64(notes), "notes.txt", i64(len(text))),
	)

	for _ in 0 ..< 2000 {
		thumbnails_sync(s)
		if s.thumbs.sweep_done && thumbnails_pending(s) == 0 {
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, s.thumbs.sweep_done)
	testing.expect_value(t, s.thumbs.sweep_queued, 6)
	for id in pictures {
		b, _ := blob_get(&s.blobs, id)
		testing.expect(t, b.thumb > 0)
	}
	o, _ := blob_get(&s.blobs, orphan)
	testing.expect_value(t, o.thumb, i64(0))
	n, _ := blob_get(&s.blobs, notes)
	testing.expect_value(t, n.thumb, i64(0))

	// With every picture done, another sweep finds nothing to queue.
	s.thumbs.sweep_done = false
	s.thumbs.sweep_cursor = max(i64)
	before := s.thumbs.sweep_queued
	thumbnails_sync(s)
	testing.expect_value(t, s.thumbs.sweep_queued, before)
	testing.expect_value(t, thumbnails_pending(s), 0)
}

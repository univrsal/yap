package server

import "base:runtime"
import "core:bytes"
import "core:fmt"
import "core:hash"
import "core:image"
import "core:image/png"
import "core:image/qoi"
import "core:log"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import stbi "vendor:stb/image"

import "common:gif"
import "common:proto"
import "common:webp"

/*
The server's own emoji (src/common/proto/emoji.odin): a folder of
pictures the admin fills, `emoji/` in the data directory. `foo.png`,
`foo.webp` or `foo.gif` is the emoji `:foo:`; a file whose name isn't one
an emoji may have (2 to 32 of `a-z 0-9 _`), or that can't be read, is
skipped with a warning, as is a second file of the same name (the first
of png, webp, gif is the one).

They go to clients as one picture, the sheet: every emoji scaled into a
cell of EMOJI_CELL pixels (and a transparent pixel of gap after it),
EMOJI_COLUMNS to a row, in name order. Core Odin writes no PNG but writes
QOI, which both clients read in pure Odin, so the sheet is a QOI. It's
kept as a blob (of kind Emoji_Sheet), so an unchanged folder makes the
same blob and clients keep their copy. Every connection is told of it
when it logs in (Emoji_Sheet) and when it changes.

An animated WebP or GIF is an emoji that moves: its first frame is its
cell in the sheet, and all its frames (at most proto.MAX_EMOJI_FRAMES,
thinned out evenly if there are more, at the same speed) are scaled into
cells of their own, in a grid written as a WebP with how long each is
shown, a blob of kind Emoji_Frames (read_animation). The sheet's
Emoji_Sheet names them. A client from before animated emoji shows the
first frame.

The folder is looked at every EMOJI_RESCAN: a file added, removed or
changed has the sheet made again, on a thread of its own (reading and
scaling pictures takes a moment, and the loop carries voice), and told
to everyone when it's done. Nothing has to be restarted.
*/

EMOJI_DIR :: "emoji"
EMOJI_CELL :: 64 // pixels: twice the size an emoji is drawn at, for scaled-up screens
EMOJI_COLUMNS :: proto.EMOJI_SHEET_COLUMNS
// Every cell is followed by a transparent pixel, right and below, so
// scaling a cell up (filtering) doesn't bleed its neighbour into it.
EMOJI_STRIDE :: EMOJI_CELL + 1
EMOJI_RESCAN :: 5 * time.Second
// A picture bigger than this isn't read: an emoji is small.
EMOJI_MAX_FILE :: 1024 * 1024
// The kinds of file an emoji may be, the one used first when there are
// two of the same name.
EMOJI_EXTENSIONS :: [?]string{".png", ".webp", ".gif"}
// An animation's frames are read only if they're no bigger than this
// (each is scaled down to a cell straight away, but a GIF's are all
// decoded at once), and not more of them than EMOJI_MAX_READ: past that,
// it's its first frame.
EMOJI_MAX_SIDE :: 2048
EMOJI_GIF_BUDGET :: 64 * 1024 * 1024
EMOJI_MAX_READ :: 2000
// The quality of an animation's frames (WebP, its alpha kept as it is).
EMOJI_FRAMES_QUALITY :: 90

Custom_Emoji :: struct {
	dir:       string,
	// The sheet everyone has now: its blob (0 for none), and the names of
	// its cells (owned), and the ones that move.
	blob:      Blob_Id,
	size:      int,
	names:     [dynamic]string,
	animated:  [dynamic]proto.Emoji_Anim,
	// What the folder looked like when the sheet was made, and when it was
	// last looked at.
	signature: u64,
	last_scan: time.Tick,
	building:  ^Emoji_Build,
}

// Emoji_Build is a sheet being made on a thread of its own.
Emoji_Build :: struct {
	thread:    ^thread.Thread,
	dir:       string, // lent by Custom_Emoji
	signature: u64,
	done:      bool, // atomic: set by the thread
	sheet:     Built_Sheet,
}

Built_Sheet :: struct {
	qoi:   []u8, // owned; nil if there are no emoji
	names: []string, // owned, as is each
	anims: [dynamic]Built_Anim,
	ok:    bool,
}

// Built_Anim is an emoji that moves: the index of its cell, and its
// Emoji_Frames blob (owned), whose grid is width x height.
Built_Anim :: struct {
	index:         int,
	data:          []u8,
	width, height: int,
}

built_sheet_destroy :: proc(b: ^Built_Sheet) {
	delete(b.qoi)
	for n in b.names {
		delete(n)
	}
	delete(b.names)
	for a in b.anims {
		delete(a.data)
	}
	delete(b.anims)
	b^ = {}
}

/*
emoji_open makes the sheet for the folder as it is, before the loop
starts: everyone who logs in gets it. A folder that isn't there is a
server without emoji of its own.
*/
emoji_open :: proc(s: ^Server, dir: string) {
	e := &s.emoji
	e.dir = strings.clone(dir)
	e.signature = folder_signature(dir)
	e.last_scan = time.tick_now()
	sheet := build_sheet(dir)
	defer built_sheet_destroy(&sheet)
	emoji_take(s, &sheet, tell = false)
}

emoji_close :: proc(s: ^Server) {
	e := &s.emoji
	if b := e.building; b != nil {
		thread.join(b.thread)
		thread.destroy(b.thread)
		built_sheet_destroy(&b.sheet)
		free(b)
	}
	for n in e.names {
		delete(n)
	}
	delete(e.names)
	delete(e.animated)
	delete(e.dir)
	e^ = {}
}

// emoji_sync looks at the folder every EMOJI_RESCAN, makes the sheet
// again if it has changed, and takes it once it's made.
emoji_sync :: proc(s: ^Server) {
	e := &s.emoji
	if b := e.building; b != nil {
		if !sync.atomic_load(&b.done) {
			return
		}
		thread.join(b.thread)
		thread.destroy(b.thread)
		if b.sheet.ok {
			e.signature = b.signature
			emoji_take(s, &b.sheet, tell = true)
		}
		built_sheet_destroy(&b.sheet)
		free(b)
		e.building = nil
	}
	if e.dir == "" || time.tick_since(e.last_scan) < EMOJI_RESCAN {
		return
	}
	e.last_scan = time.tick_now()
	signature := folder_signature(e.dir)
	if signature == e.signature {
		return
	}
	log.infof("%s has changed; making the emoji again", e.dir)
	b := new(Emoji_Build)
	b.dir, b.signature = e.dir, signature
	b.thread = thread.create_and_start_with_poly_data(
		b,
		proc(b: ^Emoji_Build) {
			// This thread's own scratch space: the loop's is emptied every turn.
			scratch: runtime.Default_Temp_Allocator
			runtime.default_temp_allocator_init(&scratch, 4 * 1024 * 1024, context.allocator)
			defer runtime.default_temp_allocator_destroy(&scratch)
			context.temp_allocator = runtime.default_temp_allocator(&scratch)
			b.sheet = build_sheet(b.dir)
			sync.atomic_store(&b.done, true)
		},
		context,
	)
	if b.thread == nil {
		free(b)
		return
	}
	e.building = b
}

/*
emoji_take makes a sheet that was made the one everyone has: kept as a
blob, as are the frames of the ones that move, and with `tell`, told to
every connection. Takes the names over.
*/
@(private = "file")
emoji_take :: proc(s: ^Server, sheet: ^Built_Sheet, tell: bool) {
	e := &s.emoji
	blob: Blob_Id
	if len(sheet.qoi) > 0 {
		ok: bool
		rows := (len(sheet.names) + EMOJI_COLUMNS - 1) / EMOJI_COLUMNS
		blob, ok = blob_put(
			&s.blobs,
			.Emoji_Sheet,
			sheet.qoi,
			EMOJI_COLUMNS * EMOJI_STRIDE,
			rows * EMOJI_STRIDE,
		)
		if !ok {
			log.error("could not keep the sheet of emoji")
			return
		}
	}
	animated := make([dynamic]proto.Emoji_Anim)
	for a in sheet.anims {
		frames, ok := blob_put(&s.blobs, .Emoji_Frames, a.data, a.width, a.height)
		if !ok {
			log.errorf("could not keep the frames of :%s:; it stays still", sheet.names[a.index])
			continue
		}
		append(&animated, proto.Emoji_Anim{index = a.index, blob = frames, size = len(a.data)})
	}
	for n in e.names {
		delete(n)
	}
	clear(&e.names)
	append(&e.names, ..sheet.names)
	delete(sheet.names)
	sheet.names = nil
	delete(e.animated)
	e.animated = animated
	e.blob, e.size = blob, len(sheet.qoi)
	// For purging, which keeps them, also when it runs without the server
	// (retention.odin).
	db_meta_set(&s.db, EMOJI_SHEET_META, i64(blob))
	q := db_stmt(&s.db, .Meta_Delete_Like)
	db_bind_text(q, 1, EMOJI_FRAMES_META + "%")
	if !db_run(&s.db, q) {
		log.error("could not forget the frames of the emoji there were")
	}
	for a in e.animated {
		db_meta_set(&s.db, fmt.tprintf("%s%d", EMOJI_FRAMES_META, a.blob), i64(a.blob))
	}
	log.infof("%d emoji of our own, %d of them moving", len(e.names), len(e.animated))
	if tell {
		for _, u in s.conns {
			send_emoji_sheet(s, u)
		}
	}
}

// emoji_take_for_test is emoji_take, for tests, which tell nobody.
emoji_take_for_test :: proc(s: ^Server, sheet: ^Built_Sheet) {
	emoji_take(s, sheet, tell = false)
}

// send_emoji_sheet tells a connection of the server's emoji.
send_emoji_sheet :: proc(s: ^Server, u: ^Conn) {
	e := &s.emoji
	out := make(
		[]u8,
		proto.emoji_sheet_max_size(len(e.names), len(e.animated)),
		context.temp_allocator,
	)
	body := proto.encode_emoji_sheet(
		out,
		{
			blob = e.blob,
			size = e.size,
			cell = EMOJI_CELL,
			names = e.names[:],
			animated = e.animated[:],
		},
	)
	send_event(u, .Emoji_Sheet, body)
}

// emoji_known is whether `name` is one of the server's emoji.
emoji_known :: proc(s: ^Server, name: string) -> bool {
	_, found := slice.binary_search(s.emoji.names[:], name)
	return found
}

// emoji_frames_known is whether `blob` is the frames of one of the
// server's emoji that move, for anyone to fetch.
emoji_frames_known :: proc(s: ^Server, blob: Blob_Id) -> bool {
	for a in s.emoji.animated {
		if a.blob == blob {
			return true
		}
	}
	return false
}

/*
folder_signature is what changes when a file in the folder is added,
removed, renamed or written: a hash of the names, sizes and times.
*/
@(private = "file")
folder_signature :: proc(dir: string) -> u64 {
	files, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return 0
	}
	slice.sort_by(files, proc(a, b: os.File_Info) -> bool {
		return a.name < b.name
	})
	h := u64(len(files))
	for f in files {
		h = hash.fnv64a(transmute([]u8)f.name, h)
		stamp := [2]i64{f.size, time.time_to_unix_nano(f.modification_time)}
		h = hash.fnv64a(([^]u8)(&stamp)[:size_of(stamp)], h)
	}
	return h
}

// An emoji's file: which of EMOJI_EXTENSIONS it is (the first wins).
@(private = "file")
Emoji_File :: struct {
	path: string,
	kind: int,
}

/*
build_sheet makes the sheet from the folder: every picture that may be
an emoji, scaled into its cell, in name order, as a QOI, and the frames
of those that move. Safe to run on a thread of its own: it touches
nothing of the server's. `ok` is false only if the folder couldn't be
read or the sheet made; a folder that isn't there has no emoji.
*/
build_sheet :: proc(dir: string) -> (sheet: Built_Sheet) {
	sheet.ok = true
	if !os.exists(dir) {
		return
	}
	files, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		log.errorf("could not read %s: %v", dir, err)
		sheet.ok = false
		return
	}

	// One file for each name.
	chosen := make(map[string]Emoji_File, context.temp_allocator)
	for f in files {
		if f.type != .Regular {
			continue
		}
		kind := -1
		name: string
		for ext, k in EMOJI_EXTENSIONS {
			if strings.has_suffix(f.name, ext) {
				kind, name = k, f.name[:len(f.name) - len(ext)]
			}
		}
		if kind < 0 {
			continue
		}
		switch {
		case !proto.custom_emoji_name_ok(name):
			log.warnf("%s: an emoji's name is 2 to 32 of a-z, 0-9 and _; skipping it", f.fullpath)
			continue
		case f.size > EMOJI_MAX_FILE:
			log.warnf("%s is too big for an emoji; skipping it", f.fullpath)
			continue
		}
		if other, twice := chosen[name]; twice {
			first, second := other, Emoji_File{f.fullpath, kind}
			if second.kind < first.kind {
				first, second = second, first
			}
			log.warnf("%s and %s are both :%s:; using %s", first.path, second.path, name, first.path)
			chosen[name] = first
			continue
		}
		chosen[name] = {f.fullpath, kind}
	}
	order := make([dynamic]string, context.temp_allocator)
	for name in chosen {
		append(&order, name)
	}
	slice.sort(order[:])

	names := make([dynamic]string)
	cells := make([dynamic][]u8, context.temp_allocator) // RGBA, EMOJI_CELL square
	for name in order {
		path := chosen[name].path
		if len(names) >= proto.MAX_CUSTOM_EMOJI {
			log.warnf("%s: a server has at most %d emoji; skipping it", path, proto.MAX_CUSTOM_EMOJI)
			continue
		}
		cell, anim, ok := read_emoji(path)
		if !ok {
			continue
		}
		if anim.data != nil {
			anim.index = len(names)
			append(&sheet.anims, anim)
		}
		append(&names, strings.clone(name))
		append(&cells, cell)
	}
	sheet.names = names[:]
	if len(names) == 0 {
		return
	}

	// Shrinking as long as it's too big to send: the last ones go.
	for len(cells) > 0 {
		data, ok := encode_sheet(cells[:])
		if !ok {
			sheet.ok = false
			return
		}
		if len(data) <= proto.MAX_BLOB_SIZE {
			sheet.qoi = data
			break
		}
		delete(data)
		keep := len(cells) * 9 / 10
		log.warnf(
			"the sheet of %d emoji is too big; leaving out the last %d",
			len(cells),
			len(cells) - keep,
		)
		for n in names[keep:] {
			delete(n)
		}
		resize(&names, keep)
		resize(&cells, keep)
		sheet.names = names[:]
		for len(sheet.anims) > 0 && sheet.anims[len(sheet.anims) - 1].index >= keep {
			delete(pop(&sheet.anims).data)
		}
	}
	return
}

/*
read_emoji reads a picture and scales it into a cell (in the temp
allocator); for an animated WebP or GIF, also its frames, as the blob
that holds them (index left for the caller). What it is, is told by
what's in it rather than by its name.
*/
@(private = "file")
read_emoji :: proc(path: string) -> (cell: []u8, anim: Built_Anim, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		log.warnf("could not read %s: %v", path, err)
		return
	}
	switch {
	case webp.is_webp(data):
		return read_webp(path, data)
	case gif.is_gif(data):
		return read_gif(path, data)
	}
	img, png_err := png.load_from_bytes(data, {.alpha_add_if_missing}, context.temp_allocator)
	if png_err != nil || img == nil {
		log.warnf("%s isn't a PNG, WebP or GIF that can be read; skipping it", path)
		return
	}
	// In the temp allocator, all of it: nothing to destroy.
	if img.depth != 8 || img.channels != 4 || img.width <= 0 || img.height <= 0 {
		log.warnf("%s: only 8-bit pictures make emoji; skipping it", path)
		return
	}
	return scale_cell(bytes.buffer_to_bytes(&img.pixels), img.width, img.height), {}, true
}

// read_webp is read_emoji for a WebP, still or animated.
@(private = "file")
read_webp :: proc(path: string, data: []u8) -> (cell: []u8, anim: Built_Anim, ok: bool) {
	dec, info, opened := webp.anim_open(data)
	if !opened {
		log.warnf("%s isn't a WebP that can be read; skipping it", path)
		return
	}
	defer webp.anim_close(dec)
	if info.width > EMOJI_MAX_SIDE || info.height > EMOJI_MAX_SIDE || info.width <= 0 || info.height <= 0 {
		log.warnf("%s is %dx%d, too big for an emoji; skipping it", path, info.width, info.height)
		return
	}
	frames := info.frames
	if frames > EMOJI_MAX_READ {
		log.warnf("%s has %d frames, too many to read; it stays still", path, frames)
		frames = 1
	}
	thin := Thinning {
		frames = frames,
	}
	thin_start(&thin)
	ended := 0
	for i in 0 ..< frames {
		pixels, ends, next := webp.anim_next(dec, info)
		if next != .Frame {
			if i == 0 {
				log.warnf("%s isn't a WebP that can be read; skipping it", path)
				return
			}
			log.warnf("%s is broken after %d frames; it stays still", path, i)
			thin_still(&thin)
			break
		}
		thin_frame(&thin, i, ends - ended, pixels, info.width, info.height)
		ended = ends
	}
	return thin_finish(&thin, path)
}

// read_gif is read_emoji for a GIF, still or animated.
@(private = "file")
read_gif :: proc(path: string, data: []u8) -> (cell: []u8, anim: Built_Anim, ok: bool) {
	g, read := gif.info(data)
	if !read || g.width <= 0 || g.height <= 0 {
		log.warnf("%s isn't a GIF that can be read; skipping it", path)
		return
	}
	if g.width > EMOJI_MAX_SIDE || g.height > EMOJI_MAX_SIDE {
		log.warnf("%s is %dx%d, too big for an emoji; skipping it", path, g.width, g.height)
		return
	}
	all := g.frames > 1
	if all && (g.frames > EMOJI_MAX_READ || i64(g.width) * i64(g.height) * 4 * i64(g.frames) > EMOJI_GIF_BUDGET) {
		log.warnf("%s has %d frames, too many to read; it stays still", path, g.frames)
		all = false
	}
	if !all {
		w, h, comp: i32
		pixels := stbi.load_from_memory(raw_data(data), i32(len(data)), &w, &h, &comp, 4)
		if pixels == nil {
			log.warnf("%s isn't a GIF that can be read; skipping it", path)
			return
		}
		defer stbi.image_free(pixels)
		return scale_cell(pixels[:int(w) * int(h) * 4], int(w), int(h)), {}, true
	}
	delays: [^]i32
	x, y, z, comp: i32
	pixels := stbi.load_gif_from_memory(raw_data(data), i32(len(data)), &delays, &x, &y, &z, &comp, 4)
	if pixels == nil || x <= 0 || y <= 0 || z <= 0 {
		log.warnf("%s isn't a GIF that can be read; skipping it", path)
		return
	}
	defer stbi.image_free(pixels)
	defer stbi.image_free(rawptr(delays))
	thin := Thinning {
		frames = int(z),
	}
	thin_start(&thin)
	n := int(x) * int(y) * 4
	for i in 0 ..< int(z) {
		thin_frame(&thin, i, int(delays[i]), pixels[i * n:][:n], int(x), int(y))
	}
	return thin_finish(&thin, path)
}

/*
Thinning keeps at most proto.MAX_EMOJI_FRAMES of an animation's frames:
they're split into that many runs, as even as they go, and the first of
each run is kept (scaled into a cell), shown for the whole run's time,
so the animation keeps its speed.
*/
@(private = "file")
Thinning :: struct {
	frames:    int, // in the animation
	kept:      int, // how many are kept
	run:       int, // the run the last frame taken was in
	cells:     [dynamic][]u8,
	durations: [dynamic]int,
}

@(private = "file")
thin_start :: proc(t: ^Thinning) {
	t.kept = min(t.frames, proto.MAX_EMOJI_FRAMES)
	t.run = 0
	t.cells = make([dynamic][]u8, context.temp_allocator)
	t.durations = make([dynamic]int, context.temp_allocator)
}

/*
thin_frame takes frame `i` (they come in order), which says it's shown
for `ms`. Run k starts at frame k * frames / kept; the first frame of
each is the one kept.
*/
@(private = "file")
thin_frame :: proc(t: ^Thinning, i, ms: int, pixels: []u8, width, height: int) {
	for t.run + 1 < t.kept && (t.run + 1) * t.frames / t.kept <= i {
		t.run += 1
	}
	if t.run >= len(t.cells) {
		append(&t.cells, scale_cell(pixels, width, height))
		append(&t.durations, 0)
	}
	t.durations[t.run] += frame_ms(ms)
}

// thin_still keeps only the first frame: the emoji stays still.
@(private = "file")
thin_still :: proc(t: ^Thinning) {
	resize(&t.cells, min(len(t.cells), 1))
	resize(&t.durations, min(len(t.durations), 1))
}

// thin_finish is the first frame's cell, and with more than one frame
// kept, the blob of all of them.
@(private = "file")
thin_finish :: proc(t: ^Thinning, path: string) -> (cell: []u8, anim: Built_Anim, ok: bool) {
	if len(t.cells) == 0 {
		return
	}
	cell, ok = t.cells[0], true
	if len(t.cells) > 1 {
		anim = encode_frames(t.cells[:], t.durations[:], path)
	}
	return
}

// frame_ms is how long a frame that says `ms` is shown, as clients have
// it: a frame that says 10 ms or less is shown for 100, as browsers do,
// and none for less than 20.
@(private = "file")
frame_ms :: proc(ms: int) -> int {
	if ms <= 10 {
		return 100
	}
	return max(ms, 20)
}

/*
encode_frames lays an animation's cells out in a grid as near square as
it goes, and writes it, with each frame's time, as an Emoji_Frames blob.
Nothing (the emoji stays still) if that's too big to send.
*/
@(private = "file")
encode_frames :: proc(cells: [][]u8, durations: []int, path: string) -> (anim: Built_Anim) {
	n := len(cells)
	columns := int(math.ceil(math.sqrt(f64(n))))
	rows := (n + columns - 1) / columns
	width, height := columns * EMOJI_STRIDE, rows * EMOJI_STRIDE
	pixels := make([]u8, width * height * 4)
	defer delete(pixels)
	place_cells(pixels, width, columns, cells)
	image, ok := webp.encode_rgba(pixels, width, height, EMOJI_FRAMES_QUALITY, 4, context.temp_allocator)
	if !ok {
		log.warnf("could not write the frames of %s; it stays still", path)
		return
	}
	times := make([]u16, n, context.temp_allocator)
	for d, i in durations {
		times[i] = u16(min(d, int(max(u16))))
	}
	data, encoded := proto.encode_emoji_frames({durations = times, columns = columns, image = image})
	if !encoded || len(data) > proto.MAX_BLOB_SIZE {
		log.warnf("the frames of %s are too big to send; it stays still", path)
		delete(data)
		return
	}
	return {data = data, width = width, height = height}
}

/*
scale_cell scales a picture (RGBA) into a cell, in the temp allocator:
as big as fits, keeping its shape, in the middle. Shrinking averages the
pixels each one covers; growing repeats them.
*/
@(private = "file")
scale_cell :: proc(src: []u8, width, height: int) -> (cell: []u8) {
	cell = make([]u8, EMOJI_CELL * EMOJI_CELL * 4, context.temp_allocator)
	side := max(width, height)
	w := max(1, width * EMOJI_CELL / side)
	h := max(1, height * EMOJI_CELL / side)
	ox, oy := (EMOJI_CELL - w) / 2, (EMOJI_CELL - h) / 2
	for y in 0 ..< h {
		y0 := y * height / h
		y1 := max(y0 + 1, (y + 1) * height / h)
		for x in 0 ..< w {
			x0 := x * width / w
			x1 := max(x0 + 1, (x + 1) * width / w)
			// Averaged weighted by alpha, so transparent pixels don't
			// darken the edges.
			sum: [4]u32
			n := u32((y1 - y0) * (x1 - x0))
			for sy in y0 ..< y1 {
				for sx in x0 ..< x1 {
					p := src[(sy * width + sx) * 4:]
					a := u32(p[3])
					sum += {u32(p[0]) * a, u32(p[1]) * a, u32(p[2]) * a, a}
				}
			}
			d := cell[((oy + y) * EMOJI_CELL + ox + x) * 4:]
			if sum[3] > 0 {
				d[0], d[1], d[2] = u8(sum[0] / sum[3]), u8(sum[1] / sum[3]), u8(sum[2] / sum[3])
			}
			d[3] = u8(sum[3] / n)
		}
	}
	return cell
}

// place_cells copies cells into `pixels` (RGBA, `width` wide), `columns`
// to a row, each followed by a pixel of gap.
@(private = "file")
place_cells :: proc(pixels: []u8, width, columns: int, cells: [][]u8) {
	for cell, i in cells {
		cx, cy := (i % columns) * EMOJI_STRIDE, (i / columns) * EMOJI_STRIDE
		for y in 0 ..< EMOJI_CELL {
			copy(
				pixels[((cy + y) * width + cx) * 4:][:EMOJI_CELL * 4],
				cell[y * EMOJI_CELL * 4:][:EMOJI_CELL * 4],
			)
		}
	}
}

// encode_sheet lays the cells out and writes them as a QOI.
@(private = "file")
encode_sheet :: proc(cells: [][]u8) -> (data: []u8, ok: bool) {
	rows := (len(cells) + EMOJI_COLUMNS - 1) / EMOJI_COLUMNS
	width, height := EMOJI_COLUMNS * EMOJI_STRIDE, rows * EMOJI_STRIDE
	pixels := make([]u8, width * height * 4, context.temp_allocator)
	place_cells(pixels, width, EMOJI_COLUMNS, cells)
	img := image.Image {
		width    = width,
		height   = height,
		channels = 4,
		depth    = 8,
	}
	bytes.buffer_init(&img.pixels, pixels)
	defer bytes.buffer_destroy(&img.pixels)
	out: bytes.Buffer
	if err := qoi.save_to_buffer(&out, &img); err != nil {
		log.errorf("could not make the sheet of emoji: %v", err)
		bytes.buffer_destroy(&out)
		return
	}
	data = make([]u8, bytes.buffer_length(&out))
	copy(data, bytes.buffer_to_bytes(&out))
	bytes.buffer_destroy(&out)
	return data, true
}

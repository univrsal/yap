package server

import "base:runtime"
import "core:bytes"
import "core:hash"
import "core:image"
import "core:image/png"
import "core:image/qoi"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "common:proto"

/*
The server's own emoji (src/common/proto/emoji.odin): a folder of PNGs
the admin fills, `emoji/` in the data directory. `foo.png` is the emoji
`:foo:`; a file whose name isn't one an emoji may have (2 to 32 of
`a-z 0-9 _`), or that isn't a PNG, is skipped with a warning.

They go to clients as one picture, the sheet: every emoji scaled into a
cell of EMOJI_CELL pixels, EMOJI_COLUMNS to a row, in name order. Core
Odin writes no PNG but writes QOI, which both clients read in pure Odin,
so the sheet is a QOI. It's kept as a blob (of kind Emoji_Sheet), so an
unchanged folder makes the same blob and clients keep their copy. Every
connection is told of it when it logs in (Emoji_Sheet) and when it
changes.

The folder is looked at every EMOJI_RESCAN: a file added, removed or
changed has the sheet made again, on a thread of its own (reading and
scaling pictures takes a moment, and the loop carries voice), and told
to everyone when it's done. Nothing has to be restarted.
*/

EMOJI_DIR :: "emoji"
EMOJI_CELL :: 32 // pixels: twice the size an emoji is drawn at, for scaled-up screens
EMOJI_COLUMNS :: proto.EMOJI_SHEET_COLUMNS
EMOJI_RESCAN :: 5 * time.Second
// A picture bigger than this isn't read: an emoji is small.
EMOJI_MAX_FILE :: 1024 * 1024

Custom_Emoji :: struct {
	dir:       string,
	// The sheet everyone has now: its blob (0 for none), and the names of
	// its cells (owned).
	blob:      Blob_Id,
	size:      int,
	names:     [dynamic]string,
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
	ok:    bool,
}

built_sheet_destroy :: proc(b: ^Built_Sheet) {
	delete(b.qoi)
	for n in b.names {
		delete(n)
	}
	delete(b.names)
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
	b.thread = thread.create_and_start_with_poly_data(b, proc(b: ^Emoji_Build) {
		// This thread's own scratch space: the loop's is emptied every turn.
		scratch: runtime.Default_Temp_Allocator
		runtime.default_temp_allocator_init(&scratch, 4 * 1024 * 1024, context.allocator)
		defer runtime.default_temp_allocator_destroy(&scratch)
		context.temp_allocator = runtime.default_temp_allocator(&scratch)
		b.sheet = build_sheet(b.dir)
		sync.atomic_store(&b.done, true)
	}, context)
	if b.thread == nil {
		free(b)
		return
	}
	e.building = b
}

/*
emoji_take makes a sheet that was made the one everyone has: kept as a
blob, and with `tell`, told to every connection. Takes the names over.
*/
@(private = "file")
emoji_take :: proc(s: ^Server, sheet: ^Built_Sheet, tell: bool) {
	e := &s.emoji
	blob: Blob_Id
	if len(sheet.qoi) > 0 {
		ok: bool
		rows := (len(sheet.names) + EMOJI_COLUMNS - 1) / EMOJI_COLUMNS
		blob, ok = blob_put(&s.blobs, .Emoji_Sheet, sheet.qoi, EMOJI_COLUMNS * EMOJI_CELL, rows * EMOJI_CELL)
		if !ok {
			log.error("could not keep the sheet of emoji")
			return
		}
	}
	for n in e.names {
		delete(n)
	}
	clear(&e.names)
	append(&e.names, ..sheet.names)
	delete(sheet.names)
	sheet.names = nil
	e.blob, e.size = blob, len(sheet.qoi)
	// For purging, which keeps it, also when it runs without the server
	// (retention.odin).
	db_meta_set(&s.db, EMOJI_SHEET_META, i64(blob))
	log.infof("%d emoji of our own", len(e.names))
	if tell {
		for _, u in s.conns {
			send_emoji_sheet(s, u)
		}
	}
}

// send_emoji_sheet tells a connection of the server's emoji.
send_emoji_sheet :: proc(s: ^Server, u: ^Conn) {
	e := &s.emoji
	out := make([]u8, 8 + 4 + 2 + 2 + len(e.names) * (1 + proto.MAX_EMOJI_NAME), context.temp_allocator)
	body := proto.encode_emoji_sheet(out, {blob = e.blob, size = e.size, cell = EMOJI_CELL, names = e.names[:]})
	send_event(u, .Emoji_Sheet, body)
}

// emoji_known is whether `name` is one of the server's emoji.
emoji_known :: proc(s: ^Server, name: string) -> bool {
	_, found := slice.binary_search(s.emoji.names[:], name)
	return found
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

/*
build_sheet makes the sheet from the folder: every PNG that may be an
emoji, scaled into its cell, in name order, as a QOI. Safe to run on a
thread of its own: it touches nothing of the server's. `ok` is false
only if the folder couldn't be read or the sheet made; a folder that
isn't there has no emoji.
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
	slice.sort_by(files, proc(a, b: os.File_Info) -> bool {
		return a.name < b.name
	})

	names := make([dynamic]string)
	cells := make([dynamic][]u8, context.temp_allocator) // RGBA, EMOJI_CELL square
	for f in files {
		if f.type != .Regular || !strings.has_suffix(f.name, ".png") {
			continue
		}
		name := f.name[:len(f.name) - len(".png")]
		switch {
		case !proto.custom_emoji_name_ok(name):
			log.warnf("%s: an emoji's name is 2 to 32 of a-z, 0-9 and _; skipping it", f.fullpath)
			continue
		case f.size > EMOJI_MAX_FILE:
			log.warnf("%s is too big for an emoji; skipping it", f.fullpath)
			continue
		case len(names) >= proto.MAX_CUSTOM_EMOJI:
			log.warnf("%s: a server has at most %d emoji; skipping it", f.fullpath, proto.MAX_CUSTOM_EMOJI)
			continue
		}
		cell, ok := read_emoji(f.fullpath)
		if !ok {
			continue
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
		log.warnf("the sheet of %d emoji is too big; leaving out the last %d", len(cells), len(cells) - keep)
		for n in names[keep:] {
			delete(n)
		}
		resize(&names, keep)
		resize(&cells, keep)
		sheet.names = names[:]
	}
	return
}

/*
read_emoji reads a PNG and scales it into a cell: as big as fits,
keeping its shape, in the middle. Shrinking averages the pixels each
one covers; growing repeats them.
*/
@(private = "file")
read_emoji :: proc(path: string) -> (cell: []u8, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		log.warnf("could not read %s: %v", path, err)
		return
	}
	img, png_err := png.load_from_bytes(data, {.alpha_add_if_missing}, context.temp_allocator)
	if png_err != nil || img == nil {
		log.warnf("%s isn't a PNG that can be read; skipping it", path)
		return
	}
	// In the temp allocator, all of it: nothing to destroy.
	if img.depth != 8 || img.channels != 4 || img.width <= 0 || img.height <= 0 {
		log.warnf("%s: only 8-bit pictures make emoji; skipping it", path)
		return
	}
	src := bytes.buffer_to_bytes(&img.pixels)
	cell = make([]u8, EMOJI_CELL * EMOJI_CELL * 4, context.temp_allocator)
	side := max(img.width, img.height)
	w := max(1, img.width * EMOJI_CELL / side)
	h := max(1, img.height * EMOJI_CELL / side)
	ox, oy := (EMOJI_CELL - w) / 2, (EMOJI_CELL - h) / 2
	for y in 0 ..< h {
		y0 := y * img.height / h
		y1 := max(y0 + 1, (y + 1) * img.height / h)
		for x in 0 ..< w {
			x0 := x * img.width / w
			x1 := max(x0 + 1, (x + 1) * img.width / w)
			// Averaged weighted by alpha, so transparent pixels don't
			// darken the edges.
			sum: [4]u32
			n := u32((y1 - y0) * (x1 - x0))
			for sy in y0 ..< y1 {
				for sx in x0 ..< x1 {
					p := src[(sy * img.width + sx) * 4:]
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
	return cell, true
}

// encode_sheet lays the cells out and writes them as a QOI.
@(private = "file")
encode_sheet :: proc(cells: [][]u8) -> (data: []u8, ok: bool) {
	rows := (len(cells) + EMOJI_COLUMNS - 1) / EMOJI_COLUMNS
	width, height := EMOJI_COLUMNS * EMOJI_CELL, rows * EMOJI_CELL
	pixels := make([]u8, width * height * 4, context.temp_allocator)
	for cell, i in cells {
		cx, cy := (i % EMOJI_COLUMNS) * EMOJI_CELL, (i / EMOJI_COLUMNS) * EMOJI_CELL
		for y in 0 ..< EMOJI_CELL {
			copy(pixels[((cy + y) * width + cx) * 4:][:EMOJI_CELL * 4], cell[y * EMOJI_CELL * 4:][:EMOJI_CELL * 4])
		}
	}
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

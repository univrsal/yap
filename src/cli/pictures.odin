package main

import "core:time"

import "client:conn"
import "common:proto"
import "common:stbtrack"
import "common:webp"
import "tui"

// Pictures in messages, drawn with half-block characters: each cell is two pixels
// tall, the upper one the colour of "▀" and the lower one its background. That
// needs a terminal with 24-bit colour (nearly all of them) and nothing else, and
// it is plain cells to the renderer, so it scrolls and redraws like text.

// How big a picture is drawn at most, in cells.
PICTURE_MAX_COLS :: 56
PICTURE_MAX_ROWS :: 14

Pixel :: [3]u8

Picture :: struct {
	cols, rows: int,
	top:        []Pixel, // cols x rows: the upper pixel of each cell
	bottom:     []Pixel,
	failed:     bool, // it could not be decoded
}

Pictures :: struct {
	by_blob: map[proto.Blob_Id]Picture,
	asked:   map[proto.Blob_Id]time.Tick, // when its preview was last asked for
}

pictures_destroy :: proc(p: ^Pictures) {
	for _, pic in p.by_blob {
		delete(pic.top)
		delete(pic.bottom)
	}
	delete(p.by_blob)
	delete(p.asked)
	p^ = {}
}

// picture_decode turns the bytes of a picture file into pixels, scaled to fit
// `max_cols` x `max_rows` cells. The formats are the ones previews are asked
// for (png, jpg, gif, bmp, webp); an animation shows its first frame.
picture_decode :: proc(data: []u8, max_cols, max_rows: int) -> Picture {
	w, h: int
	pixels: []u8 // RGBA
	free_pixels: proc(p: []u8)
	if webp.is_webp(data) {
		ww, hh, ok := webp.size(data)
		if !ok || ww <= 0 || hh <= 0 || ww * hh > 64 * 1024 * 1024 {
			return {failed = true}
		}
		w, h = ww, hh
		pixels = make([]u8, w * h * 4)
		if !webp.decode_into(data, pixels, w) {
			delete(pixels)
			return {failed = true}
		}
		free_pixels = proc(p: []u8) {delete(p)}
	} else {
		x, y, channels: i32
		raw := stbtrack.load_from_memory(raw_data(data), i32(len(data)), &x, &y, &channels, 4)
		if raw == nil || x <= 0 || y <= 0 {
			return {failed = true}
		}
		w, h = int(x), int(y)
		pixels = raw[:w * h * 4]
		free_pixels = proc(p: []u8) {stbtrack.image_free(raw_data(p))}
	}
	defer free_pixels(pixels)
	return picture_scale(pixels, w, h, max_cols, max_rows)
}

// picture_scale averages RGBA pixels into a grid of cells, as many as fit in
// `max_cols` x `max_rows` with the picture's proportions. A cell is one pixel
// wide and two high, so the grid has twice as many pixel rows as cell rows.
// Transparent parts are blended on black.
picture_scale :: proc(rgba: []u8, w, h, max_cols, max_rows: int) -> Picture {
	// The size in pixels of the grid: the picture, shrunk to fit and no bigger.
	gw := min(max_cols, w)
	gh := h * gw / w
	if gh > 2 * max_rows {
		gh = 2 * max_rows
		gw = max(w * gh / h, 1)
	}
	gh = max(gh, 2)
	gh += gh % 2 // whole cells
	pic := Picture {
		cols   = gw,
		rows   = gh / 2,
		top    = make([]Pixel, gw * (gh / 2)),
		bottom = make([]Pixel, gw * (gh / 2)),
	}
	for gy in 0 ..< gh {
		y0, y1 := gy * h / gh, max((gy + 1) * h / gh, gy * h / gh + 1)
		for gx in 0 ..< gw {
			x0, x1 := gx * w / gw, max((gx + 1) * w / gw, gx * w / gw + 1)
			r, g, b, n: int
			for y in y0 ..< min(y1, h) {
				for x in x0 ..< min(x1, w) {
					i := (y * w + x) * 4
					a := int(rgba[i + 3])
					r += int(rgba[i]) * a / 255
					g += int(rgba[i + 1]) * a / 255
					b += int(rgba[i + 2]) * a / 255
					n += 1
				}
			}
			n = max(n, 1)
			px := Pixel{u8(r / n), u8(g / n), u8(b / n)}
			cell := (gy / 2) * gw + gx
			if gy % 2 == 0 {
				pic.top[cell] = px
			} else {
				pic.bottom[cell] = px
			}
		}
	}
	return pic
}

// picture_row is one row of cells of a picture as segments of "▀".
picture_row :: proc(pic: Picture, row: int, allocator := context.allocator) -> []Seg {
	segs := make([]Seg, pic.cols, allocator)
	for x in 0 ..< pic.cols {
		i := row * pic.cols + x
		t, b := pic.top[i], pic.bottom[i]
		segs[x] = Seg {
			text = "▀",
			style = {fg = tui.color_rgb(t.r, t.g, t.b), bg = tui.color_rgb(b.r, b.g, b.b)},
		}
	}
	return segs
}

// is_picture_file says whether a message's file is one that gets a preview.
is_picture_file :: proc(f: conn.Msg_File) -> bool {
	return f.blob != 0 && conn.preview_wanted(f.name, f.size)
}

// pictures_update decodes pictures that have arrived, one a call so that a
// screenful of them does not stall the screen. Call with the View locked.
pictures_update :: proc(p: ^Pictures, v: ^conn.View, cols: int) -> bool {
	for blob, img in v.blobs {
		if img.state != .Ready || blob in p.by_blob || len(img.jpeg) == 0 {
			continue
		}
		p.by_blob[blob] = picture_decode(img.jpeg, min(cols, PICTURE_MAX_COLS), PICTURE_MAX_ROWS)
		return true
	}
	return false
}

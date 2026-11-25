#+build !wasi
package render

import stbtt "client:wstbtt"
import stbi "client:wstbi"
import "core:math"
import "core:unicode/utf16"

// Color glyphs from an emoji font of the system's (sysemoji_native.odin).
// Every system stores its emoji differently, and stb_truetype reads none of
// them, so the tables are read here:
//
//   - sbix (macOS, Apple Color Emoji): a PNG per glyph per size ("strike").
//     The smallest strike at least as big as the emoji is drawn is used.
//   - CBDT/CBLC (Linux, Noto Color Emoji and Blobmoji): PNGs too, usually
//     in one big strike.
//   - COLR version 0 with CPAL (Windows, Segoe UI Emoji): an emoji is a stack
//     of ordinary outlines, each filled with one color of a palette. The
//     outlines are rasterized by stb_truetype and laid over each other.
//     COLR version 1's gradients and transforms aren't drawn; a version 1
//     table that still lists an emoji in the version 0 way (as Windows 11's
//     does for compatibility) is drawn from that.
//
// Bitmap fonts often have no outlines at all, which stb_truetype won't even
// open, so the character map is read here too. An emoji is drawn into a
// square tile of the size it is shown at, fitted inside it with a margin as
// the sheet's emoji are (emoji_atlas.odin), and centered.

Color_Format :: enum u8 {
	None,
	Sbix,
	Cbdt,
	Colr,
}

// A font's table: where it starts in the file and how long it is.
@(private = "file")
Table :: struct {
	at, size: int,
}

Color_Font :: struct {
	data:         []u8, // the whole file
	format:       Color_Format,
	num_glyphs:   int,
	units_per_em: int,
	cmap:         int, // where the character map's subtable is, or 0
	cmap_format:  int, // 4 or 12
	sbix:         Table,
	cblc, cbdt:   Table,
	colr, cpal:   Table,
	names:        Table,
	// The font's outlines, for COLR's layers.
	info:         stbtt.fontinfo,
}

// Readers of big-endian numbers that return 0 past the end of the data, so
// that a broken font draws nothing rather than crashing.
@(private = "file")
u8_at :: proc(d: []u8, at: int) -> int {
	return int(d[at]) if at >= 0 && at < len(d) else 0
}
@(private = "file")
u16_at :: proc(d: []u8, at: int) -> int {
	return u8_at(d, at) << 8 | u8_at(d, at + 1)
}
@(private = "file")
i16_at :: proc(d: []u8, at: int) -> int {
	return int(i16(u16(u16_at(d, at))))
}
@(private = "file")
u32_at :: proc(d: []u8, at: int) -> int {
	return u16_at(d, at) << 16 | u16_at(d, at + 2)
}
@(private = "file")
tag_at :: proc(d: []u8, at: int) -> string {
	if at < 0 || at + 4 > len(d) {
		return ""
	}
	return string(d[at:][:4])
}

// color_font_open reads font `index` of a file (0 unless it is a
// collection). It is ok if the font has color glyphs in a format we draw.
color_font_open :: proc(data: []u8, index: i32) -> (f: Color_Font, ok: bool) {
	f.data = data
	base := 0
	if tag_at(data, 0) == "ttcf" {
		if int(index) >= u32_at(data, 8) {
			return
		}
		base = u32_at(data, 12 + 4 * int(index))
	}
	head, maxp, cmap: Table
	for i in 0 ..< u16_at(data, base + 4) {
		rec := base + 12 + 16 * i
		t := Table{u32_at(data, rec + 8), u32_at(data, rec + 12)}
		if t.at + t.size > len(data) {
			continue
		}
		switch tag_at(data, rec) {
		case "head":
			head = t
		case "maxp":
			maxp = t
		case "cmap":
			cmap = t
		case "sbix":
			f.sbix = t
		case "CBLC":
			f.cblc = t
		case "CBDT":
			f.cbdt = t
		case "COLR":
			f.colr = t
		case "name":
			f.names = t
		case "CPAL":
			f.cpal = t
		}
	}
	f.units_per_em = u16_at(data, head.at + 18)
	f.num_glyphs = u16_at(data, maxp.at + 4)
	if head.size == 0 || maxp.size == 0 || cmap.size == 0 || f.units_per_em == 0 {
		return
	}
	// The character map: a full Unicode one (format 12) if there is one,
	// otherwise the BMP's (format 4).
	best := 0
	for i in 0 ..< u16_at(data, cmap.at + 2) {
		rec := cmap.at + 4 + 8 * i
		platform, encoding := u16_at(data, rec), u16_at(data, rec + 2)
		sub := cmap.at + u32_at(data, rec + 4)
		format := u16_at(data, sub)
		unicode := platform == 0 || (platform == 3 && (encoding == 1 || encoding == 10))
		if !unicode || (format != 4 && format != 12) {
			continue
		}
		if best == 0 || (format == 12 && f.cmap_format != 12) {
			f.cmap, f.cmap_format = sub, format
			best = 1
		}
	}
	if f.cmap == 0 {
		return
	}
	switch {
	case f.sbix.size > 0:
		f.format = .Sbix
	case f.cblc.size > 0 && f.cbdt.size > 0:
		f.format = .Cbdt
	case f.colr.size > 0 && f.cpal.size > 0 && u16_at(data, f.colr.at + 2) > 0:
		// The layers are outlines, which stb_truetype draws.
		if !stbtt.InitFont(&f.info, raw_data(data), i32(base)) {
			return
		}
		f.format = .Colr
	case:
		return
	}
	return f, true
}

// color_font_glyph returns the glyph of a character, if the font has a
// color picture for it (0 otherwise).
color_font_glyph :: proc(f: ^Color_Font, r: rune) -> int {
	g := cmap_glyph(f, r)
	if g == 0 || g >= f.num_glyphs {
		return 0
	}
	switch f.format {
	case .Sbix:
		if _, ok := sbix_image(f, g, 0); ok {
			return g
		}
	case .Cbdt:
		if _, ok := cbdt_image(f, g, 0); ok {
			return g
		}
	case .Colr:
		if _, n := colr_layers(f, g); n > 0 {
			return g
		}
	case .None:
	}
	return 0
}

@(private = "file")
cmap_glyph :: proc(f: ^Color_Font, r: rune) -> int {
	d, sub, c := f.data, f.cmap, int(r)
	if f.cmap_format == 12 {
		// Groups of consecutive characters, sorted.
		lo, hi := 0, u32_at(d, sub + 12)
		for lo < hi {
			mid := (lo + hi) / 2
			group := sub + 16 + 12 * mid
			start, end := u32_at(d, group), u32_at(d, group + 4)
			switch {
			case c < start:
				hi = mid
			case c > end:
				lo = mid + 1
			case:
				return u32_at(d, group + 8) + c - start
			}
		}
		return 0
	}
	if c > 0xffff {
		return 0
	}
	segments := u16_at(d, sub + 6) / 2
	ends := sub + 14
	starts := ends + 2 * segments + 2
	deltas := starts + 2 * segments
	ranges := deltas + 2 * segments
	for i in 0 ..< segments {
		if c > u16_at(d, ends + 2 * i) {
			continue
		}
		start := u16_at(d, starts + 2 * i)
		if c < start {
			return 0
		}
		delta := u16_at(d, deltas + 2 * i)
		range_offset := u16_at(d, ranges + 2 * i)
		if range_offset == 0 {
			return (c + delta) & 0xffff
		}
		g := u16_at(d, ranges + 2 * i + range_offset + 2 * (c - start))
		return (g + delta) & 0xffff if g != 0 else 0
	}
	return 0
}

// sbix_image returns a glyph's picture from the smallest strike at least
// `side` pixels big, or the biggest one.
@(private = "file")
sbix_image :: proc(f: ^Color_Font, glyph, side: int) -> (image: []u8, ok: bool) {
	d, t := f.data, f.sbix
	best, best_ppem := -1, 0
	for i in 0 ..< u32_at(d, t.at + 4) {
		strike := t.at + u32_at(d, t.at + 8 + 4 * i)
		ppem := u16_at(d, strike)
		better :=
			best < 0 ||
			(ppem >= side && (best_ppem < side || ppem < best_ppem)) ||
			(ppem < side && best_ppem < side && ppem > best_ppem)
		if better && sbix_data(f, strike, glyph, 0) != nil {
			best, best_ppem = strike, ppem
		}
	}
	if best < 0 {
		return
	}
	image = sbix_data(f, best, glyph, 0)
	return image, image != nil
}

@(private = "file")
sbix_data :: proc(f: ^Color_Font, strike, glyph, depth: int) -> []u8 {
	d := f.data
	start := strike + u32_at(d, strike + 4 + 4 * glyph)
	end := strike + u32_at(d, strike + 8 + 4 * glyph)
	if end <= start + 8 || end > len(d) {
		return nil
	}
	switch tag_at(d, start + 4) {
	case "png ", "jpg ":
		return d[start + 8:end]
	case "dupe":
		// The same picture as another glyph.
		if depth == 0 {
			return sbix_data(f, strike, u16_at(d, start + 8), 1)
		}
	}
	return nil
}

// cbdt_image returns a glyph's picture from the smallest strike at least
// `side` pixels big that has it, or the biggest one.
@(private = "file")
cbdt_image :: proc(f: ^Color_Font, glyph, side: int) -> (image: []u8, ok: bool) {
	d, t := f.data, f.cblc
	best: []u8
	best_ppem := 0
	for i in 0 ..< u32_at(d, t.at + 4) {
		size := t.at + 8 + 48 * i
		if glyph < u16_at(d, size + 40) || glyph > u16_at(d, size + 42) {
			continue
		}
		ppem := u8_at(d, size + 45)
		better :=
			best == nil ||
			(ppem >= side && (best_ppem < side || ppem < best_ppem)) ||
			(ppem < side && best_ppem < side && ppem > best_ppem)
		if !better {
			continue
		}
		if found := cbdt_strike_image(f, size, glyph); found != nil {
			best, best_ppem = found, ppem
		}
	}
	return best, best != nil
}

@(private = "file")
cbdt_strike_image :: proc(f: ^Color_Font, size, glyph: int) -> []u8 {
	d := f.data
	array := f.cblc.at + u32_at(d, size)
	for i in 0 ..< u32_at(d, size + 8) {
		entry := array + 8 * i
		first, last := u16_at(d, entry), u16_at(d, entry + 2)
		if glyph < first || glyph > last {
			continue
		}
		sub := array + u32_at(d, entry + 4)
		index_format, image_format := u16_at(d, sub), u16_at(d, sub + 2)
		data := f.cbdt.at + u32_at(d, sub + 4)
		start, end := -1, -1
		switch index_format {
		case 1:
			at := sub + 8 + 4 * (glyph - first)
			start, end = data + u32_at(d, at), data + u32_at(d, at + 4)
		case 3:
			at := sub + 8 + 2 * (glyph - first)
			start, end = data + u16_at(d, at), data + u16_at(d, at + 2)
		case 2:
			image_size := u32_at(d, sub + 8)
			start = data + image_size * (glyph - first)
			end = start + image_size
		case 4:
			for j in 0 ..< u32_at(d, sub + 8) {
				pair := sub + 12 + 4 * j
				if u16_at(d, pair) == glyph {
					start, end = data + u16_at(d, pair + 2), data + u16_at(d, pair + 6)
					break
				}
			}
		case 5:
			image_size := u32_at(d, sub + 8)
			for j in 0 ..< u32_at(d, sub + 20) {
				if u16_at(d, sub + 24 + 2 * j) == glyph {
					start = data + image_size * j
					end = start + image_size
					break
				}
			}
		}
		if start < 0 || end <= start || end > len(d) {
			return nil
		}
		// The picture follows its metrics (small: 5 bytes, big: 8, or none
		// when the index has them) and its length.
		skip := 0
		switch image_format {
		case 17:
			skip = 5
		case 18:
			skip = 8
		case 19:
			skip = 0
		case:
			return nil
		}
		length := u32_at(d, start + skip)
		image := start + skip + 4
		if length <= 0 || image + length > end {
			return nil
		}
		return d[image:][:length]
	}
	return nil
}

// colr_layers returns where a glyph's layers start in COLR and how many
// there are (0 if it has none).
@(private = "file")
colr_layers :: proc(f: ^Color_Font, glyph: int) -> (first, count: int) {
	d, t := f.data, f.colr
	bases := t.at + u32_at(d, t.at + 4)
	lo, hi := 0, u16_at(d, t.at + 2)
	for lo < hi {
		mid := (lo + hi) / 2
		g := u16_at(d, bases + 6 * mid)
		switch {
		case glyph < g:
			hi = mid
		case glyph > g:
			lo = mid + 1
		case:
			layers := t.at + u32_at(d, t.at + 8)
			return layers + 4 * u16_at(d, bases + 6 * mid + 2), u16_at(d, bases + 6 * mid + 4)
		}
	}
	return
}

// color_glyph_draw draws a glyph into a `side` x `side` tile of RGBA pixels
// (straight alpha), whose rows are `stride` texels apart. `fill` is how much
// of the tile the emoji takes up.
color_glyph_draw :: proc(f: ^Color_Font, glyph, side: int, fill: f32, out: []u8, stride: int) -> bool {
	box := max(1, int(math.round(f32(side) * fill)))
	premultiplied := make([]f32, side * side * 4, context.temp_allocator)
	drawn: bool
	switch f.format {
	case .Sbix:
		if image, ok := sbix_image(f, glyph, box); ok {
			drawn = draw_picture(image, side, box, premultiplied)
		}
	case .Cbdt:
		if image, ok := cbdt_image(f, glyph, box); ok {
			drawn = draw_picture(image, side, box, premultiplied)
		}
	case .Colr:
		drawn = draw_layers(f, glyph, side, box, premultiplied)
	case .None:
	}
	if !drawn {
		return false
	}
	for y in 0 ..< side {
		for x in 0 ..< side {
			p := premultiplied[(y * side + x) * 4:][:4]
			o := out[(y * stride + x) * 4:][:4]
			a := clamp(p[3], 0, 1)
			if a <= 0 {
				o[0], o[1], o[2], o[3] = 0, 0, 0, 0
				continue
			}
			for c in 0 ..< 3 {
				o[c] = u8(math.round(clamp(p[c] / a, 0, 1) * 255))
			}
			o[3] = u8(math.round(a * 255))
		}
	}
	return true
}

// draw_picture decodes a PNG and scales it to fit a `box` square in the
// middle of the tile, each pixel the average of the picture's pixels it
// covers (in premultiplied alpha, so that transparent pixels don't darken
// the edges).
@(private = "file")
draw_picture :: proc(image: []u8, side, box: int, out: []f32) -> bool {
	w, h, comp: i32
	pixels := stbi.load_from_memory(raw_data(image), i32(len(image)), &w, &h, &comp, 4)
	if pixels == nil || w <= 0 || h <= 0 {
		return false
	}
	defer stbi.image_free(pixels)
	k := f32(box) / f32(max(w, h)) // tile pixels per picture pixel
	tw := max(1, int(math.round(f32(w) * k)))
	th := max(1, int(math.round(f32(h) * k)))
	ox, oy := (side - tw) / 2, (side - th) / 2
	for ty in 0 ..< th {
		// The picture's rows this pixel covers.
		ya, yb := f32(ty) / k, f32(ty + 1) / k
		for tx in 0 ..< tw {
			xa, xb := f32(tx) / k, f32(tx + 1) / k
			sum: [4]f32
			area: f32
			for sy := int(ya); sy < int(h) && f32(sy) < yb; sy += 1 {
				dy := min(yb, f32(sy + 1)) - max(ya, f32(sy))
				for sx := int(xa); sx < int(w) && f32(sx) < xb; sx += 1 {
					cover := dy * (min(xb, f32(sx + 1)) - max(xa, f32(sx)))
					p := pixels[(sy * int(w) + sx) * 4:][:4]
					a := f32(p[3]) / 255
					sum += cover * [4]f32{f32(p[0]) / 255 * a, f32(p[1]) / 255 * a, f32(p[2]) / 255 * a, a}
					area += cover
				}
			}
			x, y := ox + tx, oy + ty
			if area > 0 && x >= 0 && y >= 0 && x < side && y < side {
				o := out[(y * side + x) * 4:][:4]
				v := sum / area
				o[0], o[1], o[2], o[3] = v[0], v[1], v[2], v[3]
			}
		}
	}
	return true
}

// draw_layers draws a COLR glyph: its layers' outlines, scaled together to
// fit a `box` square in the middle of the tile, each filled with its color
// over the ones below.
@(private = "file")
draw_layers :: proc(f: ^Color_Font, glyph, side, box: int, out: []f32) -> bool {
	d := f.data
	first, count := colr_layers(f, glyph)
	if count == 0 {
		return false
	}
	// The layers' bounds together, in font units.
	x0, y0, x1, y1 := max(int), max(int), min(int), min(int)
	for i in 0 ..< count {
		lx0, ly0, lx1, ly1: i32
		if stbtt.GetGlyphBox(&f.info, i32(u16_at(d, first + 4 * i)), &lx0, &ly0, &lx1, &ly1) != 0 {
			x0, y0 = min(x0, int(lx0)), min(y0, int(ly0))
			x1, y1 = max(x1, int(lx1)), max(y1, int(ly1))
		}
	}
	if x1 <= x0 || y1 <= y0 {
		return false
	}
	k := f32(box) / f32(max(x1 - x0, y1 - y0))
	// Where the glyph's origin goes in the tile (y down), so that its bounds
	// are in the middle.
	ox := (f32(side) - f32(x1 - x0) * k) / 2 - f32(x0) * k
	oy := (f32(side) - f32(y1 - y0) * k) / 2 + f32(y1) * k
	shift_x, shift_y := ox - math.floor(ox), oy - math.floor(oy)
	palette := palette_colors(f)

	for i in 0 ..< count {
		layer := first + 4 * i
		g := i32(u16_at(d, layer))
		color := [4]f32{0, 0, 0, 1} // the text's color, which emoji don't have: black
		if entry := u16_at(d, layer + 2); entry != 0xffff && entry < len(palette) {
			color = palette[entry]
		}
		bx0, by0, bx1, by1: i32
		stbtt.GetGlyphBitmapBoxSubpixel(&f.info, g, k, k, shift_x, shift_y, &bx0, &by0, &bx1, &by1)
		w, h := int(bx1 - bx0), int(by1 - by0)
		if w <= 0 || h <= 0 {
			continue
		}
		coverage := make([]u8, w * h, context.temp_allocator)
		stbtt.MakeGlyphBitmapSubpixel(&f.info, raw_data(coverage), i32(w), i32(h), i32(w), k, k, shift_x, shift_y, g)
		left := int(math.floor(ox)) + int(bx0)
		top := int(math.floor(oy)) + int(by0)
		for y in 0 ..< h {
			for x in 0 ..< w {
				tx, ty := left + x, top + y
				if tx < 0 || ty < 0 || tx >= side || ty >= side {
					continue
				}
				a := f32(coverage[y * w + x]) / 255 * color[3]
				if a <= 0 {
					continue
				}
				o := out[(ty * side + tx) * 4:][:4]
				for c in 0 ..< 3 {
					o[c] = color[c] * a + o[c] * (1 - a)
				}
				o[3] = a + o[3] * (1 - a)
			}
		}
	}
	return true
}

// palette_colors returns the first palette's colors (RGBA, 0..1). In the temp
// allocator.
@(private = "file")
palette_colors :: proc(f: ^Color_Font) -> [][4]f32 {
	d, t := f.data, f.cpal
	n := u16_at(d, t.at + 2)
	records := t.at + u32_at(d, t.at + 8)
	first := u16_at(d, t.at + 12)
	colors := make([][4]f32, n, context.temp_allocator)
	for &c, i in colors {
		bgra := records + 4 * (first + i)
		c = {
			f32(u8_at(d, bgra + 2)) / 255,
			f32(u8_at(d, bgra + 1)) / 255,
			f32(u8_at(d, bgra)) / 255,
			f32(u8_at(d, bgra + 3)) / 255,
		}
	}
	return colors
}

// color_font_name returns the font's full name in English, or "". In the
// temp allocator.
color_font_name :: proc(f: ^Color_Font) -> string {
	d, t := f.data, f.names
	if t.size == 0 {
		return ""
	}
	strings_at := t.at + u16_at(d, t.at + 4)
	mac := ""
	for i in 0 ..< u16_at(d, t.at + 2) {
		rec := t.at + 6 + 12 * i
		platform, encoding := u16_at(d, rec), u16_at(d, rec + 2)
		language, id := u16_at(d, rec + 4), u16_at(d, rec + 6)
		length, at := u16_at(d, rec + 8), strings_at + u16_at(d, rec + 10)
		if id != 4 || at + length > len(d) {
			continue
		}
		if platform == 3 && encoding == 1 && language == 0x409 {
			// UTF-16, big-endian.
			units := make([]u16, length / 2, context.temp_allocator)
			for &u, j in units {
				u = u16(u16_at(d, at + 2 * j))
			}
			buf := make([]u8, len(units) * 3, context.temp_allocator)
			return string(buf[:utf16.decode_to_utf8(buf, units)])
		}
		if platform == 1 && encoding == 0 && language == 0 {
			mac = string(d[at:][:length])
		}
	}
	return mac
}

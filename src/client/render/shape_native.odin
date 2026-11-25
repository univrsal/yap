#+build !wasi
package render

import "client:shape"
import stbtt "client:wstbtt"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// Text shaping: scripts whose letters change shape with their neighbors
// (Arabic, the Indic scripts, Thai, Hebrew's marks), combining marks, and
// right-to-left text (docs/design/fonts.md). Text that needs none of that,
// which is nearly all of it, is drawn character by character as before
// (font.odin); needs_shaping tells which is which.
//
// A string is shaped as one line, which is how the UI draws text: one
// string per line, or per piece of a line in another style (rich text,
// whose pieces are shaped and ordered each on its own). Each character
// keeps the font that find_glyph picks for it (a face, or one of the
// system's fonts; a combining mark goes with the character it combines
// with), and runs of one font, script and direction are shaped by
// kb_text_shape (client:shape). The runs are then put in visual order
// (Unicode's bidirectional algorithm, rule L2, with the two levels that a
// run's direction and the line's give).
//
// Characters drawn the old way (Unifont's, emoji, the server's emoji, the
// replacement character) are kept as they are and take their usual room, in
// the order the runs put them in. Shaped glyphs are rasterized into the
// fallback atlas by their font and index (shaped_key).
//
// A shaped string is kept for the frames it is used in (Shaping.cache), as
// the UI measures and draws the same strings every frame. Its widths don't
// depend on the scale or the zoom, so one entry serves every font.

@(private = "file")
NO_FONT :: 0xffff

// The cache is trimmed of what the last frames didn't use once it has this
// many strings.
@(private = "file")
CACHE_SIZE :: 2048

// A font that kb_text_shape shapes with: a face or a system font.
@(private = "file")
Shape_Font :: struct {
	system: bool,
	index:  int, // the Font_Style, or the index in System_Fonts.fonts
	per_em: f32, // font units to ems
}

Shaping :: struct {
	faces:    [Font_Style]i32, // their numbers, -1 if they can't be used, 0 until tried (stored + 1)
	system:   map[int]i32, // system font index to number + 1 (0: can't be used)
	fonts:    map[u16]Shape_Font,
	cache:    map[string]Shaped,
	frame:    u64,
	// Scratch space for shaping a string.
	runes:    [dynamic]rune,
	font_of:  [dynamic]u16,
	glyphs:   [dynamic]shape.Glyph,
	runs:     [dynamic]shape.Run,
}

shaping_destroy :: proc(sh: ^Shaping) {
	shaping_clear(sh)
	delete(sh.cache)
	delete(sh.system)
	delete(sh.fonts)
	delete(sh.runes)
	delete(sh.font_of)
	delete(sh.glyphs)
	delete(sh.runs)
	shape.shutdown()
	sh^ = {}
}

// shaping_clear forgets every shaped string, for when the fonts change.
shaping_clear :: proc(sh: ^Shaping) {
	for key, v in sh.cache {
		delete(key)
		delete(v.glyphs)
		delete(v.joined)
	}
	clear(&sh.cache)
}

// shaping_frame is called once a frame: it trims the cache of the strings
// that the last frames didn't use, when it has grown.
shaping_frame :: proc(sh: ^Shaping) {
	sh.frame += 1
	if len(sh.cache) < CACHE_SIZE {
		return
	}
	old := make([dynamic]string, context.temp_allocator)
	for key, v in sh.cache {
		if v.used + 2 < sh.frame {
			append(&old, key)
		}
	}
	for key in old {
		k, v := delete_key(&sh.cache, key)
		delete(k)
		delete(v.glyphs)
		delete(v.joined)
	}
}

// needs_shaping returns whether a string has anything that drawing it
// character by character would get wrong: right-to-left text, scripts that
// join or reorder their letters, combining marks, joiners. Latin, Greek,
// Cyrillic, CJK, symbols and emoji don't.
needs_shaping :: proc(f: ^Font, text: string) -> bool {
	if f.sys == nil {
		return false
	}
	for i := 0; i < len(text); i += 1 {
		if text[i] < 0xcc {
			// ASCII, and the start of U+0080..U+02FF.
			continue
		}
		r, n := utf8.decode_rune(text[i:])
		i += n - 1
		if complex_rune(r) {
			return true
		}
	}
	return false
}

@(private = "file")
complex_rune :: proc(r: rune) -> bool {
	switch r {
	case 0x0300 ..= 0x036f, 0x0483 ..= 0x0489:
		// Combining marks.
		return true
	case 0x0370 ..= 0x058f, 0x1e00 ..= 0x1fff:
		// Greek, Cyrillic, Armenian, Latin Extended Additional, Greek
		// Extended.
		return false
	case 0x200c ..= 0x200f:
		// Joiners and direction marks.
		return true
	case 0x2000 ..= 0x2bff, 0x2e00 ..= 0x2e7f:
		// Punctuation, symbols, arrows, shapes.
		return r >= 0x20d0 && r <= 0x20ff // combining marks for symbols
	case 0x2e80 ..= 0x9fff, 0xac00 ..= 0xd7af, 0xf900 ..= 0xfaff, 0xff00 ..= 0xffef:
		// CJK, kana, Hangul syllables, full-width forms.
		return false
	case 0xfe00 ..= 0xfe0f:
		// Variation selectors.
		return false
	case 0xfe20 ..= 0xfe2f:
		return true
	case 0x1f000 ..= 0x1faff, 0x20000 ..= 0x3ffff:
		// Emoji and symbols; CJK extensions.
		return false
	}
	return r >= 0x0590
}

// shaped_text returns `text` shaped in `style`, from the cache or shaped
// now. Glyphs and widths are the same for every font of the renderer, but
// the characters' fonts are picked by `f`'s faces (which are the same in
// all of them too).
shaped_text :: proc(f: ^Font, style: Font_Style, text: string) -> Shaped {
	sh := &f.sys.shaping
	key_buf := make([]u8, len(text) + 1, context.temp_allocator)
	key_buf[0] = u8(style)
	copy(key_buf[1:], text)
	key := string(key_buf)
	if v, found := sh.cache[key]; found {
		v.used = sh.frame
		sh.cache[key] = v
		return v
	}
	glyphs, width, rtl, joined := shape_string(f, style, text)
	v := Shaped{glyphs = glyphs, width = width, rtl = rtl, used = sh.frame, joined = joined}
	sh.cache[strings.clone(key)] = v
	return v
}

// shape_string shapes `text` (see above). The glyphs are allocated.
@(private = "file")
shape_string :: proc(f: ^Font, style: Font_Style, text: string) -> ([]Shaped_Glyph, f32, bool, []bool) {
	sh := &f.sys.shaping
	clear(&sh.runes)
	clear(&sh.font_of)
	// Each character's font. A mark, joiner or selector goes with the
	// character before it where that font has it, so that it is shaped
	// together with it.
	prev := u16(NO_FONT)
	for r in text {
		_, source, face := find_glyph(f, style, r)
		font := u16(NO_FONT)
		#partial switch source {
		case .Face:
			font = face_font(f, face)
		case .System:
			g, _ := system_glyph(f.sys, r)
			font = system_font(f, int(g.font))
		}
		attaches := source == .None || unicode.is_grapheme_extend(r) || unicode.is_spacing_mark(r)
		if attaches && prev != NO_FONT && prev != font && font_has(f, prev, r) {
			font = prev
		}
		append(&sh.runes, r)
		append(&sh.font_of, font)
		prev = font
	}
	count := i32(len(sh.runes))
	if len(sh.glyphs) < len(sh.runes) * 2 {
		resize(&sh.glyphs, len(sh.runes) * 2)
	}
	if len(sh.runs) < 16 {
		resize(&sh.runs, 16)
	}
	glyph_count, run_count, rtl: i32
	starts := make([]u8, len(sh.runes), context.temp_allocator)
	for {
		result := shape.shape(
			raw_data(sh.runes),
			raw_data(sh.font_of),
			count,
			raw_data(sh.glyphs),
			i32(len(sh.glyphs)),
			&glyph_count,
			raw_data(sh.runs),
			i32(len(sh.runs)),
			&run_count,
			&rtl,
			raw_data(starts),
		)
		if result == shape.TOO_SMALL {
			resize(&sh.glyphs, max(len(sh.glyphs), int(glyph_count)))
			resize(&sh.runs, max(len(sh.runs), int(run_count)))
			continue
		}
		if result != shape.OK {
			glyph_count, run_count = 0, 0
		}
		break
	}
	runs := sh.runs[:run_count]
	levels := char_levels(runs, sh.runes[:], rtl != 0)

	// The pieces that are reordered: a right-to-left run as a whole (its
	// glyphs are already in visual order), and a left-to-right run cut where
	// its characters' levels change.
	Piece :: struct {
		first, count: int, // glyphs
		level:        int,
		rtl:          bool,
	}
	pieces := make([dynamic]Piece, context.temp_allocator)
	for run in runs {
		glyphs := sh.glyphs[run.first_glyph:][:run.glyph_count]
		if run.rtl != 0 || len(glyphs) == 0 {
			append(&pieces, Piece{int(run.first_glyph), int(run.glyph_count), levels[run.first], run.rtl != 0})
			continue
		}
		start := 0
		for k in 1 ..= len(glyphs) {
			if k < len(glyphs) && levels[glyphs[k].cluster] == levels[glyphs[start].cluster] {
				continue
			}
			append(&pieces, Piece{int(run.first_glyph) + start, k - start, levels[glyphs[start].cluster], false})
			start = k
		}
	}
	piece_levels := make([]int, len(pieces), context.temp_allocator)
	for p, i in pieces {
		piece_levels[i] = p.level
	}

	out := make([dynamic]Shaped_Glyph, 0, len(sh.runes))
	pen: f32
	for pi in visual_order(piece_levels) {
		piece := pieces[pi]
		for g in sh.glyphs[piece.first:][:piece.count] {
			sf, known := sh.fonts[g.font]
			if !known || g.id == 0 {
				// Drawn the old way: a character without a shaping font, or
				// one its font has no glyph for after all.
				r := sh.runes[g.cluster]
				w := rune_advance(f, style, r)
				append(&out, Shaped_Glyph{kind = .Char, r = r, at = int(g.cluster), x = pen, w = w, rtl = piece.rtl})
				pen += w
				continue
			}
			k := sf.per_em * f.em
			append(
				&out,
				Shaped_Glyph {
					kind = .Glyph,
					font = g.font,
					id = g.id,
					at = int(g.cluster),
					x = pen,
					dx = f32(g.x_offset) * k,
					dy = f32(g.y_offset) * k,
					w = f32(g.advance) * k,
					rtl = piece.rtl,
				},
			)
			pen += f32(g.advance) * k
		}
	}
	joined := make([]bool, len(sh.runes))
	if glyph_count > 0 || len(sh.runes) == 0 {
		for s, i in starts {
			joined[i] = s == 0
		}
	}
	return out[:], pen, rtl != 0, joined
}

// char_levels returns each character's embedding level (Unicode's
// bidirectional algorithm), from its run's direction: in a left-to-right
// line, 0 for left-to-right text and 1 for right-to-left text; in a
// right-to-left line, 2 and 1. kb_text_shape gives directions, not levels,
// so numbers are worked out here: in a left-to-right line, numbers that
// follow right-to-left text go with it (level 2, on its left), as do the
// spaces and punctuation before them, while those after the last digit
// belong to the line again unless more right-to-left text follows them. In
// a right-to-left line, the spaces and punctuation at the ends of a
// left-to-right run belong to the line when right-to-left text or the end
// of the line is on that side. In the temp allocator.
@(private = "file")
char_levels :: proc(runs: []shape.Run, runes: []rune, rtl: bool) -> []int {
	levels := make([]int, len(runes), context.temp_allocator)
	// Where a run's letters and digits (its strong characters) begin and end.
	strong :: proc(r: rune) -> bool {
		return unicode.is_letter(r) || unicode.is_number(r)
	}
	after_rtl := rtl // whether the last letters were right to left (the line's start counts as its direction)
	for run, ri in runs {
		chars := runes[run.first:][:run.count]
		next_rtl := rtl if ri + 1 == len(runs) else runs[ri + 1].rtl != 0
		prev_rtl := rtl if ri == 0 else runs[ri - 1].rtl != 0
		letters := false
		first, last := -1, -1
		for r, i in chars {
			letters ||= unicode.is_letter(r)
			if strong(r) {
				if first < 0 {
					first = i
				}
				last = i
			}
		}
		for i in 0 ..< len(chars) {
			level := &levels[int(run.first) + i]
			switch {
			case run.rtl != 0:
				level^ = 1
			case !rtl && (letters || !after_rtl || first < 0):
				level^ = 0
			case !rtl:
				// Numbers after right-to-left text, in a left-to-right line.
				switch {
				case i < first:
					level^ = 1
				case i <= last:
					level^ = 2
				case:
					level^ = 1 if next_rtl else 0
				}
			case first < 0:
				level^ = 1
			case i < first:
				level^ = 1 if prev_rtl else 2
			case i > last:
				level^ = 1 if next_rtl else 2
			case:
				level^ = 2
			}
		}
		if letters {
			after_rtl = run.rtl != 0
		}
	}
	return levels
}

// visual_order returns the order to lay out pieces at `levels` in: from the
// highest level down to 1, every stretch of pieces at that level or above is
// reversed (rule L2). In the temp allocator.
@(private = "file")
visual_order :: proc(levels: []int) -> []int {
	order := make([]int, len(levels), context.temp_allocator)
	for &o, i in order {
		o = i
	}
	for lv := 2; lv >= 1; lv -= 1 {
		i := 0
		for i < len(order) {
			if levels[order[i]] < lv {
				i += 1
				continue
			}
			j := i
			for j < len(order) && levels[order[j]] >= lv {
				j += 1
			}
			for a, b := i, j - 1; a < b; a, b = a + 1, b - 1 {
				order[a], order[b] = order[b], order[a]
			}
			i = j
		}
	}
	return order
}

// face_font returns a face's number as a shaping font, adding it the first
// time.
@(private = "file")
face_font :: proc(f: ^Font, style: Font_Style) -> u16 {
	sh := &f.sys.shaping
	if sh.faces[style] == 0 {
		sh.faces[style] = -1
		data := face_data(style)
		if n := shape.font_add(raw_data(data), i32(len(data)), 0); n >= 0 {
			info := &face_get(f, style).info
			sh.fonts[u16(n)] = {system = false, index = int(style), per_em = stbtt.ScaleForMappingEmToPixels(info, 1)}
			sh.faces[style] = n + 1
		}
	}
	return u16(sh.faces[style] - 1) if sh.faces[style] > 0 else NO_FONT
}

// system_font returns a system font's number as a shaping font, adding it
// the first time.
@(private = "file")
system_font :: proc(f: ^Font, index: int) -> u16 {
	sh := &f.sys.shaping
	n, tried := sh.system[index]
	if !tried {
		sf := &f.sys.fonts[index]
		added := shape.font_add(raw_data(sf.data), i32(len(sf.data)), sf.index)
		n = added + 1 if added >= 0 else 0
		sh.system[index] = n
		if added >= 0 {
			sh.fonts[u16(added)] = {system = true, index = index, per_em = sf.per_em}
		}
	}
	return u16(n - 1) if n > 0 else NO_FONT
}

// font_info returns the outlines of a shaping font.
@(private = "file")
font_info :: proc(f: ^Font, sf: Shape_Font) -> ^stbtt.fontinfo {
	if sf.system {
		return &f.sys.fonts[sf.index].info
	}
	return &face_get(f, Font_Style(sf.index)).info
}

// font_has returns whether a shaping font has a glyph for a character.
@(private = "file")
font_has :: proc(f: ^Font, font: u16, r: rune) -> bool {
	sf, known := f.sys.shaping.fonts[font]
	return known && stbtt.FindGlyphIndex(font_info(f, sf), r) != 0
}

// shaped_glyph_cache puts a shaped glyph into the font's fallback atlas, at
// its scale, if it isn't there yet. It fails once the atlas is full (it is
// then emptied before the next frame).
shaped_glyph_cache :: proc(f: ^Font, font, id: u16) -> (g: Atlas_Glyph, ok: bool) {
	a := &f.fallback
	key := shaped_key(font, id)
	if g, ok = glyph_atlas_find(a, key); ok {
		return
	}
	sf, known := f.sys.shaping.fonts[font]
	if !known {
		return
	}
	info := font_info(f, sf)
	k := sf.per_em * f.em * a.scale
	x0, y0, x1, y1: i32
	stbtt.GetGlyphBitmapBoxSubpixel(info, i32(id), k, k, 0, 0, &x0, &y0, &x1, &y1)
	w, h := max(x1 - x0, 0), max(y1 - y0, 0)
	pixels: []u8
	g, pixels, ok = glyph_atlas_add(a, key, w, h, x0, y0)
	if !ok || pixels == nil {
		return
	}
	stbtt.MakeGlyphBitmapSubpixel(info, raw_data(pixels), w, h, a.side, k, k, 0, 0, i32(id))
	return g, true
}

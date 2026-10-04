package render

import "core:math"
import "core:slice"
import "core:unicode/utf8"
import "common:proto"
import stbtt "client:wstbtt"

/*
The UI font: Roboto (embedded with #load), rasterized with stb_truetype.
Every character the font has is used: its Latin, Greek and Cyrillic
letters and common punctuation and symbols. Emoji (proto/emoji.odin)
come from Noto Emoji, a single-colour outline font, drawn in the text's
colour like any other glyph. Anything else comes from Unifont
(unifont.odin) if it has it, and draws as the replacement character if
not. Emoji glyphs are rasterized as they're first drawn, into Unifont's
atlas, which is how the renderer gets them without a texture of their
own.

A font has faces, one per Font_Style: Roboto Regular, which is what the
UI uses, and for messages Roboto Bold, Italic and Bold Italic, and
JetBrains Mono for code. Each face has its own glyphs and atlas, and is
only read and rasterized once text in it is measured or drawn, so the
UI's font never builds more than Regular. All faces are set at Regular's
em size and on its baseline, so styles mix in a line: the other files
are a later Roboto (2.137) whose ascent and descent differ, which sizing
by pixel height (as Regular is) would make about an eighth bigger. A
character a face doesn't have comes from Regular, then from the
fallbacks as above, which have no styles: they're drawn as they are.

Layout happens in logical pixels, but glyphs are rasterized at the
display's real density (`scale` physical pixels per logical pixel), so
text is sharp on high-DPI screens. The atlases are rebuilt whenever the
scale changes, e.g. when the window moves to another monitor.

Glyph advances are taken from the unscaled font metrics, so text widths,
and with them the whole layout, are the same at every scale.

A font can be zoomed: the chat's text has a size of its own (its zoom),
on top of the UI's scale. A zoomed font is the same font laid out in a
space `zoom` times smaller and blown up again: its widths and line
height are `zoom` times the plain font's, its atlases are rasterized at
`scale * zoom`, and glyphs are snapped to physical pixels as usual, so
it's as sharp as the rest.
*/

Font_Style :: enum u8 {
	Regular,
	Bold,
	Italic,
	Bold_Italic,
	Mono,
}

@(private = "file")
FACE_DATA := [Font_Style][]u8 {
	.Regular     = #load("../assets/Roboto-Regular.ttf"),
	.Bold        = #load("../assets/Roboto-Bold.ttf"),
	.Italic      = #load("../assets/Roboto-Italic.ttf"),
	.Bold_Italic = #load("../assets/Roboto-BoldItalic.ttf"),
	.Mono        = #load("../assets/JetBrainsMono-Regular.ttf"),
}
@(private = "file")
EMOJI_FONT_DATA := #load("../assets/NotoEmoji.ttf")

// How tall an emoji is, from the font's ascent to its descent, in
// logical pixels: Unifont's cell, so it fits in that atlas's slots.
EMOJI_SIZE :: UNIFONT_SIZE

FONT_SIZE :: 15 // logical pixels, Regular's ascent to descent
LINE_HEIGHT :: 18 // logical pixels; microui's default, which its layout metrics assume

// Shown for characters the font doesn't have: the first of these it does.
FALLBACK_CHARS :: [?]rune{utf8.RUNE_ERROR, '?'}

// One of a font's faces (Font_Style): a font file, its glyphs and their
// atlas.
Face :: struct {
	info:       stbtt.fontinfo,
	tried:      bool, // read (face_get), whether or not that worked
	ok:         bool,
	// The characters we have glyphs for, sorted; the arrays below are
	// indexed the same way.
	codepoints: []rune,
	advance:    []f32, // logical pixels
	glyphs:     []stbtt.packedchar, // for the current atlas
	ascii:      [128]i32, // index of each ASCII character, or -1
	fallback:   i32,
	unit:       f32, // logical pixels per font unit

	// Atlas for `scale` (built by font_build_atlas).
	scale:      f32,
	pixels:     []u8, // width * height, one alpha byte per texel
	width:      i32,
	height:     i32,
	// A few fully opaque texels, for drawing solid rectangles.
	white:      [2]f32,
}

Font :: struct {
	faces:      [Font_Style]Face,
	ok:         bool,
	// The em size every face is set at, Regular's for FONT_SIZE (logical
	// pixels).
	em:         f32,
	// Distance from the top of a LINE_HEIGHT line box to the baseline.
	baseline:   f32,
	// How much bigger than FONT_SIZE this one is drawn: 1, or the
	// chat's size (see above). Set before the atlases are built.
	zoom:       f32,
	// The density the atlases are for (font_set_scale); a face whose
	// atlas is for another is built again before it's drawn.
	scale:      f32,

	// The fallback font, with an atlas of its own.
	uni:        Unifont,
	// The emoji font, which draws into that atlas too; and how much it's
	// scaled by for EMOJI_SIZE (unscaled, in font units per logical pixel).
	emoji:      stbtt.fontinfo,
	emoji_ok:   bool,
	emoji_unit: f32,
}

font_init :: proc(f: ^Font) -> bool {
	regular := &f.faces[.Regular]
	if !stbtt.InitFont(&regular.info, raw_data(FACE_DATA[.Regular]), 0) {
		return false
	}
	// Regular is sized by its pixel height; that's the em every face gets.
	s := stbtt.ScaleForPixelHeight(&regular.info, FONT_SIZE)
	f.em = s / stbtt.ScaleForMappingEmToPixels(&regular.info, 1)
	if !face_init(f, .Regular) {
		return false
	}

	ascent, descent, line_gap: i32
	stbtt.GetFontVMetrics(&regular.info, &ascent, &descent, &line_gap)
	text_height := f32(ascent - descent) * s
	f.baseline = (LINE_HEIGHT - text_height) / 2 + f32(ascent) * s

	// Without its emoji the UI still works: they draw as the fallback.
	if stbtt.InitFont(&f.emoji, raw_data(EMOJI_FONT_DATA), 0) {
		f.emoji_ok = true
		f.emoji_unit = stbtt.ScaleForPixelHeight(&f.emoji, EMOJI_SIZE)
	}
	f.zoom = 1
	f.ok = true
	return true
}

// face_init reads a face's file: the characters it has, and how wide.
@(private = "file")
face_init :: proc(f: ^Font, style: Font_Style) -> bool {
	fc := &f.faces[style]
	fc.tried = true
	if !stbtt.InitFont(&fc.info, raw_data(FACE_DATA[style]), 0) {
		return false
	}

	// Everything in the Basic Multilingual Plane the face has a glyph for,
	// except control characters.
	codepoints := make([dynamic]rune)
	for r in rune(0x20) ..< 0x10000 {
		if (r >= 0x7f && r < 0xa0) || (r >= 0xd800 && r < 0xe000) {
			continue
		}
		if stbtt.FindGlyphIndex(&fc.info, r) != 0 {
			append(&codepoints, r)
		}
	}
	if len(codepoints) == 0 {
		delete(codepoints)
		return false
	}
	fc.codepoints = codepoints[:]
	fc.advance = make([]f32, len(fc.codepoints))
	fc.glyphs = make([]stbtt.packedchar, len(fc.codepoints))

	fc.unit = stbtt.ScaleForMappingEmToPixels(&fc.info, f.em)
	for r, i in fc.codepoints {
		advance, lsb: i32
		stbtt.GetCodepointHMetrics(&fc.info, r, &advance, &lsb)
		fc.advance[i] = f32(advance) * fc.unit
	}

	fc.fallback = 0
	for r in FALLBACK_CHARS {
		if i, found := slice.binary_search(fc.codepoints, r); found {
			fc.fallback = i32(i)
			break
		}
	}
	for &index, c in fc.ascii {
		i, found := slice.binary_search(fc.codepoints, rune(c))
		index = i32(i) if found else fc.fallback
	}
	fc.ok = true
	return true
}

// face_get is one of the font's faces, read the first time it's asked
// for; Regular if that one can't be.
face_get :: proc(f: ^Font, style: Font_Style) -> ^Face {
	fc := &f.faces[style]
	if !fc.tried {
		face_init(f, style)
	}
	return fc if fc.ok else &f.faces[.Regular]
}

// font_line_height is how tall a line of this font is, in logical pixels.
font_line_height :: proc(f: ^Font) -> i32 {
	return i32(math.round(LINE_HEIGHT * f.zoom))
}

font_destroy :: proc(f: ^Font) {
	unifont_destroy(&f.uni)
	for &fc in f.faces {
		delete(fc.pixels)
		delete(fc.codepoints)
		delete(fc.advance)
		delete(fc.glyphs)
	}
	// Everything, so a font built again asks for new atlases rather
	// than trusting the ones this scale used to have (see render).
	f^ = {}
}

// font_set_scale says the font is now drawn at `scale` physical pixels per
// logical pixel: each face's atlas is built again for it before it's next
// drawn (font_build_atlas).
font_set_scale :: proc(f: ^Font, scale: f32) {
	f.scale = scale
}

// font_build_atlas rasterizes a face's glyphs for the font's scale, if its
// atlas is for another (or it has none). It says whether there's a new one
// to upload.
font_build_atlas :: proc(f: ^Font, style: Font_Style) -> bool {
	fc := &f.faces[style]
	if fc.scale == f.scale && fc.pixels != nil {
		return false
	}
	delete(fc.pixels)
	fc.pixels = nil
	fc.scale = f.scale
	if !fc.ok {
		return false
	}

	// Start small and grow until everything fits. Two extra rows at the
	// bottom, outside the packing area, hold the white texels.
	for size: i32 = 256; size <= 4096; size *= 2 {
		pixels := make([]u8, int(size) * int(size + 2))
		spc: stbtt.pack_context
		if !stbtt.PackBegin(&spc, raw_data(pixels), size, size, size, 1, nil) {
			delete(pixels)
			return false
		}
		r := stbtt.pack_range {
			// Negative: the em size, rather than the pixel height.
			font_size                   = -f.em * f.scale,
			array_of_unicode_codepoints = raw_data(fc.codepoints),
			num_chars                   = i32(len(fc.codepoints)),
			chardata_for_range          = raw_data(fc.glyphs),
		}
		packed := stbtt.PackFontRanges(&spc, raw_data(FACE_DATA[style]), 0, &r, 1)
		stbtt.PackEnd(&spc)
		if !packed {
			delete(pixels)
			continue
		}

		white_row := int(size) * int(size)
		for i in 0 ..< 2 {
			pixels[white_row + i] = 255
			pixels[white_row + int(size) + i] = 255
		}
		fc.pixels = pixels
		fc.width, fc.height = size, size + 2
		fc.white = {1 / f32(fc.width), (f32(size) + 1) / f32(fc.height)}
		return true
	}
	return false
}

// Which font a character is drawn from.
@(private = "file")
Glyph_Source :: enum {
	Face, // the index is into the face's arrays
	Unifont, // the index is the character itself
	Emoji, // the index is the character itself
	Placeholder, // one of the server's emoji, drawn over it by the UI: room, nothing drawn
	None, // draws nothing and takes no room (is_ignorable)
}

// find_glyph finds a character's glyph, or the fallback's, for text in
// `style`; `face` is the face it's from when it's from one. Invalid UTF-8
// reaches here as utf8.RUNE_ERROR, so it shows as the fallback too.
@(private = "file")
find_glyph :: proc(
	f: ^Font,
	style: Font_Style,
	r: rune,
) -> (
	index: int,
	source: Glyph_Source,
	face: Font_Style,
) {
	fc := face_get(f, style)
	face = style if fc == &f.faces[style] else .Regular
	if r >= 0 && r < len(fc.ascii) {
		return int(fc.ascii[r]), .Face, face
	}
	if i, found := slice.binary_search(fc.codepoints, r); found {
		return i, .Face, face
	}
	// Regular may have it when the style doesn't.
	if face != .Regular {
		if i, found := slice.binary_search(f.faces[.Regular].codepoints, r); found {
			return i, .Face, .Regular
		}
	}
	if is_ignorable(r) {
		return 0, .None, face
	}
	if r == proto.CUSTOM_EMOJI_PLACEHOLDER {
		return 0, .Placeholder, face
	}
	if f.emoji_ok && r >= 0xa9 {
		if _, is := proto.emoji_index(r); is {
			return int(r), .Emoji, face
		}
	}
	if unifont_width(&f.uni, r) > 0 {
		return int(r), .Unifont, face
	}
	return int(fc.fallback), .Face, face
}

font_text_width :: proc(f: ^Font, text: string, style := Font_Style.Regular) -> f32 {
	return font_text_width_unzoomed(f, text, style) * f.zoom
}

@(private = "file")
font_text_width_unzoomed :: proc(f: ^Font, text: string, style: Font_Style) -> f32 {
	w: f32
	for r in text {
		i, source, face := find_glyph(f, style, r)
		switch source {
		case .Face:
			w += f.faces[face].advance[i]
		case .Unifont:
			w += f32(f.uni.width[i])
		case .Emoji:
			w += emoji_advance(f, r)
		case .Placeholder:
			w += CUSTOM_EMOJI_ADVANCE
		case .None:
		}
	}
	return w
}

// How much room one of the server's emoji takes in a line, and how big
// it's drawn (logical pixels).
CUSTOM_EMOJI_ADVANCE :: 19
CUSTOM_EMOJI_SIZE :: 17

// emoji_advance is how far an emoji moves the pen, in logical pixels.
@(private = "file")
emoji_advance :: proc(f: ^Font, r: rune) -> f32 {
	advance, lsb: i32
	stbtt.GetCodepointHMetrics(&f.emoji, r, &advance, &lsb)
	return math.round(f32(advance) * f.emoji_unit)
}

// emoji_cache puts an emoji's glyph in Unifont's atlas at its scale, if
// it isn't there already, and says which slot it has and where the glyph
// is from the pen and the baseline (physical pixels). Fails once the
// atlas is full, as unifont_cache does.
@(private = "file")
emoji_cache :: proc(f: ^Font, r: rune) -> (slot: i32, box: Emoji_Box, ok: bool) {
	u := &f.uni
	if s, found := u.slots[r]; found {
		return s, u.emoji_boxes[r], true
	}
	if u.full || u.side == 0 {
		return
	}
	slot = i32(len(u.slots))
	if slot >= u.per_row * u.per_row {
		u.full = true
		return
	}
	if u.pixels == nil {
		u.pixels = make([]u8, int(u.side) * int(u.side))
	}
	scale := f.emoji_unit * u.scale
	x0, y0, x1, y1: i32
	stbtt.GetCodepointBitmapBox(&f.emoji, r, scale, scale, &x0, &y0, &x1, &y1)
	// What doesn't fit in a slot is cut off; at EMOJI_SIZE nothing is.
	box = {x0, y0, min(x1 - x0, u.cell - 1), min(y1 - y0, u.cell - 1)}
	sx := (slot % u.per_row) * u.cell
	sy := (slot / u.per_row) * u.cell
	if box.w > 0 && box.h > 0 {
		stbtt.MakeCodepointBitmap(
			&f.emoji,
			raw_data(u.pixels[int(sy) * int(u.side) + int(sx):]),
			box.w,
			box.h,
			u.side,
			scale,
			scale,
			r,
		)
	}
	u.slots[r] = slot
	u.emoji_boxes[r] = box
	u.dirty_y0 = min(u.dirty_y0, sy)
	u.dirty_y1 = max(u.dirty_y1, sy + u.cell)
	return slot, box, true
}

// font_cache_glyphs puts the Unifont glyphs `text` needs in their atlas,
// ahead of font_layout; the renderer uploads what changed in between.
font_cache_glyphs :: proc(f: ^Font, text: string, style := Font_Style.Regular) {
	for r in text {
		#partial switch _, source, _ := find_glyph(f, style, r); source {
		case .Unifont:
			unifont_cache(&f.uni, r)
		case .Emoji:
			emoji_cache(f, r)
		}
	}
}

// font_faces_used is which faces drawing `text` in `style` takes glyphs
// from, for the renderer to have their atlases ready.
font_faces_used :: proc(f: ^Font, text: string, style: Font_Style) -> (used: bit_set[Font_Style]) {
	for r in text {
		if _, source, face := find_glyph(f, style, r); source == .Face {
			used += {face}
		}
	}
	return
}

Glyph_Quad :: struct {
	x0, y0, x1, y1: f32, // logical pixels
	u0, v0, u1, v1: f32,
	unifont:        bool, // from the Unifont atlas rather than a face's
	face:           Font_Style, // which face's atlas, if not
}

// font_layout calls `emit` for every visible glyph of `text` in `style`,
// with the top of its line box at `y` (all logical pixels). Glyph edges are
// snapped to physical pixels, which keeps small text crisp.
font_layout :: proc(
	f: ^Font,
	text: string,
	x, y: f32,
	data: rawptr,
	emit: proc(data: rawptr, q: Glyph_Quad),
	style := Font_Style.Regular,
) {
	if f.zoom == 1 {
		font_layout_unzoomed(f, text, style, x, y, data, emit)
		return
	}
	// In the zoomed font's own space, and the glyphs blown up from it.
	Zoomed :: struct {
		zoom: f32,
		data: rawptr,
		emit: proc(data: rawptr, q: Glyph_Quad),
	}
	z := Zoomed{f.zoom, data, emit}
	font_layout_unzoomed(f, text, style, x / f.zoom, y / f.zoom, &z, proc(data: rawptr, q: Glyph_Quad) {
		z := (^Zoomed)(data)
		q := q
		q.x0, q.y0, q.x1, q.y1 = q.x0 * z.zoom, q.y0 * z.zoom, q.x1 * z.zoom, q.y1 * z.zoom
		z.emit(z.data, q)
	})
}

@(private = "file")
font_layout_unzoomed :: proc(
	f: ^Font,
	text: string,
	style: Font_Style,
	x, y: f32,
	data: rawptr,
	emit: proc(data: rawptr, q: Glyph_Quad),
) {
	s := f.scale
	baseline := math.round((y + f.baseline) * s)
	pen := x
	for r in text {
		i, source, face := find_glyph(f, style, r)
		switch source {
		case .None:
		case .Placeholder:
			pen += CUSTOM_EMOJI_ADVANCE
		case .Unifont:
			u := &f.uni
			if slot, ok := unifont_cache(u, r); ok && u.scale == s {
				h := f32(unifont_glyph_height(s))
				w := f32(unifont_glyph_width(u, r))
				px := math.round(pen * s)
				py := baseline - math.round(UNIFONT_ASCENT * h / UNIFONT_SIZE)
				sx := f32((slot % u.per_row) * u.cell)
				sy := f32((slot / u.per_row) * u.cell)
				side := f32(u.side)
				emit(
					data,
					Glyph_Quad {
						x0 = px / s,
						y0 = py / s,
						x1 = (px + w) / s,
						y1 = (py + h) / s,
						u0 = sx / side,
						v0 = sy / side,
						u1 = (sx + w) / side,
						v1 = (sy + h) / side,
						unifont = true,
					},
				)
			} else {
				// The atlas is full: this frame makes do with the
				// fallback, in the room the glyph would have had.
				emit_glyph(f, .Regular, int(f.faces[.Regular].fallback), pen, baseline, data, emit)
			}
			pen += f32(u.width[i])
		case .Emoji:
			u := &f.uni
			if slot, box, ok := emoji_cache(f, r); ok && u.scale == s {
				px := math.round(pen * s) + f32(box.x)
				py := baseline + f32(box.y)
				sx := f32((slot % u.per_row) * u.cell)
				sy := f32((slot / u.per_row) * u.cell)
				side := f32(u.side)
				w, h := f32(box.w), f32(box.h)
				emit(
					data,
					Glyph_Quad {
						x0 = px / s,
						y0 = py / s,
						x1 = (px + w) / s,
						y1 = (py + h) / s,
						u0 = sx / side,
						v0 = sy / side,
						u1 = (sx + w) / side,
						v1 = (sy + h) / side,
						unifont = true,
					},
				)
			} else {
				emit_glyph(f, .Regular, int(f.faces[.Regular].fallback), pen, baseline, data, emit)
			}
			pen += emoji_advance(f, r)
		case .Face:
			emit_glyph(f, face, i, pen, baseline, data, emit)
			pen += f.faces[face].advance[i]
		}
	}
}

// emit_glyph emits one of a face's glyphs, at `pen` (logical pixels) on
// `baseline` (physical ones). Nothing, if the face has no atlas for this
// scale (font_build_atlas).
@(private = "file")
emit_glyph :: proc(
	f: ^Font,
	face: Font_Style,
	i: int,
	pen, baseline: f32,
	data: rawptr,
	emit: proc(data: rawptr, q: Glyph_Quad),
) {
	fc := &f.faces[face]
	s := f.scale
	if fc.pixels == nil || fc.scale != s {
		return
	}
	g := &fc.glyphs[i]
	if g.x1 <= g.x0 {
		return
	}
	px := math.round(pen * s + g.xoff)
	py := baseline + math.round(g.yoff)
	w, h := f32(g.x1 - g.x0), f32(g.y1 - g.y0)
	emit(
		data,
		Glyph_Quad {
			x0 = px / s,
			y0 = py / s,
			x1 = (px + w) / s,
			y1 = (py + h) / s,
			u0 = f32(g.x0) / f32(fc.width),
			v0 = f32(g.y0) / f32(fc.height),
			u1 = f32(g.x1) / f32(fc.width),
			v1 = f32(g.y1) / f32(fc.height),
			face = face,
		},
	)
}

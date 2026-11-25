package render

import stbtt "client:wstbtt"
import "common:proto"
import "core:math"
import "core:slice"
import "core:unicode/utf8"

// The UI font is Roboto (embedded with #load), rasterized with stb_truetype.
// Every character the font has is used, which includes its Latin, Greek and
// Cyrillic letters and common punctuation and symbols. Emoji (proto/emoji.odin)
// are color pictures from a sheet (emoji_atlas.odin). Each emoji takes a fixed
// amount of space in the line and is drawn from a texture of its own instead
// of from a font's atlas. Any other character comes from one of the system's
// fonts if one has it and they are turned on (sysfont.odin), from Unifont
// (unifont.odin) if it has a glyph for it, and is drawn as the replacement
// character otherwise. Those glyphs share an atlas that fills up as text
// needs them (glyph_atlas.odin).
//
// A font has faces, one per Font_Style: Roboto Regular, which the UI uses,
// and, for messages, Roboto Bold, Italic and Bold Italic, plus JetBrains Mono
// for code. Each face has its own glyphs and atlas and is only read and
// rasterized once text in it is measured or drawn, so the UI's font never
// builds more than Regular. All faces are set at Regular's em size and on its
// baseline so that styles can be mixed in a line. The other files are from a
// later Roboto (2.137) with a different ascent and descent, which would make
// them about an eighth bigger if they were sized by pixel height like
// Regular. A character that a face does not have comes from Regular, then
// from the fallbacks described above, which have no styles and are drawn as
// they are.
//
// Layout happens in logical pixels, but glyphs are rasterized at the
// display's real density (`scale` physical pixels per logical pixel), so text
// is sharp on high-DPI screens. The atlases are rebuilt whenever the scale
// changes, for example when the window moves to another monitor.
//
// Glyph advances are taken from the unscaled font metrics, so text widths
// and therefore the whole layout are the same at every scale.
//
// A font can be zoomed. The chat's text has a size of its own (its zoom) on
// top of the UI's scale. A zoomed font is the same font laid out in a space
// that is `zoom` times smaller and then blown up again. Its widths and line
// height are `zoom` times those of the plain font, its atlases are rasterized
// at `scale * zoom`, and glyphs are snapped to physical pixels as usual, so
// it is as sharp as the rest.

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
// face_data is the font file of one face, for a browser to draw the same
// letters with (the web client's text fields, ui_field_web.odin).
face_data :: proc(style: Font_Style) -> []u8 {
	return FACE_DATA[style]
}

FONT_SIZE :: 15 // logical pixels, Regular's ascent to descent
LINE_HEIGHT :: 18 // logical pixels; microui's default, which its layout metrics assume

// Characters shown in place of ones the font does not have. The first one
// that the font has is used.
FALLBACK_CHARS :: [?]rune{utf8.RUNE_ERROR, '?'}

// One face of a font (see Font_Style). It holds a font file, its glyphs and
// their atlas.
Face :: struct {
	info:       stbtt.fontinfo,
	tried:      bool, // whether reading was attempted (face_get), even if it failed
	ok:         bool,
	// The characters we have glyphs for, sorted. The arrays below use the
	// same indices.
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
	// A few fully opaque texels for drawing solid rectangles.
	white:      [2]f32,
	// The pieces of rounded rects, below the white texels (corners.odin).
	corners:    Corner_Tiles,
}

Font :: struct {
	faces:    [Font_Style]Face,
	ok:       bool,
	// The em size every face is set at. This is Regular's em size for
	// FONT_SIZE (in logical pixels).
	em:       f32,
	// Distance from the top of a LINE_HEIGHT line box to the baseline.
	baseline: f32,
	// How much bigger than FONT_SIZE this font is drawn. This is 1 or the
	// chat's size (see above). It is set before the atlases are built.
	zoom:     f32,
	// The density the atlases are for (font_set_scale). A face whose atlas
	// is for a different density is rebuilt before it is drawn.
	scale:    f32,

	// The fallbacks: the system's fonts, shared by all fonts (nil for none),
	// and Unifont. Their glyphs are in an atlas of their own, which fills up
	// as text needs them (glyph_atlas.odin).
	sys:      ^System_Fonts,
	uni:      Unifont,
	fallback: Glyph_Atlas,
	// The system's color emoji drawn so far (sysemoji_native.odin), in RGBA.
	emoji:    Glyph_Atlas,
}

font_init :: proc(f: ^Font) -> bool {
	regular := &f.faces[.Regular]
	if !stbtt.InitFont(&regular.info, raw_data(FACE_DATA[.Regular]), 0) {
		return false
	}
	// Regular is sized by its pixel height, and that is the em size every
	// face gets.
	s := stbtt.ScaleForPixelHeight(&regular.info, FONT_SIZE)
	f.em = s / stbtt.ScaleForMappingEmToPixels(&regular.info, 1)
	if !face_init(f, .Regular) {
		return false
	}

	ascent, descent, line_gap: i32
	stbtt.GetFontVMetrics(&regular.info, &ascent, &descent, &line_gap)
	text_height := f32(ascent - descent) * s
	f.baseline = (LINE_HEIGHT - text_height) / 2 + f32(ascent) * s

	f.zoom = 1
	f.emoji.rgba = true
	f.ok = true
	return true
}

// face_init reads a face's file to find out which characters it has and how
// wide they are.
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

// face_get returns one of the font's faces, which is read the first time it
// is requested. It returns Regular if the requested face cannot be read.
face_get :: proc(f: ^Font, style: Font_Style) -> ^Face {
	fc := &f.faces[style]
	if !fc.tried {
		face_init(f, style)
	}
	return fc if fc.ok else &f.faces[.Regular]
}

// font_line_height returns the height of a line of this font in logical
// pixels.
font_line_height :: proc(f: ^Font) -> i32 {
	return i32(math.round(LINE_HEIGHT * f.zoom))
}

font_destroy :: proc(f: ^Font) {
	unifont_destroy(&f.uni)
	glyph_atlas_destroy(&f.fallback)
	glyph_atlas_destroy(&f.emoji)
	for &fc in f.faces {
		delete(fc.pixels)
		delete(fc.codepoints)
		delete(fc.advance)
		delete(fc.glyphs)
		delete(fc.corners.at)
	}
	// Reset everything, so that a font that is built again asks for new
	// atlases instead of trusting the ones from the previous scale (see
	// render).
	f^ = {}
}

// font_set_scale sets the font to be drawn at `scale` physical pixels per
// logical pixel. Each face's atlas is rebuilt for it before the face is next
// drawn (font_build_atlas).
font_set_scale :: proc(f: ^Font, scale: f32) {
	f.scale = scale
}

// font_build_atlas rasterizes a face's glyphs for the font's scale if its
// atlas is for a different scale or does not exist. It returns whether there
// is a new atlas to upload.
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
	// bottom, outside the packing area, hold the white texels, and the pieces
	// of rounded rects go below them.
	for size: i32 = 256; size <= 4096; size *= 2 {
		corners_h := corner_tiles_layout(&fc.corners, f.scale, size, size + 2)
		pixels := make([]u8, int(size) * int(size + 2 + corners_h))
		spc: stbtt.pack_context
		if !stbtt.PackBegin(&spc, raw_data(pixels), size, size, size, 1, nil) {
			delete(pixels)
			return false
		}
		r := stbtt.pack_range {
			// A negative value means the em size instead of the pixel height.
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
		corner_tiles_draw(&fc.corners, pixels, size)
		fc.pixels = pixels
		fc.width, fc.height = size, size + 2 + corners_h
		fc.white = {1 / f32(fc.width), (f32(size) + 1) / f32(fc.height)}
		return true
	}
	return false
}

// The kind of source a character's glyph is drawn from.
@(private)
Glyph_Source :: enum {
	Face, // the index is into the face's arrays
	System, // one of the system's fonts (sysfont.odin); the index is the character itself
	Unifont, // the index is the character itself
	Emoji, // the index is its cell in the sheet (emoji_cell)
	Placeholder, // one of the server's emoji, drawn over it by the UI: takes space but draws nothing; the index is its span
	None, // draws nothing and takes no room (is_ignorable)
}

// find_glyph finds a character's glyph (or the fallback's) for text in
// `style`. `face` is the face the glyph comes from, if it comes from one.
// Invalid UTF-8 arrives here as utf8.RUNE_ERROR, so it is shown as the
// fallback too.
@(private)
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
	if span := proto.emoji_placeholder_span(r); span > 0 {
		return span, .Placeholder, face
	}
	if r >= 0xa9 {
		if cell, is := emoji_cell(r); is {
			return cell, .Emoji, face
		}
	}
	if _, ok := system_glyph(f.sys, r); ok {
		return int(r), .System, face
	}
	if unifont_width(&f.uni, r) > 0 {
		return int(r), .Unifont, face
	}
	return int(fc.fallback), .Face, face
}

// font_text_width returns how wide `text` is in `style` (logical pixels).
// Text that needs shaping (shape_native.odin) is measured shaped, in visual
// order, the way it is drawn.
font_text_width :: proc(f: ^Font, text: string, style := Font_Style.Regular) -> f32 {
	if needs_shaping(f, text) {
		return shaped_text(f, style, text).width * f.zoom
	}
	w: f32
	for r in text {
		w += rune_advance(f, style, r)
	}
	return w * f.zoom
}

// rune_advance is how far a character moves the pen when it isn't shaped
// (logical pixels, unzoomed).
@(private)
rune_advance :: proc(f: ^Font, style: Font_Style, r: rune) -> f32 {
	i, source, face := find_glyph(f, style, r)
	switch source {
	case .Face:
		return f.faces[face].advance[i]
	case .Unifont:
		return f32(f.uni.width[i])
	case .System:
		g, _ := system_glyph(f.sys, r)
		return g.advance * f.em
	case .Emoji:
		return EMOJI_ADVANCE
	case .Placeholder:
		return custom_emoji_advance(i)
	case .None:
	}
	return 0
}

// How much space one of the server's emoji takes up in a line and how big it
// is drawn (in logical pixels).
CUSTOM_EMOJI_ADVANCE :: 19
CUSTOM_EMOJI_SIZE :: 17

// custom_emoji_advance is how much room an emoji of `span` takes up: as many
// times its size, with the gap around it that one of span 1 has.
custom_emoji_advance :: proc(span: int) -> f32 {
	return f32(span * CUSTOM_EMOJI_SIZE + (CUSTOM_EMOJI_ADVANCE - CUSTOM_EMOJI_SIZE))
}

// font_cache_glyphs puts the fallback glyphs, shaped glyphs and color emoji
// that `text` needs into their atlases before font_layout. The renderer
// uploads whatever changed in between.
font_cache_glyphs :: proc(f: ^Font, text: string, style := Font_Style.Regular) {
	if needs_shaping(f, text) {
		for g in shaped_text(f, style, text).glyphs {
			if g.kind == .Glyph {
				shaped_glyph_cache(f, g.font, g.id)
			} else {
				cache_rune(f, style, g.r)
			}
		}
		return
	}
	for r in text {
		cache_rune(f, style, r)
	}
}

@(private = "file")
cache_rune :: proc(f: ^Font, style: Font_Style, r: rune) {
	#partial switch _, source, _ := find_glyph(f, style, r); source {
	case .System:
		system_glyph_cache(f.sys, &f.fallback, r, f.em)
	case .Unifont:
		unifont_cache(&f.uni, &f.fallback, r)
	case .Emoji:
		if _, ok := system_emoji_glyph(f.sys, r); ok {
			system_emoji_cache(f.sys, &f.emoji, r, emoji_side(f.scale), EMOJI_FILL)
		}
	}
}

// font_faces_used returns the faces that glyphs are taken from when drawing
// `text` in `style`, so the renderer can have their atlases ready. (Shaped
// glyphs are in the fallback atlas, whichever font they are from.)
font_faces_used :: proc(f: ^Font, text: string, style: Font_Style) -> (used: bit_set[Font_Style]) {
	if needs_shaping(f, text) {
		return {.Regular}
	}
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
	fallback:       bool, // from the fallback atlas (Unifont's, the system's and shaped glyphs) rather than a face's
	emoji:          bool, // from the emoji sheet, in color; none of the others
	color:          bool, // from the font's atlas of the system's color emoji; none of the others
	face:           Font_Style, // which face's atlas the glyph is from, if it is a face glyph
}

// font_layout calls `emit` for every visible glyph of `text` in `style`,
// with the top of its line box at `y` (all logical pixels). Glyph edges are
// snapped to physical pixels, which keeps small text crisp. Text that needs
// shaping is shaped and put in visual order (shape_native.odin).
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
	// Lay out in the zoomed font's own space, then blow the glyphs up from
	// it.
	Zoomed :: struct {
		zoom: f32,
		data: rawptr,
		emit: proc(data: rawptr, q: Glyph_Quad),
	}
	z := Zoomed{f.zoom, data, emit}
	font_layout_unzoomed(
		f,
		text,
		style,
		x / f.zoom,
		y / f.zoom,
		&z,
		proc(data: rawptr, q: Glyph_Quad) {
			z := (^Zoomed)(data)
			q := q
			q.x0, q.y0, q.x1, q.y1 = q.x0 * z.zoom, q.y0 * z.zoom, q.x1 * z.zoom, q.y1 * z.zoom
			z.emit(z.data, q)
		},
	)
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
	// The text starts on a physical pixel and its glyphs are placed relative
	// to that. If each glyph were rounded from its own logical position, a
	// glyph would move one pixel and its neighbour two as the text moves (at
	// a scale of 1.5, such as while a window is resized), and the letters
	// would shuffle.
	origin := math.round(x * s)
	if needs_shaping(f, text) {
		sh := shaped_text(f, style, text)
		// A right-to-left line is placed from its right end, which is where
		// it is aligned (ui_bidi.odin's line_is_rtl): the end of the room
		// its measured width (rounded up) takes. Measuring each glyph back
		// from there keeps the letters that are already typed where they
		// are when another is added on their left; measured from the start
		// the rounding of each would change with the line's width and the
		// text would shuffle.
		back: f32
		if sh.rtl {
			end := x + math.ceil(sh.width * f.zoom) / f.zoom
			origin = math.round(end * s)
			back = sh.width
		}
		for g in sh.glyphs {
			if g.kind == .Char {
				layout_rune(f, style, g.r, g.x - back, origin, baseline, y, data, emit)
				continue
			}
			a := &f.fallback
			ag, ok := shaped_glyph_cache(f, g.font, g.id)
			if !ok || a.scale != s || ag.w == 0 || ag.h == 0 {
				continue
			}
			px := origin + math.round((g.x + g.dx - back) * s) + f32(ag.xoff)
			py := baseline - math.round(g.dy * s) + f32(ag.yoff)
			emit_atlas_glyph(a, ag, px, py, s, data, emit)
		}
		return
	}
	// The offset from the start of the text, in logical pixels.
	pen: f32
	for r in text {
		pen += layout_rune(f, style, r, pen, origin, baseline, y, data, emit)
	}
}

// layout_rune emits a character's glyph `pen` logical pixels from `origin`
// (where the text starts, in physical pixels) on `baseline` (physical
// pixels) in a line box whose top is `y` (logical), and returns how far it
// moves the pen.
@(private = "file")
layout_rune :: proc(
	f: ^Font,
	style: Font_Style,
	r: rune,
	pen, origin, baseline, y: f32,
	data: rawptr,
	emit: proc(data: rawptr, q: Glyph_Quad),
) -> f32 {
	s := f.scale
	i, source, face := find_glyph(f, style, r)
	switch source {
	case .None:
	case .Placeholder:
		return custom_emoji_advance(i)
	case .Unifont, .System:
		advance: f32
		g: Atlas_Glyph
		ok: bool
		if source == .Unifont {
			advance = f32(f.uni.width[i])
			g, ok = unifont_cache(&f.uni, &f.fallback, r)
		} else {
			sg, _ := system_glyph(f.sys, r)
			advance = sg.advance * f.em
			g, ok = system_glyph_cache(f.sys, &f.fallback, r, f.em)
		}
		a := &f.fallback
		if ok && a.scale == s {
			if g.w > 0 && g.h > 0 {
				px := origin + math.round(pen * s) + f32(g.xoff)
				emit_atlas_glyph(a, g, px, baseline + f32(g.yoff), s, data, emit)
			}
		} else {
			// The atlas is full, so this frame uses the fallback in the
			// space the glyph would have had.
			emit_glyph(f, .Regular, int(f.faces[.Regular].fallback), pen, origin, baseline, data, emit)
		}
		return advance
	case .Emoji:
		// Place it on whole physical pixels like the text next to it.
		px := origin + math.round(pen * s) + math.round((EMOJI_ADVANCE - EMOJI_SIZE) / 2 * s)
		py := math.round((y + (LINE_HEIGHT - EMOJI_SIZE) / 2) * s)
		side := math.round(EMOJI_SIZE * s)
		// The system's picture where there is one (sysemoji_native.odin),
		// drawn at this size; the sheet's otherwise, or while the atlas
		// is full.
		if _, has := system_emoji_glyph(f.sys, r); has {
			a := &f.emoji
			g, ok := system_emoji_cache(f.sys, a, r, i32(side), EMOJI_FILL)
			if ok && a.scale == s && f32(g.w) == side {
				emit(
					data,
					Glyph_Quad {
						x0 = px / s,
						y0 = py / s,
						x1 = (px + side) / s,
						y1 = (py + side) / s,
						u0 = f32(g.x) / f32(a.side),
						v0 = f32(g.y) / f32(a.side),
						u1 = f32(g.x + g.w) / f32(a.side),
						v1 = f32(g.y + g.h) / f32(a.side),
						color = true,
					},
				)
				return EMOJI_ADVANCE
			}
		}
		u0, v0, u1, v1 := emoji_uv(i)
		emit(
			data,
			Glyph_Quad {
				x0 = px / s,
				y0 = py / s,
				x1 = (px + side) / s,
				y1 = (py + side) / s,
				u0 = u0,
				v0 = v0,
				u1 = u1,
				v1 = v1,
				emoji = true,
			},
		)
		return EMOJI_ADVANCE
	case .Face:
		emit_glyph(f, face, i, pen, origin, baseline, data, emit)
		return f.faces[face].advance[i]
	}
	return 0
}

// emit_atlas_glyph emits a glyph of the fallback atlas with its top left at
// px, py (physical pixels).
@(private = "file")
emit_atlas_glyph :: proc(
	a: ^Glyph_Atlas,
	g: Atlas_Glyph,
	px, py, s: f32,
	data: rawptr,
	emit: proc(data: rawptr, q: Glyph_Quad),
) {
	side := f32(a.side)
	emit(
		data,
		Glyph_Quad {
			x0 = px / s,
			y0 = py / s,
			x1 = (px + f32(g.w)) / s,
			y1 = (py + f32(g.h)) / s,
			u0 = f32(g.x) / side,
			v0 = f32(g.y) / side,
			u1 = f32(g.x + g.w) / side,
			v1 = f32(g.y + g.h) / side,
			fallback = true,
		},
	)
}

// emit_glyph emits one of a face's glyphs `pen` logical pixels from `origin`
// (in physical pixels, where the text starts) on `baseline` (also in physical
// pixels). It emits nothing if the face has no atlas for this scale
// (font_build_atlas).
@(private = "file")
emit_glyph :: proc(
	f: ^Font,
	face: Font_Style,
	i: int,
	pen, origin, baseline: f32,
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
	px := origin + math.round(pen * s + g.xoff)
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

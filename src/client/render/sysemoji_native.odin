#+build !wasi
package render

import "core:strings"

// The system's color emoji (sysfont.odin): the emoji of the bundled sheet
// (emoji_atlas.odin) are drawn from the system's emoji font where it has
// them in a format we draw (colorfont.odin), and from the sheet otherwise.
// An emoji takes the same space either way, so turning this on or off
// doesn't move any text. Its picture is drawn at the size it is shown, into
// the font's color atlas (Font.emoji), the first time it is needed.
//
// The emoji font is the one the system offers for 😀: Segoe UI Emoji on
// Windows, Apple Color Emoji on macOS, and whatever fontconfig prefers
// elsewhere (usually Noto Color Emoji). It is mapped like the other fonts,
// which matters here: Apple Color Emoji is close to 200 MB, of which only
// the pictures drawn are ever read.

System_Emoji :: struct {
	tried: bool, // whether the font was looked for (or that failed)
	ok:    bool,
	font:  Color_Font,
	name:  string,
}

system_emoji_destroy :: proc(e: ^System_Emoji) {
	if e.ok {
		unmap_font_file(e.font.data)
	}
	delete(e.name)
	e^ = {}
}

// system_emoji_font finds the system's emoji font the first time it is
// needed. It returns nil if there is none that can be drawn.
@(private = "file")
system_emoji_font :: proc(s: ^System_Fonts) -> ^Color_Font {
	e := &s.emoji
	if !e.tried {
		e.tried = true
		files := make([dynamic]Font_File, context.temp_allocator)
		system_emoji_files(s, &files)
		for file in files {
			data, mapped := map_font_file(file.path)
			if !mapped {
				continue
			}
			if font, ok := color_font_open(data, file.index); ok {
				e.font, e.ok = font, true
				e.name = strings.clone(color_font_name(&e.font))
				break
			}
			unmap_font_file(data)
		}
	}
	return &e.font if e.ok else nil
}

// system_emoji_glyph returns the emoji font's glyph for a character, if the
// system's emoji are on and the font has a picture for it.
system_emoji_glyph :: proc(s: ^System_Fonts, r: rune) -> (glyph: int, ok: bool) {
	if s == nil || !s.emoji_enabled {
		return
	}
	found: bool
	if glyph, found = s.emoji_found[r]; !found {
		if font := system_emoji_font(s); font != nil {
			glyph = color_font_glyph(font, r)
		}
		s.emoji_found[r] = glyph
	}
	return glyph, glyph != 0
}

// system_emoji_cache puts a character's emoji, drawn `side` x `side`
// physical pixels with `fill` of that taken up, into the color atlas `a`, if
// it is not there already. It fails once the atlas is full (it is then
// emptied before the next frame) or if the picture can't be drawn.
system_emoji_cache :: proc(
	s: ^System_Fonts,
	a: ^Glyph_Atlas,
	r: rune,
	side: i32,
	fill: f32,
) -> (
	g: Atlas_Glyph,
	ok: bool,
) {
	if g, ok = glyph_atlas_find(a, atlas_key(r)); ok {
		return
	}
	glyph, has := system_emoji_glyph(s, r)
	if !has {
		return
	}
	pixels: []u8
	g, pixels, ok = glyph_atlas_add(a, atlas_key(r), side, side, 0, 0)
	if !ok || pixels == nil {
		return
	}
	if !color_glyph_draw(&s.emoji.font, glyph, int(side), fill, pixels, int(a.side)) {
		// Not drawable after all: the sheet's picture from now on.
		s.emoji_found[r] = 0
		ok = false
	}
	return
}

// system_emoji_name returns the name of the system's emoji font, or "" if
// there is none that can be drawn. It looks for the font if that hasn't
// happened yet.
system_emoji_name :: proc(s: ^System_Fonts) -> string {
	if system_emoji_font(s) == nil {
		return ""
	}
	return s.emoji.name
}

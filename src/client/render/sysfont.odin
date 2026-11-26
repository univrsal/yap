package render

import stbtt "client:wstbtt"
import "core:strings"

// The system's fonts, for the characters that the bundled faces don't have
// (docs/design/fonts.md). Windows, macOS and most Linux desktops come with
// fonts for nearly every script, which look much better than Unifont's
// 16-pixel bitmaps. They are optional: a character is drawn from a system
// font only where the system has one for it, and from Unifont otherwise, as
// before. The web client has no way to read the system's fonts, so there it
// is Unifont for everything (sysfont_web.odin).
//
// Which font has a character is asked of the system the first time the
// character is measured or drawn (system_font_candidates, one file per OS),
// and the answer is kept for the session, so each character is asked about
// at most once, and never for text the bundled faces have. The font files
// are mapped rather than read: their pages belong to the system's file cache
// rather than to us, and only the parts that are used are loaded at all (the
// character map and the outlines drawn). A 20 MB Chinese font costs little
// more than its table of characters.
//
// Glyphs are set at the bundled faces' em size, on their baseline, and
// rasterized with stb_truetype into the font's fallback atlas
// (glyph_atlas.odin) when they are first drawn. Nothing is shaped: a
// character is drawn from the font as it is, like Unifont's.
//
// The fonts are shared by every Font of the renderer (Font.sys), since which
// font has a character doesn't depend on the size.

// A font file of the system's, mapped.
System_Font :: struct {
	path:    string,
	index:   i32, // in a collection (.ttc)
	ps_name: string, // its PostScript name, which macOS names fonts by
	name:    string, // its full name, to show
	data:    []u8, // the mapped file; nil if it couldn't be read
	info:    stbtt.fontinfo,
	per_em:  f32, // font units to ems
	used:    int, // characters drawn from it so far
	gsub:    bool, // whether it has OpenType rules for joining and reordering letters
}

// What a character comes from: one of System_Fonts.fonts, or none.
System_Glyph :: struct {
	font:    i32, // index into System_Fonts.fonts, or -1 if no font has it
	advance: f32, // in ems
}

System_Fonts :: struct {
	enabled:       bool,
	// The user's language ("de-de", "ja", "zh-tw"), which decides between
	// Chinese, Japanese and Korean shapes of the same character.
	language:      string,
	fonts:         [dynamic]System_Font,
	found:         map[rune]System_Glyph,
	// Counts each time the fonts were turned on or off, so that whatever
	// was laid out with the other fonts can be laid out again.
	generation:    int,
	lookup:        System_Lookup, // the OS's own state (sysfont_*.odin)
	// The system's color emoji (sysemoji_native.odin): whether they are
	// used, the font, and its glyph for each emoji looked up (0 for none).
	emoji_enabled: bool,
	emoji:         System_Emoji,
	emoji_found:   map[rune]int,
	// Shaping text with these fonts and the faces (shape_native.odin).
	shaping:       Shaping,
}

// A font file that the system offers for a character.
Font_File :: struct {
	path:    string,
	index:   i32,
	ps_name: string, // when set, the font in the collection with this name rather than `index`
}

system_fonts_destroy :: proc(s: ^System_Fonts) {
	// First, while the fonts it shapes with are still mapped.
	shaping_destroy(&s.shaping)
	for &f in s.fonts {
		if f.data != nil {
			unmap_font_file(f.data)
		}
		delete(f.path)
		delete(f.ps_name)
		delete(f.name)
	}
	delete(s.fonts)
	delete(s.found)
	delete(s.language)
	system_lookup_destroy(&s.lookup)
	system_emoji_destroy(&s.emoji)
	delete(s.emoji_found)
	s^ = {}
}

// system_fonts_language sets the language that fonts are picked for (a
// locale name such as "de_DE.UTF-8" or "zh-TW"). Characters looked up
// already keep their fonts.
system_fonts_language :: proc(s: ^System_Fonts, locale: string) {
	delete(s.language)
	lang := locale
	if i := strings.index_any(lang, ".@"); i >= 0 {
		lang = lang[:i]
	}
	lang, _ = strings.replace_all(lang, "_", "-", context.temp_allocator)
	s.language = strings.to_lower(lang)
}

// system_fonts_enable turns the system's fonts on or off. It returns whether
// that changed anything.
system_fonts_enable :: proc(s: ^System_Fonts, enabled: bool) -> bool {
	if s.enabled == enabled {
		return false
	}
	s.enabled = enabled
	s.generation += 1
	// Strings were shaped with the other fonts.
	shaping_clear(&s.shaping)
	return true
}


// system_emoji_enable turns the system's color emoji on or off. It returns
// whether that changed anything.
system_emoji_enable :: proc(s: ^System_Fonts, enabled: bool) -> bool {
	if s.emoji_enabled == enabled {
		return false
	}
	s.emoji_enabled = enabled
	return true
}
// system_glyph returns the system font that a character is drawn from, if
// the fonts are on and one of them has the character.
system_glyph :: proc(s: ^System_Fonts, r: rune) -> (g: System_Glyph, ok: bool) {
	if s == nil || !s.enabled {
		return
	}
	found: bool
	if g, found = s.found[r]; !found {
		g = system_glyph_find(s, r)
		s.found[r] = g
		if g.font >= 0 {
			s.fonts[g.font].used += 1
		}
	}
	return g, g.font >= 0
}

// system_fonts_in_use returns the names of the system's fonts that text was
// drawn from so far, in the order they were first needed. In the temp
// allocator.
system_fonts_in_use :: proc(s: ^System_Fonts) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	for f in s.fonts {
		if f.used > 0 {
			append(&names, f.name)
		}
	}
	return names[:]
}

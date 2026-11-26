#+build !windows
#+build !darwin
#+build !wasi
package render

import "core:c"
import "core:dynlib"
import "core:reflect"
import "core:strings"

// The system's fonts on Linux and the BSDs (sysfont.odin), from fontconfig,
// which every desktop has. It is loaded when the first character needs it
// rather than linked, so that the client still starts without it; then
// there are only the bundled fonts. Most distributions install fonts for
// few scripts by default (CJK and color emoji fonts are often missing), so
// Unifont stays the fallback here more often than elsewhere.
//
// fontconfig sorts the installed fonts by how well they match: the user's
// language and a font that has the character. The first few that do have
// it are the candidates.

// The fontconfig calls used, loaded by name with the prefix "Fc".
@(private = "file")
Fontconfig :: struct {
	__handle:               dynlib.Library,
	InitLoadConfigAndFonts: proc "c" () -> rawptr,
	PatternCreate:          proc "c" () -> rawptr,
	PatternDestroy:         proc "c" (p: rawptr),
	PatternAddCharSet:      proc "c" (p: rawptr, object: cstring, cs: rawptr) -> c.int,
	PatternAddString:       proc "c" (p: rawptr, object: cstring, s: cstring) -> c.int,
	PatternAddBool:         proc "c" (p: rawptr, object: cstring, b: c.int) -> c.int,
	PatternGetString:       proc "c" (p: rawptr, object: cstring, n: c.int, s: ^cstring) -> c.int,
	PatternGetInteger:      proc "c" (p: rawptr, object: cstring, n: c.int, i: ^c.int) -> c.int,
	PatternGetCharSet:      proc "c" (p: rawptr, object: cstring, n: c.int, cs: ^rawptr) -> c.int,
	CharSetCreate:          proc "c" () -> rawptr,
	CharSetDestroy:         proc "c" (cs: rawptr),
	CharSetAddChar:         proc "c" (cs: rawptr, ucs4: u32) -> c.int,
	CharSetHasChar:         proc "c" (cs: rawptr, ucs4: u32) -> c.int,
	ConfigSubstitute:       proc "c" (config: rawptr, p: rawptr, kind: c.int) -> c.int,
	DefaultSubstitute:      proc "c" (p: rawptr),
	FontSort:               proc "c" (
		config: rawptr,
		p: rawptr,
		trim: c.int,
		csp: ^rawptr,
		result: ^c.int,
	) -> ^Font_Set,
	FontSetDestroy:         proc "c" (s: ^Font_Set),
	ConfigDestroy:          proc "c" (config: rawptr),
}

@(private = "file")
Font_Set :: struct {
	nfont: c.int,
	sfont: c.int,
	fonts: [^]rawptr,
}

// How many fonts fontconfig offers for a character are tried.
@(private = "file")
MAX_CANDIDATES :: 4

System_Lookup :: struct {
	tried:  bool, // whether fontconfig was loaded (or that failed)
	fc:     Fontconfig,
	config: rawptr, // nil if fontconfig isn't there
}

system_lookup_destroy :: proc(l: ^System_Lookup) {
	if l.config != nil {
		l.fc.ConfigDestroy(l.config)
	}
	if l.fc.__handle != nil {
		dynlib.unload_library(l.fc.__handle)
	}
	l^ = {}
}

// system_font_candidates lists the font files that may have `r`.
@(private)
system_font_candidates :: proc(s: ^System_Fonts, r: rune, out: ^[dynamic]Font_File) {
	candidates(s, r, out, false)
}

// candidates is system_font_candidates; with `emoji` it asks for fonts that
// fontconfig calls emoji fonts first. Without that, the fonts that merely
// have the character (DejaVu Sans, in four styles, has most emoji as
// outlines) come before an installed color emoji font and use up all the
// candidates.
@(private = "file")
candidates :: proc(s: ^System_Fonts, r: rune, out: ^[dynamic]Font_File, emoji: bool) {
	l := &s.lookup
	if !l.tried {
		l.tried = true
		count, ok := dynlib.initialize_symbols(&l.fc, "libfontconfig.so.1", "Fc")
		if !ok || count < len(reflect.struct_field_names(Fontconfig)) - 1 {
			if l.fc.__handle != nil {
				dynlib.unload_library(l.fc.__handle)
			}
			l.fc = {}
			return
		}
		l.config = l.fc.InitLoadConfigAndFonts()
	}
	if l.config == nil {
		return
	}
	fc := &l.fc
	pattern := fc.PatternCreate()
	defer fc.PatternDestroy(pattern)
	chars := fc.CharSetCreate()
	defer fc.CharSetDestroy(chars)
	fc.CharSetAddChar(chars, u32(r))
	fc.PatternAddCharSet(pattern, "charset", chars)
	fc.PatternAddBool(pattern, "scalable", 1)
	if emoji {
		fc.PatternAddString(pattern, "family", "emoji")
		fc.PatternAddBool(pattern, "color", 1)
	}
	if s.language != "" {
		fc.PatternAddString(
			pattern,
			"lang",
			strings.clone_to_cstring(s.language, context.temp_allocator),
		)
	}
	fc.ConfigSubstitute(l.config, pattern, 0) // FcMatchPattern
	fc.DefaultSubstitute(pattern)
	result: c.int
	set := fc.FontSort(l.config, pattern, 1, nil, &result)
	if set == nil {
		return
	}
	defer fc.FontSetDestroy(set)
	found := 0
	for font in set.fonts[:set.nfont] {
		if found == MAX_CANDIDATES {
			break
		}
		has: rawptr
		if fc.PatternGetCharSet(font, "charset", 0, &has) != 0 ||
		   fc.CharSetHasChar(has, u32(r)) == 0 {
			continue
		}
		file: cstring
		index: c.int
		if fc.PatternGetString(font, "file", 0, &file) != 0 || file == nil {
			continue
		}
		fc.PatternGetInteger(font, "index", 0, &index)
		append(
			out,
			Font_File {
				path  = strings.clone(string(file), context.temp_allocator),
				index = i32(index & 0xffff), // the upper half is a variable font's instance
			},
		)
		found += 1
	}
}

// system_emoji_files lists the fonts that the system offers for an emoji;
// the first that has color glyphs we draw is used (sysemoji_native.odin).
@(private)
system_emoji_files :: proc(s: ^System_Fonts, out: ^[dynamic]Font_File) {
	candidates(s, 0x1f600, out, true)
}

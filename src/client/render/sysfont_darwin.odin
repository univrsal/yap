package render

import "core:strings"
import CF "core:sys/darwin/CoreFoundation"
import "core:unicode/utf8"

// The system's fonts on macOS (sysfont.odin), from CoreText. First the font
// that the system would draw a character with in place of Helvetica, which
// takes the user's languages into account, then the rest of the system's
// list of fallback fonts for Helvetica (its cascade list), in order. Many of
// the system's fonts are collections (.ttc), so a font is found in its file
// by its PostScript name.
//
// The cascade list matters because stb_truetype can't read every font the
// system has: PingFang, macOS's font for Chinese, is a variable font with
// CFF2 outlines, so Chinese comes from the next font in the list that has it
// (Hiragino Sans GB, Heiti). Apple Color Emoji's pictures are PNGs, which
// stb_truetype can't draw either; sysfont.odin skips fonts without outlines.
// Some of Apple's fonts for complex scripts rely on shaping we don't do (and
// that kb_text_shape wouldn't either, see docs/design/fonts.md), so those
// scripts look as they would with Unifont: letter by letter.

@(private = "file")
CTFontRef :: distinct rawptr
@(private = "file")
CFArrayRef :: distinct rawptr

foreign import CoreText "system:CoreText.framework"
foreign import CoreFoundation "system:CoreFoundation.framework"

@(private = "file", default_calling_convention = "c")
foreign CoreText {
	CTFontCreateWithName :: proc(name: CF.String, size: f64, transform: rawptr) -> CTFontRef ---
	CTFontCreateForString :: proc(current: CTFontRef, str: CF.String, range: CF.Range) -> CTFontRef ---
	CTFontCopyAttribute :: proc(font: CTFontRef, attribute: CF.String) -> CF.TypeRef ---
	CTFontCopyPostScriptName :: proc(font: CTFontRef) -> CF.String ---
	CTFontCopyDefaultCascadeListForLanguages :: proc(font: CTFontRef, languages: CFArrayRef) -> CFArrayRef ---
	CTFontDescriptorCopyAttribute :: proc(descriptor: rawptr, attribute: CF.String) -> CF.TypeRef ---
	kCTFontURLAttribute: CF.String
	kCTFontNameAttribute: CF.String
}

@(private = "file", default_calling_convention = "c")
foreign CoreFoundation {
	CFStringCreateWithBytes :: proc(alloc: rawptr, bytes: [^]u8, num: CF.Index, encoding: CF.StringEncoding, external: b8) -> CF.String ---
	CFURLGetFileSystemRepresentation :: proc(url: CF.TypeRef, resolve: b8, buffer: [^]u8, max_len: CF.Index) -> b8 ---
	CFArrayGetCount :: proc(array: CFArrayRef) -> CF.Index ---
	CFArrayGetValueAtIndex :: proc(array: CFArrayRef, index: CF.Index) -> rawptr ---
}

@(private = "file")
UTF8 :: CF.StringEncoding(0x08000100)

System_Lookup :: struct {
	tried:   bool,
	base:    CTFontRef, // Helvetica, whose fallbacks are asked for
	cascade: [dynamic]Font_File, // its cascade list (owned strings)
}

system_lookup_destroy :: proc(l: ^System_Lookup) {
	if l.base != nil {
		CF.CFRelease(CF.TypeRef(l.base))
	}
	for f in l.cascade {
		delete(f.path)
		delete(f.ps_name)
	}
	delete(l.cascade)
	l^ = {}
}

// system_font_candidates lists the font files that macOS draws `r` with,
// best first.
@(private)
system_font_candidates :: proc(s: ^System_Fonts, r: rune, out: ^[dynamic]Font_File) {
	l := &s.lookup
	if !l.tried {
		l.tried = true
		lookup_init(l)
	}
	if l.base == nil {
		return
	}

	bytes, n := utf8.encode_rune(r)
	str := CFStringCreateWithBytes(nil, raw_data(bytes[:]), CF.Index(n), UTF8, false)
	if str != nil {
		defer CF.CFRelease(CF.TypeRef(str))
		// The range is in UTF-16 code units.
		font := CTFontCreateForString(l.base, str, {0, 2 if r >= 0x10000 else 1})
		if font != nil {
			defer CF.CFRelease(CF.TypeRef(font))
			ps := CTFontCopyPostScriptName(font)
			ps_name := cf_string(CF.TypeRef(ps))
			if ps != nil {
				CF.CFRelease(CF.TypeRef(ps))
			}
			url := CTFontCopyAttribute(font, kCTFontURLAttribute)
			path := cf_path(url)
			if url != nil {
				CF.CFRelease(url)
			}
			// LastResort is the font that draws a box for anything.
			if path != "" && ps_name != "" && ps_name != "LastResort" {
				append(out, Font_File{path = path, ps_name = ps_name})
			}
		}
	}
	append(out, ..l.cascade[:])
}

// lookup_init makes the base font and reads its cascade list.
@(private = "file")
lookup_init :: proc(l: ^System_Lookup) {
	name := "Helvetica"
	cf_name := CFStringCreateWithBytes(nil, raw_data(name), CF.Index(len(name)), UTF8, false)
	if cf_name == nil {
		return
	}
	l.base = CTFontCreateWithName(cf_name, 12, nil)
	CF.CFRelease(CF.TypeRef(cf_name))
	if l.base == nil {
		return
	}
	list := CTFontCopyDefaultCascadeListForLanguages(l.base, nil)
	if list == nil {
		return
	}
	defer CF.CFRelease(CF.TypeRef(list))
	for i in 0 ..< CFArrayGetCount(list) {
		descriptor := CFArrayGetValueAtIndex(list, i)
		url := CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute)
		path := cf_path(url)
		if url != nil {
			CF.CFRelease(url)
		}
		ps := CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute)
		ps_name := cf_string(ps)
		if ps != nil {
			CF.CFRelease(ps)
		}
		if path == "" || ps_name == "" || ps_name == "LastResort" {
			continue
		}
		append(&l.cascade, Font_File{path = strings.clone(path), ps_name = strings.clone(ps_name)})
	}
}

// cf_string returns a CFString's text, or "" for none. In the temp
// allocator.
@(private = "file")
cf_string :: proc(s: CF.TypeRef) -> string {
	if s == nil {
		return ""
	}
	return CF.StringCopyToOdinString(CF.String(s), context.temp_allocator)
}

// cf_path returns a file URL's path, or "" for none. In the temp allocator.
@(private = "file")
cf_path :: proc(url: CF.TypeRef) -> string {
	if url == nil {
		return ""
	}
	path: [1024]u8
	if !CFURLGetFileSystemRepresentation(url, true, raw_data(path[:]), len(path)) {
		return ""
	}
	return strings.clone(string(cstring(raw_data(path[:]))), context.temp_allocator)
}

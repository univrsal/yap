#+build !wasi
package render

import stbtt "client:wstbtt"
import "core:strings"
import "core:unicode/utf16"

// The part of the system's fonts (sysfont.odin) that reads font files, which
// the web client doesn't have.

// system_font_open returns the index of a font file in s.fonts, mapping it
// the first time. It returns -1 if the file can't be used, which is kept too
// so that it isn't tried again.
@(private)
system_font_open :: proc(s: ^System_Fonts, file: Font_File) -> int {
	for f, i in s.fonts {
		if f.path != file.path {
			continue
		}
		same := f.ps_name == file.ps_name if file.ps_name != "" else f.index == file.index
		if same {
			return i if f.data != nil else -1
		}
	}
	f := System_Font {
		path    = strings.clone(file.path),
		index   = file.index,
		ps_name = strings.clone(file.ps_name),
	}
	if data, mapped := map_font_file(file.path); mapped {
		if system_font_init(&f, data) {
			f.data = data
		} else {
			unmap_font_file(data)
		}
	}
	append(&s.fonts, f)
	return len(s.fonts) - 1 if f.data != nil else -1
}

// system_font_init reads a mapped font file's headers: which font of a
// collection to use, and its names.
@(private = "file")
system_font_init :: proc(f: ^System_Font, data: []u8) -> bool {
	count := max(1, stbtt.GetNumberOfFonts(raw_data(data)))
	if f.ps_name != "" {
		// The font of the collection with that name.
		f.index = -1
		for i in 0 ..< count {
			info: stbtt.fontinfo
			if font_init_at(&info, data, i) && font_name(&info, 6) == f.ps_name {
				f.index = i
				break
			}
		}
		if f.index < 0 && count == 1 {
			// A single font that doesn't go by that name: one of a variable
			// font's styles, which stb_truetype draws as the font's default.
			f.index = 0
		}
		if f.index < 0 {
			return false
		}
	}
	if f.index >= count || !font_init_at(&f.info, data, f.index) {
		return false
	}
	f.per_em = stbtt.ScaleForMappingEmToPixels(&f.info, 1)
	f.gsub = has_table(data, f.info.fontstart, "GSUB")
	if f.ps_name == "" {
		f.ps_name = strings.clone(font_name(&f.info, 6))
	}
	f.name = strings.clone(font_name(&f.info, 4))
	if f.name == "" {
		f.name = strings.clone(f.ps_name)
	}
	return true
}

// font_init_at reads the headers of font `index` of a file (0 unless it is a
// collection).
@(private = "file")
font_init_at :: proc(info: ^stbtt.fontinfo, data: []u8, index: i32) -> bool {
	offset := stbtt.GetFontOffsetForIndex(raw_data(data), index)
	return offset >= 0 && bool(stbtt.InitFont(info, raw_data(data), offset))
}

// font_name returns one of a font's names (4: its full name, 6: its
// PostScript name) in English, or "". In the temp allocator.
@(private = "file")
font_name :: proc(info: ^stbtt.fontinfo, id: i32) -> string {
	// Windows' names (UTF-16, big-endian), then the old Mac ones (ASCII for
	// these).
	n: i32
	if s := stbtt.GetFontNameString(info, &n, .PLATFORM_ID_MICROSOFT, 1, 0x409, id); s != nil {
		bytes := ([^]u8)(s)[:n]
		units := make([]u16, n / 2, context.temp_allocator)
		for &u, i in units {
			u = u16(bytes[2 * i]) << 8 | u16(bytes[2 * i + 1])
		}
		buf := make([]u8, len(units) * 3, context.temp_allocator)
		return string(buf[:utf16.decode_to_utf8(buf, units)])
	}
	if s := stbtt.GetFontNameString(info, &n, .PLATFORM_ID_MAC, 0, 0, id); s != nil {
		return strings.clone(string(([^]u8)(s)[:n]), context.temp_allocator)
	}
	return ""
}

// has_table returns whether the font that starts at `start` in a file has a
// table `tag`.
@(private = "file")
has_table :: proc(data: []u8, start: i32, tag: string) -> bool {
	at := int(start)
	if at < 0 || at + 12 > len(data) {
		return false
	}
	count := int(data[at + 4]) << 8 | int(data[at + 5])
	for i in 0 ..< count {
		rec := at + 12 + 16 * i
		if rec + 4 > len(data) {
			return false
		}
		if string(data[rec:][:4]) == tag {
			return true
		}
	}
	return false
}

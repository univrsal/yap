package render

import "core:os"
import "core:strings"
import win "core:sys/windows"

// The system's fonts on Windows (sysfont.odin). Every Windows since 10 comes
// with the same fonts for the world's scripts in its Fonts folder, so these
// are tried in order, and the first that draws a character wins. Chinese,
// Japanese and Korean share characters but not their shapes, so the font of
// the user's language goes first among those. Segoe UI Emoji is left out:
// its emoji are colored layers that stb_truetype would draw in one color.
//
// DirectWrite's IDWriteFontFallback could ask Windows instead, including
// fonts the user installed, but that needs bindings of our own for COM.

System_Lookup :: struct {
	fonts_dir: string,
}

// Fonts for most scripts, tried first: Latin, Greek, Cyrillic, Arabic,
// Hebrew, Armenian and Georgian, then symbols.
@(private = "file")
WINDOWS_FIRST := [?]string{"segoeui.ttf", "seguisym.ttf"}

// Chinese (simplified, then traditional), Japanese and Korean.
@(private = "file")
WINDOWS_CJK := [?]string{"msyh.ttc", "msjh.ttc", "YuGothR.ttc", "malgun.ttf"}

// The rest: Indic scripts, Southeast Asian ones, African ones, Canadian
// syllabics and Cherokee, Myanmar, Tibetan, Yi, Mongolian, historic
// scripts, Javanese, Tai scripts, Phags-pa, Thaana, Syriac, and older
// fonts with wide coverage, last the CJK extensions.
@(private = "file")
WINDOWS_REST := [?]string {
	"Nirmala.ttf",
	"LeelawUI.ttf",
	"ebrima.ttf",
	"gadugi.ttf",
	"mmrtext.ttf",
	"himalaya.ttf",
	"msyi.ttf",
	"monbaiti.ttf",
	"seguihis.ttf",
	"javatext.ttf",
	"ntailu.ttf",
	"taile.ttf",
	"phagspa.ttf",
	"mvboli.ttf",
	"estre.ttf",
	"sylfaen.ttf",
	"simsun.ttc",
	"SimsunExtG.ttf",
}

system_lookup_destroy :: proc(l: ^System_Lookup) {
	delete(l.fonts_dir)
	l^ = {}
}

// system_font_candidates lists the font files that may have `r`.
@(private)
system_font_candidates :: proc(s: ^System_Fonts, r: rune, out: ^[dynamic]Font_File) {
	l := &s.lookup
	if l.fonts_dir == "" {
		windir := os.get_env("WINDIR", context.temp_allocator)
		if windir == "" {
			windir = "C:\\Windows"
		}
		l.fonts_dir = strings.concatenate({windir, "\\Fonts\\"})
	}
	add :: proc(out: ^[dynamic]Font_File, dir, name: string) {
		path := strings.concatenate({dir, name}, context.temp_allocator)
		for f in out {
			if f.path == path {
				return
			}
		}
		append(out, Font_File{path = path})
	}
	for name in WINDOWS_FIRST {
		add(out, l.fonts_dir, name)
	}
	lang := s.language
	switch {
	case strings.has_prefix(lang, "ja"):
		add(out, l.fonts_dir, "YuGothR.ttc")
	case strings.has_prefix(lang, "ko"):
		add(out, l.fonts_dir, "malgun.ttf")
	case lang == "zh-tw" || lang == "zh-hk" || lang == "zh-mo" || strings.has_prefix(lang, "zh-hant"):
		add(out, l.fonts_dir, "msjh.ttc")
	}
	for name in WINDOWS_CJK {
		add(out, l.fonts_dir, name)
	}
	for name in WINDOWS_REST {
		add(out, l.fonts_dir, name)
	}
}

// map_font_file maps a file into memory, read-only.
@(private)
map_font_file :: proc(path: string) -> (data: []u8, ok: bool) {
	wpath := win.utf8_to_wstring(path, context.temp_allocator)
	file := win.CreateFileW(
		wpath,
		win.GENERIC_READ,
		win.FILE_SHARE_READ,
		nil,
		win.OPEN_EXISTING,
		win.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	if file == win.INVALID_HANDLE_VALUE {
		return
	}
	defer win.CloseHandle(file)
	size: win.LARGE_INTEGER
	if !win.GetFileSizeEx(file, &size) || size <= 0 || size > 1 << 31 {
		return
	}
	mapping := win.CreateFileMappingW(file, nil, win.PAGE_READONLY, 0, 0, nil)
	if mapping == nil {
		return
	}
	defer win.CloseHandle(mapping)
	view := win.MapViewOfFile(mapping, win.FILE_MAP_READ, 0, 0, 0)
	if view == nil {
		return
	}
	return ([^]u8)(view)[:size], true
}

@(private)
unmap_font_file :: proc(data: []u8) {
	win.UnmapViewOfFile(raw_data(data))
}

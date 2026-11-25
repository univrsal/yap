#+build !windows
#+build !darwin
#+build !wasi
#+build !js
package spell

import log "common:wlog"
import "core:c"
import "core:dynlib"
import "core:os"
import "core:strings"

// Hunspell, loaded at runtime (so that yap starts without it), with the
// dictionaries that are installed: a pair of files, `<tag>.aff` and
// `<tag>.dic`, in one of the directories Hunspell's own tools look in, or in
// the ones the client names (which are looked in first).
//
// Hunspell takes and gives words in the dictionary's encoding. UTF-8 and the
// Latin ones (ISO 8859-1 and -15) are handled, and a dictionary in another
// encoding isn't used.

@(private = "file")
Hunhandle :: distinct rawptr

@(private = "file")
Symbols :: struct {
	__handle:                  dynlib.Library,
	Hunspell_create:           proc "c" (affpath, dpath: cstring) -> Hunhandle,
	Hunspell_destroy:          proc "c" (h: Hunhandle),
	Hunspell_spell:            proc "c" (h: Hunhandle, word: cstring) -> c.int,
	Hunspell_get_dic_encoding: proc "c" (h: Hunhandle) -> cstring,
	Hunspell_suggest:          proc "c" (h: Hunhandle, list: ^[^]cstring, word: cstring) -> c.int,
	Hunspell_free_list:        proc "c" (h: Hunhandle, list: ^[^]cstring, n: c.int),
}

@(private = "file")
Encoding :: enum {
	UTF8,
	Latin1,
	Latin9, // ISO 8859-15
}

@(private = "file")
Dictionary :: struct {
	h:        Hunhandle,
	encoding: Encoding,
}

// A dictionary for one language.
Handle :: ^Dictionary

@(private = "file")
g_sym: Symbols

@(private = "file")
g_tried: bool

// The library's names: Linux names it by its soname, the BSDs version it
// differently, and their loaders find the newest for a name without one.
@(private = "file")
LIBRARIES := [?]string {
	"libhunspell-1.7.so.0",
	"libhunspell-1.6.so.0",
	"libhunspell-1.7.so",
	"libhunspell-1.6.so",
	"libhunspell.so",
}

@(private = "file")
load :: proc() -> bool {
	if !g_tried {
		g_tried = true
		ok := false
		for name in LIBRARIES {
			if _, ok = dynlib.initialize_symbols(&g_sym, name); ok {
				break
			}
		}
		s := &g_sym
		ok =
			ok &&
			s.Hunspell_create != nil &&
			s.Hunspell_destroy != nil &&
			s.Hunspell_spell != nil &&
			s.Hunspell_get_dic_encoding != nil &&
			s.Hunspell_suggest != nil &&
			s.Hunspell_free_list != nil
		if !ok {
			log.info("spell: no Hunspell library, so no spell checking")
			if g_sym.__handle != nil {
				dynlib.unload_library(g_sym.__handle)
			}
			g_sym = {}
		}
	}
	return g_sym.__handle != nil
}

@(private)
backend_available :: proc() -> bool {
	return load()
}

// search_dirs are where dictionaries are looked for: `dirs` first, then
// $DICPATH, then where the systems keep them.
@(private = "file")
search_dirs :: proc(dirs: []string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	append(&out, ..dirs)
	if p := os.get_env("DICPATH", context.temp_allocator); p != "" {
		append(&out, ..strings.split(p, ":", context.temp_allocator))
	}
	if home := os.get_env("HOME", context.temp_allocator); home != "" {
		append(&out, strings.concatenate({home, "/.local/share/hunspell"}, context.temp_allocator))
	}
	append(
		&out,
		"/usr/share/hunspell",
		"/usr/share/myspell",
		"/usr/share/myspell/dicts",
		"/usr/local/share/hunspell",
		"/usr/local/share/myspell",
	)
	return out[:]
}

// find is the path, without its extension, of the dictionary for `tag` (with
// a hyphen or an underscore), or "".
@(private = "file")
find :: proc(tag: string, dirs: []string) -> string {
	under, _ := strings.replace_all(tag, "-", "_", context.temp_allocator)
	for d in search_dirs(dirs) {
		for name in ([]string{under, tag}) {
			base := strings.concatenate({d, "/", name}, context.temp_allocator)
			aff := strings.concatenate({base, ".aff"}, context.temp_allocator)
			dic := strings.concatenate({base, ".dic"}, context.temp_allocator)
			if os.exists(aff) && os.exists(dic) {
				return base
			}
		}
	}
	return ""
}

@(private)
backend_languages :: proc(dirs: []string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	if !load() {
		return out[:]
	}
	seen := make(map[string]struct{}, context.temp_allocator)
	for d in search_dirs(dirs) {
		entries, err := os.read_all_directory_by_path(d, context.temp_allocator)
		if err != nil {
			continue
		}
		for e in entries {
			if !strings.has_suffix(e.name, ".aff") {
				continue
			}
			stem := e.name[:len(e.name) - len(".aff")]
			// Hyphenation patterns and the like are kept alongside.
			if strings.has_prefix(stem, "hyph_") || strings.has_prefix(stem, "th_") {
				continue
			}
			dic := strings.concatenate({d, "/", stem, ".dic"}, context.temp_allocator)
			if !os.exists(dic) {
				continue
			}
			tag := normalize_tag(stem)
			if tag in seen {
				continue
			}
			seen[tag] = {}
			append(&out, strings.clone(tag, allocator))
		}
	}
	return out[:]
}

@(private)
backend_open :: proc(tag: string, dirs: []string) -> (h: Handle, ok: bool) {
	if !load() {
		return nil, false
	}
	base := find(tag, dirs)
	if base == "" {
		log.warnf("spell: no dictionary for %s", tag)
		return nil, false
	}
	aff := strings.clone_to_cstring(
		strings.concatenate({base, ".aff"}, context.temp_allocator),
		context.temp_allocator,
	)
	dic := strings.clone_to_cstring(
		strings.concatenate({base, ".dic"}, context.temp_allocator),
		context.temp_allocator,
	)
	hh := g_sym.Hunspell_create(aff, dic)
	if hh == nil {
		log.warnf("spell: Hunspell couldn't read %s", base)
		return nil, false
	}
	encoding: Encoding
	switch strings.to_upper(string(g_sym.Hunspell_get_dic_encoding(hh)), context.temp_allocator) {
	case "UTF-8", "UTF8":
		encoding = .UTF8
	case "ISO8859-1", "ISO-8859-1":
		encoding = .Latin1
	case "ISO8859-15", "ISO-8859-15":
		encoding = .Latin9
	case:
		log.warnf(
			"spell: %s is in %s, which isn't supported",
			base,
			g_sym.Hunspell_get_dic_encoding(hh),
		)
		g_sym.Hunspell_destroy(hh)
		return nil, false
	}
	h = new(Dictionary)
	h^ = {hh, encoding}
	return h, true
}

@(private)
backend_close :: proc(h: Handle) {
	g_sym.Hunspell_destroy(h.h)
	free(h)
}

@(private)
backend_check :: proc(h: Handle, word: string) -> bool {
	w, ok := encode(h.encoding, word)
	if !ok {
		return false // a letter the dictionary can't even spell
	}
	return g_sym.Hunspell_spell(h.h, w) != 0
}

@(private)
backend_suggest :: proc(h: Handle, word: string, allocator := context.allocator) -> []string {
	w, ok := encode(h.encoding, word)
	if !ok {
		return nil
	}
	list: [^]cstring
	n := g_sym.Hunspell_suggest(h.h, &list, w)
	if n <= 0 || list == nil {
		return nil
	}
	defer g_sym.Hunspell_free_list(h.h, &list, n)
	out := make([]string, n, allocator)
	for i in 0 ..< int(n) {
		out[i] = decode(h.encoding, string(list[i]), allocator)
	}
	return out
}

// encode is `word` in the dictionary's encoding, as a C string in the temp
// allocator, and false if it has a character the encoding hasn't.
@(private = "file")
encode :: proc(encoding: Encoding, word: string) -> (cstring, bool) {
	if encoding == .UTF8 {
		return strings.clone_to_cstring(word, context.temp_allocator), true
	}
	b := make([dynamic]u8, 0, len(word) + 1, context.temp_allocator)
	for r in word {
		v, ok := latin_byte(encoding, r)
		if !ok {
			return nil, false
		}
		append(&b, v)
	}
	append(&b, 0)
	return cstring(raw_data(b)), true
}

@(private = "file")
decode :: proc(encoding: Encoding, s: string, allocator := context.allocator) -> string {
	if encoding == .UTF8 {
		return strings.clone(s, allocator)
	}
	b := strings.builder_make(0, len(s) * 2, allocator)
	for v in transmute([]u8)s {
		strings.write_rune(&b, latin_rune(encoding, v))
	}
	return strings.to_string(b)
}

// Where ISO 8859-15 differs from ISO 8859-1.
@(private = "file")
LATIN9 := [?]struct {
	b: u8,
	r: rune,
} {
	{0xA4, '€'},
	{0xA6, 'Š'},
	{0xA8, 'š'},
	{0xB4, 'Ž'},
	{0xB8, 'ž'},
	{0xBC, 'Œ'},
	{0xBD, 'œ'},
	{0xBE, 'Ÿ'},
}

@(private = "file")
latin_byte :: proc(encoding: Encoding, r: rune) -> (u8, bool) {
	if encoding == .Latin9 {
		for p in LATIN9 {
			if p.r == r {
				return p.b, true
			}
			if rune(p.b) == r {
				return 0, false // replaced in 8859-15
			}
		}
	}
	if r < 0x100 {
		return u8(r), true
	}
	return 0, false
}

@(private = "file")
latin_rune :: proc(encoding: Encoding, b: u8) -> rune {
	if encoding == .Latin9 {
		for p in LATIN9 {
			if p.b == b {
				return p.r
			}
		}
	}
	return rune(b)
}

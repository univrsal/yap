package spell

import "core:slice"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// Spell checking with whatever checker the system has:
//
//   - Windows: its own spell checker (ISpellChecker, Windows 8 and later),
//     with the languages that Windows has installed (spell_windows.odin).
//   - macOS: NSSpellChecker, with the languages it knows (spell_darwin.odin).
//   - Linux and the BSDs: Hunspell, loaded at runtime, with the dictionaries
//     that are installed where Hunspell's are kept or in the directories the
//     client names (spell_hunspell.odin).
//   - The web: nothing. The page's own text field is checked by the browser.
//
// A language is named by its tag, as the system names it but with a hyphen
// ("en-US", "de-DE", "de"). A Speller checks text against several languages at
// once: a word is right if any of them knows it, or if it is in the user's own
// dictionary (which yap keeps itself, not the system).
//
// Splitting text into words is done here, the same everywhere (next_word), and
// so is skipping what isn't meant as prose: anything with a digit or an
// underscore in it, acronyms (ALL CAPS), camelCase, mentions, channels,
// :emoji: and addresses (URLs and e-mail addresses).

// The most suggestions that suggest gives.
MAX_SUGGESTIONS :: 5

// How many words a Speller remembers the verdict on before it starts over.
@(private)
CACHE_MAX :: 4096

// One language that a Speller checks against.
@(private)
Checker :: struct {
	tag:    string,
	handle: Handle,
}

// What checks text against the languages it was given. It is used from the
// UI's thread only (macOS's checker wants that, and Windows' was made there).
Speller :: struct {
	checkers: [dynamic]Checker,
	// Where else to look for Hunspell dictionaries (yap's own downloads).
	dirs:     []string,
	// The user's own words.
	personal: map[string]struct{},
	// The verdict on words checked before: whether each is right.
	cache:    map[string]bool,
}

// available is whether there is a spell checker here at all: false on the web,
// and where Hunspell isn't installed.
available :: proc() -> bool {
	return backend_available()
}

// languages are the tags of the languages that can be checked here, sorted,
// each once. `dirs` are where else to look for Hunspell dictionaries (ignored
// elsewhere). Empty when nothing can be checked (no Hunspell, the web).
languages :: proc(dirs: []string = nil, allocator := context.allocator) -> []string {
	tags := backend_languages(dirs, allocator)
	slice.sort(tags)
	return tags[:len(slice.unique(tags))]
}

// normalize_tag is `tag` with hyphens instead of underscores ("en_US" is
// "en-US"), in the temp allocator.
normalize_tag :: proc(tag: string) -> string {
	t, _ := strings.replace_all(tag, "_", "-", context.temp_allocator)
	return t
}

// speller_set_languages makes `s` check against the languages `tags` (from
// languages), and returns how many of them it could open. One that is already
// open stays open. `dirs` are where else to look for Hunspell dictionaries.
speller_set_languages :: proc(s: ^Speller, tags: []string, dirs: []string = nil) -> int {
	// Close what isn't wanted any more.
	for i := len(s.checkers) - 1; i >= 0; i -= 1 {
		if !slice.contains(tags, s.checkers[i].tag) {
			backend_close(s.checkers[i].handle)
			delete(s.checkers[i].tag)
			ordered_remove(&s.checkers, i)
		}
	}
	for d in s.dirs {
		delete(d)
	}
	delete(s.dirs)
	s.dirs = make([]string, len(dirs))
	for d, i in dirs {
		s.dirs[i] = strings.clone(d)
	}
	outer: for tag in tags {
		for c in s.checkers {
			if c.tag == tag {
				continue outer
			}
		}
		if h, ok := backend_open(tag, s.dirs); ok {
			append(&s.checkers, Checker{strings.clone(tag), h})
		}
	}
	speller_forget(s)
	return len(s.checkers)
}

// speller_set_personal makes `words` the user's own words, which are always right.
speller_set_personal :: proc(s: ^Speller, words: []string) {
	for w in s.personal {
		delete(w)
	}
	clear(&s.personal)
	for w in words {
		if w != "" && w not_in s.personal {
			s.personal[strings.clone(w)] = {}
		}
	}
	speller_forget(s)
}

// speller_destroy closes what `s` has open and frees it.
speller_destroy :: proc(s: ^Speller) {
	for c in s.checkers {
		backend_close(c.handle)
		delete(c.tag)
	}
	delete(s.checkers)
	for d in s.dirs {
		delete(d)
	}
	delete(s.dirs)
	speller_set_personal(s, nil)
	delete(s.personal)
	delete(s.cache)
	s^ = {}
}

// speller_active is whether `s` checks anything at all.
speller_active :: proc(s: ^Speller) -> bool {
	return len(s.checkers) > 0
}

@(private)
speller_forget :: proc(s: ^Speller) {
	for w in s.cache {
		delete(w)
	}
	clear(&s.cache)
}

// check_word is whether `word` is right: in the user's own words (as it is, or
// with its first letter in lower case, as at the start of a sentence), or
// known to one of the languages. With no languages, every word is right.
check_word :: proc(s: ^Speller, word: string) -> bool {
	if len(s.checkers) == 0 || word == "" {
		return true
	}
	if ok, known := s.cache[word]; known {
		return ok
	}
	ok := in_personal(s, word)
	for c in s.checkers {
		if ok {
			break
		}
		ok = backend_check(c.handle, word)
	}
	if len(s.cache) >= CACHE_MAX {
		speller_forget(s)
	}
	s.cache[strings.clone(word)] = ok
	return ok
}

@(private)
in_personal :: proc(s: ^Speller, word: string) -> bool {
	if word in s.personal {
		return true
	}
	r, n := utf8.decode_rune_in_string(word)
	if !unicode.is_upper(r) {
		return false
	}
	lower := strings.concatenate(
		{utf8.runes_to_string({unicode.to_lower(r)}, context.temp_allocator), word[n:]},
		context.temp_allocator,
	)
	return lower in s.personal
}

// suggest is up to MAX_SUGGESTIONS words that `word` may have been meant to
// be: the best of each language first, then the rest in turn, each once.
suggest :: proc(s: ^Speller, word: string, allocator := context.allocator) -> []string {
	lists := make([][]string, len(s.checkers), context.temp_allocator)
	for c, i in s.checkers {
		lists[i] = backend_suggest(c.handle, word, context.temp_allocator)
	}
	out := make([dynamic]string, 0, MAX_SUGGESTIONS, allocator)
	for rank := 0; len(out) < MAX_SUGGESTIONS; rank += 1 {
		any := false
		for l in lists {
			if rank >= len(l) {
				continue
			}
			any = true
			if len(out) < MAX_SUGGESTIONS && !slice.contains(out[:], l[rank]) {
				append(&out, strings.clone(l[rank], allocator))
			}
		}
		if !any {
			break
		}
	}
	return out[:]
}

// misspelled are the words in `text` that are wrong, as their start and end.
// Nothing when `s` checks no language.
misspelled :: proc(s: ^Speller, text: string, allocator := context.allocator) -> [][2]int {
	out := make([dynamic][2]int, allocator)
	if !speller_active(s) {
		return out[:]
	}
	at := 0
	for {
		start, end, ok := next_word(text, at)
		if !ok {
			break
		}
		if !check_word(s, text[start:end]) {
			append(&out, [2]int{start, end})
		}
		at = end
	}
	return out[:]
}

// next_word is the next word in `text` from `at` on that is to be checked, as
// its start and end. A word is a run of letters (with the marks that go on
// them), with apostrophes between letters ("don't", "l'eau") but not at its
// ends. Hyphens split words: "e-mail" is checked as "e" and "mail".
//
// Skipped: words with a digit or underscore in them, words in capitals (two
// or more), camelCase, @mentions, #channels, :emoji:, and the whole of
// anything between spaces that looks like an address ("https://...",
// "www.x.org", "me@x.org").
next_word :: proc(text: string, at: int) -> (start, end: int, ok: bool) {
	i := clamp(at, 0, len(text))
	for i < len(text) {
		r, n := utf8.decode_rune_in_string(text[i:])
		if !is_word_rune(r) {
			i += n
			continue
		}
		start = i
		end = word_end(text, start)
		if word_skipped(text, start, end) {
			i = end
			continue
		}
		if chunk_start, chunk_end := chunk_around(text, start); is_address(
			text[chunk_start:chunk_end],
		) {
			i = chunk_end
			continue
		}
		return start, end, true
	}
	return 0, 0, false
}

// is_word_rune is whether `r` is part of a word as far as splitting goes:
// letters and what goes with them, and digits and underscores, which make a
// word skipped rather than split it.
@(private)
is_word_rune :: proc(r: rune) -> bool {
	return unicode.is_letter(r) || unicode.is_digit(r) || is_mark(r) || r == '_'
}

@(private)
is_mark :: proc(r: rune) -> bool {
	return unicode.is_nonspacing_mark(r) || unicode.is_spacing_mark(r) || unicode.is_enclosing_mark(r)
}

@(private)
is_apostrophe :: proc(r: rune) -> bool {
	return r == '\'' || r == '’'
}

// word_end is where the word starting at `start` ends: after its last word
// rune, taking in apostrophes that have word runes on both sides.
@(private)
word_end :: proc(text: string, start: int) -> int {
	i := start
	for i < len(text) {
		r, n := utf8.decode_rune_in_string(text[i:])
		if is_word_rune(r) {
			i += n
			continue
		}
		if is_apostrophe(r) && i + n < len(text) {
			next, _ := utf8.decode_rune_in_string(text[i + n:])
			if is_word_rune(next) {
				i += n
				continue
			}
		}
		break
	}
	return i
}

// word_skipped is whether the word text[start:end] isn't checked, for what it
// is made of or what is around it.
@(private)
word_skipped :: proc(text: string, start, end: int) -> bool {
	word := text[start:end]
	letters, upper := 0, 0
	lower_seen := false
	for r in word {
		switch {
		case unicode.is_digit(r) || r == '_':
			return true
		case unicode.is_upper(r):
			if lower_seen {
				return true // camelCase
			}
			upper += 1
			letters += 1
		case unicode.is_letter(r):
			lower_seen = true
			letters += 1
		}
	}
	if upper >= 2 && upper == letters {
		return true // an acronym
	}
	if start > 0 {
		switch text[start - 1] {
		case '@', '#':
			return true
		case ':':
			if end < len(text) && text[end] == ':' {
				return true // :emoji:
			}
		}
	}
	return false
}

// chunk_around is the run of text without spaces that `at` is in.
@(private)
chunk_around :: proc(text: string, at: int) -> (start, end: int) {
	start, end = at, at
	for start > 0 && !is_space_byte(text[start - 1]) {
		start -= 1
	}
	for end < len(text) && !is_space_byte(text[end]) {
		end += 1
	}
	return
}

@(private)
is_space_byte :: proc(b: u8) -> bool {
	return b == ' ' || b == '\t' || b == '\n' || b == '\r'
}

// is_address is whether `chunk` looks like a URL or an e-mail address.
@(private)
is_address :: proc(chunk: string) -> bool {
	if strings.contains(chunk, "://") || strings.has_prefix(chunk, "www.") {
		return true
	}
	at := strings.index_byte(chunk, '@')
	return at > 0 && strings.index_byte(chunk[at:], '.') > 1
}

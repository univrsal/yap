package client

import "core:strings"

import "client:platform"
import "client:spell"

// Spell checking in the composer: the words that the system's spell checker
// (client:spell) doesn't know are underlined with a wavy line in the text area
// (text_area_spell). Code isn't checked: `inline code` and ``` blocks.
//
// The languages are the one the system is set to and English, of those that
// the checker has. It is opened when first needed.

// What the UI keeps for spell checking.
UI_Spell :: struct {
	speller:    spell.Speller,
	opened:     bool,
	// Counts up when the languages or the user's words change, so text areas
	// know to check their text again.
	generation: u32,
}

// ui_speller is the UI's speller, opened with the default languages the first
// time. Nil when nothing can be checked here (the web, or no checker).
ui_speller :: proc(ui: ^UI) -> ^spell.Speller {
	when platform.WEB {
		return nil
	} else {
		sp := &ui.spell
		if !sp.opened {
			sp.opened = true
			sp.generation += 1
			tags := spell_default_languages(
				spell.languages(nil, context.temp_allocator),
				platform.locale_name(),
			)
			spell.speller_set_languages(&sp.speller, tags)
		}
		if !spell.speller_active(&sp.speller) {
			return nil
		}
		return &sp.speller
	}
}

ui_spell_destroy :: proc(ui: ^UI) {
	spell.speller_destroy(&ui.spell.speller)
	ui.spell = {}
}

// spell_default_languages are the languages to check when nothing was picked:
// the one of the locale `locale` ("de_DE.UTF-8", "de-DE", "") and English, as
// they are in `have` (sorted). The locale's own country first ("de-AT"), then
// the language on its own ("de"), its main country ("de-DE"), or any.
// For English, en-US comes before the others, and when the locale is in
// English that is the only English.
spell_default_languages :: proc(have: []string, locale: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	pick :: proc(out: ^[dynamic]string, have: []string, lang, country: string) {
		if lang == "" {
			return
		}
		tries := [?]string {
			strings.concatenate({lang, "-", country}, context.temp_allocator) if country != "" else "",
			lang,
			strings.concatenate(
				{lang, "-", strings.to_upper(lang, context.temp_allocator)},
				context.temp_allocator,
			),
			"en-US" if lang == "en" else "",
		}
		for t in tries {
			for h in have {
				if t != "" && h == t {
					append_unique(out, h)
					return
				}
			}
		}
		for h in have {
			if strings.has_prefix(h, lang) && len(h) > len(lang) && h[len(lang)] == '-' {
				append_unique(out, h)
				return
			}
		}
	}
	append_unique :: proc(out: ^[dynamic]string, s: string) {
		for o in out {
			if o == s {
				return
			}
		}
		append(out, s)
	}
	// "de_DE.UTF-8@euro": the language and the country.
	l := locale
	if i := strings.index_any(l, ".@"); i >= 0 {
		l = l[:i]
	}
	lang, country := l, ""
	if i := strings.index_any(l, "_-"); i >= 0 {
		lang, country = l[:i], l[i + 1:]
		if j := strings.index_any(country, "_-"); j >= 0 {
			country = country[j + 1:] // "sr-Latn-RS": the country is last
		}
	}
	lang = strings.to_lower(lang, context.temp_allocator)
	if lang == "c" || lang == "posix" {
		lang = ""
	}
	pick(&out, have, lang, strings.to_upper(country, context.temp_allocator))
	if lang != "en" || len(out) == 0 {
		pick(&out, have, "en", "")
	}
	return out[:]
}

// code_ranges are the parts of `text` that are code, as markdown has them:
// blocks between ``` lines (to the end of the text when one isn't closed), and
// inline spans between runs of the same number of backticks, both with their
// backticks.
code_ranges :: proc(text: string, allocator := context.temp_allocator) -> [][2]int {
	out := make([dynamic][2]int, allocator)
	block_start := -1
	at := 0
	for at < len(text) {
		end := strings.index_byte(text[at:], '\n')
		end = len(text) if end < 0 else at + end
		line := text[at:end]
		if strings.has_prefix(strings.trim_left(line, " "), "```") {
			if block_start < 0 {
				block_start = at
			} else {
				append(&out, [2]int{block_start, end})
				block_start = -1
			}
		} else if block_start < 0 {
			code_spans(text, at, end, &out)
		}
		at = end + 1
	}
	if block_start >= 0 {
		append(&out, [2]int{block_start, len(text)})
	}
	return out[:]
}

// code_spans adds the inline code spans in text[start:end] to `out`.
@(private = "file")
code_spans :: proc(text: string, start, end: int, out: ^[dynamic][2]int) {
	run :: proc(text: string, i, end: int) -> int {
		n := 0
		for i + n < end && text[i + n] == '`' {
			n += 1
		}
		return n
	}
	i := start
	for i < end {
		if text[i] != '`' {
			i += 1
			continue
		}
		n := run(text, i, end)
		// The closing run: the same number of backticks.
		j := i + n
		closed := -1
		for j < end {
			if text[j] != '`' {
				j += 1
				continue
			}
			m := run(text, j, end)
			if m == n {
				closed = j + m
				break
			}
			j += m
		}
		if closed < 0 {
			i += n
			continue
		}
		append(out, [2]int{i, closed})
		i = closed
	}
}

// spell_marks are the misspelled words in `text` that aren't in code, at most
// len(marks) of them, put in `marks`. Returns how many there are.
spell_marks :: proc(sp: ^spell.Speller, text: string, marks: [][2]int) -> int {
	code := code_ranges(text)
	n := 0
	outer: for w in spell.misspelled(sp, text, context.temp_allocator) {
		for c in code {
			if w[0] < c[1] && w[1] > c[0] {
				continue outer
			}
		}
		if n == len(marks) {
			break
		}
		marks[n] = w
		n += 1
	}
	return n
}

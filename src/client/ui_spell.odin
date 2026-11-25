package client

import "core:fmt"
import "core:strings"
import mu "vendor:microui"

import "client:platform"
import "client:spell"

// Spell checking in the composer: the words that the system's spell checker
// (client:spell) doesn't know are underlined with a wavy line in the text area
// (text_area_spell). Code isn't checked: `inline code` and ``` blocks.
//
// The languages are the one the system is set to and English, of those that
// the checker has. It is opened when first needed. The user's own words are
// kept in the settings (spell_words).
//
// Right-clicking an underlined word opens a menu (spell_menu) with what it may
// have been meant to be, which replaces it, and a way to add it to the user's
// own words.

// What the UI keeps for spell checking.
UI_Spell :: struct {
	speller:    spell.Speller,
	opened:     bool,
	// Counts up when the languages or the user's words change, so text areas
	// know to check their text again.
	generation: u32,
	menu:       Spell_Menu,
}

// The menu for a misspelled word in a composer.
@(private = "file")
Spell_Menu :: struct {
	requested:   bool, // open the menu this frame
	// The composer the word is in: the page's (0, on `page`) or a thread's.
	page:        Page,
	thread:      int,
	word:        [2]int, // where the word is in the composer's text
	text:        string, // the word (owned)
	suggestions: []string, // (owned)
}

@(private = "file")
SPELL_MENU :: "spell menu"

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
			spell.speller_set_personal(&sp.speller, ui.settings.spell_words[:])
		}
		if !spell.speller_active(&sp.speller) {
			return nil
		}
		return &sp.speller
	}
}

ui_spell_destroy :: proc(ui: ^UI) {
	spell_menu_forget(&ui.spell.menu)
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

// spell_menu_open opens the menu for the misspelled word at `word` in the
// composer `c`, which was right-clicked.
spell_menu_open :: proc(ui: ^UI, c: Composer, word: [2]int) {
	sp := ui_speller(ui)
	if sp == nil || word[1] > c.len^ {
		return
	}
	m := &ui.spell.menu
	spell_menu_forget(m)
	text := string(c.buf[word[0]:word[1]])
	m^ = {
		requested   = true,
		page        = ui.page,
		thread      = c.thread,
		word        = word,
		text        = strings.clone(text),
		suggestions = spell.suggest(sp, text),
	}
}

@(private = "file")
spell_menu_forget :: proc(m: ^Spell_Menu) {
	delete(m.text)
	for s in m.suggestions {
		delete(s)
	}
	delete(m.suggestions)
	m^ = {}
}

// spell_menu shows the menu while it is open and does what is picked in it.
// Called where the page's other menus are (message_menu).
spell_menu :: proc(ui: ^UI) {
	ctx := &ui.ctx
	m := &ui.spell.menu
	if m.requested {
		m.requested = false
		mu.open_popup(ctx, SPELL_MENU)
	}
	if cnt := mu.get_container(ctx, SPELL_MENU, {.CLOSED}); cnt != nil && cnt.open {
		w, h := i32(ui.metrics.logical_w), i32(ui.metrics.logical_h)
		cnt.rect.x = clamp(cnt.rect.x, 0, max(w - cnt.rect.w, 0))
		cnt.rect.y = clamp(cnt.rect.y, 0, max(h - cnt.rect.h, 0))
	}
	if !begin_popup(ui, SPELL_MENU) {
		return
	}
	defer mu.end_popup(ctx)
	close :: proc(ctx: ^mu.Context) {
		mu.get_current_container(ctx).open = false
	}

	// The word has to be where it was: the composer may be gone, or its text
	// may have changed since.
	c, ok := spell_menu_composer(ui)
	if !ok || m.word[1] > c.len^ || string(c.buf[m.word[0]:m.word[1]]) != m.text {
		close(ctx)
		return
	}

	width := i32(160)
	for s in m.suggestions {
		width = max(width, ctx.text_width(ctx.style.font, s) + 4 * ctx.style.padding)
	}
	mu.layout_row(ctx, {width})
	if len(m.suggestions) == 0 {
		dim_label(ctx, "No suggestions")
	}
	for s, i in m.suggestions {
		if .SUBMIT in stable_button(ctx, fmt.tprintf("suggestion %d", i), s) {
			spell_replace(ui, c, m.word, s)
			close(ctx)
			return
		}
	}
	if .SUBMIT in stable_button(ctx, "add", "Add to dictionary") {
		spell_add_word(ui, m.text)
		close(ctx)
	}
}

// spell_menu_composer is the composer the menu's word is in, if it is still there.
@(private = "file")
spell_menu_composer :: proc(ui: ^UI) -> (Composer, bool) {
	m := &ui.spell.menu
	if m.thread > 0 {
		if m.thread > len(ui.threads) || ui.threads[m.thread - 1].key == {} {
			return {}, false
		}
	} else if ui.page != m.page {
		return {}, false
	}
	c := composer_of(ui, m.thread)
	return c, c.buf != nil && c.len != nil
}

// spell_replace puts `with` in the place of the word at `word` in the
// composer `c`, and the caret after it, when it fits.
spell_replace :: proc(ui: ^UI, c: Composer, word: [2]int, with: string) {
	n := c.len^ - (word[1] - word[0]) + len(with)
	if n > len(c.buf) {
		return
	}
	copy(c.buf[word[0] + len(with):], c.buf[word[1]:c.len^])
	copy(c.buf[word[0]:], with)
	c.len^ = n
	focus_composer(ui, c, word[0] + len(with))
}

// spell_add_word adds `word` to the user's own words, which the spell checker
// takes as right from now on.
spell_add_word :: proc(ui: ^UI, word: string) {
	for w in ui.settings.spell_words {
		if w == word {
			return
		}
	}
	append(&ui.settings.spell_words, strings.clone(word))
	ui.settings_dirty = true
	spell.speller_set_personal(&ui.spell.speller, ui.settings.spell_words[:])
	ui.spell.generation += 1
}

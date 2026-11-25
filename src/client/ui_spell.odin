package client

import "core:fmt"
import "core:slice"
import "core:strings"
import mu "vendor:microui"

import "client:platform"
import "client:spell"

// Spell checking in the composer: the words that the system's spell checker
// (client:spell) doesn't know are underlined with a wavy line in the text area
// (text_area_spell). Code isn't checked: `inline code` and ``` blocks.
//
// It is set up in the settings' Spelling category (spell_settings): whether it
// is on, the languages (until some are picked, the one the system is set to
// and English, of those that the checker has) and the user's own words. The
// checker is opened when first needed, and again when they change.
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
	// The languages the checker has, for the settings: listed when the
	// Spelling category is first shown (owned).
	languages:  []string,
	listed:     bool,
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

// ui_speller is the UI's speller, opened with the languages of the settings
// the first time and after they change (spell_settings_changed). Nil when
// spell checking is off or nothing can be checked here (the web, no checker,
// no languages).
ui_speller :: proc(ui: ^UI) -> ^spell.Speller {
	when platform.WEB {
		return nil
	} else {
		if !ui.settings.spell_check {
			return nil
		}
		sp := &ui.spell
		if !sp.opened {
			sp.opened = true
			sp.generation += 1
			spell.speller_set_languages(&sp.speller, spell_chosen_languages(ui))
			spell.speller_set_personal(&sp.speller, ui.settings.spell_words[:])
		}
		if !spell.speller_active(&sp.speller) {
			return nil
		}
		return &sp.speller
	}
}

// spell_chosen_languages are the languages to check: the ones picked in the
// settings, or until some are, the default ones (spell_default_languages).
spell_chosen_languages :: proc(ui: ^UI) -> []string {
	if ui.settings.spell_languages_picked {
		return ui.settings.spell_languages[:]
	}
	return spell_default_languages(
		spell.languages(nil, context.temp_allocator),
		platform.locale_name(),
	)
}

// spell_settings_changed makes the checker take up the settings again, and
// text areas check their text again.
spell_settings_changed :: proc(ui: ^UI) {
	ui.spell.opened = false
	ui.spell.generation += 1
	ui_redraw(ui)
}

ui_spell_destroy :: proc(ui: ^UI) {
	spell_menu_forget(&ui.spell.menu)
	spell_languages_forget(&ui.spell)
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

@(private = "file")
spell_languages_forget :: proc(sp: ^UI_Spell) {
	for l in sp.languages {
		delete(l)
	}
	delete(sp.languages)
	sp.languages, sp.listed = nil, false
}

// spell_settings_opened is called when the Spelling category is opened: the
// languages are listed again, as some may have been installed since.
spell_settings_opened :: proc(ui: ^UI) {
	spell_languages_forget(&ui.spell)
}

// spell_settings is the settings' Spelling category: whether spelling is
// checked, the languages to check against, and the user's own words.
spell_settings :: proc(ui: ^UI) {
	ctx := &ui.ctx
	sp := &ui.spell
	if !sp.listed {
		sp.listed = true
		sp.languages = spell.languages()
		// By the names they are shown with, those without one last.
		slice.sort_by(sp.languages, proc(a, b: string) -> bool {
			na, nb := spell_language_name(a), spell_language_name(b)
			if (na == "") != (nb == "") {
				return nb == ""
			}
			return na < nb if na != nb else a < b
		})
	}
	mu.layout_row(ctx, {-1})
	if .CHANGE in
	   checkbox(ctx, "Enable spell checking for message composer", &ui.settings.spell_check) {
		save_settings(ui)
		spell_settings_changed(ui)
	}
	if !spell.available() {
		// Only Hunspell can be missing (Linux and the BSDs).
		mu.layout_row(ctx, {-1})
		with_text_color(
			ctx,
			theme.warning,
			"Spell checking needs Hunspell, which isn't installed. Install your system's Hunspell library (libhunspell) and the dictionaries for your languages (hunspell-en-us, hunspell-de-de, ...), then restart yap.",
			wrap_text,
		)
		return
	}

	spell_words_settings(ui)
	spell_language_settings(ui)
}

// spell_words_settings lists the user's own words, which can be removed.
@(private = "file")
spell_words_settings :: proc(ui: ^UI) {
	ctx := &ui.ctx
	sp := &ui.spell
	section_label(ui, "Custom dictionary")
	words := &ui.settings.spell_words
	if len(words) == 0 {
		mu.layout_row(ctx, {-1})
		section_label(
			ui,
			"None yet. Right-click an underlined word in a message and pick \"Add to dictionary\".",
		)
		return
	}
	remove := -1
	for w, i in words {
		mu.push_id(ctx, uintptr(i))
		defer mu.pop_id(ctx)
		mu.layout_row(ctx, {-(80 + ctx.style.spacing), -1})
		mu.label(ctx, w)
		if .SUBMIT in stable_button(ctx, "remove", "Remove") {
			remove = i
		}
	}
	// Done after the loop, which the list is shown by.
	if remove >= 0 {
		delete(words[remove])
		ordered_remove(words, remove)
		save_settings(ui)
		spell.speller_set_personal(&sp.speller, words[:])
		spell_settings_changed(ui)
	}
}

// spell_language_settings lists the languages that the system's checker has,
// each with whether it is checked against.
@(private = "file")
spell_language_settings :: proc(ui: ^UI) {
	ctx := &ui.ctx
	sp := &ui.spell
	// Where they come from, and how several are checked.
	when ODIN_OS == .Windows {
		WHERE :: "the windows spell checker"
	} else when ODIN_OS == .Darwin {
		WHERE :: "the macOS spell checker"
	} else {
		WHERE :: "Hunspell"
	}

	section_label(ui, "Languages (using " + WHERE + ")")

	if len(sp.languages) == 0 {
		mu.layout_row(ctx, {-1})
		with_text_color(ctx, theme.warning, "No languages were found.", wrap_text)
	}
	when ODIN_OS == .Windows {
		mu.layout_row(ctx, {200})
		if .SUBMIT in stable_button(ctx, "windows languages", "Open Windows language settings") {
			platform.open_language_settings()
		}
	}
	chosen := spell_chosen_languages(ui)
	for tag, i in sp.languages {
		mu.push_id(ctx, uintptr(i))
		defer mu.pop_id(ctx)
		on := slice.contains(chosen, tag)
		name := spell_language_name(tag)
		label := tag if name == "" else fmt.tprintf("%s (%s)", name, tag)
		mu.layout_row(ctx, {-1})
		if .CHANGE in checkbox(ctx, label, &on) {
			spell_pick_language(ui, chosen, tag, on)
		}
	}
}

// spell_pick_language checks against `tag` (`on`) or not any more. The
// languages are picked from then on, starting from the ones that were
// checked (`chosen`, which may be the default ones).
@(private = "file")
spell_pick_language :: proc(ui: ^UI, chosen: []string, tag: string, on: bool) {
	picked := make([dynamic]string)
	for c in chosen {
		if c != tag {
			append(&picked, strings.clone(c))
		}
	}
	if on {
		append(&picked, strings.clone(tag))
	}
	s := &ui.settings
	for l in s.spell_languages {
		delete(l)
	}
	delete(s.spell_languages)
	s.spell_languages = picked
	s.spell_languages_picked = true
	save_settings(ui)
	spell_settings_changed(ui)
}

// spell_language_name is the name of the language `tag` ("de-AT") in English
// ("German (Austria)"), or "" when it isn't known.
spell_language_name :: proc(tag: string) -> string {
	parts := strings.split(tag, "-", context.temp_allocator)
	lang := ""
	for l in LANGUAGE_NAMES {
		if l[0] == strings.to_lower(parts[0], context.temp_allocator) {
			lang = l[1]
			break
		}
	}
	if lang == "" {
		return ""
	}
	if len(parts) == 1 {
		return lang
	}
	rest := make([dynamic]string, context.temp_allocator)
	for p in parts[1:] {
		name := p
		for r in REGION_NAMES {
			if r[0] == p {
				name = r[1]
				break
			}
		}
		append(&rest, name)
	}
	return fmt.tprintf("%s (%s)", lang, strings.join(rest[:], ", ", context.temp_allocator))
}

@(private = "file")
LANGUAGE_NAMES := [?][2]string {
	{"af", "Afrikaans"},
	{"ar", "Arabic"},
	{"ars", "Najdi Arabic"},
	{"be", "Belarusian"},
	{"bg", "Bulgarian"},
	{"br", "Breton"},
	{"ca", "Catalan"},
	{"cs", "Czech"},
	{"cy", "Welsh"},
	{"da", "Danish"},
	{"de", "German"},
	{"el", "Greek"},
	{"en", "English"},
	{"eo", "Esperanto"},
	{"es", "Spanish"},
	{"et", "Estonian"},
	{"eu", "Basque"},
	{"fa", "Persian"},
	{"fi", "Finnish"},
	{"fo", "Faroese"},
	{"fr", "French"},
	{"fy", "Western Frisian"},
	{"ga", "Irish"},
	{"gd", "Scottish Gaelic"},
	{"gl", "Galician"},
	{"he", "Hebrew"},
	{"hi", "Hindi"},
	{"hr", "Croatian"},
	{"hu", "Hungarian"},
	{"hy", "Armenian"},
	{"id", "Indonesian"},
	{"is", "Icelandic"},
	{"it", "Italian"},
	{"ja", "Japanese"},
	{"ka", "Georgian"},
	{"ko", "Korean"},
	{"la", "Latin"},
	{"lb", "Luxembourgish"},
	{"lt", "Lithuanian"},
	{"lv", "Latvian"},
	{"mk", "Macedonian"},
	{"mn", "Mongolian"},
	{"ms", "Malay"},
	{"nb", "Norwegian Bokmål"},
	{"nds", "Low German"},
	{"ne", "Nepali"},
	{"nl", "Dutch"},
	{"nn", "Norwegian Nynorsk"},
	{"no", "Norwegian"},
	{"oc", "Occitan"},
	{"pa", "Punjabi"},
	{"pl", "Polish"},
	{"pt", "Portuguese"},
	{"ro", "Romanian"},
	{"ru", "Russian"},
	{"rw", "Kinyarwanda"},
	{"sk", "Slovak"},
	{"sl", "Slovenian"},
	{"sr", "Serbian"},
	{"sv", "Swedish"},
	{"te", "Telugu"},
	{"th", "Thai"},
	{"tk", "Turkmen"},
	{"tr", "Turkish"},
	{"uk", "Ukrainian"},
	{"vi", "Vietnamese"},
	{"zh", "Chinese"},
}

// Countries and regions, the scripts a tag can name, and the variants
// dictionaries are named with.
@(private = "file")
REGION_NAMES := [?][2]string {
	{"029", "Caribbean"},
	{"419", "Latin America"},
	{"AR", "Argentina"},
	{"AT", "Austria"},
	{"AU", "Australia"},
	{"BE", "Belgium"},
	{"BO", "Bolivia"},
	{"BR", "Brazil"},
	{"BZ", "Belize"},
	{"CA", "Canada"},
	{"CH", "Switzerland"},
	{"CL", "Chile"},
	{"CO", "Colombia"},
	{"CR", "Costa Rica"},
	{"CU", "Cuba"},
	{"DE", "Germany"},
	{"DK", "Denmark"},
	{"DO", "Dominican Republic"},
	{"EC", "Ecuador"},
	{"ES", "Spain"},
	{"FI", "Finland"},
	{"FR", "France"},
	{"GB", "United Kingdom"},
	{"GT", "Guatemala"},
	{"HK", "Hong Kong"},
	{"HN", "Honduras"},
	{"ID", "Indonesia"},
	{"IE", "Ireland"},
	{"IN", "India"},
	{"IT", "Italy"},
	{"JM", "Jamaica"},
	{"JP", "Japan"},
	{"LI", "Liechtenstein"},
	{"LU", "Luxembourg"},
	{"MX", "Mexico"},
	{"MY", "Malaysia"},
	{"NI", "Nicaragua"},
	{"NL", "Netherlands"},
	{"NZ", "New Zealand"},
	{"PA", "Panama"},
	{"PE", "Peru"},
	{"PH", "Philippines"},
	{"PR", "Puerto Rico"},
	{"PT", "Portugal"},
	{"PY", "Paraguay"},
	{"SE", "Sweden"},
	{"SG", "Singapore"},
	{"SV", "El Salvador"},
	{"TT", "Trinidad and Tobago"},
	{"US", "United States"},
	{"UY", "Uruguay"},
	{"VE", "Venezuela"},
	{"ZA", "South Africa"},
	{"ZW", "Zimbabwe"},
	{"Latn", "Latin script"},
	{"Cyrl", "Cyrillic script"},
	{"polyton", "polytonic"},
	{"valencia", "Valencian"},
	{"frami", "with Swiss and Austrian spellings"},
}

#+build !wasi
#+build !js
package spell

import "core:log"
import "core:slice"
import "core:testing"

@(private = "file")
words_of :: proc(text: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	at := 0
	for {
		start, end, ok := next_word(text, at)
		if !ok {
			break
		}
		append(&out, text[start:end])
		at = end
	}
	return out[:]
}

@(test)
test_next_word :: proc(t: ^testing.T) {
	cases := [?]struct {
		text:  string,
		words: []string,
	} {
		{"", {}},
		{"Hello, world!", {"Hello", "world"}},
		{"don't l'eau rock'n'roll", {"don't", "l'eau", "rock'n'roll"}},
		{"it’s", {"it’s"}},
		// Apostrophes at the ends aren't the word's.
		{"'quoted' dogs'", {"quoted", "dogs"}},
		{"e-mail", {"e", "mail"}},
		{"grüße Straße", {"grüße", "Straße"}},
		// Digits, underscores, acronyms, camelCase.
		{"abc1 snake_case NASA iPhone camelCase A I", {"A", "I"}},
		{"Hello NASA there", {"Hello", "there"}},
		// Mentions, channels, emoji.
		{"hi @alice in #general :smile: ok", {"hi", "in", "ok"}},
		{"time: 5", {"time"}},
		// Addresses, whole.
		{"see https://example.com/some/path ok", {"see", "ok"}},
		{"www.example.org and me@example.org", {"and"}},
		{"(https://x.org/a)", {}},
	}
	for c in cases {
		got := words_of(c.text)
		testing.expectf(t, slice.equal(got, c.words), "%q: %v, not %v", c.text, got, c.words)
	}
}

@(test)
test_personal :: proc(t: ^testing.T) {
	s: Speller
	defer speller_destroy(&s)
	speller_set_personal(&s, {"yap", "Odin"})
	testing.expect(t, in_personal(&s, "yap"))
	testing.expect(t, in_personal(&s, "Yap")) // at the start of a sentence
	testing.expect(t, in_personal(&s, "Odin"))
	testing.expect(t, !in_personal(&s, "odin"))
	testing.expect(t, !in_personal(&s, "YAP"))
	// Without languages, nothing is wrong.
	testing.expect(t, check_word(&s, "qwxzv"))
	testing.expect(t, len(misspelled(&s, "qwxzv", context.temp_allocator)) == 0)
}

// The system's own checker, when it has English: run where there is one.
@(test)
test_system_checker :: proc(t: ^testing.T) {
	langs := languages(nil, context.temp_allocator)
	tag := ""
	for l in ([]string{"en-US", "en-GB", "en"}) {
		if slice.contains(langs, l) {
			tag = l
			break
		}
	}
	if tag == "" {
		log.infof("no English to check against here (%v)", langs)
		return
	}
	s: Speller
	defer speller_destroy(&s)
	testing.expect(t, speller_set_languages(&s, {tag}) == 1)
	testing.expect(t, check_word(&s, "house"))
	testing.expect(t, !check_word(&s, "hosue"))
	bad := misspelled(&s, "The hosue is red, @bob.", context.temp_allocator)
	testing.expectf(t, slice.equal(bad, [][2]int{{4, 9}}), "%v", bad)
	sug := suggest(&s, "hosue", context.temp_allocator)
	testing.expectf(t, slice.contains(sug, "house"), "%v", sug)
	speller_set_personal(&s, {"hosue"})
	testing.expect(t, check_word(&s, "hosue"))
}

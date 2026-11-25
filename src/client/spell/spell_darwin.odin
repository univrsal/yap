#+build darwin
package spell

import "base:intrinsics"
import "core:strings"
import NS "core:sys/darwin/Foundation"

// macOS' own spell checker, NSSpellChecker, which knows a good many languages
// without anything installed. It names them with an underscore ("en_GB"), and
// is only used from the main thread.

// The language as the checker names it.
Handle :: ^NS.String

@(private = "file", objc_class = "NSSpellChecker")
Spell_Checker :: struct {
	using _: NS.Object,
}

@(private = "file")
checker :: proc() -> ^Spell_Checker {
	return intrinsics.objc_send(^Spell_Checker, Spell_Checker, "sharedSpellChecker")
}

@(private = "file")
ns_string :: proc(s: string) -> ^NS.String {
	return NS.String.alloc()->initWithOdinString(s)
}

@(private = "file")
take_strings :: proc(a: ^NS.Array, allocator := context.allocator) -> []string {
	if a == nil {
		return nil
	}
	out := make([]string, a->count(), allocator)
	for i in 0 ..< len(out) {
		out[i] = strings.clone(a->objectAs(NS.UInteger(i), ^NS.String)->odinString(), allocator)
	}
	return out
}

@(private)
backend_available :: proc() -> bool {
	return checker() != nil
}

@(private)
backend_languages :: proc(dirs: []string, allocator := context.allocator) -> []string {
	NS.scoped_autoreleasepool()
	sc := checker()
	if sc == nil {
		return nil
	}
	tags := take_strings(intrinsics.objc_send(^NS.Array, sc, "availableLanguages"), allocator)
	for &t in tags {
		n := strings.clone(normalize_tag(t), allocator)
		delete(t, allocator)
		t = n
	}
	return tags
}

@(private)
backend_open :: proc(tag: string, dirs: []string) -> (h: Handle, ok: bool) {
	if checker() == nil {
		return nil, false
	}
	mac, _ := strings.replace_all(tag, "-", "_", context.temp_allocator)
	return ns_string(mac), true
}

@(private)
backend_close :: proc(h: Handle) {
	h->release()
}

@(private)
backend_check :: proc(h: Handle, word: string) -> bool {
	NS.scoped_autoreleasepool()
	w := ns_string(word)
	defer w->release()
	r := intrinsics.objc_send(
		NS.Range,
		checker(),
		"checkSpellingOfString:startingAt:language:wrap:inSpellDocumentWithTag:wordCount:",
		w,
		NS.Integer(0),
		h,
		NS.BOOL(false),
		NS.Integer(0),
		(^NS.Integer)(nil),
	)
	return r.location == NS.UInteger(NS.NotFound) || r.length == 0
}

@(private)
backend_suggest :: proc(h: Handle, word: string, allocator := context.allocator) -> []string {
	NS.scoped_autoreleasepool()
	w := ns_string(word)
	defer w->release()
	guesses := intrinsics.objc_send(
		^NS.Array,
		checker(),
		"guessesForWordRange:inString:language:inSpellDocumentWithTag:",
		NS.Range{0, w->length()},
		w,
		h,
		NS.Integer(0),
	)
	return take_strings(guesses, allocator)
}

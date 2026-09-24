package client

import log "../common/wlog"
import "core:strings"
import "core:unicode"

/*
Links in chat messages: http(s):// URLs and bare www. addresses. The text
shown is always the URL itself, so what you click is what opens.
*/

Link :: struct {
	start, end: int, // byte range in the text
}

@(private = "file")
LINK_PREFIXES := [?]string{"https://", "http://", "www."}

// find_links returns the links in `text`, in order.
find_links :: proc(text: string, allocator := context.temp_allocator) -> []Link {
	links := make([dynamic]Link, allocator)
	i := 0
	outer: for i < len(text) {
		// Only at the start of a word, so "xhttp://" isn't a link.
		if i > 0 && is_word_byte(text[i - 1]) {
			i += 1
			continue
		}
		for prefix in LINK_PREFIXES {
			if len(text) - i <= len(prefix) || !strings.equal_fold(text[i:][:len(prefix)], prefix) {
				continue
			}
			end := link_end(text, i)
			if end - i > len(prefix) {
				append(&links, Link{i, end})
				i = end
				continue outer
			}
		}
		i += 1
	}
	return links[:]
}

// link_url is the address to open for a link.
link_url :: proc(text: string, l: Link, allocator := context.temp_allocator) -> string {
	s := text[l.start:l.end]
	if len(s) >= 4 && strings.equal_fold(s[:4], "www.") {
		return strings.concatenate({"https://", s}, allocator)
	}
	return strings.clone(s, allocator)
}

// link_end finds where a link starting at `start` ends: at whitespace or
// a character that can't be in a URL, minus trailing punctuation that is
// more likely the sentence's ("see https://example.com.") and closing
// brackets without a matching opening one ("(https://example.com)").
@(private = "file")
link_end :: proc(text: string, start: int) -> int {
	end := len(text)
	for r, i in text[start:] {
		if unicode.is_space(r) || unicode.is_control(r) || strings.contains_rune(`<>"{}|\^`, r) {
			end = start + i
			break
		}
	}
	for end > start {
		s := text[start:end]
		last := s[len(s) - 1]
		switch last {
		case '.', ',', ';', ':', '!', '?', '\'', '*':
			end -= 1
			continue
		case ')':
			if strings.count(s, "(") < strings.count(s, ")") {
				end -= 1
				continue
			}
		case ']':
			if strings.count(s, "[") < strings.count(s, "]") {
				end -= 1
				continue
			}
		}
		break
	}
	return end
}

@(private = "file")
is_word_byte :: proc(b: u8) -> bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || b == '_' || b >= 0x80
}

// open_url opens a web address in the default browser. Anything but
// http(s) is refused, so a message can't make us run other handlers.
open_url :: proc(url: string) {
	lower := strings.to_lower(url, context.temp_allocator)
	if !strings.has_prefix(lower, "https://") && !strings.has_prefix(lower, "http://") {
		log.warnf("not opening %q: only http and https links are opened", url)
		return
	}
	for r in url {
		if unicode.is_space(r) || unicode.is_control(r) {
			log.warnf("not opening %q: it contains spaces or control characters", url)
			return
		}
	}
	log.infof("opening %s", url)
	if !platform_open_url(url) {
		log.errorf("could not open %s in the browser", url)
	}
}

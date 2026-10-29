package mattermost

import "core:fmt"
import "core:slice"
import "core:strings"

// The text of a message (docs/design/mattermost-import.md, step 9): what
// Mattermost's messages say about people, channels and emoji, written as yap
// writes it.
//
//	@bob         <@17>, the account's token (proto/mentions.odin)
//	@channel     <@everyone>, and so does @all
//	@here        <@here>
//	~secret      #Secret, the channel's name as a person reads it: yap has no
//	             link to a channel
//	:thumbsup:   the emoji character; :partyparrot: stays :partyparrot: (under
//	             the name it got in yap), and a skin tone is left off
//
// Names that aren't known (a group, a person or channel that wasn't imported,
// an emoji that isn't there) are left as they were typed. Nothing in code is
// touched, neither in a block (a line that starts with ``` or ~~~ to the next
// one) nor in a span between backticks.

// Rewriter is what the rules need to know.
Rewriter :: struct {
	users:    map[string]u32, // lower-case Mattermost username -> the account in yap
	channels: map[string]string, // Mattermost's name of a channel -> its name in yap
	emoji:    ^Emoji_Map,
}

// Rewritten is a message's text as written for yap, with what it mentions.
Rewritten :: struct {
	text:     string,
	accounts: [dynamic]u32, // the people mentioned by name, each once
	everyone: bool, // @channel or @all
	here:     bool, // @here
}

// rewrite_text rewrites `text`. Its result is allocated with `allocator`.
rewrite_text :: proc(
	r: ^Rewriter,
	text: string,
	allocator := context.temp_allocator,
) -> (
	out: Rewritten,
) {
	b: strings.Builder
	strings.builder_init(&b, 0, len(text) + 16, allocator)
	out.accounts.allocator = allocator
	i := 0
	line_start := true
	fence: u8 // the character of the code block that is open, or 0
	for i < len(text) {
		if line_start {
			line_start = false
			if marker, is_fence := fence_at(text, i); is_fence {
				switch {
				case fence == 0:
					fence = marker
				case fence == marker:
					fence = 0
				}
				i = copy_line(&b, text, i)
				line_start = true
				continue
			}
			if fence != 0 {
				i = copy_line(&b, text, i)
				line_start = true
				continue
			}
		}
		c := text[i]
		switch c {
		case '\n':
			strings.write_byte(&b, c)
			i += 1
			line_start = true
			continue
		case '`':
			i = copy_code_span(&b, text, i)
			continue
		case '@':
			if n := rewrite_mention(r, &b, &out, text, i); n > 0 {
				i += n
				continue
			}
		case '~':
			if n := rewrite_channel(r, &b, text, i); n > 0 {
				i += n
				continue
			}
		case ':':
			if n := rewrite_emoji(r, &b, text, i); n > 0 {
				i += n
				continue
			}
		}
		strings.write_byte(&b, c)
		i += 1
	}
	out.text = strings.to_string(b)
	return
}

// fence_at says whether the line at `i` starts a code block's fence: three or
// more backticks or tildes, after at most three spaces.
@(private = "file")
fence_at :: proc(text: string, i: int) -> (marker: u8, ok: bool) {
	j := i
	for j < len(text) && j - i < 3 && text[j] == ' ' {
		j += 1
	}
	if j + 2 < len(text) &&
	   (text[j] == '`' || text[j] == '~') &&
	   text[j + 1] == text[j] &&
	   text[j + 2] == text[j] {
		return text[j], true
	}
	return
}

// copy_line copies the line at `i`, with its newline, and returns where the
// next begins.
@(private = "file")
copy_line :: proc(b: ^strings.Builder, text: string, i: int) -> int {
	end := strings.index_byte(text[i:], '\n')
	end = len(text) if end < 0 else i + end + 1
	strings.write_string(b, text[i:end])
	return end
}

// copy_code_span copies a span between backticks, if it is closed by as many
// again, as it is, and otherwise only the backticks that start it. It returns
// where to go on.
@(private = "file")
copy_code_span :: proc(b: ^strings.Builder, text: string, i: int) -> int {
	n := 0
	for i + n < len(text) && text[i + n] == '`' {
		n += 1
	}
	at := i + n
	for at < len(text) {
		close := strings.index_byte(text[at:], '`')
		if close < 0 {
			break
		}
		start := at + close
		run := 0
		for start + run < len(text) && text[start + run] == '`' {
			run += 1
		}
		if run == n {
			strings.write_string(b, text[i:start + run])
			return start + run
		}
		at = start + run
	}
	strings.write_string(b, text[i:i + n])
	return i + n
}

// is_word says whether a byte is part of a word, which a mention or a link
// can't follow without a gap (an email address, a path).
@(private = "file")
is_word :: proc(c: u8) -> bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_'
}

// rewrite_mention writes what `@...` at `i` is, and returns how many bytes of
// the text it used, or 0 if it is not a mention (nothing was written then).
@(private = "file")
rewrite_mention :: proc(
	r: ^Rewriter,
	b: ^strings.Builder,
	out: ^Rewritten,
	text: string,
	i: int,
) -> int {
	if i > 0 &&
	   (is_word(text[i - 1]) ||
			   text[i - 1] == '/' ||
			   text[i - 1] == '@' ||
			   text[i - 1] == '\\' ||
			   text[i - 1] == '.') {
		return 0
	}
	end := i + 1
	for end < len(text) && (is_word(text[end]) || text[end] == '.' || text[end] == '-') {
		end += 1
	}
	// The name is the longest start of the run that is one: "@bob." ends a sentence.
	name := text[i + 1:end]
	for len(name) > 0 {
		lower := strings.to_lower(name, context.temp_allocator)
		switch lower {
		case "channel", "all":
			strings.write_string(b, "<@everyone>")
			out.everyone = true
			return 1 + len(name)
		case "here":
			strings.write_string(b, "<@here>")
			out.here = true
			return 1 + len(name)
		}
		if id, known := r.users[lower]; known {
			fmt.sbprintf(b, "<@%d>", id)
			if !slice.contains(out.accounts[:], id) {
				append(&out.accounts, id)
			}
			return 1 + len(name)
		}
		last := name[len(name) - 1]
		if last != '.' && last != '-' && last != '_' {
			break
		}
		name = name[:len(name) - 1]
	}
	return 0
}

// rewrite_channel writes what `~name` at `i` is: `#` and the channel's name in
// yap. It returns how many bytes it used, or 0.
@(private = "file")
rewrite_channel :: proc(r: ^Rewriter, b: ^strings.Builder, text: string, i: int) -> int {
	if i > 0 &&
	   (is_word(text[i - 1]) || text[i - 1] == '~' || text[i - 1] == '/' || text[i - 1] == '\\') {
		return 0
	}
	if i + 1 >= len(text) || text[i + 1] == '~' {
		return 0 // ~~struck~~
	}
	end := i + 1
	for end < len(text) && (is_word(text[end]) || text[end] == '-') {
		end += 1
	}
	name := text[i + 1:end]
	for len(name) > 0 {
		if yap_name, known := r.channels[strings.to_lower(name, context.temp_allocator)]; known {
			strings.write_byte(b, '#')
			strings.write_string(b, yap_name)
			return 1 + len(name)
		}
		last := name[len(name) - 1]
		if last != '-' && last != '_' {
			break
		}
		name = name[:len(name) - 1]
	}
	return 0
}

// rewrite_emoji writes what `:name:` at `i` is, if it is an emoji. It returns
// how many bytes it used, or 0.
@(private = "file")
rewrite_emoji :: proc(r: ^Rewriter, b: ^strings.Builder, text: string, i: int) -> int {
	if r.emoji == nil || i > 0 && is_word(text[i - 1]) {
		return 0
	}
	end := i + 1
	for end < len(text) && (is_word(text[end]) || text[end] == '+' || text[end] == '-') {
		end += 1
	}
	// Closed by a colon that isn't followed by more of a word ("12:30:45").
	if end >= len(text) || text[end] != ':' || end - i - 1 < 2 {
		return 0
	}
	if end + 1 < len(text) && is_word(text[end + 1]) {
		return 0
	}
	name := text[i + 1:end]
	emoji, result := map_reaction(r.emoji, name, context.temp_allocator)
	if result == .Unknown {
		return 0
	}
	strings.write_string(b, emoji)
	return end + 1 - i
}

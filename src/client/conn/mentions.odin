package conn

import "core:strings"

import "common:proto"

/*
Mentions as people see them (src/common/proto/mentions.odin has the
tokens). What's typed and what's stored differ, and these are the only
procedures that go between them:

	typed / edited   @alice        mentions_encode     stored   <@17>
	stored           <@17>         mentions_for_edit   edited   @alice
	stored           <@17>         mentions_display    shown    @Alice

A mention is typed as `@username`, at the start of a word. Usernames are
letters, digits and `_ . -`, so `@alice.` could be "alice" and a full
stop: the longest username the word starts with is the one meant.
`@everyone` becomes <@everyone> whoever types it; the server decides
whether it counts.

Shown, a mention is the account's display name as it is now, so a
rename changes how old mentions read; one for an account that isn't
known reads `@unknown`.

The procedures take any map of accounts whose values have `username`
and `display`: the directory's (Dir_Account) or the View's.
*/

// Mention_Span is where a mention is in shown text, and whether it's
// the reader.
Mention_Span :: struct {
	start, end: int,
	me:         bool,
}

@(private = "file")
username_byte :: proc(ch: u8) -> bool {
	switch ch {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', '.', '-':
		return true
	}
	return false
}

// username_lookup is the account whose username is `name`, whatever its
// case; 0 if there's none.
@(private = "file")
username_lookup :: proc(accounts: map[proto.Account_Id]$T, name: string) -> proto.Account_Id {
	for id, acc in accounts {
		if strings.equal_fold(acc.username, name) {
			return id
		}
	}
	return 0
}

/*
mentions_encode turns what was typed into what's stored: each `@username`
starting a word becomes the account's token. Anything else stays. The
result is in the temp allocator.
*/
mentions_encode :: proc(text: string, accounts: map[proto.Account_Id]$T) -> string {
	if strings.index_byte(text, '@') < 0 {
		return text
	}
	b := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(text) {
		ch := text[i]
		if ch != '@' || (i > 0 && !strings.is_space(rune(text[i - 1]))) {
			strings.write_byte(&b, ch)
			i += 1
			continue
		}
		word := i + 1
		for word < len(text) && username_byte(text[word]) {
			word += 1
		}
		// The longest username the word starts with.
		matched := 0
		account: proto.Account_Id
		everyone := false
		for end := word; end > i + 1; end -= 1 {
			name := text[i + 1:end]
			if name == proto.MENTION_EVERYONE {
				matched, everyone = end, true
				break
			}
			if id := username_lookup(accounts, name); id != 0 {
				matched, account = end, id
				break
			}
		}
		if matched == 0 {
			strings.write_byte(&b, ch)
			i += 1
			continue
		}
		strings.write_string(&b, proto.mention_token(0 if everyone else account))
		i = matched
	}
	return strings.to_string(b)
}

/*
mentions_for_edit turns a stored message back into what's typed, to be
edited: tokens become `@username`. One for an account that isn't known
stays a token, and is sent back as it was. In the temp allocator.
*/
mentions_for_edit :: proc(text: string, accounts: map[proto.Account_Id]$T) -> string {
	b := strings.builder_make(context.temp_allocator)
	at := 0
	for {
		m, ok := proto.next_mention(text, at)
		if !ok {
			break
		}
		strings.write_string(&b, text[at:m.start])
		switch {
		case m.everyone:
			strings.write_string(&b, "@" + proto.MENTION_EVERYONE)
		case m.account in accounts:
			strings.write_byte(&b, '@')
			strings.write_string(&b, accounts[m.account].username)
		case:
			strings.write_string(&b, text[m.start:m.end])
		}
		at = m.end
	}
	strings.write_string(&b, text[at:])
	return strings.to_string(b)
}

// Emoji_Span is where one of the server's emoji is in shown text (its
// placeholder character), and which it is: its cell in the sheet.
Emoji_Span :: struct {
	start, end: int,
	index:      int,
}

/*
mentions_display is a stored message as it's shown: tokens become
`@display name`, and where each is, and whether it's `me` (<@everyone>
is everyone's), is in the spans. Text without tokens comes back as it
is, with no spans; anything else is in the temp allocator.
*/
mentions_display :: proc(
	text: string,
	accounts: map[proto.Account_Id]$T,
	me: proto.Account_Id,
) -> (
	shown: string,
	spans: []Mention_Span,
) {
	shown, spans, _ = text_display(text, accounts, me, nil)
	return
}

/*
text_display is mentions_display, and also puts the server's emoji
(`emoji`, its names in order) in place of their `:name:`: one
proto.CUSTOM_EMOJI_PLACEHOLDER each, with where it is and which emoji it
is in `custom`. A `:name:` that isn't one of them stays as it is.
*/
text_display :: proc(
	text: string,
	accounts: map[proto.Account_Id]$T,
	me: proto.Account_Id,
	emoji: []string,
) -> (
	shown: string,
	spans: []Mention_Span,
	custom: []Emoji_Span,
) {
	shown, spans, custom, _ = text_display_links(text, accounts, me, emoji)
	return
}

// Link_Span is where a link to a message (proto/forward.odin) is in a
// text as it's shown, and what it points at.
Link_Span :: struct {
	start, end: int,
	link:       proto.Msg_Link,
}

// A link's text, when whoever shows it has nothing better.
LINK_TEXT :: "\u21aa a message"

/*
text_display_links is text_display, with links to messages too: each
becomes `label`'s text for it (LINK_TEXT without one), and its own span.
*/
text_display_links :: proc(
	text: string,
	accounts: map[proto.Account_Id]$T,
	me: proto.Account_Id,
	emoji: []string,
	label: proc(data: rawptr, l: proto.Msg_Link) -> string = nil,
	label_data: rawptr = nil,
) -> (
	shown: string,
	spans: []Mention_Span,
	custom: []Emoji_Span,
	links: []Link_Span,
) {
	if !strings.contains(text, "<@") &&
	   !strings.contains(text, proto.LINK_PREFIX) &&
	   (len(emoji) == 0 || strings.count(text, ":") < 2) {
		return text, nil, nil, nil
	}
	b := strings.builder_make(context.temp_allocator)
	list := make([dynamic]Mention_Span, context.temp_allocator)
	icons := make([dynamic]Emoji_Span, context.temp_allocator)
	found := make([dynamic]Link_Span, context.temp_allocator)
	i := 0
	for i < len(text) {
		if strings.has_prefix(text[i:], proto.LINK_PREFIX) {
			if l, ok := proto.next_link(text, i); ok && l.start == i {
				start := strings.builder_len(b)
				strings.write_string(&b, label(label_data, l) if label != nil else LINK_TEXT)
				append(&found, Link_Span{start, strings.builder_len(b), l})
				i = l.end
				continue
			}
		}
		if strings.has_prefix(text[i:], "<@") {
			if m, ok := proto.next_mention(text, i); ok && m.start == i {
				start := strings.builder_len(b)
				strings.write_byte(&b, '@')
				switch {
				case m.everyone:
					strings.write_string(&b, proto.MENTION_EVERYONE)
				case m.account in accounts:
					strings.write_string(&b, accounts[m.account].display)
				case:
					strings.write_string(&b, "unknown")
				}
				append(
					&list,
					Mention_Span {
						start,
						strings.builder_len(b),
						m.everyone || (me != 0 && m.account == me),
					},
				)
				i = m.end
				continue
			}
		}
		if text[i] == ':' && len(emoji) > 0 {
			if end := strings.index_byte(text[i + 1:], ':'); end > 0 {
				name := text[i + 1:][:end]
				if index, known := custom_emoji_index(emoji, name); known {
					start := strings.builder_len(b)
					strings.write_rune(&b, proto.CUSTOM_EMOJI_PLACEHOLDER)
					append(&icons, Emoji_Span{start, strings.builder_len(b), index})
					i += end + 2
					continue
				}
			}
		}
		strings.write_byte(&b, text[i])
		i += 1
	}
	return strings.to_string(b), list[:], icons[:], found[:]
}

/*
emoji_encode turns what was typed into what's stored, for emoji: each
`:shortcode:` of a Unicode emoji becomes its character, unless the
server has an emoji of its own by that name (`custom`, in order), which
stays `:name:`. Anything else stays. In the temp allocator.
*/
emoji_encode :: proc(text: string, custom: []string) -> string {
	if strings.count(text, ":") < 2 {
		return text
	}
	b := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(text) {
		if text[i] == ':' {
			if end := strings.index_byte(text[i + 1:], ':'); end > 0 {
				name := text[i + 1:][:end]
				if _, theirs := custom_emoji_index(custom, name); !theirs {
					if r, ok := proto.emoji_by_shortcode(name); ok {
						strings.write_rune(&b, r)
						i += end + 2
						continue
					}
				}
			}
		}
		strings.write_byte(&b, text[i])
		i += 1
	}
	return strings.to_string(b)
}

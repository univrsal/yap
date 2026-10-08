package conn

import "core:slice"
import "core:strings"

import "common:proto"

/*
Mentions as people see them (src/common/proto/mentions.odin has the
tokens). What's typed and what's stored differ, and these are the only
procedures that go between them:

	typed / edited   @alice        mentions_encode     stored   <@17>
	stored           <@17>         mentions_for_edit   edited   @alice
	stored           <@17>         mentions_display    shown    @Alice
	typed            @Team Leads   mentions_encode     stored   <@&5>

A mention is typed as `@username`, at the start of a word. Usernames are
letters, digits and `_ . -`, so `@alice.` could be "alice" and a full
stop: the longest username the word starts with is the one meant.
`@everyone` becomes <@everyone> whoever types it; the server decides
whether it counts.

A role is mentioned by its name, which may have spaces in it: `@` and
the name, whatever its case, up to where a word ends. Only a role that's
Mentionable (role_mentionable) is. Whichever of a username and a role's
name is longer is the one meant; if they're the same, it's the account,
and the role can only be written as its token (which the completion
does, ui_completion.odin), and stays one to be edited.

Shown, a mention is the account's display name as it is now, so a
rename changes how old mentions read; one for an account that isn't
known reads `@unknown`.

The procedures take any map of accounts whose values have `username`,
`display` and `roles`: the directory's (Dir_Account) or the View's; and
the roles, the View's (or dir_roles).
*/

// Mention_Span is where a mention is in shown text, and whether it's
// the reader (or one of the reader's roles).
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

// role_mentionable is whether a role can be mentioned: not everyone's.
role_mentionable :: proc(r: View_Role) -> bool {
	return r.id != proto.EVERYONE_ROLE && .Mentionable in r.flags
}

// word_byte is whether a byte goes on with a word, so a role's name
// followed by it isn't the name.
@(private = "file")
word_byte :: proc(ch: u8) -> bool {
	switch ch {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', 0x80 ..= 0xFF:
		return true
	}
	return false
}

@(private = "file")
role_by_id :: proc(roles: []View_Role, id: proto.Role_Id) -> (View_Role, bool) {
	for r in roles {
		if r.id == id {
			return r, true
		}
	}
	return {}, false
}

// role_name_shadowed is whether `@name` would be an account's mention,
// not the role's.
role_name_shadowed :: proc(accounts: map[proto.Account_Id]$T, name: string) -> bool {
	return username_lookup(accounts, name) != 0
}

/*
mentions_encode turns what was typed into what's stored: each `@username`
starting a word becomes the account's token, and `@role name` the role's.
Anything else stays. The result is in the temp allocator.
*/
mentions_encode :: proc(
	text: string,
	accounts: map[proto.Account_Id]$T,
	roles: []View_Role,
) -> string {
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
		// Or a role's name, if that's longer; it may go past the word.
		role: proto.Role_Id
		for r in roles {
			end := i + 1 + len(r.name)
			if role_mentionable(r) &&
			   end > matched &&
			   end <= len(text) &&
			   strings.equal_fold(text[i + 1:end], r.name) &&
			   (end == len(text) || !word_byte(text[end])) {
				matched, role = end, r.id
			}
		}
		if matched == 0 {
			strings.write_byte(&b, ch)
			i += 1
			continue
		}
		if role != 0 {
			strings.write_string(&b, proto.role_mention_token(role))
		} else {
			strings.write_string(&b, proto.mention_token(0 if everyone else account))
		}
		i = matched
	}
	return strings.to_string(b)
}

/*
mentions_for_edit turns a stored message back into what's typed, to be
edited: tokens become `@username`, or `@role name`. One for an account
or a role that isn't known stays a token, and is sent back as it was;
so does a role's whose name is a username. In the temp allocator.
*/
mentions_for_edit :: proc(
	text: string,
	accounts: map[proto.Account_Id]$T,
	roles: []View_Role,
) -> string {
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
		case m.role != 0:
			r, known := role_by_id(roles, m.role)
			if known && !role_name_shadowed(accounts, r.name) {
				strings.write_byte(&b, '@')
				strings.write_string(&b, r.name)
			} else {
				strings.write_string(&b, text[m.start:m.end])
			}
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
`@display name` (a role's `@role name`), and where each is, and whether
it's `me` (<@everyone> is everyone's, a role's whoever has it), is in
the spans. Text without tokens comes back as it is, with no spans;
anything else is in the temp allocator.
*/
mentions_display :: proc(
	text: string,
	accounts: map[proto.Account_Id]$T,
	roles: []View_Role,
	me: proto.Account_Id,
) -> (
	shown: string,
	spans: []Mention_Span,
) {
	shown, spans, _ = text_display(text, accounts, roles, me, nil)
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
	roles: []View_Role,
	me: proto.Account_Id,
	emoji: []string,
) -> (
	shown: string,
	spans: []Mention_Span,
	custom: []Emoji_Span,
) {
	shown, spans, custom, _ = text_display_links(text, accounts, roles, me, emoji)
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
	roles: []View_Role,
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
				mine := m.everyone || (me != 0 && m.account == me)
				switch {
				case m.everyone:
					strings.write_string(&b, proto.MENTION_EVERYONE)
				case m.role != 0:
					r, known := role_by_id(roles, m.role)
					strings.write_string(&b, r.name if known else "unknown role")
					if me in accounts {
						mine = slice.contains(accounts[me].roles, m.role)
					}
				case m.account in accounts:
					strings.write_string(&b, accounts[m.account].display)
				case:
					strings.write_string(&b, "unknown")
				}
				append(&list, Mention_Span{start, strings.builder_len(b), mine})
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

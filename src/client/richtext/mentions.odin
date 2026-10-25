package richtext

import "core:slice"
import "core:strings"

import "common:proto"

// Mentions as people see them (src/common/proto/mentions.odin defines the
// tokens). The typed text and the stored text differ, and only the procedures
// in this file convert between them:
//
//   typed / edited   @alice        mentions_encode     stored   <@17>
//   stored           <@17>         mentions_for_edit   edited   @alice
//   stored           <@17>         mentions_display    shown    @Alice
//   typed            @Team Leads   mentions_encode     stored   <@&5>
//
// An account is mentioned by typing `@username` at the start of a word.
// Usernames consist of letters, digits and `_ . -`, so `@alice.` could mean
// "alice" followed by a full stop. The longest username that the word starts
// with is the one meant.
//
// `@everyone` becomes <@everyone> no matter who types it. The server decides
// whether it counts.
//
// A role is mentioned by its name, which may contain spaces: `@` followed by
// the name in any case, up to where a word ends. Only roles that are
// Mentionable (see role_mentionable) can be mentioned. If both a username and a
// role name match, the longer one is meant. If they are equally long, the
// account is meant, and the role can then only be written as its token (which
// the completion in ui_completion.odin does) and stays a token when edited.
//
// When shown, a mention is the account's current display name, so renaming an
// account changes how old mentions read. A mention of an unknown account reads
// `@unknown`.
//
// The procedures accept any map of accounts whose values have `username`,
// `display` and `roles` fields, such as the directory's (Dir_Account) or the
// View's. The roles are the View's (or dir_roles).

// Role is a role as the client keeps it (conn.View_Role is the same type).
Role :: struct {
	id:    proto.Role_Id,
	name:  string, // owned
	perms: proto.Permissions,
	color: u32, // proto.ROLE_COLOR_SET | 0xRRGGBB, or 0
	flags: proto.Role_Flags,
}

// Mention_Span is the position of a mention in the shown text, and whether it
// mentions the reader (or one of the reader's roles).
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

// username_lookup returns the account whose username is `name`, ignoring case.
// It returns 0 if there is no such account.
@(private = "file")
username_lookup :: proc(accounts: map[proto.Account_Id]$T, name: string) -> proto.Account_Id {
	for id, acc in accounts {
		if strings.equal_fold(acc.username, name) {
			return id
		}
	}
	return 0
}

// role_mentionable reports whether a role can be mentioned. The everyone role
// cannot.
role_mentionable :: proc(r: Role) -> bool {
	return r.id != proto.EVERYONE_ROLE && .Mentionable in r.flags
}

// word_byte reports whether a byte continues a word. A role name that is
// followed by such a byte does not count as a match.
@(private = "file")
word_byte :: proc(ch: u8) -> bool {
	switch ch {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', 0x80 ..= 0xFF:
		return true
	}
	return false
}

@(private = "file")
role_by_id :: proc(roles: []Role, id: proto.Role_Id) -> (Role, bool) {
	for r in roles {
		if r.id == id {
			return r, true
		}
	}
	return {}, false
}

// role_name_shadowed reports whether `@name` would be a mention of an account
// rather than of the role.
role_name_shadowed :: proc(accounts: map[proto.Account_Id]$T, name: string) -> bool {
	return username_lookup(accounts, name) != 0
}

// mentions_encode turns what was typed into what is stored: each `@username`
// at the start of a word becomes the account's token, and `@role name` becomes
// the role's token. Everything else stays unchanged. The result is allocated in
// the temp allocator.
mentions_encode :: proc(text: string, accounts: map[proto.Account_Id]$T, roles: []Role) -> string {
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
		// Find the longest username that the word starts with.
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
		// Or a role's name, if that is longer. It may extend past the word.
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

// mentions_for_edit turns a stored message back into the text to be edited:
// tokens become `@username` or `@role name`. A token for an unknown account or
// role stays a token and is sent back as it was, and so does the token of a role
// whose name is also a username. The result is allocated in the temp allocator.
mentions_for_edit :: proc(
	text: string,
	accounts: map[proto.Account_Id]$T,
	roles: []Role,
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

// custom_emoji_index returns the position of the emoji `name` in the sheet. It
// returns false if the server has no emoji with that name.
custom_emoji_index :: proc(names: []string, name: string) -> (int, bool) {
	return slice.binary_search(names, name)
}

// Emoji_Span is the position of one of the server's emoji in the shown text
// (its placeholder character), and which emoji it is (its cell in the sheet).
Emoji_Span :: struct {
	start, end: int,
	index:      int,
}

// mentions_display returns a stored message as it is shown. Tokens become
// `@display name` (or `@role name` for a role), and the spans say where each
// mention is and whether it mentions `me`. <@everyone> mentions everybody, and a
// role mention mentions whoever has the role. Text without tokens is returned
// unchanged with no spans. Anything else is allocated in the temp allocator.
mentions_display :: proc(
	text: string,
	accounts: map[proto.Account_Id]$T,
	roles: []Role,
	me: proto.Account_Id,
) -> (
	shown: string,
	spans: []Mention_Span,
) {
	shown, spans, _ = text_display(text, accounts, roles, me, nil)
	return
}

// text_display is like mentions_display, and additionally replaces the server's
// emoji (`emoji`, its names in order) written as `:name:` with one
// proto.CUSTOM_EMOJI_PLACEHOLDER each. `custom` says where each placeholder is
// and which emoji it stands for. A `:name:` that isn't one of the server's emoji
// stays unchanged.
text_display :: proc(
	text: string,
	accounts: map[proto.Account_Id]$T,
	roles: []Role,
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

// Link_Span is the position of a link to a message (proto/forward.odin) in the
// shown text, and what the link points at.
Link_Span :: struct {
	start, end: int,
	link:       proto.Msg_Link,
}

// The text of a link, used when the caller has nothing better to show.
LINK_TEXT :: "\u21aa a message"

// text_display_links is like text_display, and additionally handles links to
// messages. Each link is replaced by the text that `label` returns for it
// (LINK_TEXT if there is no `label`) and gets its own span.
text_display_links :: proc(
	text: string,
	accounts: map[proto.Account_Id]$T,
	roles: []Role,
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

// emoji_encode turns what was typed into what is stored, for emoji: each
// `:shortcode:` of a Unicode emoji becomes its character, unless the server has
// an emoji of its own with that name (`custom`, in order), which stays as
// `:name:`. Everything else stays unchanged. The result is allocated in the temp
// allocator.
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

package mattermost

import "core:strings"
import "core:unicode/utf8"

import "common:proto"

// Emoji: the names that reactions use. Mattermost's reactions are names
// (`thumbsup`, `+1`, `partyparrot`) and yap's are the character itself, or
// `:name:` for one of the server's own (proto/emoji.odin).

// Emoji_Map holds what a name can be.
Emoji_Map :: struct {
	codes:     map[string]rune, // yap's own emoji, by each of their shortcodes
	custom:    map[string]string, // Mattermost's custom emoji name -> its name in yap
	allocator: Allocator,
}

// emoji_map_make makes the map of yap's emoji. It reads the whole table once;
// proto.emoji_by_shortcode, which does it for each call, would be slow for
// the number of reactions that a server has.
emoji_map_make :: proc(allocator: Allocator) -> Emoji_Map {
	m := Emoji_Map {
		codes     = make(map[string]rune, len(proto.EMOJI) * 2, allocator),
		custom    = make(map[string]string, allocator),
		allocator = allocator,
	}
	for e in proto.EMOJI {
		names := e.names
		for code in strings.split_iterator(&names, " ") {
			if code not_in m.codes {
				m.codes[strings.clone(code, allocator)] = e.r
			}
		}
	}
	return m
}

// emoji_add_custom says that Mattermost's custom emoji `name` is `yap_name` in
// yap.
emoji_add_custom :: proc(m: ^Emoji_Map, name, yap_name: string) {
	m.custom[strings.clone(name, m.allocator)] = strings.clone(yap_name, m.allocator)
}

// custom_emoji_name returns the name that a custom emoji gets in yap: Mattermost
// allows capitals and `-` and `+`, yap only a-z 0-9 _, 2 to 64 characters. `changed`
// says when it isn't the name it was.
custom_emoji_name :: proc(names: ^Unique, raw: string) -> (name: string, changed: bool) {
	b := make([dynamic]u8, 0, len(raw), context.temp_allocator)
	for ch in transmute([]u8)raw {
		switch ch {
		case 'A' ..= 'Z':
			append(&b, ch + ('a' - 'A'))
		case 'a' ..= 'z', '0' ..= '9', '_':
			append(&b, ch)
		case:
			if ch < 0x80 || ch >= 0xc0 {
				append(&b, '_')
			}
		}
	}
	base := string(b[:])
	for len(base) < proto.MIN_EMOJI_NAME {
		base = strings.concatenate({base, "_"}, context.temp_allocator)
	}
	name = unique_name(names, base, proto.MAX_EMOJI_NAME)
	return name, name != raw
}

Reaction_Result :: enum {
	Mapped, // a yap emoji, or one of the server's own
	Tone_Dropped, // mapped without the skin tone, which yap has no emoji for
	Unknown, // a name that isn't known; the reaction is left out
}

// map_reaction returns the reaction that Mattermost's emoji `name` becomes: the
// character, or `:name:` for a custom emoji. Skin tones (`thumbsup_tone3`,
// `+1::skin-tone-3`) are dropped, as a single emoji with a tone isn't one that
// yap can send (proto/emoji.odin). The result is allocated with `allocator`.
map_reaction :: proc(
	m: ^Emoji_Map,
	name: string,
	allocator: Allocator,
) -> (
	reaction: string,
	result: Reaction_Result,
) {
	base := strings.trim(name, ":")
	// A name that is one as it is wins over reading a skin tone out of it: a
	// custom emoji may be called anything.
	if found, ok := lookup(m, base, allocator); ok {
		return found, .Mapped
	}
	tone := strings.index(base, "::skin-tone-")
	if tone < 0 {
		underscore := strings.last_index(base, "_tone")
		if underscore > 0 && is_tone_suffix(base[underscore + 5:]) {
			tone = underscore
		}
	}
	if tone >= 0 {
		if found, ok := lookup(m, base[:tone], allocator); ok {
			// A custom emoji has no tones, so nothing was dropped from it.
			return found, .Mapped if found[0] == ':' else .Tone_Dropped
		}
	}
	return "", .Unknown
}

// is_tone_suffix says whether `s` is the number of a skin tone, 1 to 5.
@(private = "file")
is_tone_suffix :: proc(s: string) -> bool {
	return len(s) == 1 && s[0] >= '1' && s[0] <= '5'
}

// lookup finds a name in yap's emoji, then in the custom ones.
@(private = "file")
lookup :: proc(m: ^Emoji_Map, name: string, allocator: Allocator) -> (reaction: string, ok: bool) {
	if r, found := m.codes[name]; found {
		bytes, n := utf8.encode_rune(r)
		return strings.clone(string(bytes[:n]), allocator), true
	}
	if yap_name, found := m.custom[name]; found {
		return strings.concatenate({":", yap_name, ":"}, allocator), true
	}
	return "", false
}

package mattermost

import "core:strings"

import "common:proto"

// Names: how a Mattermost user, bot or channel is called in yap.

// username_of returns the username for an account called `raw`: lower case,
// and only the characters yap allows (a-z 0-9 _ . -), the others becoming `_`,
// at most MAX_USERNAME_SIZE of them, and not the username of an account that
// `names` has already given. Mattermost's own rules are the same or narrower
// (3 to 22 characters of these), so for an export from Mattermost it is the
// name as it was, and `changed` says when it wasn't.
username_of :: proc(names: ^Unique, raw: string) -> (username: string, changed: bool) {
	b := make([dynamic]u8, 0, len(raw), context.temp_allocator)
	for ch in transmute([]u8)raw {
		switch ch {
		case 'A' ..= 'Z':
			append(&b, ch + ('a' - 'A'))
		case 'a' ..= 'z', '0' ..= '9', '_', '.', '-':
			append(&b, ch)
		case:
			// One underscore for a whole character, not one for each of its bytes.
			if ch < 0x80 || ch >= 0xc0 {
				append(&b, '_')
			}
		}
	}
	base := string(b[:])
	if base == "" {
		base = "user"
	}
	username = unique_name(names, base, proto.MAX_USERNAME_SIZE)
	return username, username != raw
}

// display_of returns the name that people are shown for a user: the nickname,
// else the first and last name, else the username.
display_of :: proc(u: User) -> string {
	candidates := [?]string {
		u.nickname,
		strings.join({u.first_name, u.last_name}, " ", context.temp_allocator),
		u.username,
	}
	for c in candidates {
		if name, _ := clean_text(c, proto.MAX_NAME_SIZE); name != "" {
			return name
		}
	}
	return u.username
}

// bot_display_of returns the name that a bot is shown with.
bot_display_of :: proc(b: Bot) -> string {
	for c in ([?]string{b.display_name, b.username}) {
		if name, _ := clean_text(c, proto.MAX_NAME_SIZE); name != "" {
			return name
		}
	}
	return b.username
}

Email_Problem :: enum {
	None,
	Invalid, // not an address yap accepts (see proto.email_clean); the account gets none
	Taken, // another account has it (yap's are unique); the later one gets none
}

// email_of returns the address of an account as yap keeps it (lower case), or
// "" and what is wrong with it. `taken` holds the addresses given so far.
email_of :: proc(
	taken: ^map[string]bool,
	raw: string,
	allocator: Allocator,
) -> (
	address: string,
	problem: Email_Problem,
) {
	if strings.trim_space(raw) == "" {
		return
	}
	buf: [proto.MAX_EMAIL_SIZE]u8
	cleaned, ok := proto.email_clean(raw, &buf)
	if !ok {
		return "", .Invalid
	}
	if cleaned in taken^ {
		return "", .Taken
	}
	address = strings.clone(cleaned, allocator)
	taken[address] = true
	return address, .None
}

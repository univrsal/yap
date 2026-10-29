package proto

import "core:slice"
import "core:strconv"
import "core:strings"

// Mentions: a message's text refers to accounts with tokens,
//
// 	<@17>         account 17
// 	<@&5>         everyone with role 5 among the conversation's members
// 	<@everyone>   every member of the conversation
// 	<@here>       the members of the conversation who are online
//
// These tokens stay valid when an account changes its name, and the server can
// read them without knowing any names. Clients write them when a message is
// sent (an `@username` that was typed becomes the account's token) and display
// them as `@display name`. Anything else that merely resembles a token is just
// text.
//
// The server records who a message mentions (and so for whom it counts as a
// mention), as long as they may read it. `<@everyone>` requires the
// Mention_Everyone permission. If anyone else uses it, the server stores it as
// the plain text `@everyone`, which reads the same but mentions nobody. So does
// `<@here>` (as `@here`), which mentions those whose activity is Online
// (activity.odin) when the message is posted, as Mattermost's @here does. A
// client can't know who that was, so it counts a new `<@here>` as mentioning
// it if it is online itself. A
// role's token is treated the same way unless the role is Mentionable
// (roles.odin), in which case it is stored as `@name`. Mentioning a role
// doesn't subscribe anybody to anything.

MENTION_EVERYONE :: "everyone"
MENTION_HERE :: "here"

Mention :: struct {
	start, end: int, // the token's bytes in the text
	account:    Account_Id, // 0 for everyone, here or a role
	role:       Role_Id, // 0 unless it's a role mention
	everyone:   bool,
	here:       bool,
}

// next_mention finds the first token in text[from:]. ok is false if there is
// none.
next_mention :: proc(text: string, from: int) -> (m: Mention, ok: bool) {
	at := from
	for at < len(text) {
		i := strings.index(text[at:], "<@")
		if i < 0 {
			return
		}
		start := at + i
		close := strings.index_byte(text[start + 2:], '>')
		if close < 0 {
			return
		}
		inside := text[start + 2:][:close]
		end := start + 2 + close + 1
		switch {
		case inside == MENTION_EVERYONE:
			return {start = start, end = end, everyone = true}, true
		case inside == MENTION_HERE:
			return {start = start, end = end, here = true}, true
		case len(inside) > 0 && len(inside) <= 10 && all_digits(inside):
			if n, parsed := strconv.parse_u64_of_base(inside, 10);
			   parsed && n > 0 && n <= u64(max(Account_Id)) {
				return {start = start, end = end, account = Account_Id(n)}, true
			}
		case len(inside) > 1 && len(inside) <= 11 && inside[0] == '&' && all_digits(inside[1:]):
			if n, parsed := strconv.parse_u64_of_base(inside[1:], 10);
			   parsed && n > 0 && n <= u64(max(Role_Id)) {
				return {start = start, end = end, role = Role_Id(n)}, true
			}
		}
		at = start + 2
	}
	return
}

all_digits :: proc(s: string) -> bool {
	for ch in transmute([]u8)s {
		if ch < '0' || ch > '9' {
			return false
		}
	}
	return true
}

// mention_token writes the token for an account (0 means everyone), allocated
// with the temp allocator.
mention_token :: proc(account: Account_Id) -> string {
	if account == 0 {
		return "<@" + MENTION_EVERYONE + ">"
	}
	buf := make([]u8, 16, context.temp_allocator)
	return strings.concatenate(
		{"<@", strconv.write_uint(buf, u64(account), 10), ">"},
		context.temp_allocator,
	)
}

// role_mention_token writes the token for a role, allocated with the temp
// allocator.
role_mention_token :: proc(role: Role_Id) -> string {
	buf := make([]u8, 16, context.temp_allocator)
	return strings.concatenate(
		{"<@&", strconv.write_uint(buf, u64(role), 10), ">"},
		context.temp_allocator,
	)
}

// mentions_account reports whether `text` mentions `account`, either by its
// token, by the token of one of its `roles`, by <@everyone> (if `everyone`
// counts) or by <@here> (if `here` counts).
mentions_account :: proc(
	text: string,
	account: Account_Id,
	roles: []Role_Id = nil,
	everyone := true,
	here := true,
) -> bool {
	at := 0
	for {
		m, ok := next_mention(text, at)
		if !ok {
			return false
		}
		if (m.account != 0 && m.account == account) ||
		   (m.everyone && everyone) ||
		   (m.here && here) ||
		   (m.role != 0 && slice.contains(roles, m.role)) {
			return true
		}
		at = m.end
	}
}

package proto

import "core:strconv"
import "core:strings"

/*
Mentions: a message's text names accounts with tokens,

	<@17>         account 17
	<@everyone>   every member of the conversation

which survive an account changing what it's called, and which the
server reads without knowing any names. Clients write them when a
message is sent (`@username` as typed becomes the account's token) and
show them as `@display name`. Anything else that looks a little like
one is just text.

The server records who a message mentions (and so who it counts as a
mention for), as long as they may read it. `<@everyone>` needs the
Mention_Everyone permission: from anyone else the server stores it as
the plain text `@everyone`, so it reads the same and mentions nobody.
*/

MENTION_EVERYONE :: "everyone"

Mention :: struct {
	start, end: int, // the token's bytes in the text
	account:    Account_Id, // 0 for everyone
	everyone:   bool,
}

// next_mention finds the first token in text[from:]; ok is false if
// there's none.
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
		case len(inside) > 0 && len(inside) <= 10 && all_digits(inside):
			if n, parsed := strconv.parse_u64_of_base(inside, 10); parsed && n > 0 && n <= u64(max(Account_Id)) {
				return {start = start, end = end, account = Account_Id(n)}, true
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

// mention_token writes the token for an account (0: everyone), in the
// temp allocator.
mention_token :: proc(account: Account_Id) -> string {
	if account == 0 {
		return "<@" + MENTION_EVERYONE + ">"
	}
	buf := make([]u8, 16, context.temp_allocator)
	return strings.concatenate({"<@", strconv.write_uint(buf, u64(account), 10), ">"}, context.temp_allocator)
}

// mentions_account is whether `text` mentions `account`: by its token,
// or (if `everyone` counts) <@everyone>.
mentions_account :: proc(text: string, account: Account_Id, everyone := true) -> bool {
	at := 0
	for {
		m, ok := next_mention(text, at)
		if !ok {
			return false
		}
		if m.account == account || (m.everyone && everyone) {
			return true
		}
		at = m.end
	}
}

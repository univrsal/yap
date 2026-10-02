#+build !wasi
package proto

import "core:testing"

@(test)
test_mention_tokens :: proc(t: ^testing.T) {
	text := "<@17>hi <@everyone> and <@3><@4>, not <@x>, <@0>, <@99999999999> or <@5"
	want := []Mention {
		{start = 0, end = 5, account = 17},
		{start = 8, end = 19, everyone = true},
		{start = 24, end = 28, account = 3},
		{start = 28, end = 32, account = 4},
	}
	at, n := 0, 0
	for {
		m, ok := next_mention(text, at)
		if !ok {
			break
		}
		testing.expect(t, n < len(want), "a token too many")
		if n < len(want) {
			testing.expect_value(t, m, want[n])
		}
		n += 1
		at = m.end
	}
	testing.expect_value(t, n, len(want))

	testing.expect_value(t, mention_token(17), "<@17>")
	testing.expect_value(t, mention_token(0), "<@everyone>")
	testing.expect(t, mentions_account("hey <@17>!", 17))
	testing.expect(t, !mentions_account("hey <@171>!", 17))
	testing.expect(t, mentions_account("<@everyone>", 17))
	testing.expect(t, !mentions_account("<@everyone>", 17, everyone = false))
	testing.expect(t, !mentions_account("@everyone", 17))
}

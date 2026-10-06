#+build !wasi
package proto

import "core:testing"

@(test)
test_register_codecs :: proc(t: ^testing.T) {
	buf: [REGISTER_BODY_MAX]u8
	longest := Register {
		username = "abcdefghijklmnopqrstuvwxyz012345",
		password = string(buf[:MAX_ACCOUNT_PASSWORD]),
		device   = "abcdefghijklmnopqrstuvwxyz012345",
		email    = string(buf[:MAX_EMAIL_SIZE]),
		invite   = "ABCDEFGHJK",
	}
	out: [REGISTER_BODY_MAX]u8
	testing.expect(t, encode_register(out[:], longest) != nil)
	r, ok := decode_register(encode_register(out[:], {username = "alice", password = "pw", email = "a@b.cd"}))
	testing.expect(t, ok)
	testing.expect_value(t, r.username, "alice")
	testing.expect_value(t, r.email, "a@b.cd")
	testing.expect_value(t, r.invite, "")

	reason, reason_ok := decode_register_refusal({u8(Register_Refusal.Invite)})
	testing.expect(t, reason_ok && reason == .Invite)
	_, reason_ok = decode_register_refusal({0})
	testing.expect(t, !reason_ok)
	_, reason_ok = decode_register_refusal(nil)
	testing.expect(t, !reason_ok)

	code_buf: [INVITE_CODE_SIZE]u8
	code, code_ok := invite_code_clean(" abcdefghjk ", &code_buf)
	testing.expect(t, code_ok)
	testing.expect_value(t, code, "ABCDEFGHJK")
	_, code_ok = invite_code_clean("ABCDEFGHJ0", &code_buf) // no 0 in the alphabet
	testing.expect(t, !code_ok)
	_, code_ok = invite_code_clean("ABCDEFGHJ", &code_buf)
	testing.expect(t, !code_ok)

	testing.expect(t, invite_usable({max_uses = 0, uses = 99}, 5))
	testing.expect(t, !invite_usable({max_uses = 2, uses = 2}, 5))
	testing.expect(t, !invite_usable({expires = 5}, 5))
	testing.expect(t, invite_usable({expires = 6}, 5))
	testing.expect(t, !invite_usable({revoked = true}, 5))

	invites := []Invite {
		{code = "ABCDEFGHJK", creator = 3, created = 10, max_uses = 5, uses = 1, expires = 99},
		{code = "KJHGFEDCBA", creator = 4, revoked = true},
	}
	list_buf: [2 + 2 * INVITE_MAX_SIZE]u8
	got, list_ok := decode_invites(encode_invites(list_buf[:], invites))
	testing.expect(t, list_ok)
	testing.expect_value(t, len(got), 2)
	if len(got) == 2 {
		testing.expect_value(t, got[0], invites[0])
		testing.expect_value(t, got[1], invites[1])
	}
	// What doesn't fit is left out.
	small: [2 + INVITE_MAX_SIZE]u8
	got, list_ok = decode_invites(encode_invites(small[:], invites))
	testing.expect(t, list_ok && len(got) == 1)

	info_buf: [SERVER_INFO_MAX_SIZE]u8
	body, info_ok := encode_server_info(
		info_buf[:],
		{name = "x", registration = {.Open, .Email}, email = "yap@example.org"},
	)
	testing.expect(t, info_ok)
	info, _ := decode_server_info(body)
	testing.expect_value(t, info.registration, Registration_Flags{.Open, .Email})
	testing.expect_value(t, info.email, "yap@example.org")
}

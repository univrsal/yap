#+build !wasi
package proto

import "core:strings"
import "core:testing"

@(test)
test_voice_moderation_roundtrip :: proc(t: ^testing.T) {
	move_buf: [VOICE_MOVE_SIZE]u8
	account, room, ok := decode_voice_move(encode_voice_move(&move_buf, 7, 12))
	testing.expect(t, ok)
	testing.expect_value(t, account, Account_Id(7))
	testing.expect_value(t, room, Room(12))
	_, _, ok = decode_voice_move(move_buf[:7])
	testing.expect(t, !ok)

	mute_buf: [VOICE_MUTE_SIZE]u8
	on: bool
	account, on, ok = decode_voice_mute(encode_voice_mute(&mute_buf, 9, true))
	testing.expect(t, ok)
	testing.expect_value(t, account, Account_Id(9))
	testing.expect(t, on)
	_, _, ok = decode_voice_mute(mute_buf[:4])
	testing.expect(t, !ok)

	moved_buf: [VOICE_MOVED_SIZE]u8
	by: Account_Id
	room, by, ok = decode_voice_moved(encode_voice_moved(&moved_buf, 3, 5))
	testing.expect(t, ok)
	testing.expect_value(t, room, Room(3))
	testing.expect_value(t, by, Account_Id(5))
	// An older server sends only the room.
	room_buf: [4]u8
	room, by, ok = decode_voice_moved(encode_room(&room_buf, 4))
	testing.expect(t, ok)
	testing.expect_value(t, room, Room(4))
	testing.expect_value(t, by, Account_Id(0))
	_, _, ok = decode_voice_moved(moved_buf[:6])
	testing.expect(t, !ok)
}

@(test)
test_ban_roundtrip :: proc(t: ^testing.T) {
	buf: [BAN_SET_MAX_SIZE]u8
	b := Ban_Set {
		account = 4,
		on      = true,
		reason  = "spam",
		purge   = .Week,
	}
	got, ok := decode_ban_set(encode_ban_set(&buf, b))
	testing.expect(t, ok)
	testing.expect_value(t, got, b)

	// The longest reason fits; a longer one isn't encoded, and isn't
	// accepted either.
	b.reason = strings.repeat("x", MAX_BAN_REASON, context.temp_allocator)
	got, ok = decode_ban_set(encode_ban_set(&buf, b))
	testing.expect(t, ok)
	testing.expect_value(t, got.reason, b.reason)
	b.reason = strings.repeat("x", MAX_BAN_REASON + 1, context.temp_allocator)
	testing.expect(t, encode_ban_set(&buf, b) == nil)
	long: [BAN_SET_MAX_SIZE + 1]u8
	long[5] = MAX_BAN_REASON + 1
	_, ok = decode_ban_set(long[:])
	testing.expect(t, !ok)

	// An unknown purge, or a truncated body, is refused.
	b.reason = ""
	body := encode_ban_set(&buf, b)
	body[len(body) - 1] = u8(max(Ban_Purge)) + 1
	_, ok = decode_ban_set(body)
	testing.expect(t, !ok)
	_, ok = decode_ban_set(body[:len(body) - 1])
	testing.expect(t, !ok)
}

@(test)
test_ban_list_roundtrip :: proc(t: ^testing.T) {
	bans := []Ban {
		{account = 2, by = 1, time = 1_790_000_000_000, reason = "spam"},
		{account = 3, by = 1, time = 1_790_000_000_001, reason = ""},
	}
	buf: [256]u8
	got, ok := decode_bans(encode_bans(buf[:], bans))
	testing.expect(t, ok)
	testing.expect_value(t, len(got), 2)
	for b, i in bans {
		testing.expect_value(t, got[i], b)
	}

	// Only those that fit, all of them whole.
	small: [4 + BAN_MAX_SIZE]u8
	long := Ban {
		account = 5,
		reason  = strings.repeat("y", MAX_BAN_REASON, context.temp_allocator),
	}
	got, ok = decode_bans(encode_bans(small[:], {long, long}))
	testing.expect(t, ok)
	testing.expect_value(t, len(got), 1)
	testing.expect_value(t, got[0], long)

	_, ok = decode_bans(encode_bans(buf[:], bans)[:20])
	testing.expect(t, !ok)
}

@(test)
test_banned_and_logged_out :: proc(t: ^testing.T) {
	banned_buf: [BANNED_MAX_SIZE]u8
	testing.expect_value(t, decode_banned(encode_banned(&banned_buf, "spam")), "spam")
	testing.expect_value(t, decode_banned(nil), "")

	out_buf: [LOGGED_OUT_MAX_SIZE]u8
	reason, text := decode_logged_out(encode_logged_out(&out_buf, .Banned, "spam"))
	testing.expect_value(t, reason, Logout_Reason.Banned)
	testing.expect_value(t, text, "spam")
	// Without a text, the body is the reason alone, as older servers send it.
	body := encode_logged_out(&out_buf, .Revoked, "")
	testing.expect_value(t, len(body), 1)
	reason, text = decode_logged_out(body)
	testing.expect_value(t, reason, Logout_Reason.Revoked)
	testing.expect_value(t, text, "")
}

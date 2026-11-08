#+build !wasi
package conn

import "core:strings"
import "core:testing"

import "common:proto"

// Tests of the account's settings, status, picture and the members of
// conversations (profiles.odin).

@(private = "file")
open_profile :: proc(tc: ^Test_Conn) -> ^View {
	tc_open(tc)
	tc.c.auth.me = 1
	tc_account(tc, 1, "bob", "Bob")
	tc_account(tc, 2, "alice", "Alice")
	tc_account(tc, 3, "carol", "Carol")
	tc_conv(tc, 4, "Lobby")
	tc_conv(tc, 5, "Gaming")
	return tc_view(tc)
}

@(private = "file")
setting_event :: proc(tc: ^Test_Conn, key, value: string) {
	buf: [proto.SETTING_MAX_SIZE]u8
	tc_event(tc, .Setting_Changed, proto.encode_setting(buf[:], key, transmute([]u8)value))
}

// ---- settings ----

@(test)
test_settings_follow_the_server :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_profile(&tc)
	defer tc_close(&tc)
	defer profiles_destroy(&tc.c)
	c := &tc.c

	// Settings arrive with the sync, then one at a time.
	tc_event(&tc, .Sync_Begin)
	testing.expect(t, !c.profiles.synced)
	setting_event(&tc, "ui/theme", "dark")
	setting_event(&tc, "ui/view", "5")
	testing.expect_value(t, len(c.profiles.shared), 2)
	testing.expect_value(t, c.profiles.shared["ui/theme"], "dark")
	tc_event(&tc, .Sync_End)
	testing.expect(t, c.profiles.synced)
	testing.expect_value(t, c.profiles.syncs, 1)
	testing.expect(t, v.shared_synced)
	testing.expect_value(t, v.shared["ui/theme"], "dark")

	// A change replaces the value, an empty one removes the setting.
	setting_event(&tc, "ui/theme", "light")
	testing.expect_value(t, c.profiles.shared["ui/theme"], "light")
	testing.expect_value(t, v.shared["ui/theme"], "light")
	setting_event(&tc, "ui/theme", "")
	testing.expect_value(t, len(c.profiles.shared), 1)
	_, has := v.shared["ui/theme"]
	testing.expect(t, !has)

	// An invalid key or body is ignored.
	setting_event(&tc, "Not A Key", "x")
	setting_event(&tc, "", "x")
	tc_event(&tc, .Setting_Changed, []u8{5, 'a'})
	testing.expect_value(t, len(c.profiles.shared), 1)

	// A new sync starts from none.
	tc_event(&tc, .Sync_Begin)
	testing.expect_value(t, len(c.profiles.shared), 0)
	testing.expect(t, !v.shared_synced)
}

@(test)
test_setting_put :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_profile(&tc)
	defer tc_close(&tc)
	defer profiles_destroy(&tc.c)
	c := &tc.c

	setting_put(c, "ui/theme", "dark")
	r, ok := tc_one(t, &tc, .Setting_Set)
	testing.expect(t, ok)
	key, value, dec := proto.decode_setting(r.body)
	testing.expect(t, dec)
	testing.expect_value(t, key, "ui/theme")
	testing.expect_value(t, string(value), "dark")
	// It is kept at once, without waiting for the answer.
	testing.expect_value(t, c.profiles.shared["ui/theme"], "dark")

	// The same value is not sent again.
	setting_put(c, "ui/theme", "dark")
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	// Removing is an empty value; removing what isn't there is nothing.
	setting_put(c, "ui/theme", "")
	r, ok = tc_one(t, &tc, .Setting_Set)
	testing.expect(t, ok)
	testing.expect_value(t, len(c.profiles.shared), 0)
	setting_put(c, "ui/theme", "")
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)

	// A key or value the server would refuse is not sent.
	setting_put(c, "Bad Key", "x")
	setting_put(c, "", "x")
	setting_put(
		c,
		"ui/big",
		strings.repeat("x", proto.MAX_SETTING_VALUE + 1, context.temp_allocator),
	)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	testing.expect_value(t, len(c.profiles.shared), 0)
	setting_put(c, "ui/big", strings.repeat("x", proto.MAX_SETTING_VALUE, context.temp_allocator))
	testing.expect_value(t, len(tc_sent(t, &tc)), 1)
}

@(test)
test_viewed_conversation_is_shared :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_profile(&tc)
	defer tc_close(&tc)
	defer profiles_destroy(&tc.c)
	c := &tc.c

	// Not before the settings have arrived, or for no conversation.
	shared_viewed(c, 4)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)

	// The conversation another device looked at last is opened when the sync
	// ends, once.
	tc_event(&tc, .Sync_Begin)
	tc_conv(&tc, 4, "Lobby") // the sync brings the conversations again
	tc_conv(&tc, 5, "Gaming")
	setting_event(&tc, SETTING_VIEW, "5")
	testing.expect_value(t, c.convs.viewing, proto.Conv_Id(0))
	tc_event(&tc, .Sync_End)
	testing.expect_value(t, c.convs.viewing, proto.Conv_Id(5))
	testing.expect_value(t, shared_view(c), proto.Conv_Id(0))
	_ = tc_sent(t, &tc)

	shared_viewed(c, 0)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	// Looking at another one tells the server, for the other devices.
	shared_viewed(c, 4)
	r, ok := tc_one(t, &tc, .Setting_Set)
	testing.expect(t, ok)
	key, value, _ := proto.decode_setting(r.body)
	testing.expect_value(t, key, SETTING_VIEW)
	testing.expect_value(t, string(value), "4")
	// ... but only when it is a change.
	shared_viewed(c, 4)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
}

@(test)
test_shared_view_is_used_once :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_profile(&tc)
	defer tc_close(&tc)
	defer profiles_destroy(&tc.c)
	setting_event(&tc, SETTING_VIEW, "5")
	testing.expect_value(t, shared_view(&tc.c), proto.Conv_Id(5))
	testing.expect_value(t, shared_view(&tc.c), proto.Conv_Id(0))
}

@(test)
test_shared_view_needs_a_number :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_profile(&tc)
	defer tc_close(&tc)
	defer profiles_destroy(&tc.c)
	setting_event(&tc, SETTING_VIEW, "lobby")
	testing.expect_value(t, shared_view(&tc.c), proto.Conv_Id(0))

	tc2: Test_Conn
	_ = open_profile(&tc2)
	defer tc_close(&tc2)
	defer profiles_destroy(&tc2.c)
	testing.expect_value(t, shared_view(&tc2.c), proto.Conv_Id(0)) // none kept
}

// ---- status and picture ----

@(test)
test_status_set :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_profile(&tc)
	defer tc_close(&tc)

	status_set(&tc.c, "on holiday", 5000, 0)
	r, ok := tc_one(t, &tc, .Profile_Set)
	testing.expect(t, ok)
	p, dec := proto.decode_profile_set(r.body)
	testing.expect(t, dec)
	testing.expect_value(t, p.mask, u8(proto.PROFILE_STATUS))
	testing.expect_value(t, p.status, "on holiday")
	testing.expect_value(t, p.status_until, proto.Unix_Ms(5000))
	testing.expect_value(t, p.status_at, proto.Unix_Ms(0))

	// Copied from another server it says when it was set.
	status_set(&tc.c, "lunch", 0, 777)
	r, _ = tc_one(t, &tc, .Profile_Set)
	p, _ = proto.decode_profile_set(r.body)
	testing.expect_value(t, p.status_at, proto.Unix_Ms(777))

	// An empty status has no end, and control characters don't get through.
	status_set(&tc.c, "", 9999, 0)
	r, _ = tc_one(t, &tc, .Profile_Set)
	p, _ = proto.decode_profile_set(r.body)
	testing.expect_value(t, p.status, "")
	testing.expect_value(t, p.status_until, proto.Unix_Ms(0))
	status_set(&tc.c, "a\x00b\nc", 0, 0)
	r, _ = tc_one(t, &tc, .Profile_Set)
	p, _ = proto.decode_profile_set(r.body)
	testing.expect(t, !strings.contains_any(p.status, "\x00\n"))

	// Only a failure is said.
	count := v.notice.count
	tc_answer(&tc, r.id, .Ok)
	testing.expect_value(t, v.notice.count, count)
	status_set(&tc.c, "x", 0, 0)
	r, _ = tc_one(t, &tc, .Profile_Set)
	tc_answer(&tc, r.id, .Denied)
	testing.expect_value(t, v.notice.text, status_text(.Denied))
	testing.expect(t, !v.notice.ok)
}

@(test)
test_avatar_set :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_profile(&tc)
	defer tc_close(&tc)
	defer blobs_destroy(&tc.c)

	// Removing the picture is a profile change of its own.
	avatar_set(&tc.c, {}, true)
	r, ok := tc_one(t, &tc, .Profile_Set)
	testing.expect(t, ok)
	p, dec := proto.decode_profile_set(r.body)
	testing.expect(t, dec)
	testing.expect_value(t, p.mask, u8(proto.PROFILE_AVATAR))
	testing.expect_value(t, p.avatar, proto.Blob_Id(0))

	// A picture the server would refuse is never uploaded. The call frees it.
	image :: proc(size, width, height: int) -> Chat_Image {
		return {jpeg = make([]u8, size), width = width, height = height}
	}
	avatar_set(&tc.c, image(0, 64, 64), false)
	avatar_set(&tc.c, image(proto.MAX_AVATAR_SIZE + 1, 64, 64), false)
	avatar_set(&tc.c, image(100, proto.MAX_AVATAR_SIDE + 1, 64), false)
	avatar_set(&tc.c, image(100, 64, proto.MAX_AVATAR_SIDE + 1), false)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	testing.expect_value(t, len(tc.c.blobs.pictures), 0)

	// One that is within the limits (the largest allowed included) is uploaded.
	avatar_set(&tc.c, image(100, 64, 64), false)
	avatar_set(
		&tc.c,
		image(proto.MAX_AVATAR_SIZE, proto.MAX_AVATAR_SIDE, proto.MAX_AVATAR_SIDE),
		false,
	)
	testing.expect_value(t, len(tc.c.blobs.pictures), 2)
	if len(tc.c.blobs.pictures) == 2 {
		testing.expect_value(t, tc.c.blobs.pictures[0].put.size, 100)
		testing.expect(t, !tc.c.blobs.pictures[0].server)
	}
}

// ---- members ----

@(test)
test_members :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_profile(&tc)
	defer tc_close(&tc)
	defer profiles_destroy(&tc.c)

	members_fetch(&tc.c, 0)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)

	members_fetch(&tc.c, 4)
	testing.expect(t, v.members.loading)
	testing.expect_value(t, v.members.conv, proto.Conv_Id(4))
	r, ok := tc_one(t, &tc, .Conv_Members)
	testing.expect(t, ok)
	conv, conv_ok := proto.decode_conv_id(r.body)
	testing.expect(t, conv_ok)
	testing.expect_value(t, conv, proto.Conv_Id(4))

	out: [256]u8
	tc_answer(&tc, r.id, .Ok, proto.encode_conv_members(out[:], {1, 2, 3}, {2}))
	testing.expect(t, !v.members.loading)
	testing.expect_value(t, len(v.members.accounts), 3)
	testing.expect_value(t, len(v.members.admins), 1)
	if len(v.members.admins) == 1 {
		testing.expect_value(t, v.members.admins[0], proto.Account_Id(2))
	}
	testing.expect_value(t, v.members.count, 2)

	// The members of a conversation that has since been replaced by another are dropped.
	members_fetch(&tc.c, 4)
	old, _ := tc_one(t, &tc, .Conv_Members)
	members_fetch(&tc.c, 5)
	newer, _ := tc_one(t, &tc, .Conv_Members)
	tc_answer(&tc, old.id, .Ok, proto.encode_conv_members(out[:], {1}))
	testing.expect(t, v.members.loading)
	testing.expect_value(t, v.members.conv, proto.Conv_Id(5))
	tc_answer(&tc, newer.id, .Ok, proto.encode_conv_members(out[:], {2, 3}))
	testing.expect_value(t, len(v.members.accounts), 2)
	testing.expect_value(t, v.members.conv, proto.Conv_Id(5))

	// A refusal or an unreadable answer ends the loading with nobody listed.
	for failure in ([]proto.Status{.Denied, .Ok}) {
		members_fetch(&tc.c, 5)
		r, _ = tc_one(t, &tc, .Conv_Members)
		body: []u8 = nil if failure == .Denied else []u8{9}
		tc_answer(&tc, r.id, failure, body)
		testing.expectf(t, !v.members.loading, "%v: still loading", failure)
		testing.expectf(t, len(v.members.accounts) == 0, "%v: members listed", failure)
	}
}

#+build !wasi
package proto

import "core:testing"

@(test)
test_username_clean :: proc(t: ^testing.T) {
	buf: [MAX_USERNAME_SIZE]u8
	name, ok := username_clean("Alice", &buf)
	testing.expect(t, ok)
	testing.expect_value(t, name, "alice")
	name, ok = username_clean("a.b_c-9", &buf)
	testing.expect(t, ok)
	testing.expect_value(t, name, "a.b_c-9")
	name, ok = username_clean("ab", &buf)
	testing.expect(t, ok)
	name, ok = username_clean("abcdefghijklmnopqrstuvwxyz012345", &buf)
	testing.expect(t, ok)
	testing.expect_value(t, len(name), MAX_USERNAME_SIZE)

	for bad in ([]string {
			"",
			"a",
			"abcdefghijklmnopqrstuvwxyz0123456",
			"has space",
			"ümlaut",
			"semi;colon",
			"a\x00b",
		}) {
		_, ok = username_clean(bad, &buf)
		testing.expectf(t, !ok, "%q should not be a username", bad)
	}

	testing.expect(t, !account_password_ok("1234567"))
	testing.expect(t, account_password_ok("12345678"))
}

@(test)
test_account_bodies :: proc(t: ^testing.T) {
	buf: [ACCOUNT_BODY_MAX]u8

	{
		body := encode_auth_login(buf[:], "alice", "correct horse", "laptop")
		username, password, device, ok := decode_auth_login(body)
		testing.expect(t, ok)
		testing.expect_value(t, username, "alice")
		testing.expect_value(t, password, "correct horse")
		testing.expect_value(t, device, "laptop")
		_, _, _, ok = decode_auth_login(body[:len(body) - 1])
		testing.expect(t, !ok)
		// The longest of each still fits.
		long := make([]u8, 255, context.temp_allocator)
		testing.expect(
			t,
			encode_auth_login(buf[:], string(long), string(long), string(long)) != nil,
		)
		// And a string too long for its length byte doesn't.
		longer := make([]u8, 256, context.temp_allocator)
		testing.expect(t, encode_auth_login(buf[:], "a", string(longer), "") == nil)
	}
	{
		rb: [AUTH_LOGIN_RESPONSE_SIZE]u8
		account, flags, ok := decode_auth_login_response(
			encode_auth_login_response(&rb, 17, {.Must_Change}),
		)
		testing.expect(t, ok)
		testing.expect_value(t, account, 17)
		testing.expect_value(t, flags, Account_Flags{.Must_Change})
	}
	{
		old, new, revoke, ok := decode_password_change(
			encode_password_change(buf[:], "old one", "new one", true),
		)
		testing.expect(t, ok)
		testing.expect_value(t, old, "old one")
		testing.expect_value(t, new, "new one")
		testing.expect(t, revoke)
	}
	{
		key: [KEY_SIZE]u8
		for &b, i in key {
			b = u8(i)
		}
		got, ok := decode_device_revoke(encode_device_revoke(buf[:], key))
		testing.expect(t, ok)
		testing.expect_value(t, got, key)
		_, ok = decode_device_revoke(buf[:KEY_SIZE - 1])
		testing.expect(t, !ok)
	}
	{
		p, ok := decode_profile_set(
			encode_profile_set(buf[:], {mask = PROFILE_DISPLAY, display = "Alice A."}),
		)
		testing.expect(t, ok)
		testing.expect_value(t, p.mask, PROFILE_DISPLAY)
		testing.expect_value(t, p.display, "Alice A.")
		// The others, without the name.
		p, ok = decode_profile_set(
			encode_profile_set(
				buf[:],
				{
					mask = PROFILE_STATUS | PROFILE_AVATAR,
					status = "away",
					status_until = 1234,
					avatar = 9,
				},
			),
		)
		testing.expect(t, ok)
		testing.expect_value(t, p.mask, PROFILE_STATUS | PROFILE_AVATAR)
		testing.expect_value(t, p.display, "")
		testing.expect_value(t, p.status, "away")
		testing.expect_value(t, p.status_until, 1234)
		testing.expect_value(t, p.avatar, 9)
		_, ok = decode_profile_set(buf[:3])
		testing.expect(t, !ok)
		// Nothing to change is fine; a field we don't know isn't.
		p, ok = decode_profile_set([]u8{0})
		testing.expect(t, ok)
		testing.expect_value(t, p.mask, 0)
		_, ok = decode_profile_set([]u8{0x80})
		testing.expect(t, !ok)
	}
	{
		username, password, display, ok := decode_account_create(
			encode_account_create(buf[:], "bob", "first password", "Bob"),
		)
		testing.expect(t, ok)
		testing.expect_value(t, username, "bob")
		testing.expect_value(t, password, "first password")
		testing.expect_value(t, display, "Bob")

		ib: [4]u8
		id, id_ok := decode_account_id(encode_account_id(&ib, 0xdeadbeef))
		testing.expect(t, id_ok)
		testing.expect_value(t, id, 0xdeadbeef)
	}
	{
		account, password, ok := decode_account_password_set(
			encode_account_password_set(buf[:], 5, "another one"),
		)
		testing.expect(t, ok)
		testing.expect_value(t, account, 5)
		testing.expect_value(t, password, "another one")
	}
	{
		sb: [SELF_SIZE]u8
		account, permissions, flags, ok := decode_self(
			encode_self(&sb, 3, {.Manage_Accounts, .Purge}, {.Owner}),
		)
		testing.expect(t, ok)
		testing.expect_value(t, account, 3)
		testing.expect_value(t, permissions, Permissions{.Manage_Accounts, .Purge})
		testing.expect_value(t, flags, Account_Flags{.Owner})
		testing.expect_value(t, self_email(encode_self(&sb, 3, {}, {})), "")
		with := encode_self(&sb, 3, {}, {}, .Busy, "alice@example.com")
		testing.expect_value(t, self_email(with), "alice@example.com")
		testing.expect_value(t, self_activity(with), Activity.Busy)
		code, by := self_verify(with)
		testing.expect_value(t, code, "")
		testing.expect_value(t, by, 0)
		waiting := encode_self(&sb, 3, {}, {.Unverified}, .Online, "a@b.cd", "ABCD2345", 1234)
		code, by = self_verify(waiting)
		testing.expect_value(t, code, "ABCD2345")
		testing.expect_value(t, by, 1234)
		testing.expect_value(t, self_email(waiting), "a@b.cd")
	}
	{
		buf: [1 + MAX_EMAIL_SIZE]u8
		email, ok := decode_email_set(encode_email_set(buf[:], "bob@example.net"))
		testing.expect(t, ok)
		testing.expect_value(t, email, "bob@example.net")
		_, ok = decode_email_set({3, 'a'})
		testing.expect(t, !ok)
	}
}

@(test)
test_account_record :: proc(t: ^testing.T) {
	buf: [ACCOUNT_MAX_SIZE]u8
	a := Account {
		id           = 42,
		flags        = {.Owner},
		username     = "abcdefghijklmnopqrstuvwxyz012345",
		display      = "0123456789012345678901234567890!",
		status       = "01234567890123456789012345678901234567890123456789012345678901234567890123456789",
		status_until = 77,
		avatar       = 5,
		roles        = {2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17},
	}
	body := encode_account(buf[:], a)
	testing.expect(t, body != nil)
	// The longest account is what ACCOUNT_MAX_SIZE says it is.
	testing.expect_value(t, len(body), ACCOUNT_MAX_SIZE)
	got, ok := decode_account(body)
	testing.expect(t, ok)
	testing.expect_value(t, got.id, a.id)
	testing.expect_value(t, got.flags, a.flags)
	testing.expect_value(t, got.username, a.username)
	testing.expect_value(t, got.display, a.display)
	testing.expect_value(t, got.status, a.status)
	testing.expect_value(t, got.status_until, a.status_until)
	testing.expect_value(t, got.avatar, a.avatar)
	testing.expect_value(t, len(got.roles), MAX_ACCOUNT_ROLES)
	testing.expect_value(t, got.roles[15], 17)

	// Without its activity (an older server's), it's online.
	got, ok = decode_account(body[:len(body) - 1])
	testing.expect(t, ok)
	testing.expect_value(t, got.activity, Activity.Online)
	_, ok = decode_account(body[:len(body) - 2])
	testing.expect(t, !ok)

	// One from a later server, with a status, an avatar and roles, and
	// more after them: what we know still reads.
	later := make([dynamic]u8, context.temp_allocator)
	append(&later, 7, 0, 0, 0, 0) // id, flags
	append(&later, 1, 'x', 1, 'X') // username, display
	append(&later, 4, 'a', 'w', 'a', 'y') // status
	append(&later, 1, 2, 3, 4, 5, 6, 7, 8) // until
	append(&later, 9, 0, 0, 0, 0, 0, 0, 0) // avatar
	append(&later, 2, 1, 0, 0, 0, 2, 0, 0, 0) // roles
	append(&later, 2) // busy
	append(&later, 0xff, 0xff) // whatever comes next
	got, ok = decode_account(later[:])
	testing.expect(t, ok)
	testing.expect_value(t, got.id, 7)
	testing.expect_value(t, got.username, "x")
	testing.expect_value(t, got.display, "X")
	testing.expect_value(t, got.status, "away")
	testing.expect_value(t, got.avatar, 9)
	testing.expect(t, len(got.roles) == 2 && got.roles[1] == 2)
	testing.expect_value(t, got.activity, Activity.Busy)
}

@(test)
test_roles :: proc(t: ^testing.T) {
	buf: [ROLE_MAX_SIZE]u8
	name := "0123456789abcdef0123456789abcdef"
	body := encode_role(
		buf[:],
		{
			id = 4,
			perms = {.Invite, .Purge},
			name = name,
			color = ROLE_COLOR_SET | 0x3366CC,
			position = 7,
			flags = {.Mentionable},
		},
	)
	testing.expect_value(t, len(body), ROLE_MAX_SIZE)
	role, ok := decode_role(body)
	testing.expect(t, ok)
	testing.expect_value(t, role.id, 4)
	testing.expect_value(t, role.perms, Permissions{.Invite, .Purge})
	testing.expect_value(t, role.name, name)
	testing.expect_value(t, role.color, ROLE_COLOR_SET | 0x3366CC)
	testing.expect_value(t, role.position, 7)
	testing.expect_value(t, role.flags, Role_Flags{.Mentionable})
	_, ok = decode_role(body[:len(body) - 2])
	testing.expect(t, !ok)
	// As older clients send it: no flags; nor colour or position.
	role, ok = decode_role(body[:len(body) - 1])
	testing.expect(t, ok && role.position == 7 && role.flags == {})
	role, ok = decode_role(body[:len(body) - 7])
	testing.expect(t, ok && role.name == name && role.color == 0 && role.position == 0)
	// A colour without the bit that says it's set is none.
	role, ok = decode_role(encode_role(buf[:], {id = 4, name = "x", color = 0x3366CC}))
	testing.expect(t, ok && role.color == 0)

	order_buf: [ROLE_ORDER_MAX_SIZE]u8
	order := []Role_Id{5, 3, 9}
	got_order_buf: [MAX_ROLES]Role_Id
	got_order, order_ok := decode_role_order(
		encode_role_order(order_buf[:], order),
		got_order_buf[:],
	)
	testing.expect(t, order_ok && len(got_order) == 3 && got_order[0] == 5 && got_order[2] == 9)

	roles_buf: [ACCOUNT_ROLES_MAX_SIZE]u8
	ids := [MAX_ACCOUNT_ROLES]Role_Id{}
	for &id, i in ids {
		id = Role_Id(i + 2)
	}
	body = encode_account_roles(roles_buf[:], 9, ids[:])
	testing.expect_value(t, len(body), ACCOUNT_ROLES_MAX_SIZE)
	got_buf: [MAX_ACCOUNT_ROLES]Role_Id
	account, roles, roles_ok := decode_account_roles(body, got_buf[:])
	testing.expect(t, roles_ok && account == 9 && len(roles) == MAX_ACCOUNT_ROLES && roles[0] == 2)
	small: [2]Role_Id
	_, _, roles_ok = decode_account_roles(body, small[:])
	testing.expect(t, !roles_ok)

	dis_buf: [ACCOUNT_DISABLE_SIZE]u8
	acc, on, dis_ok := decode_account_disable(encode_account_disable(&dis_buf, 7, true))
	testing.expect(t, dis_ok && acc == 7 && on)
}

@(test)
test_devices :: proc(t: ^testing.T) {
	devices: [3]Device
	for &d, i in devices {
		d.key[0] = u8(i + 1)
		d.created = u64(1000 + i)
		d.last_seen = u64(2000 + i)
	}
	devices[0].name = "laptop"
	devices[0].flags = {.Current, .Online}
	devices[1].name = "phone"
	devices[2].name = "a name that is a good deal longer than any device's may be"

	out: [2 + 3 * DEVICE_MAX_SIZE]u8
	body := encode_devices(out[:], devices[:])
	testing.expect(t, body != nil)
	buf: [8]Device
	got, ok := decode_devices(body, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, len(got), 3)
	testing.expect_value(t, got[0].name, "laptop")
	testing.expect_value(t, got[0].flags, Device_Flags{.Current, .Online})
	testing.expect_value(t, got[1].key[0], 2)
	testing.expect_value(t, got[1].created, 1001)
	testing.expect_value(t, got[2].last_seen, 2002)
	testing.expect_value(t, len(got[2].name), MAX_DEVICE_NAME)

	// Room for two takes two.
	body = encode_devices(out[:2 + 2 * DEVICE_MAX_SIZE], devices[:])
	got, ok = decode_devices(body, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, len(got), 2)

	// None at all, more than the reader has room for, and one cut short.
	got, ok = decode_devices([]u8{0, 0}, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, len(got), 0)
	_, ok = decode_devices(body, buf[:1])
	testing.expect(t, !ok)
	_, ok = decode_devices(body[:len(body) - 1], buf[:])
	testing.expect(t, !ok)
}

@(test)
test_settings :: proc(t: ^testing.T) {
	buf: [SETTING_MAX_SIZE]u8
	value := make([]u8, MAX_SETTING_VALUE, context.temp_allocator)
	value[0], value[MAX_SETTING_VALUE - 1] = 1, 2
	key := "user/17.volume-x_012345678901234567890123456789012345678901234567890123456789"
	testing.expect(t, setting_key_ok(key[:MAX_SETTING_KEY]))
	body := encode_setting(buf[:], key[:MAX_SETTING_KEY], value)
	testing.expect_value(t, len(body), SETTING_MAX_SIZE)
	k, v, ok := decode_setting(body)
	testing.expect(t, ok)
	testing.expect_value(t, k, key[:MAX_SETTING_KEY])
	testing.expect_value(t, len(v), MAX_SETTING_VALUE)
	testing.expect(t, v[0] == 1 && v[MAX_SETTING_VALUE - 1] == 2)
	_, _, ok = decode_setting(body[:len(body) - 1])
	testing.expect(t, !ok)
	// Removing one: no value.
	k, v, ok = decode_setting(encode_setting(buf[:], "ui/open", nil))
	testing.expect(t, ok && k == "ui/open" && len(v) == 0)

	testing.expect(t, !setting_key_ok(""))
	testing.expect(t, !setting_key_ok(key))
	testing.expect(t, !setting_key_ok("User/1"))
	testing.expect(t, !setting_key_ok("a b"))
}

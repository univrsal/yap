package proto

/*
An account's settings: what a person has chosen that isn't about one of
their devices (per-user volumes, which conversation was open), kept by
the server so every device of theirs has them. The server keeps them as
they come and doesn't look inside; what they mean is the client's.

	Setting_Set       [key str8][value bytes16]   set one; an empty value
	                                              removes it
	Setting_Changed   [key str8][value bytes16]   one of them, as it is now
	                                              (empty: removed)

A key is 1 to MAX_SETTING_KEY of `a-z 0-9 _ . / -`; a value at most
MAX_SETTING_VALUE bytes; an account has at most MAX_SETTINGS. The login
sync carries every one of them as Setting_Changed, and a change goes to
the account's other connections.
*/

MAX_SETTING_KEY :: 64
MAX_SETTING_VALUE :: 4096
MAX_SETTINGS :: 256
SETTING_MAX_SIZE :: 1 + MAX_SETTING_KEY + 2 + MAX_SETTING_VALUE

// setting_key_ok is whether `key` may be a setting's.
setting_key_ok :: proc(key: string) -> bool {
	if len(key) == 0 || len(key) > MAX_SETTING_KEY {
		return false
	}
	for ch in transmute([]u8)key {
		switch ch {
		case 'a' ..= 'z', '0' ..= '9', '_', '.', '/', '-':
		case:
			return false
		}
	}
	return true
}

// encode_setting writes a Setting_Set or a Setting_Changed.
encode_setting :: proc(out: []u8, key: string, value: []u8) -> []u8 {
	w := Writer {
		buf = out,
	}
	put_str8(&w, key)
	put_u16(&w, u16(len(value)))
	put_bytes(&w, value)
	return nil if w.overflow || len(value) > 0xffff else w.buf[:w.pos]
}

// decode_setting reads one; both point into `body`.
decode_setting :: proc(body: []u8) -> (key: string, value: []u8, ok: bool) {
	r := Reader {
		buf = body,
	}
	key = get_str8(&r)
	n := int(get_u16(&r))
	value = get_bytes(&r, n)
	return key, value, !r.overflow
}

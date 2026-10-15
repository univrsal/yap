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

/*
Whether pushes (push.odin) leave out what a message says, giving only
who wrote and where: "hidden" if so; not set, they say it. The server
reads it, and takes any value; only "hidden" hides.
*/
SETTING_PUSH_TEXT :: "push/text"
PUSH_TEXT_HIDDEN :: "hidden"

/*
A setting the server reads: which mails it sends an account about
what came while it was away (server/digest.odin), if it sends any
(Server_Info.digests). Mentions: unread mentions, and unread direct
messages, which count as mentions; Missed: those, and every other
unread message where the account hears of every message
(Notify_Level.All). Not set is None. A value that isn't one of
EMAIL_DIGEST_NAMES is refused.
*/
SETTING_EMAIL_DIGEST :: "email/digest"

Email_Digest :: enum u8 {
	None,
	Missed,
	Mentions,
}

@(rodata)
EMAIL_DIGEST_NAMES := [Email_Digest]string {
	.None     = "none",
	.Missed   = "missed",
	.Mentions = "mentions",
}

// email_digest_parse reads the setting's value; "" is None.
email_digest_parse :: proc(value: string) -> (d: Email_Digest, ok: bool) {
	if value == "" {
		return .None, true
	}
	for name, choice in EMAIL_DIGEST_NAMES {
		if value == name {
			return choice, true
		}
	}
	return .None, false
}

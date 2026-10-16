package proto

// An account's settings are choices a person made that don't belong to one
// specific device (for example per-user volumes or which conversation was
// open). The server stores them so that every device of that person has
// them. It stores them as received and doesn't interpret them, their meaning
// is up to the client.
//
//	Setting_Set       [key str8][value bytes16]   sets a setting, an empty
//	                                              value removes it
//	Setting_Changed   [key str8][value bytes16]   a setting's current value
//	                                              (empty: removed)
//
// A key is 1 to MAX_SETTING_KEY characters of `a-z 0-9 _ . / -`. A value is
// at most MAX_SETTING_VALUE bytes, and an account has at most MAX_SETTINGS
// settings. The login sync sends every setting as Setting_Changed, and a
// change is sent to the account's other connections.

MAX_SETTING_KEY :: 64
MAX_SETTING_VALUE :: 4096
MAX_SETTINGS :: 256
SETTING_MAX_SIZE :: 1 + MAX_SETTING_KEY + 2 + MAX_SETTING_VALUE

// setting_key_ok says whether `key` is a valid setting key.
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

// encode_setting writes a Setting_Set or Setting_Changed body.
encode_setting :: proc(out: []u8, key: string, value: []u8) -> []u8 {
	w := Writer {
		buf = out,
	}
	put_str8(&w, key)
	put_u16(&w, u16(len(value)))
	put_bytes(&w, value)
	return nil if w.overflow || len(value) > 0xffff else w.buf[:w.pos]
}

// decode_setting reads a setting. The key and value point into `body`.
decode_setting :: proc(body: []u8) -> (key: string, value: []u8, ok: bool) {
	r := Reader {
		buf = body,
	}
	key = get_str8(&r)
	n := int(get_u16(&r))
	value = get_bytes(&r, n)
	return key, value, !r.overflow
}

// Whether push notifications (push.odin) leave out the text of a message and
// only say who wrote it and where: "hidden" if so. If the setting isn't set,
// they include the text. The server reads it and accepts any value, but only
// "hidden" hides the text.
SETTING_PUSH_TEXT :: "push/text"
PUSH_TEXT_HIDDEN :: "hidden"

// Whether everyone is shown that the account is talking in a voice room or
// in a call (User_Flag.In_Voice and .In_Call): "hidden" if not. If the
// setting isn't set, it is shown. The server reads it and accepts any
// value, but only "hidden" hides it.
SETTING_VOICE_SHOWN :: "voice/shown"
VOICE_SHOWN_HIDDEN :: "hidden"

// This is a setting the server reads. It determines which emails the server
// sends an account about what happened while the account was away
// (server/digest.odin), if the server sends any (Server_Info.digests).
// Mentions: unread mentions and unread direct messages, which count as
// mentions. Missed: those plus every other unread message in conversations
// where the account is notified about every message (Notify_Level.All).
// Not set means None. A value that isn't one of EMAIL_DIGEST_NAMES is
// refused.
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

// email_digest_parse reads the setting's value. "" means None.
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

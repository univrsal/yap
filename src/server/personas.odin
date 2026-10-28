package server

import "core:strings"

import "common:proto"
import "sqlite"

// Personas (proto/messages.odin): a bot's message under another name and
// picture. persona_check decides whether a bot may post one.

// persona_check returns the persona that a post asks for, with its name
// cleaned up (it points into `buf`), or the status to refuse it with:
// Denied for an account that isn't a bot, or a name that is any account's
// username or display name, Invalid for a name that is empty once cleaned up,
// and whatever avatar_ok says about the picture.
persona_check :: proc(
	s: ^Server,
	acc: ^Account,
	want: proto.Persona,
	buf: ^[proto.MAX_NAME_SIZE]u8,
) -> (
	persona: proto.Persona,
	status: proto.Status,
) {
	if .Bot not_in acc.flags {
		return {}, .Denied
	}
	name := proto.sanitize_text(want.name, buf[:proto.MAX_PERSONA_NAME_SIZE])
	if name == "" {
		return {}, .Invalid
	}
	for _, other in s.accounts.by_id {
		if strings.equal_fold(other.username, name) || strings.equal_fold(other.display, name) {
			return {}, .Denied
		}
	}
	if want.avatar != 0 {
		if status = avatar_ok(s, want.avatar); status != .Ok {
			return {}, status
		}
	}
	return {name, want.avatar}, .Ok
}

// persona_avatar_known says whether a blob is the picture of a persona that
// some message has, which anyone may fetch like somebody's own picture
// (blob_get_request).
persona_avatar_known :: proc(s: ^Server, blob: proto.Blob_Id) -> bool {
	q := db_query(&s.db, .Persona_Avatar_Used, i64(blob))
	row, ok := db_step(&s.db, q)
	sqlite.reset(q)
	return ok && row
}

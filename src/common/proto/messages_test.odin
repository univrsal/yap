#+build !wasi
package proto

import "core:testing"

@(test)
test_state_roundtrip :: proc(t: ^testing.T) {
	users := []User_Info {
		{num = 1, account = 10, flags = {.Muted}, room = 3},
		{num = 2, account = 10, flags = {.Muted, .Deafened}},
		{num = 7, account = max(Account_Id), room = max(Room)},
	}
	state := Presence {
		your_user = 7,
		users     = users,
	}

	body_buf: [MAX_STATE_SIZE]byte
	body, ok := encode_state(state, body_buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, len(body), 4 + 2 + 3 * USER_SIZE)

	users_buf: [64]User_Info
	got: Presence
	got, ok = decode_state(body, users_buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, got.your_user, 7)
	testing.expect_value(t, len(got.users), 3)
	for u, i in users {
		testing.expect_value(t, got.users[i].num, u.num)
		testing.expect_value(t, got.users[i].account, u.account)
		testing.expect_value(t, got.users[i].flags, u.flags)
		testing.expect_value(t, got.users[i].room, u.room)
	}
	me := find_user(&got, 7)
	testing.expect(t, me != nil && me.account == max(Account_Id))
	testing.expect(t, find_user(&got, 3) == nil)

	// Nobody at all is a snapshot too.
	body, ok = encode_state({your_user = 1}, body_buf[:])
	testing.expect(t, ok)
	got, ok = decode_state(body, users_buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, len(got.users), 0)
}

@(test)
test_state_decode_rejects_garbage :: proc(t: ^testing.T) {
	state := Presence {
		your_user = 1,
		users     = []User_Info{{num = 1, account = 1}, {num = 2, account = 2}},
	}
	body_buf: [MAX_STATE_SIZE]byte
	body, _ := encode_state(state, body_buf[:])

	users_buf: [64]User_Info
	// Truncated, trailing junk, and more users than there's room for.
	_, ok := decode_state(body[:len(body) - 1], users_buf[:])
	testing.expect(t, !ok)
	junk := make([]byte, len(body) + 1, context.temp_allocator)
	copy(junk, body)
	_, ok = decode_state(junk, users_buf[:])
	testing.expect(t, !ok)
	_, ok = decode_state(body, users_buf[:1])
	testing.expect(t, !ok)
	_, ok = decode_state(nil, users_buf[:])
	testing.expect(t, !ok)
}

@(test)
test_state_chunking :: proc(t: ^testing.T) {
	// Big enough to need several chunks.
	users: [100]User_Info
	for &u, i in users {
		u = {
			num     = User_Num(i + 1),
			account = Account_Id(i + 1),
			room    = Room(i % 5),
		}
	}
	state := Presence {
		your_user = 63,
		users     = users[:],
	}

	body_buf: [MAX_STATE_SIZE]byte
	body, ok := encode_state(state, body_buf[:])
	testing.expect(t, ok)
	count := state_chunk_count(len(body))
	testing.expect(t, count > 1)

	chunk_bufs := make([][MAX_PAYLOAD_SIZE]byte, count, context.temp_allocator)
	chunks := make([][]byte, count, context.temp_allocator)
	for i in 0 ..< count {
		chunks[i] = encode_state_chunk(chunk_bufs[i][:], 9, body, i)
		kind, kind_ok := message_kind(chunks[i])
		testing.expect(t, kind_ok && kind == .State)
		testing.expect(t, len(chunks[i]) <= MAX_PAYLOAD_SIZE)
	}

	a := new(State_Assembler, context.temp_allocator)
	// Out of order, with a duplicate; completes only on the last new chunk.
	order := make([dynamic]int, context.temp_allocator)
	for i := count - 1; i >= 0; i -= 1 {
		append(&order, i)
	}
	append(&order, 0)
	complete_at := -1
	got_body: []byte
	for idx, n in order {
		version, b, complete := assembler_add(a, chunks[idx], 0)
		if complete {
			testing.expect_value(t, version, 9)
			complete_at, got_body = n, b
			break
		}
	}
	testing.expect_value(t, complete_at, count - 1)
	testing.expect_value(t, string(got_body), string(body))

	// Chunks of a version the caller already has are ignored.
	_, _, complete := assembler_add(a, chunks[0], 9)
	testing.expect(t, !complete)

	// As many as a snapshot can hold still fit in one.
	most := make([]User_Info, MAX_STATE_USERS, context.temp_allocator)
	_, ok = encode_state({users = most}, body_buf[:])
	testing.expect(t, ok)
}

@(test)
test_assembler_prefers_newer_version :: proc(t: ^testing.T) {
	body_buf: [MAX_STATE_SIZE]byte
	body, _ := encode_state(Presence{your_user = 1}, body_buf[:])

	old_buf, new_buf: [MAX_PAYLOAD_SIZE]byte
	older := encode_state_chunk(old_buf[:], 1, body, 0)
	newer := encode_state_chunk(new_buf[:], 2, body, 0)

	a := new(State_Assembler, context.temp_allocator)
	version, _, complete := assembler_add(a, newer, 0)
	testing.expect(t, complete && version == 2)
	// A late snapshot older than the one applied is ignored.
	_, _, complete = assembler_add(a, older, 2)
	testing.expect(t, !complete)
}

@(test)
test_serial_newer :: proc(t: ^testing.T) {
	testing.expect(t, serial_newer(2, 1))
	testing.expect(t, !serial_newer(1, 1))
	testing.expect(t, !serial_newer(1, 2))
	testing.expect(t, serial_newer(0, max(u32))) // wraps
}

@(test)
test_ack_encoding :: proc(t: ^testing.T) {
	ab: [STATE_ACK_SIZE]byte
	msg := encode_state_ack(&ab, 5)
	kind, ok := message_kind(msg)
	testing.expect(t, ok && kind == .State_Ack)
	testing.expect_value(t, decode_state_ack(msg), 5)

	// Join is retired: nothing that claims to be one is taken.
	_, ok = message_kind([]u8{u8(Message_Kind.Join), 0, 0, 0, 0, 0, 0})
	testing.expect(t, !ok)
}

@(test)
test_sanitize_name :: proc(t: ^testing.T) {
	cases := [?]struct {
		input, want: string,
	} {
		{"alice", "alice"},
		{"  padded \t", "padded"},
		{"tab\there", "tab here"},
		{"new\nline\x00", "new line"},
		{"Zoë ☕", "Zoë ☕"},
		{"bad\xffutf8", "badutf8"},
		// Right-to-left override and zero-width space, used for spoofing.
		{"ev\u202eil\u200bname", "evilname"},
		// Cut at 32 bytes without splitting a character (é is 2 bytes).
		{"0123456789012345678901234567890é", "0123456789012345678901234567890"},
		{"", ""},
		{"   ", ""},
	}
	for c in cases {
		buf: [MAX_NAME_SIZE]u8
		testing.expect_value(t, sanitize_name(c.input, &buf), c.want)
	}
}

@(test)
test_hello_and_welcome :: proc(t: ^testing.T) {
	hb: [HELLO_MAX_SIZE]u8
	conn_id, password, ok := decode_hello(encode_hello(&hb, 7))
	testing.expect(t, ok)
	testing.expect_value(t, conn_id, 7)
	testing.expect_value(t, password, "")

	conn_id, password, ok = decode_hello(encode_hello(&hb, max(u64), "hunter2"))
	testing.expect(t, ok)
	testing.expect_value(t, conn_id, max(u64))
	testing.expect_value(t, password, "hunter2")

	// The longest still fits.
	long_password := "0123456789012345678901234567890123456789012345678901234567890123456789"
	_, password, ok = decode_hello(encode_hello(&hb, 1, long_password))
	testing.expect(t, ok)
	testing.expect_value(t, password, long_password[:MAX_PASSWORD_SIZE])

	_, _, ok = decode_hello(nil) // no hello at all: no conn_id
	testing.expect(t, !ok)
	id :: [8]u8{1, 2, 3, 4, 5, 6, 7, 8}
	hello :: proc(version: u8, rest: ..u8) -> []u8 {
		out := make([dynamic]u8, context.temp_allocator)
		append(&out, version)
		conn := id
		append(&out, ..conn[:])
		append(&out, ..rest)
		return out[:]
	}
	_, _, ok = decode_hello(hello(HELLO_VERSION, 1, 'a'))
	testing.expect(t, ok)
	_, _, ok = decode_hello(hello(HELLO_VERSION + 1, 0)) // unknown version
	testing.expect(t, !ok)
	_, _, ok = decode_hello(hello(5, 1, 'a', 0)) // version 5: with a name
	testing.expect(t, !ok)
	_, _, ok = decode_hello(hello(HELLO_VERSION, 2, 'x')) // truncated password
	testing.expect(t, !ok)
	_, _, ok = decode_hello(hello(HELLO_VERSION, 0, 'x')) // trailing bytes
	testing.expect(t, !ok)

	wb: [WELCOME_SIZE]u8
	welcome := encode_welcome(&wb, 0x1122334455667788, false)
	kind, kind_ok := message_kind(welcome)
	testing.expect(t, kind_ok && kind == .Welcome)
	instance, logged_in := decode_welcome(welcome)
	testing.expect_value(t, instance, 0x1122334455667788)
	testing.expect(t, !logged_in)
	_, logged_in = decode_welcome(encode_welcome(&wb, 1, true))
	testing.expect(t, logged_in)

	rb: [REFUSED_SIZE]u8
	refused := encode_refused(&rb, .Wrong_Password)
	kind, kind_ok = message_kind(refused)
	testing.expect(t, kind_ok && kind == .Refused)
	testing.expect_value(t, decode_refused(refused), Refusal.Wrong_Password)

	// Set_Name is retired: nothing that claims to be one is taken.
	_, kind_ok = message_kind([]u8{u8(Message_Kind.Set_Name), 1, 'a'})
	testing.expect(t, !kind_ok)
}

@(test)
test_sound_roundtrip :: proc(t: ^testing.T) {
	for flags in ([]User_Flags{{}, {.Muted}, {.Deafened}, {.Muted, .Deafened}}) {
		buf: [SOUND_SIZE]byte
		pt := encode_sound(&buf, flags)
		kind, ok := message_kind(pt)
		testing.expect(t, ok)
		testing.expect_value(t, kind, Message_Kind.Sound)
		testing.expect_value(t, decode_sound(pt), flags)
	}
	// A flag a newer client knows about and this build doesn't survives
	// the trip, rather than turning into something we do know.
	unknown := [SOUND_SIZE]byte{u8(Message_Kind.Sound), 0x80}
	kept := decode_sound(unknown[:])
	testing.expect(t, .Muted not_in kept && .Deafened not_in kept)
	buf: [SOUND_SIZE]byte
	testing.expect_value(t, encode_sound(&buf, kept)[1], 0x80)
}

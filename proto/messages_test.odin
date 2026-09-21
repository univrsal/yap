#+build !wasi
package proto

import "core:fmt"
import "core:testing"

@(private = "file")
decode_bufs :: struct {
	users:    [64]User_Info,
	channels: [MAX_CHANNELS]Channel_Info,
	members:  [1024]u32,
}

@(test)
test_state_roundtrip :: proc(t: ^testing.T) {
	users := []User_Info {
		{num = 1, key = {0 = 0xaa, 31 = 0x01}, name = "alice", flags = {.Muted}},
		{num = 2, key = {0 = 0xbb, 31 = 0x02}, name = "", flags = {.Muted, .Deafened}},
		{num = 7, key = {0 = 0xcc, 31 = 0x03}, name = "Zoë"},
	}
	channels := []Channel_Info {
		{name = "Lobby", members = {1, 2}},
		{name = "Empty"},
		{name = "Gaming", members = {7}},
	}
	state := Channel_State {
		your_channel = 2,
		your_user    = 7,
		join_ack     = 7,
		users        = users,
		channels     = channels,
	}

	body_buf: [MAX_STATE_SIZE]byte
	body, ok := encode_state(state, body_buf[:])
	testing.expect(t, ok)

	bufs: decode_bufs
	got: Channel_State
	got, ok = decode_state(body, bufs.users[:], bufs.channels[:], bufs.members[:])
	testing.expect(t, ok)
	testing.expect_value(t, got.your_channel, 2)
	testing.expect_value(t, got.your_user, 7)
	testing.expect_value(t, got.join_ack, 7)
	testing.expect_value(t, len(got.users), 3)
	for u, i in users {
		testing.expect_value(t, got.users[i].num, u.num)
		testing.expect_value(t, got.users[i].key, u.key)
		testing.expect_value(t, got.users[i].name, u.name)
		testing.expect_value(t, got.users[i].flags, u.flags)
	}
	testing.expect_value(t, len(got.channels), 3)
	for ch, i in channels {
		testing.expect_value(t, got.channels[i].name, ch.name)
		testing.expect_value(t, len(got.channels[i].members), len(ch.members))
		for m, j in ch.members {
			testing.expect_value(t, got.channels[i].members[j], m)
		}
	}
	me := find_user(&got, 7)
	testing.expect(t, me != nil && me.name == "Zoë")
	testing.expect(t, find_user(&got, 3) == nil)
}

@(test)
test_state_decode_rejects_garbage :: proc(t: ^testing.T) {
	state := Channel_State {
		channels = []Channel_Info{{name = "Lobby", members = {1, 2}}},
	}
	body_buf: [MAX_STATE_SIZE]byte
	body, _ := encode_state(state, body_buf[:])

	bufs: decode_bufs
	// Truncated, trailing junk, and your_channel out of range.
	_, ok := decode_state(body[:len(body) - 1], bufs.users[:], bufs.channels[:], bufs.members[:])
	testing.expect(t, !ok)
	junk := make([]byte, len(body) + 1, context.temp_allocator)
	copy(junk, body)
	_, ok = decode_state(junk, bufs.users[:], bufs.channels[:], bufs.members[:])
	testing.expect(t, !ok)
	body[0] = 5
	_, ok = decode_state(body, bufs.users[:], bufs.channels[:], bufs.members[:])
	testing.expect(t, !ok)
}

@(test)
test_state_chunking :: proc(t: ^testing.T) {
	// Big enough to need several chunks.
	channels: [MAX_CHANNELS]Channel_Info
	members: [256]u32
	for &m, i in members {
		m = u32(i)
	}
	for &ch, i in channels {
		ch.name = fmt.tprintf("channel-with-a-long-name-%02d", i)
		ch.members = members[i * 4:][:4]
	}
	state := Channel_State {
		your_channel = 63,
		join_ack     = 1,
		channels     = channels[:],
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
}

@(test)
test_assembler_prefers_newer_version :: proc(t: ^testing.T) {
	body_buf: [MAX_STATE_SIZE]byte
	body, _ := encode_state(Channel_State{channels = []Channel_Info{{name = "a"}}}, body_buf[:])

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
test_join_and_ack_encoding :: proc(t: ^testing.T) {
	jb: [JOIN_SIZE]byte
	msg := encode_join(&jb, 0xdeadbeef, 42)
	kind, ok := message_kind(msg)
	testing.expect(t, ok && kind == .Join)
	request, channel := decode_join(msg)
	testing.expect_value(t, request, 0xdeadbeef)
	testing.expect_value(t, channel, 42)

	ab: [STATE_ACK_SIZE]byte
	msg = encode_state_ack(&ab, 5)
	kind, ok = message_kind(msg)
	testing.expect(t, ok && kind == .State_Ack)
	testing.expect_value(t, decode_state_ack(msg), 5)
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
test_hello_and_set_name :: proc(t: ^testing.T) {
	hb: [HELLO_MAX_SIZE]u8
	name, ok := decode_hello(encode_hello(&hb, "alice"))
	testing.expect(t, ok)
	testing.expect_value(t, name, "alice")

	name, ok = decode_hello(nil) // no hello at all: fine, no name
	testing.expect(t, ok)
	testing.expect_value(t, name, "")
	_, ok = decode_hello([]u8{9, 0}) // unknown version
	testing.expect(t, !ok)
	_, ok = decode_hello([]u8{HELLO_VERSION, 10, 'a'}) // truncated
	testing.expect(t, !ok)

	sb: [SET_NAME_MAX_SIZE]u8
	msg := encode_set_name(&sb, "bob")
	kind, kind_ok := message_kind(msg)
	testing.expect(t, kind_ok && kind == .Set_Name)
	testing.expect_value(t, decode_set_name(msg), "bob")
	// A length byte that doesn't match the message is rejected.
	msg[1] = 7
	_, kind_ok = message_kind(msg)
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

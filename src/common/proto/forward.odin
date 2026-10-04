package proto

import "core:strconv"
import "core:strings"

/*
Forwarding messages and linking to them (polish 12).

	Msg_Forward  [conv u32][nonce u64][thread_root u64][msg u64]
	             ->  [id u64][time u64], as Msg_Post

Forwarding copies a message somewhere else: one the account may read,
to a conversation it may post to, whichever two. The copy is a message
of the forwarder's whose content (text, or picture: the same blob) is
the original's, with the Forwarded flag and, in its record, who wrote
the original, where and when:

	if Forwarded:  [sender u32][conv u32][time u64]

A copy of a copy names the first. Only text and pictures can be
forwarded (`Invalid` otherwise, or for one deleted or whose picture
is gone); a copy's mentions don't mention anybody again, and it can't
be edited.

A link is a token in a message's text,

	<msg:12:3456>   message 3456 of conversation 12

which a client shows as the message it points at, if it may read it,
and goes to when it's clicked. A link to a DM's message is only kept in
that DM: anywhere else the server writes it as plain text
(links_restrict, server/messages.odin).
*/

MSG_FORWARD_SIZE :: 4 + 8 + 8 + 8
FORWARD_INFO_SIZE :: 4 + 4 + 8

Msg_Forward :: struct {
	conv:        Conv_Id,
	nonce:       u64,
	thread_root: Msg_Id,
	msg:         Msg_Id,
}

// Forward_Info is where a forwarded message came from.
Forward_Info :: struct {
	sender: Account_Id,
	conv:   Conv_Id,
	time:   Unix_Ms,
}

encode_msg_forward :: proc(out: ^[MSG_FORWARD_SIZE]u8, f: Msg_Forward) -> []u8 {
	w := Writer {
		buf = out[:],
	}
	put_u32(&w, u32(f.conv))
	put_u64(&w, f.nonce)
	put_u64(&w, u64(f.thread_root))
	put_u64(&w, u64(f.msg))
	return out[:]
}

decode_msg_forward :: proc(body: []u8) -> (f: Msg_Forward, ok: bool) {
	r := Reader {
		buf = body,
	}
	f.conv = Conv_Id(get_u32(&r))
	f.nonce = get_u64(&r)
	f.thread_root = Msg_Id(get_u64(&r))
	f.msg = Msg_Id(get_u64(&r))
	return f, !r.overflow && f.nonce != 0 && f.msg != 0
}

LINK_PREFIX :: "<msg:"

// Msg_Link is a link token found in a text.
Msg_Link :: struct {
	start, end: int, // the token's bytes
	conv:       Conv_Id,
	id:         Msg_Id,
}

// link_token writes a link to message `id` of `conv`, in the temp
// allocator.
link_token :: proc(conv: Conv_Id, id: Msg_Id) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, LINK_PREFIX)
	strings.write_u64(&b, u64(conv))
	strings.write_byte(&b, ':')
	strings.write_u64(&b, u64(id))
	strings.write_byte(&b, '>')
	return strings.to_string(b)
}

// next_link finds the first link token in text[from:]; ok is false if
// there's none. Anything that only looks a little like one is text.
next_link :: proc(text: string, from: int) -> (l: Msg_Link, ok: bool) {
	at := from
	for at < len(text) {
		i := strings.index(text[at:], LINK_PREFIX)
		if i < 0 {
			return
		}
		start := at + i
		inside_from := start + len(LINK_PREFIX)
		close := strings.index_byte(text[inside_from:], '>')
		if close >= 0 && close <= 32 {
			inside := text[inside_from:][:close]
			if colon := strings.index_byte(inside, ':'); colon > 0 {
				conv_text, id_text := inside[:colon], inside[colon + 1:]
				if all_digits(conv_text) &&
				   all_digits(id_text) &&
				   len(conv_text) <= 10 &&
				   len(id_text) <= 20 {
					c, c_ok := strconv.parse_u64_of_base(conv_text, 10)
					m, m_ok := strconv.parse_u64_of_base(id_text, 10)
					if c_ok && m_ok && c > 0 && c <= u64(max(Conv_Id)) && m > 0 {
						return {
								start = start,
								end = inside_from + close + 1,
								conv = Conv_Id(c),
								id = Msg_Id(m),
							},
							true
					}
				}
			}
		}
		at = start + len(LINK_PREFIX)
	}
	return
}

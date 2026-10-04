package proto

import "core:encoding/endian"

/*
Attachments: files uploaded to the server with a message, in a channel
or a DM, and kept there until the message is deleted (msgs.odin says how
a message carries them). Unlike a DM's file (files.odin), which goes
from one client to the other and is never kept, an attachment is
uploaded once and fetched by any member, any time.

	Attach_Put  [size u64][name str8]  ->  [upload u64]
	Attach_Get  [blob u64]             ->  [size u64][download u64]

	client -> server  Upload_Chunk, Download_Ack   (transfer.odin)
	server -> client  Upload_Ack, Download_Chunk
	either way        Transfer_Cancel [kind][id u64][reason u8]

Uploading: Attach_Put says how big the file is and what it's called,
and is answered with the upload's id, which its chunks go under
(Upload_Chunk) and the server's acks come under (Upload_Ack). Once the
server has all of it, and has kept it, its ack says complete; the
message is then posted naming the upload (Msg_Post), and gets the file's
name and size from it. An upload may be named by the account that made
it, for an hour after it's complete; a file uploaded twice is kept once.

Fetching: Attach_Get, by a member of a conversation with a message that
has the file, is answered with its size and the download's id, whose
chunks the server sends (Download_Chunk) and the client acks
(Download_Ack).

Either side stops a transfer with Transfer_Cancel; a transfer that
hears nothing for ATTACH_IDLE is dropped. Each connection has at most
MAX_ATTACH_TRANSFERS uploads and as many downloads at once (Rate_Limited
past that). The server says how big a file may be in Server_Info
(`max_attachment`, 0 when it takes none); past that Attach_Put is
Too_Large. Attaching takes the Attach_Files permission.
*/

// At most this many uploads, and this many downloads, per connection.
MAX_ATTACH_TRANSFERS :: 4

ATTACH_PUT_MAX_SIZE :: 8 + 1 + MAX_FILE_NAME
ATTACH_PUT_ANSWER_SIZE :: 8
ATTACH_GET_SIZE :: 8
ATTACH_GET_ANSWER_SIZE :: 8 + 8

Attach_Put :: struct {
	size: u64,
	name: string, // raw until sanitized
}

encode_attach_put :: proc(out: []u8, p: Attach_Put) -> []u8 {
	w := Writer {
		buf = out,
	}
	put_u64(&w, p.size)
	put_str8(&w, p.name)
	return nil if w.overflow || len(p.name) > MAX_FILE_NAME else out[:w.pos]
}

decode_attach_put :: proc(body: []u8) -> (p: Attach_Put, ok: bool) {
	r := Reader {
		buf = body,
	}
	p.size = get_u64(&r)
	p.name = get_str8(&r)
	return p, !r.overflow && r.pos == len(body) && len(p.name) <= MAX_FILE_NAME
}

encode_attach_id :: proc(out: ^[8]u8, id: u64) -> []u8 {
	endian.unchecked_put_u64le(out[:], id)
	return out[:]
}

decode_attach_id :: proc(body: []u8) -> (id: u64, ok: bool) {
	if len(body) != 8 {
		return
	}
	return endian.unchecked_get_u64le(body), true
}

encode_attach_get_answer :: proc(
	out: ^[ATTACH_GET_ANSWER_SIZE]u8,
	size: u64,
	download: u64,
) -> []u8 {
	endian.unchecked_put_u64le(out[0:], size)
	endian.unchecked_put_u64le(out[8:], download)
	return out[:]
}

decode_attach_get_answer :: proc(body: []u8) -> (size: u64, download: u64, ok: bool) {
	if len(body) != ATTACH_GET_ANSWER_SIZE {
		return
	}
	return endian.unchecked_get_u64le(body[0:]), endian.unchecked_get_u64le(body[8:]), true
}

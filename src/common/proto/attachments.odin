package proto

import "core:encoding/endian"

// Attachments: files that are uploaded to the server together with a message
// in a channel or a DM. They are kept until the message is deleted (messages.odin
// describes how a message carries them). A file sent in a DM (files.odin) goes
// directly from one client to the other and is never stored. An attachment is
// uploaded once instead and can be fetched by any member at any time.
//
// 	Attach_Put  [size u64][name str8]  ->  [upload u64]
// 	Attach_Get  [blob u64][variant u8] ->  [size u64][download u64]
//
// 	client -> server  Upload_Chunk, Download_Ack   (transfer.odin)
// 	server -> client  Upload_Ack, Download_Chunk
// 	either way        Transfer_Cancel [kind][id u64][reason u8]
//
// Uploading: Attach_Put states the size and name of the file. The answer is
// the upload's id, which the chunks are sent under (Upload_Chunk) and which the
// server's acks refer to (Upload_Ack). Once the server has received and stored
// the whole file, its ack says complete. The message is then posted with a
// reference to the upload (Msg_Post), and takes the file's name and size from
// it. The account that made an upload may reference it for an hour after it is
// complete. A file that is uploaded twice is only stored once.
//
// Fetching: Attach_Get is sent by a member of a conversation that has a message
// with the file. It is answered with the file's size and the download's id. The
// server then sends the chunks (Download_Chunk) and the client acknowledges them
// (Download_Ack).
//
// The variant says which form of the file is wanted: the file as it was
// uploaded (Original, 0) or, for a picture, its thumbnail (Thumbnail, 1: a
// small WebP made by the server, thumbnails.odin). A picture that has no
// thumbnail (too small to need one, an animation, not made yet or not made at
// all) is answered with the original, so a client asks for the thumbnail
// whenever it wants to show the picture small and finds out from the size in
// the answer what it gets. The variant is optional: a request of only the blob
// is for the original. An unknown variant is Invalid. Whether a member may
// fetch is decided by the original, which is the blob that messages name.
// There is no flag in Server_Info for this: the hello version (hello.odin) is
// how clients and servers that don't agree on the protocol are told apart.
//
// Either side can stop a transfer with Transfer_Cancel. A transfer that hears
// nothing for ATTACH_IDLE is dropped. Each connection may have at most
// MAX_ATTACH_TRANSFERS uploads and as many downloads at once (beyond that the
// answer is Rate_Limited). The server states the maximum file size in
// Server_Info (`max_attachment`, which is 0 if it accepts no attachments).
// Attach_Put for a larger file is answered with Too_Large. Attaching files
// requires the Attach_Files permission.

// The maximum number of uploads, and also of downloads, per connection.
MAX_ATTACH_TRANSFERS :: 4

ATTACH_PUT_MAX_SIZE :: 8 + 1 + MAX_FILE_NAME
ATTACH_PUT_ANSWER_SIZE :: 8
ATTACH_GET_ANSWER_SIZE :: 8 + 8
ATTACH_GET_SIZE :: 8 + 1

// The forms of an attachment that can be fetched (see above).
Attach_Variant :: enum u8 {
	Original  = 0,
	Thumbnail = 1,
}

Attach_Put :: struct {
	size: u64,
	name: string, // raw until it is sanitized
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
	return id_put(out[:], id)
}

decode_attach_id :: proc(body: []u8) -> (id: u64, ok: bool) {
	return id_get(u64, body)
}

// encode_attach_get is the body of an Attach_Get request.
encode_attach_get :: proc(out: ^[ATTACH_GET_SIZE]u8, blob: u64, variant: Attach_Variant) -> []u8 {
	endian.unchecked_put_u64le(out[0:], blob)
	out[8] = u8(variant)
	return out[:]
}

// decode_attach_get reads an Attach_Get request: the blob and the variant,
// which is Original if the request leaves it out. `ok` is false for a request of
// another size or with a variant that isn't known.
decode_attach_get :: proc(body: []u8) -> (blob: u64, variant: Attach_Variant, ok: bool) {
	if len(body) != 8 && len(body) != ATTACH_GET_SIZE {
		return
	}
	blob = endian.unchecked_get_u64le(body[0:])
	if len(body) == ATTACH_GET_SIZE {
		if body[8] > u8(max(Attach_Variant)) {
			return
		}
		variant = Attach_Variant(body[8])
	}
	return blob, variant, true
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

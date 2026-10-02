package proto

import "core:encoding/endian"
import "core:strings"
import "core:unicode/utf8"

/*
File transfers in direct messages.

A file is offered in a DM, as a message of kind File (msgs.odin) that
says what it is: its name and size. The transfer's id is that message's.
If the recipient accepts, the two clients move it through the server,
which only relays and never keeps any of it:

	recipient -> server -> sender     File_Accept  [kind][id u64][account u32][max rate u32]
	sender -> server -> recipient     File_Chunk   [kind][id u64][index u32][data]
	recipient -> server -> sender     File_Ack     [kind][id u64][max rate u32][base u32][highest u32][flags u8][count u16][missing u32...]
	either -> server -> the other     File_Cancel  [kind][id u64][account u32][reason u8]

`account` is the other party's on the way up and the one it came from
on the way down, as the server fills in who sent it. The file is on the
device that offered it, and an account may have several: the server
remembers which connection posted the offer, and sets a transfer up
between it and the connection of the recipient's account that accepts,
as long as the one that offered is still here. It relays File_Chunk
only from that one and File_Ack only from the one that accepted, and
drops the transfer when either cancels, leaves, or it has been quiet
for FILE_IDLE. The recipient's other connections are told the offer was
taken elsewhere (Elsewhere), whether it was accepted or declined.

The file is cut into chunks of FILE_CHUNK_DATA bytes, chunk i starting
at byte i * FILE_CHUNK_DATA. They aren't sealed between the two clients
any more: the server may read DMs (D1), and each leg is encrypted
between a client and the server like everything else.

Nothing here is reliable on its own. The recipient resends File_Accept
until chunks come, and sends File_Ack every FILE_ACK_INTERVAL while the
transfer runs: everything below `base` has arrived, `highest` is the
highest index that has, and `missing` lists chunks from `base` on that
haven't (as many as fit). The sender sends each chunk once, within
FILE_WINDOW chunks of `base`, then whatever is listed missing, paced to
the lower of its own limit and the recipient's `max rate` (bytes per
second, 0 for no limit). Once everything's there, File_Ack carries
FILE_ACK_COMPLETE, a few times over, and both are done.
*/

MAX_FILE_NAME :: 200 // bytes of UTF-8

FILE_ACCEPT_SIZE :: 1 + 8 + 4 + 4
FILE_CHUNK_HEADER_SIZE :: 1 + 8 + 4
FILE_CHUNK_DATA :: MAX_PAYLOAD_SIZE - FILE_CHUNK_HEADER_SIZE
FILE_ACK_HEADER_SIZE :: 1 + 8 + 4 + 4 + 4 + 1 + 2
FILE_ACK_MAX_MISSING :: (MAX_PAYLOAD_SIZE - FILE_ACK_HEADER_SIZE) / 4
FILE_CANCEL_SIZE :: 1 + 8 + 4 + 1

FILE_ACK_COMPLETE :: 1 << 0

// Chunks ahead of the recipient's `base` a sender may have out at once.
FILE_WINDOW :: 1024

// Why a transfer ended early.
File_Cancel_Reason :: enum u8 {
	Declined  = 1, // the recipient said no
	Cancelled = 2, // either side stopped it
	Gone      = 3, // the other side left, or the offer isn't there any more
	Expired   = 4, // the sender doesn't have the offer any more (a restart)
	Failed    = 5, // the file couldn't be read or written
	Elsewhere = 6, // another device of the recipient's answered it
}

file_chunk_count :: proc(size: u64) -> u32 {
	return u32((size + FILE_CHUNK_DATA - 1) / FILE_CHUNK_DATA)
}

// file_chunk_range is the part of a file chunk `index` carries.
file_chunk_range :: proc(size: u64, index: u32) -> (start, end: u64) {
	start = u64(index) * FILE_CHUNK_DATA
	return start, min(start + FILE_CHUNK_DATA, size)
}

encode_file_accept :: proc(
	out: ^[FILE_ACCEPT_SIZE]u8,
	id: Msg_Id,
	account: Account_Id,
	max_rate: u32,
) -> []u8 {
	out[0] = u8(Message_Kind.File_Accept)
	endian.unchecked_put_u64le(out[1:], u64(id))
	endian.unchecked_put_u32le(out[9:], u32(account))
	endian.unchecked_put_u32le(out[13:], max_rate)
	return out[:]
}

decode_file_accept :: proc(pt: []u8) -> (id: Msg_Id, account: Account_Id, max_rate: u32) {
	id = Msg_Id(endian.unchecked_get_u64le(pt[1:]))
	account = Account_Id(endian.unchecked_get_u32le(pt[9:]))
	max_rate = endian.unchecked_get_u32le(pt[13:])
	return
}

// set_file_message_account replaces the account in a File_Accept or
// File_Cancel, which the server does before passing one on.
set_file_message_account :: proc(pt: []u8, account: Account_Id) {
	endian.unchecked_put_u32le(pt[9:], u32(account))
}

encode_file_chunk :: proc(out: []u8, id: Msg_Id, index: u32, data: []u8) -> []u8 {
	out[0] = u8(Message_Kind.File_Chunk)
	endian.unchecked_put_u64le(out[1:], u64(id))
	endian.unchecked_put_u32le(out[9:], index)
	n := copy(out[FILE_CHUNK_HEADER_SIZE:], data)
	return out[:FILE_CHUNK_HEADER_SIZE + n]
}

decode_file_chunk :: proc(pt: []u8) -> (id: Msg_Id, index: u32, data: []u8) {
	return Msg_Id(endian.unchecked_get_u64le(pt[1:])),
		endian.unchecked_get_u32le(pt[9:]),
		pt[FILE_CHUNK_HEADER_SIZE:]
}

// file_message_id is the transfer a File_* message is about.
file_message_id :: proc(pt: []u8) -> Msg_Id {
	return Msg_Id(endian.unchecked_get_u64le(pt[1:]))
}

File_Ack :: struct {
	id:       Msg_Id,
	max_rate: u32,
	base:     u32,
	highest:  u32,
	complete: bool,
}

// encode_file_ack writes as many of `missing` as fit.
encode_file_ack :: proc(out: []u8, ack: File_Ack, missing: []u32) -> []u8 {
	count := min(len(missing), FILE_ACK_MAX_MISSING, (len(out) - FILE_ACK_HEADER_SIZE) / 4)
	out[0] = u8(Message_Kind.File_Ack)
	endian.unchecked_put_u64le(out[1:], u64(ack.id))
	endian.unchecked_put_u32le(out[9:], ack.max_rate)
	endian.unchecked_put_u32le(out[13:], ack.base)
	endian.unchecked_put_u32le(out[17:], ack.highest)
	out[21] = FILE_ACK_COMPLETE if ack.complete else 0
	endian.unchecked_put_u16le(out[22:], u16(count))
	for i in 0 ..< count {
		endian.unchecked_put_u32le(out[FILE_ACK_HEADER_SIZE + i * 4:], missing[i])
	}
	return out[:FILE_ACK_HEADER_SIZE + count * 4]
}

// decode_file_ack returns the missing indices as the raw bytes they are
// in the packet; read them with file_ack_missing.
@(require_results)
decode_file_ack :: proc(pt: []u8) -> (ack: File_Ack, count: int, missing: []u8, ok: bool) {
	ack.id = Msg_Id(endian.unchecked_get_u64le(pt[1:]))
	ack.max_rate = endian.unchecked_get_u32le(pt[9:])
	ack.base = endian.unchecked_get_u32le(pt[13:])
	ack.highest = endian.unchecked_get_u32le(pt[17:])
	ack.complete = pt[21] & FILE_ACK_COMPLETE != 0
	count = int(endian.unchecked_get_u16le(pt[22:]))
	if len(pt) != FILE_ACK_HEADER_SIZE + count * 4 {
		return
	}
	return ack, count, pt[FILE_ACK_HEADER_SIZE:], true
}

file_ack_missing :: proc(missing: []u8, i: int) -> u32 {
	return endian.unchecked_get_u32le(missing[i * 4:])
}

encode_file_cancel :: proc(
	out: ^[FILE_CANCEL_SIZE]u8,
	id: Msg_Id,
	account: Account_Id,
	reason: File_Cancel_Reason,
) -> []u8 {
	out[0] = u8(Message_Kind.File_Cancel)
	endian.unchecked_put_u64le(out[1:], u64(id))
	endian.unchecked_put_u32le(out[9:], u32(account))
	out[13] = u8(reason)
	return out[:]
}

// decode_file_cancel may return a reason this build has no name for.
decode_file_cancel :: proc(pt: []u8) -> (id: Msg_Id, account: Account_Id, reason: File_Cancel_Reason) {
	id = Msg_Id(endian.unchecked_get_u64le(pt[1:]))
	account = Account_Id(endian.unchecked_get_u32le(pt[9:]))
	reason = File_Cancel_Reason(pt[13])
	return
}

/*
What may be sent: archives, pictures and videos, told apart by their
extension. The receiving side checks it again before accepting, so
nothing it could run by mistake lands in its downloads.
*/
FILE_EXTENSIONS := [?]string {
	// Archives
	"zip",
	"rar",
	"7z",
	"tar",
	"gz",
	"tgz",
	"bz2",
	"tbz2",
	"xz",
	"txz",
	"zst",
	"lz",
	"lzma",
	"cab",
	"iso",
	// Pictures
	"png",
	"jpg",
	"jpeg",
	"gif",
	"webp",
	"bmp",
	"tif",
	"tiff",
	"heic",
	"heif",
	"avif",
	"ico",
	"psd",
	"raw",
	// Videos
	"mp4",
	"m4v",
	"mkv",
	"webm",
	"mov",
	"avi",
	"wmv",
	"flv",
	"mpg",
	"mpeg",
	"ts",
	"m2ts",
	"3gp",
	"ogv",
	// Audio
	"mp3",
	"m4a",
	"flac",
	"wav",
	"ogg",
	"opus",
	"aac",
	"wma",
	"alac",
}

// file_type_allowed is whether a file called `name` may be sent.
file_type_allowed :: proc(name: string) -> bool {
	dot := strings.last_index_byte(name, '.')
	if dot < 0 || dot == len(name) - 1 {
		return false
	}
	ext := name[dot + 1:]
	for allowed in FILE_EXTENSIONS {
		if strings.equal_fold(ext, allowed) {
			return true
		}
	}
	return false
}

/*
sanitize_file_name makes a name safe to save under: no directories, no
characters a file system would refuse (or take as something else), no
leading dots, and at most MAX_FILE_NAME bytes, keeping the extension.
Empty if nothing's left of it. The result points into `buf`.
*/
sanitize_file_name :: proc(name: string, buf: ^[MAX_FILE_NAME]u8) -> string {
	// Only the last part of a path.
	name := name
	if i := strings.last_index_any(name, "/\\"); i >= 0 {
		name = name[i + 1:]
	}
	tmp: [MAX_FILE_NAME * 2]u8
	clean := sanitize_text(name, tmp[:])
	n := 0
	for r in clean {
		switch r {
		case '<', '>', ':', '"', '|', '?', '*':
			continue
		}
		size := utf8.rune_size(r)
		if n + size > MAX_FILE_NAME {
			break
		}
		utf8_buf, w := utf8.encode_rune(r)
		copy(buf[n:], utf8_buf[:w])
		n += w
	}
	return strings.trim(string(buf[:n]), " .")
}

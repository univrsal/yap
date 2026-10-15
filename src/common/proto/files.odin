package proto

import "core:encoding/endian"
import "core:strings"
import "core:unicode/utf8"

// File transfers in direct messages.
//
// A file is offered in a DM as a message of kind File (msgs.odin) that states
// its name and size. The transfer's id is the id of that message. If the
// recipient accepts, the two clients transfer the file through the server,
// which only relays it and never stores any of it:
//
// 	recipient -> server -> sender     File_Accept  [kind][id u64][account u32][max rate u32]
// 	sender -> server -> recipient     File_Chunk   [kind][id u64][index u32][data]
// 	recipient -> server -> sender     File_Ack     [kind][id u64][max rate u32][base u32][highest u32][flags u8][count u16][missing u32...]
// 	either -> server -> the other     File_Cancel  [kind][id u64][account u32][reason u8]
//
// `account` is the other party's account on the way to the server, and the
// account that the message came from on the way back. The server fills in who
// sent it. The file is on the device that offered it, and an account may have
// several devices. The server remembers which connection posted the offer and
// sets up a transfer between that connection and the connection of the
// recipient's account that accepts, as long as the connection that made the
// offer is still online. It only relays File_Chunk from the connection that
// offered and File_Ack from the connection that accepted. It drops the
// transfer when either side cancels or disconnects, or when nothing has
// happened for FILE_IDLE. The recipient's other connections are told that the
// offer was handled elsewhere (Elsewhere), whether it was accepted or declined.
//
// The file is cut into chunks of FILE_CHUNK_DATA bytes, and chunk i starts at
// byte i * FILE_CHUNK_DATA. The chunks are no longer sealed between the two
// clients, because the server may read DMs (D1). Each leg is encrypted between
// a client and the server like everything else.
//
// Nothing here is reliable on its own. The recipient resends File_Accept until
// chunks arrive, and sends File_Ack every FILE_ACK_INTERVAL while the transfer
// runs. Everything below `base` has arrived, `highest` is the highest index
// that has arrived, and `missing` lists the chunks from `base` onwards that
// haven't arrived (as many as fit). The sender sends each chunk once, within
// FILE_WINDOW chunks of `base`, and afterwards the chunks that are listed as
// missing. It is paced to the lower of its own limit and the recipient's
// `max rate` (in bytes per second, 0 for no limit). Once everything has
// arrived, File_Ack carries FILE_ACK_COMPLETE, which is repeated a few times,
// and both sides are done.

MAX_FILE_NAME :: 200 // bytes of UTF-8

// The largest file that can be offered or saved. The recipient keeps a bit
// per chunk (Transfer_Receiver), which is 28 MiB for a file of this size,
// so the sender, who chooses the size, can't make it allocate much more.
MAX_FILE_SIZE :: u64(256) << 30

FILE_ACCEPT_SIZE :: 1 + 8 + 4 + 4
FILE_CHUNK_HEADER_SIZE :: 1 + 8 + 4
FILE_CHUNK_DATA :: MAX_PAYLOAD_SIZE - FILE_CHUNK_HEADER_SIZE
FILE_ACK_HEADER_SIZE :: 1 + 8 + 4 + 4 + 4 + 1 + 2
FILE_ACK_MAX_MISSING :: (MAX_PAYLOAD_SIZE - FILE_ACK_HEADER_SIZE) / 4
FILE_CANCEL_SIZE :: 1 + 8 + 4 + 1

FILE_ACK_COMPLETE :: 1 << 0

// The number of chunks ahead of the recipient's `base` that a sender may have
// in flight at once.
FILE_WINDOW :: 1024

// The reason why a transfer ended early.
File_Cancel_Reason :: enum u8 {
	Declined  = 1, // the recipient declined
	Cancelled = 2, // either side stopped it
	Gone      = 3, // the other side disconnected or the offer no longer exists
	Expired   = 4, // the sender no longer has the offer (after a restart)
	Failed    = 5, // the file couldn't be read or written
	Elsewhere = 6, // another device of the recipient answered it
}

file_chunk_count :: proc(size: u64) -> u32 {
	return u32((size + FILE_CHUNK_DATA - 1) / FILE_CHUNK_DATA)
}

// file_chunk_range returns the part of a file that chunk `index` carries.
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
// File_Cancel. The server does this before it passes the message on.
set_file_message_account :: proc(pt: []u8, account: Account_Id) {
	endian.unchecked_put_u32le(pt[9:], u32(account))
}

// A DM's chunks and acks are handled by transfer.odin, under File_Chunk and
// File_Ack, with the offer's id.
encode_file_chunk :: proc(out: []u8, id: Msg_Id, index: u32, data: []u8) -> []u8 {
	return encode_transfer_chunk(out, .File_Chunk, u64(id), index, data)
}

decode_file_chunk :: proc(pt: []u8) -> (id: Msg_Id, index: u32, data: []u8) {
	raw: u64
	raw, index, data = decode_transfer_chunk(pt)
	return Msg_Id(raw), index, data
}

// file_message_id returns the id of the transfer that a File_* message belongs to.
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

encode_file_ack :: proc(out: []u8, ack: File_Ack, missing: []u32) -> []u8 {
	return encode_transfer_ack(
		out,
		.File_Ack,
		{u64(ack.id), ack.max_rate, ack.base, ack.highest, ack.complete},
		missing,
	)
}

@(require_results)
decode_file_ack :: proc(pt: []u8) -> (ack: File_Ack, count: int, missing: []u8, ok: bool) {
	raw: Transfer_Ack
	raw, count, missing, ok = decode_transfer_ack(pt)
	return {Msg_Id(raw.id), raw.max_rate, raw.base, raw.highest, raw.complete}, count, missing, ok
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

// decode_file_cancel may return a reason that this build doesn't have a name for.
decode_file_cancel :: proc(
	pt: []u8,
) -> (
	id: Msg_Id,
	account: Account_Id,
	reason: File_Cancel_Reason,
) {
	id = Msg_Id(endian.unchecked_get_u64le(pt[1:]))
	account = Account_Id(endian.unchecked_get_u32le(pt[9:]))
	reason = File_Cancel_Reason(pt[13])
	return
}

// The file types that may be sent: archives, pictures, videos and audio, which
// are recognized by their extension. The receiving side checks the extension
// again before accepting, so that nothing that could be run by mistake ends up
// in its downloads.
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

// file_type_allowed reports whether a file called `name` may be sent.
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

// sanitize_file_name turns a name into one that is safe to save a file under.
// It removes directories, characters that a file system would refuse or treat
// specially, and leading dots, and limits the name to MAX_FILE_NAME bytes while
// keeping the extension. The result is empty if nothing is left of the name.
// The result points into `buf`.
sanitize_file_name :: proc(name: string, buf: ^[MAX_FILE_NAME]u8) -> string {
	// Keep only the last part of a path.
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
	clean = strings.trim(string(buf[:n]), " .")
	// On Windows, CON, NUL, COM1 and the like are devices, with any
	// extension, so a file can't be saved under such a name.
	base := clean
	if dot := strings.index_byte(base, '.'); dot >= 0 {
		base = base[:dot]
	}
	if !windows_device_name(strings.trim_right_space(base)) {
		return clean
	}
	if len(clean) == MAX_FILE_NAME {
		// No room for one more: the first letter becomes the _ instead.
		buf[0] = '_'
		copy(buf[1:], clean[1:])
		return string(buf[:len(clean)])
	}
	copy(buf[1:], clean) // copy may overlap
	buf[0] = '_'
	return string(buf[:len(clean) + 1])
}

@(private = "file")
windows_device_name :: proc(name: string) -> bool {
	for device in ([]string{"CON", "PRN", "AUX", "NUL"}) {
		if strings.equal_fold(name, device) {
			return true
		}
	}
	if len(name) == 4 && '1' <= name[3] && name[3] <= '9' {
		return strings.equal_fold(name[:3], "COM") || strings.equal_fold(name[:3], "LPT")
	}
	return false
}

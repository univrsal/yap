// What kind of picture some bytes are, from their first bytes, and a
// picture's size from its header. It is pure Odin with no libraries behind it, so the
// gateway, the server and both clients can use it (common:webp, for one,
// links libwebp).
package imagekind

Kind :: enum {
	Unknown,
	JPEG,
	PNG,
	WebP,
	GIF,
}

kind_of :: proc(data: []u8) -> Kind {
	switch {
	case is_jpeg(data):
		return .JPEG
	case is_png(data):
		return .PNG
	case is_webp(data):
		return .WebP
	case is_gif(data):
		return .GIF
	}
	return .Unknown
}

// content_type is the MIME type of a kind of picture.
content_type :: proc(kind: Kind) -> string {
	switch kind {
	case .JPEG:
		return "image/jpeg"
	case .PNG:
		return "image/png"
	case .WebP:
		return "image/webp"
	case .GIF:
		return "image/gif"
	case .Unknown:
	}
	return "application/octet-stream"
}

is_jpeg :: proc(data: []u8) -> bool {
	return len(data) >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF
}

is_png :: proc(data: []u8) -> bool {
	return len(data) >= 8 && string(data[:8]) == "\x89PNG\r\n\x1a\n"
}

// is_webp: a RIFF container of type WEBP.
is_webp :: proc(data: []u8) -> bool {
	return len(data) >= 12 && string(data[:4]) == "RIFF" && string(data[8:12]) == "WEBP"
}

is_gif :: proc(data: []u8) -> bool {
	return len(data) >= 6 && (string(data[:6]) == "GIF89a" || string(data[:6]) == "GIF87a")
}

// dimensions returns the width and height that the header of a JPEG, PNG,
// WebP, GIF or BMP states. `ok` is false for anything else, or if the header
// isn't all in `data`. A JPEG's start of frame may come after its metadata,
// so `data` should be the first few dozen KB of the file.
dimensions :: proc(data: []u8) -> (width, height: int, ok: bool) {
	be32 :: proc(b: []u8) -> int {
		return int(b[0]) << 24 | int(b[1]) << 16 | int(b[2]) << 8 | int(b[3])
	}
	le16 :: proc(b: []u8) -> int {
		return int(b[0]) | int(b[1]) << 8
	}
	le24 :: proc(b: []u8) -> int {
		return int(b[0]) | int(b[1]) << 8 | int(b[2]) << 16
	}
	switch {
	case is_jpeg(data):
		return jpeg_size(data)
	case is_png(data):
		// The first chunk is IHDR, which starts with the width and height.
		if len(data) < 24 || string(data[12:16]) != "IHDR" {
			return
		}
		width, height = be32(data[16:]), be32(data[20:])
	case is_gif(data):
		// The logical screen, which the frames are drawn on.
		if len(data) < 10 {
			return
		}
		width, height = le16(data[6:]), le16(data[8:])
	case is_webp(data):
		if len(data) < 30 {
			return
		}
		switch string(data[12:16]) {
		case "VP8 ":
			// Lossy: a frame tag, its start code, then 14 bits each.
			if data[23] != 0x9d || data[24] != 0x01 || data[25] != 0x2a {
				return
			}
			width, height = le16(data[26:]) & 0x3fff, le16(data[28:]) & 0x3fff
		case "VP8L":
			// Lossless: a signature byte, then 14 bits each of one less.
			if data[20] != 0x2f {
				return
			}
			bits := le24(data[21:]) | int(data[24]) << 24
			width, height = bits & 0x3fff + 1, (bits >> 14) & 0x3fff + 1
		case "VP8X":
			// Extended (animated, or with alpha or metadata): the canvas, 24
			// bits each of one less, after the flags.
			width, height = le24(data[24:]) + 1, le24(data[27:]) + 1
		case:
			return
		}
	case len(data) >= 26 && data[0] == 'B' && data[1] == 'M':
		// The info header's size says which of its versions it is. The
		// oldest has 16-bit sizes, and the others have a height that is
		// negative for a picture stored top-down.
		if le16(data[14:]) == 12 {
			width, height = le16(data[18:]), le16(data[20:])
		} else {
			width = int(i32(u32(le16(data[18:]) | le16(data[20:]) << 16)))
			height = abs(int(i32(u32(le16(data[22:]) | le16(data[24:]) << 16))))
		}
	case:
		return
	}
	return width, height, width > 0 && height > 0
}

// jpeg_size returns the width and height from the first start-of-frame
// segment of a JPEG's header. `ok` is false if `data` isn't a JPEG that has
// one.
jpeg_size :: proc(data: []u8) -> (width, height: int, ok: bool) {
	if len(data) < 4 || data[0] != 0xFF || data[1] != 0xD8 {
		return
	}
	at := 2
	for at + 4 <= len(data) {
		if data[at] != 0xFF {
			return
		}
		marker := data[at + 1]
		switch marker {
		case 0xFF:
			at += 1 // fill byte
			continue
		case 0x01, 0xD0 ..= 0xD8:
			// No length: TEM, the restart markers, and a stray start of image.
			at += 2
			continue
		case 0xD9, 0xDA:
			return // end of image or start of image data before any frame
		}
		length := int(data[at + 2]) << 8 | int(data[at + 3])
		if length < 2 || at + 2 + length > len(data) {
			return
		}
		switch marker {
		// All start-of-frame markers, i.e. excluding the markers in this range
		// that aren't (C4 is a Huffman table, C8 is reserved and CC is the
		// arithmetic coding conditioning).
		case 0xC0 ..= 0xC3, 0xC5 ..= 0xC7, 0xC9 ..= 0xCB, 0xCD ..= 0xCF:
			if length < 7 {
				return
			}
			height = int(data[at + 5]) << 8 | int(data[at + 6])
			width = int(data[at + 7]) << 8 | int(data[at + 8])
			return width, height, width > 0 && height > 0
		}
		at += 2 + length
	}
	return
}

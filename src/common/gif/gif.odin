// Reads a GIF's size, frame count and loop count from its blocks without
// decoding any pixels. The client uses it to find out whether a picture is
// an animation and whether its frames fit in memory before decoding them
// (stb_image reads all frames at once). The server uses it for animated
// emoji. It is pure Odin, so the web build can use it too.
package gif

import "common:imagekind"

Info :: struct {
	width, height: int,
	frames:        int,
	loops:         int, // how often it plays; 0 means forever
}

// is_gif returns whether `data` starts with a GIF header.
is_gif :: proc(data: []u8) -> bool {
	return imagekind.is_gif(data)
}

// info reads a GIF's size, frame count and loop count.
// The loop count follows browser behavior: without a NETSCAPE2.0 block the
// GIF plays once, with a block value of 0 it loops forever, and with a
// value of n it plays once and then repeats n more times.
// ok is false if the data isn't a GIF or is cut off inside a block.
info :: proc(data: []u8) -> (info: Info, ok: bool) {
	if !is_gif(data) || len(data) < 13 {
		return
	}
	info.width = int(data[6]) | int(data[7]) << 8
	info.height = int(data[8]) | int(data[9]) << 8
	info.loops = 1
	pos := 13
	if data[10] & 0x80 != 0 {
		pos += 3 << ((data[10] & 7) + 1) // the global color table
	}
	for pos < len(data) {
		switch data[pos] {
		case 0x2C:
			// an image
			if pos + 10 > len(data) {
				return
			}
			flags := data[pos + 9]
			pos += 10
			if flags & 0x80 != 0 {
				pos += 3 << ((flags & 7) + 1) // its own color table
			}
			pos += 1 // the LZW code size
			pos = skip_sub_blocks(data, pos) or_return
			info.frames += 1
		case 0x21:
			// an extension
			if pos + 2 > len(data) {
				return
			}
			label := data[pos + 1]
			pos += 2
			app := data[pos:]
			if label == 0xFF &&
			   len(app) >= 16 &&
			   app[0] == 11 &&
			   string(app[1:12]) == "NETSCAPE2.0" {
				if app[12] == 3 && app[13] == 1 {
					n := int(app[14]) | int(app[15]) << 8
					info.loops = 0 if n == 0 else n + 1
				}
			}
			pos = skip_sub_blocks(data, pos) or_return
		case 0x3B:
			// the end
			return info, info.frames > 0 && info.width > 0 && info.height > 0
		case:
			return
		}
	}
	// Some GIFs end after a complete block without the trailer byte.
	// stb_image accepts those too.
	return info, info.frames > 0 && info.width > 0 && info.height > 0
}

// skip_sub_blocks returns the position where the sub-blocks starting at
// `start` end.
@(private = "file")
skip_sub_blocks :: proc(data: []u8, start: int) -> (pos: int, ok: bool) {
	pos = start
	for pos < len(data) {
		n := int(data[pos])
		pos += 1
		if n == 0 {
			return pos, true
		}
		pos += n
	}
	return
}

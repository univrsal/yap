/*
What a GIF is, read from its blocks without decoding any: its size, how
many frames it has and how often it plays. The client uses it to know
whether a picture is an animation and whether its frames fit in memory
before decoding them (stb_image reads them all at once), and the server
the same for animated emoji. Pure Odin, so a web build has it too.
*/
package gif

Info :: struct {
	width, height: int,
	frames:        int,
	loops:         int, // how often it plays; 0 is for ever
}

// is_gif is whether `data` starts the way a GIF does.
is_gif :: proc(data: []u8) -> bool {
	return len(data) >= 6 && (string(data[:6]) == "GIF89a" || string(data[:6]) == "GIF87a")
}

/*
info reads a GIF's size, how many frames it has and how often it plays.
How often is as browsers have it: without a NETSCAPE2.0 block, once;
with one that says 0, for ever; with one that says n, the first time and
n more. False for data that isn't a GIF, or is cut off inside a block.
*/
info :: proc(data: []u8) -> (info: Info, ok: bool) {
	if !is_gif(data) || len(data) < 13 {
		return
	}
	info.width = int(data[6]) | int(data[7]) << 8
	info.height = int(data[8]) | int(data[9]) << 8
	info.loops = 1
	pos := 13
	if data[10] & 0x80 != 0 {
		pos += 3 << ((data[10] & 7) + 1) // the global colour table
	}
	for pos < len(data) {
		switch data[pos] {
		case 0x2C: // an image
			if pos + 10 > len(data) {
				return
			}
			flags := data[pos + 9]
			pos += 10
			if flags & 0x80 != 0 {
				pos += 3 << ((flags & 7) + 1) // its own colour table
			}
			pos += 1 // the LZW code size
			pos = skip_sub_blocks(data, pos) or_return
			info.frames += 1
		case 0x21: // an extension
			if pos + 2 > len(data) {
				return
			}
			label := data[pos + 1]
			pos += 2
			app := data[pos:]
			if label == 0xFF && len(app) >= 16 && app[0] == 11 && string(app[1:12]) == "NETSCAPE2.0" {
				if app[12] == 3 && app[13] == 1 {
					n := int(app[14]) | int(app[15]) << 8
					info.loops = 0 if n == 0 else n + 1
				}
			}
			pos = skip_sub_blocks(data, pos) or_return
		case 0x3B: // the end
			return info, info.frames > 0 && info.width > 0 && info.height > 0
		case:
			return
		}
	}
	// Ending after a whole block without the trailer, which happens, and
	// which stb_image reads too.
	return info, info.frames > 0 && info.width > 0 && info.height > 0
}

// skip_sub_blocks is where the sub-blocks starting at `pos` end.
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

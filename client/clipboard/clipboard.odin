package clipboard

import "core:encoding/endian"
import "core:log"
import stbi "vendor:stb/image"

/*
Reading images from the system clipboard, which GLFW can't do (it only
knows text).

	Linux    Wayland (on GLFW's connection) or X11 (a connection of our
	         own); both libraries are loaded at runtime, like GLFW does,
	         so neither is a link dependency.
	Windows  the registered "PNG" format, else CF_DIBV5 / CF_DIB.
	macOS    NSPasteboard: PNG, JPEG, or TIFF (converted to PNG).

Whatever the source format, the result is decoded with stb_image into
8-bit RGBA. Call everything from the thread that runs the window (on
Wayland, GLFW's event loop feeds our clipboard events).

Based on how copycat (clipboard/copycat-main) talks to each platform.
*/

Image :: struct {
	width, height: int,
	pixels:        []u8, // RGBA, rows top to bottom
}

Error :: enum {
	None,
	No_Image, // the clipboard is empty or holds no image we can read
	Unavailable, // no clipboard access (no display server, clipboard locked, ...)
	Timeout, // the owning application didn't hand the data over in time
	Too_Large,
	Decode_Failed,
}

// Clipboard data bigger than this isn't read at all.
MAX_DATA_SIZE :: 64 * 1024 * 1024
// Images with more pixels than this (8K UHD) aren't decoded. Callers
// scale down whatever they decode to what they actually need.
MAX_PIXELS :: 7680 * 4320
// How long the owner of the clipboard gets to hand over the data.
READ_TIMEOUT_MS :: 2000

// Image formats, most preferred first, as MIME types. Linux offers these
// directly; the other platforms map them to their own names.
MIME_TYPES :: [?]string{"image/png", "image/jpeg", "image/bmp", "image/x-bmp", "image/gif"}

// init prepares clipboard access. On Linux pass GLFW's Wayland display
// (glfw.GetWaylandDisplay) when GLFW runs on Wayland, and nil for X11.
// Elsewhere it's ignored. Returns whether reading can work at all.
init :: proc(wayland_display: rawptr) -> bool {
	return _init(wayland_display)
}

destroy :: proc() {
	_destroy()
}

// read_image returns the image on the clipboard, decoded. Delete its
// pixels with image_destroy.
read_image :: proc(allocator := context.allocator) -> (img: Image, err: Error) {
	data, mime, read_err := _read_encoded(context.allocator)
	if read_err != .None {
		return {}, read_err
	}
	defer delete(data)
	log.debugf("clipboard: %d bytes of %s", len(data), mime)
	return decode(data, allocator)
}

image_destroy :: proc(img: ^Image, allocator := context.allocator) {
	delete(img.pixels, allocator)
	img^ = {}
}

// decode turns PNG, JPEG, BMP or GIF data into RGBA pixels, refusing
// images over MAX_PIXELS before decoding them.
decode :: proc(data: []u8, allocator := context.allocator) -> (img: Image, err: Error) {
	if len(data) == 0 || len(data) > MAX_DATA_SIZE {
		return {}, .Decode_Failed if len(data) == 0 else .Too_Large
	}
	w, h, comp: i32
	if stbi.info_from_memory(raw_data(data), i32(len(data)), &w, &h, &comp) == 0 {
		log.debugf("clipboard: can't decode the image: %s", stbi.failure_reason())
		return {}, .Decode_Failed
	}
	if w <= 0 || h <= 0 || i64(w) * i64(h) > MAX_PIXELS {
		log.debugf("clipboard: image is %dx%d, over the limit", w, h)
		return {}, .Too_Large
	}
	pixels := stbi.load_from_memory(raw_data(data), i32(len(data)), &w, &h, &comp, 4)
	if pixels == nil {
		log.debugf("clipboard: can't decode the image: %s", stbi.failure_reason())
		return {}, .Decode_Failed
	}
	defer stbi.image_free(pixels)
	n := int(w) * int(h) * 4
	img = {
		width  = int(w),
		height = int(h),
		pixels = make([]u8, n, allocator),
	}
	copy(img.pixels, pixels[:n])
	return img, .None
}

@(private = "file")
BI_BITFIELDS :: 3
@(private = "file")
BI_ALPHABITFIELDS :: 6

// dib_to_bmp turns a Windows DIB (a BMP file without its 14-byte file
// header) into a BMP file for stb_image. The header's pixel offset
// depends on the header size, color masks and palette before the pixels.
dib_to_bmp :: proc(dib: []u8, allocator := context.allocator) -> (bmp: []u8, err: Error) {
	if len(dib) < 40 {
		return nil, .Decode_Failed
	}
	header_size := int(endian.unchecked_get_u32le(dib[0:]))
	bit_count := int(endian.unchecked_get_u16le(dib[14:]))
	compression := endian.unchecked_get_u32le(dib[16:])
	colors_used := int(endian.unchecked_get_u32le(dib[32:]))
	if header_size < 40 || header_size > len(dib) {
		return nil, .Decode_Failed
	}

	masks := 0
	if header_size == 40 {
		// Only the original header keeps the masks after itself.
		switch compression {
		case BI_BITFIELDS:
			masks = 12
		case BI_ALPHABITFIELDS:
			masks = 16
		}
	}
	palette := colors_used
	if palette == 0 && bit_count <= 8 {
		palette = 1 << uint(bit_count)
	}
	offset := 14 + header_size + masks + palette * 4
	if offset - 14 > len(dib) {
		return nil, .Decode_Failed
	}

	bmp = make([]u8, 14 + len(dib), allocator)
	bmp[0], bmp[1] = 'B', 'M'
	endian.unchecked_put_u32le(bmp[2:], u32(len(bmp)))
	endian.unchecked_put_u32le(bmp[10:], u32(offset))
	copy(bmp[14:], dib)
	log.debugf("clipboard: DIB, %d-bit, header %d", bit_count, header_size)
	return bmp, .None
}

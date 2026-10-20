package clipboard

import log "common:wlog"
import "core:encoding/endian"

// Reading images from the system clipboard, which GLFW can't do (it only
// supports text).
//
//	Linux    Wayland (on GLFW's connection) or X11 (a connection of our
//	         own). Both libraries are loaded at runtime, as GLFW does, so
//	         neither is a link dependency.
//	OpenBSD  X11, loaded the same way.
//	Windows  the registered "PNG" format, otherwise CF_DIBV5 / CF_DIB.
//	macOS    NSPasteboard: PNG, JPEG, or TIFF (converted to PNG).
//
// Whatever the source format, the result is decoded with stb_image (or
// libwebp for WebP) into 8-bit RGBA. Everything has to be called from the
// thread that runs the window (on Wayland, GLFW's event loop feeds our
// clipboard events).
//
// This is based on how copycat (clipboard/copycat-main) talks to each
// platform.

Image :: struct {
	width, height: int,
	pixels:        []u8, // RGBA, rows top to bottom
}

Error :: enum {
	None,
	No_Image, // the clipboard is empty or contains no image we can read
	Unavailable, // no clipboard access (no display server, clipboard locked, etc.)
	Timeout, // the application owning the clipboard didn't provide the data in time
	Too_Large,
	Decode_Failed,
}

// Clipboard data larger than this is not read.
MAX_DATA_SIZE :: 64 * 1024 * 1024
// Images with more pixels than this (8K UHD) are not decoded. Callers scale
// down whatever they decode to the size they actually need.
MAX_PIXELS :: 7680 * 4320
// How long the owner of the clipboard has to provide the data.
READ_TIMEOUT_MS :: 2000

// Supported image formats as MIME types, most preferred first. Linux uses
// these directly, while the other platforms map them to their own names.
// GIF and WebP come first because either may be an animation, which a pasted
// picture keeps (see ui_paste.odin), and a still one is as good as the PNG
// version of it.
MIME_TYPES :: [?]string {
	"image/gif",
	"image/webp",
	"image/png",
	"image/jpeg",
	"image/bmp",
	"image/x-bmp",
}

// init prepares clipboard access. On Linux, pass GLFW's Wayland display
// (glfw.GetWaylandDisplay) when GLFW runs on Wayland, and nil for X11. On
// other platforms the argument is ignored. It returns whether reading the
// clipboard can work at all.
init :: proc(wayland_display: rawptr) -> bool {
	return _init(wayland_display)
}

destroy :: proc() {
	_destroy()
}

// read_image returns the decoded image on the clipboard. Free its pixels
// with image_destroy.
read_image :: proc(allocator := context.allocator) -> (img: Image, err: Error) {
	data, read_err := read_encoded(context.allocator)
	if read_err != .None {
		return {}, read_err
	}
	defer delete(data)
	return decode(data, allocator)
}

// read_encoded returns the image on the clipboard in its original encoded
// format (PNG, GIF, etc., all of which decode can read). The caller owns the
// result.
read_encoded :: proc(allocator := context.allocator) -> (data: []u8, err: Error) {
	mime: string
	data, mime, err = _read_encoded(allocator)
	if err == .None {
		log.debugf("clipboard: %d bytes of %s", len(data), mime)
	}
	return
}

// drag_over says whether files are being dragged over the window, and where,
// in window coordinates. Only Wayland tells: the compositor shows a drag to
// every data device the window's client has, ours among them (see
// wayland_linux.odin), while GLFW only reports the drop. Elsewhere it is
// always false. `wayland_surface` is the window's (glfw.GetWaylandWindow).
// Call it from the window's thread, once a frame.
drag_over :: proc(wayland_surface: rawptr) -> (x, y: f64, over: bool) {
	return _drag_over(wayland_surface)
}

image_destroy :: proc(img: ^Image, allocator := context.allocator) {
	delete(img.pixels, allocator)
	img^ = {}
}

// pick_mime returns the most preferred image type from `offered`.
pick_mime :: proc(offered: []string) -> (mime: string, ok: bool) {
	for want in MIME_TYPES {
		for have in offered {
			if have == want {
				return want, true
			}
		}
	}
	return "", false
}


@(private = "file")
BI_BITFIELDS :: 3
@(private = "file")
BI_ALPHABITFIELDS :: 6

// dib_to_bmp turns a Windows DIB (a BMP file without its 14-byte file
// header) into a BMP file that stb_image can read. The pixel offset in the
// header depends on the header size, color masks and palette that come
// before the pixels.
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
		// Only the original header stores the masks directly after itself.
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

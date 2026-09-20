package clipboard

import win "core:sys/windows"
import "core:time"

/*
Windows: browsers, Office and most image editors put a "PNG" format on
the clipboard; everything that copies an image offers a device
independent bitmap (CF_DIBV5 / CF_DIB, synthesized by Windows from the
others). A DIB is a BMP file without its 14-byte file header, so we add
one and let stb_image decode it like any BMP.
*/

@(private = "file")
CF_DIB :: 8
@(private = "file")
CF_DIBV5 :: 17

_init :: proc(wayland_display: rawptr) -> bool {
	return true
}

_destroy :: proc() {}

_read_encoded :: proc(allocator := context.allocator) -> (data: []u8, mime: string, err: Error) {
	// Another program may have the clipboard open for a moment.
	opened := false
	for _ in 0 ..< 10 {
		if win.OpenClipboard(nil) {
			opened = true
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	if !opened {
		return nil, "", .Unavailable
	}
	defer win.CloseClipboard()

	if png := win.RegisterClipboardFormatW(win.L("PNG")); png != 0 && win.IsClipboardFormatAvailable(png) {
		if data, err = global_bytes(png, allocator); err == .None {
			return data, "image/png", .None
		}
	}
	for format in ([]u32{CF_DIBV5, CF_DIB}) {
		if !win.IsClipboardFormatAvailable(format) {
			continue
		}
		dib: []u8
		if dib, err = global_bytes(format, context.temp_allocator); err != .None {
			continue
		}
		if data, err = dib_to_bmp(dib, allocator); err == .None {
			return data, "image/bmp", .None
		}
	}
	return nil, "", .No_Image
}

// global_bytes copies out the clipboard's data in `format`, which Windows
// keeps in a global memory block.
@(private = "file")
global_bytes :: proc(format: u32, allocator := context.allocator) -> (data: []u8, err: Error) {
	h := win.GetClipboardData(format)
	if h == nil {
		return nil, .No_Image
	}
	size := int(win.GlobalSize(win.HGLOBAL(h)))
	if size == 0 {
		return nil, .No_Image
	}
	if size > MAX_DATA_SIZE {
		return nil, .Too_Large
	}
	p := win.GlobalLock(win.HGLOBAL(h))
	if p == nil {
		return nil, .Unavailable
	}
	defer win.GlobalUnlock(win.HGLOBAL(h))
	data = make([]u8, size, allocator)
	copy(data, ([^]u8)(p)[:size])
	return data, .None
}

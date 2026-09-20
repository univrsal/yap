package clipboard

import "base:intrinsics"
import NS "core:sys/darwin/Foundation"

/*
macOS: NSPasteboard. Browsers and most apps offer PNG; screenshots and
Preview also offer TIFF, which stb_image can't read, so TIFF goes through
NSBitmapImageRep to become PNG. (Odin's Foundation bindings leave
NSPasteboard unimplemented, so the messages are sent here directly.)
*/

@(private = "file")
msgSend :: intrinsics.objc_send

@(private = "file", objc_class = "NSPasteboard")
Pasteboard :: struct {
	using _: NS.Object,
}

@(private = "file")
BITMAP_IMAGE_FILE_TYPE_PNG :: 4 // NSBitmapImageFileTypePNG

_init :: proc(wayland_display: rawptr) -> bool {
	return true
}

_destroy :: proc() {}

_read_encoded :: proc(allocator := context.allocator) -> (data: []u8, mime: string, err: Error) {
	pool := NS.AutoreleasePool_init(NS.AutoreleasePool_alloc())
	defer NS.AutoreleasePool_drain(pool)

	pb := msgSend(^Pasteboard, Pasteboard, "generalPasteboard")
	if pb == nil {
		return nil, "", .Unavailable
	}
	if d := msgSend(^NS.Data, pb, "dataForType:", NS.AT("public.png")); d != nil {
		return copy_data(d, "image/png", allocator)
	}
	if d := msgSend(^NS.Data, pb, "dataForType:", NS.AT("public.jpeg")); d != nil {
		return copy_data(d, "image/jpeg", allocator)
	}
	if tiff := msgSend(^NS.Data, pb, "dataForType:", NS.AT("public.tiff")); tiff != nil {
		rep := msgSend(^NS.BitmapImageRep, NS.BitmapImageRep, "imageRepWithData:", tiff)
		if rep == nil {
			return nil, "", .Decode_Failed
		}
		png := msgSend(
			^NS.Data,
			rep,
			"representationUsingType:properties:",
			NS.UInteger(BITMAP_IMAGE_FILE_TYPE_PNG),
			NS.Dictionary_dictionary(),
		)
		if png == nil {
			return nil, "", .Decode_Failed
		}
		return copy_data(png, "image/png", allocator)
	}
	return nil, "", .No_Image
}

@(private = "file")
copy_data :: proc(d: ^NS.Data, mime: string, allocator := context.allocator) -> (data: []u8, m: string, err: Error) {
	n := int(NS.Data_length(d))
	if n == 0 {
		return nil, "", .No_Image
	}
	if n > MAX_DATA_SIZE {
		return nil, "", .Too_Large
	}
	bytes := msgSend(rawptr, d, "bytes")
	data = make([]u8, n, allocator)
	copy(data, ([^]u8)(bytes)[:n])
	return data, mime, .None
}

#+build wasi
package conn

import "core:strings"

import "client:settings"
import "common:proto"

/*
The image cache in a browser (web/images.js): pictures are kept in the
site's IndexedDB under the same names a desktop gives their files
(settings.server_key). The page keeps a list of what's there, so how
much there is, dropping the ones used longest ago and clearing it are
answered at once; reading a picture takes a moment (image_cache.odin).
There's no folder to choose.
*/

@(default_calling_convention = "c")
foreign _ {
	yap_image_cache_open :: proc(max_bytes: f64) -> i32 ---
	yap_image_cache_bytes :: proc() -> f64 ---
	yap_image_cache_count :: proc() -> i32 ---
	yap_image_cache_set_max :: proc(max_bytes: f64) ---
	yap_image_cache_clear :: proc() ---
	yap_image_cache_request :: proc(key: cstring) -> i32 ---
	yap_image_cache_poll :: proc(req: i32) -> i32 ---
	yap_image_cache_take :: proc(req: i32, buf: [^]u8, len: i32) ---
	yap_image_cache_cancel :: proc(req: i32) ---
	yap_image_cache_store :: proc(key: cstring, data: [^]u8, len: i32) ---
}

Image_Cache :: struct {}

default_image_cache_dir :: proc(allocator := context.allocator) -> string {
	return ""
}

// image_cache_open: the page opens its database when it loads, and
// whatever the folder is, there's only the one.
image_cache_open :: proc(ic: ^Image_Cache, dir: string, max_bytes: int) -> bool {
	return yap_image_cache_open(f64(max(max_bytes, 0))) != 0
}

image_cache_destroy :: proc(ic: ^Image_Cache) {}

image_cache_dir :: proc(ic: ^Image_Cache) -> string {
	return ""
}

image_cache_usage :: proc(ic: ^Image_Cache) -> (bytes, count: int) {
	return int(yap_image_cache_bytes()), int(yap_image_cache_count())
}

image_cache_set_max :: proc(ic: ^Image_Cache, max_bytes: int) {
	yap_image_cache_set_max(f64(max(max_bytes, 0)))
}

image_cache_clear :: proc(ic: ^Image_Cache) {
	yap_image_cache_clear()
}

image_cache_request :: proc(ic: ^Image_Cache, server: [proto.KEY_SIZE]u8, id: proto.Blob_Id) -> Cache_Request {
	key := strings.clone_to_cstring(settings.server_key(server, u64(id)), context.temp_allocator)
	return Cache_Request(yap_image_cache_request(key))
}

image_cache_poll :: proc(
	ic: ^Image_Cache,
	req: Cache_Request,
	allocator := context.allocator,
) -> (
	data: []u8,
	state: Cache_Poll,
) {
	switch size := yap_image_cache_poll(i32(req)); {
	case size == -1:
		return nil, .Pending
	case size <= 0:
		return nil, .Failed
	case:
		data = make([]u8, int(size), allocator)
		yap_image_cache_take(i32(req), raw_data(data), size)
		return data, .Done
	}
}

image_cache_cancel :: proc(ic: ^Image_Cache, req: Cache_Request) {
	yap_image_cache_cancel(i32(req))
}

image_cache_store :: proc(ic: ^Image_Cache, server: [proto.KEY_SIZE]u8, id: proto.Blob_Id, data: []u8) {
	if len(data) == 0 {
		return
	}
	key := strings.clone_to_cstring(settings.server_key(server, u64(id)), context.temp_allocator)
	yap_image_cache_store(key, raw_data(data), i32(len(data)))
}

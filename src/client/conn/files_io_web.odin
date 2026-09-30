#+build wasi
package conn

import log "common:wlog"
import "core:strings"

/*
Reading a file being sent and writing one being received, in a browser
(web/files.js): the picked file stays with the page, which reads it in
blocks as the transfer asks for them, and a received file is collected
by the page and offered as a download under its name once it's whole.
*/

@(default_calling_convention = "c")
foreign _ {
	yap_file_pick :: proc(accept: cstring) ---
	yap_file_read :: proc(handle: i32, offset: f64, buf: [^]u8, len: i32) -> i32 ---
	yap_file_close :: proc(handle: i32) ---
	yap_sink_open :: proc(name: cstring, size: f64) -> i32 ---
	yap_sink_write :: proc(handle: i32, offset: f64, data: [^]u8, len: i32) -> i32 ---
	yap_sink_finish :: proc(handle: i32) -> i32 ---
	yap_sink_abort :: proc(handle: i32) ---
}

File_Source :: struct {
	handle: i32,
}

File_Sink :: struct {
	handle: i32,
}

file_source_open :: proc(
	cmd: Send_File_Command,
) -> (
	src: File_Source,
	name: string,
	size: u64,
	ok: bool,
) {
	if cmd.web_file <= 0 {
		return
	}
	return {handle = cmd.web_file}, cmd.web_name, cmd.web_size, true
}

// file_source_read fills `buf` from `offset`, if the page has read that
// far; if not, it's on its way and `ready` is false.
file_source_read :: proc(src: ^File_Source, offset: u64, buf: []u8) -> (ready, ok: bool) {
	n := yap_file_read(src.handle, f64(offset), raw_data(buf), i32(len(buf)))
	switch n {
	case -1:
		return false, true
	case i32(len(buf)):
		return true, true
	}
	return false, false
}

file_source_close :: proc(src: ^File_Source) {
	if src.handle > 0 {
		yap_file_close(src.handle)
		src.handle = 0
	}
}

// file_sink_create starts collecting a file; the browser picks where it
// goes when it's done, so the "path" is its name.
file_sink_create :: proc(
	dir, name: string,
	size: u64,
) -> (
	sink: File_Sink,
	path: string,
	ok: bool,
) {
	handle := yap_sink_open(strings.clone_to_cstring(name, context.temp_allocator), f64(size))
	if handle <= 0 {
		log.error("file: the page couldn't start the download")
		return
	}
	return {handle = handle}, strings.clone(name), true
}

file_sink_write :: proc(sink: ^File_Sink, offset: u64, data: []u8) -> bool {
	return yap_sink_write(sink.handle, f64(offset), raw_data(data), i32(len(data))) != 0
}

file_sink_finish :: proc(sink: ^File_Sink, path: string) -> bool {
	ok := yap_sink_finish(sink.handle) != 0
	sink.handle = 0
	return ok
}

file_sink_abort :: proc(sink: ^File_Sink) {
	if sink.handle > 0 {
		yap_sink_abort(sink.handle)
		sink.handle = 0
	}
}

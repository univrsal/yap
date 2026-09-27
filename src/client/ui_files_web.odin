#+build wasi
package client

import "core:strings"

import "../proto"

/*
Picking a file to send, in a browser: a file input the page opens
(web/files.js), which keeps the file and tells the client its name and
size (web_file_picked). It has to be opened from something the person
just did, which the click on the button is.
*/

File_Pick_Job :: struct {}

@(private = "file")
g_pick_to: [proto.KEY_SIZE]u8

file_pick_start :: proc(ui: ^UI, to: [proto.KEY_SIZE]u8) {
	g_pick_to = to
	b := strings.builder_make(context.temp_allocator)
	for ext, i in proto.FILE_EXTENSIONS {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_byte(&b, '.')
		strings.write_string(&b, ext)
	}
	yap_file_pick(strings.to_cstring(&b))
}

file_pick_poll :: proc(ui: ^UI) {}
file_pick_wait :: proc(ui: ^UI) {}

// The page's picked file: offered to whoever the button was pressed for.
@(export)
web_file_picked :: proc "c" (handle: i32, name: [^]u8, name_len: i32, size: f64) {
	context = callback_context()
	if g_ui == nil || g_ui.session == nil {
		yap_file_close(handle)
		return
	}
	push_command(
		&g_ui.session.client.commands,
		Send_File_Command {
			to = g_pick_to,
			web_file = handle,
			web_name = strings.clone(string(name[:max(name_len, 0)])),
			web_size = u64(size),
		},
	)
}

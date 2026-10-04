#+build wasi
package client

import "core:strings"

import "common:proto"
import "client:platform"
import "client:conn"

/*
Picking a file to send, in a browser: a file input the page opens
(web/files.js), which keeps the file and tells the client its name and
size (web_file_picked). It has to be opened from something the person
just did, which the click on the button is. For files to attach to a
message (ui_attachments.odin), several may be picked, of any kind, and
each is told of in turn.
*/

File_Pick_Job :: struct {}

@(private = "file")
g_pick_to: proto.Account_Id
// The pick is of files to attach, for this composer.
@(private = "file")
g_pick_attach: bool
@(private = "file")
g_attach_to: Attach_Target

file_pick_start :: proc(ui: ^UI, to: proto.Account_Id) {
	g_pick_to, g_pick_attach = to, false
	b := strings.builder_make(context.temp_allocator)
	for ext, i in proto.FILE_EXTENSIONS {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_byte(&b, '.')
		strings.write_string(&b, ext)
	}
	conn.yap_file_pick(strings.to_cstring(&b), false)
}

file_pick_poll :: proc(ui: ^UI) {}

// attach_pick_start opens the page's file input for files to attach.
attach_pick_start :: proc(ui: ^UI, at: Attach_Target) {
	g_pick_attach, g_attach_to = true, at
	conn.yap_file_pick("", true)
}
file_pick_wait :: proc(ui: ^UI) {}

// The page's picked file: offered to whoever the button was pressed for.
@(export)
web_file_picked :: proc "c" (handle: i32, name: [^]u8, name_len: i32, size: f64) {
	context = platform.callback_context()
	if g_ui == nil || g_ui.session == nil {
		conn.yap_file_close(handle)
		return
	}
	if g_pick_attach {
		picked := Picked_File {
			web_file = handle,
			name     = string(name[:max(name_len, 0)]),
			size     = u64(size),
		}
		attach_add(g_ui, g_attach_to, {picked})
		return
	}
	conn.push_command(
		&g_ui.session.client.commands,
		conn.Send_File_Command {
			to = g_pick_to,
			web_file = handle,
			web_name = strings.clone(string(name[:max(name_len, 0)])),
			web_size = u64(size),
		},
	)
}

// attach_dropped: a browser's dropped files come from the page
// (web_file_dropped), not as paths.
attach_dropped :: proc(ui: ^UI) {}

// A file dropped on the page: attached to the message being written
// where it was dropped.
@(export)
web_file_dropped :: proc "c" (handle: i32, name: [^]u8, name_len: i32, size: f64) {
	context = platform.callback_context()
	if g_ui == nil || g_ui.session == nil || g_ui.page == .Settings {
		conn.yap_file_close(handle)
		return
	}
	picked := Picked_File {
		web_file = handle,
		name     = string(name[:max(name_len, 0)]),
		size     = u64(size),
	}
	attach_add(g_ui, drop_target(g_ui), {picked})
	ui_redraw(g_ui)
}

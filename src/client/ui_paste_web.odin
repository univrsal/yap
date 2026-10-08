#+build wasi
package client

import "client:conn"
import "client:platform"
import log "common:wlog"
import "core:strings"
import mu "vendor:microui"

/*
Pasting a picture into the chat. A page can only read the clipboard
inside the paste event the user caused, so the page does the whole job
there (web/paste.js): it decodes the picture, scales it to fit
MAX_IMAGE_SIDE and compresses it to a JPEG within MAX_IMAGE_BYTES -
what image.odin does for a desktop - and keeps the result as a file
(web/files.js), which web_file_pasted attaches to the message being
written, as a desktop's paste is. Nothing is read from here, so the
calls below are empty.

Text comes the same way. Emscripten's GLFW has no clipboard, so the page
hands over the text of every paste event (web_paste_text) before the
frame that sees the Ctrl+V, and that is what the text box pastes.
Copying goes to the browser's clipboard directly (web_copy_text).
*/

Paste_Job :: struct {}

paste_start :: proc(ui: ^UI) {}
paste_poll :: proc(ui: ^UI) {}
paste_wait :: proc(ui: ^UI) {}

@(default_calling_convention = "c")
foreign _ {
	// navigator.clipboard.writeText (see web/shell.c).
	yap_copy_text :: proc(text: cstring) -> i32 ---
}

// The text of the page's latest paste event; empty if it had none.
@(private = "file")
g_pasted_text: string

web_pasted_text :: proc() -> string {
	return g_pasted_text
}

// The page's paste event, text and all. Every paste replaces the last
// one's, so pasting a picture doesn't also paste old text.
@(export)
web_paste_text :: proc "c" (data: [^]u8, size: i32) {
	context = platform.callback_context()
	delete(g_pasted_text)
	g_pasted_text = strings.clone(string(data[:max(size, 0)]))
	ui_wake()
}

web_copy_text :: proc(text: string) -> bool {
	return yap_copy_text(strings.clone_to_cstring(text, context.temp_allocator)) != 0
}

// The page's finished JPEG, kept by the page under `handle` like a picked
// file: attached in the composer with the focus, else the page's.
@(export)
web_file_pasted :: proc "c" (handle: i32, name: [^]u8, name_len: i32, size: f64) {
	context = platform.callback_context()
	if g_ui == nil || g_ui.session == nil || g_ui.page == .Settings {
		conn.yap_file_close(handle)
		return
	}
	log.infof("pasted an image, %d KB as JPEG", int(size) / 1024)
	at := Attach_Target{g_ui.page, 0}
	ctx := &g_ui.ctx
	for &t, i in g_ui.threads {
		if t.key != {} && ctx.focus_id == mu.get_id(ctx, uintptr(&t.buf[0])) {
			at.thread = i + 1
		}
	}
	picked := Picked_File {
		web_file = handle,
		name     = pasted_image_name(g_ui),
		size     = u64(size),
	}
	attach_add(g_ui, at, {picked})
	ui_redraw(g_ui)
}

// The page could not make a picture of what was pasted.
@(export)
web_paste_failed :: proc "c" () {
	context = platform.callback_context()
	log.warn("the pasted image could not be prepared for sending")
}

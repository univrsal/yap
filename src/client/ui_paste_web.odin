#+build wasi
package client

import "core:strings"
import log "../common/wlog"

/*
Pasting a picture into the chat. A page can only read the clipboard
inside the paste event the user caused, so the page does the whole job
there (web/paste.js): it decodes the picture, scales it to fit
MAX_IMAGE_SIDE and compresses it to a JPEG within MAX_IMAGE_BYTES -
what image.odin does for a desktop - and hands the result to
web_paste_image. Nothing is read from here, so the calls below are
empty.

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
	context = callback_context()
	delete(g_pasted_text)
	g_pasted_text = strings.clone(string(data[:max(size, 0)]))
}

web_copy_text :: proc(text: string) -> bool {
	return yap_copy_text(strings.clone_to_cstring(text, context.temp_allocator)) != 0
}

// The page's finished JPEG, posted to the chat like a desktop's paste.
// The bytes are copied: the page's buffer is only good for this call.
@(export)
web_paste_image :: proc "c" (data: [^]u8, size: i32, width, height: i32) {
	context = callback_context()
	if g_ui == nil || size <= 0 {
		return
	}
	if g_ui.session == nil {
		log.warn("not connected, so the pasted image wasn't sent")
		return
	}
	img := Chat_Image {
		jpeg   = make([]u8, size),
		width  = int(width),
		height = int(height),
	}
	copy(img.jpeg, data[:size])
	log.infof("pasted a %dx%d image, %d KB as JPEG", img.width, img.height, len(img.jpeg) / 1024)
	push_command(&g_ui.session.client.commands, Chat_Image_Command{img})
}

// The page could not make a picture of what was pasted.
@(export)
web_paste_failed :: proc "c" () {
	context = callback_context()
	log.warn("the pasted image could not be prepared for sending")
}

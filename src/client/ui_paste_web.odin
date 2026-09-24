#+build wasi
package client

import log "../common/wlog"

/*
Pasting a picture into the chat. A page can only read the clipboard
inside the paste event the user caused, so the page does the whole job
there (web/paste.js): it decodes the picture, scales it to fit
MAX_IMAGE_SIDE and compresses it to a JPEG within MAX_IMAGE_BYTES -
what image.odin does for a desktop - and hands the result to
web_paste_image. Nothing is read from here, so the calls below are
empty. Text still pastes into the chat box as usual.
*/

Paste_Job :: struct {}

paste_start :: proc(ui: ^UI) {}
paste_poll :: proc(ui: ^UI) {}
paste_wait :: proc(ui: ^UI) {}

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

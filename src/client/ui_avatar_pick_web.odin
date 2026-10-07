#+build wasi
package client

import "client:conn"
import "client:platform"
import log "common:wlog"

/*
Choosing our picture in a browser: a file input the page opens
(web/avatar.js). It has to be opened from something the person just did,
which the click on the button is. The page makes the picture itself, as
avatar_prepare does on a desktop (ui_avatar_pick_native.odin), and hands
over the finished JPEG (web_avatar_picked). Pasting isn't offered: a
page can only read the clipboard inside a paste event (ui_paste_web.odin).

ui.profiles.pick is only a mark that a chosen file is being read, for the
settings to say so; closing the dialog without choosing never sets it.
*/

Avatar_Pick :: struct {}

@(default_calling_convention = "c")
foreign _ {
	// Opens the page's file input (see web/shell.c).
	yap_avatar_pick :: proc() ---
}

avatar_pick_start :: proc(ui: ^UI, paste: bool) {
	if paste || ui.profiles.pick != nil {
		return
	}
	ui.profiles.pick_notice = ""
	yap_avatar_pick()
}

avatar_pick_poll :: proc(ui: ^UI) {}

avatar_pick_wait :: proc(ui: ^UI) {
	if g_ui != nil {
		avatar_pick_finish(g_ui)
	}
}

@(private = "file")
avatar_pick_finish :: proc(ui: ^UI) {
	if ui.profiles.pick != nil {
		free(ui.profiles.pick)
		ui.profiles.pick = nil
	}
}

// A file was chosen; the page is making a picture of it.
@(export)
web_avatar_reading :: proc "c" () {
	context = platform.callback_context()
	if g_ui == nil || g_ui.profiles.pick != nil {
		return
	}
	g_ui.profiles.pick = new(Avatar_Pick)
	ui_wake()
}

// The page's finished JPEG, uploaded as our picture. The bytes are
// copied: the page's buffer is only good for this call.
@(export)
web_avatar_picked :: proc "c" (data: [^]u8, size: i32, side: i32) {
	context = platform.callback_context()
	if g_ui == nil {
		return
	}
	avatar_pick_finish(g_ui)
	defer ui_wake()
	if size <= 0 || g_ui.session == nil {
		return
	}
	img := conn.Chat_Image {
		jpeg   = make([]u8, size),
		width  = int(side),
		height = int(side),
	}
	copy(img.jpeg, data[:size])
	log.infof("chose a %dx%d picture, %d KB as JPEG", img.width, img.height, len(img.jpeg) / 1024)
	conn.push_command(&g_ui.session.client.commands, conn.Avatar_Command{image = img})
}

// The page could not make a picture of the file.
@(export)
web_avatar_failed :: proc "c" () {
	context = platform.callback_context()
	if g_ui == nil {
		return
	}
	avatar_pick_finish(g_ui)
	g_ui.profiles.pick_notice = "that isn't a picture that can be read"
	ui_wake()
}

package conn

import "core:slice"
import "core:strings"

import "common:proto"

/*
The server's own emoji (src/common/proto/emoji.odin): their names, and
the picture with all of them, which is fetched like a message's picture
(blobs.odin) and kept however many of those there are. The server tells
us of them when we log in, and again whenever its folder of them changes.
*/

Emoji_Client :: struct {
	blob:  proto.Blob_Id, // 0 for none
	cell:  int,
	names: [dynamic]string, // owned, in the sheet's order, which is by name
}

emoji_destroy :: proc(c: ^Voice_Client) {
	emoji_clear(c)
	delete(c.emoji.names)
	c.emoji = {}
}

@(private = "file")
emoji_clear :: proc(c: ^Voice_Client) {
	for n in c.emoji.names {
		delete(n)
	}
	clear(&c.emoji.names)
	c.emoji.blob = 0
}

// emoji_event takes an event about the server's emoji; false if `op`
// isn't one.
emoji_event :: proc(c: ^Voice_Client, op: proto.Event_Op, body: []u8) -> bool {
	if op != .Emoji_Sheet {
		return false
	}
	sheet, ok := proto.decode_emoji_sheet(body)
	if !ok {
		return true
	}
	emoji_clear(c)
	e := &c.emoji
	e.blob, e.cell = sheet.blob, sheet.cell
	for n in sheet.names {
		append(&e.names, strings.clone(n))
	}
	if e.blob != 0 {
		blob_want(c, {blob = e.blob, size = u32(sheet.size)}, keep = true)
	}
	publish_emoji(c)
	return true
}

// custom_emoji_index is where the server's emoji `name` is in its sheet;
// false if it hasn't got one by that name.
custom_emoji_index :: proc(names: []string, name: string) -> (int, bool) {
	return slice.binary_search(names, name)
}

// The server's emoji, as the UI sees them.
View_Emoji :: struct {
	blob:     proto.Blob_Id,
	cell:     int,
	names:    [dynamic]string, // owned
	revision: int, // bumped when they change
}

publish_emoji :: proc(c: ^Voice_Client) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	view_clear_emoji(v)
	v.emoji.blob, v.emoji.cell = c.emoji.blob, c.emoji.cell
	for n in c.emoji.names {
		append(&v.emoji.names, strings.clone(n))
	}
	v.emoji.revision += 1
}

// Call with the mutex held.
view_clear_emoji :: proc(v: ^View) {
	for n in v.emoji.names {
		delete(n)
	}
	clear(&v.emoji.names)
	v.emoji.blob = 0
}

// typed_text is what was typed as it's stored: mentions and emoji
// written as their tokens and characters (mentions.odin).
typed_text :: proc(c: ^Voice_Client, text: string) -> string {
	return emoji_encode(mentions_encode(text, c.auth.accounts), c.emoji.names[:])
}

package conn

import "core:strings"

import "client:richtext"
import "common:proto"

// The server's custom emoji (src/common/proto/emoji.odin) consist of their names
// and a sheet image containing all of them. The sheet is fetched like a message
// picture (see blobs.odin) and is always kept, regardless of how many other
// pictures are cached. The server sends the emoji when we log in, and again
// whenever its emoji folder changes. Animated emoji each come with a blob of
// their frames (Emoji_Frames), which is fetched and kept the same way.

Emoji_Client :: struct {
	blob:     proto.Blob_Id, // 0 if there is none
	cell:     int,
	names:    [dynamic]string, // owned, in the sheet's order (sorted by name)
	animated: [dynamic]proto.Emoji_Anim, // the ones that move
}

emoji_destroy :: proc(c: ^Server_Conn) {
	emoji_clear(c)
	delete(c.emoji.names)
	delete(c.emoji.animated)
	c.emoji = {}
}

@(private = "file")
emoji_clear :: proc(c: ^Server_Conn) {
	for n in c.emoji.names {
		delete(n)
	}
	clear(&c.emoji.names)
	clear(&c.emoji.animated)
	c.emoji.blob = 0
}

// emoji_event handles an event about the server's emoji. It returns false if
// `op` is not an emoji event.
emoji_event :: proc(c: ^Server_Conn, op: proto.Event_Op, body: []u8) -> bool {
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
	append(&e.animated, ..sheet.animated)
	for a in sheet.animated {
		blob_want(c, {blob = a.blob, size = u32(a.size)}, keep = true)
	}
	publish_emoji(c)
	return true
}

// The server's emoji as seen by the UI.
View_Emoji :: struct {
	blob:     proto.Blob_Id,
	cell:     int,
	names:    [dynamic]string, // owned
	animated: [dynamic]proto.Emoji_Anim, // the ones that move
	revision: int, // incremented whenever the emoji change
}

publish_emoji :: proc(c: ^Server_Conn) {
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
	append(&v.emoji.animated, ..c.emoji.animated[:])
	v.emoji.revision += 1
}

// Call with the mutex held.
view_clear_emoji :: proc(v: ^View) {
	for n in v.emoji.names {
		delete(n)
	}
	clear(&v.emoji.names)
	clear(&v.emoji.animated)
	v.emoji.blob = 0
}

// typed_text converts the text the user typed into the form in which it is
// stored, with mentions and emoji written as tokens and characters
// (see richtext/mentions.odin).
typed_text :: proc(c: ^Server_Conn, text: string) -> string {
	return richtext.emoji_encode(
		richtext.mentions_encode(text, c.auth.accounts, dir_roles(c)),
		c.emoji.names[:],
	)
}

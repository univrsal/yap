#+build !wasi
package client

import "core:testing"

import "client:conn"

@(test)
test_inline_parts :: proc(t: ^testing.T) {
	files := []conn.Msg_File {
		{blob = 1, size = 100, name = "a.png"},
		{blob = 2, size = 100, name = "b.png"},
		{blob = 3, size = 100, name = "doc.pdf"},
	}
	m := conn.View_Message {
		kind  = .Text,
		files = files,
	}

	// No tokens, or none that a picture answers: the text is as it is.
	m.text = "just text"
	parts, in_text := inline_parts(m)
	testing.expect(t, parts == nil && in_text == 0)
	m.text = "<img:nothing.png> and <img:doc.pdf>"
	parts, in_text = inline_parts(m)
	testing.expect(t, parts == nil && in_text == 0)

	// Text, a picture, text, a picture: the line breaks around them are dropped.
	m.text = "before\n<img:a.png>\nmiddle <img:b.png>\n"
	parts, in_text = inline_parts(m)
	testing.expect_value(t, in_text, u32(0b011))
	testing.expect_value(t, len(parts), 4)
	if len(parts) == 4 {
		testing.expect_value(t, parts[0], Inline_Part{"before", -1})
		testing.expect_value(t, parts[1], Inline_Part{"", 0})
		testing.expect_value(t, parts[2], Inline_Part{"middle", -1})
		testing.expect_value(t, parts[3], Inline_Part{"", 1})
	}

	// A message that starts with a picture still starts with a (empty) piece
	// of text, and a name used twice shows the picture once.
	m.text = "<img:a.png> then <img:a.png>"
	parts, in_text = inline_parts(m)
	testing.expect_value(t, in_text, u32(0b001))
	testing.expect_value(t, len(parts), 3)
	if len(parts) == 3 {
		testing.expect_value(t, parts[0], Inline_Part{"", -1})
		testing.expect_value(t, parts[1], Inline_Part{"", 0})
		testing.expect_value(t, parts[2], Inline_Part{"then <img:a.png>", -1})
	}

	// A file that has been removed can't be shown.
	files[0].blob = 0
	m.text = "<img:a.png>"
	parts, in_text = inline_parts(m)
	testing.expect(t, parts == nil && in_text == 0)
}

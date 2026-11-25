package proto

import "core:strings"

// A picture that a message carries can be shown where the text says so, instead
// of under it. The text names it with a token,
//
// 	<img:photo.jpg>   the attachment called photo.jpg
//
// The name is the attachment's, as the message lists it. A client that shows
// the picture there leaves it out of the list under the message. A token that
// names no picture of the message is shown as [photo.jpg], and the server keeps
// the text as it is.

INLINE_IMAGE_PREFIX :: "<img:"

// How many pictures of one message are shown in its text (and so, how many
// pieces of text the message can have: one more than that).
MAX_INLINE_IMAGES :: 8

Inline_Image :: struct {
	start, end: int, // the token: text[start:end]
	name:       string, // the attachment's name
}

// next_inline_image finds the first token that starts at or after `from`.
next_inline_image :: proc(text: string, from := 0) -> (img: Inline_Image, ok: bool) {
	at := from
	for at < len(text) {
		i := strings.index(text[at:], INLINE_IMAGE_PREFIX)
		if i < 0 {
			return
		}
		start := at + i
		rest := text[start + len(INLINE_IMAGE_PREFIX):]
		end := strings.index_byte(rest, '>')
		if end > 0 && end <= MAX_FILE_NAME && !strings.contains_any(rest[:end], "<\n\r") {
			img.start = start
			img.name = rest[:end]
			img.end = start + len(INLINE_IMAGE_PREFIX) + end + 1
			return img, true
		}
		at = start + 1
	}
	return
}

// inline_image_token is the token that names an attachment, in the temp
// allocator.
inline_image_token :: proc(name: string) -> string {
	return strings.concatenate({INLINE_IMAGE_PREFIX, name, ">"}, context.temp_allocator)
}

// inline_images_plain is a text with each token written as [name], for places
// that show the text without the pictures (notifications, previews). Text with
// no token is returned as it is.
inline_images_plain :: proc(text: string) -> string {
	if !strings.contains(text, INLINE_IMAGE_PREFIX) {
		return text
	}
	b := strings.builder_make(context.temp_allocator)
	at := 0
	for {
		img, ok := next_inline_image(text, at)
		if !ok {
			break
		}
		strings.write_string(&b, text[at:img.start])
		strings.write_byte(&b, '[')
		strings.write_string(&b, img.name)
		strings.write_byte(&b, ']')
		at = img.end
	}
	strings.write_string(&b, text[at:])
	return strings.to_string(b)
}

// unlinked_span widens text[start:end], a picture, to the markdown link that
// wraps it, [picture](address): a picture shown in the text needs no link
// around it. Where nothing wraps it, the span is returned as it is.
unlinked_span :: proc(text: string, start, end: int) -> (from, to: int) {
	from, to = start, end
	if start < 1 || text[start - 1] != '[' || !strings.has_prefix(text[end:], "](") {
		return
	}
	depth := 1
	for i := end + 2; i < len(text); i += 1 {
		switch text[i] {
		case '\n':
			return
		case '(':
			depth += 1
		case ')':
			depth -= 1
			if depth == 0 {
				return start - 1, i + 1
			}
		}
	}
	return
}

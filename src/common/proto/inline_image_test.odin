#+build !wasi
package proto

import "core:testing"

@(test)
test_inline_images :: proc(t: ^testing.T) {
	text := "a <img:one.jpg> b <img:two words.png>c"
	img, ok := next_inline_image(text)
	testing.expect(t, ok)
	testing.expect_value(t, img, Inline_Image{start = 2, end = 15, name = "one.jpg"})
	img, ok = next_inline_image(text, img.end)
	testing.expect(t, ok)
	testing.expect_value(t, img.name, "two words.png")
	testing.expect_value(t, text[img.end:], "c")
	_, ok = next_inline_image(text, img.end)
	testing.expect(t, !ok)

	// Not tokens: no name, a line break, another tag inside, no end.
	for bad in ([]string{"<img:>", "<img:a\nb>", "<img:a<b>", "<img:abc", "<img", "no"}) {
		_, ok = next_inline_image(bad)
		testing.expect(t, !ok, bad)
	}
	// A broken start doesn't hide a token after it.
	img, ok = next_inline_image("<img:x <img:y.png>")
	testing.expect(t, !ok || img.name == "y.png")
	testing.expect_value(t, inline_image_token("a b.png"), "<img:a b.png>")
	testing.expect_value(t, inline_images_plain("a <img:x.png> b <img:y>"), "a [x.png] b [y]")
	testing.expect_value(t, inline_images_plain("plain"), "plain")
}

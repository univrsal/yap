package clipboard

// scale_down returns a copy of `img` made smaller to fit `max_side` pixels
// on its longer side, or `img` itself if it already fits (scaled is false
// then, and the caller still owns `img`; otherwise `img` is freed). Both are
// allocated with `allocator`.
//
// Pictures come from other people, and a small file can be a huge picture: a
// plain 7680x4320 PNG takes a few kilobytes and 133 MB once decoded. Nothing
// is shown that big, so pictures are kept at the size they can be shown at.
// Each pixel of the result is the average of the pixels it covers (a box
// filter), weighted by their alpha so that transparent pixels don't darken
// the edges.
scale_down :: proc(
	img: Image,
	max_side: int,
	allocator := context.allocator,
) -> (
	out: Image,
	scaled: bool,
) {
	if img.width <= max_side && img.height <= max_side || max_side <= 0 {
		return img, false
	}
	out.width, out.height = img.width, img.height
	if out.width >= out.height {
		out.height = max(1, img.height * max_side / img.width)
		out.width = max_side
	} else {
		out.width = max(1, img.width * max_side / img.height)
		out.height = max_side
	}
	out.pixels = make([]u8, out.width * out.height * 4, allocator)

	// Each output column covers source columns [x0, x1), and each row covers
	// source rows [y0, y1). Sums for one output row are kept per column.
	sums := make([][4]u64, out.width, context.temp_allocator)
	for oy in 0 ..< out.height {
		y0 := oy * img.height / out.height
		y1 := max((oy + 1) * img.height / out.height, y0 + 1)
		for &s in sums {
			s = {}
		}
		for y in y0 ..< y1 {
			row := img.pixels[y * img.width * 4:][:img.width * 4]
			for ox in 0 ..< out.width {
				x0 := ox * img.width / out.width
				x1 := max((ox + 1) * img.width / out.width, x0 + 1)
				s := &sums[ox]
				for x in x0 ..< x1 {
					p := row[x * 4:][:4]
					a := u64(p[3])
					s[0] += u64(p[0]) * a
					s[1] += u64(p[1]) * a
					s[2] += u64(p[2]) * a
					s[3] += a
				}
			}
		}
		for ox in 0 ..< out.width {
			x0 := ox * img.width / out.width
			x1 := max((ox + 1) * img.width / out.width, x0 + 1)
			count := u64((x1 - x0) * (y1 - y0))
			s := sums[ox]
			p := out.pixels[(oy * out.width + ox) * 4:][:4]
			if s[3] > 0 {
				p[0] = u8(s[0] / s[3])
				p[1] = u8(s[1] / s[3])
				p[2] = u8(s[2] / s[3])
			}
			p[3] = u8(s[3] / count)
		}
	}
	delete(img.pixels, allocator)
	return out, true
}

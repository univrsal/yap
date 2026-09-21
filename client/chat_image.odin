package client

// A picture ready to post in the chat: JPEG bytes and the size they were
// scaled to (see image.odin, which makes these from files and pastes).
Chat_Image :: struct {
	jpeg:          []u8, // owned
	width, height: int, // after scaling
}

chat_image_destroy :: proc(img: ^Chat_Image, allocator := context.allocator) {
	delete(img.jpeg, allocator)
	img^ = {}
}

// fit_box shrinks (never grows) width and height to fit a rectangle,
// keeping the shape of the image.
fit_box :: proc(width, height, max_w, max_h: int) -> (w, h: int) {
	if width <= 0 || height <= 0 {
		return max_w, max_h
	}
	w, h = width, height
	if w > max_w {
		w, h = max_w, max(height * max_w / width, 1)
	}
	if h > max_h {
		w, h = max(w * max_h / h, 1), max_h
	}
	return w, h
}

package conn

// A picture that is ready to be posted in the chat, consisting of the compressed
// bytes and the size the picture was scaled to (see imaging/image.odin, which creates
// these from files and pastes). Profile and server pictures are JPEGs, and
// pasted images are WebPs.
Chat_Image :: struct {
	jpeg:          []u8, // owned
	width, height: int, // after scaling
}

chat_image_destroy :: proc(img: ^Chat_Image, allocator := context.allocator) {
	delete(img.jpeg, allocator)
	img^ = {}
}

// fit_box shrinks width and height to fit inside the given rectangle while
// keeping the aspect ratio. It never enlarges them.
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

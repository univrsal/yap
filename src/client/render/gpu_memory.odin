package render

// Tracks how much memory the textures take, for the memory page
// (ui_memory.odin). GPU memory is not part of the heap, so nothing else
// counts it, but a driver may keep a copy in the process's own memory, and an
// integrated GPU shares the same RAM. The numbers are estimated from the
// texture sizes (a texture with mipmaps takes a third more). They are updated
// by the backends' gpu_texture_make and _delete on the drawing thread.

@(private = "file")
g_textures: map[Gpu_Texture]int

@(private)
texture_noted :: proc(tex: Gpu_Texture, kind: Texture_Kind, width, height: i32, mipmaps: bool) {
	if tex == 0 {
		return
	}
	bytes := int(width) * int(height) * (1 if kind == .Alpha else 4)
	if mipmaps {
		bytes += bytes / 3
	}
	g_textures[tex] = bytes
}

@(private)
texture_forgotten :: proc(tex: Gpu_Texture) {
	delete_key(&g_textures, tex)
}

// texture_memory returns the number of textures and roughly how many bytes
// they take.
texture_memory :: proc() -> (bytes: int, count: int) {
	for _, b in g_textures {
		bytes += b
	}
	return bytes, len(g_textures)
}

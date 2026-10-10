package render

/*
What the textures take, for the memory page (ui_memory.odin): the GPU's
memory isn't the heap's, so nothing else counts it, but a driver may
keep a copy in the process's own, and an integrated GPU's is the same
RAM. Estimated from their sizes - a texture with mipmaps takes a third
more - and kept by the backends' gpu_texture_make and _delete, on the
thread that draws.
*/

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

// texture_memory is how many textures there are, and roughly what they
// take.
texture_memory :: proc() -> (bytes: int, count: int) {
	for _, b in g_textures {
		bytes += b
	}
	return bytes, len(g_textures)
}

#+build !windows
package client

import log "../common/wlog"
import mu "vendor:microui"
import gl "wgl"
import glfw "wglfw"

/*
The renderer's OpenGL 3.3 backend (WebGL 2 in a browser), for everywhere
but Windows. The context lives in the window, so it comes and goes with
it (see window_open).
*/

Gpu :: struct {
	program:  u32,
	vao:      u32,
	vbo:      u32,
	ebo:      u32,
	u_screen: i32,
	u_rgba:   i32,
	fb_h:     i32, // for flipping clip rects, which GL counts from the bottom
	window:   glfw.WindowHandle,
}

/*
WebGL 2 speaks GLSL ES 3.00, which as far as these shaders go is the
same language as desktop GLSL 3.30 - it only wants its own version line
and a default precision for floats.
*/
@(private = "file")
SHADER_HEADER :: "#version 300 es\nprecision highp float;\n" when WEB else "#version 330 core\n"

@(private = "file")
VERTEX_SHADER :: SHADER_HEADER + `layout(location = 0) in vec2 a_pos;
layout(location = 1) in vec2 a_uv;
layout(location = 2) in vec4 a_color;
uniform vec2 u_screen;
out vec2 v_uv;
out vec4 v_color;
void main() {
	v_uv = a_uv;
	v_color = a_color;
	gl_Position = vec4(a_pos.x / u_screen.x * 2.0 - 1.0, 1.0 - a_pos.y / u_screen.y * 2.0, 0.0, 1.0);
}
`

@(private = "file")
FRAGMENT_SHADER :: SHADER_HEADER + `in vec2 v_uv;
in vec4 v_color;
uniform sampler2D u_atlas;
// The atlases keep coverage in their red channel; chat images are
// ordinary colour textures.
uniform bool u_rgba;
out vec4 frag;
void main() {
	vec4 t = texture(u_atlas, v_uv);
	frag = u_rgba ? vec4(t.rgb * v_color.rgb, t.a * v_color.a) : vec4(v_color.rgb, v_color.a * t.r);
}
`

// gpu_window_hints asks GLFW for a window with the context we draw with.
gpu_window_hints :: proc() {
	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 3)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 3)
	glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
	when ODIN_OS == .Darwin {
		glfw.WindowHint(glfw.OPENGL_FORWARD_COMPAT, true)
	}
}

GPU_REQUIREMENT :: "OpenGL 3.3"

gpu_init :: proc(g: ^Gpu, window: glfw.WindowHandle) -> bool {
	g.window = window
	glfw.MakeContextCurrent(window)
	gl.load_up_to(3, 3, glfw.gl_set_proc_address)

	program, ok := gl.load_shaders_source(VERTEX_SHADER, FRAGMENT_SHADER)
	if !ok {
		log.error("gpu: the shaders didn't compile")
		return false
	}
	g.program = program
	g.u_screen = gl.GetUniformLocation(program, "u_screen")
	g.u_rgba = gl.GetUniformLocation(program, "u_rgba")

	gl.GenVertexArrays(1, &g.vao)
	gl.BindVertexArray(g.vao)

	gl.GenBuffers(1, &g.vbo)
	gl.BindBuffer(gl.ARRAY_BUFFER, g.vbo)
	gl.BufferData(gl.ARRAY_BUFFER, MAX_QUADS * 4 * size_of(Vertex), nil, gl.DYNAMIC_DRAW)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 2, gl.FLOAT, false, size_of(Vertex), offset_of(Vertex, pos))
	gl.EnableVertexAttribArray(1)
	gl.VertexAttribPointer(1, 2, gl.FLOAT, false, size_of(Vertex), offset_of(Vertex, uv))
	gl.EnableVertexAttribArray(2)
	gl.VertexAttribPointer(2, 4, gl.UNSIGNED_BYTE, true, size_of(Vertex), offset_of(Vertex, color))

	indices := quad_indices()
	gl.GenBuffers(1, &g.ebo)
	gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, g.ebo)
	gl.BufferData(gl.ELEMENT_ARRAY_BUFFER, size_of(indices^), indices, gl.STATIC_DRAW)
	gl.BindVertexArray(0)
	return true
}

gpu_destroy :: proc(g: ^Gpu) {
	gl.DeleteBuffers(1, &g.ebo)
	gl.DeleteBuffers(1, &g.vbo)
	gl.DeleteVertexArrays(1, &g.vao)
	gl.DeleteProgram(g.program)
	g^ = {}
}

// gpu_lost is whether the device has gone and has to be set up again
// (renderer_reset). An OpenGL context doesn't say.
gpu_lost :: proc(g: ^Gpu) -> bool {
	return false
}

// gpu_swap_interval says how many display refreshes a present waits
// for: 1 for vsync, 0 not to wait (see set_swap_pace).
gpu_swap_interval :: proc(g: ^Gpu, interval: i32) {
	glfw.SwapInterval(interval)
}

// gpu_begin starts a frame, cleared to `clear`, projecting view_w x
// view_h logical pixels onto the fb_w x fb_h framebuffer. False when
// there's nothing to draw into.
gpu_begin :: proc(g: ^Gpu, fb_w, fb_h: i32, view_w, view_h: f32, clear: mu.Color) -> bool {
	g.fb_h = fb_h
	gl.Viewport(0, 0, fb_w, fb_h)
	gl.Disable(gl.SCISSOR_TEST)
	gl.ClearColor(f32(clear.r) / 255, f32(clear.g) / 255, f32(clear.b) / 255, 1)
	gl.Clear(gl.COLOR_BUFFER_BIT)

	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
	gl.Enable(gl.SCISSOR_TEST)
	gl.Scissor(0, 0, fb_w, fb_h)

	gl.UseProgram(g.program)
	gl.Uniform2f(g.u_screen, view_w, view_h)
	gl.BindVertexArray(g.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, g.vbo)
	gl.ActiveTexture(gl.TEXTURE0)
	return true
}

gpu_end :: proc(g: ^Gpu) {
	gl.BindVertexArray(0)
}

gpu_present :: proc(g: ^Gpu) {
	glfw.SwapBuffers(g.window)
}

// gpu_clip limits drawing to a rect of physical pixels, counted from
// the top left.
gpu_clip :: proc(g: ^Gpu, x, y, w, h: i32) {
	gl.Scissor(x, g.fb_h - y - h, w, h)
}

// gpu_draw draws quads (four vertices each, see quad_indices) from `tex`.
gpu_draw :: proc(g: ^Gpu, vertices: []Vertex, tex: Gpu_Texture, kind: Texture_Kind) {
	gl.BindTexture(gl.TEXTURE_2D, u32(tex))
	gl.Uniform1i(g.u_rgba, 1 if kind == .Rgba else 0)
	gl.BufferSubData(gl.ARRAY_BUFFER, 0, len(vertices) * size_of(Vertex), raw_data(vertices))
	gl.DrawElements(gl.TRIANGLES, i32(len(vertices) / 4 * 6), gl.UNSIGNED_SHORT, nil)
}

// gpu_texture_make makes a width x height texture from `pixels` (one
// byte a pixel for .Alpha, four for .Rgba). Without pixels it's left
// empty, for the page's video decoder to fill (video_web.odin).
gpu_texture_make :: proc(g: ^Gpu, kind: Texture_Kind, width, height: i32, pixels: []u8) -> Gpu_Texture {
	tex: u32
	gl.GenTextures(1, &tex)
	gl.BindTexture(gl.TEXTURE_2D, tex)
	if pixels != nil {
		gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
		switch kind {
		case .Alpha:
			gl.TexImage2D(gl.TEXTURE_2D, 0, gl.R8, width, height, 0, gl.RED, gl.UNSIGNED_BYTE, raw_data(pixels))
		case .Rgba:
			gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(pixels))
		}
	}
	filter: i32 = gl.NEAREST if kind == .Alpha else gl.LINEAR
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, filter)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, filter)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.BindTexture(gl.TEXTURE_2D, 0)
	return Gpu_Texture(tex)
}

// gpu_texture_update_rows replaces rows y0 up to y1 of an .Alpha texture
// that is `width` wide with `rows`.
gpu_texture_update_rows :: proc(g: ^Gpu, tex: Gpu_Texture, width, y0, y1: i32, rows: []u8) {
	gl.BindTexture(gl.TEXTURE_2D, u32(tex))
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
	gl.TexSubImage2D(gl.TEXTURE_2D, 0, 0, y0, width, y1 - y0, gl.RED, gl.UNSIGNED_BYTE, raw_data(rows))
	gl.BindTexture(gl.TEXTURE_2D, 0)
}

// gpu_texture_delete deletes `tex`, if there is one, and makes it 0.
gpu_texture_delete :: proc(g: ^Gpu, tex: ^Gpu_Texture) {
	if tex^ != 0 {
		name := u32(tex^)
		gl.DeleteTextures(1, &name)
	}
	tex^ = 0
}

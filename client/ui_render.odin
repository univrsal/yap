package client

import gl "vendor:OpenGL"
import mu "vendor:microui"

/*
Draws microui's command list with OpenGL 3.3: every rect, glyph and icon
is a textured quad from microui's built-in 128x128 alpha atlas (font and
icons included, so there are no asset files). Quads are batched and
flushed whenever the clip rect changes.
*/

@(private = "file")
MAX_QUADS :: 4096

@(private = "file")
Vertex :: struct {
	pos:   [2]f32,
	uv:    [2]f32,
	color: [4]u8,
}

Renderer :: struct {
	program:  u32,
	vao:      u32,
	vbo:      u32,
	ebo:      u32,
	atlas:    u32,
	u_screen: i32,

	vertices: [MAX_QUADS * 4]Vertex,
	quads:    int,

	// Layout happens in window coordinates; the framebuffer may be
	// larger on high-DPI displays.
	width, height: i32,
	scale:         f32,
}

@(private = "file")
VERTEX_SHADER :: `#version 330 core
layout(location = 0) in vec2 a_pos;
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
FRAGMENT_SHADER :: `#version 330 core
in vec2 v_uv;
in vec4 v_color;
uniform sampler2D u_atlas;
out vec4 frag;
void main() {
	frag = vec4(v_color.rgb, v_color.a * texture(u_atlas, v_uv).r);
}
`

renderer_init :: proc(r: ^Renderer) -> bool {
	program, ok := gl.load_shaders_source(VERTEX_SHADER, FRAGMENT_SHADER)
	if !ok {
		return false
	}
	r.program = program
	r.u_screen = gl.GetUniformLocation(program, "u_screen")

	gl.GenVertexArrays(1, &r.vao)
	gl.BindVertexArray(r.vao)

	gl.GenBuffers(1, &r.vbo)
	gl.BindBuffer(gl.ARRAY_BUFFER, r.vbo)
	gl.BufferData(gl.ARRAY_BUFFER, size_of(r.vertices), nil, gl.DYNAMIC_DRAW)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 2, gl.FLOAT, false, size_of(Vertex), offset_of(Vertex, pos))
	gl.EnableVertexAttribArray(1)
	gl.VertexAttribPointer(1, 2, gl.FLOAT, false, size_of(Vertex), offset_of(Vertex, uv))
	gl.EnableVertexAttribArray(2)
	gl.VertexAttribPointer(2, 4, gl.UNSIGNED_BYTE, true, size_of(Vertex), offset_of(Vertex, color))

	// Two triangles per quad, the same pattern every time.
	indices := new([MAX_QUADS * 6]u16, context.temp_allocator)
	for q in 0 ..< MAX_QUADS {
		base := u16(q * 4)
		copy(indices[q * 6:], []u16{base, base + 1, base + 2, base + 2, base + 3, base})
	}
	gl.GenBuffers(1, &r.ebo)
	gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, r.ebo)
	gl.BufferData(gl.ELEMENT_ARRAY_BUFFER, size_of(indices^), indices, gl.STATIC_DRAW)

	gl.GenTextures(1, &r.atlas)
	gl.BindTexture(gl.TEXTURE_2D, r.atlas)
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.R8, mu.DEFAULT_ATLAS_WIDTH, mu.DEFAULT_ATLAS_HEIGHT, 0,
		gl.RED, gl.UNSIGNED_BYTE, &mu.default_atlas_alpha)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)

	gl.BindVertexArray(0)
	return true
}

renderer_destroy :: proc(r: ^Renderer) {
	gl.DeleteTextures(1, &r.atlas)
	gl.DeleteBuffers(1, &r.ebo)
	gl.DeleteBuffers(1, &r.vbo)
	gl.DeleteVertexArrays(1, &r.vao)
	gl.DeleteProgram(r.program)
}

// render draws one frame of microui output. width/height are the window
// size (what microui laid out for); fb_width/fb_height the framebuffer.
render :: proc(r: ^Renderer, ctx: ^mu.Context, width, height, fb_width, fb_height: i32, clear: mu.Color) {
	r.width, r.height = width, height
	r.scale = width > 0 ? f32(fb_width) / f32(width) : 1

	gl.Viewport(0, 0, fb_width, fb_height)
	gl.Disable(gl.SCISSOR_TEST)
	gl.ClearColor(f32(clear.r) / 255, f32(clear.g) / 255, f32(clear.b) / 255, 1)
	gl.Clear(gl.COLOR_BUFFER_BIT)

	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
	gl.Enable(gl.SCISSOR_TEST)
	gl.Scissor(0, 0, fb_width, fb_height)

	gl.UseProgram(r.program)
	gl.Uniform2f(r.u_screen, f32(width), f32(height))
	gl.BindVertexArray(r.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, r.vbo)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, r.atlas)

	cmd: ^mu.Command
	for variant in mu.next_command_iterator(ctx, &cmd) {
		switch c in variant {
		case ^mu.Command_Text:
			draw_text(r, c.str, c.pos, c.color)
		case ^mu.Command_Rect:
			push_quad(r, c.rect, mu.default_atlas[mu.DEFAULT_ATLAS_WHITE], c.color)
		case ^mu.Command_Icon:
			src := mu.default_atlas[c.id]
			x := c.rect.x + (c.rect.w - src.w) / 2
			y := c.rect.y + (c.rect.h - src.h) / 2
			push_quad(r, {x, y, src.w, src.h}, src, c.color)
		case ^mu.Command_Clip:
			flush(r)
			set_clip(r, c.rect)
		case ^mu.Command_Jump:
			unreachable()
		}
	}
	flush(r)
	gl.BindVertexArray(0)
}

@(private = "file")
draw_text :: proc(r: ^Renderer, text: string, pos: mu.Vec2, color: mu.Color) {
	// Mirrors mu.default_atlas_text_width: ASCII only, one glyph per
	// UTF-8 sequence, anything beyond ASCII drawn as the last glyph.
	x := pos.x
	for b in transmute([]u8)text {
		if b & 0xc0 == 0x80 {
			continue
		}
		src := mu.default_atlas[mu.DEFAULT_ATLAS_FONT + min(int(b), 127)]
		push_quad(r, {x, pos.y, src.w, src.h}, src, color)
		x += src.w
	}
}

@(private = "file")
push_quad :: proc(r: ^Renderer, dst, src: mu.Rect, color: mu.Color) {
	if r.quads == MAX_QUADS {
		flush(r)
	}
	ATLAS :: f32(mu.DEFAULT_ATLAS_WIDTH)
	x0, y0 := f32(dst.x), f32(dst.y)
	x1, y1 := f32(dst.x + dst.w), f32(dst.y + dst.h)
	u0, v0 := f32(src.x) / ATLAS, f32(src.y) / ATLAS
	u1, v1 := f32(src.x + src.w) / ATLAS, f32(src.y + src.h) / ATLAS
	c := [4]u8{color.r, color.g, color.b, color.a}

	v := r.vertices[r.quads * 4:]
	v[0] = {{x0, y0}, {u0, v0}, c}
	v[1] = {{x1, y0}, {u1, v0}, c}
	v[2] = {{x1, y1}, {u1, v1}, c}
	v[3] = {{x0, y1}, {u0, v1}, c}
	r.quads += 1
}

@(private = "file")
flush :: proc(r: ^Renderer) {
	if r.quads == 0 {
		return
	}
	gl.BufferSubData(gl.ARRAY_BUFFER, 0, r.quads * 4 * size_of(Vertex), &r.vertices[0])
	gl.DrawElements(gl.TRIANGLES, i32(r.quads * 6), gl.UNSIGNED_SHORT, nil)
	r.quads = 0
}

@(private = "file")
set_clip :: proc(r: ^Renderer, rect: mu.Rect) {
	// GL's scissor origin is bottom-left, in framebuffer pixels.
	s := r.scale
	gl.Scissor(
		i32(f32(rect.x) * s),
		i32(f32(r.height - (rect.y + rect.h)) * s),
		i32(f32(rect.w) * s),
		i32(f32(rect.h) * s),
	)
}

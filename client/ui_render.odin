package client

import "core:math"
import gl "vendor:OpenGL"
import mu "vendor:microui"

/*
Draws microui's command list with OpenGL 3.3. Rects and text are quads
from the font atlas (ui_font.odin), rasterized at the display's density
so they stay sharp on high-DPI screens; microui's own icons come from its
built-in atlas. Quads are batched and flushed whenever the clip rect or
the texture changes.

Everything is laid out in logical pixels; `scale` is physical pixels per
logical pixel.
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
	program:      u32,
	vao:          u32,
	vbo:          u32,
	ebo:          u32,
	u_screen:     i32,
	font:         Font,
	font_texture: u32,
	icon_texture: u32, // microui's own icons
	icons:        Icon_Atlas, // ours (ui_icons.odin)
	icons_texture: u32,
	bound:        u32, // texture the pending quads use
	rgba:         bool, // the bound texture is a picture, not the atlas
	u_rgba:       i32,
	images:       ^UI_Images, // this frame's chat images (ui_images.odin)
	vertices:     [MAX_QUADS * 4]Vertex,
	quads:        int,
	height:       f32, // logical
	scale:        f32,
}

// The font microui measures text with (its callbacks take no user data).
@(private = "file")
g_font: ^Font

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
// The atlases keep coverage in their red channel; chat images are
// ordinary colour textures.
uniform bool u_rgba;
out vec4 frag;
void main() {
	vec4 t = texture(u_atlas, v_uv);
	frag = u_rgba ? vec4(t.rgb * v_color.rgb, t.a * v_color.a) : vec4(v_color.rgb, v_color.a * t.r);
}
`

renderer_init :: proc(r: ^Renderer) -> bool {
	if !font_init(&r.font) {
		return false
	}
	g_font = &r.font

	program, ok := gl.load_shaders_source(VERTEX_SHADER, FRAGMENT_SHADER)
	if !ok {
		return false
	}
	r.program = program
	r.u_screen = gl.GetUniformLocation(program, "u_screen")
	r.u_rgba = gl.GetUniformLocation(program, "u_rgba")

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
	gl.BindVertexArray(0)

	r.icon_texture = make_alpha_texture(
		mu.DEFAULT_ATLAS_WIDTH,
		mu.DEFAULT_ATLAS_HEIGHT,
		mu.default_atlas_alpha[:],
	)
	return true
}

renderer_destroy :: proc(r: ^Renderer) {
	gl.DeleteTextures(1, &r.font_texture)
	gl.DeleteTextures(1, &r.icon_texture)
	gl.DeleteTextures(1, &r.icons_texture)
	icon_atlas_destroy(&r.icons)
	gl.DeleteBuffers(1, &r.ebo)
	gl.DeleteBuffers(1, &r.vbo)
	gl.DeleteVertexArrays(1, &r.vao)
	gl.DeleteProgram(r.program)
	font_destroy(&r.font)
	// Nothing in here outlives the OpenGL context it was made in: the
	// window can be taken down and built again (window_close), and a
	// texture name left lying about would then belong to somebody else.
	r^ = {}
}

// microui text metrics, in logical pixels.
ui_text_width :: proc(font: mu.Font, text: string) -> i32 {
	return i32(math.ceil(font_text_width(g_font, text)))
}

ui_text_height :: proc(font: mu.Font) -> i32 {
	return LINE_HEIGHT
}

// render draws one frame of microui output. The layout was done for a
// logical_w x logical_h window; the framebuffer is fb_w x fb_h, and
// `scale` is physical pixels per logical pixel (the display's density).
render :: proc(
	r: ^Renderer,
	ctx: ^mu.Context,
	logical_w, logical_h: f32,
	fb_w, fb_h: i32,
	scale: f32,
	clear: mu.Color,
) {
	r.height, r.scale = logical_h, scale

	if scale != r.font.scale {
		if font_build_atlas(&r.font, scale) {
			gl.DeleteTextures(1, &r.font_texture)
			r.font_texture = make_alpha_texture(r.font.width, r.font.height, r.font.pixels)
		}
	}
	if scale != r.icons.scale {
		if icon_atlas_build(&r.icons, scale) {
			gl.DeleteTextures(1, &r.icons_texture)
			r.icons_texture = make_alpha_texture(r.icons.width, r.icons.height, r.icons.pixels)
		}
	}

	gl.Viewport(0, 0, fb_w, fb_h)
	gl.Disable(gl.SCISSOR_TEST)
	gl.ClearColor(f32(clear.r) / 255, f32(clear.g) / 255, f32(clear.b) / 255, 1)
	gl.Clear(gl.COLOR_BUFFER_BIT)

	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
	gl.Enable(gl.SCISSOR_TEST)
	gl.Scissor(0, 0, fb_w, fb_h)

	gl.UseProgram(r.program)
	gl.Uniform2f(r.u_screen, logical_w, logical_h)
	gl.BindVertexArray(r.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, r.vbo)
	gl.ActiveTexture(gl.TEXTURE0)
	r.bound = 0

	cmd: ^mu.Command
	for variant in mu.next_command_iterator(ctx, &cmd) {
		switch c in variant {
		case ^mu.Command_Text:
			use_texture(r, r.font_texture)
			Emit :: struct {
				r:     ^Renderer,
				color: mu.Color,
			}
			emit := Emit{r, c.color}
			font_layout(
				&r.font,
				c.str,
				f32(c.pos.x),
				f32(c.pos.y),
				&emit,
				proc(data: rawptr, q: Glyph_Quad) {
					e := (^Emit)(data)
					push_quad(e.r, {q.x0, q.y0, q.x1, q.y1}, {q.u0, q.v0, q.u1, q.v1}, e.color)
				},
			)
		case ^mu.Command_Rect:
			use_texture(r, r.font_texture)
			// Snap edges to physical pixels so borders stay crisp at
			// fractional scales.
			w := r.font.white
			snap :: proc(v: i32, s: f32) -> f32 {return math.round(f32(v) * s) / s}
			x0, y0 := snap(c.rect.x, r.scale), snap(c.rect.y, r.scale)
			x1, y1 := snap(c.rect.x + c.rect.w, r.scale), snap(c.rect.y + c.rect.h, r.scale)
			push_quad(r, {x0, y0, x1, y1}, {w.x, w.y, w.x, w.y}, c.color)
		case ^mu.Command_Icon:
			if index := int(c.id) - IMAGE_ICON_BASE; index >= 0 {
				draw_image(r, index, c.rect, c.color)
				continue
			}
			if index := int(c.id) - UI_ICON_BASE; index >= 0 {
				draw_ui_icon(r, Icon(index), c.rect, c.color)
				continue
			}
			use_texture(r, r.icon_texture)
			src := mu.default_atlas[c.id]
			x := f32(c.rect.x + (c.rect.w - src.w) / 2)
			y := f32(c.rect.y + (c.rect.h - src.h) / 2)
			A :: f32(mu.DEFAULT_ATLAS_WIDTH)
			push_quad(
				r,
				{x, y, x + f32(src.w), y + f32(src.h)},
				{f32(src.x) / A, f32(src.y) / A, f32(src.x + src.w) / A, f32(src.y + src.h) / A},
				c.color,
			)
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
make_alpha_texture :: proc(width, height: i32, pixels: []u8) -> (tex: u32) {
	gl.GenTextures(1, &tex)
	gl.BindTexture(gl.TEXTURE_2D, tex)
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
	gl.TexImage2D(
		gl.TEXTURE_2D,
		0,
		gl.R8,
		width,
		height,
		0,
		gl.RED,
		gl.UNSIGNED_BYTE,
		raw_data(pixels),
	)
	// Glyphs are drawn 1:1 with physical pixels, so no filtering is wanted.
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
	return
}

@(private = "file")
use_texture :: proc(r: ^Renderer, tex: u32, rgba := false) {
	if r.bound != tex || r.rgba != rgba {
		flush(r)
		gl.BindTexture(gl.TEXTURE_2D, tex)
		gl.Uniform1i(r.u_rgba, 1 if rgba else 0)
		r.bound, r.rgba = tex, rgba
	}
}

// draw_image draws one of this frame's chat images, which come as icon
// commands so microui clips and layers them like anything else.
@(private = "file")
draw_image :: proc(r: ^Renderer, index: int, rect: mu.Rect, color: mu.Color) {
	if r.images == nil || index >= len(r.images.draws) {
		return
	}
	use_texture(r, r.images.draws[index].texture, rgba = true)
	push_quad(
		r,
		{f32(rect.x), f32(rect.y), f32(rect.x + rect.w), f32(rect.y + rect.h)},
		{0, 0, 1, 1},
		color,
	)
}

/*
draw_ui_icon draws one of our own icons (ui_icons.odin), centred in the
space the layout gave it. It's drawn at the size it was rasterized for,
snapped to physical pixels, so it stays as crisp as the text beside it.
*/
@(private = "file")
draw_ui_icon :: proc(r: ^Renderer, icon: Icon, rect: mu.Rect, color: mu.Color) {
	if r.icons.side == 0 || int(icon) >= len(Icon) {
		return
	}
	use_texture(r, r.icons_texture)
	side := f32(r.icons.side) / r.scale
	snap :: proc(v: f32, s: f32) -> f32 {return math.round(v * s) / s}
	x := snap(f32(rect.x) + (f32(rect.w) - side) / 2, r.scale)
	y := snap(f32(rect.y) + (f32(rect.h) - side) / 2, r.scale)
	u0 := f32(int(icon) * int(r.icons.side)) / f32(r.icons.width)
	u1 := f32((int(icon) + 1) * int(r.icons.side)) / f32(r.icons.width)
	push_quad(r, {x, y, x + side, y + side}, {u0, 0, u1, 1}, color)
}

// dst and uv are {x0, y0, x1, y1}.
@(private = "file")
push_quad :: proc(r: ^Renderer, dst, uv: [4]f32, color: mu.Color) {
	if r.quads == MAX_QUADS {
		flush(r)
	}
	c := [4]u8{color.r, color.g, color.b, color.a}
	v := r.vertices[r.quads * 4:]
	v[0] = {{dst[0], dst[1]}, {uv[0], uv[1]}, c}
	v[1] = {{dst[2], dst[1]}, {uv[2], uv[1]}, c}
	v[2] = {{dst[2], dst[3]}, {uv[2], uv[3]}, c}
	v[3] = {{dst[0], dst[3]}, {uv[0], uv[3]}, c}
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
	x0 := math.round(f32(rect.x) * s)
	x1 := math.round(f32(rect.x + rect.w) * s)
	y0 := math.round((r.height - f32(rect.y + rect.h)) * s)
	y1 := math.round((r.height - f32(rect.y)) * s)
	gl.Scissor(i32(x0), i32(y0), i32(x1 - x0), i32(y1 - y0))
}

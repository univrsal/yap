package render

import glfw "client:wglfw"
import "core:math"
import mu "vendor:microui"

/*
Draws microui's command list. Rects and text are quads from the font
atlas (font.odin), rasterized at the display's density so they stay
sharp on high-DPI screens; microui's own icons come from its built-in
atlas. Quads are batched and flushed whenever the clip rect or the
texture changes.

What the quads are drawn with is the GPU backend's business: Direct3D 11
on Windows (gpu_d3d11.odin), OpenGL everywhere else (gpu_gl.odin).
Both give the same procs, gpu_*, over the same vertices.

Everything is laid out in logical pixels; `scale` is physical pixels per
logical pixel.
*/

MAX_QUADS :: 4096

Vertex :: struct {
	pos:   [2]f32,
	uv:    [2]f32,
	color: [4]u8,
}

/*
A texture, as the backend knows it: an OpenGL texture name, or a pointer
to the backend's own record of one. 0 is none.
*/
Gpu_Texture :: distinct uintptr

// What a texture holds, which decides how it's drawn.
Texture_Kind :: enum {
	// Coverage for text and icons, one byte a pixel, drawn in the
	// quad's colour and 1:1 with physical pixels, so without filtering.
	Alpha,
	// A picture, RGBA, usually drawn smaller than it is, so filtered.
	Rgba,
}

// Icon ids from here on mean "the picture at this index of the frame's
// draw list" (Renderer.images), which microui's own icons never reach.
IMAGE_ICON_BASE :: 1000

Image_Draw :: struct {
	texture: Gpu_Texture,
	// The part of the texture to draw (u0, v0, u1, v1); all of it if zero.
	uv:      [4]f32,
}

/*
The fonts: the UI's, and the chat's, which is the same font zoomed to
the chat's size (font.odin). microui names a font by an opaque handle,
which says which of the two and which face (Font_Style): nil is the
UI's in Regular (microui's default), CHAT_FONT the chat's, and
chat_font any face of the chat's.
*/
Font_Kind :: enum {
	UI,
	Chat,
}

CHAT_FONT :: mu.Font(uintptr(1))

// font_handle is the handle for `kind`'s font in `style`.
font_handle :: proc(kind: Font_Kind, style: Font_Style) -> mu.Font {
	return mu.Font(uintptr(kind) | uintptr(style) << 4)
}

// chat_font is the handle for the chat's font in `style`.
chat_font :: proc(style: Font_Style) -> mu.Font {
	return font_handle(.Chat, style)
}

// font_with_style is `font` (the UI's or the chat's) in another face.
font_with_style :: proc(font: mu.Font, style: Font_Style) -> mu.Font {
	return mu.Font(uintptr(font) & 0xf | uintptr(style) << 4)
}

// font_style is the face a handle names.
font_style :: proc(font: mu.Font) -> Font_Style {
	return Font_Style((uintptr(font) >> 4) % len(Font_Style))
}

Font_Slot :: struct {
	font:            Font,
	textures:        [Font_Style]Gpu_Texture, // the faces' atlases; 0 until drawn
	unifont_texture: Gpu_Texture, // the fallback font's atlas; 0 until it has glyphs
	// The zoom wanted (font_set_zoom); the font takes it with its next
	// atlas.
	zoom:            f32,
}

Renderer :: struct {
	gpu:           Gpu,
	fonts:         [Font_Kind]Font_Slot,
	icon_texture:  Gpu_Texture, // microui's own icons
	icons:         Icon_Atlas, // ours (icons.odin)
	icons_texture: Gpu_Texture,
	bound:         Gpu_Texture, // texture the pending quads use
	rgba:          bool, // the bound texture is a picture, not the atlas
	images:        ^[dynamic]Image_Draw, // this frame's pictures; the UI's to fill
	vertices:      [MAX_QUADS * 4]Vertex,
	quads:         int,
	scale:         f32,
}

// The fonts microui measures text with (its callbacks take no user data).
@(private = "file")
g_fonts: ^[Font_Kind]Font_Slot

// slot_of is the font microui's handle names (font_style its face).
@(private = "file")
slot_of :: proc(fonts: ^[Font_Kind]Font_Slot, font: mu.Font) -> ^Font_Slot {
	return &fonts[.Chat] if uintptr(font) & 0xf == uintptr(Font_Kind.Chat) else &fonts[.UI]
}

/*
set_chat_zoom sets how much bigger than the UI's text the chat's is (1
is the same). Measuring takes it at once; the glyphs are rasterized
again for it at the next frame.
*/
set_chat_zoom :: proc(r: ^Renderer, zoom: f32) {
	slot := &r.fonts[.Chat]
	if zoom == slot.zoom {
		return
	}
	slot.zoom = zoom
	slot.font.zoom = zoom
	// Built again, at the new size, by the next frame.
	slot.font.scale, slot.font.uni.scale = 0, 0
}

// quad_indices is the index buffer's contents: two triangles per quad,
// the same pattern every time. In the temp allocator.
quad_indices :: proc() -> ^[MAX_QUADS * 6]u16 {
	indices := new([MAX_QUADS * 6]u16, context.temp_allocator)
	for q in 0 ..< MAX_QUADS {
		base := u16(q * 4)
		copy(indices[q * 6:], []u16{base, base + 1, base + 2, base + 2, base + 3, base})
	}
	return indices
}

// renderer_init sets up drawing into `window`, which was made with
// gpu_window_hints.
renderer_init :: proc(r: ^Renderer, window: glfw.WindowHandle) -> bool {
	for &slot in r.fonts {
		if !font_init(&slot.font) {
			for &other in r.fonts {
				font_destroy(&other.font)
			}
			return false
		}
		slot.zoom = 1
	}
	g_fonts = &r.fonts
	if !gpu_init(&r.gpu, window) {
		for &slot in r.fonts {
			font_destroy(&slot.font)
		}
		return false
	}
	r.icon_texture = gpu_texture_make(
		&r.gpu,
		.Alpha,
		mu.DEFAULT_ATLAS_WIDTH,
		mu.DEFAULT_ATLAS_HEIGHT,
		mu.default_atlas_alpha[:],
	)
	return true
}

renderer_destroy :: proc(r: ^Renderer) {
	for &slot in r.fonts {
		for &t in slot.textures {
			gpu_texture_delete(&r.gpu, &t)
		}
		gpu_texture_delete(&r.gpu, &slot.unifont_texture)
	}
	gpu_texture_delete(&r.gpu, &r.icon_texture)
	gpu_texture_delete(&r.gpu, &r.icons_texture)
	icon_atlas_destroy(&r.icons)
	gpu_destroy(&r.gpu)
	for &slot in r.fonts {
		font_destroy(&slot.font)
	}
	// Nothing in here outlives the device it was made on: the window can
	// be taken down and built again (window_close), and a texture left
	// lying about would then belong to somebody else.
	r^ = {}
}

/*
renderer_reset makes what's on the GPU again for the same window, after
the device was lost (gpu_lost). The atlases are rebuilt, and uploaded
with them, when the next frame finds them missing.
*/
renderer_reset :: proc(r: ^Renderer, window: glfw.WindowHandle) -> bool {
	for &slot in r.fonts {
		for &t in slot.textures {
			gpu_texture_delete(&r.gpu, &t)
		}
		gpu_texture_delete(&r.gpu, &slot.unifont_texture)
		slot.font.scale, slot.font.uni.scale = 0, 0
	}
	gpu_texture_delete(&r.gpu, &r.icon_texture)
	gpu_texture_delete(&r.gpu, &r.icons_texture)
	gpu_destroy(&r.gpu)
	r.icons.scale = 0
	if !gpu_init(&r.gpu, window) {
		return false
	}
	r.icon_texture = gpu_texture_make(
		&r.gpu,
		.Alpha,
		mu.DEFAULT_ATLAS_WIDTH,
		mu.DEFAULT_ATLAS_HEIGHT,
		mu.default_atlas_alpha[:],
	)
	return true
}

// microui text metrics, in logical pixels.
ui_text_width :: proc(font: mu.Font, text: string) -> i32 {
	return i32(math.ceil(font_text_width(&slot_of(g_fonts, font).font, text, font_style(font))))
}

ui_text_height :: proc(font: mu.Font) -> i32 {
	return font_line_height(&slot_of(g_fonts, font).font)
}

// render draws one frame of microui output into an fb_w x fb_h
// framebuffer; `scale` is physical pixels per logical pixel (the display's
// density).
render :: proc(r: ^Renderer, ctx: ^mu.Context, fb_w, fb_h: i32, scale: f32, clear: mu.Color) {
	// Everything is snapped to physical pixels as round(v * scale) /
	// scale, which only lands on them if the projection maps a logical
	// pixel to exactly `scale` physical ones, on both axes. The layout's
	// logical size (window_metrics) needn't be quite fb / scale (the framebuffer
	// comes in whole pixels, and a width ratio needn't match the
	// height's), and projecting that instead stretches everything by a
	// fraction of a pixel, which depends on the window's size: at 1.5,
	// a glyph's stem would move into the next pixel column as the window
	// is resized. So project fb / scale, which differs from the layout
	// by less than a logical pixel at the right and bottom edges.
	view_w, view_h := f32(fb_w) / scale, f32(fb_h) / scale
	r.scale = scale
	if !gpu_begin(&r.gpu, fb_w, fb_h, view_w, view_h, clear) {
		return // minimized, or the device is gone
	}

	for &slot in r.fonts {
		// A zoomed font's atlases are at its own density (font.odin).
		// Regular's is always there (rects are drawn from it); the other
		// faces' are built when text in them is first drawn.
		at := scale * slot.font.zoom
		if at != slot.font.scale {
			font_set_scale(&slot.font, at)
		}
		face_ready(r, &slot, .Regular)
		// The fallback font's atlas fills up as text needs glyphs; it
		// starts empty at a new scale, and again once it has run out of
		// room.
		if at != slot.font.uni.scale || slot.font.uni.full {
			unifont_reset(&slot.font.uni, at)
			gpu_texture_delete(&r.gpu, &slot.unifont_texture)
		}
	}
	if scale != r.icons.scale {
		if icon_atlas_build(&r.icons, scale) {
			gpu_texture_delete(&r.gpu, &r.icons_texture)
			r.icons_texture = gpu_texture_make(
				&r.gpu,
				.Alpha,
				r.icons.width,
				r.icons.height,
				r.icons.pixels,
			)
		}
	}

	r.bound, r.rgba = 0, false

	cmd: ^mu.Command
	for variant in mu.next_command_iterator(ctx, &cmd) {
		switch c in variant {
		case ^mu.Command_Text:
			slot := slot_of(&r.fonts, c.font)
			style := font_style(c.font)
			font_cache_glyphs(&slot.font, c.str, style)
			upload_unifont(r, slot)
			if style != .Regular {
				for face in font_faces_used(&slot.font, c.str, style) {
					face_ready(r, slot, face)
				}
			}
			Emit :: struct {
				r:     ^Renderer,
				slot:  ^Font_Slot,
				color: mu.Color,
			}
			emit := Emit{r, slot, c.color}
			font_layout(
				&slot.font,
				c.str,
				f32(c.pos.x),
				f32(c.pos.y),
				&emit,
				proc(data: rawptr, q: Glyph_Quad) {
					e := (^Emit)(data)
					use_texture(
						e.r,
						e.slot.unifont_texture if q.unifont else e.slot.textures[q.face],
					)
					push_quad(e.r, {q.x0, q.y0, q.x1, q.y1}, {q.u0, q.v0, q.u1, q.v1}, e.color)
				},
				style,
			)
		case ^mu.Command_Rect:
			ui_font := &r.fonts[.UI]
			use_texture(r, ui_font.textures[.Regular])
			// Snap edges to physical pixels so borders stay crisp at
			// fractional scales.
			w := ui_font.font.faces[.Regular].white
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
	gpu_end(&r.gpu)
}

// face_ready has a face's atlas built for the font's scale and on the GPU.
@(private = "file")
face_ready :: proc(r: ^Renderer, slot: ^Font_Slot, face: Font_Style) {
	fc := &slot.font.faces[face]
	if font_build_atlas(&slot.font, face) || (slot.textures[face] == 0 && fc.pixels != nil) {
		gpu_texture_delete(&r.gpu, &slot.textures[face])
		slot.textures[face] = gpu_texture_make(&r.gpu, .Alpha, fc.width, fc.height, fc.pixels)
	}
}

/*
upload_unifont sends the rows of the fallback font's atlas that have
changed to its texture, making the texture the first time. Glyphs only
ever go into empty slots, so quads already waiting to be drawn still
find theirs.
*/
@(private = "file")
upload_unifont :: proc(r: ^Renderer, slot: ^Font_Slot) {
	u := &slot.font.uni
	if u.dirty_y1 <= u.dirty_y0 {
		return
	}
	if slot.unifont_texture == 0 {
		slot.unifont_texture = gpu_texture_make(&r.gpu, .Alpha, u.side, u.side, u.pixels)
	} else {
		rows := u.pixels[int(u.dirty_y0) * int(u.side):int(u.dirty_y1) * int(u.side)]
		gpu_texture_update_rows(&r.gpu, slot.unifont_texture, u.side, u.dirty_y0, u.dirty_y1, rows)
	}
	u.dirty_y0, u.dirty_y1 = u.side, 0
}

@(private = "file")
use_texture :: proc(r: ^Renderer, tex: Gpu_Texture, rgba := false) {
	if r.bound != tex || r.rgba != rgba {
		flush(r)
		r.bound, r.rgba = tex, rgba
	}
}

// draw_image draws one of this frame's chat images, which come as icon
// commands so microui clips and layers them like anything else.
@(private = "file")
draw_image :: proc(r: ^Renderer, index: int, rect: mu.Rect, color: mu.Color) {
	if r.images == nil || index >= len(r.images) {
		return
	}
	use_texture(r, r.images[index].texture, rgba = true)
	uv := r.images[index].uv
	if uv == {} {
		uv = {0, 0, 1, 1}
	}
	push_quad(
		r,
		{f32(rect.x), f32(rect.y), f32(rect.x + rect.w), f32(rect.y + rect.h)},
		{uv[0], uv[1], uv[2], uv[3]},
		color,
	)
}

/*
draw_ui_icon draws one of our own icons (icons.odin), centred in the
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
	gpu_draw(&r.gpu, r.vertices[:r.quads * 4], r.bound, .Rgba if r.rgba else .Alpha)
	r.quads = 0
}

@(private = "file")
set_clip :: proc(r: ^Renderer, rect: mu.Rect) {
	s := r.scale
	x0 := math.round(f32(rect.x) * s)
	x1 := math.round(f32(rect.x + rect.w) * s)
	y0 := math.round(f32(rect.y) * s)
	y1 := math.round(f32(rect.y + rect.h) * s)
	gpu_clip(&r.gpu, i32(x0), i32(y0), i32(x1 - x0), i32(y1 - y0))
}

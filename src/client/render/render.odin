package render

import glfw "client:wglfw"
import "core:math"
import mu "vendor:microui"

// Draws microui's command list. Rects and text are quads from the font atlas
// (font.odin), which is rasterized at the display's density so they stay sharp
// on high-DPI screens. microui's own icons come from its built-in atlas. Quads
// are batched and flushed whenever the clip rect or the texture changes.
//
// How the quads are drawn is up to the GPU backend: Direct3D 11 on Windows
// (gpu_d3d11.odin), Metal on macOS (gpu_metal.odin) and OpenGL everywhere else
// (gpu_gl.odin). All of them provide the same gpu_* procs over the same
// vertices.
//
// Everything is laid out in logical pixels, and `scale` is the number of
// physical pixels per logical pixel.

MAX_QUADS :: 4096

Vertex :: struct {
	pos:   [2]f32,
	uv:    [2]f32,
	color: [4]u8,
}

// A texture as the backend knows it: an OpenGL texture name or a pointer to
// the backend's own record of a texture. 0 means no texture.
Gpu_Texture :: distinct uintptr

// The underlying device, for a library that creates textures that we draw
// (yap_video, see conn/video_native.odin). This is Direct3D 11's
// ID3D11Device, Metal's MTLDevice together with the MTLCommandQueue that the
// frames go through, or, for OpenGL, glfwGetProcAddress to look up the
// current context's functions.
Gpu_Native :: struct {
	d3d11_device: rawptr,
	gl_get_proc:  rawptr,
	metal_device: rawptr,
	metal_queue:  rawptr,
}

// What a texture holds, which determines how it is drawn.
Texture_Kind :: enum {
	// Coverage for text and icons, one byte per pixel. It is drawn in the
	// quad's color and 1:1 with physical pixels, so without filtering.
	Alpha,
	// A picture in RGBA, usually drawn smaller than its original size, so
	// it is filtered.
	Rgba,
}

// Icon ids from here on mean "the picture at this index of the frame's draw
// list" (Renderer.images). microui's own icons never reach this range.
IMAGE_ICON_BASE :: 1000

// An icon command with this id is a border around its rect (draw_border).
BORDER_ICON :: mu.Icon(UI_ICON_BASE - 1)
// An icon command with this id is the filled area inside that border
// (draw_frame).
INSIDE_BORDER_ICON :: mu.Icon(UI_ICON_BASE - 2)

// draw_border draws a one pixel border inside `rect` like mu.draw_box does,
// but as a single command so the renderer can snap it as a whole
// (push_border).
draw_border :: proc(ctx: ^mu.Context, rect: mu.Rect, color: mu.Color) {
	mu.draw_icon(ctx, BORDER_ICON, rect, color)
}

// draw_frame is microui's default_draw_frame, with its border drawn by
// draw_border. Set it as the context's draw_frame. With a border, the fill is
// snapped from the same box as the border and fills exactly the area inside
// it. If the fill were snapped on its own, it could leave a one pixel gap
// inside the border on some sides but not on others.
draw_frame :: proc(ctx: ^mu.Context, rect: mu.Rect, colorid: mu.Color_Type) {
	bordered :=
		colorid != .SCROLL_BASE &&
		colorid != .SCROLL_THUMB &&
		colorid != .TITLE_BG &&
		ctx.style.colors[.BORDER].a != 0
	if !bordered {
		mu.draw_rect(ctx, rect, ctx.style.colors[colorid])
		return
	}
	outer := mu.expand_rect(rect, 1)
	if color := ctx.style.colors[colorid]; color.a != 0 {
		mu.draw_icon(ctx, INSIDE_BORDER_ICON, outer, color)
	}
	draw_border(ctx, outer, ctx.style.colors[.BORDER])
}

Image_Draw :: struct {
	texture: Gpu_Texture,
	// The part of the texture to draw (u0, v0, u1, v1), or all of it if
	// zero.
	uv:      [4]f32,
	// The image is drawn this many line thicknesses (push_border's) in from
	// its rect on every side, once that is snapped. This keeps a dot inside
	// a ring with the same rect in the middle at any scale.
	inset:   i32,
}

// The fonts are the UI's and the chat's, which is the same font zoomed to the
// chat's size (font.odin). microui refers to a font by an opaque handle that
// identifies which of the two fonts and which face (Font_Style) is meant. nil
// is the UI's font in Regular (microui's default), CHAT_FONT is the chat's
// font, and chat_font gives any face of the chat's font.
Font_Kind :: enum {
	UI,
	Chat,
	// The UI's font blown up PREVIEW_ZOOM times, for looking at an emoji
	// closely (a hover preview). Its atlases are only created once it is
	// drawn with.
	Preview,
}

PREVIEW_ZOOM :: 3

// PREVIEW_FONT is the handle of the large font.
PREVIEW_FONT :: mu.Font(uintptr(Font_Kind.Preview))

CHAT_FONT :: mu.Font(uintptr(1))

// font_handle returns the handle for the font of `kind` in `style`.
font_handle :: proc(kind: Font_Kind, style: Font_Style) -> mu.Font {
	return mu.Font(uintptr(kind) | uintptr(style) << 4)
}

// chat_font returns the handle for the chat's font in `style`.
chat_font :: proc(style: Font_Style) -> mu.Font {
	return font_handle(.Chat, style)
}

// font_with_style returns `font` (the UI's or the chat's) in another face.
font_with_style :: proc(font: mu.Font, style: Font_Style) -> mu.Font {
	return mu.Font(uintptr(font) & 0xf | uintptr(style) << 4)
}

// font_style returns the face that a handle refers to.
font_style :: proc(font: mu.Font) -> Font_Style {
	return Font_Style((uintptr(font) >> 4) % len(Font_Style))
}

Font_Slot :: struct {
	font:            Font,
	textures:        [Font_Style]Gpu_Texture, // the faces' atlases; 0 until drawn
	unifont_texture: Gpu_Texture, // the fallback font's atlas; 0 until it has glyphs
	// The requested zoom (font_set_zoom). The font applies it with its next
	// atlas.
	zoom:            f32,
}

Renderer :: struct {
	gpu:              Gpu,
	fonts:            [Font_Kind]Font_Slot,
	icon_texture:     Gpu_Texture, // microui's own icons
	icons:            Icon_Atlas, // our own icons (icons.odin)
	icons_texture:    Gpu_Texture,
	// The window's own controls (Minimize..Close) are drawn at the display's
	// density alone, without the UI's zoom on top. They have their own atlas
	// for `control_scale` physical pixels per logical pixel, which the client
	// sets before each frame (0 means the same as `scale`).
	control_scale:    f32,
	controls:         Icon_Atlas,
	controls_texture: Gpu_Texture,
	emoji_texture:    Gpu_Texture, // the emoji sheet (emoji_atlas.odin); 0 until it is decoded
	bound:            Gpu_Texture, // the texture used by the pending quads
	rgba:             bool, // the bound texture is a picture, not an atlas
	images:           ^[dynamic]Image_Draw, // this frame's pictures, filled in by the UI
	vertices:         [MAX_QUADS * 4]Vertex,
	quads:            int,
	scale:            f32,
	// The root container being drawn. `origin` is its position (logical),
	// which its commands are relative to, and `snapped` is the whole
	// physical position that it snaps to, which push_quad adds back
	// (origin_at).
	origin:           [2]i32,
	snapped:          [2]f32,
}

// The fonts that microui measures text with (its callbacks take no user
// data).
@(private = "file")
g_fonts: ^[Font_Kind]Font_Slot

// slot_of returns the font that a microui handle refers to (font_style
// returns its face).
@(private = "file")
slot_of :: proc(fonts: ^[Font_Kind]Font_Slot, font: mu.Font) -> ^Font_Slot {
	switch uintptr(font) & 0xf {
	case uintptr(Font_Kind.Chat):
		return &fonts[.Chat]
	case uintptr(Font_Kind.Preview):
		return &fonts[.Preview]
	}
	return &fonts[.UI]
}

// set_chat_zoom sets how much bigger the chat's text is than the UI's text
// (1 means the same size). Text measuring uses it immediately, and the glyphs
// are rasterized again for it in the next frame.
set_chat_zoom :: proc(r: ^Renderer, zoom: f32) {
	slot := &r.fonts[.Chat]
	if zoom == slot.zoom {
		return
	}
	slot.zoom = zoom
	slot.font.zoom = zoom
	// The next frame rebuilds them at the new size.
	slot.font.scale, slot.font.uni.scale = 0, 0
}

// quad_indices returns the contents of the index buffer: two triangles per
// quad, with the same pattern every time. It is allocated in the temp
// allocator.
quad_indices :: proc() -> ^[MAX_QUADS * 6]u16 {
	indices := new([MAX_QUADS * 6]u16, context.temp_allocator)
	for q in 0 ..< MAX_QUADS {
		base := u16(q * 4)
		copy(indices[q * 6:], []u16{base, base + 1, base + 2, base + 2, base + 3, base})
	}
	return indices
}

// renderer_init sets up drawing into `window`, which was created with
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
	r.fonts[.Preview].zoom, r.fonts[.Preview].font.zoom = PREVIEW_ZOOM, PREVIEW_ZOOM
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
	gpu_texture_delete(&r.gpu, &r.controls_texture)
	gpu_texture_delete(&r.gpu, &r.emoji_texture)
	icon_atlas_destroy(&r.icons)
	icon_atlas_destroy(&r.controls)
	gpu_destroy(&r.gpu)
	for &slot in r.fonts {
		font_destroy(&slot.font)
	}
	// Nothing in here may outlive the device it was created on. The window
	// can be closed and created again (window_close), and a texture that was
	// left behind would then belong to somebody else.
	r^ = {}
}

// renderer_reset recreates everything on the GPU for the same window after
// the device was lost (gpu_lost). The atlases are rebuilt and uploaded when
// the next frame finds them missing.
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
	gpu_texture_delete(&r.gpu, &r.controls_texture)
	// The sheet's pixels are not kept. The client decodes it again when it
	// sees that the texture is missing (ui_images_frame).
	gpu_texture_delete(&r.gpu, &r.emoji_texture)
	gpu_destroy(&r.gpu)
	r.icons.scale, r.controls.scale = 0, 0
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
// framebuffer. `scale` is the number of physical pixels per logical pixel
// (the display's density).
render :: proc(r: ^Renderer, ctx: ^mu.Context, fb_w, fb_h: i32, scale: f32, clear: mu.Color) {
	// Everything is snapped to physical pixels as round(v * scale) / scale,
	// which only lands on physical pixels if the projection maps a logical
	// pixel to exactly `scale` physical pixels on both axes. The layout's
	// logical size (window_metrics) is not necessarily exactly fb / scale,
	// because the framebuffer size is a whole number of pixels and the width
	// ratio does not have to match the height ratio. Projecting the layout
	// size instead would stretch everything by a fraction of a pixel that
	// depends on the window's size. At a scale of 1.5, for example, a
	// glyph's stem would move into the next pixel column as the window is
	// resized. So this projects fb / scale, which differs from the layout
	// size by less than a logical pixel at the right and bottom edges.
	view_w, view_h := f32(fb_w) / scale, f32(fb_h) / scale
	r.scale = scale
	if !gpu_begin(&r.gpu, fb_w, fb_h, view_w, view_h, clear) {
		return // minimized, or the device is lost
	}

	for kind in Font_Kind {
		// The preview font waits until it is drawn with (Command_Text).
		if kind != .Preview {
			slot_prepare(r, &r.fonts[kind], scale)
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

	if r.control_scale > 0 && r.control_scale != scale && r.control_scale != r.controls.scale {
		if icon_atlas_build(&r.controls, r.control_scale) {
			gpu_texture_delete(&r.gpu, &r.controls_texture)
			r.controls_texture = gpu_texture_make(
				&r.gpu,
				.Alpha,
				r.controls.width,
				r.controls.height,
				r.controls.pixels,
			)
		}
	}

	r.bound, r.rgba = 0, false
	r.origin, r.snapped = {}, {}

	// Where each root container's commands start (after its head jump, which
	// next_command follows), so we can tell when a new root container
	// begins.
	Root :: struct {
		first: uintptr,
		pos:   [2]i32,
	}
	roots: [mu.ROOT_LIST_SIZE]Root
	for cnt, i in ctx.root_list.items[:ctx.root_list.idx] {
		roots[i] = {uintptr(cnt.head) + size_of(mu.Command_Jump), {cnt.rect.x, cnt.rect.y}}
	}

	cmd: ^mu.Command
	for variant in mu.next_command_iterator(ctx, &cmd) {
		for root in roots[:ctx.root_list.idx] {
			if root.first == uintptr(cmd) {
				origin_at(r, root.pos)
				break
			}
		}
		switch c in variant {
		case ^mu.Command_Text:
			slot := slot_of(&r.fonts, c.font)
			if slot == &r.fonts[.Preview] && slot.font.scale != scale * slot.font.zoom {
				slot_prepare(r, slot, scale)
			}
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
				f32(c.pos.x - r.origin.x),
				f32(c.pos.y - r.origin.y),
				&emit,
				proc(data: rawptr, q: Glyph_Quad) {
					e := (^Emit)(data)
					if q.emoji {
						// The emoji keeps its own colors but takes the text's
						// opacity. Nothing is drawn until the sheet is decoded.
						if e.r.emoji_texture != 0 {
							use_texture(e.r, e.r.emoji_texture, rgba = true)
							push_quad(
								e.r,
								{q.x0, q.y0, q.x1, q.y1},
								{q.u0, q.v0, q.u1, q.v1},
								{255, 255, 255, e.color.a},
							)
						}
						return
					}
					use_texture(
						e.r,
						e.slot.unifont_texture if q.unifont else e.slot.textures[q.face],
					)
					push_quad(e.r, {q.x0, q.y0, q.x1, q.y1}, {q.u0, q.v0, q.u1, q.v1}, e.color)
				},
				style,
			)
		case ^mu.Command_Rect:
			w := rect_white(r)
			rect := local(r, c.rect)
			x0, x1 := snap_span(rect.x, rect.w, r.scale)
			y0, y1 := snap_span(rect.y, rect.h, r.scale)
			push_quad(r, {x0, y0, x1, y1}, {w.x, w.y, w.x, w.y}, c.color)
		case ^mu.Command_Icon:
			rect := local(r, c.rect)
			if c.id == BORDER_ICON {
				push_border(r, rect, c.color)
				continue
			}
			if c.id == INSIDE_BORDER_ICON {
				push_border(r, rect, c.color, inside = true)
				continue
			}
			if own, ok := own_icon(c.id); ok {
				draw_ui_icon(r, own, rect, c.color)
				continue
			}
			if index := int(c.id) - IMAGE_ICON_BASE; index >= 0 {
				draw_image(r, index, rect, c.color)
				continue
			}
			if index := int(c.id) - UI_ICON_BASE; index >= 0 {
				draw_ui_icon(r, Icon(index), rect, c.color)
				continue
			}
			use_texture(r, r.icon_texture)
			src := mu.default_atlas[c.id]
			x := f32(rect.x + (rect.w - src.w) / 2)
			y := f32(rect.y + (rect.h - src.h) / 2)
			A :: f32(mu.DEFAULT_ATLAS_WIDTH)
			push_quad(
				r,
				{x, y, x + f32(src.w), y + f32(src.h)},
				{f32(src.x) / A, f32(src.y) / A, f32(src.x + src.w) / A, f32(src.y + src.h) / A},
				c.color,
			)
		case ^mu.Command_Clip:
			flush(r)
			set_clip(r, local(r, c.rect))
		case ^mu.Command_Jump:
			unreachable()
		}
	}
	flush(r)
	gpu_end(&r.gpu)
}

// origin_at starts drawing a root container (a window or a popup) at `pos`.
// Everything in the container is snapped to physical pixels relative to where
// `pos` snaps, instead of each item being snapped from its own place on the
// screen. At a fractional scale those would round differently as the window
// moves (at a scale of 1.5, a point 1 logical pixel in from x = 10 is 1
// physical pixel past its border's rounded edge, while from x = 11 it is 2),
// so the title bar could come away from the border or a letter could shift in
// its box in some positions but not in others. This way the whole window
// moves by whole pixels as one.
@(private = "file")
origin_at :: proc(r: ^Renderer, pos: [2]i32) {
	r.origin = pos
	r.snapped = {math.round(f32(pos.x) * r.scale), math.round(f32(pos.y) * r.scale)}
}

// local converts a rect to be relative to the root container being drawn
// (origin_at).
@(private = "file")
local :: proc(r: ^Renderer, rect: mu.Rect) -> mu.Rect {
	return {rect.x - r.origin.x, rect.y - r.origin.y, rect.w, rect.h}
}

// slot_prepare makes sure a font's atlases are at the display's density. A
// zoomed font's atlases are at its own density (font.odin).
@(private = "file")
slot_prepare :: proc(r: ^Renderer, slot: ^Font_Slot, scale: f32) {
	// Regular's atlas is always present because rects are drawn from it.
	// The other faces' atlases are built when text in them is first drawn.
	at := scale * slot.font.zoom
	if at != slot.font.scale {
		font_set_scale(&slot.font, at)
	}
	face_ready(r, slot, .Regular)
	// The fallback font's atlas fills up as text needs glyphs. It starts
	// empty at a new scale and is emptied again once it runs out of room.
	if at != slot.font.uni.scale || slot.font.uni.full {
		unifont_reset(&slot.font.uni, at)
		gpu_texture_delete(&r.gpu, &slot.unifont_texture)
	}
}

// snap_span returns where a rect's edges go along one axis, in logical pixels
// on physical pixel boundaries, so borders stay crisp at fractional scales.
// Each edge is rounded on its own, which keeps neighboring rects meeting
// without gaps. However, it would also make a line that is one logical pixel
// thick one physical pixel thick in one place and two in the next, as the
// position moves across the rounding (at a scale of 1.5, x = 10 and x = 11
// are 15 and 16.5). So a thin rect (an underline, a caret or a separator)
// gets the same thickness everywhere, rounded down, and only its start is
// snapped. That would open gaps where lines meet, so the borders of boxes are
// not drawn as separate lines but as a whole (push_border).
@(private)
snap_span :: proc(start, size: i32, s: f32) -> (a, b: f32) {
	first := math.round(f32(start) * s)
	physical := f32(size) * s
	if size > 0 && size <= THIN_RECT {
		return first / s, (first + max(1, math.floor(physical + 0.001))) / s
	}
	return first / s, math.round(f32(start + size) * s) / s
}

// Rects this many logical pixels thick or less are lines (snap_span).
@(private)
THIN_RECT :: 2

// own_icon returns our icon to draw in place of one of microui's, whose
// pictures are bitmaps for a single density.
@(private = "file")
own_icon :: proc(id: mu.Icon) -> (Icon, bool) {
	#partial switch id {
	case .CLOSE:
		return .Close, true
	case .CHECK:
		return .Check, true
	case .COLLAPSED:
		return .Collapsed, true
	case .EXPANDED:
		return .Expanded, true
	}
	return {}, false
}

// line_thickness returns how many physical pixels thick a line that is one
// logical pixel thick is, rounded down to a whole number.
@(private = "file")
line_thickness :: proc(s: f32) -> f32 {
	return max(1, math.floor(s + 0.001))
}

// push_border draws a border inside `rect`. Its edges are snapped to physical
// pixels like a rect's are, and all its sides have the same thickness, which
// is the whole number of pixels that a logical pixel comes to (rounded down).
// If it were drawn as four lines that each snap on their own (like microui's
// draw_box), the sides could come apart at the corners or vary in thickness.
// With `inside` set, it instead fills the area that the border surrounds.
@(private = "file")
push_border :: proc(r: ^Renderer, rect: mu.Rect, color: mu.Color, inside := false) {
	if rect.w <= 0 || rect.h <= 0 {
		return
	}
	s := r.scale
	w := rect_white(r)
	uv := [4]f32{w.x, w.y, w.x, w.y}
	x0, y0 := math.round(f32(rect.x) * s), math.round(f32(rect.y) * s)
	x1, y1 := math.round(f32(rect.x + rect.w) * s), math.round(f32(rect.y + rect.h) * s)
	t := min(line_thickness(s), (x1 - x0) / 2, (y1 - y0) / 2)
	if inside {
		push_quad(r, [4]f32{x0 + t, y0 + t, x1 - t, y1 - t} / s, uv, color)
		return
	}
	push_quad(r, [4]f32{x0, y0, x1, y0 + t} / s, uv, color)
	push_quad(r, [4]f32{x0, y1 - t, x1, y1} / s, uv, color)
	push_quad(r, [4]f32{x0, y0 + t, x0 + t, y1 - t} / s, uv, color)
	push_quad(r, [4]f32{x1 - t, y0 + t, x1, y1 - t} / s, uv, color)
}

// face_ready makes sure a face's atlas is built for the font's scale and
// uploaded to the GPU.
@(private = "file")
face_ready :: proc(r: ^Renderer, slot: ^Font_Slot, face: Font_Style) {
	fc := &slot.font.faces[face]
	if font_build_atlas(&slot.font, face) || (slot.textures[face] == 0 && fc.pixels != nil) {
		gpu_texture_delete(&r.gpu, &slot.textures[face])
		slot.textures[face] = gpu_texture_make(&r.gpu, .Alpha, fc.width, fc.height, fc.pixels)
	}
}

// upload_unifont uploads the rows of the fallback font's atlas that have
// changed to its texture, and creates the texture the first time. Glyphs are
// only ever added to empty slots, so quads that are already waiting to be
// drawn still find their glyphs.
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

// rect_white returns the position of the white texel to use for a rect. It
// is in whichever font atlas is currently bound, because they all have one, so
// that rects between glyphs (such as the frame of each button around its emoji
// in the emoji picker) do not each switch textures and cost a draw call.
// Otherwise it is in the UI font's atlas, which gets bound. The emoji sheet
// has a white texel too, which a run of emoji uses.
@(private = "file")
rect_white :: proc(r: ^Renderer) -> [2]f32 {
	if r.bound != 0 && r.rgba && r.bound == r.emoji_texture {
		return emoji_white()
	}
	if r.bound != 0 && !r.rgba {
		for &slot in r.fonts {
			if r.bound == slot.unifont_texture {
				if uv, ok := unifont_white(&slot.font.uni); ok {
					return uv
				}
			}
			for t, face in slot.textures {
				if r.bound == t && slot.font.faces[face].pixels != nil {
					return slot.font.faces[face].white
				}
			}
		}
	}
	ui_font := &r.fonts[.UI]
	use_texture(r, ui_font.textures[.Regular])
	return ui_font.font.faces[.Regular].white
}

@(private = "file")
use_texture :: proc(r: ^Renderer, tex: Gpu_Texture, rgba := false) {
	if r.bound != tex || r.rgba != rgba {
		flush(r)
		r.bound, r.rgba = tex, rgba
	}
}

// draw_image draws one of this frame's chat images. They arrive as icon
// commands so that microui clips and layers them like everything else.
@(private = "file")
draw_image :: proc(r: ^Renderer, index: int, rect: mu.Rect, color: mu.Color) {
	if r.images == nil || index >= len(r.images) {
		return
	}
	img := r.images[index]
	use_texture(r, img.texture, rgba = true)
	uv := img.uv
	if uv == {} {
		uv = {0, 0, 1, 1}
	}
	// Place the image on whole physical pixels and give it the same number
	// of pixels wherever it is. Otherwise a picture that falls between
	// pixels is smudged across them, and differently so as it moves (for
	// example a dot beside a name while the window is resized).
	s := r.scale
	x0, y0 := math.round(f32(rect.x) * s), math.round(f32(rect.y) * s)
	x1, y1 := x0 + math.round(f32(rect.w) * s), y0 + math.round(f32(rect.h) * s)
	if img.inset > 0 {
		t := f32(img.inset) * line_thickness(s)
		x0, y0, x1, y1 = x0 + t, y0 + t, x1 - t, y1 - t
		if x1 <= x0 || y1 <= y0 {
			return
		}
	}
	push_quad(r, [4]f32{x0, y0, x1, y1} / s, {uv[0], uv[1], uv[2], uv[3]}, color)
}

// draw_ui_icon draws one of our own icons (icons.odin), centered in the space
// that the layout gave it. It is drawn at the size it was rasterized for and
// snapped to physical pixels, so it stays as crisp as the text next to it.
@(private = "file")
draw_ui_icon :: proc(r: ^Renderer, icon: Icon, rect: mu.Rect, color: mu.Color) {
	if r.icons.side == 0 || int(icon) >= len(Icon) {
		return
	}
	atlas, texture := &r.icons, r.icons_texture
	if icon >= .Minimize &&
	   icon <= .Close &&
	   r.controls.scale == r.control_scale &&
	   r.controls.side > 0 {
		atlas, texture = &r.controls, r.controls_texture
	}
	use_texture(r, texture)
	side := f32(atlas.side) / r.scale
	snap :: proc(v: f32, s: f32) -> f32 {return math.round(v * s) / s}
	x := snap(f32(rect.x) + (f32(rect.w) - side) / 2, r.scale)
	y := snap(f32(rect.y) + (f32(rect.h) - side) / 2, r.scale)
	u0 := f32(int(icon) * int(atlas.side)) / f32(atlas.width)
	u1 := f32((int(icon) + 1) * int(atlas.side)) / f32(atlas.width)
	push_quad(r, {x, y, x + side, y + side}, {u0, 0, u1, 1}, color)
}

// dst and uv are {x0, y0, x1, y1}.
@(private = "file")
push_quad :: proc(r: ^Renderer, dst, uv: [4]f32, color: mu.Color) {
	if r.quads == MAX_QUADS {
		flush(r)
	}
	c := [4]u8{color.r, color.g, color.b, color.a}
	// Convert from the root container's coordinates back to the screen
	// (origin_at).
	o := r.snapped / r.scale
	p := dst + {o.x, o.y, o.x, o.y}
	v := r.vertices[r.quads * 4:]
	v[0] = {{p[0], p[1]}, {uv[0], uv[1]}, c}
	v[1] = {{p[2], p[1]}, {uv[2], uv[1]}, c}
	v[2] = {{p[2], p[3]}, {uv[2], uv[3]}, c}
	v[3] = {{p[0], p[3]}, {uv[0], uv[3]}, c}
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
	o := r.snapped
	x0 := o.x + math.round(f32(rect.x) * s)
	x1 := o.x + math.round(f32(rect.x + rect.w) * s)
	y0 := o.y + math.round(f32(rect.y) * s)
	y1 := o.y + math.round(f32(rect.y + rect.h) * s)
	gpu_clip(&r.gpu, i32(x0), i32(y0), i32(x1 - x0), i32(y1 - y0))
}

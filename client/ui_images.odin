package client

import "base:runtime"
import "core:fmt"
import log "../common/wlog"
import "core:strings"
import "core:sync"
import gl "wgl"
import mu "vendor:microui"

import "../proto"
import "clipboard"

/*
Showing chat images. The network thread hands over the JPEG it fetched
(View.images); here it's decoded on a worker thread, uploaded to a
texture on the UI thread, and drawn in microui's command list so it's
clipped and layered like everything else (see ui_render.odin, which
takes an icon id of IMAGE_ICON_BASE or more as "draw image N of this
frame's list").

Textures are kept for MAX_IMAGE_TEXTURES images, the least recently
drawn going first; scrolling back to one decodes it again.
*/

MAX_IMAGE_TEXTURES :: 32
// How tall an image may be drawn, in logical pixels.
MAX_IMAGE_DISPLAY_HEIGHT :: 320

// Icon ids from here on mean "the image at this index of the frame's
// draw list", which microui's own icons never reach.
IMAGE_ICON_BASE :: 1000

@(private = "file")
IMAGE_WINDOW :: "image"

Image_Draw :: struct {
	texture: u32,
}

@(private = "file")
Texture_State :: enum {
	Decoding,
	Ready,
	Failed,
}

@(private = "file")
Texture :: struct {
	state:   Texture_State,
	texture: u32,
	frame:   int, // when it was last drawn
}

Decode_Job :: struct {
	id:   u32,
	jpeg: []u8, // owned by the job
}

Decode_Result :: struct {
	id:    u32,
	image: clipboard.Image, // pixels owned by the result
	ok:    bool,
}

UI_Images :: struct {
	textures:    map[u32]Texture,
	// The image shown enlarged, 0 for none, and whether it still has to
	// be sized to the window.
	viewer:      u32,
	placed:      bool,
	// A saved copy of what's on screen, so the viewer and saving can work
	// outside the View's lock.
	shown:       proto.Image_Info,
	state:       Image_State,
	// Bytes to write to the downloads folder after the frame, and where
	// the last one went. viewer_save is the viewer's Save button, acted
	// on where the bytes are at hand.
	save:        []u8,
	viewer_save: bool,
	saved_to:    string,
	// What this frame draws, indexed by icon id (see IMAGE_ICON_BASE).
	draws:       [dynamic]Image_Draw,
	frame:       int,

	// The decoding thread, its queue and what it has finished.
	worker:      Decode_Worker,
	mutex:       sync.Mutex,
	wake:        sync.Sema,
	queue:       [dynamic]Decode_Job,
	results:     [dynamic]Decode_Result,
	stopping:    bool,
	ctx:         runtime.Context,
}

ui_images_init :: proc(ui: ^UI) {
	ui.images.ctx = context
	decode_worker_start(ui)
}

/*
ui_images_forget_textures drops what the OpenGL context holds, without
deleting anything: it's called as that context goes away (window_close),
and the names in here mean nothing outside it. The pictures themselves
are decoded again when they're next drawn.
*/
ui_images_forget_textures :: proc(ui: ^UI) {
	im := &ui.images
	clear(&im.textures)
	clear(&im.draws)
}

ui_images_destroy :: proc(ui: ^UI) {
	im := &ui.images
	{
		sync.guard(&im.mutex)
		im.stopping = true
	}
	decode_worker_stop(ui)
	for job in im.queue {
		delete(job.jpeg)
	}
	for &result in im.results {
		clipboard.image_destroy(&result.image)
	}
	for _, t in im.textures {
		if t.state == .Ready {
			tex := t.texture
			gl.DeleteTextures(1, &tex)
		}
	}
	delete(im.queue)
	delete(im.results)
	delete(im.textures)
	delete(im.draws)
	delete(im.save)
	delete(im.saved_to)
}

// ui_images_frame takes in what the worker decoded and starts a new
// frame's draw list. Call before laying out.
ui_images_frame :: proc(ui: ^UI) {
	im := &ui.images
	im.frame += 1
	clear(&im.draws)

	results: [dynamic]Decode_Result
	{
		sync.guard(&im.mutex)
		results, im.results = im.results, {}
	}
	defer delete(results)
	for &result in results {
		defer clipboard.image_destroy(&result.image)
		t := im.textures[result.id] or_else {}
		if !result.ok {
			im.textures[result.id] = {
				state = .Failed,
				frame = im.frame,
			}
			continue
		}
		t.state = .Ready
		t.texture = make_image_texture(result.image)
		t.frame = im.frame
		im.textures[result.id] = t
	}
	trim_textures(im)
}

// image_block draws one image message: the picture once it's here, and
// what's happening with it until then. It's laid out at the size the
// image will take, so nothing jumps when it arrives. Clicking it opens
// the viewer; the right button saves it.
image_block :: proc(ui: ^UI, info: proto.Image_Info, state: Image_State, jpeg: []u8) {
	ctx := &ui.ctx
	w, h := image_display_size(ctx, int(info.width), int(info.height))
	mu.layout_row(ctx, {i32(w)}, i32(h))
	rect := mu.layout_next(ctx)

	im := &ui.images
	if state == .Ready && mu.mouse_over(ctx, rect) {
		ui.chat.hovering = true // the pointing hand
		if .LEFT in ctx.mouse_pressed_bits {
			im.viewer, im.placed = info.id, false
		}
		if .RIGHT in ctx.mouse_pressed_bits {
			request_save(im, jpeg)
		}
	}
	if info.id == im.viewer {
		// What the viewer draws, copied while the View is locked.
		im.shown, im.state = info, state
		if len(im.save) == 0 && im.viewer_save {
			im.viewer_save = false
			request_save(im, jpeg)
		}
	}
	t, known := im.textures[info.id]
	if !known && state == .Ready && len(jpeg) > 0 {
		enqueue_decode(im, info.id, jpeg)
		t, known = im.textures[info.id]
	}
	if known && t.state == .Ready {
		t.frame = im.frame
		im.textures[info.id] = t
		append(&im.draws, Image_Draw{texture = t.texture})
		// An icon command, which the renderer draws as this frame's image
		// number N; microui takes care of clipping it to the panel.
		mu.draw_icon(ctx, mu.Icon(IMAGE_ICON_BASE + len(im.draws) - 1), rect, {255, 255, 255, 255})
		return
	}

	// A frame where the picture will be, with a word on why it isn't.
	mu.draw_rect(ctx, rect, {50, 50, 50, 255})
	label: string
	switch {
	case known && t.state == .Failed:
		label = "broken image"
	case state == .Gone:
		label = "image no longer on the server"
	case known && t.state == .Decoding, state == .Ready:
		label = "showing image..."
	case:
		label = "loading image..."
	}
	mu.draw_control_text(ctx, label, rect, .TEXT, {.ALIGN_CENTER})
}

// request_save keeps a copy of an image to write out after the frame,
// once the View isn't locked any more.
@(private = "file")
request_save :: proc(im: ^UI_Images, jpeg: []u8) {
	if len(jpeg) == 0 || len(im.save) > 0 {
		return
	}
	im.save = make([]u8, len(jpeg))
	copy(im.save, jpeg)
}

// image_viewer shows the image that was clicked, as large as its window
// allows. It's a window of its own, so it floats over everything.
image_viewer :: proc(ui: ^UI, window_w, window_h: i32) {
	im := &ui.images
	if im.viewer == 0 {
		return
	}
	ctx := &ui.ctx
	// Open it centred, big enough for the image but inside the window.
	if !im.placed {
		im.placed = true
		w := max(min(int(im.shown.width) + 2 * int(ctx.style.padding), int(window_w) - 40), 240)
		h := max(min(int(im.shown.height) + 60, int(window_h) - 40), 160)
		rect := mu.Rect{(window_w - i32(w)) / 2, (window_h - i32(h)) / 2, i32(w), i32(h)}
		if cnt := mu.get_container(ctx, IMAGE_WINDOW); cnt != nil {
			cnt.rect = rect
			cnt.open = true
			mu.bring_to_front(ctx, cnt)
			// The click that opened this landed on the window behind it,
			// and microui raises whatever was clicked at the end of the
			// frame, which would bury this one. Counting it as the
			// clicked container instead keeps it on top, the same way
			// microui opens its own popups.
			ctx.hover_root, ctx.next_hover_root = cnt, cnt
		}
	}
	// Clicking the window behind raises it (microui raises whatever was
	// clicked), so keep this one above for as long as it's open.
	if cnt := mu.get_container(ctx, IMAGE_WINDOW, {.CLOSED});
	   cnt != nil && cnt.open && cnt.zindex != ctx.last_zindex {
		mu.bring_to_front(ctx, cnt)
	}
	if !mu.begin_window(ctx, IMAGE_WINDOW, {}, {.NO_SCROLL}) {
		im.viewer = 0 // closed with the title bar's button
		return
	}
	defer mu.end_window(ctx)
	cnt := mu.get_current_container(ctx)

	row := ctx.style.size.y + 2 * ctx.style.padding + 10
	mu.layout_row(ctx, {-1}, cnt.body.h - i32(row) - ctx.style.spacing)
	picture := mu.layout_next(ctx)
	w, h := fit_box(
		int(im.shown.width),
		int(im.shown.height),
		max(int(picture.w), 1),
		max(int(picture.h), 1),
	)
	rect := mu.Rect {
		picture.x + (picture.w - i32(w)) / 2,
		picture.y + (picture.h - i32(h)) / 2,
		i32(w),
		i32(h),
	}
	if t, known := im.textures[im.viewer]; known && t.state == .Ready {
		append(&im.draws, Image_Draw{texture = t.texture})
		mu.draw_icon(ctx, mu.Icon(IMAGE_ICON_BASE + len(im.draws) - 1), rect, {255, 255, 255, 255})
	} else {
		mu.draw_rect(ctx, rect, {50, 50, 50, 255})
		mu.draw_control_text(ctx, "loading image...", rect, .TEXT, {.ALIGN_CENTER})
	}

	mu.layout_row(ctx, {90, 90, -1})
	if .SUBMIT in mu.button(ctx, "Save") {
		im.viewer_save = true
	}
	if .SUBMIT in mu.button(ctx, "Close") {
		im.viewer = 0
	}
	status := fmt.tprintf("%dx%d", im.shown.width, im.shown.height)
	if im.saved_to != "" {
		status = fmt.tprintf("%s   saved %s to your downloads", status, file_name(im.saved_to))
	}
	with_text_color(ctx, CHAT_DIM_COLOR, status, label_proc)
}

// ui_images_after_frame writes out an image the viewer or a right-click
// asked to save, now that the View isn't locked.
ui_images_after_frame :: proc(ui: ^UI) {
	im := &ui.images
	if len(im.save) == 0 {
		return
	}
	defer {
		delete(im.save)
		im.save = nil
	}
	if path, ok := save_to_downloads(im.save, "jpg"); ok {
		log.infof("saved the image to %s", path)
		delete(im.saved_to)
		im.saved_to = path
	}
}

// image_display_size is how big an image is drawn: as large as fits the
// chat panel, never enlarged, and never taller than a few hundred pixels.
image_display_size :: proc(ctx: ^mu.Context, width, height: int) -> (w, h: int) {
	if width <= 0 || height <= 0 {
		return 160, 90
	}
	// As wide as the panel's content area.
	available := 160
	if cnt := mu.get_current_container(ctx); cnt != nil {
		available = max(
			int(cnt.body.w) - 2 * int(ctx.style.padding) - int(ctx.style.scrollbar_size),
			32,
		)
	}
	return fit_box(width, height, available, MAX_IMAGE_DISPLAY_HEIGHT)
}

@(private = "file")
enqueue_decode :: proc(im: ^UI_Images, id: u32, jpeg: []u8) {
	copy_of := make([]u8, len(jpeg))
	copy(copy_of, jpeg)
	im.textures[id] = {
		state = .Decoding,
		frame = im.frame,
	}
	{
		sync.guard(&im.mutex)
		append(&im.queue, Decode_Job{id = id, jpeg = copy_of})
	}
	sync.sema_post(&im.wake)
}


@(private = "file")
make_image_texture :: proc(img: clipboard.Image) -> (tex: u32) {
	gl.GenTextures(1, &tex)
	gl.BindTexture(gl.TEXTURE_2D, tex)
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
	gl.TexImage2D(
		gl.TEXTURE_2D,
		0,
		gl.RGBA8,
		i32(img.width),
		i32(img.height),
		0,
		gl.RGBA,
		gl.UNSIGNED_BYTE,
		raw_data(img.pixels),
	)
	// Images are usually drawn smaller than they are.
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	return
}

// trim_textures frees the textures that haven't been drawn for longest.
@(private = "file")
trim_textures :: proc(im: ^UI_Images) {
	for len(im.textures) > MAX_IMAGE_TEXTURES {
		oldest_id: u32
		oldest_frame := max(int)
		for id, t in im.textures {
			if t.state != .Decoding && t.frame < oldest_frame {
				oldest_id, oldest_frame = id, t.frame
			}
		}
		if oldest_id == 0 {
			return
		}
		t := im.textures[oldest_id]
		if t.state == .Ready {
			tex := t.texture
			gl.DeleteTextures(1, &tex)
		}
		delete_key(&im.textures, oldest_id)
	}
}

// file_name is the last part of a path, after its last separator.
@(private = "file")
file_name :: proc(path: string) -> string {
	i := strings.last_index_any(path, "/\\")
	return path[i + 1:]
}

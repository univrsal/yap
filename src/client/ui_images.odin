package client

import "base:runtime"
import log "common:wlog"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:sync"
import mu "vendor:microui"

import "client:clipboard"
import "client:conn"
import "client:platform"
import "client:render"
import "common:proto"

/*
Showing pictures. The network thread hands over the JPEG it fetched
(View.blobs); here it's decoded on a worker thread, uploaded to a
texture on the UI thread, and drawn in microui's command list so it's
clipped and layered like everything else (see render/render.odin, which
takes an icon id of IMAGE_ICON_BASE or more as "draw image N of this
frame's list").

Textures are kept for MAX_IMAGE_TEXTURES images, the least recently
drawn going first; scrolling back to one decodes it again.
*/

MAX_IMAGE_TEXTURES :: 96
// How tall an image may be drawn, in logical pixels.
MAX_IMAGE_DISPLAY_HEIGHT :: 320

@(private = "file")
IMAGE_WINDOW :: "image"

@(private = "file")
Texture_State :: enum {
	Decoding,
	Ready,
	Failed,
}

@(private = "file")
Texture :: struct {
	state:   Texture_State,
	texture: render.Gpu_Texture,
	frame:   int, // when it was last drawn
	// The picture's own size, once it's decoded.
	width:   int,
	height:  int,
}

// Pictures are known by a key their drawer gives (image_block): a
// message's picture by its blob's id.

Decode_Job :: struct {
	id:         u64,
	jpeg:       []u8, // owned by the job
	generation: u64, // UI_Images.generation when it was asked for
}

Decode_Result :: struct {
	id:         u64,
	image:      clipboard.Image, // pixels owned by the result
	ok:         bool,
	generation: u64,
}

UI_Images :: struct {
	textures:    map[u64]Texture,
	// The image shown enlarged, 0 for none, and whether it still has to
	// be sized to the window.
	viewer:      u64,
	placed:      bool,
	// The viewer's zoom, relative to the image fitted to its window (1 is
	// fitted, and as far out as it goes), and how far the image's centre
	// is dragged from the picture area's, in pixels.
	zoom:        f32,
	pan:         [2]f32,
	// A saved copy of what's on screen, so the viewer and saving can work
	// outside the View's lock.
	shown:       proto.Msg_Image,
	state:       conn.Image_State,
	// Bytes to write to the downloads folder after the frame, and where
	// the last one went. viewer_save is the viewer's Save button, acted
	// on where the bytes are at hand.
	save:        []u8,
	viewer_save: bool,
	saved_to:    string,
	// What this frame draws, indexed by icon id (see IMAGE_ICON_BASE).
	draws:       [dynamic]render.Image_Draw,
	frame:       int,

	// The decoding thread, its queue and what it has finished.
	worker:      Decode_Worker,
	mutex:       sync.Mutex,
	wake:        sync.Sema,
	queue:       [dynamic]Decode_Job,
	results:     [dynamic]Decode_Result,
	stopping:    bool,
	ctx:         runtime.Context,
	// Bumped when the server shown changes (ui_images_switch): pictures
	// are known by its blob ids, so what was decoded for another server
	// is thrown away.
	generation:  u64,
}

ui_images_init :: proc(ui: ^UI) {
	ui.images.ctx = context
	decode_worker_start(ui)
}

/*
ui_images_forget_textures drops what the GPU device holds, without
deleting anything: it's called as that device goes away (window_close),
and the textures in here mean nothing outside it. The pictures themselves
are decoded again when they're next drawn.
*/
ui_images_forget_textures :: proc(ui: ^UI) {
	im := &ui.images
	clear(&im.textures)
	clear(&im.draws)
}

/*
ui_images_switch drops every picture, as another server is shown: they
are known by the server's blob ids, which mean something else there.
What's still being decoded is thrown away when it's done, and the new
server's pictures are decoded as they're drawn.
*/
ui_images_switch :: proc(ui: ^UI) {
	im := &ui.images
	for _, &t in im.textures {
		if t.state == .Ready {
			render.gpu_texture_delete(&ui.renderer.gpu, &t.texture)
		}
	}
	clear(&im.textures)
	clear(&im.draws)
	im.viewer, im.placed = 0, false
	sync.guard(&im.mutex)
	im.generation += 1
	for job in im.queue {
		delete(job.jpeg)
	}
	clear(&im.queue)
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
	for _, &t in im.textures {
		if t.state == .Ready {
			render.gpu_texture_delete(&ui.renderer.gpu, &t.texture)
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
	when platform.WEB {
		decode_queued(im)
	}

	results: [dynamic]Decode_Result
	{
		sync.guard(&im.mutex)
		results, im.results = im.results, {}
	}
	defer delete(results)
	for &result in results {
		defer clipboard.image_destroy(&result.image)
		if result.generation != im.generation {
			continue // another server's
		}
		t := im.textures[result.id] or_else {}
		if !result.ok {
			im.textures[result.id] = {
				state = .Failed,
				frame = im.frame,
			}
			continue
		}
		if result.id & AVATAR_KEY != 0 {
			round_off(&result.image) // a picture of somebody (ui_avatars.odin)
		}
		t.state = .Ready
		t.width, t.height = result.image.width, result.image.height
		t.texture = render.gpu_texture_make(
			&ui.renderer.gpu,
			.Rgba,
			i32(result.image.width),
			i32(result.image.height),
			result.image.pixels,
			mipmaps = true, // usually drawn smaller, and pictures of people round
		)
		t.frame = im.frame
		im.textures[result.id] = t
	}
	trim_textures(im, &ui.renderer.gpu)
}

// image_block draws one image message: the picture once it's here, and
// what's happening with it until then (`gone` says why it isn't coming).
// It's laid out at the size the image will take, so nothing jumps when
// it arrives. Clicking it opens the viewer; the message's menu (the right
// button) saves it.
image_block :: proc(
	ui: ^UI,
	key: u64, // which picture it is: its blob's id
	info: proto.Msg_Image,
	state: conn.Image_State,
	jpeg: []u8,
	gone := "image no longer on the server",
	available := 0, // how wide it may be; 0 for the panel's width
) {
	ctx := &ui.ctx
	w, h := image_display_size(ctx, int(info.width), int(info.height), available)
	mu.layout_row(ctx, {i32(w)}, i32(h))
	rect := mu.layout_next(ctx)

	im := &ui.images
	if state == .Ready && mu.mouse_over(ctx, rect) {
		ui.chat.hovering = true // the pointing hand
		if .LEFT in ctx.mouse_pressed_bits {
			im.viewer, im.placed = key, false
		}
	}
	if key == im.viewer {
		// What the viewer draws, copied while the View is locked.
		im.shown, im.state = info, state
		if len(im.save) == 0 && im.viewer_save {
			im.viewer_save = false
			request_save(im, jpeg)
		}
	}
	t, known := im.textures[key]
	if !known && state == .Ready && len(jpeg) > 0 {
		enqueue_decode(im, key, jpeg)
		t, known = im.textures[key]
	}
	if known && t.state == .Ready {
		t.frame = im.frame
		im.textures[key] = t
		append(&im.draws, render.Image_Draw{texture = t.texture})
		// An icon command, which the renderer draws as this frame's image
		// number N; microui takes care of clipping it to the panel.
		mu.draw_icon(
			ctx,
			mu.Icon(render.IMAGE_ICON_BASE + len(im.draws) - 1),
			rect,
			{255, 255, 255, 255},
		)
		return
	}

	// A frame where the picture will be, with a word on why it isn't.
	mu.draw_rect(ctx, rect, {50, 50, 50, 255})
	label: string
	switch {
	case known && t.state == .Failed:
		label = "broken image"
	case state == .Gone:
		label = gone
	case known && t.state == .Decoding, state == .Ready:
		label = "showing image..."
	case:
		label = "loading image..."
	}
	mu.draw_control_text(ctx, label, rect, .TEXT, {.ALIGN_CENTER})
}

/*
image_fitted draws a picture as large as fits `area`, at its left, for
pictures whose size isn't known until they're decoded (a message's
attached picture, ui_attachments.odin): the area doesn't change when it
arrives. Clicking it opens the viewer. `save` says the viewer's Save was
pressed for this one, for the caller to save it its own way.
*/
image_fitted :: proc(
	ui: ^UI,
	key: u64,
	state: conn.Image_State,
	data: []u8,
	area: mu.Rect,
) -> (
	save: bool,
) {
	ctx := &ui.ctx
	im := &ui.images
	t, known := im.textures[key]
	if !known && state == .Ready && len(data) > 0 {
		enqueue_decode(im, key, data)
		t, known = im.textures[key]
	}
	if !known || t.state != .Ready {
		label := "broken image" if known && t.state == .Failed else "loading picture..."
		mu.draw_rect(ctx, area, {50, 50, 50, 255})
		mu.draw_control_text(ctx, label, area, .TEXT, {.ALIGN_CENTER})
		return
	}
	w, h := conn.fit_box(t.width, t.height, int(area.w), int(area.h))
	rect := mu.Rect{area.x, area.y, i32(w), i32(h)}
	t.frame = im.frame
	im.textures[key] = t
	append(&im.draws, render.Image_Draw{texture = t.texture})
	mu.draw_icon(
		ctx,
		mu.Icon(render.IMAGE_ICON_BASE + len(im.draws) - 1),
		rect,
		{255, 255, 255, 255},
	)
	if mu.mouse_over(ctx, rect) {
		ui.chat.hovering = true // the pointing hand
		if .LEFT in ctx.mouse_pressed_bits {
			im.viewer, im.placed = key, false
		}
	}
	if key == im.viewer {
		im.shown = {
			width  = u16(min(t.width, 65535)),
			height = u16(min(t.height, 65535)),
		}
		im.state = .Ready
		if im.viewer_save {
			im.viewer_save = false
			save = true
		}
	}
	return
}

// request_save keeps a copy of an image to write out after the frame,
// once the View isn't locked any more.
request_save :: proc(im: ^UI_Images, jpeg: []u8) {
	if len(jpeg) == 0 || len(im.save) > 0 {
		return
	}
	im.save = make([]u8, len(jpeg))
	copy(im.save, jpeg)
}

// Zooming in stops once an image pixel is this many screen pixels.
@(private = "file")
MAX_PIXEL_SIZE :: 8
// How much one notch of the mouse wheel (30, see scroll_callback) zooms.
@(private = "file")
ZOOM_STEP :: 1.25

/*
image_viewer shows the image that was clicked, as large as its window
allows. It's a window of its own, so it floats over everything.

The mouse wheel zooms in and out around the pointer, dragging moves a
zoomed image around, and Fit goes back to the whole image.
*/
image_viewer :: proc(ui: ^UI, window_w, window_h: i32) {
	im := &ui.images
	if im.viewer == 0 {
		return
	}
	ctx := &ui.ctx
	// Open it centred, big enough for the image but inside the window.
	if !im.placed {
		im.placed = true
		im.zoom, im.pan = 1, {}
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
	fit_w, _ := conn.fit_box(
		int(im.shown.width),
		int(im.shown.height),
		max(int(picture.w), 1),
		max(int(picture.h), 1),
	)
	max_zoom := max(1, MAX_PIXEL_SIZE * f32(im.shown.width) / f32(max(fit_w, 1)))
	viewer_input(ui, picture, max_zoom)
	rect := viewer_rect(im, picture)
	if t, known := im.textures[im.viewer]; known && t.state == .Ready {
		append(&im.draws, render.Image_Draw{texture = t.texture})
		// Zoomed in, the image is bigger than the picture area; only the
		// part inside it is drawn.
		mu.push_clip_rect(ctx, picture)
		mu.draw_icon(
			ctx,
			mu.Icon(render.IMAGE_ICON_BASE + len(im.draws) - 1),
			rect,
			{255, 255, 255, 255},
		)
		mu.pop_clip_rect(ctx)
	} else {
		mu.draw_rect(ctx, rect, {50, 50, 50, 255})
		mu.draw_control_text(ctx, "loading image...", rect, .TEXT, {.ALIGN_CENTER})
	}

	mu.layout_row(ctx, {90, 90, 90, -1})
	if .SUBMIT in mu.button(ctx, "Save") {
		im.viewer_save = true
	}
	if .SUBMIT in mu.button(ctx, "Fit") {
		im.zoom, im.pan = 1, {}
	}
	if .SUBMIT in mu.button(ctx, "Close") {
		im.viewer = 0
	}
	shown_percent := 100 * f32(rect.w) / f32(max(im.shown.width, 1))
	status := fmt.tprintf("%dx%d   %.0f%%", im.shown.width, im.shown.height, shown_percent)
	if im.saved_to != "" {
		status = fmt.tprintf("%s   saved %s to your downloads", status, file_name(im.saved_to))
	}
	with_text_color(ctx, CHAT_DIM_COLOR, status, label_proc)
}

// viewer_input zooms with the mouse wheel over the picture area, keeping
// the point under the pointer where it is, and pans while the image is
// dragged, even once the pointer has left the area.
@(private = "file")
viewer_input :: proc(ui: ^UI, picture: mu.Rect, max_zoom: f32) {
	ctx := &ui.ctx
	im := &ui.images
	id := mu.get_id(ctx, "picture")
	mu.update_control(ctx, id, picture, {.HOLD_FOCUS})

	if ctx.hover_id == id && ctx.scroll_delta.y != 0 {
		old := im.zoom
		im.zoom = clamp(old * math.pow(ZOOM_STEP, -f32(ctx.scroll_delta.y) / 30), 1, max_zoom)
		// The pointer, from the picture area's centre.
		p := [2]f32 {
			f32(ctx.mouse_pos.x) - (f32(picture.x) + f32(picture.w) / 2),
			f32(ctx.mouse_pos.y) - (f32(picture.y) + f32(picture.h) / 2),
		}
		im.pan = p - (p - im.pan) * (im.zoom / old)
		// Used up here, rather than also scrolling whatever is behind.
		ctx.scroll_delta = {}
	}
	if ctx.focus_id == id && .LEFT in ctx.mouse_down_bits {
		im.pan += {f32(ctx.mouse_delta.x), f32(ctx.mouse_delta.y)}
	}
	if im.zoom > 1 && (ctx.hover_id == id || ctx.focus_id == id) {
		// The pointing hand, as for images in the chat: there's
		// something to grab.
		ui.chat.hovering = true
	}

	// Never further than to where the image's edge meets the area's, and
	// centred along a side that isn't bigger than the area.
	r := viewer_rect(im, picture)
	room := [2]f32{max(f32(r.w - picture.w), 0) / 2, max(f32(r.h - picture.h), 0) / 2}
	im.pan = {clamp(im.pan.x, -room.x, room.x), clamp(im.pan.y, -room.y, room.y)}
}

// viewer_rect is where the viewer's image goes, zoomed and panned.
@(private = "file")
viewer_rect :: proc(im: ^UI_Images, picture: mu.Rect) -> mu.Rect {
	fw, fh := conn.fit_box(
		int(im.shown.width),
		int(im.shown.height),
		max(int(picture.w), 1),
		max(int(picture.h), 1),
	)
	w := f32(fw) * im.zoom
	h := f32(fh) * im.zoom
	cx := f32(picture.x) + f32(picture.w) / 2 + im.pan.x
	cy := f32(picture.y) + f32(picture.h) / 2 + im.pan.y
	return {
		i32(math.round(cx - w / 2)),
		i32(math.round(cy - h / 2)),
		i32(math.round(w)),
		i32(math.round(h)),
	}
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
	if path, ok := platform.save_to_downloads(im.save, "jpg"); ok {
		log.infof("saved the image to %s", path)
		delete(im.saved_to)
		im.saved_to = path
	}
}

// image_display_size is how big an image is drawn: as large as fits the
// chat panel, never enlarged, and never taller than a few hundred pixels.
image_display_size :: proc(ctx: ^mu.Context, width, height: int, available := 0) -> (w, h: int) {
	if width <= 0 || height <= 0 {
		return 160, 90
	}
	if available > 0 {
		return conn.fit_box(width, height, available, MAX_IMAGE_DISPLAY_HEIGHT)
	}
	// As wide as the panel's content area.
	panel := 160
	if cnt := mu.get_current_container(ctx); cnt != nil {
		panel = max(
			int(cnt.body.w) - 2 * int(ctx.style.padding) - int(ctx.style.scrollbar_size),
			32,
		)
	}
	return conn.fit_box(width, height, panel, MAX_IMAGE_DISPLAY_HEIGHT)
}

enqueue_decode :: proc(im: ^UI_Images, id: u64, jpeg: []u8) {
	copy_of := make([]u8, len(jpeg))
	copy(copy_of, jpeg)
	im.textures[id] = {
		state = .Decoding,
		frame = im.frame,
	}
	{
		sync.guard(&im.mutex)
		append(&im.queue, Decode_Job{id = id, jpeg = copy_of, generation = im.generation})
	}
	decode_wake(im)
}


// trim_textures frees the textures that haven't been drawn for longest.
@(private = "file")
trim_textures :: proc(im: ^UI_Images, gpu: ^render.Gpu) {
	for len(im.textures) > MAX_IMAGE_TEXTURES {
		oldest_id: u64
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
			render.gpu_texture_delete(gpu, &t.texture)
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

// The key the server's sheet of emoji is decoded and kept under, beside
// messages' pictures (which are their blob's id).
@(private = "file")
EMOJI_SHEET_KEY :: u64(1) << 62

/*
custom_emoji_icon is what draws the server's emoji number `index`: an
icon id for mu.draw_icon, for this frame. False until the sheet is here
and decoded. Call with the View locked.
*/
custom_emoji_icon :: proc(ui: ^UI, index: int) -> (mu.Icon, bool) {
	v := ui.view
	im := &ui.images
	e := &v.emoji
	if e.blob == 0 || index < 0 || index >= len(e.names) {
		return {}, false
	}
	key := EMOJI_SHEET_KEY | u64(e.blob)
	t, known := im.textures[key]
	if !known {
		if img, ok := v.blobs[e.blob]; ok && img.state == .Ready && len(img.jpeg) > 0 {
			enqueue_decode(im, key, img.jpeg)
		}
		return {}, false
	}
	if t.state != .Ready {
		return {}, false
	}
	t.frame = im.frame
	im.textures[key] = t
	cols := proto.EMOJI_SHEET_COLUMNS
	rows := (len(e.names) + cols - 1) / cols
	u0 := f32(index % cols) / f32(cols)
	v0 := f32(index / cols) / f32(rows)
	append(
		&im.draws,
		render.Image_Draw {
			texture = t.texture,
			uv = {u0, v0, u0 + 1 / f32(cols), v0 + 1 / f32(rows)},
		},
	)
	return mu.Icon(render.IMAGE_ICON_BASE + len(im.draws) - 1), true
}

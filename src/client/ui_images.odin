package client

import "base:runtime"
import log "common:wlog"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import mu "vendor:microui"

import "client:clipboard"
import "client:conn"
import "client:platform"
import "client:render"
import "client:settings"
import glfw "client:wglfw"
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

An animated picture's texture holds one frame at a time: the worker
decodes the next while the one before is shown (anims_advance), only
for pictures that are drawn, and only while the window has the focus.
*/

MAX_IMAGE_TEXTURES :: 96

// The least an animation's frame is shown for, in milliseconds: shorter
// ones are merged with the next (ui_images_anim_native.odin), and moving
// emoji ask for no more frames than this allows (custom_emoji_frame), so
// nothing animated redraws more than 30 times a second.
ANIM_MIN_SHOWN :: 33

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
	// An animation (ui_images_anim_native.odin): the texture shows a frame
	// at a time, and `next` (owned) is the one after it once the worker
	// has it, shown at `due` for `next_shown`. `asked` while the worker is
	// on it; `ended` once there are no more. It moves on only if it was
	// drawn playing the frame before (`played`, see image_fitted); `gif`
	// is for the badge it has while it isn't.
	anim:       bool,
	gif:        bool,
	played:     int,
	next:       []u8,
	next_shown: time.Duration,
	due:        time.Tick,
	asked:      bool,
	ended:      bool,
}

// Pictures are known by a key their drawer gives (image_fitted).

Decode_Job_Kind :: enum {
	Decode, // the picture in `jpeg`
	Next_Frame, // the animation's next frame
	Drop, // stop playing the animation
}

Decode_Job :: struct {
	kind:       Decode_Job_Kind,
	id:         u64,
	jpeg:       []u8, // owned by the job
	generation: u64, // UI_Images.generation when it was asked for
}

Decode_Result :: struct {
	id:         u64,
	image:      clipboard.Image, // pixels owned by the result
	ok:         bool,
	generation: u64,
	// The picture is an animation, the image a frame of it shown for
	// `shown`: its first, or with `frame` one asked for (Next_Frame),
	// which without pixels says there are no more. `gif` for a GIF's.
	anim:       bool,
	frame:      bool,
	gif:        bool,
	shown:      time.Duration,
}

UI_Images :: struct {
	textures:      map[u64]Texture,
	// The image shown enlarged, 0 for none, and whether it still has to
	// be sized to the window.
	viewer:        u64,
	placed:        bool,
	// The shown image's file name, for the window's title ("" if it has
	// none). Owned; kept from the View, which isn't locked while the
	// viewer is drawn.
	viewer_name:   string,
	// The viewer's zoom, relative to the image fitted to its window (1 is
	// fitted, and as far out as it goes), and how far the image's centre
	// is dragged from the picture area's, in pixels.
	zoom:          f32,
	pan:           [2]f32,
	// A saved copy of what's on screen, so the viewer and saving can work
	// outside the View's lock.
	shown:         conn.Image_Info,
	state:         conn.Image_State,
	// Bytes to write to the downloads folder after the frame, and where
	// the last one went. viewer_save is the viewer's Save button, acted
	// on where the bytes are at hand.
	// save:          []u8,
	// viewer_save:   bool,
	// saved_to:      string,
	// What this frame draws, indexed by icon id (see IMAGE_ICON_BASE).
	draws:         [dynamic]render.Image_Draw,
	frame:         int,

	// The decoding thread, its queue and what it has finished.
	worker:        Decode_Worker,
	mutex:         sync.Mutex,
	wake:          sync.Sema,
	queue:         [dynamic]Decode_Job,
	results:       [dynamic]Decode_Result,
	stopping:      bool,
	ctx:           runtime.Context,
	// Bumped when the server shown changes (ui_images_switch): pictures
	// are known by its blob ids, so what was decoded for another server
	// is thrown away.
	generation:    u64,
	// The emoji sheet (render/emoji_atlas.odin) is being decoded, or
	// couldn't be (and isn't tried again).
	sheet_pending: bool,
	sheet_failed:  bool,
	// The frames of the server's emoji that move, by their texture's key,
	// and when the client started, which their time goes from.
	emoji_frames:  map[u64]Emoji_Timing,
	anim_epoch:    time.Tick,
}

// The id the emoji sheet is decoded under, which no picture's key is.
// Unlike them it belongs to no server and to no texture in `textures`:
// it goes straight to the renderer (ui_images_frame).
@(private = "file")
EMOJI_SHEET_ID :: u64(1) << 61

@(private = "file")
EMOJI_SHEET_DATA := #load("assets/emoji.webp")

ui_images_init :: proc(ui: ^UI) {
	ui.images.ctx = context
	ui.images.anim_epoch = time.tick_now()
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
	for id, &t in im.textures {
		texture_drop(im, nil, id, &t)
	}
	clear(&im.textures)
	clear(&im.draws)
}

/*
texture_drop lets go of what texture `id` holds - its pixels on `gpu`
(nil when the device is gone already), an animation's next frame, and
the worker's decoder of it - before it's removed from `textures`.
*/
@(private = "file")
texture_drop :: proc(im: ^UI_Images, gpu: ^render.Gpu, id: u64, t: ^Texture) {
	if gpu != nil && t.state == .Ready {
		render.gpu_texture_delete(gpu, &t.texture)
	}
	delete(t.next)
	t.next = nil
	if t.anim {
		anim_job(im, .Drop, id, im.generation)
	}
}

// anim_job asks the worker for an animation's next frame, or to drop it.
@(private = "file")
anim_job :: proc(im: ^UI_Images, kind: Decode_Job_Kind, id, generation: u64) {
	{
		sync.guard(&im.mutex)
		append(&im.queue, Decode_Job{kind = kind, id = id, generation = generation})
	}
	decode_wake(im)
}

/*
ui_images_switch drops every picture, as another server is shown: they
are known by the server's blob ids, which mean something else there.
What's still being decoded is thrown away when it's done, and the new
server's pictures are decoded as they're drawn.
*/
ui_images_switch :: proc(ui: ^UI) {
	im := &ui.images
	emoji_frames_clear(im)
	// The servers' own pictures stay: they're known by address, and
	// the rail draws them whichever server is shown.
	drop := make([dynamic]u64, context.temp_allocator)
	for id, &t in im.textures {
		if is_server_icon_key(id) && t.state == .Ready {
			continue
		}
		texture_drop(im, &ui.renderer.gpu, id, &t)
		append(&drop, id)
	}
	for id in drop {
		delete_key(&im.textures, id)
	}
	clear(&im.draws)
	im.viewer, im.placed = 0, false
	sync.guard(&im.mutex)
	im.generation += 1
	// The emoji sheet is every server's, and the animations dropped above
	// still have to be let go of.
	kept := 0
	for job in im.queue {
		if job.id == EMOJI_SHEET_ID || job.kind == .Drop {
			im.queue[kept] = job
			kept += 1
		} else {
			delete(job.jpeg)
		}
	}
	resize(&im.queue, kept)
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
		delete(t.next) // the worker has let go of its decoders already
	}
	delete(im.queue)
	delete(im.results)
	delete(im.textures)
	delete(im.draws)
	emoji_frames_clear(im)
	delete(im.emoji_frames)
}

// emoji_frames_clear forgets the timings of the emoji that move, which
// are a server's.
@(private = "file")
emoji_frames_clear :: proc(im: ^UI_Images) {
	for _, timing in im.emoji_frames {
		delete(timing.durations)
	}
	clear(&im.emoji_frames)
}

// ui_images_frame takes in what the worker decoded and starts a new
// frame's draw list. Call before laying out.
ui_images_frame :: proc(ui: ^UI) {
	im := &ui.images
	im.frame += 1
	clear(&im.draws)
	// The emoji sheet is wanted from the first frame, and again if the
	// device it was on was lost.
	if !render.emoji_sheet_ready(&ui.renderer) && !im.sheet_pending && !im.sheet_failed {
		im.sheet_pending = true
		{
			sync.guard(&im.mutex)
			append(
				&im.queue,
				Decode_Job {
					id = EMOJI_SHEET_ID,
					jpeg = slice.clone(EMOJI_SHEET_DATA),
					generation = im.generation,
				},
			)
		}
		decode_wake(im)
	}
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
		if result.id == EMOJI_SHEET_ID {
			im.sheet_pending = false
			if !result.ok ||
			   !render.emoji_sheet_upload(
					   &ui.renderer,
					   result.image.pixels,
					   result.image.width,
					   result.image.height,
				   ) {
				log.warn("could not decode the emoji sheet")
				im.sheet_failed = true
			}
			continue
		}
		if result.generation != im.generation {
			// Another server's; dropped with its texture (ui_images_switch)
			// unless it was still being decoded then.
			if result.anim && !result.frame {
				anim_job(im, .Drop, result.id, result.generation)
			}
			continue
		}
		if result.frame {
			anim_frame_arrived(im, &result)
			continue
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
			// Usually drawn smaller, and pictures of people round; but an
			// animation's frames replace each other, and making them again
			// for every frame isn't worth it.
			mipmaps = !result.anim && !is_emoji_atlas(result.id),
		)
		t.frame = im.frame
		if result.anim {
			t.anim, t.gif = true, result.gif
			t.due = time.tick_add(time.tick_now(), result.shown)
		}
		im.textures[result.id] = t
	}
	trim_textures(im, &ui.renderer.gpu)
	anims_advance(ui)
}

/*
anim_frame_arrived keeps an animation's next frame, which the worker
decoded when asked, for anims_advance to show when it's time. One
without pixels is the end of it.
*/
@(private = "file")
anim_frame_arrived :: proc(im: ^UI_Images, result: ^Decode_Result) {
	t, known := &im.textures[result.id]
	if !known || !t.anim {
		return // dropped meanwhile, and the worker told so
	}
	t.asked = false
	if !result.ok || result.image.pixels == nil {
		t.ended = true
		return
	}
	delete(t.next)
	t.next, t.next_shown = result.image.pixels, result.shown
	result.image.pixels = nil // the texture's now
}

// How late a frame may be shown and still have the next one follow on
// from when it was due; later (it wasn't drawn for a while, say), the
// animation carries on from now.
@(private = "file")
ANIM_LATE :: 250 * time.Millisecond

/*
anims_advance moves the animations that were drawn playing last frame
on: the next frame goes into the texture once it's due, and the one
after it is asked for. Ones that weren't - scrolled away, say, or not
under the pointer - stay where they are, as do all while the window
isn't looked at (anims_running).
*/
@(private = "file")
anims_advance :: proc(ui: ^UI) {
	im := &ui.images
	if !anims_running(ui) {
		return
	}
	now := time.tick_now()
	for id, &t in im.textures {
		if !t.anim || t.state != .Ready || t.ended || t.played < im.frame - 1 {
			continue
		}
		if t.next != nil && time.tick_diff(t.due, now) >= 0 {
			render.gpu_texture_update(
				&ui.renderer.gpu,
				t.texture,
				i32(t.width),
				i32(t.height),
				t.next,
			)
			delete(t.next)
			t.next = nil
			from := t.due if time.tick_diff(t.due, now) < ANIM_LATE else now
			t.due = time.tick_add(from, t.next_shown)
		}
		if t.next == nil && !t.asked {
			t.asked = true
			anim_job(im, .Next_Frame, id, im.generation)
		}
	}
}

// anims_running is whether animations play: not while the window is
// hidden or another has the focus.
@(private = "file")
anims_running :: proc(ui: ^UI) -> bool {
	return ui.window != nil && !ui.hidden && (ALWAYS_FOCUSED || glfw.WindowFocused(ui.window))
}

// anim_badge says, in the corner of an animated picture that isn't
// playing, that it would move (and as what).
@(private = "file")
anim_badge :: proc(ctx: ^mu.Context, rect: mu.Rect, label: string) {
	font := ctx.style.font
	pad: i32 = 3
	w := ctx.text_width(font, label) + 2 * pad
	h := ctx.text_height(font) + pad
	if rect.w < w + 2 * pad || rect.h < h + 2 * pad {
		return // too small a picture to put it on
	}
	r := mu.Rect{rect.x + pad, rect.y + rect.h - h - pad, w, h}
	mu.draw_rect(ctx, r, {0, 0, 0, 170})
	mu.draw_text(ctx, font, label, {r.x + pad, r.y + pad / 2}, {255, 255, 255, 255})
}

/*
anim_drawn asks for a frame when an animation that was just drawn moves
on: when its next frame is due, or right away if that's still to be
asked for (it's been paused). The next frame being decoded doesn't wake
the UI (that would be a whole frame drawn for nothing): it's taken when
it's due, and if it isn't there yet, it's looked for again a tick later.
*/
@(private = "file")
anim_drawn :: proc(ui: ^UI, t: Texture) {
	if !t.anim || t.ended || !anims_running(ui) {
		return
	}
	switch {
	case t.next != nil:
		anim_redraw_at(ui, t.due)
	case !t.asked:
		ui_redraw(ui)
	case:
		anim_redraw_at(ui, time.tick_add(time.tick_now(), time.Millisecond))
	}
}

/*
anim_redraw_at asks for a frame for an animation by `at`, put off to
the next of the ticks ANIM_MIN_SHOWN apart that all animations share
(from when the client started): however many there are, out of step
with each other, they're drawn together, at most 30 times a second.
*/
anim_redraw_at :: proc(ui: ^UI, at: time.Tick) {
	tick := ANIM_MIN_SHOWN * time.Millisecond
	since := max(time.tick_diff(ui.images.anim_epoch, at), 0)
	ticks := (since + tick - 1) / tick
	ui_redraw_at(ui, time.tick_add(ui.images.anim_epoch, ticks * tick))
}

/*
image_fitted draws a picture as large as fits `area`, at its left, for
pictures whose size isn't known until they're decoded (a message's
attached picture, ui_attachments.odin): the area doesn't change when it
arrives. Clicking it opens the viewer. `save` says the viewer's Save was
pressed for this one, for the caller to save it its own way.

An animated one plays as the "Animate pictures" setting says: while the
pointer is on it (the default), always, or never. `hovered` is for one
that's only shown while the pointer is on something (a chip's preview):
it plays unless the setting is never.
*/
image_fitted :: proc(
	ui: ^UI,
	key: u64,
	state: conn.Image_State,
	data: []u8,
	area: mu.Rect,
	name := "",
	hovered := false,
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
		mu.draw_rect(ctx, area, theme.image_bg)
		mu.draw_control_text(ctx, label, area, .TEXT, {.ALIGN_CENTER})
		return
	}
	w, h := conn.fit_box(t.width, t.height, int(area.w), int(area.h))
	rect := mu.Rect{area.x, area.y, i32(w), i32(h)}
	over := mu.mouse_over(ctx, rect)
	playing := false
	if t.anim {
		switch settings.animate_pictures(&ui.settings) {
		case .Hover:
			playing = over || hovered
		case .Always:
			playing = true
		case .Never:
		}
	}
	t.frame = im.frame
	if playing {
		t.played = im.frame
	}
	im.textures[key] = t
	append(&im.draws, render.Image_Draw{texture = t.texture})
	mu.draw_icon(
		ctx,
		mu.Icon(render.IMAGE_ICON_BASE + len(im.draws) - 1),
		rect,
		{255, 255, 255, 255},
	)
	if playing {
		anim_drawn(ui, t)
	} else if t.anim {
		anim_badge(ctx, rect, "GIF" if t.gif else "WEBP")
	}
	if over {
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
		if name != im.viewer_name {
			delete(im.viewer_name)
			im.viewer_name = strings.clone(name)
		}

	}
	return
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
	// The window's title is also what identifies it.
	title := im.viewer_name if im.viewer_name != "" else IMAGE_WINDOW
	// Open it centred, big enough for the image but inside the window.
	if !im.placed {
		im.placed = true
		im.zoom, im.pan = 1, {}
		w := max(min(int(im.shown.width) + 2 * int(ctx.style.padding), int(window_w) - 40), 240)
		h := max(min(int(im.shown.height) + 60, int(window_h) - 40), 160)
		rect := mu.Rect{(window_w - i32(w)) / 2, (window_h - i32(h)) / 2, i32(w), i32(h)}
		if cnt := mu.get_container(ctx, title); cnt != nil {
			cnt.rect = rect
			cnt.open = true
		}
	}

	if !mu.begin_window(ctx, title, {}, {.NO_SCROLL}) {
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
	if t, known := &im.textures[im.viewer]; known && t.state == .Ready {
		// Drawn, also when its place in the chat isn't: kept, and played
		// whatever the setting says (opening it asks to see it).
		t.frame, t.played = im.frame, im.frame
		anim_drawn(ui, t^)
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
		mu.draw_rect(ctx, rect, theme.image_bg)
		mu.draw_control_text(ctx, "loading image...", rect, .TEXT, {.ALIGN_CENTER})
	}

	mu.layout_row(ctx, {90, -1})
	if .SUBMIT in mu.button(ctx, "Fit") {
		im.zoom, im.pan = 1, {}
	}
	shown_percent := 100 * f32(rect.w) / f32(max(im.shown.width, 1))
	status := fmt.tprintf("%dx%d   %.0f%%", im.shown.width, im.shown.height, shown_percent)
	with_text_color(ctx, theme.dim, status, label_proc)
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

// image_want has a picture decoded under `key` from `data` (copied),
// unless it's known already, for image_fitted to draw without the bytes.
image_want :: proc(ui: ^UI, key: u64, data: []u8) {
	if key not_in ui.images.textures && len(data) > 0 {
		enqueue_decode(&ui.images, key, data)
	}
}

// image_size is a decoded picture's own size; false until it's decoded.
image_size :: proc(ui: ^UI, key: u64) -> (w, h: int, ok: bool) {
	t, known := ui.images.textures[key]
	if !known || t.state != .Ready {
		return
	}
	return t.width, t.height, true
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
		texture_drop(im, gpu, oldest_id, &t)
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
// messages' pictures (which are their blob's id), and the one the frames
// of one that moves are (with their blob's id).
@(private = "file")
EMOJI_SHEET_KEY :: u64(1) << 62
@(private = "file")
EMOJI_FRAMES_KEY :: u64(1) << 58

// is_emoji_atlas is whether a picture's key is one of the server's
// sheets of emoji cells, which have no smaller copies made (mipmaps):
// those would mix neighbouring cells.
@(private = "file")
is_emoji_atlas :: proc(key: u64) -> bool {
	return key & (EMOJI_SHEET_KEY | EMOJI_FRAMES_KEY) != 0 && key & AVATAR_KEY == 0
}

// Emoji_Timing is how the frames of one of the server's emoji that move
// are laid out and shown: each one's time in ms (owned), the columns of
// their grid, and the time of them all.
Emoji_Timing :: struct {
	durations: []u16,
	columns:   int,
	total:     int,
}

/*
custom_emoji_icon is what draws the server's emoji number `index`: an
icon id for mu.draw_icon, for this frame. False until the sheet is here
and decoded. Call with the View locked.

One that moves is drawn from its own frames (custom_emoji_frame) once
they're here, while the window has the focus; till then, and while it
hasn't, it's its first frame, in the sheet.
*/
custom_emoji_icon :: proc(ui: ^UI, index: int) -> (mu.Icon, bool) {
	v := ui.view
	im := &ui.images
	e := &v.emoji
	if e.blob == 0 || index < 0 || index >= len(e.names) {
		return {}, false
	}
	if icon, moving := custom_emoji_frame(ui, index); moving {
		return icon, true
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
	return emoji_cell(im, t.texture, index, cols, rows, e.cell), true
}

// emoji_cell draws cell `index` of a grid of `cols` x `rows` cells of
// `cell` pixels, each followed by a pixel of gap (EMOJI_STRIDE on the
// server).
@(private = "file")
emoji_cell :: proc(
	im: ^UI_Images,
	texture: render.Gpu_Texture,
	index, cols, rows, cell: int,
) -> mu.Icon {
	stride := f32(cell + 1)
	u0 := f32(index % cols) / f32(cols)
	v0 := f32(index / cols) / f32(rows)
	du := f32(cell) / (f32(cols) * stride)
	dv := f32(cell) / (f32(rows) * stride)
	append(&im.draws, render.Image_Draw{texture = texture, uv = {u0, v0, u0 + du, v0 + dv}})
	return mu.Icon(render.IMAGE_ICON_BASE + len(im.draws) - 1)
}

/*
custom_emoji_frame draws the server's emoji `index` as it is now, if it
moves and its frames are here: the frame is the one the time since the
client started is in, so all of them that are the same move together.
It asks for a frame when the next one is due, at most 30 a second.
*/
@(private = "file")
custom_emoji_frame :: proc(ui: ^UI, index: int) -> (icon: mu.Icon, ok: bool) {
	v := ui.view
	im := &ui.images
	e := &v.emoji
	blob: proto.Blob_Id
	for a in e.animated {
		if a.index == index {
			blob = a.blob
		}
	}
	if blob == 0 || !anims_running(ui) {
		return
	}
	key := EMOJI_FRAMES_KEY | u64(blob)
	t, known := im.textures[key]
	if !known {
		img, here := v.blobs[blob]
		if !here || img.state != .Ready {
			return
		}
		f, read := proto.decode_emoji_frames(img.jpeg)
		total := 0
		for d in f.durations {
			total += int(d)
		}
		if !read || total == 0 {
			im.textures[key] = {
				state = .Failed,
				frame = im.frame,
			}
			return
		}
		if old, had := im.emoji_frames[key]; had {
			delete(old.durations)
		}
		im.emoji_frames[key] = {
			durations = slice.clone(f.durations),
			columns   = f.columns,
			total     = total,
		}
		enqueue_decode(im, key, f.image)
		return
	}
	timing, timed := im.emoji_frames[key]
	if t.state != .Ready || !timed {
		return
	}
	t.frame = im.frame
	im.textures[key] = t

	now := int(time.duration_milliseconds(time.tick_since(im.anim_epoch)))
	at := now % timing.total
	frame, ends := 0, 0
	for d, i in timing.durations {
		ends += int(d)
		if at < ends {
			frame = i
			break
		}
	}
	anim_redraw_at(ui, time.tick_add(time.tick_now(), time.Duration(ends - at) * time.Millisecond))
	n := len(timing.durations)
	rows := (n + timing.columns - 1) / timing.columns
	return emoji_cell(im, t.texture, frame, timing.columns, rows, e.cell), true
}

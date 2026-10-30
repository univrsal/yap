package client

import "base:intrinsics"
import "client:clipboard"
import "client:platform"
import "client:render"
import glfw "client:wglfw"
import log "common:wlog"
import "core:math"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import mu "vendor:microui"

// The window: opening and closing it, its size and scale, the cursor, the
// clipboard, and GLFW's callbacks, which turn its input into microui's.

window_open :: proc(ui: ^UI) -> bool {
	render.gpu_window_hints()
	// Where window coordinates are physical pixels (Windows, X11), size
	// the window for the monitor's scale so it isn't tiny on high DPI.
	glfw.WindowHint(glfw.SCALE_TO_MONITOR, true)
	when !platform.WEB {
		// The name of the installed .desktop entry (see settings/install_unix.odin).
		// Wayland uses it to find the window's icon, and the desktop uses it
		// to group the window under that entry.
		glfw.WindowHintString(glfw.WAYLAND_APP_ID, "yap")
		glfw.WindowHintString(glfw.X11_CLASS_NAME, "yap")
		glfw.WindowHintString(glfw.X11_INSTANCE_NAME, "yap")
	}
	titlebar_window_hints(ui.settings.merge_title_bar)
	ui.window = glfw.CreateWindow(ui.window_size.x, ui.window_size.y, "Yap", nil, nil)
	delete(ui.window_title)
	ui.window_title = strings.clone("Yap") // what the window title says
	if ui.window == nil {
		log.errorf("failed to create a window (%s is required)", render.GPU_REQUIREMENT)
		return false
	}
	glfw.SetWindowSizeLimits(ui.window, 480, 300, glfw.DONT_CARE, glfw.DONT_CARE)
	when !platform.WEB {
		set_window_icon(ui.window)
	}
	if !render.renderer_init(&ui.renderer, ui.window) {
		log.errorf("failed to set up %s rendering", render.GPU_REQUIREMENT)
		glfw.DestroyWindow(ui.window)
		ui.window = nil
		return false
	}
	// Before the title bar, whose window procedure goes in front of this one.
	thumbbar_attach(ui.window)
	titlebar_merge(ui.window, ui.settings.merge_title_bar)
	set_swap_pace(ui)
	ui.renderer.images = &ui.images.draws

	glfw.SetWindowIconifyCallback(ui.window, iconify_callback)
	when !platform.WEB {
		glfw.SetWindowRefreshCallback(ui.window, refresh_callback)
		glfw.SetWindowFocusCallback(ui.window, focus_callback)
		glfw.SetCursorEnterCallback(ui.window, cursor_enter_callback)
	}
	when ODIN_OS == .Darwin {
		glfw.SetFramebufferSizeCallback(ui.window, resize_callback)
	}
	glfw.SetCursorPosCallback(ui.window, cursor_pos_callback)
	glfw.SetMouseButtonCallback(ui.window, mouse_button_callback)
	glfw.SetScrollCallback(ui.window, scroll_callback)
	glfw.SetKeyCallback(ui.window, key_callback)
	glfw.SetCharCallback(ui.window, char_callback)
	when !platform.WEB {
		glfw.SetDropCallback(ui.window, drop_callback)
	}
	// The cursor outlives the window, but the cursor that the window shows
	// doesn't (see set_cursor).
	ui.cursor_shown = .Arrow
	ui.metrics = {}
	ui_redraw(ui)
	return true
}

// reset_gpu recreates everything on the GPU for the same window after the
// device has been lost (for example by a graphics driver update or reset). If the
// new device doesn't come up either, it is tried again a second later.
// Nothing is drawn until then.
reset_gpu :: proc(ui: ^UI) {
	if ui.gpu_reset_at != {} && time.tick_since(ui.gpu_reset_at) < time.Second {
		return
	}
	ui.gpu_reset_at = time.tick_now()
	log.warn("ui: lost the GPU device, setting it up again")
	ui_images_forget_textures(ui)
	ui_avatars_forget_textures(ui)
	ui_video_forget_texture(ui)
	if !render.renderer_reset(&ui.renderer, ui.window) {
		log.error("ui: could not set the GPU device up again")
		return
	}
	set_swap_pace(ui)
}

window_close :: proc(ui: ^UI) {
	if ui.window == nil {
		return
	}
	// Come back at the same size as before. Where window coordinates
	// are physical pixels (see window_metrics), CreateWindow scales the
	// size it is given for the monitor (SCALE_TO_MONITOR), so it has to
	// be given the unscaled size, or the window grows every time.
	if w, h := glfw.GetWindowSize(ui.window); w > 0 && h > 0 {
		fb_w, _ := glfw.GetFramebufferSize(ui.window)
		if f32(fb_w) / f32(w) <= 1.01 {
			sx, sy := glfw.GetWindowContentScale(ui.window)
			w = i32(math.round(f32(w) / max(sx, 1)))
			h = i32(math.round(f32(h) / max(sy, 1)))
		}
		ui.window_size = {w, h}
	}
	// The video library releases what it created on the device while the device
	// still exists (an OpenGL context can only be cleaned up while current).
	ui_video_forget_texture(ui)
	render.renderer_destroy(&ui.renderer)
	// The pictures' textures belong to the device that is about to go away.
	// They are decoded again when they are next on screen.
	ui_images_forget_textures(ui)
	ui_avatars_forget_textures(ui)
	thumbbar_detach()
	glfw.DestroyWindow(ui.window)
	ui.window = nil
}

// clipboard_init sets up reading images from the clipboard. On Wayland it
// needs GLFW's connection, because only the focused window may read.
clipboard_init :: proc() {
	wayland: rawptr
	when ODIN_OS == .Linux {
		if glfw.GetPlatform() == glfw.PLATFORM_WAYLAND {
			wayland = glfw.GetWaylandDisplay()
		}
	}
	clipboard.init(wayland)
}

Cursor :: enum {
	Arrow, // the window's own cursor, not one of ours
	Hand,
	IBeam,
	// Over the edges of a window that we resize ourselves (see window_edge).
	Resize_EW,
	Resize_NS,
	Resize_NWSE,
	Resize_NESW,
}

// set_cursor switches the mouse cursor, unless it is already that one.
set_cursor :: proc(ui: ^UI, cursor: Cursor) {
	if cursor == ui.cursor_shown {
		return
	}
	ui.cursor_shown = cursor
	if cursor != .Arrow && ui.cursors[cursor] == nil {
		ui.cursors[cursor] = glfw.CreateStandardCursor(CURSOR_SHAPES[cursor])
	}
	glfw.SetCursor(ui.window, ui.cursors[cursor])
}

Window_Metrics :: struct {
	logical_w, logical_h: f32, // the size the UI is laid out for
	fb_w, fb_h:           i32,
	scale:                f32, // physical pixels per logical pixel
	input_scale:          f32, // logical pixels per window coordinate
}

// Platforms disagree on what window coordinates are. On Wayland and macOS
// they are logical and the framebuffer is bigger on high-DPI screens. On
// Windows and X11 they are physical pixels, and the monitor's scale is only
// known from the content scale. Either way we lay out in logical pixels
// and render at `scale`.
window_metrics :: proc(window: glfw.WindowHandle, ui_scale: f32) -> (m: Window_Metrics) {
	w, h := glfw.GetWindowSize(window)
	m.fb_w, m.fb_h = glfw.GetFramebufferSize(window)
	if w <= 0 || h <= 0 || m.fb_w <= 0 {
		return {logical_w = 1, logical_h = 1, scale = 1, input_scale = 1}
	}

	// A browser reports its ratio itself (see wglfw_web.odin). The framebuffer's
	// whole pixels would only give an approximation that changes with the
	// window's size, and with it the font's rasterization.
	ratio := f32(m.fb_w) / f32(w)
	if ratio > 1.01 && !platform.WEB {
		// The framebuffer's whole pixels make the ratio wobble as the
		// window is resized (1.5, then 1.4995). Then everything snapped
		// to physical pixels would shift by one, and the fonts would be
		// rasterized again at every step. Scales are whole 120ths
		// (Wayland's fractional scaling), which the wobble never
		// reaches.
		m.scale = math.round(ratio * 120) / 120
		m.logical_w, m.logical_h = f32(w), f32(h)
	} else {
		content, _ := glfw.GetWindowContentScale(window)
		m.scale = max(content, 1)
		m.logical_w, m.logical_h = f32(m.fb_w) / m.scale, f32(m.fb_h) / m.scale
	}

	// The UI's own zoom stacks with the display's DPI scale above.
	// It shrinks the logical canvas the layout runs in while rendering it
	// at a proportionally higher `scale`. That makes every widget sized in
	// logical pixels cover more of the screen without the layout code (or the
	// font and icon atlases, which already rebuild when `scale` changes)
	// knowing the difference.
	m.scale *= ui_scale
	m.logical_w /= ui_scale
	m.logical_h /= ui_scale
	m.input_scale = m.logical_w / f32(w)
	return
}

// GLFW input -> microui. The callbacks run on the main thread, inside
// glfw.WaitEventsTimeout.

glfw_error_callback :: proc "c" (code: i32, description: cstring) {
	context = platform.callback_context()
	context.logger = g_logger
	log.errorf("GLFW: %s (0x%x)", description, code)
}

// to_logical turns window coordinates into the UI's (see Window_Metrics).
to_logical :: proc "contextless" (v: f64) -> i32 {
	return i32(v * f64(g_ui.input_scale))
}

// iconify_callback records that the desktop has minimized us, so the loop can
// move the client to the tray if the settings say so.
//
// Not every desktop reports this. X11 does. Wayland has no message for it, so
// there the window simply minimizes and the setting does nothing. The
// settings page says as much when it would matter.
@(private = "file")
iconify_callback :: proc "c" (window: glfw.WindowHandle, iconified: i32) {
	if iconified != 0 {
		g_ui.minimized = true
	}
	ui_redraw(g_ui)
}

// focus_callback draws a frame when the window gains or loses the focus,
// because animated pictures only play while it has the focus (see anims_running).
@(private = "file")
focus_callback :: proc "c" (window: glfw.WindowHandle, focused: i32) {
	ui_redraw(g_ui)
}

// refresh_callback is called when the window needs its contents drawn again,
// for example when it was uncovered and nothing kept them. A frame is then drawn
// at the next turn of the loop, except on Windows, where one is drawn right
// away. There it also comes while the window is being resized: dragging its edge
// runs a loop of the system's own until the mouse is released, and
// glfw.WaitEventsTimeout doesn't return before then, so without this
// the window would stand still for as long as the drag lasts.
@(private = "file")
refresh_callback :: proc "c" (window: glfw.WindowHandle) {
	context = platform.callback_context()
	context.logger = g_logger
	ui_redraw(g_ui)
	when ODIN_OS == .Windows {
		if g_ui.window == window && !g_ui.hidden {
			draw_frame(g_ui)
		}
	}
}

// resize_callback is macOS's way into the resize loop that refresh_callback
// describes. AppKit never asks a view whose layer is ours (Metal's) to
// draw, so no refresh comes while the edge is dragged, but the window's
// size changes do. Each one is drawn at once, in step with the window's new
// size (see render.gpu_resizing), or the picture would lag behind its edge.
when ODIN_OS == .Darwin {
	@(private = "file")
	resize_callback :: proc "c" (window: glfw.WindowHandle, width, height: i32) {
		context = platform.callback_context()
		context.logger = g_logger
		ui_redraw(g_ui)
		if g_ui.window == window && !g_ui.hidden {
			render.gpu_resizing(&g_ui.renderer.gpu, true)
			draw_frame(g_ui)
			render.gpu_resizing(&g_ui.renderer.gpu, false)
		}
	}
}

@(private = "file")
cursor_pos_callback :: proc "c" (window: glfw.WindowHandle, x, y: f64) {
	context = platform.callback_context()
	ui_redraw(g_ui)
	titlebar_motion(window)
	mu.input_mouse_move(&g_ui.ctx, to_logical(x), to_logical(y))
}

// cursor_enter_callback takes the pointer out of microui's sight when it
// leaves the window, so nothing stays hovered (for example an animated picture
// that plays while the pointer is on it). The exception is while a button is
// held, because something is being dragged, which carries on outside the window.
@(private = "file")
cursor_enter_callback :: proc "c" (window: glfw.WindowHandle, entered: i32) {
	context = platform.callback_context()
	if entered == 0 && g_ui.ctx.mouse_down_bits == {} {
		ui_redraw(g_ui)
		mu.input_mouse_move(&g_ui.ctx, -100_000, -100_000)
	}
}

@(private = "file")
mouse_button_callback :: proc "c" (window: glfw.WindowHandle, button, action, mods: i32) {
	context = platform.callback_context()
	context.logger = g_logger
	ui_redraw(g_ui)
	btn: mu.Mouse
	switch button {
	case glfw.MOUSE_BUTTON_LEFT:
		btn = .LEFT
	case glfw.MOUSE_BUTTON_RIGHT:
		btn = .RIGHT
	case glfw.MOUSE_BUTTON_MIDDLE:
		btn = .MIDDLE
	case:
		return
	}
	wx, wy := glfw.GetCursorPos(window)
	x, y := to_logical(wx), to_logical(wy)
	log.debugf("ui: mouse %v %s at %d,%d", btn, action == glfw.PRESS ? "down" : "up", x, y)
	// Hover was worked out at the last known pointer position. If the
	// press is somewhere else (because motion events were missed), it would click
	// whatever was under the old position, so drop the hover instead.
	// The edges of a window without a frame resize it (X11 only, see
	// ui_titlebar_x11.odin), and the strip where a title bar would be moves
	// it instead, where it isn't a control in the main window or the rail.
	// The strip reaches down to the line under the title row
	// (UI.title_line), if that is lower.
	if btn == .LEFT && action == glfw.PRESS {
		if edge := window_edge(g_ui, x, y); edge != .None {
			titlebar_resize(window, edge)
			return
		}
	}
	if btn == .LEFT &&
	   action == glfw.PRESS &&
	   y < max(g_ui.titlebar_height, g_ui.title_line) &&
	   g_ui.ctx.hover_id == 0 &&
	   (g_ui.ctx.hover_root == mu.get_container(&g_ui.ctx, "yap") ||
			   g_ui.ctx.hover_root == mu.get_container(&g_ui.ctx, RAIL_WINDOW)) {
		titlebar_press(window)
		return
	}
	if action == glfw.PRESS && g_ui.ctx.mouse_pos != {x, y} {
		g_ui.ctx.hover_id = 0
	}
	switch action {
	case glfw.PRESS:
		mu.input_mouse_down(&g_ui.ctx, x, y, btn)
	case glfw.RELEASE:
		mu.input_mouse_up(&g_ui.ctx, x, y, btn)
	}
}

// How far a notch of the mouse wheel scrolls, in pixels.
WHEEL_NOTCH :: 60

@(private = "file")
scroll_callback :: proc "c" (window: glfw.WindowHandle, x, y: f64) {
	context = platform.callback_context()
	ui_redraw(g_ui)
	// A wheel turns in whole notches, which are spread over a few frames
	// (scroll_step). A touchpad scrolls in fractions of one, a little at a
	// time already, so that goes to microui as it comes.
	if x == math.round(x) && y == math.round(y) {
		g_ui.scroll_left += {f32(-x * WHEEL_NOTCH), f32(-y * WHEEL_NOTCH)}
	} else {
		mu.input_scroll(&g_ui.ctx, i32(-x * WHEEL_NOTCH), i32(-y * WHEEL_NOTCH))
	}
}

// The mouse wheel's scrolling eases out: what is left shrinks by e every
// SCROLL_EASE, so a notch is mostly done in a few frames. While some is left,
// frames come every SCROLL_FRAME.
SCROLL_EASE :: 0.1 // seconds
SCROLL_FRAME :: time.Second / 60

// scroll_step hands microui this frame's share of the mouse wheel's
// scrolling, before the frame is laid out. Only whole pixels are handed over,
// so in the end a notch scrolls exactly as far as it would at once.
scroll_step :: proc(ui: ^UI) {
	if ui.scroll_left == {} {
		return
	}
	now := time.tick_now()
	// The first frame of a scroll gets a frame's share too.
	dt := f32(time.duration_seconds(SCROLL_FRAME))
	if ui.scroll_at != {} {
		dt = clamp(f32(time.duration_seconds(time.tick_diff(ui.scroll_at, now))), 0, 0.1)
	}
	left := ui.scroll_left * math.exp(-dt / SCROLL_EASE)
	for &v in left {
		if abs(v) < 1 {
			v = 0 // the rest, now
		}
	}
	give := [2]i32 {
		i32(math.round(ui.scroll_left.x - left.x)),
		i32(math.round(ui.scroll_left.y - left.y)),
	}
	// At least a pixel while some is left: with a slow ease, a frame's share
	// of the last few pixels rounds to none, and it would never finish.
	for &g, i in give {
		if g == 0 && ui.scroll_left[i] != 0 {
			g = 1 if ui.scroll_left[i] > 0 else -1
		}
	}
	ui.scroll_left -= {f32(give.x), f32(give.y)}
	mu.input_scroll(&ui.ctx, give.x, give.y)
	if ui.scroll_left != {} {
		ui.scroll_at = now
		ui_redraw_in(ui, SCROLL_FRAME)
	} else {
		ui.scroll_at = {}
	}
}

@(private = "file")
char_callback :: proc "c" (window: glfw.WindowHandle, codepoint: rune) {
	context = platform.callback_context()
	ui_redraw(g_ui)
	if g_ui.drop_space && codepoint == ' ' {
		g_ui.drop_space = false
		return
	}
	buf, n := utf8.encode_rune(codepoint)
	mu.input_text(&g_ui.ctx, string(buf[:n]))
}

@(private = "file")
key_callback :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
	context = platform.callback_context()
	ui_redraw(g_ui)
	g_ui.drop_space = false
	// The command palette: Cmd+K on macOS, where Ctrl+Space usually switches
	// the input source, and in a browser (which may be on a Mac).
	if action == glfw.PRESS &&
	   (ODIN_OS == .Darwin || platform.WEB) &&
	   key == glfw.KEY_K &&
	   mods & (glfw.MOD_SUPER | glfw.MOD_CONTROL | glfw.MOD_ALT | glfw.MOD_SHIFT) ==
		   glfw.MOD_SUPER {
		g_ui.keys += {.Palette}
		return
	}
	// The composer's markdown keys and the command palette, from the key's own
	// modifiers. Ctrl+Shift+X isn't Ctrl+X: it doesn't go on to cut.
	if action != glfw.RELEASE && mods & glfw.MOD_CONTROL != 0 && mods & glfw.MOD_ALT == 0 {
		shift := mods & glfw.MOD_SHIFT != 0
		extra: Maybe(Extra_Key)
		switch {
		case key == glfw.KEY_B && !shift:
			extra = .Bold
		case key == glfw.KEY_I && !shift:
			extra = .Italic
		case key == glfw.KEY_U && !shift:
			extra = .Underline
		case key == glfw.KEY_E && !shift:
			extra = .Code
		case key == glfw.KEY_X && shift:
			extra = .Strike
		case key == glfw.KEY_Z && !shift:
			extra = .Undo
		case key == glfw.KEY_Y || (key == glfw.KEY_Z && shift):
			extra = .Redo
		case (key == glfw.KEY_SPACE || key == glfw.KEY_K) && !shift:
			if action == glfw.PRESS {
				g_ui.keys += {.Palette}
			}
			// Windows also sends Ctrl+Space as a space to type.
			g_ui.drop_space = key == glfw.KEY_SPACE
			return
		}
		if e, ok := extra.?; ok {
			g_ui.keys += {e}
			return
		}
	}
	k: mu.Key
	switch key {
	case glfw.KEY_LEFT_SHIFT, glfw.KEY_RIGHT_SHIFT:
		k = .SHIFT
	case glfw.KEY_LEFT_CONTROL, glfw.KEY_RIGHT_CONTROL:
		k = .CTRL
	case glfw.KEY_LEFT_ALT, glfw.KEY_RIGHT_ALT:
		k = .ALT
	case glfw.KEY_BACKSPACE:
		k = .BACKSPACE
	case glfw.KEY_DELETE:
		k = .DELETE
	case glfw.KEY_ESCAPE:
		// Close the enlarged image, if one is open. For the rest of
		// the frame, treat it as a key like microui's (see UI.keys).
		if action == glfw.PRESS {
			g_ui.images.viewer = {}
			g_ui.keys += {.Escape}
		}
		return
	case glfw.KEY_UP, glfw.KEY_DOWN, glfw.KEY_TAB:
		if action == glfw.PRESS || action == glfw.REPEAT {
			switch key {
			case glfw.KEY_UP:
				key_press(.Up)
			case glfw.KEY_DOWN:
				key_press(.Down)
			case:
				key_press(.Back_Tab if mods & glfw.MOD_SHIFT != 0 else .Tab)
			}
		}
		return
	case glfw.KEY_F6:
		if action == glfw.PRESS {
			key_press(.Prev_Area if mods & glfw.MOD_SHIFT != 0 else .Next_Area)
		}
		return
	case glfw.KEY_SPACE:
		// The space itself comes as text (char_callback).
		if action == glfw.PRESS && mods & (glfw.MOD_CONTROL | glfw.MOD_ALT | glfw.MOD_SUPER) == 0 {
			key_press(.Activate)
		}
		return
	case glfw.KEY_ENTER, glfw.KEY_KP_ENTER:
		k = .RETURN
		// Shift+Enter starts a new line in a text area. The key's own
		// modifiers say so, even when Shift is released again before the
		// frame (and with it microui's SHIFT).
		if action != glfw.RELEASE && mods & glfw.MOD_SHIFT != 0 {
			g_ui.keys += {.Newline}
		}
	case glfw.KEY_LEFT:
		k = .LEFT
	case glfw.KEY_RIGHT:
		k = .RIGHT
	case glfw.KEY_HOME:
		k = .HOME
	case glfw.KEY_END:
		k = .END
	case glfw.KEY_A:
		k = .A
	case glfw.KEY_X:
		k = .X
	case glfw.KEY_C:
		k = .C
	case glfw.KEY_V:
		k = .V
	case:
		return
	}
	switch action {
	case glfw.PRESS, glfw.REPEAT:
		mu.input_key_down(&g_ui.ctx, k)
	case glfw.RELEASE:
		mu.input_key_up(&g_ui.ctx, k)
	}
}

set_clipboard :: proc(user_data: rawptr, text: string) -> bool {
	// Emscripten's GLFW has no clipboard. In a browser it comes from the page
	// (see ui_paste_web.odin).
	when platform.WEB {
		return web_copy_text(text)
	} else {
		glfw.SetClipboardString(
			g_ui.window,
			strings.clone_to_cstring(text, context.temp_allocator),
		)
		return true
	}
}

get_clipboard :: proc(user_data: rawptr) -> (string, bool) {
	when platform.WEB {
		text := web_pasted_text()
	} else {
		text := glfw.GetClipboardString(g_ui.window)
	}
	return text, text != ""
}

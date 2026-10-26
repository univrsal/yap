package client

import "base:intrinsics"
import "client:audio"
import "client:clipboard"
import "client:conn"
import "client:platform"
import "client:render"
import "client:settings"
import "client:video"
import glfw "client:wglfw"
import "common:."
import log "common:wlog"
import "core:crypto/ecdh"
import "core:hash"
import "core:slice"
import "core:sync"
import "core:time"
import mu "vendor:microui"

// Running the UI: starting up and shutting down, and the frame loop, which
// only draws when something changed (ui_redraw and friends) and paces the
// swaps.

// run_ui drives the client from a loop of its own, which is what a desktop
// provides. A web build has no loop of its own because the browser hands
// out one frame at a time, so the work is split into starting up, one turn
// of the loop and shutting down, and main_web.odin drives those.
run_ui :: proc(opts: UI_Options) -> bool {
	ui := new(UI)
	defer free(ui)
	if !ui_startup(ui, opts) {
		ui_shutdown(ui)
		return false
	}
	for ui_frame(ui) {}
	app_sound_goodbye(ui)
	ui_shutdown(ui)
	return true
}

ui_startup :: proc(ui: ^UI, opts: UI_Options) -> bool {
	g_ui = ui
	g_logger = context.logger
	ui.opts = opts
	ui.log_drawn = -1
	ui.view = &ui.no_view
	conn.view_init(ui.view)
	ui.view.wake = ui_wake
	video.set_wake(ui_wake)
	ui_chat_init(ui)

	// Load (or create) the key now, to show our id before connecting.
	{
		key: ecdh.Private_Key
		if common.load_or_create_private_key(opts.key_path, &key) {
			ecdh.private_key_public_bytes(&key, ui.my_key[:])
			ecdh.private_key_clear(&key)
		}
	}
	ui.settings = settings.settings_load(opts.settings_path)
	ui.ui_scale_draft = settings.ui_scale_factor(&ui.settings) * 100
	ui.chat_scale_draft = settings.chat_scale_factor(&ui.settings) * 100
	image_cache_start(ui)

	// Audio problems shouldn't stop the rest of the client from working.
	// The settings page shows what went wrong.
	audio.audio_init(&ui.audio)
	app_audio_init(ui)
	sounds_load(ui)
	app_sound_play(ui, .Welcome)

	glfw.SetErrorCallback(glfw_error_callback)
	titlebar_init(ui.settings.merge_title_bar)
	if !glfw.Init() {
		log.error("failed to initialize GLFW")
		return false
	}

	ui.window_size = {760, 480}
	if !window_open(ui) {
		return false
	}
	clipboard_init()
	ui_images_init(ui)

	mu.init(&ui.ctx, set_clipboard, get_clipboard)
	ui.ctx.text_width = render.ui_text_width
	ui.ctx.text_height = render.ui_text_height
	ui.ctx.draw_frame = draw_frame_themed
	ui.input_scale = 1

	ui.action = .Start
	return true
}

// ui_frame is one turn of the loop. It returns false when the client
// is done and should shut down.
ui_frame :: proc(ui: ^UI) -> bool {
	if ui.quitting {
		return false
	}

	// Closing the window moves the client to the tray instead of
	// ending it, if there is a tray icon and the settings ask for that
	// (see ui_tray.odin). Quit in the tray menu sets `quitting` instead,
	// and there may be no window at all.
	if ui.window != nil && glfw.WindowShouldClose(ui.window) {
		if !tray_takes_window(ui, ui.settings.close_to_tray) {
			return false
		}
		glfw.SetWindowShouldClose(ui.window, false)
		hide_to_tray(ui)
	}

	// Minimizing can also move the client to the tray. Only some desktops report
	// when the window is minimized (see iconify_callback).
	if ui.minimized {
		ui.minimized = false
		if tray_takes_window(ui, ui.settings.minimize_to_tray) {
			// Leave the minimized state first, so the window comes back
			// as a normal window instead of being minimized again.
			glfw.RestoreWindow(ui.window)
			hide_to_tray(ui)
		}
	}

	free_all(context.temp_allocator)

	if ui.action != .None {
		ui_redraw(ui)
	}
	switch ui.action {
	case .None:
	case .Start:
		connect_joined(ui)
	case .Disconnect:
		disconnect(ui, ui.session)
	case .Reconnect:
		reconnect(ui, ui.session)
	case .Trust_Key:
		trust_new_key(ui)
	}
	ui.action = .None
	join_frame(ui)
	rail_frame(ui)
	switch_now(ui)
	memory_frame(ui)

	// Wake up for input, or often enough for the work below that isn't
	// drawing. A frame is only drawn when there is something new to show
	// (see frame_due). Listen back without a connection is fed from this
	// loop (see monitor_update), so the loop needs to run at the display's rate.
	// In a web build the browser has already decided when this frame
	// happens, so there is nothing to wait for.
	// A frame asked for by a time (ui_redraw_at) wakes it sooner, so that what
	// moves faster than that (scrolling, see scroll_step) does.
	wait := 1.0 / 240 if ui.monitor.streams.playback != nil else 1.0 / 30
	if ui.redraw_at != {} {
		due := time.duration_seconds(time.tick_diff(time.tick_now(), ui.redraw_at))
		wait = clamp(due, 0.001, wait)
	}
	glfw.WaitEventsTimeout(wait)

	// Without threads nobody else can run the connection, so it
	// gets its turn here, between frames (see net_thread).
	// Touch input arrives as a queue, with one event handled per frame (see ui_touch_web.odin).
	when platform.WEB {
		net_step(ui)
		touch_step(ui)
	}

	if ui.settings_dirty && time.tick_since(ui.settings_saved) > time.Second {
		save_settings(ui)
	}

	// Listen back is only a test on the settings page, so don't leave it running.
	if ui.page != .Settings {
		set_listen_back(ui, false)
	}
	monitor_update(ui)
	app_sound_step(ui)
	sounds_frame(ui)
	session_capture_update(ui)
	app_audio_frame(ui)
	servers_frame(ui)
	// Run before the tray and the taskbar update, so they show what a hotkey just
	// did, and before returning early for a hidden window, since hotkeys work
	// without a window.
	hotkeys_frame(ui)
	tray_update(ui)
	thumbbar_update(ui)
	activity_step(ui)
	status_sync(ui)
	push_frame(ui)
	if ui.hidden {
		ui.meter_shown = false
		return true // there is no window to draw in
	}
	drag_frame(ui)
	if !frame_due(ui) {
		return true
	}
	draw_frame(ui)
	// A browser paces frames itself and a page can't sleep.
	when !platform.WEB {
		if ui.frame_pace > 0 {
			if left := ui.frame_pace - time.tick_since(ui.last_swap); left > 0 {
				time.sleep(left)
			}
			ui.last_swap = time.tick_now()
		}
	}
	return true
}

// draw_frame lays out the UI and draws it. It is the second half of ui_frame
// and everything that refresh_callback does while the window is being resized.
draw_frame :: proc(ui: ^UI) {
	if ui.drawing {
		return
	}
	ui.drawing = true
	defer ui.drawing = false
	if render.gpu_lost(&ui.renderer.gpu) {
		reset_gpu(ui)
	}

	m := window_metrics(ui.window, settings.ui_scale_factor(&ui.settings))
	if m != ui.metrics {
		ww, wh := glfw.GetWindowSize(ui.window)
		log.debugf(
			"ui: window %dx%d, framebuffer %dx%d, scale %.2f, layout %.0fx%.0f",
			ww,
			wh,
			m.fb_w,
			m.fb_h,
			m.scale,
			m.logical_w,
			m.logical_h,
		)
		ui.metrics = m
	}
	ui.input_scale = m.input_scale
	left, right, height := titlebar_area(ui)
	ui.titlebar_left = i32(left * m.input_scale)
	ui.titlebar_right = i32(right * m.input_scale)
	ui.titlebar_height = i32(height * m.input_scale)
	// Whatever asked for this frame has been served now. The layout asks again
	// for whatever still needs more frames (see frame_due).
	ui.redraw_frames = max(ui.redraw_frames - 1, 0)
	ui.redraw_at = {}
	ui.log_drawn = -1
	// microui turns a press into focus for whatever `hover_id` names without
	// checking the pointer again, and only a control itself clears its hover. If
	// a hovered control disappears (because of a screen change or a relabeled
	// button), the stale id could fire on a click anywhere once the id reappears.
	// Recomputing the hover in every frame without a press keeps it tied to what
	// is actually under the pointer.
	if ui.ctx.mouse_pressed_bits == {} && ui.ctx.mouse_down_bits == {} {
		ui.ctx.hover_id = 0
	}
	ui_images_frame(ui)
	clear(&ui.text_boxes)
	// The chat's text size, used for measuring and drawing this frame.
	render.set_chat_zoom(&ui.renderer, settings.chat_scale_factor(&ui.settings))
	activity_input(ui)
	voice_elsewhere_update(ui)
	theme_update(ui) // the palette for this frame (theme.odin)
	style_apply(ui, i32(m.logical_w))
	scroll_step(ui)
	mu.begin(&ui.ctx)
	ui.meter_shown = false // until gate_settings draws it again (it sets this when it draws the meter)
	layout(ui, i32(m.logical_w), i32(m.logical_h))
	nav_frame(ui)
	mu.end(&ui.ctx)
	clock_redraws(ui)
	settle(ui)
	when platform.WEB {
		touch_after_frame(ui)
		fields_after_frame(ui)
	}
	edge := Window_Edge.None
	if ui.ctx.mouse_down_bits == {} {
		edge = window_edge(ui, ui.ctx.mouse_pos.x, ui.ctx.mouse_pos.y)
	}
	switch {
	case edge != .None:
		set_cursor(ui, EDGE_CURSORS[edge])
	case ui.chat.hovering:
		set_cursor(ui, .Hand)
	case ui.select.over_text || ui.select.dragging:
		set_cursor(ui, .IBeam)
	case:
		set_cursor(ui, .Arrow)
	}
	ui.select.over_text = false
	ui_chat_after_frame(ui)
	camera_after_frame(ui)
	ui.keys = {}
	// The window's buttons keep their size at 100%. Only the display's
	// density scales them, not the UI's zoom.
	ui.renderer.control_scale = m.scale / settings.ui_scale_factor(&ui.settings)
	render.render(&ui.renderer, &ui.ctx, m.fb_w, m.fb_h, m.scale, theme.background)
	render.gpu_present(&ui.renderer.gpu)
	// A camera turned off in this frame no longer has its preview drawn.
	video.frame_done()
}

// After input, draw at least this many frames, because microui answers some
// input (a click) in the frame after the one that saw it.
@(private = "file")
SETTLE_FRAMES :: 2

// How often things that move smoothly (a fade, the level meter) are redrawn.
ANIMATION_FRAME :: time.Second / 30

// ui_wake asks for a frame from any thread, for a change that no input
// event reports: from the network side (View.wake) and from threads that
// have finished their work. It wakes the loop if it is waiting.
ui_wake :: proc "c" () {
	if !intrinsics.atomic_exchange(&g_wake, true) {
		glfw.PostEmptyEvent()
	}
}

// ui_redraw asks for frames right now, from the UI's own thread.
ui_redraw :: proc "contextless" (ui: ^UI) {
	ui.redraw_frames = max(ui.redraw_frames, SETTLE_FRAMES)
}

// ui_redraw_at asks for a frame by `at`, for things that change with the clock
// alone. The layout asks again in every frame that still needs it.
ui_redraw_at :: proc(ui: ^UI, at: time.Tick) {
	if ui.redraw_at == {} || time.tick_diff(at, ui.redraw_at) > 0 {
		ui.redraw_at = at
	}
}

ui_redraw_in :: proc(ui: ^UI, after: time.Duration) {
	ui_redraw_at(ui, time.tick_add(time.tick_now(), max(after, 0)))
}

// frame_due says whether the loop should draw a frame in this turn.
@(private = "file")
frame_due :: proc(ui: ^UI) -> bool {
	if intrinsics.atomic_exchange(&g_wake, false) {
		ui_redraw(ui)
	}
	if ui.redraw_frames > 0 {
		return true
	}
	if ui.redraw_at != {} && time.tick_diff(ui.redraw_at, time.tick_now()) >= 0 {
		return true
	}
	// A new size or scale. No callback is needed for this.
	if window_metrics(ui.window, settings.ui_scale_factor(&ui.settings)) != ui.metrics {
		return true
	}
	// Lines are logged from everywhere, far too often to wake for each
	// one, so they are only checked for while the log is on screen.
	if ui.log_drawn >= 0 && ui.opts.logs != nil {
		sync.guard(&ui.opts.logs.mutex)
		return ui.opts.logs.total != ui.log_drawn
	}
	return false
}

// clock_redraws asks for frames for things that change with the clock and are
// shown in too many places to ask from each of them: who is speaking and who is
// typing (which stop by themselves), the network side's notices (which
// disappear after a while), and times shown to the minute.
@(private = "file")
clock_redraws :: proc(ui: ^UI) {
	{
		v := ui.view
		sync.guard(&v.mutex)
		if t := conn.speaking_until(v); t != {} {
			ui_redraw_at(ui, t)
		}
		if t := conn.typing_until(v); t != {} {
			ui_redraw_at(ui, t)
		}
		if t := notice_until(v); t != {} {
			ui_redraw_at(ui, t)
		}
	}
	// Message times, "Today" and "last seen 5 minutes ago" all
	// change on the minute.
	MINUTE :: i64(time.Minute)
	into := time.time_to_unix_nano(time.now()) % MINUTE
	ui_redraw_in(ui, time.Duration(MINUTE - into))
}

// settle asks for another frame when this frame's draw commands differ
// from the previous frame's.
@(private = "file")
settle :: proc(ui: ^UI) {
	list := &ui.ctx.command_list
	h := hash.fnv64a(list.items[:list.idx])
	h = hash.fnv64a(slice.to_bytes(ui.images.draws[:]), h)
	if h != ui.drawn_hash {
		ui.drawn_hash = h
		ui.redraw_frames = max(ui.redraw_frames, 1)
	}
}

// ui_shutdown tears everything down in the reverse order of the startup.
ui_shutdown :: proc(ui: ^UI) {
	disconnect_all(ui)
	delete(ui.sessions)
	delete(ui.relay_server)
	delete(ui.window_title)
	hotkeys_stop(ui)
	tray_hide(ui)
	monitor_stop(ui)
	app_sound_stop(ui)
	sounds_destroy(ui)
	if ui.settings_dirty {
		save_settings(ui)
	}
	ui_images_destroy(ui)
	ui_avatars_destroy(ui)
	conn.image_cache_destroy(&ui.image_cache)
	ui_video_destroy(ui)
	app_audio_destroy(ui)
	ui_memory_destroy(ui)
	delete(ui.text_boxes)
	ui_nav_destroy(ui)
	delete(ui.scrollbar_fades)
	// The paste thread uses the clipboard, so it has to be
	// finished before the clipboard is torn down.
	paste_wait(ui)
	file_pick_wait(ui)
	// What the UI kept for each server went away with its session
	// (see disconnect_all).
	for path in ui.dropped {
		delete(path)
	}
	delete(ui.dropped)
	clipboard.destroy()
	activity_close(ui)
	window_close(ui)
	glfw.Terminate()
	audio.audio_destroy(&ui.audio)
	settings.settings_destroy(&ui.settings)
	known_servers_destroy(ui)
	install_destroy(ui)
	ui_chat_destroy(ui)
	ui_select_destroy(ui)
	conn.view_destroy(ui.view)
}

// The window and everything that lives on its GPU device (an OpenGL
// context, or a Direct3D 11 device on Windows). They come and go
// together, because hiding the client in the tray destroys the window
// entirely (see hide_to_tray). A Wayland surface that has been
// unmapped can't be brought back: the EGL buffers behind it are never
// released, and the next swap waits for them forever.
//
// Nothing above the device lives in here: microui's state, the view,
// the connection and the tray icon all survive across windows.
// set_swap_pace decides what keeps frames at the display's rate.
//
// Usually that is the buffer swap, which waits for the display (vsync). On
// Wayland that wait is for the compositor's go-ahead, which it only gives to a
// window it is showing. If the window is minimized or on another virtual
// desktop, the swap would wait until the window is looked at again, and
// everything else on this thread would wait with it: notifications, the tray
// icon and listen back. So there the swap doesn't wait, and the loop keeps to
// the monitor's refresh rate itself (see frame_pace, at the end of ui_frame).
// Wayland never tears, so nothing is lost.
set_swap_pace :: proc(ui: ^UI) {
	ui.frame_pace = 0
	when !platform.WEB {
		if on_wayland() {
			render.gpu_swap_interval(&ui.renderer.gpu, 0)
			refresh: i32 = 60
			if monitor := glfw.GetPrimaryMonitor(); monitor != nil {
				if mode := glfw.GetVideoMode(monitor); mode != nil && mode.refresh_rate > 0 {
					refresh = mode.refresh_rate
				}
			}
			ui.frame_pace = time.Second / time.Duration(refresh)
			log.debugf("ui: Wayland, so frames are paced here, at %d Hz", refresh)
			return
		}
	}
	render.gpu_swap_interval(&ui.renderer.gpu, 1)
}

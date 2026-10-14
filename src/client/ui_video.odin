package client

import "core:fmt"
import "core:strings"
import "core:time"
import mu "vendor:microui"

import "client:conn"
import "client:platform"
import "client:render"
import "common:proto"

/*
Screen sharing in the UI (see conn/video.odin): the Share button beside mute
and deafen, and the Screen tab beside the chat, which opens by itself on
starting to watch somebody. Both work in a browser, and on the desktop
with the yap_video library (conn/video_native.odin), where the Share
button opens a menu of monitors and windows to share (share_menu), or
where the system asks itself (Wayland's portal, macOS 15), the system's
picker; a browser has its own. Either way, the channel list marks who
is sharing. What's shared is set up in the settings (Screen sharing,
ui_share_settings.odin), held to what the server takes.

The page or the library decodes the picture and hands us the newest
frame as a texture (conn.video_picture), which is drawn like a chat
image. The library wakes the UI for each new one (conn.video_set_wake);
a page draws every frame anyway. Under it, if the settings say so, a
line of figures: size, frame rate, codec, bitrate, loss. Fullscreen in a browser is the browser's, for the whole page; on
the desktop it's the picture filling the window. Either way there's
nothing but the picture while it lasts.
*/

UI_Video :: struct {
	// Whom the tabs were last arranged for (see screen_tab_follow).
	watched:        proto.User_Num,
	// The share menu: to be opened, and what it offers (owned).
	menu_requested: bool,
	sources:        []conn.Video_Source,
	allowed:        bool, // capturing is (macOS asks the user)
	// What the server takes from a sharer (kbit/s, 0 if it didn't say),
	// as share_button last saw it.
	limit_kbit:     int,
	// For the figures: the picture's size, and the frame rate worked
	// out from the decoded count once a second.
	size:           [2]int,
	fps:            f64,
	fps_frames:     u64,
	fps_at:         time.Tick,
	// The bitrate slider's value while it's dragged (ui_share_settings.odin).
	kbit_draft:     f32,
}

// share_config is how to share, from the settings and the server's
// limit.
share_config :: proc(ui: ^UI) -> conn.Share_Config {
	return conn.share_config(&ui.settings, ui.video.limit_kbit)
}

ui_video_destroy :: proc(ui: ^UI) {
	conn.video_forget_gpu(&ui.renderer.gpu)
	free_sources(ui)
	ui.video = {}
}

@(private = "file")
free_sources :: proc(ui: ^UI) {
	for s in ui.video.sources {
		delete(s.name)
		delete(s.app)
	}
	delete(ui.video.sources)
	ui.video.sources = nil
}

// ui_video_forget_texture lets go of the picture's texture as its GPU
// device goes (see ui_images_forget_textures); before it goes, where
// there's a choice.
ui_video_forget_texture :: proc(ui: ^UI) {
	conn.video_forget_gpu(&ui.renderer.gpu)
}

// can_watch_screens says whether we can watch anybody's screen: with
// the add-on (or a browser that decodes), over the media link. Call
// with the View locked.
can_watch_screens :: proc(ui: ^UI) -> bool {
	return conn.video_can_watch() && ui.view.video_link
}

// share_button starts or stops sharing our screen. Only shown where it's
// possible (video_can_share). Call with the View locked.
share_button :: proc(ui: ^UI) {
	ui.video.limit_kbit = ui.view.video_limit_kbit
	system := conn.video_system_picker()
	state := conn.video_share_state()
	if state != .Off {
		// The page may change it (the browser's own Stop sharing), or the
		// library (a shared window closed).
		ui_redraw_in(ui, 250 * time.Millisecond)
	}
	hint := "Share your screen"
	color := mu.Color{}
	switch state {
	case .Live:
		hint, color = "Stop sharing your screen", theme.speaking
		s := ui.view.video_stats
		if s.kbit_out > 0 {
			hint = fmt.tprintf(
				"Stop sharing your screen (%.1f Mbit/s going out)",
				f64(s.kbit_out) / 1000,
			)
		}
		if s.kbit_target > 0 && s.kbit_max > 0 {
			hint = fmt.tprintf(
				"%s; held to %.1f of %.1f Mbit/s, as that's what your viewers' connections take",
				hint,
				f64(s.kbit_target) / 1000,
				f64(s.kbit_max) / 1000,
			)
		}
		if s.left_out > 0 {
			hint = fmt.tprintf("%s (one viewer is too far behind to go by)", hint)
		}
	case .Starting:
		hint, color = "Starting to share...", theme.dim
		if !conn.VIDEO_PICKER || system {
			hint = "Choosing what to share (in the system's picker)..."
		}
	case .Failed:
		why := conn.video_share_error()
		if why == "" {
			why = "the browser's console says why"
		}
		hint = fmt.tprintf("Sharing didn't work (%s); try again", why)
		color = theme.off
	case .Off:
	}
	if .SUBMIT in icon_button(ui, "share", .Screen, hint, color) {
		if state == .Live || state == .Starting {
			conn.video_share_stop()
		} else if system {
			// Its picker is all there is to ask.
			conn.video_share_source({}, share_config(ui))
		} else if conn.VIDEO_PICKER {
			ui.video.menu_requested = true
		} else {
			// Straight from the click: the browser only opens its
			// picker for something the user just did.
			conn.video_share_start()
		}
	}
}

@(private = "file")
SHARE_MENU :: "share menu"
@(private = "file")
SHARE_MENU_WIDTH :: 320

/*
share_menu is what the desktop shares, while it's open: the monitors,
then the windows, as the library finds them when it opens. Picking one
starts sharing it (in place of anything shared before).
*/
share_menu :: proc(ui: ^UI) {
	when !conn.VIDEO_PICKER {
		return
	}
	ctx := &ui.ctx
	vid := &ui.video
	if vid.menu_requested {
		vid.menu_requested = false
		free_sources(ui)
		vid.allowed = conn.video_capture_allowed()
		vid.sources = conn.video_sources(context.allocator)
		mu.open_popup(ctx, SHARE_MENU)
	}
	if cnt := mu.get_container(ctx, SHARE_MENU, {.CLOSED}); cnt != nil && cnt.open {
		w, h := i32(ui.metrics.logical_w), i32(ui.metrics.logical_h)
		cnt.rect.x = clamp(cnt.rect.x, 0, max(w - cnt.rect.w, 0))
		cnt.rect.y = clamp(cnt.rect.y, 0, max(h - cnt.rect.h, 0))
	}
	if !mu.begin_popup(ctx, SHARE_MENU) {
		return
	}
	defer mu.end_popup(ctx)

	if !vid.allowed {
		allow_capture(ui)
		return
	}
	mu.layout_row(ctx, {SHARE_MENU_WIDTH})
	with_text_color(ctx, theme.dim, "Share a monitor:", label_proc)
	picked := -1
	windows := 0
	for s, i in vid.sources {
		if s.kind != .Monitor {
			windows += 1
			continue
		}
		mu.push_id(ctx, uintptr(i))
		mu.layout_row(ctx, {SHARE_MENU_WIDTH})
		label := fmt.tprintf(
			"%s, %dx%d%s",
			s.name,
			s.width,
			s.height,
			" (main)" if s.primary else "",
		)
		if .SUBMIT in stable_button(ctx, "source", label) {
			picked = i
		}
		mu.pop_id(ctx)
	}
	if windows > 0 {
		mu.layout_row(ctx, {SHARE_MENU_WIDTH})
		with_text_color(ctx, theme.dim, "Or a window:", label_proc)
	}
	for s, i in vid.sources {
		if s.kind != .Window {
			continue
		}
		mu.push_id(ctx, uintptr(i))
		mu.layout_row(ctx, {SHARE_MENU_WIDTH})
		if .SUBMIT in stable_button(ctx, "source", s.name) {
			picked = i
		}
		mu.pop_id(ctx)
	}
	mu.layout_row(ctx, {SHARE_MENU_WIDTH})
	if .SUBMIT in stable_button(ctx, "refresh", "Refresh") {
		vid.menu_requested = true
	}
	if picked >= 0 {
		conn.video_share_source(vid.sources[picked], share_config(ui))
		mu.get_current_container(ctx).open = false
	}
}

// allow_capture is the share menu while macOS doesn't let us capture.
@(private = "file")
allow_capture :: proc(ui: ^UI) {
	ctx := &ui.ctx
	mu.layout_row(ctx, {SHARE_MENU_WIDTH})
	with_text_color(
		ctx,
		theme.dim,
		"To share, allow yap to record the screen (System Settings, Privacy & Security, " +
		"Screen Recording), then start yap again.",
		mu.text,
	)
	mu.layout_row(ctx, {SHARE_MENU_WIDTH})
	if .SUBMIT in stable_button(ctx, "allow", "Allow screen recording") {
		conn.video_allow_capture()
	}
	mu.layout_row(ctx, {SHARE_MENU_WIDTH})
	if .SUBMIT in stable_button(ctx, "refresh", "Check again") {
		ui.video.menu_requested = true
	}
}

// watch starts watching `user`, or stops with 0.
watch :: proc(ui: ^UI, user: proto.User_Num) {
	if ui.session != nil {
		conn.push_command(&ui.session.client.commands, conn.Watch_Command{user})
	}
}

/*
screen_tab_follow opens the Screen tab on starting to watch somebody,
and goes back to the chat (and out of fullscreen) on stopping. Call with
the View locked.
*/
screen_tab_follow :: proc(ui: ^UI) {
	watching := ui.view.watching
	if watching == ui.video.watched {
		return
	}
	ui.video.watched = watching
	if watching != 0 {
		ui.chat.tab = .Screen
	} else {
		if ui.chat.tab == .Screen {
			ui.chat.tab = .Chat
		}
		conn.video_set_fullscreen(false)
	}
}

// watched_name is who we're watching, for a title.
@(private = "file")
watched_name :: proc(ui: ^UI) -> string {
	if u, ok := ui.view.users[ui.view.watching]; ok {
		return u.name
	}
	return "somebody"
}

// screen_panel fills the Screen tab. Call with the View locked.
screen_panel :: proc(ui: ^UI) {
	ctx := &ui.ctx
	mu.layout_row(ctx, {-(2 * ICON_BUTTON + 2 * ctx.style.spacing), ICON_BUTTON, ICON_BUTTON})
	mu.label(ctx, fmt.tprintf("%s's screen", watched_name(ui)))
	if .SUBMIT in icon_button(ui, "fullscreen", .Fullscreen, "Fullscreen") {
		conn.video_set_fullscreen(true)
	}
	if .SUBMIT in icon_button(ui, "stop watching", .Screen_Off, "Stop watching") {
		watch(ui, 0)
	}
	figures := ui.settings.share_stats
	if figures {
		mu.layout_row(ctx, {-1}, -(ctx.style.size.y + ctx.style.spacing))
	} else {
		mu.layout_row(ctx, {-1}, -1)
	}
	picture(ui, mu.layout_next(ctx))
	if figures {
		mu.layout_row(ctx, {-1})
		figures_line(ui)
	}
}

/*
figures_line says how what we watch is doing: its size and frame rate,
codec and bitrate, how it's decoded, and what got lost on the way (and
how much of it asking again saved). Call with the View locked.
*/
@(private = "file")
figures_line :: proc(ui: ^UI) {
	ctx := &ui.ctx
	vid := &ui.video
	s := ui.view.video_stats
	frames, hardware := conn.video_picture_info()
	// The frame rate, from how many were decoded in the last second.
	if now := time.tick_now(); vid.fps_at == {} || frames < vid.fps_frames {
		vid.fps_at, vid.fps_frames = now, frames
	} else if since := time.tick_diff(vid.fps_at, now); since >= time.Second {
		vid.fps = f64(frames - vid.fps_frames) / time.duration_seconds(since)
		vid.fps_at, vid.fps_frames = now, frames
	}
	ui_redraw_in(ui, time.Second)

	b := strings.builder_make(context.temp_allocator)
	if vid.size.x > 0 {
		fmt.sbprintf(&b, "%dx%d", vid.size.x, vid.size.y)
	}
	when !platform.WEB {
		fmt.sbprintf(&b, ", %.0f fps", vid.fps)
	}
	codec := [proto.Video_Codec]string {
		.H264 = "H.264",
		.HEVC = "HEVC",
		.AV1  = "AV1",
	}
	fmt.sbprintf(&b, ", %s, %.1f Mbit/s", codec[s.codec], f64(s.kbit_in) / 1000)
	switch {
	case platform.WEB:
		strings.write_string(&b, ", decoded by the browser")
	case hardware:
		strings.write_string(&b, ", decoded by the GPU")
	case:
		strings.write_string(&b, ", decoded by the CPU")
	}
	color := theme.dim
	if s.asked > 0 || s.lost > 0 {
		fmt.sbprintf(&b, "; %d fragments asked for again, %d frames saved", s.asked, s.saved)
		if s.lost > 0 {
			fmt.sbprintf(&b, ", %d lost: more than your connection takes", s.lost)
			color = theme.warning
		}
	}
	with_text_color(ctx, color, strings.to_string(b), label_proc)
}

/*
fullscreen_screen is all there is while the page (or on the desktop, the
picture) is fullscreen: the picture, and a way back. Call with the View
locked.
*/
fullscreen_screen :: proc(ui: ^UI) {
	ctx := &ui.ctx
	title_row(ui, {-(ICON_BUTTON + ctx.style.spacing), ICON_BUTTON})
	with_text_color(
		ctx,
		theme.dim,
		fmt.tprintf("%s's screen (Escape leaves fullscreen)", watched_name(ui)),
		label_proc,
	)
	if .SUBMIT in icon_button(ui, "exit fullscreen", .Exit_Fullscreen, "Leave fullscreen") ||
	   .Escape in ui.keys {
		ui.keys -= {.Escape}
		conn.video_set_fullscreen(false)
	}
	mu.layout_row(ctx, {-1}, -1)
	picture(ui, mu.layout_next(ctx))
}

// picture draws the newest frame as big as fits in `r`, on black.
@(private = "file")
picture :: proc(ui: ^UI, r: mu.Rect) {
	ctx := &ui.ctx
	texture, pw, ph, have := conn.video_picture(&ui.renderer.gpu)
	if have {
		ui.video.size = {pw, ph}
	}
	// The library wakes us for each new picture (conn.video_set_wake);
	// a page has to look every frame.
	when platform.WEB {
		ui_redraw_at(ui, time.tick_now())
	}

	mu.draw_rect(ctx, r, {0, 0, 0, 255})
	if !have || r.w <= 0 || r.h <= 0 {
		waiting := "Waiting for the picture..."
		tw := ctx.text_width(ctx.style.font, waiting)
		th := ctx.text_height(ctx.style.font)
		mu.draw_text(
			ctx,
			ctx.style.font,
			waiting,
			{r.x + (r.w - tw) / 2, r.y + (r.h - th) / 2},
			theme.dim,
		)
		return
	}
	// As big as fits, keeping its shape, in the middle.
	scale := min(f32(r.w) / f32(pw), f32(r.h) / f32(ph))
	w, h := i32(f32(pw) * scale), i32(f32(ph) * scale)
	fitted := mu.Rect{r.x + (r.w - w) / 2, r.y + (r.h - h) / 2, w, h}
	im := &ui.images
	append(&im.draws, render.Image_Draw{texture = texture})
	mu.draw_icon(
		ctx,
		mu.Icon(render.IMAGE_ICON_BASE + len(im.draws) - 1),
		fitted,
		{255, 255, 255, 255},
	)
}

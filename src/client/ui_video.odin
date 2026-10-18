package client

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import mu "vendor:microui"

import "client:conn"
import "client:platform"
import "client:render"
import "common:proto"

// Screen sharing in the UI (see conn/video.odin): the Share button beside mute
// and deafen, and the Screen tab beside the chat, which opens by itself when we
// start watching somebody. Both work in a browser, and on the desktop with the
// yap_video library (conn/video_native.odin). On the desktop, the Share button
// opens a menu of monitors and windows to share (share_menu), or, where the
// system asks by itself (Wayland's portal, macOS 15), the system's picker is
// used. Where a playback device's audio can go along (ui_app_audio_native.odin),
// the menu asks for that first, and with the system's picker the menu
// then has only that and a button to open the picker. A browser has its own picker. Either way, the channel list marks who is
// sharing. The Screen tab's picture can be popped out into a window of its own
// (screen_window), which floats over every page and stays while another server
// is shown. What is shared is set up in the settings (Screen sharing,
// ui_share_settings.odin), limited to what the server accepts.
//
// The page or the library decodes the picture and hands us the newest frame as
// a texture (conn.video_picture), which is drawn like a chat image. The library
// wakes the UI for each new frame (conn.video_set_wake), while a page draws
// every frame anyway. Under the picture, if the settings say so, there is a
// line of figures: size, frame rate, codec, bitrate and loss. Fullscreen in a
// browser is the browser's, for the whole page, and on the desktop the picture
// fills the window. Either way, nothing but the picture is shown while it
// lasts.

UI_Video :: struct {
	// Whom the tabs were last arranged for (see screen_tab_follow).
	watched:        proto.User_Num,
	// Whether the picture is in its own window (screen_window) instead of the
	// Screen tab, for whoever is watched, until it is put back.
	popped:         bool,
	window_placed:  bool, // whether it has been given a position yet
	window_shown:   bool, // whether it was drawn in the last frame
	// Whom its close button stopped watching. It is kept closed until the
	// network side has heard (the View still lists them meanwhile).
	window_closed:  proto.User_Num,
	// The share menu: whether it is to be opened, and what it offers (owned).
	menu_requested: bool,
	sources:        []conn.Video_Source,
	allowed:        bool, // whether capturing is allowed (macOS asks the user)
	// What the server accepts from a sharer (kbit/s, 0 if it didn't say), as
	// share_button last saw it.
	limit_kbit:     int,
	// For the figures: the picture's size, and the frame rate worked out from
	// the decoded count once a second.
	size:           [2]int,
	fps:            f64,
	fps_frames:     u64,
	fps_at:         time.Tick,
	// The bitrate slider's value while it is being dragged (ui_share_settings.odin).
	kbit_draft:     f32,
}

// share_config is how to share, from the settings and the server's limit.
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

// ui_video_forget_texture releases the picture's texture as its GPU device goes
// (see ui_images_forget_textures), before that happens where there is a choice.
ui_video_forget_texture :: proc(ui: ^UI) {
	conn.video_forget_gpu(&ui.renderer.gpu)
}

// can_watch_screens says whether we can watch anybody's screen: that needs the
// add-on (or a browser that decodes) and the media link. Call with the View
// locked.
can_watch_screens :: proc(ui: ^UI) -> bool {
	return conn.video_can_watch() && ui.view.video_link
}

// share_button starts or stops sharing our screen. It is only shown where
// sharing is possible (video_can_share). Call with the View locked.
share_button :: proc(ui: ^UI) {
	ui.video.limit_kbit = ui.view.video_limit_kbit
	system := conn.video_system_picker()
	state := conn.video_share_state()
	if state != .Off {
		// The page may change it (the browser's own Stop sharing), or the
		// library may (a shared window was closed).
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
				"%s; limited to %.1f of %.1f Mbit/s, because that is all your viewers' connections can take",
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
		} else if system && !app_audio_available(ui) {
			// Its picker is all there is to ask.
			conn.video_share_source({}, share_config(ui))
		} else if conn.VIDEO_PICKER {
			ui.video.menu_requested = true
		} else {
			// Straight from the click: the browser only opens its picker for
			// something the user just did.
			conn.video_share_start(share_config(ui))
		}
	}
}

@(private = "file")
SHARE_MENU :: "share menu"
@(private = "file")
SHARE_MENU_WIDTH :: 320

// share_menu is what the desktop shares, while it is open: the audio that
// goes along, then the monitors and the windows, as the library finds them
// when it opens. Picking one starts sharing it (in place of anything shared
// before). Where the system has its own picker, a button opens that instead
// of the monitors and windows.
share_menu :: proc(ui: ^UI) {
	when !conn.VIDEO_PICKER {
		return
	}
	ctx := &ui.ctx
	vid := &ui.video
	system := conn.video_system_picker()
	if vid.menu_requested {
		vid.menu_requested = false
		free_sources(ui)
		vid.allowed = conn.video_capture_allowed()
		if !system {
			vid.sources = conn.video_sources(context.allocator)
		}
		share_audio_refresh(ui)
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
	share_audio_choice(ui, SHARE_MENU_WIDTH)
	if system {
		mu.layout_row(ctx, {SHARE_MENU_WIDTH})
		if .SUBMIT in stable_button(ctx, "pick", "Choose a screen or window...") {
			conn.video_share_source({}, share_config(ui))
			share_audio_start(ui)
			mu.get_current_container(ctx).open = false
		}
		return
	}
	mu.layout_row(ctx, {SHARE_MENU_WIDTH})
	with_text_color(ctx, theme.dim, "Share a monitor:", label_proc)
	picked := -1
	windows := 0
	for s in vid.sources {
		if s.kind != .Monitor {
			windows += 1
		}
	}
	// The monitors and windows scroll beyond a certain size (menu_list_begin).
	rows := len(vid.sources) + (1 if windows > 0 else 0)
	menu_list_begin(ui, "sources", SHARE_MENU_WIDTH, rows)
	for s, i in vid.sources {
		if s.kind != .Monitor {
			continue
		}
		mu.push_id(ctx, uintptr(i))
		mu.layout_row(ctx, {-1})
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
		mu.layout_row(ctx, {-1})
		with_text_color(ctx, theme.dim, "Or a window:", label_proc)
	}
	for s, i in vid.sources {
		if s.kind != .Window {
			continue
		}
		mu.push_id(ctx, uintptr(i))
		mu.layout_row(ctx, {-1})
		if .SUBMIT in stable_button(ctx, "source", s.name) {
			picked = i
		}
		mu.pop_id(ctx)
	}
	mu.end_panel(ctx)
	mu.layout_row(ctx, {SHARE_MENU_WIDTH})
	if .SUBMIT in stable_button(ctx, "refresh", "Refresh") {
		vid.menu_requested = true
	}
	if picked >= 0 {
		conn.video_share_source(vid.sources[picked], share_config(ui))
		share_audio_start(ui)
		mu.get_current_container(ctx).open = false
	}
}

// allow_capture is the share menu while macOS doesn't allow us to capture.
@(private = "file")
allow_capture :: proc(ui: ^UI) {
	ctx := &ui.ctx
	mu.layout_row(ctx, {SHARE_MENU_WIDTH})
	with_text_color(
		ctx,
		theme.dim,
		"To share, allow yap to record the screen (System Settings, Privacy & Security, " +
		"Screen Recording), then restart yap.",
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

// watch starts watching `user`, or stops watching with 0.
watch :: proc(ui: ^UI, user: proto.User_Num) {
	if ui.session != nil {
		conn.push_command(&ui.session.client.commands, conn.Watch_Command{user})
	}
}

// screen_tab_follow opens the Screen tab when we start watching somebody, and
// goes back to the chat (and out of fullscreen) when we stop. Call with the
// View locked.
screen_tab_follow :: proc(ui: ^UI) {
	watching := ui.view.watching
	// The tab has nothing to show when the picture is in its own window, or
	// when nobody is watched (a stashed server's tab, shown again).
	if ui.chat.tab == .Screen && (watching == 0 || ui.video.popped) {
		ui.chat.tab = .Chat
	}
	if watching == ui.video.watched {
		return
	}
	ui.video.watched = watching
	if watching != 0 {
		if !ui.video.popped {
			ui.chat.tab = .Screen
		}
	} else {
		if ui.chat.tab == .Screen {
			ui.chat.tab = .Chat
		}
		conn.video_set_fullscreen(false)
	}
}

// screen_docked says whether the Screen tab is offered beside the chat: while
// watching somebody, unless the picture is popped out. Call with the View
// locked.
screen_docked :: proc(ui: ^UI) -> bool {
	return ui.view.watching != 0 && !ui.video.popped
}

// watched_name is who `v` is watching, for a title.
@(private = "file")
watched_name :: proc(v: ^conn.View) -> string {
	if u, ok := v.users[v.watching]; ok {
		return u.name
	}
	return "somebody"
}

// screen_panel fills the Screen tab. Call with the View locked.
screen_panel :: proc(ui: ^UI) {
	ctx := &ui.ctx
	mu.layout_row(
		ctx,
		// -1 fills the row: -n leaves n - 1 for the buttons and the gaps
		// before them.
		{-(3 * ICON_BUTTON + 3 * ctx.style.spacing + 1), ICON_BUTTON, ICON_BUTTON, ICON_BUTTON},
	)
	mu.label(ctx, fmt.tprintf("%s's screen", watched_name(ui.view)))
	if .SUBMIT in icon_button(ui, "pop out", .Pop_Out, "Pop out into its own window") {
		ui.video.popped = true
		ui.chat.tab = .Chat
	}
	if .SUBMIT in icon_button(ui, "fullscreen", .Fullscreen, "Fullscreen") {
		conn.video_set_fullscreen(true)
	}
	if .SUBMIT in icon_button(ui, "stop watching", .Screen_Off, "Stop watching") {
		watch(ui, 0)
	}
	picture_and_figures(ui, ui.view)
}

// picture_and_figures fills the rest of the panel or window with the picture,
// and the figures under it if the settings say so. Call with `v` locked.
@(private = "file")
picture_and_figures :: proc(ui: ^UI, v: ^conn.View) {
	ctx := &ui.ctx
	figures := ui.settings.share_stats
	if figures {
		// Room for the figures' row, which is a label's height (its text and
		// padding) after the gap. -1 would fill it all.
		label_h := ctx.style.size.y + 2 * ctx.style.padding
		mu.layout_row(ctx, {-1}, -(label_h + ctx.style.spacing + 1))
	} else {
		mu.layout_row(ctx, {-1}, -1)
	}
	picture(ui, mu.layout_next(ctx))
	if figures {
		mu.layout_row(ctx, {-1})
		figures_line(ui, v)
	}
}

@(private = "file")
SCREEN_WINDOW :: "Screen"

// screen_window is the picture popped out of the Screen tab: a window of its
// own over every page, at first in the bottom right-hand corner. It shows what
// the server that our voice is in is watching (watching needs us to be in the
// sharer's room), so it stays while another server is shown (see
// show_session). Fullscreen and putting it back are offered while that server
// is the one shown, and its close button stops watching. Call with no View
// locked.
screen_window :: proc(ui: ^UI, window_w, window_h: i32) {
	vid := &ui.video
	ns := ui.voice_at
	if !vid.popped || ns == nil {
		vid.window_shown = false
		return
	}
	v := &ns.view
	sync.guard(&v.mutex)
	if v.watching != vid.window_closed {
		vid.window_closed = 0
	}
	shown_here := ns == ui.session && ui.page != .Settings
	// In fullscreen, the picture fills the window (session_screen).
	if v.watching == 0 ||
	   v.watching == vid.window_closed ||
	   (shown_here && conn.video_is_fullscreen()) {
		vid.window_shown = false
		return
	}
	ctx := &ui.ctx
	if !vid.window_shown {
		if cnt := mu.get_container(ctx, SCREEN_WINDOW); cnt != nil {
			if !vid.window_placed {
				vid.window_placed = true
				w := clamp(window_w / 3, 320, 640)
				h :=
					w * 9 / 16 +
					2 * (ctx.style.size.y + 2 * ctx.style.padding) +
					3 * ctx.style.spacing
				if ui.settings.share_stats {
					h += ctx.style.size.y + 2 * ctx.style.padding + ctx.style.spacing
				}
				cnt.rect = {window_w - w - 20, window_h - h - 20, w, h}
			}
			cnt.open = true
			mu.bring_to_front(ctx, cnt)
		}
	}
	vid.window_shown = true
	if !mu.begin_window(ctx, SCREEN_WINDOW, {}, {.NO_SCROLL}) {
		// Closed with the title bar's button.
		vid.window_shown = false
		vid.window_closed = v.watching
		conn.push_command(&ns.client.commands, conn.Watch_Command{user = 0})
		return
	}
	defer mu.end_window(ctx)

	// No fullscreen over the settings, and neither button for a server that
	// is not shown.
	buttons: i32 = 0
	if ns == ui.session {
		buttons = 2 if shown_here else 1
	}
	widths := [3]i32{-(buttons * (ICON_BUTTON + ctx.style.spacing) + 1), ICON_BUTTON, ICON_BUTTON}
	mu.layout_row(ctx, widths[:buttons + 1])
	mu.label(ctx, fmt.tprintf("%s's screen", watched_name(v)))
	if shown_here && .SUBMIT in icon_button(ui, "popped fullscreen", .Fullscreen, "Fullscreen") {
		conn.video_set_fullscreen(true)
	}
	if ns == ui.session &&
	   .SUBMIT in icon_button(ui, "pop in", .Pop_In, "Put back beside the chat") {
		vid.popped = false
		ui.chat.tab = .Screen
	}
	picture_and_figures(ui, v)
}

// figures_line says how what we watch is doing: its size and frame rate, codec
// and bitrate, how it is decoded, and what got lost on the way (and how much of
// that was saved by asking again). Call with the View locked.
@(private = "file")
figures_line :: proc(ui: ^UI, v: ^conn.View) {
	ctx := &ui.ctx
	vid := &ui.video
	s := v.video_stats
	frames, hardware := conn.video_picture_info()
	// The frame rate, from how many frames were decoded in the last second.
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

// fullscreen_screen is all there is while the page (or, on the desktop, the
// picture) is fullscreen: the picture and a way back. Call with the View
// locked.
fullscreen_screen :: proc(ui: ^UI) {
	ctx := &ui.ctx
	title_row(ui, {-(ICON_BUTTON + ctx.style.spacing + 1), ICON_BUTTON})
	with_text_color(
		ctx,
		theme.dim,
		fmt.tprintf("%s's screen (Escape leaves fullscreen)", watched_name(ui.view)),
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
	// The library wakes us for each new picture (conn.video_set_wake), while
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

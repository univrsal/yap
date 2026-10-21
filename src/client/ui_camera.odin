package client

import "core:fmt"
import "core:slice"
import "core:sync"
import "core:time"
import mu "vendor:microui"

import "client:conn"
import "client:platform"
import "client:render"
import "common:proto"

// Cameras in the UI (see conn/video.odin, misc/video-chat): the Camera button
// beside Share, and the Video tab beside the chat.
//
// In a call, the tab shows the person we call large and our own camera small
// in a corner (click it to swap them), and it opens by itself when their
// camera comes on. In a channel's voice chat it is "Video (N)", offered while
// anybody there has their camera on but never opened by itself: a grid of every
// camera in the room, ours included, with names, and an outline round whoever
// is talking. A click on a tile makes it large, with the others in a row under
// it; another click goes back to the grid. Either can be made fullscreen or
// popped out into a window of its own (camera_window), which stays while
// another server is shown.
//
// A camera is only watched while one of its tiles is drawn: drawing a tile
// notes it and its size (note_drawn), and after the frame the list goes to the
// network if it changed (camera_after_frame). The size, in pixels, lets the
// sharer send no bigger than the largest tile anyone shows it in (conn's
// Demand).
//
// A call can be started or answered with the camera on ("Video call",
// "Answer with video"); otherwise the camera is off until its button is
// pressed, and it goes off again when we leave the voice chat or call it was
// turned on in, move to another room, or the server doesn't take it (a full
// channel). Cameras work in a browser, and on the desktop once the library
// captures them.

UI_Camera :: struct {
	// Where our camera was turned on: its session and room (camera_follow).
	at:           ^Net_Session,
	room:         proto.Room,
	// A call started or answered with video, on `call_at`: the camera comes
	// on once it is on. `call_seen` is set once that call has been seen at
	// all, so its end can be told from it not having begun yet.
	on_call:      bool,
	call_at:      ^Net_Session,
	call_seen:    bool,
	// Whose camera the tabs were last arranged for in a call.
	followed:     proto.User_Num,
	// The call's tab shows us large; the grid shows one tile large (0: none).
	swapped:      bool,
	focus:        proto.User_Num,
	// The grid or the call fills the window, or is in a window of its own
	// (camera_window, placed once).
	full:         bool,
	popped:       bool,
	placed:       bool,
	window_shown: bool, // drawn in the last frame
	// The cameras drawn this frame, and what was last asked of which session
	// (camera_after_frame).
	drawn:        [proto.MAX_CAMERAS]proto.User_Num,
	drawn_at:     [proto.MAX_CAMERAS][2]int, // each one's largest tile, in pixels
	drawn_n:      int,
	sent:         [proto.MAX_CAMERAS]proto.User_Num,
	sent_at:      [proto.MAX_CAMERAS][2]int,
	sent_n:       int,
	sent_to:      ^Net_Session,
	// The settings' preview was shown this frame (camera_settings); it is let
	// go of after a frame without it (camera_after_frame).
	looked:       bool,
}

// camera_available says whether our camera can be turned on with this server:
// the platform has a camera to offer and the server allows cameras. Call with
// the View locked.
camera_available :: proc(v: ^conn.View) -> bool {
	return conn.video_can_camera() && v.max_cameras > 0
}

// room_cameras is how many cameras are on in our room, other than ours. Call
// with the View locked.
@(private = "file")
room_cameras :: proc(v: ^conn.View) -> (n: int) {
	room := proto.Room(v.my_room)
	if room == 0 {
		return
	}
	for num, u in v.users {
		if num != v.my_num && proto.Room(u.room) == room && u.camera {
			n += 1
		}
	}
	return
}

// camera_start turns our camera on for the voice chat or call that `ns` is in,
// with `v` (its View) locked, at the room's tier (conn.camera_config): the
// camera and quality the settings say.
@(private = "file")
camera_start :: proc(ui: ^UI, ns: ^Net_Session, v: ^conn.View) {
	room := proto.Room(v.my_room)
	cfg := conn.camera_config(
		room_cameras(v) + 1,
		proto.room_call(room) != 0,
		v.camera_limit_kbit,
		conn.camera_quality(ui.settings.camera_quality),
	)
	conn.video_camera_start(cfg, ui.settings.camera_device)
	ui.camera.at = ns
	ui.camera.room = room
}

// camera_on_call has the camera come on once the call that is being started or
// answered on the shown server is on.
camera_on_call :: proc(ui: ^UI) {
	ui.camera.on_call, ui.camera.call_at, ui.camera.call_seen = true, ui.session, false
}

// camera_button turns our camera on or off. It is only shown where cameras are
// possible (camera_available). Call with the View locked.
camera_button :: proc(ui: ^UI) {
	state := conn.video_camera_state()
	if state != .Off {
		// The page may change it (the browser's own prompt, a camera that is
		// unplugged).
		ui_redraw_in(ui, 250 * time.Millisecond)
	}
	hint := "Turn your camera on"
	color := mu.Color{}
	icon := render.Icon.Camera
	switch state {
	case .Live:
		hint, color = "Turn your camera off", theme.speaking
	case .Starting:
		hint, color = "Turning your camera on...", theme.dim
	case .Failed:
		hint = "Your camera didn't start (it isn't allowed, or another program has it); try again"
		if why := conn.video_camera_error(); why != "" {
			hint = fmt.tprintf("Your camera didn't start: %s. Try again", why)
		}
		color, icon = theme.off, .Camera_Off
	case .Off:
	}
	if .SUBMIT in icon_button(ui, "camera", icon, hint, color) {
		if state == .Live || state == .Starting {
			conn.video_camera_stop()
		} else {
			// Straight from the click: a browser only asks about the camera
			// for something the user just did.
			camera_start(ui, ui.session, ui.view)
		}
	}
}

// camera_follow keeps our camera to the voice chat or call it was turned on in:
// it goes off when we leave that or move to another room, and when the server
// doesn't take it (conn has said why). It also turns the camera on once a call
// started or answered with video is on. Call with no View locked.
camera_follow :: proc(ui: ^UI) {
	cam := &ui.camera
	// The network thread keeps a camera that is on to it (follow_camera_tier).
	conn.video_set_camera_quality(conn.camera_quality(ui.settings.camera_quality))
	if cam.on_call {
		follow_video_call(ui)
	}
	state := conn.video_camera_state()
	if state == .Off || state == .Failed {
		return
	}
	ns := ui.voice_at
	stop := ns == nil || ns != cam.at
	if !stop {
		sync.guard(&ns.view.mutex)
		stop =
			proto.Room(ns.view.my_room) != cam.room || (state == .Live && ns.view.camera_refused)
	}
	if stop {
		conn.video_camera_stop()
	}
}

// follow_video_call turns the camera on once the call it was asked for with is
// on, or forgets about it once that call is over (or has gone elsewhere).
@(private = "file")
follow_video_call :: proc(ui: ^UI) {
	cam := &ui.camera
	ns := cam.call_at
	if !session_alive(ui, ns) {
		cam.on_call = false
		return
	}
	sync.guard(&ns.view.mutex)
	v := &ns.view
	switch {
	case v.call.status == .None:
		if cam.call_seen {
			cam.on_call = false
		}
	case v.call.status == .Active &&
	     v.call.here &&
	     proto.room_call(proto.Room(v.my_room)) != 0 &&
	     ui.voice_at == ns:
		cam.on_call = false
		if camera_available(v) && conn.video_camera_state() == .Off {
			camera_start(ui, ns, v)
		}
	case:
		cam.call_seen = true
	}
}

@(private = "file")
session_alive :: proc(ui: ^UI, ns: ^Net_Session) -> bool {
	if ns == nil {
		return false
	}
	for s in ui.sessions {
		if s == ns {
			return true
		}
	}
	return false
}

// call_camera is the user of the person we are in a call with on this server,
// while their camera is on; 0 otherwise. Call with the View locked.
@(private = "file")
call_camera :: proc(v: ^conn.View) -> proto.User_Num {
	if !in_call(v) {
		return 0
	}
	num, peer := call_peer(v)
	return num if peer.camera else 0
}

@(private = "file")
in_call :: proc(v: ^conn.View) -> bool {
	return v.call.status == .Active && v.call.here
}

// our_camera_on says whether our camera is on (or coming on).
@(private = "file")
our_camera_on :: proc() -> bool {
	state := conn.video_camera_state()
	return state == .Live || state == .Starting
}

// has_video says whether there is a call's video or a grid to show for `v`: in
// a call while their camera or ours is on, or in a channel's voice chat while
// anybody's is. Call with the View locked.
@(private = "file")
has_video :: proc(v: ^conn.View) -> bool {
	if in_call(v) {
		return call_camera(v) != 0 || our_camera_on()
	}
	room := proto.Room(v.my_room)
	if room == 0 || proto.room_call(room) != 0 {
		return false
	}
	return room_cameras(v) > 0 || our_camera_on()
}

// video_docked says whether the Video tab is offered beside the chat: there is
// video to show (has_video), and it isn't popped out. Call with the View
// locked.
video_docked :: proc(ui: ^UI) -> bool {
	return has_video(ui.view) && !(ui.camera.popped && ui.session == ui.voice_at)
}

// video_tab_label is the Video tab's name: in a channel, with how many cameras
// are on. Call with the View locked.
video_tab_label :: proc(ui: ^UI) -> string {
	v := ui.view
	if in_call(v) {
		return "Video"
	}
	return fmt.tprintf("Video (%d)", room_cameras(v) + (1 if our_camera_on() else 0))
}

// camera_tab_follow opens the Video tab when the person we call turns their
// camera on, and goes back to the chat when there is nothing left to show (or
// it was popped out). Fullscreen ends with the video. Call with the View
// locked.
camera_tab_follow :: proc(ui: ^UI) {
	cam := &ui.camera
	if ui.chat.tab == .Video && !video_docked(ui) {
		ui.chat.tab = .Chat
	}
	if cam.full && (!conn.video_is_fullscreen() || !has_video(ui.view)) {
		cam.full = false
		conn.video_set_fullscreen(false)
	}
	shown := call_camera(ui.view)
	if shown != cam.followed {
		cam.followed = shown
		if shown != 0 && ui.chat.tab == .Chat && video_docked(ui) {
			ui.chat.tab = .Video
		}
	}
}

// camera_fullscreen says whether the video fills the window now, in place of
// everything else (camera_full_screen). Call with the View locked.
camera_fullscreen :: proc(ui: ^UI) -> bool {
	return ui.camera.full && conn.video_is_fullscreen() && has_video(ui.view)
}

// The step tile sizes are rounded up to, so that a few pixels either way
// aren't news.
@(private = "file")
TILE_STEP :: 16

// note_drawn has a camera that a tile `r` shows watched (camera_after_frame),
// at the largest size it is drawn at this frame.
@(private = "file")
note_drawn :: proc(ui: ^UI, user: proto.User_Num, r: mu.Rect) {
	cam := &ui.camera
	if user == 0 {
		return
	}
	// In the framebuffer's pixels, which is what the picture is drawn in.
	scale := ui.metrics.scale if ui.metrics.scale > 0 else 1
	size := [2]int {
		(int(f32(r.w) * scale) + TILE_STEP - 1) / TILE_STEP * TILE_STEP,
		(int(f32(r.h) * scale) + TILE_STEP - 1) / TILE_STEP * TILE_STEP,
	}
	if i, found := slice.linear_search(cam.drawn[:cam.drawn_n], user); found {
		cam.drawn_at[i] = {max(cam.drawn_at[i].x, size.x), max(cam.drawn_at[i].y, size.y)}
		return
	}
	if cam.drawn_n == len(cam.drawn) {
		return
	}
	cam.drawn[cam.drawn_n] = user
	cam.drawn_at[cam.drawn_n] = size
	cam.drawn_n += 1
}

// camera_after_frame has the voice's server watch the cameras that the frame
// drew, and no others, when that list changed. A camera is only ever drawn for
// the room our voice is in. Call with no View locked.
camera_after_frame :: proc(ui: ^UI) {
	cam := &ui.camera
	n := cam.drawn_n
	drawn, sizes := cam.drawn[:n], cam.drawn_at[:n]
	// In the order of their users, with their sizes.
	for i in 1 ..< n {
		for j := i; j > 0 && drawn[j] < drawn[j - 1]; j -= 1 {
			drawn[j], drawn[j - 1] = drawn[j - 1], drawn[j]
			sizes[j], sizes[j - 1] = sizes[j - 1], sizes[j]
		}
	}
	ns := ui.voice_at
	if ns != cam.sent_to ||
	   !slice.equal(drawn, cam.sent[:cam.sent_n]) ||
	   !slice.equal(sizes, cam.sent_at[:cam.sent_n]) {
		if cam.sent_to != ns && cam.sent_n > 0 && session_alive(ui, cam.sent_to) {
			conn.push_command(&cam.sent_to.client.commands, conn.watch_cameras())
		}
		if ns != nil {
			cmd := conn.watch_cameras(..drawn)
			copy(cmd.tiles[:], sizes)
			conn.push_command(&ns.client.commands, cmd)
		}
		cam.sent_to = ns
		cam.sent_n = copy(cam.sent[:], drawn)
		copy(cam.sent_at[:], sizes)
	}
	cam.drawn_n = 0
	if !cam.looked {
		conn.video_camera_look_stop()
	}
	cam.looked = false
}

// camera_switch has our camera, if it is on, go on with the camera the
// settings now say. Call with no View locked.
camera_switch :: proc(ui: ^UI) {
	cam := &ui.camera
	state := conn.video_camera_state()
	if state == .Off || state == .Failed || !session_alive(ui, cam.at) {
		return
	}
	conn.video_camera_stop()
	sync.guard(&cam.at.view.mutex)
	camera_start(ui, cam.at, &cam.at.view)
}

// video_panel fills the Video tab: the call's video or the room's grid, with
// buttons to pop it out and to make it fullscreen. Call with the View locked.
video_panel :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := ui.view
	cam := &ui.camera
	mu.layout_row(ctx, {-(2 * icon_button_w(ctx) + 2 * ctx.style.spacing + 1), icon_button_w(ctx), icon_button_w(ctx)})
	mu.label(ctx, video_title(v))
	if .SUBMIT in icon_button(ui, "video pop out", .Pop_Out, "Pop out into its own window") {
		cam.popped = true
		ui.chat.tab = .Chat
	}
	if .SUBMIT in icon_button(ui, "video fullscreen", .Fullscreen, "Fullscreen") {
		cam.full = true
		conn.video_set_fullscreen(true)
	}
	mu.layout_row(ctx, {-1}, -1)
	video_body(ui, v, mu.layout_next(ctx))
}

@(private = "file")
video_title :: proc(v: ^conn.View) -> string {
	if in_call(v) {
		return fmt.tprintf("Video call with %s", call_peer_name(v))
	}
	return "Cameras"
}

// camera_full_screen is all there is while the video is fullscreen: the call
// or the grid, and a way back. Call with the View locked.
camera_full_screen :: proc(ui: ^UI) {
	ctx := &ui.ctx
	title_row(ui, {-(icon_button_w(ctx) + ctx.style.spacing + 1), icon_button_w(ctx)})
	with_text_color(
		ctx,
		theme.dim,
		fmt.tprintf("%s (Escape leaves fullscreen)", video_title(ui.view)),
		label_proc,
	)
	if .SUBMIT in icon_button(ui, "video exit fullscreen", .Exit_Fullscreen, "Leave fullscreen") ||
	   .Escape in ui.keys {
		ui.keys -= {.Escape}
		ui.camera.full = false
		conn.video_set_fullscreen(false)
	}
	mu.layout_row(ctx, {-1}, -1)
	video_body(ui, ui.view, mu.layout_next(ctx))
}

@(private = "file")
CAMERA_WINDOW :: "Cameras"

// camera_window is the Video tab popped out: a window of its own over every
// page, at first in the bottom left-hand corner. It shows the room our voice
// is in, so it stays while another server is shown. Putting it back and
// fullscreen are offered while that server is the one shown; closing it
// stops watching. Call with no View locked.
camera_window :: proc(ui: ^UI, window_w, window_h: i32) {
	cam := &ui.camera
	ns := ui.voice_at
	if !cam.popped || ns == nil {
		cam.window_shown = false
		return
	}
	v := &ns.view
	sync.guard(&v.mutex)
	shown_here := ns == ui.session && ui.page != .Settings
	if !has_video(v) || (shown_here && camera_fullscreen(ui)) {
		cam.window_shown = false
		return
	}
	ctx := &ui.ctx
	if !cam.window_shown {
		if cnt := mu.get_container(ctx, CAMERA_WINDOW); cnt != nil {
			if !cam.placed {
				cam.placed = true
				w := clamp(window_w / 3, 320, 640)
				h :=
					w * 9 / 16 +
					2 * (ctx.style.size.y + 2 * ctx.style.padding) +
					3 * ctx.style.spacing
				cnt.rect = {20, window_h - h - 20, w, h}
			}
			cnt.open = true
			mu.bring_to_front(ctx, cnt)
		}
	}
	cam.window_shown = true
	if !mu.begin_window(ctx, CAMERA_WINDOW, {}, {.NO_SCROLL}) {
		// Closed with the title bar's button.
		cam.window_shown, cam.popped = false, false
		return
	}
	defer mu.end_window(ctx)

	buttons: i32 = 0
	if ns == ui.session {
		buttons = 2 if shown_here else 1
	}
	widths := [3]i32{-(buttons * (icon_button_w(ctx) + ctx.style.spacing) + 1), icon_button_w(ctx), icon_button_w(ctx)}
	mu.layout_row(ctx, widths[:buttons + 1])
	mu.label(ctx, video_title(v))
	if shown_here &&
	   .SUBMIT in icon_button(ui, "popped video fullscreen", .Fullscreen, "Fullscreen") {
		cam.full = true
		conn.video_set_fullscreen(true)
	}
	if ns == ui.session &&
	   .SUBMIT in icon_button(ui, "video pop in", .Pop_In, "Put back beside the chat") {
		cam.popped = false
		ui.chat.tab = .Video
	}
	mu.layout_row(ctx, {-1}, -1)
	video_body(ui, v, mu.layout_next(ctx))
}

// video_body draws the call's video or the room's grid of `v` in `r`.
@(private = "file")
video_body :: proc(ui: ^UI, v: ^conn.View, r: mu.Rect) {
	mu.draw_rect(&ui.ctx, r, {0, 0, 0, 255})
	// A page draws its pictures every frame (the library wakes us instead).
	when platform.WEB {
		ui_redraw_at(ui, time.tick_now())
	}
	if in_call(v) {
		call_video(ui, v, r)
	} else {
		camera_grid(ui, v, r)
	}
}

// The self view's share of the call's width, and its gap from the corner.
@(private = "file")
SELF_VIEW_PART :: 4
@(private = "file")
SELF_VIEW_GAP :: 8

// call_video is the person we call, large, and our own camera in the bottom
// right-hand corner, mirrored like a mirror unless the settings say not to (they
// see it the right way round either way).
// Clicking the corner swaps them.
@(private = "file")
call_video :: proc(ui: ^UI, v: ^conn.View, r: mu.Rect) {
	ctx := &ui.ctx
	cam := &ui.camera
	them := call_camera(v)
	ours := conn.video_camera_state() == .Live
	if them == 0 || !ours {
		cam.swapped = false
	}
	big_self := ours && (them == 0 || cam.swapped)
	if big_self {
		self_view(ui, r)
	} else {
		peer_view(ui, r, them, fmt.tprintf("%s's camera is off", call_peer_name(v)))
	}
	if !(ours && them != 0) {
		return
	}
	// The other one, small, in the corner; a click swaps them.
	w := max(r.w / SELF_VIEW_PART, 80)
	h := w * 9 / 16
	small := mu.Rect{r.x + r.w - w - SELF_VIEW_GAP, r.y + r.h - h - SELF_VIEW_GAP, w, h}
	id := mu.get_id(ctx, "video corner")
	mu.update_control(ctx, id, small)
	if ctx.hover_id == id {
		ui.hint, ui.hint_of = "Swap the pictures", small
		if .LEFT in ctx.mouse_pressed_bits {
			cam.swapped = !cam.swapped
		}
	}
	mu.draw_rect(ctx, small, {30, 30, 30, 255})
	if big_self {
		peer_view(ui, small, them, "")
	} else {
		self_view(ui, small)
	}
	mu.draw_box(ctx, mu.expand_rect(small, 1), ctx.style.colors[.BORDER])
}

// A camera in the grid: whose (ours: self), what to call it, and whether they
// are talking.
@(private = "file")
Tile :: struct {
	user:     proto.User_Num,
	self:     bool,
	name:     string,
	speaking: bool,
}

// The gap between tiles, the part of the height the row under a large tile
// takes, and what a tile's shape is kept to.
@(private = "file")
TILE_GAP :: 6
@(private = "file")
TILE_ROW_PART :: 5

// camera_grid is every camera in our room as tiles of 16:9, ours last, in as
// many columns as makes them largest. With a tile made large (focus), it is on
// top and the others are in a row under it.
@(private = "file")
camera_grid :: proc(ui: ^UI, v: ^conn.View, r: mu.Rect) {
	cam := &ui.camera
	tiles := make([dynamic]Tile, context.temp_allocator)
	room := proto.Room(v.my_room)
	for num, u in v.users {
		if num != v.my_num && proto.Room(u.room) == room && u.camera {
			append(&tiles, Tile{user = num, name = u.name, speaking = conn.is_speaking(v, num)})
		}
	}
	slice.sort_by(tiles[:], proc(a, b: Tile) -> bool {return a.user < b.user})
	if conn.video_camera_state() == .Live {
		append(
			&tiles,
			Tile {
				user = v.my_num,
				self = true,
				name = "You",
				speaking = conn.is_speaking(v, v.my_num),
			},
		)
	}
	if len(tiles) == 0 {
		centred_text(ui, r, "Nobody's camera is on")
		return
	}
	focused := -1
	for t, i in tiles {
		if t.user == cam.focus {
			focused = i
		}
	}
	if focused < 0 || len(tiles) == 1 {
		cam.focus = 0
		rects := grid_rects(r, len(tiles), r.h)
		for t, i in tiles {
			tile(ui, rects[i], t, false)
		}
		return
	}
	row_h := max(r.h / TILE_ROW_PART, 40)
	big := mu.Rect{r.x, r.y, r.w, r.h - row_h - TILE_GAP}
	tile(ui, big, tiles[focused], true)
	others := make([dynamic]Tile, context.temp_allocator)
	for t, i in tiles {
		if i != focused {
			append(&others, t)
		}
	}
	row := mu.Rect{r.x, r.y + r.h - row_h, r.w, row_h}
	rects := grid_rects(row, len(others), row_h)
	for t, i in others {
		tile(ui, rects[i], t, false)
	}
}

// grid_rects lays out `n` tiles of 16:9 in `r`, in the number of columns that
// makes them largest, no taller than `max_h`, the whole block in the middle.
// Allocated in the temp allocator.
@(private = "file")
grid_rects :: proc(r: mu.Rect, n: int, max_h: i32) -> []mu.Rect {
	best_w, best_cols: i32 = 0, 1
	for cols in 1 ..= i32(n) {
		rows := (i32(n) + cols - 1) / cols
		cell_w := (r.w - TILE_GAP * (cols - 1)) / cols
		cell_h := min((r.h - TILE_GAP * (rows - 1)) / rows, max_h)
		w := min(cell_w, cell_h * 16 / 9)
		if w > best_w {
			best_w, best_cols = w, cols
		}
	}
	cols := best_cols
	rows := (i32(n) + cols - 1) / cols
	w, h := best_w, best_w * 9 / 16
	block_w := cols * w + (cols - 1) * TILE_GAP
	block_h := rows * h + (rows - 1) * TILE_GAP
	x0, y0 := r.x + (r.w - block_w) / 2, r.y + (r.h - block_h) / 2
	out := make([]mu.Rect, n, context.temp_allocator)
	for i in 0 ..< n {
		row, col := i32(i) / cols, i32(i) % cols
		// The last row, if it isn't full, in the middle too.
		in_row := min(cols, i32(n) - row * cols)
		x := x0 + (cols - in_row) * (w + TILE_GAP) / 2
		out[i] = {x + col * (w + TILE_GAP), y0 + row * (h + TILE_GAP), w, h}
	}
	return out
}

// tile draws one camera of the grid: its picture, the name on a dark band at
// the bottom, and an outline while they talk. A click makes it large, or back.
@(private = "file")
tile :: proc(ui: ^UI, r: mu.Rect, t: Tile, large: bool) {
	ctx := &ui.ctx
	if r.w <= 0 || r.h <= 0 {
		return
	}
	mu.draw_rect(ctx, r, {24, 24, 24, 255})
	if t.self {
		self_view(ui, r)
	} else {
		peer_view(ui, r, t.user, "")
	}
	mu.push_id(ctx, uintptr(t.user))
	id := mu.get_id(ctx, "tile")
	mu.pop_id(ctx)
	mu.update_control(ctx, id, r)
	if ctx.hover_id == id {
		ui.hint, ui.hint_of = "Back to all cameras" if large else "Make larger", r
		if .LEFT in ctx.mouse_pressed_bits {
			ui.camera.focus = 0 if large else t.user
		}
	}
	// The name, on a band across the bottom.
	th := ctx.text_height(ctx.style.font)
	band := mu.Rect{r.x, r.y + r.h - th - 6, r.w, th + 6}
	mu.draw_rect(ctx, band, {0, 0, 0, 150})
	mu.push_clip_rect(ctx, r)
	mu.draw_text(ctx, ctx.style.font, t.name, {band.x + 6, band.y + 3}, {255, 255, 255, 255})
	mu.pop_clip_rect(ctx)
	if t.speaking {
		mu.draw_box(ctx, r, theme.speaking)
		mu.draw_box(ctx, mu.expand_rect(r, -1), theme.speaking)
	}
}

// peer_view draws `user`'s camera as big as fits in `r`, or `off` (if any)
// while there is none.
@(private = "file")
peer_view :: proc(ui: ^UI, r: mu.Rect, user: proto.User_Num, off: string) {
	if user == 0 {
		centred_text(ui, r, off)
		return
	}
	note_drawn(ui, user, r)
	texture, w, h, ok := conn.video_picture(&ui.renderer.gpu, {user, .Camera})
	if !ok {
		centred_text(ui, r, "Waiting for the picture...")
		return
	}
	fitted_picture(ui, r, texture, w, h, false)
}

// self_view draws our own camera as big as fits in `r`, mirrored unless the
// settings say not to; `none` where there is no picture yet.
self_view :: proc(ui: ^UI, r: mu.Rect, none := "Your camera") {
	texture, w, h, ok := conn.video_camera_preview(&ui.renderer.gpu)
	if !ok {
		centred_text(ui, r, none)
		return
	}
	fitted_picture(ui, r, texture, w, h, ui.settings.camera_mirror)
}

@(private = "file")
centred_text :: proc(ui: ^UI, r: mu.Rect, text: string) {
	ctx := &ui.ctx
	if text == "" {
		return
	}
	tw := ctx.text_width(ctx.style.font, text)
	th := ctx.text_height(ctx.style.font)
	mu.push_clip_rect(ctx, r)
	defer mu.pop_clip_rect(ctx)
	mu.draw_text(
		ctx,
		ctx.style.font,
		text,
		{r.x + (r.w - tw) / 2, r.y + (r.h - th) / 2},
		theme.dim,
	)
}

// fitted_picture draws a picture as big as fits in `r`, keeping its shape, in
// the middle; `mirror` flips it left to right.
@(private = "file")
fitted_picture :: proc(
	ui: ^UI,
	r: mu.Rect,
	texture: render.Gpu_Texture,
	pw, ph: int,
	mirror: bool,
) {
	if r.w <= 0 || r.h <= 0 || pw <= 0 || ph <= 0 {
		return
	}
	scale := min(f32(r.w) / f32(pw), f32(r.h) / f32(ph))
	w, h := i32(f32(pw) * scale), i32(f32(ph) * scale)
	fitted := mu.Rect{r.x + (r.w - w) / 2, r.y + (r.h - h) / 2, w, h}
	im := &ui.images
	draw := render.Image_Draw {
		texture = texture,
	}
	if mirror {
		draw.uv = {1, 0, 0, 1}
	}
	append(&im.draws, draw)
	mu.draw_icon(
		&ui.ctx,
		mu.Icon(render.IMAGE_ICON_BASE + len(im.draws) - 1),
		fitted,
		{255, 255, 255, 255},
	)
}

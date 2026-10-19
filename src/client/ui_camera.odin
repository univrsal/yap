package client

import "core:fmt"
import "core:sync"
import "core:time"
import mu "vendor:microui"

import "client:conn"
import "client:platform"
import "client:render"
import "common:proto"

// Cameras in the UI (see conn/video.odin, misc/video-chat): the Camera button
// beside Share, and in a call the Video tab beside the chat, with the person we
// call large and our own camera small in a corner (click it to swap them). The
// tab opens by itself when their camera comes on, and our camera is only
// watched by them while theirs is in the tab. A call can be started or
// answered with the camera on ("Video call", "Answer with video"); otherwise
// the camera is off until its button is pressed, and it goes off again when we
// leave the voice chat or call it was turned on in, move to another room, or
// the server doesn't take it (a full channel). Cameras work in a browser, and
// on the desktop once the library captures them.

UI_Camera :: struct {
	// Where our camera was turned on: its session and room (camera_follow).
	at:         ^Net_Session,
	room:       proto.Room,
	// A call started or answered with video, on `call_at`: the camera comes
	// on once it is on. `call_seen` is set once that call has been seen at
	// all, so its end can be told from it not having begun yet.
	on_call:    bool,
	call_at:    ^Net_Session,
	call_seen:  bool,
	// The Video tab: whose camera the tabs were last arranged for, whose is
	// watched (as last told to the network), and whether it shows us large.
	followed:   proto.User_Num,
	watched:    proto.User_Num,
	swapped:    bool,
}

// camera_available says whether our camera can be turned on with this server:
// the platform has a camera to offer and the server allows cameras. Call with
// the View locked.
camera_available :: proc(v: ^conn.View) -> bool {
	return conn.video_can_camera() && v.max_cameras > 0
}

// camera_start turns our camera on for the voice chat or call that `ns` is in,
// with `v` (its View) locked.
@(private = "file")
camera_start :: proc(ui: ^UI, ns: ^Net_Session, v: ^conn.View) {
	conn.video_camera_start(conn.camera_config(v.camera_limit_kbit))
	ui.camera.at = ns
	ui.camera.room = proto.Room(v.my_room)
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
		stop = proto.Room(ns.view.my_room) != cam.room || (state == .Live && ns.view.camera_refused)
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
	alive := false
	for s in ui.sessions {
		alive = alive || s == ns
	}
	if !alive {
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

// call_camera is the user of the person we are in a call with on this server,
// while their camera is on; 0 otherwise. Call with the View locked.
@(private = "file")
call_camera :: proc(v: ^conn.View) -> proto.User_Num {
	if v.call.status != .Active || !v.call.here {
		return 0
	}
	num, peer := call_peer(v)
	return num if peer.camera else 0
}

// video_docked says whether the Video tab is offered beside the chat: in a
// call on this server while their camera or ours is on. Call with the View
// locked.
video_docked :: proc(ui: ^UI) -> bool {
	v := ui.view
	if v.call.status != .Active || !v.call.here {
		return false
	}
	ours := conn.video_camera_state()
	return call_camera(v) != 0 || ours == .Live || ours == .Starting
}

// camera_tab_follow opens the Video tab when the person we call turns their
// camera on, goes back to the chat when there is nothing left to show, and
// watches their camera while the tab shows it. Call with the View locked.
camera_tab_follow :: proc(ui: ^UI) {
	cam := &ui.camera
	if ui.chat.tab == .Video && !video_docked(ui) {
		ui.chat.tab = .Chat
	}
	shown := call_camera(ui.view)
	if shown != cam.followed {
		cam.followed = shown
		if shown != 0 && ui.chat.tab == .Chat {
			ui.chat.tab = .Video
		}
	}
	want := shown if ui.chat.tab == .Video else 0
	if want != cam.watched && ui.session != nil {
		cam.watched = want
		cmd := conn.watch_cameras(want) if want != 0 else conn.watch_cameras()
		conn.push_command(&ui.session.client.commands, cmd)
	}
}

// camera_forget_session forgets what the tabs did with a server that is no
// longer shown (it has been told to watch no cameras, see show_session).
camera_forget_session :: proc(ui: ^UI) {
	ui.camera.followed, ui.camera.watched = 0, 0
}

// The self view's share of the panel's width, and its gap from the corner.
@(private = "file")
SELF_VIEW_PART :: 4
@(private = "file")
SELF_VIEW_GAP :: 8

// video_panel fills the Video tab: the person we call, large, and our own
// camera in the bottom right-hand corner, mirrored like a mirror (they see it
// the right way round). Clicking the corner swaps them. Call with the View
// locked.
video_panel :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := ui.view
	cam := &ui.camera
	mu.layout_row(ctx, {-1})
	mu.label(ctx, fmt.tprintf("Video call with %s", call_peer_name(v)))
	mu.layout_row(ctx, {-1}, -1)
	r := mu.layout_next(ctx)
	mu.draw_rect(ctx, r, {0, 0, 0, 255})
	// A page draws its pictures every frame (the library wakes us instead).
	when platform.WEB {
		ui_redraw_at(ui, time.tick_now())
	}

	them := call_camera(v)
	ours := conn.video_camera_state() == .Live
	if them == 0 || !ours {
		cam.swapped = false
	}
	big_self := ours && (them == 0 || cam.swapped)
	if big_self {
		self_view(ui, r)
	} else {
		peer_view(ui, r, them, call_peer_name(v))
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
		peer_view(ui, small, them, call_peer_name(v))
	} else {
		self_view(ui, small)
	}
	mu.draw_box(ctx, mu.expand_rect(small, 1), ctx.style.colors[.BORDER])
}

// peer_view draws `user`'s camera as big as fits in `r`.
@(private = "file")
peer_view :: proc(ui: ^UI, r: mu.Rect, user: proto.User_Num, name: string) {
	if user == 0 {
		centred_text(ui, r, fmt.tprintf("%s's camera is off", name))
		return
	}
	texture, w, h, ok := conn.video_picture(&ui.renderer.gpu, {user, .Camera})
	if !ok {
		centred_text(ui, r, "Waiting for the picture...")
		return
	}
	fitted_picture(ui, r, texture, w, h, false)
}

// self_view draws our own camera as big as fits in `r`, mirrored.
@(private = "file")
self_view :: proc(ui: ^UI, r: mu.Rect) {
	texture, w, h, ok := conn.video_camera_preview(&ui.renderer.gpu)
	if !ok {
		centred_text(ui, r, "Your camera")
		return
	}
	fitted_picture(ui, r, texture, w, h, true)
}

@(private = "file")
centred_text :: proc(ui: ^UI, r: mu.Rect, text: string) {
	ctx := &ui.ctx
	tw := ctx.text_width(ctx.style.font, text)
	th := ctx.text_height(ctx.style.font)
	mu.push_clip_rect(ctx, r)
	defer mu.pop_clip_rect(ctx)
	mu.draw_text(ctx, ctx.style.font, text, {r.x + (r.w - tw) / 2, r.y + (r.h - th) / 2}, theme.dim)
}

// fitted_picture draws a picture as big as fits in `r`, keeping its shape, in
// the middle; `mirror` flips it left to right.
@(private = "file")
fitted_picture :: proc(ui: ^UI, r: mu.Rect, texture: render.Gpu_Texture, pw, ph: int, mirror: bool) {
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

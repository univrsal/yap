package client

import "core:fmt"
import mu "vendor:microui"

import "../proto"

/*
Screen sharing in the UI (see video.odin): the Share button beside mute
and deafen, and the Screen tab beside the chat, which opens by itself on
starting to watch somebody. Both only do anything in a browser; a
desktop build still marks who is sharing in the channel list.

The page decodes the picture (web/video.js) and puts the newest frame
into a texture of ours, which is drawn like a chat image. Fullscreen is
the browser's, for the whole page, and while it lasts there's nothing on
the page but the picture.
*/

UI_Video :: struct {
	texture: Gpu_Texture, // 0 until the first frame
	size:    [2]int, // of the picture in `texture`; 0 until there is one
	// Whom the tabs were last arranged for (see screen_tab_follow).
	watched: proto.User_Num,
}

ui_video_destroy :: proc(ui: ^UI) {
	gpu_texture_delete(&ui.renderer.gpu, &ui.video.texture)
	ui.video = {}
}

// ui_video_forget_texture drops the texture as its GPU device goes
// (see ui_images_forget_textures).
ui_video_forget_texture :: proc(ui: ^UI) {
	ui.video.texture, ui.video.size = 0, {}
}

// share_button starts or stops sharing our screen. Only shown where the
// browser can (video_can_share).
share_button :: proc(ui: ^UI) {
	state := video_share_state()
	hint := "Share your screen"
	color := mu.Color{}
	switch state {
	case .Live:
		hint, color = "Stop sharing your screen", SPEAKING_COLOR
	case .Starting:
		hint, color = "Choosing what to share...", DIM_COLOR
	case .Failed:
		hint, color = "Sharing didn't work (the browser's console says why); try again", OFF_COLOR
	case .Off:
	}
	if .SUBMIT in icon_button(ui, "share", .Screen, hint, color) {
		// Straight from the click: the browser only opens its picker
		// for something the user just did.
		if state == .Live || state == .Starting {
			video_share_stop()
		} else {
			video_share_start()
		}
	}
}

// watch starts watching `user`, or stops with 0.
watch :: proc(ui: ^UI, user: proto.User_Num) {
	if ui.session != nil {
		push_command(&ui.session.client.commands, Watch_Command{user})
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
	ui.video.size = {} // not the last one's picture
	if watching != 0 {
		ui.chat.tab = .Screen
	} else {
		if ui.chat.tab == .Screen {
			ui.chat.tab = .Chat
		}
		video_set_fullscreen(false)
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
	mu.layout_row(ctx, {-(110 + 70 + 2 * ctx.style.spacing), 110, 70})
	mu.label(ctx, fmt.tprintf("%s's screen", watched_name(ui)))
	if .SUBMIT in stable_button(ctx, "fullscreen", "Fullscreen") {
		video_set_fullscreen(true)
	}
	if .SUBMIT in stable_button(ctx, "stop watching", "Stop") {
		watch(ui, 0)
	}
	mu.layout_row(ctx, {-1}, -1)
	picture(ui, mu.layout_next(ctx))
}

/*
fullscreen_screen is all there is while the page is fullscreen: the
picture, and a way back. Call with the View locked.
*/
fullscreen_screen :: proc(ui: ^UI) {
	ctx := &ui.ctx
	mu.layout_row(ctx, {-(70 + ctx.style.spacing), 70})
	with_text_color(
		ctx,
		DIM_COLOR,
		fmt.tprintf("%s's screen (Escape leaves fullscreen)", watched_name(ui)),
		label_proc,
	)
	if .SUBMIT in stable_button(ctx, "exit fullscreen", "Exit") {
		video_set_fullscreen(false)
	}
	mu.layout_row(ctx, {-1}, -1)
	picture(ui, mu.layout_next(ctx))
}

// picture draws the newest frame as big as fits in `r`, on black.
@(private = "file")
picture :: proc(ui: ^UI, r: mu.Rect) {
	ctx := &ui.ctx
	vid := &ui.video
	if vid.texture == 0 {
		vid.texture = gpu_texture_make(&ui.renderer.gpu, .Rgba, 0, 0, nil)
	}
	if w, h, ok := video_upload(vid.texture); ok {
		vid.size = {w, h}
	}

	mu.draw_rect(ctx, r, {0, 0, 0, 255})
	if vid.size.x <= 0 || vid.size.y <= 0 || r.w <= 0 || r.h <= 0 {
		waiting := "Waiting for the picture..."
		tw := ctx.text_width(ctx.style.font, waiting)
		th := ctx.text_height(ctx.style.font)
		mu.draw_text(ctx, ctx.style.font, waiting, {r.x + (r.w - tw) / 2, r.y + (r.h - th) / 2}, DIM_COLOR)
		return
	}
	// As big as fits, keeping its shape, in the middle.
	scale := min(f32(r.w) / f32(vid.size.x), f32(r.h) / f32(vid.size.y))
	w, h := i32(f32(vid.size.x) * scale), i32(f32(vid.size.y) * scale)
	fitted := mu.Rect{r.x + (r.w - w) / 2, r.y + (r.h - h) / 2, w, h}
	im := &ui.images
	append(&im.draws, Image_Draw{texture = vid.texture})
	mu.draw_icon(ctx, mu.Icon(IMAGE_ICON_BASE + len(im.draws) - 1), fitted, {255, 255, 255, 255})
}

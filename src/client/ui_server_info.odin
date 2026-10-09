package client

import "core:hash"
import "core:strings"
import "core:sync"
import mu "vendor:microui"

import "client:conn"
import "client:platform"
import "client:render"
import "common:proto"

/*
What a server says about itself, in the UI (conn/server_info.odin is the
network's end of it): its picture on the rail and the login screen,
where its name and description go too; and for its owner, the Server
category of the settings' server tab, to change all three.

The picture is decoded like somebody's (ui_avatars.odin), and rounded
off the same way, under a key of its own made from the server's address
and the picture's id: every server on the rail has one, and their ids
are each server's own.
*/

UI_Server_Info :: struct {
	// The settings' form: the session it was filled in for, the name and
	// description as they're being edited, and whether Apply was pressed
	// (the server's answer is shown then).
	loaded_for: rawptr,
	name_buf:   [proto.MAX_SERVER_NAME]u8,
	name_len:   int,
	about_buf:  [proto.MAX_SERVER_DESCRIPTION]u8,
	about_len:  int,
	about_area: Text_Area,
	asked:      bool,
}

// The keys servers' pictures are decoded under: with AVATAR_KEY, so
// they're rounded off, and this bit, apart from people's.
@(private = "file")
SERVER_ICON_KEY :: u64(1) << 59

/*
server_icon is what draws a server's picture this frame, once it's here
and decoded; `server` is its address. Call with `v` (its View) locked.
*/
server_icon :: proc(ui: ^UI, server: string, v: ^conn.View) -> (mu.Icon, bool) {
	if v.server_icon == 0 || len(v.icon_jpeg) == 0 {
		return {}, false
	}
	im := &ui.images
	which := hash.fnv64a(transmute([]u8)server) ~ u64(v.server_icon)
	key := AVATAR_KEY | SERVER_ICON_KEY | (which & (SERVER_ICON_KEY - 1))
	t, known := im.textures[key]
	if !known {
		enqueue_decode(im, key, v.icon_jpeg)
		return {}, false
	}
	if t.state != .Ready {
		return {}, false
	}
	t.frame = im.frame
	im.textures[key] = t
	append(&im.draws, render.Image_Draw{texture = t.texture})
	return mu.Icon(render.IMAGE_ICON_BASE + len(im.draws) - 1), true
}

/*
picture_picked sends a picture that has been chosen and made ready
(ui_avatar_pick_*.odin) where it was chosen for: as our picture, or as
the server's, which keeps the server's name and description as they
are. Takes the JPEG over.
*/
picture_picked :: proc(ui: ^UI, use: Pick_For, image: conn.Chat_Image) {
	image := image
	if ui.session == nil {
		conn.chat_image_destroy(&image)
		return
	}
	switch use {
	case .Avatar:
		conn.push_command(&ui.session.client.commands, conn.Avatar_Command{image = image})
	case .Server_Icon:
		v := ui.view
		sync.guard(&v.mutex)
		ui.server_info.asked = true
		conn.push_command(
			&ui.session.client.commands,
			conn.Server_Info_Command {
				name = strings.clone(v.server_name),
				description = strings.clone(v.server_about),
				image = image,
			},
		)
	}
}

/*
server_info_settings is the settings' Server category, for the owner:
the server's picture, name and description. The picture is set as soon
as it's chosen, as our own is; the name and description with Apply.
Call with the View locked.
*/
server_info_settings :: proc(ui: ^UI, v: ^conn.View) {
	ctx := &ui.ctx
	s := &ui.server_info
	p := &ui.profiles
	if s.loaded_for != rawptr(ui.session) {
		s.loaded_for = rawptr(ui.session)
		s.name_len = copy(s.name_buf[:], v.server_name)
		s.about_len = copy(s.about_buf[:], v.server_about)
		s.asked = false
	}

	size: i32 = 48
	mu.layout_row(ctx, {FORM_LABEL, size + 8, -1}, size)
	mu.label(ctx, "Picture")
	cell := mu.layout_next(ctx)
	server_picture(
		ui,
		ui.session.server if ui.session != nil else "",
		v,
		{cell.x, cell.y, size, size},
	)
	// The buttons, of the usual height, in the middle of the row.
	mu.layout_begin_column(ctx)
	mu.layout_row(
		ctx,
		{-1},
		max((size - ctx.style.size.y - 2 * ctx.style.padding) / 2 - ctx.style.spacing, 1),
	)
	mu.layout_next(ctx)
	mu.layout_row(ctx, {110, 110, 110})
	uploading := false
	for o in v.outbox {
		uploading ||= o.server
	}
	if .SUBMIT in stable_button(ctx, "icon file", "Choose...", {.ALIGN_CENTER}) {
		avatar_pick_start(ui, false, .Server_Icon)
	}
	// A page can only read the clipboard inside a paste event.
	when !platform.WEB {
		if .SUBMIT in stable_button(ctx, "icon paste", "Paste", {.ALIGN_CENTER}) {
			avatar_pick_start(ui, true, .Server_Icon)
		}
	}
	switch {
	case uploading:
		with_text_color(ctx, theme.dim, "uploading...", label_proc)
	case p.pick != nil && p.pick_for == .Server_Icon:
		with_text_color(ctx, theme.dim, "reading the picture...", label_proc)
	case p.pick_notice != "" && p.pick_for == .Server_Icon:
		with_text_color(ctx, theme.off, p.pick_notice, label_proc)
	case v.server_icon != 0:
		if .SUBMIT in stable_button(ctx, "icon remove", "Remove", {.ALIGN_CENTER}) {
			s.asked = true
			conn.push_command(
				&ui.session.client.commands,
				conn.Server_Info_Command {
					name = strings.clone(v.server_name),
					description = strings.clone(v.server_about),
					remove = true,
				},
			)
		}
	case:
		mu.label(ctx, "")
	}
	mu.layout_end_column(ctx)

	mu.layout_row(ctx, {FORM_LABEL, FORM_FIELD})
	mu.label(ctx, "Name")
	submitted := .SUBMIT in text_box(ui, s.name_buf[:], &s.name_len)

	// What it's for, over several lines (Shift+Enter starts a new one).
	about := string(s.about_buf[:s.about_len])
	font := ctx.style.font
	mu.layout_row(ctx, {FORM_LABEL, -1}, text_area_height(ctx, font, about, &s.about_area))
	mu.label(ctx, "Description")
	submitted |= .SUBMIT in text_area(ui, s.about_buf[:], &s.about_len, &s.about_area)

	mu.layout_row(ctx, {FORM_LABEL, 110, 110, -1})
	mu.label(ctx, "")
	if .SUBMIT in stable_button(ctx, "apply", "Apply", {.ALIGN_CENTER}) || submitted {
		ui.account.mistake = ""
		s.asked = true
		conn.push_command(
			&ui.session.client.commands,
			conn.Server_Info_Command {
				name = strings.clone(string(s.name_buf[:s.name_len])),
				description = strings.clone(string(s.about_buf[:s.about_len])),
			},
		)
	}
	if .SUBMIT in stable_button(ctx, "revert", "Revert", {.ALIGN_CENTER}) {
		s.name_len = copy(s.name_buf[:], v.server_name)
		s.about_len = copy(s.about_buf[:], v.server_about)
	}
	if s.asked {
		notice_label(ui, v)
	} else {
		with_text_color(
			ctx,
			theme.dim,
			"Shown on everyone's rail, and before logging in.",
			label_proc,
		)
	}
}

/*
server_picture draws a server's picture in `r` (a square), or until it
has one, its disc with its initials. `server` is its address. Call with
`v` (its View) locked.
*/
server_picture :: proc(ui: ^UI, server: string, v: ^conn.View, r: mu.Rect) {
	ctx := &ui.ctx
	if icon, ok := server_icon(ui, server, v); ok {
		mu.draw_icon(ctx, icon, r, {255, 255, 255, 255})
		return
	}
	disc(ui, r, server_color(server))
	font := ctx.style.font
	initials := server_initials(v.server_name if v.server_name != "" else server)
	w := ctx.text_width(font, initials)
	mu.draw_text(
		ctx,
		font,
		initials,
		{r.x + (r.w - w) / 2, r.y + (r.h - ctx.text_height(font)) / 2},
		{255, 255, 255, 255},
	)
}

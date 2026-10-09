package client

import "core:math"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import mu "vendor:microui"

import "client:clipboard"
import "client:conn"
import "client:render"
import "common:proto"

/*
People's pictures, drawn round: a picture is decoded like a message's
(ui_images.odin) under a key of its own, and its corners made
transparent before it becomes a texture (round_off). Somebody without one
gets a disc in a colour of their own (from their account's id) with the
first letter of their name.

A picture is fetched the first time it's to be drawn (conn's
Avatar_Want_Command), once per session.
*/

// The key a picture is decoded and kept under: its blob's id with this
// bit set, apart from the same blob shown as a message's picture.
AVATAR_KEY :: u64(1) << 61

// How big the disc's own texture is, in pixels; it's scaled to the size
// drawn.
@(private = "file")
DISC_SIDE :: 128

UI_Avatars :: struct {
	disc:      render.Gpu_Texture, // a white disc, made on first use
	have:      bool,
	ring:      render.Gpu_Texture, // a white ring, the same
	have_ring: bool,
	// The pictures asked for, and for which session.
	asked:     map[proto.Blob_Id]bool,
	session:   rawptr,
}

ui_avatars_destroy :: proc(ui: ^UI) {
	delete(ui.avatars.asked)
	ui.avatars = {}
}

// ui_avatars_forget_textures: the GPU device is going (as for images).
ui_avatars_forget_textures :: proc(ui: ^UI) {
	ui.avatars.have = false
	ui.avatars.disc = {}
	ui.avatars.have_ring = false
	ui.avatars.ring = {}
}

/*
avatar draws an account's picture in `r` (a square). Call with the View
locked.
*/
avatar :: proc(ui: ^UI, account: proto.Account_Id, r: mu.Rect) {
	picture(ui, account, r)
	// Online, away, busy or offline (ui_activity.odin); a deleted account
	// is none of them.
	if acc, known := ui.view.accounts[account]; !known || .Deleted not_in acc.flags {
		activity_dot(ui, account, r)
	}
}

// picture draws an account's picture, or its disc and letter.
@(private = "file")
picture :: proc(ui: ^UI, account: proto.Account_Id, r: mu.Rect) {
	ctx := &ui.ctx
	v := ui.view
	acc, known := v.accounts[account]
	if known && acc.avatar != 0 {
		if icon, ok := avatar_icon(ui, acc.avatar); ok {
			mu.draw_icon(ctx, icon, r, {255, 255, 255, 255})
			return
		}
	}
	// A disc and a letter; a plain grey disc for a deleted account.
	deleted := known && .Deleted in acc.flags
	color := theme.deleted_disc if deleted else avatar_color(account)
	disc_letter(ui, r, color, acc.display if known && !deleted else "")
}

/*
letter_disc draws an account's disc and letter, from its name, without
looking it up in the View: for one on a server that isn't shown, whose
picture isn't to be had.
*/
letter_disc :: proc(ui: ^UI, account: proto.Account_Id, name: string, r: mu.Rect) {
	disc_letter(ui, r, avatar_color(account), name)
}

// disc_letter draws a disc of `color` in `r`, with the first letter of
// `name` on it if there's room.
@(private = "file")
disc_letter :: proc(ui: ^UI, r: mu.Rect, color: mu.Color, name: string) {
	ctx := &ui.ctx
	if icon, ok := disc_icon(ui); ok {
		mu.draw_icon(ctx, icon, r, color)
	} else {
		mu.draw_rect(ctx, r, color)
	}
	font := ctx.style.font
	// Smaller than a line of text, a letter wouldn't fit.
	if name == "" || r.h < ctx.text_height(font) {
		return
	}
	first, size := utf8.decode_rune_in_string(name)
	if size == 0 || first == utf8.RUNE_ERROR {
		return
	}
	letter := utf8.runes_to_string({unicode.to_upper(first)}, context.temp_allocator)
	w := ctx.text_width(font, letter)
	mu.draw_text(
		ctx,
		font,
		letter,
		{r.x + (r.w - w) / 2, r.y + (r.h - ctx.text_height(font)) / 2},
		{255, 255, 255, 255},
	)
}

// avatar_color is an account's own colour: a hue from its id, not too
// bright for white on it.
avatar_color :: proc(account: proto.Account_Id) -> mu.Color {
	// Spread neighbouring ids around the circle (the golden angle).
	hue := math.mod(f32(account) * 137.508, 360)
	s, l: f32 = 0.45, 0.42
	c := (1 - abs(2 * l - 1)) * s
	x := c * (1 - abs(math.mod(hue / 60, 2) - 1))
	m := l - c / 2
	rgb: [3]f32
	switch {
	case hue < 60:
		rgb = {c, x, 0}
	case hue < 120:
		rgb = {x, c, 0}
	case hue < 180:
		rgb = {0, c, x}
	case hue < 240:
		rgb = {0, x, c}
	case hue < 300:
		rgb = {x, 0, c}
	case:
		rgb = {c, 0, x}
	}
	return {u8((rgb[0] + m) * 255), u8((rgb[1] + m) * 255), u8((rgb[2] + m) * 255), 255}
}

// avatar_icon is what draws a picture this frame, once it's here and
// decoded; it's asked for the first time it's wanted.
@(private = "file")
avatar_icon :: proc(ui: ^UI, blob: proto.Blob_Id) -> (mu.Icon, bool) {
	v := ui.view
	im := &ui.images
	key := AVATAR_KEY | u64(blob)
	t, known := im.textures[key]
	if !known {
		img, here := v.blobs[blob]
		switch {
		case here && img.state == .Ready && len(img.jpeg) > 0:
			enqueue_decode(im, key, img.jpeg)
		case !here && ui.session != nil:
			a := &ui.avatars
			if a.session != rawptr(ui.session) {
				clear(&a.asked)
				a.session = rawptr(ui.session)
			}
			if !a.asked[blob] {
				a.asked[blob] = true
				conn.push_command(
					&ui.session.client.commands,
					conn.Avatar_Want_Command{blob = blob},
				)
			}
		}
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

// disc_icon is what draws the white disc this frame, tinted.
@(private = "file")
disc_icon :: proc(ui: ^UI) -> (mu.Icon, bool) {
	a := &ui.avatars
	im := &ui.images
	if !a.have {
		pixels := make([]u8, DISC_SIDE * DISC_SIDE * 4, context.temp_allocator)
		for &p in pixels {
			p = 255
		}
		disc := clipboard.Image {
			width  = DISC_SIDE,
			height = DISC_SIDE,
			pixels = pixels,
		}
		round_off(&disc)
		a.disc = render.gpu_texture_make(
			&ui.renderer.gpu,
			.Rgba,
			DISC_SIDE,
			DISC_SIDE,
			pixels,
			mipmaps = true,
		)
		a.have = true
	}
	append(&im.draws, render.Image_Draw{texture = a.disc})
	return mu.Icon(render.IMAGE_ICON_BASE + len(im.draws) - 1), true
}

// How wide the ring round a picture is (avatar_ringed), in logical
// pixels, and the gap between it and the picture.
@(private = "file")
RING_WIDTH :: 2
@(private = "file")
RING_GAP :: 1
// What a ring takes on each side of a picture.
RING_SPACE :: RING_WIDTH + RING_GAP

/*
avatar_ringed draws an account's picture in `slot` (a square) with room
for a ring round it, and with `ring`, the ring, of `color`: who is
talking. The picture is drawn inset by the ring's width and gap whether
the ring is there or not, so nothing moves when it comes and goes, and
the ring stays inside the slot, clear of what's next to it.
*/
avatar_ringed :: proc(
	ui: ^UI,
	account: proto.Account_Id,
	slot: mu.Rect,
	ring: bool,
	color := theme.speaking,
) {
	ctx := &ui.ctx
	a := &ui.avatars
	im := &ui.images
	inset := i32(RING_SPACE)
	if ring {
		if !a.have_ring {
			// The ring's width as a share of the texture, for a slot round a
			// picture a little taller than a line (as the voice panel's); it
			// scales with the slot.
			pixels := make([]u8, DISC_SIDE * DISC_SIDE * 4, context.temp_allocator)
			side := f32(DISC_SIDE)
			radius := side / 2
			width := side * RING_WIDTH / f32(ctx.text_height(ctx.style.font) + 6 + 2 * RING_SPACE)
			for y in 0 ..< DISC_SIDE {
				for x in 0 ..< DISC_SIDE {
					d := math.sqrt(
						math.pow(f32(x) + 0.5 - radius, 2) + math.pow(f32(y) + 0.5 - radius, 2),
					)
					cover :=
						clamp(radius - d + 0.5, 0, 1) * clamp(d - (radius - width) + 0.5, 0, 1)
					p := pixels[(y * DISC_SIDE + x) * 4:]
					p[0], p[1], p[2], p[3] = 255, 255, 255, u8(cover * 255)
				}
			}
			a.ring = render.gpu_texture_make(
				&ui.renderer.gpu,
				.Rgba,
				DISC_SIDE,
				DISC_SIDE,
				pixels,
				mipmaps = true,
			)
			a.have_ring = true
		}
		append(&im.draws, render.Image_Draw{texture = a.ring})
		mu.draw_icon(ctx, mu.Icon(render.IMAGE_ICON_BASE + len(im.draws) - 1), slot, color)
	}
	avatar(ui, account, {slot.x + inset, slot.y + inset, slot.w - 2 * inset, slot.h - 2 * inset})
}

// disc draws a round dot of `color` in `r`.
disc :: proc(ui: ^UI, r: mu.Rect, color: mu.Color) {
	if icon, ok := disc_icon(ui); ok {
		mu.draw_icon(&ui.ctx, icon, r, color)
	} else {
		mu.draw_rect(&ui.ctx, r, color)
	}
}

// round_off makes what's outside the circle that fits an image
// transparent, with a pixel of soft edge.
round_off :: proc(img: ^clipboard.Image) {
	w, h := f32(img.width), f32(img.height)
	cx, cy, radius := w / 2, h / 2, min(w, h) / 2
	for y in 0 ..< img.height {
		for x in 0 ..< img.width {
			d := math.sqrt(math.pow(f32(x) + 0.5 - cx, 2) + math.pow(f32(y) + 0.5 - cy, 2))
			cover := clamp(radius - d + 0.5, 0, 1)
			if cover >= 1 {
				continue
			}
			p := img.pixels[(y * img.width + x) * 4:]
			p[3] = u8(f32(p[3]) * cover)
		}
	}
}

// status_line is how an account's status reads in a list: dimmed, after
// its name. "" for none.
status_line :: proc(acc: conn.View_Account) -> string {
	return strings.trim_space(acc.status)
}

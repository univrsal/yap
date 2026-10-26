package client

import mu "vendor:microui"

import "client:conn"
import "client:render"
import "common:proto"

// Moving someone to another voice room by dragging them there in the channel
// list, for those who may (Move_Members). A left press on a person who is in
// a channel's room here starts it (member_row); until the pointer has moved
// DRAG_START it is only a click, and the person's menu opens on the release
// instead of on the press. While they are dragged, their name follows the
// pointer, and the channel under it is marked if they may be moved there
// (channel_rows): one whose room we may talk in ourselves (D5), and not
// theirs. Dropping them there asks the server to move them (Voice_Move_Command,
// which checks it all again); dropping them anywhere else, or Escape, does
// nothing. Not on a touch screen, where a drag scrolls the list: there the
// menu's Move to... does it.

Voice_Drag :: struct {
	// The connection that was pressed on (0 when nothing is), its account,
	// and the room it was in then.
	num:      proto.User_Num,
	account:  proto.Account_Id,
	room:     proto.Room,
	// Where the press was, and whether it has become a drag.
	from:     mu.Vec2,
	dragging: bool,
	// The channel under the pointer that takes them, as of this frame
	// (channel_rows sets it).
	target:   proto.Conv_Id,
}

@(private = "file")
DRAG_WINDOW :: "voice drag"

// can_drag is whether a left press on `user` starts dragging them rather than
// opening their menu at once. Call with the View locked.
can_drag :: proc(ui: ^UI, user: conn.View_User) -> bool {
	v := ui.view
	if ui.touched || .Move_Members not_in v.permissions {
		return false
	}
	if user.room == 0 || proto.room_call(user.room) != 0 {
		return false
	}
	// As in the menu: never the owner, nor a bot.
	acc, known := v.accounts[user.account]
	return known && acc.flags & {.Owner, .Bot} == {}
}

// voice_drag_begin starts following a left press on the connection `num`.
voice_drag_begin :: proc(ui: ^UI, num: proto.User_Num, user: conn.View_User) {
	ui.voice_drag = {
		num     = num,
		account = user.account,
		room    = user.room,
		from    = ui.ctx.mouse_pos,
	}
}

// voice_drag_target is called by channel_rows for each channel, with `block`
// the channel's row and the rows of the people in its room under it. If they
// are being dragged over it and may be moved there, it is marked, and is
// where they go if dropped now. Call with the View locked.
voice_drag_target :: proc(ui: ^UI, ch: conn.View_Channel, block: mu.Rect) {
	ctx := &ui.ctx
	d := &ui.voice_drag
	if !d.dragging || proto.Room(ch.id) == d.room || .Voice not_in ch.rights {
		return
	}
	// Only the part of the list that is on screen (it scrolls).
	clip := mu.get_clip_rect(ctx)
	if !inside(block, ctx.mouse_pos) || !inside(clip, ctx.mouse_pos) {
		return
	}
	d.target = ch.id
	accent := theme.link
	mu.draw_rect(ctx, block, {accent.r, accent.g, accent.b, 40})
	edge: i32 = 2
	mu.draw_rect(ctx, {block.x, block.y, block.w, edge}, accent)
	mu.draw_rect(ctx, {block.x, block.y + block.h - edge, block.w, edge}, accent)
	mu.draw_rect(ctx, {block.x, block.y, edge, block.h}, accent)
	mu.draw_rect(ctx, {block.x + block.w - edge, block.y, edge, block.h}, accent)
}

// voice_drag_frame follows the press after everything else is laid out:
// while the button is down it draws the name at the pointer, and when it is
// released it either moves them to the marked channel or, if the pointer
// never went far, opens their menu. Call with the View locked.
voice_drag_frame :: proc(ui: ^UI) {
	ctx := &ui.ctx
	d := &ui.voice_drag
	if d.num == 0 {
		return
	}
	target := d.target
	d.target = 0 // channel_rows marks it again in the next frame
	v := ui.view
	user, known := v.users[d.num]
	// Gone, or moved by somebody else meanwhile: there is nothing to drag.
	if !known || user.room != d.room || ui.session == nil {
		ui.voice_drag = {}
		return
	}
	if .Escape in ui.keys {
		ui.keys -= {.Escape}
		ui.voice_drag = {}
		return
	}
	p := ctx.mouse_pos
	if !d.dragging && max(abs(p.x - d.from.x), abs(p.y - d.from.y)) >= DRAG_START {
		d.dragging = true
	}
	if .LEFT in ctx.mouse_down_bits {
		if d.dragging {
			drag_label(ui, user.name, target != 0)
		}
		return
	}
	// Released.
	drag := d^
	ui.voice_drag = {}
	if !drag.dragging {
		open_user_menu(ui, drag.num, drag.account)
		ui_redraw(ui) // user_menu opens it in the next frame
		return
	}
	if target != 0 {
		command(ui, conn.Voice_Move_Command{account = drag.account, room = proto.Room(target)})
	}
}

// drag_label is the name of whoever is being dragged, by the pointer, in a
// window of its own over everything. It is just off the pointer, so that it
// doesn't take the hover from what is under it.
@(private = "file")
drag_label :: proc(ui: ^UI, name: string, over_target: bool) {
	ctx := &ui.ctx
	pad := ctx.style.padding
	font := ctx.style.font
	icon := i32(render.ICON_SIZE)
	w := icon + ctx.text_width(font, name) + 3 * pad
	h := max(ctx.text_height(font), icon) + 2 * pad
	r := mu.Rect{ctx.mouse_pos.x + 14, ctx.mouse_pos.y + 10, w, h}
	cnt := mu.get_container(ctx, DRAG_WINDOW)
	if cnt == nil {
		return
	}
	cnt.rect = r
	if cnt.zindex != ctx.last_zindex {
		mu.bring_to_front(ctx, cnt)
	}
	opts := mu.Options{.NO_TITLE, .NO_FRAME, .NO_RESIZE, .NO_SCROLL, .NO_CLOSE, .NO_INTERACT}
	if !mu.begin_window(ctx, DRAG_WINDOW, r, opts) {
		return
	}
	defer mu.end_window(ctx)
	border := theme.link if over_target else ctx.style.colors[.BORDER]
	render.draw_rounded(ctx, r, ctx.style.colors[.BASE], render.CONTROL_RADIUS)
	render.draw_rounded_border(ctx, r, border, render.CONTROL_RADIUS)
	mu.draw_icon(
		ctx,
		render.icon_id(.Mic),
		{r.x + pad, r.y + (h - icon) / 2, icon, icon},
		ctx.style.colors[.TEXT],
	)
	text_y := r.y + (h - ctx.text_height(font)) / 2
	mu.draw_text(ctx, font, name, {r.x + icon + 2 * pad, text_y}, ctx.style.colors[.TEXT])
}

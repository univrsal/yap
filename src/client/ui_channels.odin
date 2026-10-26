package client

import "client:conn"
import "client:render"
import "client:settings"
import "common:proto"
import log "common:wlog"
import "core:fmt"
import "core:strings"
import "core:sync"
import mu "vendor:microui"

// Channels in the UI (conn/convs.odin is the network's end of it).
//
//   - The list down the left of the session screen: the channels we're
//     subscribed to, the home channel first, with the number of unread
//     messages in each (dimmer for a muted channel). Clicking a channel shows its
//     chat and does nothing else. Right-clicking one opens its menu (how much
//     it may interrupt, its settings, leaving it). Under each channel are the
//     people in its voice room. At the list's foot, whichever way it is
//     scrolled, is the button to the Join a channel window.
//   - The line above the chat: which channel it is, and the button that
//     joins or leaves its voice room. Looking at a channel and talking in
//     it are two separate things, and that button is the only place where they meet.
//   - The Join a channel window: finding a channel we aren't in by its name or
//     topic, and joining it. Making and changing channels is in the settings
//     (ui_channel_settings.odin), and leaving one or how much it may interrupt
//     is in its menu.
//
// Where the window is too narrow for the list beside the chat (a phone),
// the two take turns: the list, or the chat with a way back to the list.

UI_Channels :: struct {
	// The Join a channel window, and what is typed in it to find a channel,
	// which is asked for again whenever it changes.
	open:       bool,
	placed:     bool,
	find:       Pager,
	// In a narrow window: the list is showing instead of the chat.
	show_list:  bool,
	// The channel whose menu is open (see channel_menu), and whether it was
	// right-clicked in this frame.
	menu_conv:  proto.Conv_Id,
	menu_asked: bool,
}

@(private = "file")
CHANNEL_MENU :: "channel menu"
@(private = "file")
CHANNEL_MENU_WIDTH :: 200

// The channel list's rows are in a bigger font (render.LIST_FONT), with this
// much room above and below the text, and this far apart. They are at least a
// control's height, which on a phone is a fingertip's (style_apply).
@(private = "file")
CHANNEL_ROW_PADDING :: 6
@(private = "file")
CHANNEL_ROW_GAP :: 2

@(private = "file")
CHANNELS_WINDOW :: "Join a channel"
@(private = "file")
JOIN_BUTTON :: 80

// viewed_channel is the channel whose chat is showing, or nil. Call
// with the View locked.
viewed_channel :: proc(v: ^conn.View) -> ^conn.View_Channel {
	for &ch in v.channels {
		if ch.id == v.viewing {
			return &ch
		}
	}
	return nil
}

// rights_here is what we may do in the conversation being shown: a channel's
// rights as the server told us, or everything but Voice in a DM. Call with the
// View locked.
rights_here :: proc(v: ^conn.View) -> proto.Conv_Rights {
	return rights_in(v, v.viewing)
}

// rights_in is what we may do in one of our conversations (see rights_here).
rights_in :: proc(v: ^conn.View, conv: proto.Conv_Id) -> proto.Conv_Rights {
	for ch in v.channels {
		if ch.id == conv {
			return ch.rights
		}
	}
	return proto.conv_rights_default(.DM, {})
}

// channel_list is the panel of our channels, with who is talking in each.
// Call with the View locked.
channel_list :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := ui.view

	// The list, with the way to the rest of the channels at its foot.
	mu.layout_begin_column(ctx)
	defer mu.layout_end_column(ctx)
	// And under it, the voice panel. In a narrow window that is across the
	// screen instead (see session_screen).
	panel_h := 0 if ui.narrow else voice_panel_height(ui)
	mu.layout_row(ctx, {-1}, -(panel_h + 1))
	area := mu.layout_next(ctx)

	// One frame around both: the rows scroll in a panel without its own,
	// over the button, which stays put.
	ctx.draw_frame(ctx, area, .PANEL_BG)
	pad := ctx.style.padding
	button_h := ctx.style.size.y + 2 * pad
	mu.layout_set_next(ctx, {area.x, area.y, area.w, area.h - button_h - pad}, false)
	mu.begin_panel(ctx, "channels", {.NO_FRAME})
	if len(v.channels) == 0 {
		spinner_row(ui) // the channel list, on its way
	}
	channel_rows(ui)
	mu.end_panel(ctx)
	mu.layout_set_next(
		ctx,
		{area.x + pad, area.y + area.h - button_h - pad, area.w - 2 * pad, button_h},
		false,
	)
	if .SUBMIT in button(ctx, "Join a channel...") {
		open_channels(ui)
	}

	if !ui.narrow {
		voice_panel(ui)
	}
}

// channel_rows is a row for each of our channels in the list, each followed
// by the people in its voice room. Call with the View locked.
@(private = "file")
channel_rows :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := ui.view
	// The rows close together, and so the people in a voice room under its
	// channel. Only here: the rest of the list, and the voice panel under
	// it, are spaced as everything else (voice_panel_height counts on that).
	saved_spacing := ctx.style.spacing
	ctx.style.spacing = CHANNEL_ROW_GAP
	defer ctx.style.spacing = saved_spacing
	row_h := max(
		ctx.text_height(render.LIST_FONT) + 2 * CHANNEL_ROW_PADDING,
		ctx.style.size.y + 2 * ctx.style.padding,
	)
	for ch in v.channels {
		mu.push_id(ctx, uintptr(ch.id))
		defer mu.pop_id(ctx)

		mu.layout_row(ctx, {-1}, row_h)
		viewing := ch.id == v.viewing
		label := fmt.tprintf("%s%s", ch.name, " 🔒" if ch.private else "")
		// Unread and not muted: brighter, as well as showing the count.
		saved := ctx.style.colors[.TEXT]
		if ch.unread > 0 && ch.notify != .None {
			ctx.style.colors[.TEXT] = theme.unread_text
		}
		saved_font := ctx.style.font
		ctx.style.font = render.LIST_FONT
		// When narrow, the list is all there is on screen, so no channel is open.
		clicked := .SUBMIT in list_row(ctx, "view", label, viewing && !ui.narrow, accent = true)
		ctx.style.font = saved_font
		ctx.style.colors[.TEXT] = saved
		if ctx.hover_id == mu.get_id(ctx, "view") && .RIGHT in ctx.mouse_pressed_bits {
			ui.channels.menu_conv, ui.channels.menu_asked = ch.id, true
		}
		if ch.unread > 0 {
			w := unread_badge(ctx, ctx.last_rect, ch.unread, ch.notify == .None)
			if ch.mentions > 0 {
				mention_badge(ctx, ctx.last_rect, ch.mentions, w)
			}
		}
		if clicked {
			view_channel(ui, v, ch)
		}
		block := ctx.last_rect
		for m in ch.members {
			member_row(ui, m)
		}
		// The channel and the people under it, where someone being dragged
		// can be dropped (ui_voice_drag.odin).
		block.h = ctx.last_rect.y + ctx.last_rect.h - block.y
		voice_drag_target(ui, ch, block)
	}
}

// conversation_header is the line above the chat: which channel it is, the
// button for its pinned messages, and the one for its voice room. In a
// narrow window it also leads back to the list. Call with the View locked.
conversation_header :: proc(ui: ^UI, narrow: bool) {
	ctx := &ui.ctx
	v := ui.view
	ch := viewed_channel(v)

	// The members' button is not there while they are pinned down the side.
	pinned := ui.profiles.members_pinned && !narrow
	buttons: i32 = 3 if pinned else 4
	right := buttons * icon_button_w(ctx) + buttons * ctx.style.spacing + 1
	widths := make([dynamic]i32, context.temp_allocator)
	if narrow {
		append(&widths, 40)
	}
	append(&widths, -right)
	for _ in 0 ..< buttons {
		append(&widths, icon_button_w(ctx))
	}
	mu.layout_row(ctx, widths[:])
	if narrow && .SUBMIT in icon_button(ui, "to list", .Back, "Channels") {
		ui.channels.show_list = true
	}
	if ch == nil {
		for _ in 0 ..< buttons + 1 {
			mu.label(ctx, "")
		}
		return
	}

	// The name and the topic (not in a narrow window, where the list is a
	// button away), and what is going on.
	status, status_color := chat_status(ui)
	if narrow {
		header_line(ctx, mu.layout_next(ctx), "", {}, "", status, status_color)
	} else {
		name := fmt.tprintf("# %s", ch.name)
		header_line(ctx, mu.layout_next(ctx), name, theme.viewing, ch.topic, status, status_color)
	}
	if !pinned {
		members_button(ui)
	}
	pins_button(ui)
	search_button(ui)

	in_it := v.my_room == ch.id
	// No voice room here for us: text only, or not ours to talk in.
	if .Voice not_in ch.rights && !in_it {
		mu.label(ctx, "")
		return
	}
	hint: string
	color := mu.Color{}
	switch {
	case v.voice_pending:
		hint = "Joining call..."
	case in_it:
		hint = "Stop talking in this channel"
		color = theme.off
	case:
		hint = "Talk in this channel"
		if v.my_room != 0 {
			hint = "Talk in this channel instead of the one you're in"
		}
	}
	if .SUBMIT in icon_button(ui, "voice", .Phone, hint, color) && !v.voice_pending {
		if in_it {
			log.debugf("ui: leave voice of %q", ch.name)
			command(ui, conn.Voice_Command{})
		} else {
			join_voice(ui, ch^)
		}
	}
}

// view_channel shows the channel `ch` of the shown server, as clicking it in
// the list does. Call with the View locked.
view_channel :: proc(ui: ^UI, v: ^conn.View, ch: conn.View_Channel) {
	if ch.id != v.viewing {
		log.debugf("ui: view %q", ch.name)
		command(ui, conn.View_Command{conv = ch.id})
		// Where to start the next time we are on this server.
		if settings.set_joined_channel(&ui.settings, v.server, ch.name) {
			ui.settings_dirty = true
		}
	}
	// In a narrow window, picking a channel is also how to get to it.
	ui.channels.show_list = false
}

// join_voice joins the voice room of the channel `ch` of the shown server,
// leaving one on another server. Call with the View locked.
join_voice :: proc(ui: ^UI, ch: conn.View_Channel) {
	log.debugf("ui: join voice of %q", ch.name)
	leave_voice_elsewhere(ui)
	command(ui, conn.Voice_Command{conv = ch.id})
}

// unread_badge draws a count of unread messages at the right end of
// `r`, and returns how much of the row it took.
@(private = "file")
unread_badge :: proc(ctx: ^mu.Context, r: mu.Rect, count: int, muted: bool) -> i32 {
	return badge(
		ctx,
		r,
		conn.unread_count(count),
		theme.muted_badge if muted else theme.unread_badge,
		theme.dim if muted else theme.badge_text,
		0,
	)
}

// mention_badge draws how many of the unread messages mention us, in front of
// the unread count, which took `taken` of the row's end. It is shown for a muted
// channel too, because a mention is still a mention.
@(private = "file")
mention_badge :: proc(ctx: ^mu.Context, r: mu.Rect, count: int, taken: i32) {
	badge(
		ctx,
		r,
		fmt.tprintf("@%s", conn.unread_count(count)),
		theme.mention_badge,
		theme.mention,
		taken,
	)
}

// badge draws `text` in a little box at the right end of `r`, leaving
// `taken` of it, and returns how much more it took.
@(private = "file")
badge :: proc(
	ctx: ^mu.Context,
	r: mu.Rect,
	text: string,
	background, color: mu.Color,
	taken: i32,
) -> i32 {
	font := ctx.style.font
	w := ctx.text_width(font, text) + 10
	h := ctx.text_height(font) + 2
	b := mu.Rect{r.x + r.w - w - 4 - taken, r.y + (r.h - h) / 2, w, h}
	// A pill.
	render.draw_rounded(ctx, b, background, h / 2)
	mu.draw_text(ctx, font, text, {b.x + 5, b.y + 1}, color)
	return taken + w + 4
}

// unread_total is how many messages are unread in the channels and DMs
// that aren't muted, for the window's title and the tray. Call with the
// View locked.
unread_total :: proc(s: ^settings.Settings, v: ^conn.View) -> (n: int) {
	for ch in v.channels {
		if ch.notify != .None {
			n += ch.unread
		}
	}
	return n + dm_unread(s, v)
}

@(private = "file")
NOTIFY_LABELS := [proto.Notify_Level]string {
	.All      = "Notify: all",
	.Mentions = "Mentions only",
	.None     = "Muted",
}

// channel_menu is a channel's menu, opened by right-clicking it in the
// list: how much it may interrupt (clicking cycles through the choices), its
// settings for those who may change them, and leaving it.
// It is drawn after the list, with the View locked.
channel_menu :: proc(ui: ^UI) {
	ctx := &ui.ctx
	c := &ui.channels
	if c.menu_asked {
		c.menu_asked = false
		mu.open_popup(ctx, CHANNEL_MENU)
	}
	if cnt := mu.get_container(ctx, CHANNEL_MENU, {.CLOSED}); cnt != nil && cnt.open {
		w, h := i32(ui.metrics.logical_w), i32(ui.metrics.logical_h)
		cnt.rect.x = clamp(cnt.rect.x, 0, max(w - cnt.rect.w, 0))
		cnt.rect.y = clamp(cnt.rect.y, 0, max(h - cnt.rect.h, 0))
	}
	if !begin_popup(ui, CHANNEL_MENU) {
		return
	}
	defer mu.end_popup(ctx)
	close :: proc(ctx: ^mu.Context) {
		mu.get_current_container(ctx).open = false
	}
	v := ui.view
	ch: ^conn.View_Channel
	for &each in v.channels {
		if each.id == c.menu_conv {
			ch = &each
		}
	}
	// Left, or gone, under the menu.
	if ch == nil {
		close(ctx)
		return
	}

	mu.layout_row(ctx, {CHANNEL_MENU_WIDTH})
	dim_label(ctx, ch.name)
	if .SUBMIT in
	   stable_button_hint(
		   ui,
		   "notify",
		   NOTIFY_LABELS[ch.notify],
		   "How much this channel may interrupt: click to change",
	   ) {
		next := proto.Notify_Level((int(ch.notify) + 1) % len(proto.Notify_Level))
		command(ui, conn.Notify_Command{conv = ch.id, notify = next})
	}
	if .Manage_Channels in v.permissions &&
	   .SUBMIT in stable_button(ctx, "settings", "Settings...") {
		open_channel_settings(ui, ch.id) // ui_channel_settings.odin
		close(ctx)
	}
	if !ch.home && .SUBMIT in stable_button(ctx, "unsubscribe", "Unsubscribe") {
		command(ui, conn.Subscribe_Command{conv = ch.id, on = false})
		close(ctx)
	}
}

// voice_room_name is the channel whose voice room we're in, or "".
// Call with the View locked.
voice_room_name :: proc(v: ^conn.View) -> string {
	if v.my_room == 0 {
		return ""
	}
	if proto.room_call(proto.Room(v.my_room)) != 0 {
		return "a call"
	}
	for ch in v.channels {
		if ch.id == v.my_room {
			return ch.name
		}
	}
	// One a moderator moved us into (conn/moderation.odin).
	if v.guest_name != "" {
		return v.guest_name
	}
	// A channel we're talking in without being subscribed to it.
	return "another channel"
}

open_channels :: proc(ui: ^UI) {
	ui.channels.open = true
	ui.channels.placed = false
	browse(ui, 0)
}

// browse asks for the page of channels to join that starts at `offset`,
// among those that match what is typed.
@(private = "file")
browse :: proc(ui: ^UI, offset: int) {
	command(
		ui,
		conn.Browse_Command {
			query = strings.clone(pager_query(&ui.channels.find)),
			offset = offset,
			limit = PAGE_ROWS,
		},
	)
}

// channels_window is the floating window for joining a channel: what is typed
// in it is looked for in the names and topics of the channels we aren't in,
// which the server answers a page at a time. Call with the View unlocked.
channels_window :: proc(ui: ^UI, window_w, window_h: i32) {
	c := &ui.channels
	if !c.open {
		return
	}
	ctx := &ui.ctx
	v := ui.view
	sync.guard(&v.mutex)
	if v.status != .Connected || v.login.state != .Done {
		c.open = false
		return
	}

	if !c.placed {
		c.placed = true
		w := clamp(window_w - 40, 240, 460)
		h := clamp(window_h - 40, 200, 520)
		if cnt := mu.get_container(ctx, CHANNELS_WINDOW); cnt != nil {
			cnt.rect = {(window_w - w) / 2, (window_h - h) / 2, w, h}
			cnt.open = true
			cnt.scroll = {}
			mu.bring_to_front(ctx, cnt)
			// The click that opened it would raise the window behind at
			// the end of the frame (see image_viewer).
			ctx.hover_root, ctx.next_hover_root = cnt, cnt
		}
	}
	if !mu.begin_window(ctx, CHANNELS_WINDOW, {}) {
		c.open = false // closed with the title bar's button
		return
	}
	defer mu.end_window(ctx)

	if pager_search(ui, &c.find, "Search by name or topic") {
		browse(ui, 0)
	}
	if len(v.browse) == 0 {
		text := "Asking the server..."
		if v.browse_count > 0 {
			text =
				"You're in every channel you can join." if pager_query(&c.find) == "" else "No channel you aren't in has that in its name or topic."
		}
		mu.layout_row(ctx, {-1})
		dim_note(ctx, text)
	}
	for e in v.browse {
		mu.push_id(ctx, uintptr(e.id))
		defer mu.pop_id(ctx)
		mu.layout_row(ctx, {-(JOIN_BUTTON + ctx.style.spacing + 1), JOIN_BUTTON})
		channel_label(ctx, e.name, e.topic)
		if .SUBMIT in stable_button(ctx, "join", "Join", {.ALIGN_CENTER}) {
			command(ui, conn.Subscribe_Command{conv = e.id, on = true})
		}
	}
	if offset, turned := pager_footer_open(ui, v.browse_offset, len(v.browse), v.browse_more);
	   turned {
		browse(ui, offset)
	}

	// Where the rest of what this window used to do went.
	if v.permissions & {.Create_Channels, .Manage_Channels} != {} {
		mu.layout_row(ctx, {-1})
		mu.label(ctx, "")
		mu.layout_row(ctx, {-1})
		if .SUBMIT in
		   stable_button(ctx, "channel settings", "Make or change channels...", {.ALIGN_CENTER}) {
			c.open = false
			open_channel_settings(ui, 0)
		}
	}
}

// channel_label is a channel's name and, dimmer and as far as there is
// room, its topic, in the next layout cell.
@(private = "file")
channel_label :: proc(ctx: ^mu.Context, name, topic: string) {
	r := mu.layout_next(ctx)
	font := ctx.style.font
	y := r.y + (r.h - ctx.text_height(font)) / 2
	mu.push_clip_rect(ctx, r)
	mu.draw_text(ctx, font, name, {r.x + ctx.style.padding, y}, ctx.style.colors[.TEXT])
	if topic != "" {
		x := r.x + ctx.style.padding + ctx.text_width(font, name) + 12
		mu.draw_text(ctx, font, topic, {x, y}, theme.dim)
	}
	mu.pop_clip_rect(ctx)
}

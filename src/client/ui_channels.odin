package client

import "client:conn"
import "client:settings"
import "common:proto"
import log "common:wlog"
import "core:fmt"
import "core:strings"
import "core:sync"
import mu "vendor:microui"

/*
Channels in the UI (conn/convs.odin is the network's end of it).

  - The list down the left of the session screen: the channels we're
    subscribed to, the home channel first, with how many messages are
    unread in each (dimmer for a muted one). Clicking one shows its chat
    and does nothing else; right-clicking one opens its menu (how much
    it may interrupt, its settings, leaving it). Under each are the
    people in its voice room, as they always were.
  - The line above the chat: which channel it is, and the button that
    joins or leaves its voice room. Looking at a channel and talking in
    it are two things, and that button is the only place they meet.
  - The Channels window: the ones we're in, how much each may
    interrupt, and leaving them; the ones we aren't, to subscribe to;
    and, for who may, making one.

Where the window is too narrow for the list beside the chat (a phone),
the two take turns: the list, or the chat with a way back to the list.
*/

UI_Channels :: struct {
	// The Channels window.
	open:        bool,
	placed:      bool,
	// Making one: its name and topic.
	name_buf:    [2 * proto.MAX_CHANNEL_NAME_SIZE]u8,
	name_len:    int,
	topic_buf:   [proto.MAX_TOPIC_SIZE]u8,
	topic_len:   int,
	// In a narrow window: the list is showing, rather than the chat.
	show_list:   bool,
	// What the server had said by the time the window opened isn't about
	// anything asked in it (conn.View_Notice.count).
	notice_seen: int,
	// Finding channels to subscribe to: what's typed, and what was last
	// asked for (owned), which is asked again when it changes.
	find_buf:    [proto.MAX_BROWSE_QUERY]u8,
	find_len:    int,
	find_asked:  string,
	// The channel whose menu is open (channel_menu), and that it was
	// right-clicked this frame.
	menu_conv:   proto.Conv_Id,
	menu_asked:  bool,
}

@(private = "file")
CHANNEL_MENU :: "channel menu"
@(private = "file")
CHANNEL_MENU_WIDTH :: 200

@(private = "file")
CHANNELS_WINDOW :: "Channels"
@(private = "file")
SUBSCRIBE_BUTTON :: 120
@(private = "file")
MANAGE_BUTTON :: 90
@(private = "file")
NOTIFY_BUTTON :: 120
@(private = "file")
UNREAD_TEXT_COLOR :: mu.Color{255, 255, 255, 255}
@(private = "file")
UNREAD_BADGE_COLOR :: mu.Color{60, 110, 200, 255}
@(private = "file")
MUTED_BADGE_COLOR :: mu.Color{70, 70, 70, 255}
@(private = "file")
VIEWING_COLOR :: mu.Color{230, 230, 230, 255}
@(private = "file")
NOTICE_OK_COLOR :: mu.Color{120, 200, 120, 255}

@(private = "file")
command :: proc(ui: ^UI, cmd: conn.Command) {
	if ui.session != nil {
		conn.push_command(&ui.session.client.commands, cmd)
	}
}

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

/*
channel_list is the panel of our channels, with who is talking in each.
Call with the View locked.
*/
channel_list :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := ui.view

	// The list, and under it the way to the rest of the channels.
	mu.layout_begin_column(ctx)
	defer mu.layout_end_column(ctx)
	button_h := ctx.style.size.y + 2 * ctx.style.padding
	// And under that, the voice panel; in a narrow window that's across
	// the screen instead (session_screen).
	panel_h := 0 if ui.narrow else voice_panel_height(ui)
	mu.layout_row(ctx, {-1}, -(button_h + ctx.style.spacing + panel_h + 1))

	mu.begin_panel(ctx, "channels")
	if len(v.channels) == 0 {
		mu.layout_row(ctx, {-1})
		mu.label(ctx, "Waiting for the channel list...")
	}
	for ch in v.channels {
		mu.push_id(ctx, uintptr(ch.id))
		defer mu.pop_id(ctx)

		mu.layout_row(ctx, {-1})
		viewing := ch.id == v.viewing
		label := fmt.tprintf(
			"%s%s%s",
			"⏵ " if viewing else "  ",
			ch.name,
			" 🔒" if ch.private else "",
		)
		// Unread, and not muted: brighter, as well as the count.
		saved := ctx.style.colors[.TEXT]
		if ch.unread > 0 && ch.notify != .None {
			ctx.style.colors[.TEXT] = UNREAD_TEXT_COLOR
		}
		clicked := .SUBMIT in stable_button(ctx, "view", label)
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
			if !viewing {
				log.debugf("ui: view %q", ch.name)
				command(ui, conn.View_Command{conv = ch.id})
				// Where to start the next time we're on this server.
				if settings.set_joined_channel(&ui.settings, v.server, ch.name) {
					ui.settings_dirty = true
				}
			}
			// In a narrow window, picking one is also how to get to it.
			ui.channels.show_list = false
		}
		for m in ch.members {
			member_row(ui, m)
		}
	}
	mu.end_panel(ctx)

	mu.layout_row(ctx, {-1})
	if .SUBMIT in mu.button(ctx, "Channels...") {
		open_channels(ui)
	}
	if !ui.narrow {
		voice_panel(ui)
	}
}

/*
conversation_header is the line above the chat: the channel it is, the
button for its pinned messages, and the one for its voice room. In a
narrow window it also leads back to the list. Call with the View locked.
*/
conversation_header :: proc(ui: ^UI, narrow: bool) {
	ctx := &ui.ctx
	v := ui.view
	ch := viewed_channel(v)

	right := 4 * ICON_BUTTON + 4 * ctx.style.spacing + 1
	if narrow {
		mu.layout_row(ctx, {40, -right, ICON_BUTTON, ICON_BUTTON, ICON_BUTTON, ICON_BUTTON})
		if .SUBMIT in stable_button_hint(ui, "to list", "<", "Channels", {.ALIGN_CENTER}) {
			ui.channels.show_list = true
		}
	} else {
		mu.layout_row(ctx, {-right, ICON_BUTTON, ICON_BUTTON, ICON_BUTTON, ICON_BUTTON})
	}
	if ch == nil {
		mu.label(ctx, "")
		mu.label(ctx, "")
		mu.label(ctx, "")
		mu.label(ctx, "")
		mu.label(ctx, "")
		return
	}

	// The name, and what's left of the line for the topic.
	r := mu.layout_next(ctx)
	font := ctx.style.font
	name := fmt.tprintf("# %s", ch.name)
	y := r.y + (r.h - ctx.text_height(font)) / 2
	mu.push_clip_rect(ctx, r)
	mu.draw_text(ctx, font, name, {r.x + ctx.style.padding, y}, VIEWING_COLOR)
	if ch.topic != "" {
		x := r.x + ctx.style.padding + ctx.text_width(font, name) + 12
		mu.draw_text(ctx, font, ch.topic, {x, y}, DIM_COLOR)
	}
	mu.pop_clip_rect(ctx)
	members_button(ui)
	pins_button(ui)
	search_button(ui)

	in_it := v.my_room == ch.id
	hint: string
	color := mu.Color{}
	switch {
	case v.voice_pending:
		hint = "Joining call..."
	case in_it:
		hint = "Stop talking in this channel"
		color = OFF_COLOR
	case:
		hint = "Talk in this channel"
		if v.my_room != 0 {
			hint = "Talk in this channel instead of the one you're in"
		}
	}
	if .SUBMIT in icon_button(ui, "voice", .Phone, hint, color) && !v.voice_pending {
		log.debugf("ui: %s %q", "leave voice of" if in_it else "join voice of", ch.name)
		if in_it {
			command(ui, conn.Voice_Command{})
		} else {
			leave_voice_elsewhere(ui)
			command(ui, conn.Voice_Command{conv = ch.id})
		}
	}
}

// unread_badge draws a count of unread messages at the right end of
// `r`, and says how much of the row it took.
@(private = "file")
unread_badge :: proc(ctx: ^mu.Context, r: mu.Rect, count: int, muted: bool) -> i32 {
	return badge(
		ctx,
		r,
		conn.unread_count(count),
		MUTED_BADGE_COLOR if muted else UNREAD_BADGE_COLOR,
		DIM_COLOR if muted else UNREAD_TEXT_COLOR,
		0,
	)
}

// mention_badge draws how many of them mention us, in front of the
// unread count, which took `taken` of the row's end. It shows for a muted
// channel too: a mention is still one.
@(private = "file")
mention_badge :: proc(ctx: ^mu.Context, r: mu.Rect, count: int, taken: i32) {
	badge(
		ctx,
		r,
		fmt.tprintf("@%s", conn.unread_count(count)),
		MENTION_BADGE_COLOR,
		MENTION_COLOR,
		taken,
	)
}

@(private = "file")
MENTION_BADGE_COLOR :: mu.Color{90, 65, 20, 255}

// badge draws `text` on a little box at the right end of `r`, leaving
// `taken` of it; it says how much more it took.
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
	mu.draw_rect(ctx, b, background)
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

/*
channel_menu is a channel's menu, opened by right-clicking it in the
list: how much it may interrupt (clicked round, as in the Channels
window), its settings for who may change them, and leaving it. Drawn
after the list, with the View locked.
*/
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
	if !mu.begin_popup(ctx, CHANNEL_MENU) {
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
	with_text_color(ctx, DIM_COLOR, ch.name, label_proc)
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
		open_channels(ui)
		ui.manage.conv, ui.manage.loaded = ch.id, 0
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
	// One we're talking in without being subscribed to it.
	return "another channel"
}

open_channels :: proc(ui: ^UI) {
	ui.channels.open = true
	ui.channels.placed = false
	ui.channels.notice_seen = -1 // taken from the View when it's next locked
	command(
		ui,
		conn.Browse_Command {
			query = strings.clone(
				strings.trim_space(string(ui.channels.find_buf[:ui.channels.find_len])),
			),
		},
	)
}

/*
channels_window is the floating window for what the list doesn't do:
leaving a channel, subscribing to another, making one. Call with the
View unlocked.
*/
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
	if c.notice_seen < 0 {
		c.notice_seen = v.notice.count
	}

	if !c.placed {
		c.placed = true
		w := clamp(window_w - 40, 240, 520)
		h := clamp(window_h - 40, 200, 480)
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

	mu.layout_row(ctx, {-1})
	mu.label(ctx, "Your channels")
	manage := .Manage_Channels in v.permissions
	for ch in v.channels {
		mu.push_id(ctx, uintptr(ch.id))
		defer mu.pop_id(ctx)
		if manage {
			mu.layout_row(
				ctx,
				{
					-(NOTIFY_BUTTON +
						SUBSCRIBE_BUTTON +
						MANAGE_BUTTON +
						3 * ctx.style.spacing +
						1),
					MANAGE_BUTTON,
					NOTIFY_BUTTON,
					SUBSCRIBE_BUTTON,
				},
			)
		} else {
			mu.layout_row(
				ctx,
				{
					-(NOTIFY_BUTTON + SUBSCRIBE_BUTTON + 2 * ctx.style.spacing + 1),
					NOTIFY_BUTTON,
					SUBSCRIBE_BUTTON,
				},
			)
		}
		channel_label(ctx, fmt.tprintf("%s%s", ch.name, " 🔒" if ch.private else ""), ch.topic)
		if manage &&
		   .SUBMIT in
			   stable_button(
				   ctx,
				   "manage",
				   "Close" if ui.manage.conv == ch.id else "Settings",
				   {.ALIGN_CENTER},
			   ) {
			ui.manage.conv = 0 if ui.manage.conv == ch.id else ch.id
			ui.manage.loaded = 0
		}
		// All, mentions only, muted, and round again.
		if .SUBMIT in
		   stable_button_hint(
			   ui,
			   "notify",
			   NOTIFY_LABELS[ch.notify],
			   "How much this channel may interrupt: click to change",
			   {.ALIGN_CENTER},
		   ) {
			next := proto.Notify_Level((int(ch.notify) + 1) % len(proto.Notify_Level))
			command(ui, conn.Notify_Command{conv = ch.id, notify = next})
		}
		if ch.home {
			with_text_color(ctx, DIM_COLOR, "everyone is in it", label_proc)
		} else if .SUBMIT in stable_button(ctx, "unsubscribe", "Unsubscribe", {.ALIGN_CENTER}) {
			command(ui, conn.Subscribe_Command{conv = ch.id, on = false})
		}
	}

	channel_settings(ui)

	mu.layout_row(ctx, {-1})
	mu.label(ctx, "")
	mu.label(ctx, "Find a channel to join")
	// What's typed is asked for as it changes: the server looks through
	// the channels' names and topics, a page at a time.
	mu.layout_row(ctx, {-1})
	text_box(ui, c.find_buf[:], &c.find_len)
	if find := string(c.find_buf[:c.find_len]); find != c.find_asked {
		delete(c.find_asked)
		c.find_asked = strings.clone(find)
		command(ui, conn.Browse_Command{query = strings.clone(strings.trim_space(find))})
	}
	if len(v.browse) == 0 {
		none :=
			"  There are none you aren't in." if c.find_len == 0 else "  None has that in its name or topic."
		with_text_color(
			ctx,
			DIM_COLOR,
			none if v.browse_count > 0 else "  Asking the server...",
			label_proc,
		)
	}
	for e in v.browse {
		mu.push_id(ctx, uintptr(e.id))
		defer mu.pop_id(ctx)
		mu.layout_row(ctx, {-(SUBSCRIBE_BUTTON + ctx.style.spacing + 1), SUBSCRIBE_BUTTON})
		channel_label(ctx, e.name, e.topic)
		if .SUBMIT in stable_button(ctx, "subscribe", "Subscribe", {.ALIGN_CENTER}) {
			command(ui, conn.Subscribe_Command{conv = e.id, on = true})
		}
	}
	if v.browse_more {
		mu.layout_row(ctx, {SUBSCRIBE_BUTTON})
		if .SUBMIT in stable_button(ctx, "browse more", "More...", {.ALIGN_CENTER}) {
			command(ui, conn.Browse_Command{more = true})
		}
	}

	if .Create_Channels in v.permissions {
		mu.layout_row(ctx, {-1})
		mu.label(ctx, "")
		mu.label(ctx, "Make a channel")
		submit := false
		mu.layout_row(ctx, {60, -1})
		mu.label(ctx, "Name")
		submit |= .SUBMIT in text_box(ui, c.name_buf[:], &c.name_len)
		mu.label(ctx, "Topic")
		submit |= .SUBMIT in text_box(ui, c.topic_buf[:], &c.topic_len)
		mu.layout_row(ctx, {60, -1})
		mu.label(ctx, "")
		mu.checkbox(ctx, "Private: only for those added to it", &ui.manage.private)
		mu.layout_row(ctx, {60, 120, -1})
		mu.label(ctx, "")
		submit |= .SUBMIT in mu.button(ctx, "Make channel")
		if v.notice.text != "" && v.notice.count > c.notice_seen {
			with_text_color(
				ctx,
				NOTICE_OK_COLOR if v.notice.ok else ERROR_COLOR,
				v.notice.text,
				label_proc,
			)
		} else {
			mu.label(ctx, "")
		}
		if submit && c.name_len > 0 {
			command(
				ui,
				conn.Create_Channel_Command {
					name = strings.clone(string(c.name_buf[:c.name_len])),
					topic = strings.clone(string(c.topic_buf[:c.topic_len])),
					private = ui.manage.private,
				},
			)
			c.name_len, c.topic_len = 0, 0
			ui.manage.private = false
		}
	}
}

// channel_label is a channel's name and, dimmer and as far as there's
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
		mu.draw_text(ctx, font, topic, {x, y}, DIM_COLOR)
	}
	mu.pop_clip_rect(ctx)
}

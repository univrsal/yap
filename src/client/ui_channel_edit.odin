package client

import "core:fmt"
import "core:strings"
import "core:sync"
import mu "vendor:microui"

import "client:conn"
import "common:proto"

// A channel's admins (proto/convs.odin) manage that one channel without the
// settings' Channels, which is for those who manage every channel
// (ui_channel_settings.odin):
//
//   - The channel's menu (ui_channels.odin) offers "Name and topic...", which
//     opens the floating window below, and "Stop being its admin".
//   - The menu of a member, opened from the members list (ui_users.odin),
//     has icons among its moderation icons that make them an admin, or with
//     Manage_Channels no longer one, and remove them from a private channel.
//   - The members window lets them add people (ui_manage.odin), and its list
//     says who the admins are (ui_profiles.odin).
//
// The server checks all of it again.

UI_Channel_Edit :: struct {
	conv:   proto.Conv_Id, // the channel being edited, 0 when the window is closed
	placed: bool,
	name:   Text_Field(proto.MAX_CHANNEL_NAME_SIZE),
	topic:  Text_Field(proto.MAX_TOPIC_SIZE),
}

@(private = "file")
EDIT_WINDOW :: "Name and topic"
@(private = "file")
EDIT_LABEL :: 60

// open_channel_edit opens the window for a channel, filled with its name and
// topic as they are now.
open_channel_edit :: proc(ui: ^UI, ch: conn.View_Channel) {
	e := &ui.channel_edit
	e.conv, e.placed = ch.id, false
	field_set(&e.name, ch.name)
	field_set(&e.topic, ch.topic)
}

// may_admin_channel is whether we may manage a channel as its admin: we are
// one, or we manage every channel.
may_admin_channel :: proc(v: ^conn.View, ch: conn.View_Channel) -> bool {
	return ch.admin || .Manage_Channels in v.permissions
}

channel_edit_window :: proc(ui: ^UI, window_w, window_h: i32) {
	e := &ui.channel_edit
	if e.conv == 0 {
		return
	}
	ctx := &ui.ctx
	v := ui.view
	sync.guard(&v.mutex)
	ch: ^conn.View_Channel
	for &each in v.channels {
		if each.id == e.conv {
			ch = &each
		}
	}
	// Left, archived, or no longer ours to change.
	if ui.session == nil || ch == nil || !may_admin_channel(v, ch^) {
		e.conv = 0
		return
	}
	if !e.placed {
		e.placed = true
		w := clamp(window_w / 3, 300, 440)
		if cnt := mu.get_container(ctx, EDIT_WINDOW); cnt != nil {
			cnt.rect = {(window_w - w) / 2, 120, w, 135}
			cnt.open = true
			mu.bring_to_front(ctx, cnt)
			ctx.hover_root, ctx.next_hover_root = cnt, cnt
		}
	}
	if !mu.begin_window(ctx, EDIT_WINDOW, {}, {.NO_RESIZE}) {
		e.conv = 0
		return
	}
	keep_in_window(ui)
	defer mu.end_window(ctx)

	field_row(ui, EDIT_LABEL, "Name", {-1})
	submit := .SUBMIT in text_box(ui, e.name.buf[:], &e.name.len)
	field_row(ui, EDIT_LABEL, "Topic", {-1})
	submit |= .SUBMIT in text_box(ui, e.topic.buf[:], &e.topic.len)
	name := strings.trim_space(field_text(&e.name))
	changed := name != ch.name || field_text(&e.topic) != ch.topic
	field_row(ui, EDIT_LABEL, "", {100})
	submit |=
		.SUBMIT in stable_button(ctx, "save", "Save" if changed else "Saved", {.ALIGN_CENTER})
	if submit && changed && name != "" {
		command(
			ui,
			conn.Conv_Update_Command {
				conv = ch.id,
				mask = proto.CONV_UPDATE_NAME | proto.CONV_UPDATE_TOPIC,
				name = strings.clone(name),
				topic = strings.clone(field_text(&e.topic)),
			},
		)
	}
}

// Channel_Member_Actions is what a member's menu may do about the channel
// being looked at: make them its admin or no longer one (toggle), and remove
// them from it if it is private (remove).
Channel_Member_Actions :: struct {
	conv:   proto.Conv_Id,
	name:   string, // the channel's, as the View has it
	admin:  bool, // they are one of its admins
	toggle: bool,
	remove: bool,
}

// channel_member_actions says what a member's menu may do about the channel
// being looked at. Only its admins and those who manage channels may do
// anything, and only once the members list says they are a member. Call with
// the View locked.
channel_member_actions :: proc(
	v: ^conn.View,
	account: proto.Account_Id,
) -> (
	a: Channel_Member_Actions,
) {
	ch := conn.viewed_channel(v)
	if ch == nil || !may_admin_channel(v, ch^) || v.members.conv != ch.id {
		return
	}
	member := false
	for each in v.members.accounts {
		member ||= each == account
	}
	for each in v.members.admins {
		a.admin ||= each == account
	}
	acc, known := v.accounts[account]
	if !member || !known {
		return {}
	}
	a.conv, a.name = ch.id, ch.name
	// Only those who manage channels make an admin no longer one (admins
	// stop being one themselves, in the channel's menu).
	a.toggle = !a.admin || .Manage_Channels in v.permissions
	a.remove = ch.private && !ch.home && below_us(v, acc)
	return
}

// channel_member_icons are the icons for `a` in the user menu's row of
// moderation icons (ui_users.odin): a crown that makes them the channel's
// admin, or a crossed-out one that makes them no longer one, and removing
// them from the channel. Call with the View locked, inside the menu.
channel_member_icons :: proc(ui: ^UI, account: proto.Account_Id, a: Channel_Member_Actions) {
	ctx := &ui.ctx
	if a.toggle &&
	   .SUBMIT in
		   icon_button(
			   ui,
			   "channel admin",
			   .Crown_Off if a.admin else .Crown,
			   fmt.tprintf("No longer admin of #%s" if a.admin else "Make admin of #%s", a.name),
		   ) {
		command(ui, conn.Conv_Admin_Command{conv = a.conv, account = account, on = !a.admin})
		mu.get_current_container(ctx).open = false
	}
	if a.remove &&
	   .SUBMIT in
		   icon_button(
			   ui,
			   "remove member",
			   .Remove_Person,
			   fmt.tprintf("Remove from #%s", a.name),
			   theme.error,
		   ) {
		command(ui, conn.Conv_Member_Command{conv = a.conv, account = account, on = false})
		mu.get_current_container(ctx).open = false
	}
}

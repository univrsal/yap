package client

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
//     makes them an admin, or with Manage_Channels no longer one, and
//     removes them from a private channel.
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
	submit |= .SUBMIT in stable_button(ctx, "save", "Save" if changed else "Saved", {.ALIGN_CENTER})
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

// channel_member_items is the part of a member's menu for managing the
// channel being looked at: making them an admin or no longer one, and
// removing them from a private channel. Only for its admins and those who
// manage channels, and only once the members list says they are a member.
// Call with the View locked, inside the menu.
channel_member_items :: proc(ui: ^UI, account: proto.Account_Id, menu_width: i32) {
	ctx := &ui.ctx
	v := ui.view
	ch := viewed_channel(v)
	if ch == nil || !may_admin_channel(v, ch^) || v.members.conv != ch.id {
		return
	}
	member, admin := false, false
	for a in v.members.accounts {
		member ||= a == account
	}
	for a in v.members.admins {
		admin ||= a == account
	}
	acc, known := v.accounts[account]
	if !member || !known {
		return
	}
	manage := .Manage_Channels in v.permissions
	// Only those who manage channels make an admin no longer one (admins
	// stop being one themselves, in the channel's menu).
	toggle := !admin || manage
	remove := ch.private && !ch.home && below_us(v, acc)
	if !toggle && !remove {
		return
	}
	mu.layout_row(ctx, {menu_width})
	dim_label(ctx, ch.name)
	if toggle &&
	   .SUBMIT in
		   stable_button(ctx, "channel admin", "No longer its admin" if admin else "Make channel admin") {
		command(ui, conn.Conv_Admin_Command{conv = ch.id, account = account, on = !admin})
		mu.get_current_container(ctx).open = false
	}
	if remove && .SUBMIT in stable_button(ctx, "remove member", "Remove from the channel") {
		command(ui, conn.Conv_Member_Command{conv = ch.id, account = account, on = false})
		mu.get_current_container(ctx).open = false
	}
}

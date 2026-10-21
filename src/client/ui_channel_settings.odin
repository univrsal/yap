package client

import "core:fmt"
import "core:slice"
import "core:strings"
import mu "vendor:microui"

import "client:conn"
import "common:proto"

// The Channels category of the settings' server tab, for users who may make
// channels (Create_Channels) or change them (Manage_Channels). Like the Roles
// category (ui_roles.odin), it is a list on the left and the channel picked
// from it on the right:
//
//   - The list is every channel there is, including the private ones we aren't
//     in (conn.All_Channels_Command), a page at a time and narrowed down by
//     name or topic, and under it the form to make a new one.
//   - The channel picked: its name and topic, its place in the lists,
//     deleting it, and for a private one, who is in it.
//
// Someone who may only make channels just gets the form.

UI_Channel_Admin :: struct {
	// The channel picked (0: none), the list's page and search, and whether the
	// list is still to turn to the page with the channel picked on it (when it
	// was picked from elsewhere).
	conv:          proto.Conv_Id,
	list:          Pager,
	reveal:        bool,
	// The name and topic being edited, and what they were when they were loaded
	// (owned). They are loaded again when the server's change.
	loaded:        proto.Conv_Id,
	loaded_name:   string,
	loaded_topic:  string,
	name_buf:      [2 * proto.MAX_CHANNEL_NAME_SIZE]u8,
	name_len:      int,
	topic_buf:     [proto.MAX_TOPIC_SIZE]u8,
	topic_len:     int,
	confirm:       bool, // Delete was pressed once
	// Who is in a private channel, and adding someone to it.
	members:       Pager,
	adding:        Pager,
	// Making a channel.
	new_name_buf:  [2 * proto.MAX_CHANNEL_NAME_SIZE]u8,
	new_name_len:  int,
	new_topic_buf: [proto.MAX_TOPIC_SIZE]u8,
	new_topic_len: int,
	new_private:   bool,
	// A notice that the server sent before the category was picked isn't
	// about anything requested in it (conn.View_Notice.count).
	notice_seen:   int,
}

@(private = "file")
LIST_WIDTH :: 190
@(private = "file")
EDITOR_MIN :: 320
@(private = "file")
LABEL :: 60

ui_channel_admin_destroy :: proc(ui: ^UI) {
	a := &ui.channel_admin
	delete(a.loaded_name)
	delete(a.loaded_topic)
	a.loaded_name, a.loaded_topic = "", ""
}

@(private = "file")
command :: proc(ui: ^UI, cmd: conn.Command) {
	if ui.session != nil {
		conn.push_command(&ui.session.client.commands, cmd)
	}
}

// channels_category_opened is called when the category has just been picked:
// the channels are fetched again, since the server only tells us about changes
// to the ones we're in.
channels_category_opened :: proc(ui: ^UI) {
	ui.channel_admin.notice_seen = -1 // taken from the View when it's next locked
	command(ui, conn.All_Channels_Command{})
}

// open_channel_settings shows the Channels category of the settings with a
// channel picked, for its menu's Settings... (channel_menu).
open_channel_settings :: proc(ui: ^UI, conv: proto.Conv_Id) {
	open_settings(ui)
	ui.settings_tab = .Server
	ui.settings_server = .Channels
	ui.settings_list = false
	a := &ui.channel_admin
	a.conv, a.loaded = conv, 0
	a.list.find_len = 0
	a.reveal = conv != 0
	channels_category_opened(ui)
}

// channels_settings is the category. Call with the View locked.
channels_settings :: proc(ui: ^UI) {
	a := &ui.channel_admin
	ctx := &ui.ctx
	v := ui.view
	if a.notice_seen < 0 {
		a.notice_seen = v.notice.count
	}
	if .Manage_Channels not_in v.permissions {
		if .Create_Channels in v.permissions {
			new_channel(ui)
		}
		return
	}

	// A channel that is gone takes the right-hand side with it, once the list
	// has arrived (it is empty before that).
	picked := channel_of(v, a.conv)
	if picked == nil && v.all_channels_count > 0 && len(v.all_channels) > 0 {
		a.conv = 0
	}

	// When narrow, the list and the picked channel take turns, as the roles do.
	if row_room(ctx) < LIST_WIDTH + EDITOR_MIN {
		if picked == nil {
			mu.layout_row(ctx, {-1}, -1)
			mu.begin_panel(ctx, "channel list")
			channel_admin_list(ui)
			mu.end_panel(ctx)
			return
		}
		mu.layout_row(ctx, {40, -1})
		if .SUBMIT in stable_button_hint(ui, "to channel list", "<", "Channels", {.ALIGN_CENTER}) {
			a.conv = 0
			a.confirm = false
		}
		mu.label(ctx, picked.name)
		mu.layout_row(ctx, {-1}, -1)
		mu.begin_panel(ctx, "channel")
		channel_editor(ui, picked^)
		mu.end_panel(ctx)
		return
	}

	mu.layout_row(ctx, {LIST_WIDTH, -1}, -1)
	mu.begin_panel(ctx, "channel list")
	channel_admin_list(ui)
	mu.end_panel(ctx)
	mu.begin_panel(ctx, "channel")
	if picked != nil {
		channel_editor(ui, picked^)
	} else {
		mu.layout_row(ctx, {-1})
		with_text_color(ctx, theme.dim, "Pick a channel to see and change it.", label_proc)
		channel_admin_notice(ui)
	}
	mu.end_panel(ctx)
}

@(private = "file")
channel_of :: proc(v: ^conn.View, id: proto.Conv_Id) -> ^conn.Browse_Entry {
	if id == 0 {
		return nil
	}
	for &e in v.all_channels {
		if e.id == id {
			return &e
		}
	}
	return nil
}

// channel_admin_list is the left-hand side: the channels that match the search,
// a page of them, and making a new one.
@(private = "file")
channel_admin_list :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := ui.view
	a := &ui.channel_admin

	pager_search(ui, &a.list, "Find a channel")
	query := pager_query(&a.list)
	shown := make([dynamic]int, 0, len(v.all_channels), context.temp_allocator)
	for e, i in v.all_channels {
		if pager_matches(query, e.name, e.topic) {
			append(&shown, i)
		}
	}
	if len(shown) == 0 {
		mu.layout_row(ctx, {-1})
		text := "No channel has that in its name or topic."
		if v.all_channels_count == 0 {
			text = "Asking the server..."
		} else if query == "" {
			text = "There are no channels."
		}
		with_text_color(ctx, theme.dim, text, wrap_text)
	}
	if a.reveal && v.all_channels_count > 0 {
		a.reveal = false
		for i, at in shown {
			if v.all_channels[i].id == a.conv {
				pager_page_of(&a.list, at)
			}
		}
	}
	lo, hi := pager_window(&a.list, len(shown))
	for i in shown[lo:hi] {
		e := v.all_channels[i]
		mu.push_id(ctx, uintptr(e.id))
		defer mu.pop_id(ctx)
		mu.layout_row(ctx, {-1})
		label := fmt.tprintf("%s%s", e.name, " 🔒" if .Private in e.flags else "")
		saved := ctx.style.colors[.TEXT]
		if !e.member {
			// Ours to manage, but not one we're in.
			ctx.style.colors[.TEXT] = theme.dim
		}
		if .SUBMIT in list_row(ctx, "channel", label, a.conv == e.id) {
			a.conv = e.id
			a.confirm = false
		}
		ctx.style.colors[.TEXT] = saved
	}
	pager_footer(ui, &a.list, len(shown))

	if .Create_Channels in v.permissions {
		mu.layout_row(ctx, {-1})
		mu.label(ctx, "")
		new_channel(ui)
	}
}

// new_channel is the form for making a channel: its name, its topic and whether
// it is private.
@(private = "file")
new_channel :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := ui.view
	a := &ui.channel_admin
	mu.layout_row(ctx, {-1})
	with_text_color(ctx, theme.dim, "New channel", label_proc)
	field_row(ui, LABEL, "Name", {-1})
	submit := .SUBMIT in text_box(ui, a.new_name_buf[:], &a.new_name_len)
	field_row(ui, LABEL, "Topic", {-1})
	submit |= .SUBMIT in text_box(ui, a.new_topic_buf[:], &a.new_topic_len)
	mu.layout_row(ctx, {-1})
	mu.checkbox(ctx, "Private", &a.new_private)
	if a.new_private {
		with_text_color(ctx, theme.dim, "Only those added to it can see it.", wrap_text)
	}
	mu.layout_row(ctx, {120})
	submit |= .SUBMIT in stable_button(ctx, "make channel", "Make channel", {.ALIGN_CENTER})
	if submit && a.new_name_len > 0 {
		command(
			ui,
			conn.Create_Channel_Command {
				name = strings.clone(string(a.new_name_buf[:a.new_name_len])),
				topic = strings.clone(string(a.new_topic_buf[:a.new_topic_len])),
				private = a.new_private,
			},
		)
		a.new_name_len, a.new_topic_len = 0, 0
		a.new_private = false
	}
	if .Manage_Channels not_in v.permissions {
		channel_admin_notice(ui)
	}
}

// channel_editor is the right-hand side for the channel picked.
@(private = "file")
channel_editor :: proc(ui: ^UI, ch: conn.Browse_Entry) {
	ctx := &ui.ctx
	a := &ui.channel_admin
	home := .Home in ch.flags
	private := .Private in ch.flags
	if a.loaded != ch.id || a.loaded_name != ch.name || a.loaded_topic != ch.topic {
		if a.loaded != ch.id {
			a.confirm = false
			a.members.page, a.adding.find_len = 0, 0
			if private {
				command(ui, conn.Members_Command{conv = ch.id})
			}
		}
		a.loaded = ch.id
		delete(a.loaded_name)
		delete(a.loaded_topic)
		a.loaded_name, a.loaded_topic = strings.clone(ch.name), strings.clone(ch.topic)
		a.name_len = copy(a.name_buf[:], ch.name)
		a.topic_len = copy(a.topic_buf[:], ch.topic)
	}

	mu.layout_row(ctx, {-1})
	what: string
	switch {
	case home:
		what = "Everyone is in it, and it is first in the lists."
	case private && ch.member:
		what = "Private: only those added to it can see it. You're in it."
	case private:
		what = "Private: only those added to it can see it. You aren't, so you can't read it."
	case ch.member:
		what = "Anyone can join it. You're in it."
	case:
		what = "Anyone can join it. You aren't in it."
	}
	with_text_color(ctx, theme.dim, what, wrap_text)

	field_row(ui, LABEL, "Name", {-1})
	submit := .SUBMIT in text_box(ui, a.name_buf[:], &a.name_len)
	field_row(ui, LABEL, "Topic", {-1})
	submit |= .SUBMIT in text_box(ui, a.topic_buf[:], &a.topic_len)
	changed :=
		string(a.name_buf[:a.name_len]) != ch.name || string(a.topic_buf[:a.topic_len]) != ch.topic
	field_row(ui, LABEL, "", {100, -1})
	submit |=
		.SUBMIT in stable_button(ctx, "save channel", "Save" if changed else "Saved", {.ALIGN_CENTER})
	if !ch.member && !private {
		if .SUBMIT in stable_button(ctx, "join channel", "Join it", {.ALIGN_CENTER}) {
			command(ui, conn.Subscribe_Command{conv = ch.id, on = true})
		}
	} else {
		mu.label(ctx, "")
	}
	if submit && changed && a.name_len > 0 {
		command(
			ui,
			conn.Conv_Update_Command {
				conv = ch.id,
				mask = proto.CONV_UPDATE_NAME | proto.CONV_UPDATE_TOPIC,
				name = strings.clone(string(a.name_buf[:a.name_len])),
				topic = strings.clone(string(a.topic_buf[:a.topic_len])),
			},
		)
	}

	if !home {
		channel_move_buttons(ui, ch.id)
		field_row(ui, LABEL, "", {160})
		if a.confirm {
			if .SUBMIT in
			   stable_button(ctx, "delete channel", "Delete it for everyone", {.ALIGN_CENTER}) {
				command(ui, conn.Conv_Delete_Command{conv = ch.id})
				a.conv, a.confirm = 0, false
				return
			}
		} else if .SUBMIT in stable_button(ctx, "delete channel?", "Delete channel...", {.ALIGN_CENTER}) {
			a.confirm = true
		}
	}
	channel_admin_notice(ui)

	if private {
		channel_members(ui, ch)
	}
}

// channel_move_buttons move a channel up or down the lists immediately. The
// order is the whole list's, which the search would hide, so they are only
// offered while nothing is typed in it.
@(private = "file")
channel_move_buttons :: proc(ui: ^UI, id: proto.Conv_Id) {
	ctx := &ui.ctx
	v := ui.view
	a := &ui.channel_admin
	field_row(ui, LABEL, "Place", {100, 100, -1})
	if pager_query(&a.list) != "" {
		mu.label(ctx, "")
		mu.label(ctx, "")
		with_text_color(ctx, theme.dim, "Clear the search to move it.", label_proc)
		return
	}
	at := -1
	for e, i in v.all_channels {
		if e.id == id {
			at = i
		}
	}
	// The home channel is always first, so nothing goes above it.
	first := 1 if len(v.all_channels) > 0 && .Home in v.all_channels[0].flags else 0
	up := false
	if at > first {
		up = .SUBMIT in stable_button(ctx, "move up", "Move up", {.ALIGN_CENTER})
	} else {
		mu.label(ctx, "")
	}
	down := false
	if at >= first && at < len(v.all_channels) - 1 {
		down = .SUBMIT in stable_button(ctx, "move down", "Move down", {.ALIGN_CENTER})
	} else {
		mu.label(ctx, "")
	}
	mu.label(ctx, "")
	if !up && !down {
		return
	}
	other := at - 1 if up else at + 1
	order := make([]proto.Conv_Id, len(v.all_channels), context.temp_allocator)
	for e, i in v.all_channels {
		order[i] = e.id
	}
	order[at], order[other] = order[other], order[at]
	// Number them all in the new order, so that the ones that had the same
	// number (as new channels do) get one each. Only those whose number
	// changes are sent.
	for e in v.all_channels {
		if .Home in e.flags {
			continue
		}
		for o, i in order {
			if o == e.id && e.position != i {
				command(
					ui,
					conn.Conv_Update_Command {
						conv = e.id,
						mask = proto.CONV_UPDATE_POSITION,
						position = i,
					},
				)
			}
		}
	}
	// Stay on the page that shows it.
	pager_page_of(&a.list, other)
}

// channel_members is who is in a private channel, with a way to take them out
// and, for those in it who may add people, to add more.
@(private = "file")
channel_members :: proc(ui: ^UI, ch: conn.Browse_Entry) {
	ctx := &ui.ctx
	v := ui.view
	a := &ui.channel_admin
	mu.layout_row(ctx, {-1})
	mu.label(ctx, "")
	mu.label(ctx, "Who is in it")
	if v.members.conv != ch.id || v.members.loading {
		with_text_color(ctx, theme.dim, "  Asking the server...", label_proc)
		return
	}
	allowed := make([]bool, len(v.members.accounts), context.temp_allocator)
	for id, i in v.members.accounts {
		acc := v.accounts[id] or_else {}
		allowed[i] = id != v.me && below_us(v, acc)
	}
	if out := people_list(ui, &a.members, v.members.accounts[:], "Take out", allowed);
	   out != 0 {
		command(ui, conn.Conv_Member_Command{conv = ch.id, account = out, on = false})
	}

	// The server only lets those in the channel add people to it.
	if .Invite not_in v.permissions || !ch.member {
		return
	}
	mu.layout_row(ctx, {-1})
	mu.label(ctx, "")
	mu.label(ctx, "Add someone")
	others := make([dynamic]proto.Account_Id, context.temp_allocator)
	for id, acc in v.accounts {
		if acc.flags & {.Disabled, .Deleted} == {} && !slice.contains(v.members.accounts[:], id) {
			append(&others, id)
		}
	}
	if add := people_finder(ui, &a.adding, others[:], "Add"); add != 0 {
		command(ui, conn.Conv_Member_Command{conv = ch.id, account = add, on = true})
	}
}

// channel_admin_notice is what the server last said about something requested
// in the category, such as a refusal.
@(private = "file")
channel_admin_notice :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := ui.view
	if v.notice.text == "" || v.notice.count <= ui.channel_admin.notice_seen {
		return
	}
	mu.layout_row(ctx, {-1})
	with_text_color(ctx, theme.notice_ok if v.notice.ok else theme.error, v.notice.text, wrap_text)
}

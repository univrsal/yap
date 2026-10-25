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
	loaded_flags:  proto.Conv_Flags,
	name_buf:      [2 * proto.MAX_CHANNEL_NAME_SIZE]u8,
	name_len:      int,
	topic_buf:     [proto.MAX_TOPIC_SIZE]u8,
	topic_len:     int,
	// Its Default and Text_Only being edited.
	is_default:    bool,
	text_only:     bool,
	confirm:       bool, // Delete was pressed once
	// Its rights map being edited: a row per role, in the order of View.roles
	// when it was loaded, and a box per right (see channel_rights). Loaded
	// again when the map arrives (rights_count) or the roles change.
	rows:          [proto.MAX_ROLES]proto.Role_Id,
	row_count:     int,
	cells:         [proto.MAX_ROLES][len(proto.Conv_Right)]bool,
	rights_count:  int,
	// Who is in a private channel, and adding someone to it.
	members:       Pager,
	adding:        Pager,
	// Making a channel.
	new_name_buf:  [2 * proto.MAX_CHANNEL_NAME_SIZE]u8,
	new_name_len:  int,
	new_topic_buf: [proto.MAX_TOPIC_SIZE]u8,
	new_topic_len: int,
	new_private:   bool,
	new_default:   bool,
	new_text_only: bool,
	notice:        Notice_Mark,
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

// channels_category_opened is called when the category has just been picked:
// the channels are fetched again, since the server only tells us about changes
// to the ones we're in.
channels_category_opened :: proc(ui: ^UI) {
	notice_mark_reset(&ui.channel_admin.notice)
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
	v := ui.view
	notice_mark_update(&a.notice, v)
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

	list_detail(ui, {
		name = "channel",
		list_width = LIST_WIDTH,
		detail_min = EDITOR_MIN,
		picked = picked != nil,
		title = picked.name if picked != nil else "",
		back_hint = "Channels",
		list = channel_admin_list,
		detail = channel_detail,
		back = proc(ui: ^UI) {
			ui.channel_admin.conv = 0
			ui.channel_admin.confirm = false
		},
	})
}

// channel_detail is the picked channel's side of the category, or what to do
// with none picked.
@(private = "file")
channel_detail :: proc(ui: ^UI) {
	if picked := channel_of(ui.view, ui.channel_admin.conv); picked != nil {
		channel_editor(ui, picked^)
		return
	}
	mu.layout_row(&ui.ctx, {-1})
	with_text_color(&ui.ctx, theme.dim, "Pick a channel to see and change it.", label_proc)
	notice_row(ui, ui.channel_admin.notice, ui.view)
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
		label := fmt.tprintf(
			"%s%s%s",
			e.name,
			" 🔒" if .Private in e.flags else "",
			" ⭐" if .Default in e.flags else "",
		)
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

// new_channel is the form for making a channel: its name, its topic, whether
// it is private or default, and whether it is text only.
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
	checkbox(ctx, "Private", &a.new_private)
	if a.new_private {
		with_text_color(ctx, theme.dim, "Only those added to it can see it.", wrap_text)
		a.new_default = false // the server refuses a private default channel
	} else {
		mu.layout_row(ctx, {-1})
		checkbox(ctx, "Default", &a.new_default)
		if a.new_default {
			with_text_color(ctx, theme.dim, "New members join it. They can leave.", wrap_text)
		}
	}
	mu.layout_row(ctx, {-1})
	checkbox(ctx, "Text only", &a.new_text_only)
	if a.new_text_only {
		with_text_color(ctx, theme.dim, "It has no voice room.", wrap_text)
	}
	mu.layout_row(ctx, {120})
	submit |= .SUBMIT in stable_button(ctx, "make channel", "Make channel", {.ALIGN_CENTER})
	if submit && a.new_name_len > 0 {
		flags: proto.Conv_Flags
		if a.new_default {
			flags += {.Default}
		}
		if a.new_text_only {
			flags += {.Text_Only}
		}
		command(
			ui,
			conn.Create_Channel_Command {
				name = strings.clone(string(a.new_name_buf[:a.new_name_len])),
				topic = strings.clone(string(a.new_topic_buf[:a.new_topic_len])),
				private = a.new_private,
				flags = flags,
			},
		)
		a.new_name_len, a.new_topic_len = 0, 0
		a.new_private, a.new_default, a.new_text_only = false, false, false
	}
	if .Manage_Channels not_in v.permissions {
		notice_row(ui, ui.channel_admin.notice, ui.view)
	}
}

// channel_editor is the right-hand side for the channel picked.
@(private = "file")
channel_editor :: proc(ui: ^UI, ch: conn.Browse_Entry) {
	ctx := &ui.ctx
	a := &ui.channel_admin
	home := .Home in ch.flags
	private := .Private in ch.flags
	settable := ch.flags & proto.CONV_SETTABLE_FLAGS
	if a.loaded != ch.id ||
	   a.loaded_name != ch.name ||
	   a.loaded_topic != ch.topic ||
	   a.loaded_flags != settable {
		if a.loaded != ch.id {
			a.confirm = false
			a.members.page, a.adding.find_len = 0, 0
			if private {
				command(ui, conn.Members_Command{conv = ch.id})
			}
			a.row_count, a.rights_count = 0, -1
			command(ui, conn.Conv_Rights_Get_Command{conv = ch.id})
		}
		a.loaded = ch.id
		delete(a.loaded_name)
		delete(a.loaded_topic)
		a.loaded_name, a.loaded_topic = strings.clone(ch.name), strings.clone(ch.topic)
		a.name_len = copy(a.name_buf[:], ch.name)
		a.topic_len = copy(a.topic_buf[:], ch.topic)
		a.loaded_flags = settable
		a.is_default = .Default in settable
		a.text_only = .Text_Only in settable
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
	if .Default in ch.flags {
		what = fmt.tprintf("%s New members join it, and can leave.", what)
	}
	if .Text_Only in ch.flags {
		what = fmt.tprintf("%s It has no voice room.", what)
	}
	with_text_color(ctx, theme.dim, what, wrap_text)

	field_row(ui, LABEL, "Name", {-1})
	submit := .SUBMIT in text_box(ui, a.name_buf[:], &a.name_len)
	field_row(ui, LABEL, "Topic", {-1})
	submit |= .SUBMIT in text_box(ui, a.topic_buf[:], &a.topic_len)
	// Only a channel that anyone could join can be default, and the home
	// channel is more than that.
	if !home && !private {
		field_row(ui, LABEL, "", {-1})
		checkbox(ctx, "Default: new members join it", &a.is_default)
	}
	field_row(ui, LABEL, "", {-1})
	checkbox(ctx, "Text only: no voice room", &a.text_only)
	flags: proto.Conv_Flags
	if a.is_default {
		flags += {.Default}
	}
	if a.text_only {
		flags += {.Text_Only}
	}
	changed :=
		string(a.name_buf[:a.name_len]) != ch.name ||
		string(a.topic_buf[:a.topic_len]) != ch.topic ||
		flags != settable
	field_row(ui, LABEL, "", {100, -1})
	submit |=
		.SUBMIT in
		stable_button(ctx, "save channel", "Save" if changed else "Saved", {.ALIGN_CENTER})
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
				mask = proto.CONV_UPDATE_NAME | proto.CONV_UPDATE_TOPIC | proto.CONV_UPDATE_FLAGS,
				name = strings.clone(string(a.name_buf[:a.name_len])),
				topic = strings.clone(string(a.topic_buf[:a.topic_len])),
				flags = flags,
			},
		)
	}

	if !home {
		channel_move_buttons(ui, ch.id)
		field_row(ui, LABEL, "", {160})
		if confirm_button(
			ctx,
			&a.confirm,
			"delete channel",
			"Delete channel...",
			"Delete it for everyone",
		) {
			command(ui, conn.Conv_Delete_Command{conv = ch.id})
			a.conv = 0
			return
		}
	}
	notice_row(ui, ui.channel_admin.notice, ui.view)
	channel_rights(ui, ch, a.text_only)

	if private {
		channel_members(ui, ch)
	}
}

// The grid's columns, by right, in the order they are shown, and how wide each
// is when there is room for all of them in a row.
@(private = "file")
RIGHT_LABELS := [proto.Conv_Right]string {
	.See    = "See",
	.Write  = "Write",
	.Attach = "Attach",
	.React  = "React",
	.Edit   = "Edit",
	.Delete = "Delete",
	.Voice  = "Voice",
}
@(private = "file")
RIGHT_ORDER := [?]proto.Conv_Right{.See, .Write, .Attach, .React, .Edit, .Delete, .Voice}
@(private = "file")
RIGHT_COLUMN :: 58
@(private = "file")
ROLE_COLUMN_MIN :: 110

// channel_rights is the channel's rights map: what each role may do there, as
// a grid of a row per role (everyone last) and a box per right, with its own
// Save. A box whose right needs another that its row lacks (Edit, Delete and
// Attach need Write, everything needs See) is dimmer; it still counts, since the
// account may have the other right through another role. The Voice column is
// left out for a text-only channel, and everyone always sees the home channel.
@(private = "file")
channel_rights :: proc(ui: ^UI, ch: conn.Browse_Entry, text_only: bool) {
	ctx := &ui.ctx
	v := ui.view
	a := &ui.channel_admin
	home := .Home in ch.flags
	mu.layout_row(ctx, {-1})
	mu.label(ctx, "")
	mu.label(ctx, "What each role may do here")
	m := &v.rights_map
	if m.conv != ch.id || m.loading {
		with_text_color(ctx, theme.dim, "  Asking the server...", label_proc)
		return
	}
	if a.rights_count != m.count || a.row_count != len(v.roles) {
		rights_load(ui, m)
	}
	if home {
		a.cells[a.row_count - 1][proto.Conv_Right.See] = true // everyone, last
	}

	shown := make([dynamic]proto.Conv_Right, 0, len(proto.Conv_Right), context.temp_allocator)
	for r in RIGHT_ORDER {
		if r != .Voice || !text_only {
			append(&shown, r)
		}
	}
	wide := row_room(ctx) >= ROLE_COLUMN_MIN + i32(len(shown)) * RIGHT_COLUMN
	widths := make([]i32, len(shown) + 1, context.temp_allocator)
	widths[0] = -(i32(len(shown)) * (RIGHT_COLUMN + ctx.style.spacing) + 1)
	for &w in widths[1:] {
		w = RIGHT_COLUMN
	}
	if wide {
		mu.layout_row(ctx, widths)
		mu.label(ctx, "")
		for r in shown {
			with_text_color(ctx, theme.dim, RIGHT_LABELS[r], label_proc)
		}
	}
	for i in 0 ..< a.row_count {
		role := a.rows[i]
		name := "?"
		for r in v.roles {
			if r.id == role {
				name = r.name
			}
		}
		mu.push_id(ctx, uintptr(role))
		defer mu.pop_id(ctx)
		row := &a.cells[i]
		if wide {
			mu.layout_row(ctx, widths)
			mu.label(ctx, name)
		} else {
			mu.layout_row(ctx, {-1})
			mu.label(ctx, name)
		}
		for r, at in shown {
			if !wide && at % 3 == 0 {
				mu.layout_row(ctx, {16, 90, 90, 90})
				mu.label(ctx, "")
			}
			needs := !row[proto.Conv_Right.See] && r != .See
			needs |= (r == .Edit || r == .Delete || r == .Attach) && !row[proto.Conv_Right.Write]
			fixed := home && role == proto.EVERYONE_ROLE && r == .See
			saved := ctx.style.colors[.TEXT]
			if needs || fixed {
				ctx.style.colors[.TEXT] = theme.dim
			}
			checkbox(ctx, "" if wide else RIGHT_LABELS[r], &row[r])
			ctx.style.colors[.TEXT] = saved
			if fixed {
				row[r] = true
			}
		}
	}

	entries := rights_entries(ui)
	everyone := proto.conv_rights_settle(
		rights_of(entries, proto.EVERYONE_ROLE),
		ch.flags + ({.Text_Only} if text_only else {}),
	)
	mu.layout_row(ctx, {-1})
	with_text_color(
		ctx,
		theme.dim,
		fmt.tprintf(
			"People with no role can: %s. Users with the 'manage channels' have access to all permissions.",
			conn.rights_text(everyone),
		),
		wrap_text,
	)
	changed := len(entries) != len(m.entries)
	for e in entries {
		if rights_of(m.entries[:], e.role) != e.rights || !rights_has(m.entries[:], e.role) {
			changed = true
		}
	}
	field_row(ui, LABEL, "", {120})
	if .SUBMIT in
		   stable_button(
			   ctx,
			   "save rights",
			   "Save rights" if changed else "Saved",
			   {.ALIGN_CENTER},
		   ) &&
	   changed {
		command(ui, conn.Conv_Rights_Set_Command{conv = ch.id, entries = slice.clone(entries)})
	}
}

// rights_load fills the grid from the rights map that arrived, with a row for
// each of the roles there are now.
@(private = "file")
rights_load :: proc(ui: ^UI, m: ^conn.View_Rights_Map) {
	v := ui.view
	a := &ui.channel_admin
	a.rights_count = m.count
	a.row_count = min(len(v.roles), proto.MAX_ROLES)
	for r, i in v.roles[:a.row_count] {
		a.rows[i] = r.id
		rights := rights_of(m.entries[:], r.id)
		for right in proto.Conv_Right {
			a.cells[i][right] = right in rights
		}
	}
}

// rights_entries is the grid as a rights map: every role that has a right
// there, and everyone whatever it has. Allocated with the temp allocator.
@(private = "file")
rights_entries :: proc(ui: ^UI) -> []proto.Role_Rights {
	a := &ui.channel_admin
	entries := make([dynamic]proto.Role_Rights, 0, a.row_count, context.temp_allocator)
	for i in 0 ..< a.row_count {
		rights: proto.Conv_Rights
		for right in proto.Conv_Right {
			if a.cells[i][right] {
				rights += {right}
			}
		}
		if rights != {} || a.rows[i] == proto.EVERYONE_ROLE {
			append(&entries, proto.Role_Rights{a.rows[i], rights})
		}
	}
	return entries[:]
}

@(private = "file")
rights_of :: proc(entries: []proto.Role_Rights, role: proto.Role_Id) -> proto.Conv_Rights {
	for e in entries {
		if e.role == role {
			return e.rights
		}
	}
	return {}
}

@(private = "file")
rights_has :: proc(entries: []proto.Role_Rights, role: proto.Role_Id) -> bool {
	for e in entries {
		if e.role == role {
			return true
		}
	}
	return false
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
	if out := people_list(ui, &a.members, v.members.accounts[:], "Take out", allowed); out != 0 {
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
	if add := people_finder(ui, &a.adding, others[:], "Add", .Plus); add != 0 {
		command(ui, conn.Conv_Member_Command{conv = ch.id, account = add, on = true})
	}
}

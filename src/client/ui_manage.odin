package client

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import mu "vendor:microui"

import "client:conn"
import "common:proto"

/*
Managing the server, for those who may (conn/roles.odin). Everything is
offered only to whoever has the permission it takes; the server checks
again.

  - A channel's settings, in the Channels window: its name, topic and
    place in the list, and deleting it (Manage_Channels); and for a
    private one, taking people out of it.
  - Adding people to a channel, in the members window (Invite, and being
    in it).
  - The roles, in their own window (ui_roles.odin).
  - Accounts, in the settings: their roles (Manage_Roles), and disabling
    or deleting them (Manage_Accounts).
  - Purging, in the settings (Purge): a conversation's messages, or
    every one's, or only their pictures, from before so many days ago,
    once it's been confirmed.
*/

UI_Manage :: struct {
	// The channel whose settings are open in the Channels window, and
	// its name and topic as they're being edited.
	conv:           proto.Conv_Id,
	loaded:         proto.Conv_Id,
	// What the server said they were when they were loaded: loaded again
	// when that changes.
	loaded_name:    string, // owned
	loaded_topic:   string, // owned
	name_buf:       [2 * proto.MAX_CHANNEL_NAME_SIZE]u8,
	name_len:       int,
	topic_buf:      [proto.MAX_TOPIC_SIZE]u8,
	topic_len:      int,
	confirm:        bool, // Delete was pressed once
	private:        bool, // making a private channel
	// The members window's list of people to add, open.
	adding:         bool,
	// The account whose roles are being chosen (0: none), and which.
	account:        proto.Account_Id,
	account_roles:  [dynamic]proto.Role_Id,
	// The account Delete... was pressed for (0: none).
	delete_account: proto.Account_Id,
	// The purge being set up: which conversation (0: all), how many days
	// back, only pictures, and Purge pressed once.
	purge_conv:     proto.Conv_Id,
	purge_days_buf: [6]u8,
	purge_days_len: int,
	purge_pictures: bool,
	purge_confirm:  bool,
}

ui_manage_destroy :: proc(ui: ^UI) {
	m := &ui.manage
	delete(m.account_roles)
	delete(m.loaded_name)
	delete(m.loaded_topic)
	m.account_roles, m.loaded_name, m.loaded_topic = nil, "", ""
}

@(private = "file")
command :: proc(ui: ^UI, cmd: conn.Command) {
	if ui.session != nil {
		conn.push_command(&ui.session.client.commands, cmd)
	}
}

/*
channel_settings is the Channels window's part for the channel picked
with Manage: its name, topic and place, deleting it, and for a private
one, taking people out. Call with the View locked.
*/
channel_settings :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := ui.view
	m := &ui.manage
	if m.conv == 0 || .Manage_Channels not_in v.permissions {
		return
	}
	index := -1
	for ch, i in v.channels {
		if ch.id == m.conv {
			index = i
		}
	}
	if index < 0 {
		m.conv = 0 // gone
		return
	}
	ch := v.channels[index]
	if m.loaded != ch.id || m.loaded_name != ch.name || m.loaded_topic != ch.topic {
		if m.loaded != ch.id && ch.private {
			command(ui, conn.Members_Command{conv = ch.id})
		}
		m.loaded = ch.id
		delete(m.loaded_name)
		delete(m.loaded_topic)
		m.loaded_name, m.loaded_topic = strings.clone(ch.name), strings.clone(ch.topic)
		m.name_len = copy(m.name_buf[:], ch.name)
		m.topic_len = copy(m.topic_buf[:], ch.topic)
		m.confirm = false
	}

	mu.layout_row(ctx, {-1})
	mu.label(ctx, "")
	mu.label(ctx, fmt.tprintf("Settings of #%s%s", ch.name, "  (private)" if ch.private else ""))
	mu.layout_row(ctx, {60, -1})
	mu.label(ctx, "Name")
	submit := .SUBMIT in text_box(ui, m.name_buf[:], &m.name_len)
	mu.label(ctx, "Topic")
	submit |= .SUBMIT in text_box(ui, m.topic_buf[:], &m.topic_len)
	mu.layout_row(ctx, {60, 90, 90, 90, -1})
	mu.label(ctx, "")
	submit |= .SUBMIT in stable_button(ctx, "save channel", "Save", {.ALIGN_CENTER})
	up := index > 1 && .SUBMIT in stable_button(ctx, "move up", "Move up", {.ALIGN_CENTER})
	if index <= 1 {
		mu.label(ctx, "")
	}
	down :=
		index > 0 &&
		index < len(v.channels) - 1 &&
		.SUBMIT in stable_button(ctx, "move down", "Move down", {.ALIGN_CENTER})
	if index == 0 || index == len(v.channels) - 1 {
		mu.label(ctx, "")
	}
	if !ch.home {
		if m.confirm {
			if .SUBMIT in
			   stable_button(ctx, "delete channel", "Delete it for everyone", {.ALIGN_CENTER}) {
				command(ui, conn.Conv_Delete_Command{conv = ch.id})
				m.conv, m.confirm = 0, false
				return
			}
		} else if .SUBMIT in stable_button(ctx, "delete channel?", "Delete...", {.ALIGN_CENTER}) {
			m.confirm = true
		}
	}
	if submit && m.name_len > 0 {
		command(
			ui,
			conn.Conv_Update_Command {
				conv = ch.id,
				mask = proto.CONV_UPDATE_NAME | proto.CONV_UPDATE_TOPIC,
				name = strings.clone(string(m.name_buf[:m.name_len])),
				topic = strings.clone(string(m.topic_buf[:m.topic_len])),
			},
		)
	}
	if up || down {
		// Every channel of ours numbered again in its new order (the home
		// channel stays first whatever its number).
		order := make([dynamic]proto.Conv_Id, 0, len(v.channels), context.temp_allocator)
		for c in v.channels {
			append(&order, c.id)
		}
		other := index - 1 if up else index + 1
		order[index], order[other] = order[other], order[index]
		for id, i in order {
			for c in v.channels {
				if c.id == id && c.position != i && !c.home {
					command(
						ui,
						conn.Conv_Update_Command {
							conv = id,
							mask = proto.CONV_UPDATE_POSITION,
							position = i,
						},
					)
				}
			}
		}
	}

	// Who is in a private one, and taking them out.
	if !ch.private {
		return
	}
	mu.layout_row(ctx, {-1})
	with_text_color(ctx, DIM_COLOR, "Who is in it:", label_proc)
	if v.members.conv != ch.id {
		with_text_color(ctx, DIM_COLOR, "  Loading...", label_proc)
		return
	}
	for account in v.members.accounts {
		mu.push_id(ctx, uintptr(account))
		defer mu.pop_id(ctx)
		mu.layout_row(ctx, {-100, 90})
		acc := v.accounts[account] or_else {}
		mu.label(ctx, fmt.tprintf("  %s", acc.display if acc.display != "" else "someone"))
		if account == v.me || !below_us(v, acc) {
			mu.label(ctx, "")
		} else if .SUBMIT in stable_button(ctx, "remove", "Take out", {.ALIGN_CENTER}) {
			command(ui, conn.Conv_Member_Command{conv = ch.id, account = account, on = false})
		}
	}
}

/*
add_people is the members window's list of those who could be added to
the conversation, for whoever may: everyone who isn't in it yet. Call
with the View locked.
*/
add_people :: proc(ui: ^UI, members: []proto.Account_Id) {
	ctx := &ui.ctx
	v := ui.view
	m := &ui.manage
	if .Invite not_in v.permissions || !is_channel(v, v.viewing) {
		return
	}
	mu.layout_row(ctx, {-1})
	if .SUBMIT in
	   stable_button(ctx, "add people", "Hide" if m.adding else "Add people...", {.ALIGN_CENTER}) {
		m.adding = !m.adding
	}
	if !m.adding {
		return
	}
	ids, _ := slice.map_keys(v.accounts, context.temp_allocator)
	slice.sort_by(ids, proc(a, b: proto.Account_Id) -> bool {return a < b})
	any := false
	for id in ids {
		acc := v.accounts[id]
		if slice.contains(members, id) || acc.flags & {.Disabled, .Deleted} != {} {
			continue
		}
		any = true
		mu.push_id(ctx, uintptr(id))
		defer mu.pop_id(ctx)
		mu.layout_row(ctx, {-70, 60})
		mu.label(ctx, fmt.tprintf("%s  @%s", acc.display, acc.username))
		if .SUBMIT in stable_button(ctx, "add", "Add", {.ALIGN_CENTER}) {
			command(ui, conn.Conv_Member_Command{conv = v.viewing, account = id, on = true})
		}
	}
	if !any {
		mu.layout_row(ctx, {-1})
		with_text_color(ctx, DIM_COLOR, "Everyone is in it.", label_proc)
	}
}

// below_us is whether an account may do no more than we may, so that we
// may manage it: what its roles allow is all ours too.
below_us :: proc(v: ^conn.View, acc: conn.View_Account) -> bool {
	if .Owner in acc.flags {
		return false
	}
	perms: proto.Permissions
	for r in v.roles {
		if r.id == proto.EVERYONE_ROLE || slice.contains(acc.roles, r.id) {
			perms += r.perms
		}
	}
	return perms <= v.permissions
}

@(private = "file")
is_channel :: proc(v: ^conn.View, conv: proto.Conv_Id) -> bool {
	for ch in v.channels {
		if ch.id == conv {
			return true
		}
	}
	return false
}

/*
account_manage is what the accounts list offers for one account, beside
its password: choosing its roles (Manage_Roles), and disabling or
deleting it (Manage_Accounts). Call with the View locked, in a row with
three cells for it.
*/
account_manage :: proc(ui: ^UI, id: proto.Account_Id, acc: conn.View_Account) {
	ctx := &ui.ctx
	v := ui.view
	m := &ui.manage
	owner := .Owner in acc.flags
	if .Manage_Roles in v.permissions && !owner {
		if .SUBMIT in stable_button(ctx, "roles", "Roles...", {.ALIGN_CENTER}) {
			if m.account == id {
				m.account = 0
			} else {
				m.account = id
				clear(&m.account_roles)
				append(&m.account_roles, ..acc.roles)
			}
		}
	} else {
		mu.label(ctx, "")
	}
	if .Manage_Accounts in v.permissions && !owner && id != v.me && below_us(v, acc) {
		disabled := .Disabled in acc.flags
		if .SUBMIT in
		   stable_button(ctx, "disable", "Enable" if disabled else "Disable", {.ALIGN_CENTER}) {
			command(ui, conn.Account_Disable_Command{account = id, on = !disabled})
		}
		if .SUBMIT in stable_button(ctx, "delete?", "Delete...", {.ALIGN_CENTER}) {
			m.delete_account = 0 if m.delete_account == id else id
		}
	} else {
		mu.label(ctx, "")
		mu.label(ctx, "")
	}
}

// account_delete_confirm asks whether the account picked with Delete...
// is to be deleted. Call with the View locked, after its row.
account_delete_confirm :: proc(ui: ^UI, id: proto.Account_Id, acc: conn.View_Account) {
	ctx := &ui.ctx
	m := &ui.manage
	if m.delete_account != id {
		return
	}
	mu.layout_row(ctx, {30, -1})
	mu.label(ctx, "")
	with_text_color(
		ctx,
		WARNING_COLOR,
		fmt.tprintf(
			"Delete %s for good? What they wrote stays, under \"%s\".",
			acc.username,
			proto.DELETED_NAME,
		),
		label_proc,
	)
	mu.layout_row(ctx, {30, 140, 100})
	mu.label(ctx, "")
	if .SUBMIT in stable_button(ctx, "delete account", "Delete for good", {.ALIGN_CENTER}) {
		command(ui, conn.Account_Delete_Command{account = id})
		m.delete_account = 0
	}
	if .SUBMIT in stable_button(ctx, "cancel delete", "Cancel", {.ALIGN_CENTER}) {
		m.delete_account = 0
	}
}

// account_roles_editor is the roles of the account picked with Roles...,
// to tick and save. Call with the View locked, after its row.
account_roles_editor :: proc(ui: ^UI, id: proto.Account_Id) {
	ctx := &ui.ctx
	v := ui.view
	m := &ui.manage
	if m.account != id {
		return
	}
	for r in v.roles {
		if r.id == proto.EVERYONE_ROLE {
			continue
		}
		mu.push_id(ctx, uintptr(r.id))
		defer mu.pop_id(ctx)
		mu.layout_row(ctx, {30, -1})
		mu.label(ctx, "")
		i, has := slice.linear_search(m.account_roles[:], r.id)
		if !(r.perms <= v.permissions) {
			with_text_color(
				ctx,
				DIM_COLOR,
				fmt.tprintf("[%s] %s (above you)", "x" if has else " ", r.name),
				label_proc,
			)
			continue
		}
		on := has
		if .CHANGE in mu.checkbox(ctx, r.name, &on) {
			if on && !has {
				append(&m.account_roles, r.id)
			} else if !on && has {
				ordered_remove(&m.account_roles, i)
			}
		}
	}
	mu.layout_row(ctx, {30, 100, 100})
	mu.label(ctx, "")
	if .SUBMIT in stable_button(ctx, "save roles", "Save", {.ALIGN_CENTER}) {
		cmd := conn.Account_Roles_Command {
			account = id,
		}
		for r in m.account_roles {
			if cmd.count < len(cmd.roles) {
				cmd.roles[cmd.count] = r
				cmd.count += 1
			}
		}
		command(ui, cmd)
		m.account = 0
	}
	if .SUBMIT in stable_button(ctx, "cancel roles", "Cancel", {.ALIGN_CENTER}) {
		m.account = 0
	}
}

/*
purge_settings is the settings' part for purging, for whoever has
Purge: which conversation (stepped through with the arrows), how old,
messages or only pictures. Nothing goes before a second press, which
says what will. Call with the View locked.
*/
purge_settings :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := ui.view
	m := &ui.manage
	if m.purge_days_len == 0 && !m.purge_confirm {
		m.purge_days_len = copy(m.purge_days_buf[:], "90")
	}

	// What there is to pick from: all, our channels, our DMs.
	choices := make([dynamic]proto.Conv_Id, context.temp_allocator)
	append(&choices, 0)
	for ch in v.channels {
		append(&choices, ch.id)
	}
	for dm in v.dms {
		append(&choices, dm.id)
	}
	at := 0
	for id, i in choices {
		if id == m.purge_conv {
			at = i
		}
	}
	m.purge_conv = choices[at]
	place := purge_place(v, m.purge_conv)

	mu.layout_row(ctx, {FORM_LABEL, 30, 220, 30})
	mu.label(ctx, "Conversation")
	if .SUBMIT in stable_button(ctx, "purge prev", "<", {.ALIGN_CENTER}) {
		m.purge_conv = choices[(at + len(choices) - 1) % len(choices)]
		m.purge_confirm = false
	}
	mu.label(ctx, place)
	if .SUBMIT in stable_button(ctx, "purge next", ">", {.ALIGN_CENTER}) {
		m.purge_conv = choices[(at + 1) % len(choices)]
		m.purge_confirm = false
	}

	mu.layout_row(ctx, {FORM_LABEL, 60, -1})
	mu.label(ctx, "Older than")
	if .CHANGE in text_box(ui, m.purge_days_buf[:], &m.purge_days_len) {
		m.purge_confirm = false
	}
	mu.label(ctx, "days")
	days, days_ok := strconv.parse_int(string(m.purge_days_buf[:m.purge_days_len]), 10)
	days_ok = days_ok && days >= 0

	mu.layout_row(ctx, {FORM_LABEL, -1})
	mu.label(ctx, "")
	if .CHANGE in mu.checkbox(ctx, "Only the pictures; the messages stay", &m.purge_pictures) {
		m.purge_confirm = false
	}

	mu.layout_row(ctx, {FORM_LABEL, 140, -1})
	mu.label(ctx, "")
	if !days_ok {
		mu.label(ctx, "")
		with_text_color(ctx, DIM_COLOR, "How many days, as a number.", label_proc)
		return
	}
	now_ms := time.time_to_unix_nano(time.now()) / 1_000_000
	before := now_ms - i64(days) * 24 * 60 * 60 * 1000
	if !m.purge_confirm {
		if .SUBMIT in stable_button(ctx, "purge", "Purge...", {.ALIGN_CENTER}) {
			m.purge_confirm = true
		}
		with_text_color(ctx, DIM_COLOR, "Asks first. Pinned messages are always kept.", label_proc)
		return
	}
	dt, _ := time.time_to_datetime(time.unix(before / 1000, 0))
	local := chat_local_time(ui, dt)
	when_text := fmt.tprintf(
		"%d-%02d-%02d %02d:%02d",
		local.year,
		local.month,
		local.day,
		local.hour,
		local.minute,
	)
	mu.label(ctx, "")
	with_text_color(
		ctx,
		{230, 90, 90, 255},
		fmt.tprintf(
			"This removes for good the %s in %s from before %s.",
			"pictures" if m.purge_pictures else "messages",
			place,
			when_text,
		),
		label_proc,
	)
	mu.layout_row(ctx, {FORM_LABEL, 140, 140})
	mu.label(ctx, "")
	if .SUBMIT in stable_button(ctx, "purge yes", "Purge them", {.ALIGN_CENTER}) {
		command(
			ui,
			conn.Purge_Command {
				conv = m.purge_conv,
				all = m.purge_conv == 0,
				before = proto.Unix_Ms(before),
				what = .Images if m.purge_pictures else .Messages,
			},
		)
		m.purge_confirm = false
	}
	if .SUBMIT in stable_button(ctx, "purge no", "Cancel", {.ALIGN_CENTER}) {
		m.purge_confirm = false
	}
}

// purge_place is how the purge form names a conversation.
@(private = "file")
purge_place :: proc(v: ^conn.View, conv: proto.Conv_Id) -> string {
	if conv == 0 {
		return "every conversation"
	}
	for ch in v.channels {
		if ch.id == conv {
			return fmt.tprintf("#%s", ch.name)
		}
	}
	for dm in v.dms {
		if dm.id == conv {
			name := "someone"
			if acc, ok := v.accounts[dm.with]; ok {
				name = acc.display
			}
			return fmt.tprintf("the DM with %s", name)
		}
	}
	return "a conversation"
}

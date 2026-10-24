package client

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import mu "vendor:microui"

import "client:conn"
import "client:render"
import "common:proto"

// Server management for users who have the required permissions
// (see conn/roles.odin). Every control is only shown to users who have the
// permission it needs, and the server checks the permission again.
//
//   - The channels, in the settings' Channels (ui_channel_settings.odin).
//   - Adding people to a channel in the members window (needs Invite and
//     membership of the channel).
//   - The roles, in the settings' Roles (ui_roles.odin).
//   - Accounts in the settings: their roles (Manage_Roles) and disabling or
//     deleting them (Manage_Accounts).
//   - Purging in the settings (Purge): the messages of one conversation or of
//     all of them, or only their pictures, older than a given number of days.
//     This needs a confirmation.

UI_Manage :: struct {
	// Whether the members window's list of people to add is open, and its
	// search.
	adding:         bool,
	add_find:       Pager,
	// The account whose roles are being edited (0: none), and its chosen roles.
	account:        proto.Account_Id,
	account_roles:  [dynamic]proto.Role_Id,
	// The account Delete... was pressed for (0: none).
	delete_account: proto.Account_Id,
	// The purge being set up: the conversation (0: all), how many days back,
	// whether only pictures are purged, and whether Purge was pressed once.
	purge_conv:     proto.Conv_Id,
	purge_days_buf: [6]u8,
	purge_days_len: int,
	purge_files:    bool,
	purge_confirm:  bool,
}

ui_manage_destroy :: proc(ui: ^UI) {
	m := &ui.manage
	delete(m.account_roles)
	m.account_roles = nil
}

// people_list is a list of accounts, a page at a time and with a box to
// narrow it down once it has more than a page (unless the caller has its own,
// `searched`), with a button labelled `action` beside each account that
// `allowed` permits (nil: all of them). With an `icon`, the button shows that
// instead, and `action` is its hint. It returns the account whose button was
// pressed, or 0.
people_list :: proc(
	ui: ^UI,
	p: ^Pager,
	ids: []proto.Account_Id,
	action: string,
	allowed: []bool = nil,
	searched := false,
	icon: Maybe(render.Icon) = nil,
) -> (
	pressed: proto.Account_Id,
) {
	ctx := &ui.ctx
	v := ui.view
	if !searched && (len(ids) > PAGE_ROWS || p.find_len > 0) {
		pager_search(ui, p, "Find someone")
	}
	query := pager_query(p)
	shown := make([dynamic]int, 0, len(ids), context.temp_allocator)
	for id, i in ids {
		acc := v.accounts[id] or_else {}
		if pager_matches(query, acc.display, acc.username) {
			append(&shown, i)
		}
	}
	people_sort(v, ids, shown[:])
	if len(shown) == 0 {
		mu.layout_row(ctx, {-1})
		with_text_color(
			ctx,
			theme.dim,
			"  Nobody." if query == "" else "  Nobody by that name.",
			label_proc,
		)
	}
	lo, hi := pager_window(p, len(shown))
	button_icon, has_icon := icon.?
	w := icon_button_w(ctx) if has_icon else 90
	for i in shown[lo:hi] {
		id := ids[i]
		mu.push_id(ctx, uintptr(id))
		defer mu.pop_id(ctx)
		mu.layout_row(ctx, {-(w + ctx.style.spacing + 1), w})
		mu.label(ctx, person_label(v, id))
		switch {
		case allowed != nil && !allowed[i]:
			mu.label(ctx, "")
		case has_icon:
			if .SUBMIT in icon_button(ui, "act", button_icon, action) {
				pressed = id
			}
		case .SUBMIT in stable_button(ctx, "act", action, {.ALIGN_CENTER}):
			pressed = id
		}
	}
	pager_footer(ui, p, len(shown))
	return
}

// people_finder is a box to find someone among `ids` by name: once something
// is typed, those who match it are listed with a button labelled `action`
// beside each (or an `icon`, with `action` as its hint, as for people_list).
// It returns the account whose button was pressed, or 0.
people_finder :: proc(
	ui: ^UI,
	p: ^Pager,
	ids: []proto.Account_Id,
	action: string,
	icon: Maybe(render.Icon) = nil,
) -> (
	pressed: proto.Account_Id,
) {
	ctx := &ui.ctx
	if len(ids) == 0 {
		mu.layout_row(ctx, {-1})
		with_text_color(ctx, theme.dim, "  Everyone is in it already.", label_proc)
		return
	}
	pager_search(ui, p, "Type a name")
	if pager_query(p) == "" {
		return
	}
	return people_list(ui, p, ids, action, searched = true, icon = icon)
}

// person_label is how an account is listed: its name and its username.
person_label :: proc(v: ^conn.View, id: proto.Account_Id) -> string {
	acc, known := v.accounts[id]
	if !known {
		return "  someone"
	}
	if acc.display == "" || acc.display == acc.username {
		return fmt.tprintf("  @%s", acc.username)
	}
	return fmt.tprintf("  %s  @%s", acc.display, acc.username)
}

// people_sort sorts `shown`, indices into `ids`, by name.
@(private = "file")
people_sort :: proc(v: ^conn.View, ids: []proto.Account_Id, shown: []int) {
	Key :: struct {
		v:   ^conn.View,
		ids: []proto.Account_Id,
	}
	key := Key{v, ids}
	context.user_ptr = &key
	slice.sort_by(shown, proc(a, b: int) -> bool {
		k := (^Key)(context.user_ptr)
		x := k.v.accounts[k.ids[a]] or_else {}
		y := k.v.accounts[k.ids[b]] or_else {}
		nx := x.display if x.display != "" else x.username
		ny := y.display if y.display != "" else y.username
		if c := strings.compare(
			strings.to_lower(nx, context.temp_allocator),
			strings.to_lower(ny, context.temp_allocator),
		); c != 0 {
			return c < 0
		}
		return k.ids[a] < k.ids[b]
	})
}

// add_people is the members window's list of accounts that could be added to
// the conversation: everyone who isn't a member yet. Only shown to users who
// may add people. Call with the View locked.
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
		m.add_find.find_len = 0
	}
	if !m.adding {
		return
	}
	others := make([dynamic]proto.Account_Id, context.temp_allocator)
	for id, acc in v.accounts {
		if !slice.contains(members, id) && acc.flags & {.Disabled, .Deleted} == {} {
			append(&others, id)
		}
	}
	if id := people_finder(ui, &m.add_find, others[:], "Add", .Plus); id != 0 {
		command(ui, conn.Conv_Member_Command{conv = v.viewing, account = id, on = true})
	}
}

// below_us is whether we may manage an account: it may not have any
// permission that we don't have ourselves.
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

// account_manage is what the Accounts category offers for the account picked,
// under its roles: disabling or deleting it (Manage_Accounts). Call with the
// View locked.
account_manage :: proc(ui: ^UI, id: proto.Account_Id, acc: conn.View_Account) {
	ctx := &ui.ctx
	v := ui.view
	m := &ui.manage
	if .Manage_Accounts not_in v.permissions ||
	   .Owner in acc.flags ||
	   id == v.me ||
	   !below_us(v, acc) {
		return
	}
	mu.layout_row(ctx, {-1})
	field_row(ui, FORM_LABEL, "Account", {100, 100})
	disabled := .Disabled in acc.flags
	if .SUBMIT in
	   stable_button(ctx, "disable", "Enable" if disabled else "Disable", {.ALIGN_CENTER}) {
		command(ui, conn.Account_Disable_Command{account = id, on = !disabled})
	}
	if .SUBMIT in stable_button(ctx, "delete?", "Delete...", {.ALIGN_CENTER}) {
		m.delete_account = 0 if m.delete_account == id else id
	}
}

// account_delete_confirm asks for confirmation to delete the account picked
// with Delete... Call with the View locked, after account_manage.
account_delete_confirm :: proc(ui: ^UI, id: proto.Account_Id, acc: conn.View_Account) {
	ctx := &ui.ctx
	m := &ui.manage
	if m.delete_account != id {
		return
	}
	mu.layout_row(ctx, {-1})
	with_text_color(
		ctx,
		theme.warning,
		fmt.tprintf(
			"Delete %s for good? What they wrote stays, under \"%s\".",
			acc.username,
			proto.DELETED_NAME,
		),
		wrap_text,
	)
	field_row(ui, FORM_LABEL, "", {140, 100})
	if .SUBMIT in stable_button(ctx, "delete account", "Delete for good", {.ALIGN_CENTER}) {
		command(ui, conn.Account_Delete_Command{account = id})
		m.delete_account = 0
	}
	if .SUBMIT in stable_button(ctx, "cancel delete", "Cancel", {.ALIGN_CENTER}) {
		m.delete_account = 0
	}
}

// account_roles_editor lets the user tick and save the roles of the account
// picked (Manage_Roles). The ticks are taken from the account whenever another
// one is picked or it is saved. Call with the View locked.
account_roles_editor :: proc(ui: ^UI, id: proto.Account_Id, acc: conn.View_Account) {
	ctx := &ui.ctx
	v := ui.view
	m := &ui.manage
	if .Manage_Roles not_in v.permissions || .Owner in acc.flags {
		return
	}
	if m.account != id {
		m.account = id
		clear(&m.account_roles)
		append(&m.account_roles, ..acc.roles)
	}
	mu.label(ctx, "Roles")
	if len(v.roles) <= 1 {
		with_text_color(ctx, theme.dim, "There are no roles to give yet.", label_proc)
		return
	}
	for r in v.roles {
		if r.id == proto.EVERYONE_ROLE {
			continue
		}
		mu.push_id(ctx, uintptr(r.id))
		defer mu.pop_id(ctx)
		mu.layout_row(ctx, {-1})
		i, has := slice.linear_search(m.account_roles[:], r.id)
		if !(r.perms <= v.permissions) {
			with_text_color(
				ctx,
				theme.dim,
				fmt.tprintf("[%s] %s (above you)", "x" if has else " ", r.name),
				label_proc,
			)
			continue
		}
		on := has
		if .CHANGE in checkbox(ctx, r.name, &on) {
			if on && !has {
				append(&m.account_roles, r.id)
			} else if !on && has {
				ordered_remove(&m.account_roles, i)
			}
		}
	}
	changed := len(m.account_roles) != len(acc.roles)
	for r in m.account_roles {
		changed ||= !slice.contains(acc.roles, r)
	}
	mu.layout_row(ctx, {100, 100})
	if .SUBMIT in
		   stable_button(ctx, "save roles", "Save" if changed else "Saved", {.ALIGN_CENTER}) &&
	   changed {
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
	}
	if changed && .SUBMIT in stable_button(ctx, "undo roles", "Undo", {.ALIGN_CENTER}) {
		m.account = 0 // taken from the account again
	}
}

// purge_settings is the settings' section for purging, for users who have
// Purge. It lets them pick a conversation (stepped through with the arrows),
// the age, and whether to purge messages or only pictures. Nothing is purged
// before a second press, which says what will be removed. Call with the View
// locked.
purge_settings :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := ui.view
	m := &ui.manage
	if m.purge_days_len == 0 && !m.purge_confirm {
		m.purge_days_len = copy(m.purge_days_buf[:], "90")
	}

	// What can be picked: all conversations, our channels or our DMs.
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

	field_row(ui, FORM_LABEL, "Conversation", {30, 220, 30})
	if .SUBMIT in icon_button(ui, "purge prev", .Back, "Conversation before") {
		m.purge_conv = choices[(at + len(choices) - 1) % len(choices)]
		m.purge_confirm = false
	}
	mu.label(ctx, place)
	if .SUBMIT in icon_button(ui, "purge next", .Next, "Conversation after") {
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

	field_row(ui, FORM_LABEL, "", {-1}, fill_min = 240)
	if .CHANGE in checkbox(ctx, "Only their files; the messages stay", &m.purge_files) {
		m.purge_confirm = false
	}

	field_row(ui, FORM_LABEL, "", {140, -1})
	if !days_ok {
		mu.label(ctx, "")
		with_text_color(ctx, theme.dim, "How many days, as a number.", wrap_text)
		return
	}
	now_ms := time.time_to_unix_nano(time.now()) / 1_000_000
	before := now_ms - i64(days) * 24 * 60 * 60 * 1000
	if !m.purge_confirm {
		if .SUBMIT in stable_button(ctx, "purge", "Purge...", {.ALIGN_CENTER}) {
			m.purge_confirm = true
		}
		with_text_color(ctx, theme.dim, "Asks first. Pinned messages are always kept.", wrap_text)
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
		theme.error,
		fmt.tprintf(
			"This removes for good the %s in %s from before %s.",
			"files of the messages" if m.purge_files else "messages",
			place,
			when_text,
		),
		wrap_text,
	)
	field_row(ui, FORM_LABEL, "", {140, 140})
	if .SUBMIT in stable_button(ctx, "purge yes", "Purge them", {.ALIGN_CENTER}) {
		command(
			ui,
			conn.Purge_Command {
				conv = m.purge_conv,
				all = m.purge_conv == 0,
				before = proto.Unix_Ms(before),
				what = .Files if m.purge_files else .Messages,
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

package client

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"
import mu "vendor:microui"

import "client:conn"
import "common:proto"

/*
The Roles window, for whoever has Manage_Roles (conn/roles.odin): the
roles on the left, with a box to make one under them, and the role
picked on the right - its name, its colour, its place in the list,
whether it can be mentioned, what it allows, and who has it, with
people to give it to.

A name is shown in the colour of the highest of its account's roles
that has one (name_color): in the chat, the members list, the user
menu. The order is only for that.

A role that allows more than we may is above us: it's shown, but
neither changed nor given nor taken. A permission we don't have
ourselves can't be ticked. The server checks all of it again.

Opened from the server's tab of the settings; it floats over whatever
page is showing, like the Channels window.
*/

UI_Roles :: struct {
	open:        bool,
	placed:      bool,
	// The role picked (0: none), and as it's being edited: loaded again
	// whenever another is picked or the server says it changed.
	role:        proto.Role_Id,
	loaded:      proto.Role_Id,
	seen:        proto.Role, // name owned
	name_buf:    [proto.MAX_ROLE_NAME]u8,
	name_len:    int,
	perms:       proto.Permissions,
	color:       u32,
	flags:       proto.Role_Flags,
	// Delete was pressed once; the list of people to give it to is open.
	confirm:     bool,
	adding:      bool,
	new_buf:     [proto.MAX_ROLE_NAME]u8,
	new_len:     int,
	// What the server said by the time the window opened isn't about
	// anything asked in it (conn.View_Notice.count).
	notice_seen: int,
}

@(private = "file")
ROLES_WINDOW :: "Roles"
@(private = "file")
LIST_WIDTH :: 170
@(private = "file")
NOTICE_OK_COLOR :: mu.Color{120, 200, 120, 255}
@(private = "file")
SWATCH :: 20

// The colours a role can have, readable on the dark background.
ROLE_PALETTE := [?]u32 {
	0xE05555,
	0xE08A3C,
	0xD9C04A,
	0x7CC255,
	0x3FB58A,
	0x46B5C9,
	0x4F8FE0,
	0x7A6CE6,
	0xB06BD9,
	0xD965A8,
	0xB0B0B0,
	0x8C7B6B,
}

// role_rgb is a role's colour as microui draws it.
role_rgb :: proc(color: u32) -> mu.Color {
	return {u8(color >> 16), u8(color >> 8), u8(color), 255}
}

/*
name_color is the colour an account's name is shown in: that of the
highest of its roles that has one (View.roles is in order). Call with
the View locked.
*/
name_color :: proc(v: ^conn.View, account: proto.Account_Id) -> (mu.Color, bool) {
	acc, known := v.accounts[account]
	if !known || len(acc.roles) == 0 {
		return {}, false
	}
	for role in v.roles {
		if role.color != 0 && slice.contains(acc.roles, role.id) {
			return role_rgb(role.color), true
		}
	}
	return {}, false
}

// author_color is what a message's header is shown in: its author's
// role colour, or ours or anyone's. Call with the View locked.
author_color :: proc(v: ^conn.View, sender: proto.Account_Id) -> mu.Color {
	if c, ok := name_color(v, sender); ok {
		return c
	}
	return CHAT_OWN_COLOR if sender == v.me else CHAT_NAME_COLOR
}

@(private = "file")
Chip :: struct {
	name:  string,
	color: u32,
	w:     i32,
}

/*
role_chips draws an account's roles, each a small chip with its colour's
dot and its name, as many to a row as fit `width` and in the roles'
order. Call with the View locked.
*/
role_chips :: proc(ui: ^UI, roles: []proto.Role_Id, width: i32) {
	ctx := &ui.ctx
	v := ui.view
	font := ctx.style.font
	dot := ctx.text_height(font) - 4
	line := make([dynamic]Chip, context.temp_allocator)
	used := i32(0)
	for role in v.roles {
		if !slice.contains(roles, role.id) {
			continue
		}
		w := ctx.text_width(font, role.name) + 2 * CHIP_PAD
		if role.color != 0 {
			w += dot + CHIP_PAD
		}
		if len(line) > 0 && used + w > width {
			chips_row(ui, &line, dot)
			used = 0
		}
		append(&line, Chip{role.name, role.color, w})
		used += w + ctx.style.spacing
	}
	chips_row(ui, &line, dot)
}

@(private = "file")
CHIP_PAD :: 5

@(private = "file")
chips_row :: proc(ui: ^UI, line: ^[dynamic]Chip, dot: i32) {
	ctx := &ui.ctx
	if len(line) == 0 {
		return
	}
	widths := make([]i32, len(line), context.temp_allocator)
	for c, i in line {
		widths[i] = c.w
	}
	mu.layout_row(ctx, widths)
	font := ctx.style.font
	for c in line {
		r := mu.layout_next(ctx)
		mu.draw_rect(ctx, r, ctx.style.colors[.BASE])
		x := r.x + CHIP_PAD
		if c.color != 0 {
			disc(ui, {x, r.y + (r.h - dot) / 2, dot, dot}, role_rgb(c.color))
			x += dot + CHIP_PAD
		}
		th := ctx.text_height(font)
		mu.draw_text(ctx, font, c.name, {x, r.y + (r.h - th) / 2}, ctx.style.colors[.TEXT])
	}
	clear(line)
}

// What each permission allows, as the settings say it.
PERMISSION_TEXT := [proto.Permission]string {
	.Create_Channels  = "Make channels",
	.Manage_Channels  = "Change and delete channels",
	.Invite           = "Add people to channels",
	.Manage_Roles     = "Manage roles and who has them",
	.Manage_Messages  = "Delete others' messages",
	.Pin_Messages     = "Pin messages",
	.Manage_Accounts  = "Make, disable, delete and reset accounts",
	.Mention_Everyone = "Mention @everyone",
	.Purge            = "Purge history",
	.Attach_Files     = "Attach files to messages",
	.Create_Invites   = "Make invite codes",
}

ui_roles_destroy :: proc(ui: ^UI) {
	delete(ui.roles.seen.name)
	ui.roles.seen = {}
}

@(private = "file")
command :: proc(ui: ^UI, cmd: conn.Command) {
	if ui.session != nil {
		conn.push_command(&ui.session.client.commands, cmd)
	}
}

open_roles :: proc(ui: ^UI) {
	r := &ui.roles
	r.open, r.placed = true, false
	r.notice_seen = -1 // taken from the View when it's next locked
}

/*
roles_window draws the Roles window while it's open. Call with the View
unlocked.
*/
roles_window :: proc(ui: ^UI, window_w, window_h: i32) {
	r := &ui.roles
	if !r.open {
		return
	}
	ctx := &ui.ctx
	v := ui.view
	sync.guard(&v.mutex)
	if v.status != .Connected || v.login.state != .Done || .Manage_Roles not_in v.permissions {
		r.open = false
		return
	}
	if r.notice_seen < 0 {
		r.notice_seen = v.notice.count
	}
	if !r.placed {
		r.placed = true
		w := clamp(window_w - 40, 360, 760)
		h := clamp(window_h - 40, 260, 560)
		if cnt := mu.get_container(ctx, ROLES_WINDOW); cnt != nil {
			cnt.rect = {(window_w - w) / 2, (window_h - h) / 2, w, h}
			cnt.open = true
			cnt.scroll = {}
			mu.bring_to_front(ctx, cnt)
			// The click that opened it would raise the window behind at
			// the end of the frame (see image_viewer).
			ctx.hover_root, ctx.next_hover_root = cnt, cnt
		}
	}
	if !mu.begin_window(ctx, ROLES_WINDOW, {}) {
		r.open = false // closed with the title bar's button
		return
	}
	defer mu.end_window(ctx)

	// A role that's gone takes the right-hand side with it.
	if r.role != 0 && role_of(v, r.role) == nil {
		r.role = 0
	}

	mu.layout_row(ctx, {LIST_WIDTH, -1}, -1)
	mu.begin_panel(ctx, "role list")
	role_list(ui)
	mu.end_panel(ctx)
	mu.begin_panel(ctx, "role")
	if role := role_of(v, r.role); role != nil {
		role_editor(ui, role^)
	} else {
		mu.layout_row(ctx, {-1})
		with_text_color(ctx, DIM_COLOR, "Pick a role to see and change it.", label_proc)
		roles_notice(ui)
	}
	mu.end_panel(ctx)
}

@(private = "file")
role_of :: proc(v: ^conn.View, id: proto.Role_Id) -> ^conn.View_Role {
	for &role in v.roles {
		if role.id == id {
			return &role
		}
	}
	return nil
}

// role_list is the left-hand side: every role, and making one.
@(private = "file")
role_list :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := ui.view
	r := &ui.roles
	for role in v.roles {
		mu.push_id(ctx, uintptr(role.id))
		defer mu.pop_id(ctx)
		mu.layout_row(ctx, {-1})
		id := mu.get_id(ctx, "role")
		rect := mu.layout_next(ctx)
		mu.update_control(ctx, id, rect)
		switch {
		case r.role == role.id:
			mu.draw_rect(ctx, rect, ctx.style.colors[.BUTTON_FOCUS])
		case ctx.hover_id == id:
			mu.draw_rect(ctx, rect, ctx.style.colors[.BUTTON_HOVER])
		}
		above := !(role.perms <= v.permissions)
		text := fmt.tprintf("%s  (above you)", role.name) if above else role.name
		if role.color != 0 {
			saved := ctx.style.colors[.TEXT]
			ctx.style.colors[.TEXT] = role_rgb(role.color)
			mu.draw_control_text(ctx, text, rect, .TEXT, {})
			ctx.style.colors[.TEXT] = saved
		} else {
			mu.draw_control_text(ctx, text, rect, .TEXT, {})
		}
		if ctx.hover_id == id && ctx.mouse_pressed_bits == {.LEFT} {
			r.role = role.id
			r.confirm, r.adding = false, false
		}
	}
	mu.layout_row(ctx, {-1})
	mu.label(ctx, "")
	with_text_color(ctx, DIM_COLOR, "New role", label_proc)
	mu.layout_row(ctx, {-1})
	submit := .SUBMIT in text_box(ui, r.new_buf[:], &r.new_len)
	submit |= .SUBMIT in stable_button(ctx, "make role", "Make role", {.ALIGN_CENTER})
	if submit && r.new_len > 0 {
		command(ui, conn.Role_Set_Command{name = strings.clone(string(r.new_buf[:r.new_len]))})
		r.new_len = 0
	}
}

// role_editor is the right-hand side for the role picked.
@(private = "file")
role_editor :: proc(ui: ^UI, role: conn.View_Role) {
	ctx := &ui.ctx
	v := ui.view
	r := &ui.roles
	mine := v.permissions
	if r.loaded != role.id ||
	   r.seen.perms != role.perms ||
	   r.seen.name != role.name ||
	   r.seen.color != role.color ||
	   r.seen.flags != role.flags {
		r.loaded = role.id
		r.name_len = copy(r.name_buf[:], role.name)
		r.perms = role.perms
		r.color = role.color
		r.flags = role.flags
		delete(r.seen.name)
		r.seen = {
			id    = role.id,
			perms = role.perms,
			name  = strings.clone(role.name),
			color = role.color,
			flags = role.flags,
		}
	}
	everyone := role.id == proto.EVERYONE_ROLE
	// A role that can do more than we can is above us: shown, not
	// changed, given or taken.
	above := !(role.perms <= mine)
	editable := !above

	mu.layout_row(ctx, {60, -1})
	mu.label(ctx, "Name")
	if everyone || above {
		mu.label(ctx, role.name)
	} else {
		text_box(ui, r.name_buf[:], &r.name_len)
	}
	// Its colour, and its place, which decide the colour of names.
	if !everyone {
		color_picker(ui, editable)
		if editable {
			move_buttons(ui, role.id)
		}
		// Whether `@name` pings whoever has it.
		mentionable := .Mentionable in r.flags
		mu.layout_row(ctx, {-1})
		if editable {
			if .CHANGE in mu.checkbox(ctx, "Can be mentioned with @name", &mentionable) {
				r.flags ~= {.Mentionable}
			}
		} else {
			with_text_color(
				ctx,
				DIM_COLOR,
				fmt.tprintf("[%s] Can be mentioned with @name", "x" if mentionable else " "),
				label_proc,
			)
		}
	}
	mu.layout_row(ctx, {-1})
	switch {
	case above:
		with_text_color(
			ctx,
			WARNING_COLOR,
			"It allows more than you may, so you can't change, give or take it.",
			label_proc,
		)
	case everyone:
		with_text_color(ctx, DIM_COLOR, "What everyone may do. Everyone has it.", label_proc)
	case:
		with_text_color(ctx, DIM_COLOR, "What it allows, besides what everyone may:", label_proc)
	}

	for p in proto.Permission {
		mu.push_id(ctx, uintptr(p) + 1)
		defer mu.pop_id(ctx)
		on := p in r.perms
		if !editable || p not_in mine {
			mu.layout_row(ctx, {-1})
			why := "" if !editable else "  (you don't have it yourself)"
			with_text_color(
				ctx,
				DIM_COLOR,
				fmt.tprintf("[%s] %s%s", "x" if on else " ", PERMISSION_TEXT[p], why),
				label_proc,
			)
			continue
		}
		mu.layout_row(ctx, {-1})
		if .CHANGE in mu.checkbox(ctx, PERMISSION_TEXT[p], &on) {
			if on {
				r.perms += {p}
			} else {
				r.perms -= {p}
			}
		}
	}

	if editable {
		changed :=
			r.perms != role.perms ||
			r.color != role.color ||
			r.flags != role.flags ||
			string(r.name_buf[:r.name_len]) != role.name
		mu.layout_row(ctx, {100, 140, -1})
		if .SUBMIT in
			   stable_button(ctx, "save role", "Save" if changed else "Saved", {.ALIGN_CENTER}) &&
		   changed &&
		   r.name_len > 0 {
			command(
				ui,
				conn.Role_Set_Command {
					id = role.id,
					name = strings.clone(string(r.name_buf[:r.name_len])),
					perms = r.perms,
					color = r.color,
					flags = r.flags,
				},
			)
		}
		switch {
		case everyone:
			mu.label(ctx, "")
		case r.confirm:
			if .SUBMIT in
			   stable_button(ctx, "delete role", "Delete it for good", {.ALIGN_CENTER}) {
				command(ui, conn.Role_Delete_Command{id = role.id})
				r.role, r.confirm = 0, false
				return
			}
		case:
			if .SUBMIT in stable_button(ctx, "delete role?", "Delete role...", {.ALIGN_CENTER}) {
				r.confirm = true
			}
		}
	}
	roles_notice(ui)

	if everyone {
		return
	}
	role_members(ui, role, editable)
}

// color_picker is the row of colours a role can have, and none; the one
// it's to have outlined. Saved with the rest.
@(private = "file")
color_picker :: proc(ui: ^UI, editable: bool) {
	ctx := &ui.ctx
	r := &ui.roles
	widths := make([]i32, len(ROLE_PALETTE) + 2, context.temp_allocator)
	widths[0] = 60
	for &w in widths[1:] {
		w = SWATCH
	}
	widths[len(widths) - 1] = 50
	mu.layout_row(ctx, widths, SWATCH)
	mu.label(ctx, "Colour")
	for c in ROLE_PALETTE {
		mu.push_id(ctx, uintptr(c))
		defer mu.pop_id(ctx)
		color := c | proto.ROLE_COLOR_SET
		id := mu.get_id(ctx, "swatch")
		cell := mu.layout_next(ctx)
		if editable {
			mu.update_control(ctx, id, cell)
		}
		if r.color == color {
			mu.draw_rect(ctx, cell, {240, 240, 240, 255})
		}
		mu.draw_rect(ctx, mu.expand_rect(cell, -2), role_rgb(c))
		if editable && ctx.hover_id == id && ctx.mouse_pressed_bits == {.LEFT} {
			r.color = color
		}
	}
	if editable {
		if .SUBMIT in stable_button(ctx, "no color", "None", {.ALIGN_CENTER}) {
			r.color = 0
		}
	} else {
		mu.label(ctx, "" if r.color != 0 else "none")
	}
}

// move_buttons move a role up or down the list, at once.
@(private = "file")
move_buttons :: proc(ui: ^UI, id: proto.Role_Id) {
	ctx := &ui.ctx
	v := ui.view
	cmd: conn.Role_Order_Command
	at := -1
	for role in v.roles {
		if role.id == proto.EVERYONE_ROLE || cmd.count == len(cmd.roles) {
			continue
		}
		if role.id == id {
			at = cmd.count
		}
		cmd.roles[cmd.count] = role.id
		cmd.count += 1
	}
	mu.layout_row(ctx, {60, 100, 100, -1})
	mu.label(ctx, "Place")
	up := false
	if at > 0 {
		up = .SUBMIT in stable_button(ctx, "move up", "Move up", {.ALIGN_CENTER})
	} else {
		mu.label(ctx, "")
	}
	down := false
	if at >= 0 && at < cmd.count - 1 {
		down = .SUBMIT in stable_button(ctx, "move down", "Move down", {.ALIGN_CENTER})
	} else {
		mu.label(ctx, "")
	}
	with_text_color(ctx, DIM_COLOR, "The highest coloured role colours a name.", label_proc)
	switch {
	case up:
		cmd.roles[at], cmd.roles[at - 1] = cmd.roles[at - 1], cmd.roles[at]
	case down:
		cmd.roles[at], cmd.roles[at + 1] = cmd.roles[at + 1], cmd.roles[at]
	case:
		return
	}
	command(ui, cmd)
}

// role_members is who has a role, with taking it from them and giving
// it to others when it's ours to give.
@(private = "file")
role_members :: proc(ui: ^UI, role: conn.View_Role, editable: bool) {
	ctx := &ui.ctx
	v := ui.view
	r := &ui.roles
	ids, _ := slice.map_keys(v.accounts, context.temp_allocator)
	slice.sort(ids)

	mu.layout_row(ctx, {-1})
	mu.label(ctx, "")
	mu.label(ctx, "Who has it")
	any := false
	for id in ids {
		acc := v.accounts[id]
		if .Deleted in acc.flags || !slice.contains(acc.roles, role.id) {
			continue
		}
		any = true
		mu.push_id(ctx, uintptr(id))
		defer mu.pop_id(ctx)
		mu.layout_row(ctx, {-(90 + ctx.style.spacing + 1), 90})
		mu.label(ctx, fmt.tprintf("  %s  @%s", acc.display, acc.username))
		if !editable {
			mu.label(ctx, "")
		} else if .SUBMIT in stable_button(ctx, "take", "Take it", {.ALIGN_CENTER}) {
			give(ui, id, acc, role.id, false)
		}
	}
	if !any {
		mu.layout_row(ctx, {-1})
		with_text_color(ctx, DIM_COLOR, "  Nobody yet.", label_proc)
	}
	if !editable {
		return
	}

	mu.layout_row(ctx, {140})
	if .SUBMIT in
	   stable_button(ctx, "give", "Hide" if r.adding else "Give it to...", {.ALIGN_CENTER}) {
		r.adding = !r.adding
	}
	if !r.adding {
		return
	}
	others := false
	for id in ids {
		acc := v.accounts[id]
		if acc.flags & {.Deleted, .Owner} != {} ||
		   slice.contains(acc.roles, role.id) ||
		   len(acc.roles) >= proto.MAX_ACCOUNT_ROLES {
			continue
		}
		others = true
		mu.push_id(ctx, uintptr(id))
		defer mu.pop_id(ctx)
		mu.layout_row(ctx, {-(90 + ctx.style.spacing + 1), 90})
		mu.label(ctx, fmt.tprintf("  %s  @%s", acc.display, acc.username))
		if .SUBMIT in stable_button(ctx, "add", "Give", {.ALIGN_CENTER}) {
			give(ui, id, acc, role.id, true)
		}
	}
	if !others {
		mu.layout_row(ctx, {-1})
		with_text_color(ctx, DIM_COLOR, "  Nobody else to give it to.", label_proc)
	}
}

// give gives an account a role, or takes it, keeping the others it has.
@(private = "file")
give :: proc(
	ui: ^UI,
	id: proto.Account_Id,
	acc: conn.View_Account,
	role: proto.Role_Id,
	on: bool,
) {
	cmd := conn.Account_Roles_Command {
		account = id,
	}
	for have in acc.roles {
		if have != role && cmd.count < len(cmd.roles) {
			cmd.roles[cmd.count] = have
			cmd.count += 1
		}
	}
	if on && cmd.count < len(cmd.roles) {
		cmd.roles[cmd.count] = role
		cmd.count += 1
	}
	command(ui, cmd)
}

// roles_notice is what the server last said about something asked in
// the window: a refusal, say.
@(private = "file")
roles_notice :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := ui.view
	if v.notice.text == "" || v.notice.count <= ui.roles.notice_seen {
		return
	}
	mu.layout_row(ctx, {-1})
	with_text_color(
		ctx,
		NOTICE_OK_COLOR if v.notice.ok else ERROR_COLOR,
		v.notice.text,
		label_proc,
	)
}

package client

import "core:fmt"
import "core:slice"
import "core:strings"
import mu "vendor:microui"

import "client:conn"
import "common:proto"

// Roles are managed in the settings' server tab by users who have
// Manage_Roles (conn/roles.odin). The roles are listed on the left, with a
// box below to create one. The role that is picked is shown on the right: its
// name, colour, position in the list, whether it can be mentioned, what it
// allows, and who has it, with a list of people to give it to.
//
// A name is shown in the colour of the highest of its account's roles that has
// a colour (name_color): in the chat, the members list and the user menu. The
// order of the roles only matters for that.
//
// A role that allows more than we may is above us. It is shown, but it can't
// be changed, given or taken. A permission that we don't have ourselves can't
// be ticked. The server checks all of this again.

UI_Roles :: struct {
	// The picked role (0: none) as it is being edited. It is loaded again
	// whenever another role is picked or the server says it changed.
	role:    proto.Role_Id,
	loaded:  proto.Role_Id,
	seen:    proto.Role, // the name is owned
	name:    Text_Field(proto.MAX_ROLE_NAME),
	perms:   proto.Permissions,
	color:   u32,
	flags:   proto.Role_Flags,
	// Delete was pressed once.
	confirm: bool,
	// Who has the picked role, and finding someone to give it to.
	holders: Pager,
	giving:  Pager,
	new:     Text_Field(proto.MAX_ROLE_NAME),
	notice:  Notice_Mark,
}

@(private = "file")
LIST_WIDTH :: 170
// When the space beside the list is narrower than this, the picked role gets
// the whole page (roles_settings).
@(private = "file")
EDITOR_MIN :: 300
@(private = "file")
SWATCH :: 20

// The colours a role can have, which are readable on the dark background.
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

// name_color is the colour an account's name is shown in: the colour of the
// highest of its roles that has one (View.roles is in order). Call with the
// View locked.
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

// author_color is the colour a message's header is shown in: its author's role
// colour, whether the author is us or someone else. Call with the View locked.
author_color :: proc(v: ^conn.View, sender: proto.Account_Id) -> mu.Color {
	if c, ok := name_color(v, sender); ok {
		return c
	}
	return theme.chat_own if sender == v.me else theme.chat_name
}

@(private = "file")
Chip :: struct {
	name:  string,
	color: u32,
	w:     i32,
}

// role_chips draws an account's roles as small chips, each with a dot in the
// role's colour and its name, as many per row as fit `width`, in the roles'
// order. Call with the View locked.
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

// What each permission allows, as worded in the settings.
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
	.Move_Members     = "Move people between voice rooms and disconnect them",
	.Mute_Members     = "Mute people in voice for everyone",
	.Ban_Members      = "Ban and unban people",
}

ui_roles_destroy :: proc(ui: ^UI) {
	delete(ui.roles.seen.name)
	ui.roles.seen = {}
}

// roles_settings is the Roles category of the settings' server tab
// (server_settings), for users who have Manage_Roles. Call with the View locked.
roles_settings :: proc(ui: ^UI) {
	r := &ui.roles
	v := ui.view
	if .Manage_Roles not_in v.permissions {
		return
	}
	notice_mark_update(&r.notice, v)

	// A role that is gone takes the right-hand side with it.
	if r.role != 0 && role_of(v, r.role) == nil {
		r.role = 0
	}

	role := role_of(v, r.role)
	list_detail(ui, {
		name = "role",
		list_width = LIST_WIDTH,
		detail_min = EDITOR_MIN,
		picked = role != nil,
		title = role.name if role != nil else "",
		back_hint = "Roles",
		list = role_list,
		detail = role_detail,
		back = proc(ui: ^UI) {
			r := &ui.roles
			r.role = 0
			r.confirm, r.holders, r.giving = false, {}, {}
		},
	})
}

// role_detail is the picked role's side of the category, or what to do with
// none picked.
@(private = "file")
role_detail :: proc(ui: ^UI) {
	if role := role_of(ui.view, ui.roles.role); role != nil {
		role_editor(ui, role^)
		return
	}
	mu.layout_row(&ui.ctx, {-1})
	with_text_color(&ui.ctx, theme.dim, "Pick a role to see and change it.", label_proc)
	notice_row(ui, ui.roles.notice, ui.view)
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

// role_list is the left-hand side: every role, and creating a new one.
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
			r.confirm, r.holders, r.giving = false, {}, {}
		}
	}
	mu.layout_row(ctx, {-1})
	mu.label(ctx, "")
	dim_label(ctx, "New role")
	mu.layout_row(ctx, {-1})
	submit := .SUBMIT in text_box(ui, r.new.buf[:], &r.new.len)
	submit |= .SUBMIT in stable_button(ctx, "make role", "Make role", {.ALIGN_CENTER})
	if submit && r.new.len > 0 {
		command(ui, conn.Role_Set_Command{name = strings.clone(field_text(&r.new))})
		r.new.len = 0
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
		field_set(&r.name, role.name)
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
	// A role that can do more than we can is above us: it is shown, but can't
	// be changed, given or taken.
	above := !(role.perms <= mine)
	editable := !above

	mu.layout_row(ctx, {60, -1})
	mu.label(ctx, "Name")
	if everyone || above {
		mu.label(ctx, role.name)
	} else {
		text_box(ui, r.name.buf[:], &r.name.len)
	}
	// Its colour and its position, which decide the colour of names.
	if !everyone {
		color_picker(ui, editable)
		if editable {
			move_buttons(ui, role.id)
		}
		// Whether `@name` notifies whoever has the role.
		mentionable := .Mentionable in r.flags
		mu.layout_row(ctx, {-1})
		if editable {
			if .CHANGE in checkbox(ctx, "Can be mentioned with @name", &mentionable) {
				r.flags ~= {.Mentionable}
			}
		} else {
			dim_label(
				ctx,
				fmt.tprintf("[%s] Can be mentioned with @name", "x" if mentionable else " "),
			)
		}
	}
	mu.layout_row(ctx, {-1})
	switch {
	case above:
		with_text_color(
			ctx,
			theme.warning,
			"It allows more than you may, so you can't change, give or take it.",
			label_proc,
		)
	case everyone:
		dim_label(ctx, "What everyone may do. Everyone has it.")
	case:
		dim_label(ctx, "What it allows, besides what everyone may:")
	}

	for p in proto.Permission {
		mu.push_id(ctx, uintptr(p) + 1)
		defer mu.pop_id(ctx)
		on := p in r.perms
		if !editable || p not_in mine {
			mu.layout_row(ctx, {-1})
			why := "" if !editable else "  (you don't have it yourself)"
			dim_label(ctx, fmt.tprintf("[%s] %s%s", "x" if on else " ", PERMISSION_TEXT[p], why))
			continue
		}
		mu.layout_row(ctx, {-1})
		if .CHANGE in checkbox(ctx, PERMISSION_TEXT[p], &on) {
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
			field_text(&r.name) != role.name
		mu.layout_row(ctx, {100, 140, -1})
		if .SUBMIT in
			   stable_button(ctx, "save role", "Save" if changed else "Saved", {.ALIGN_CENTER}) &&
		   changed &&
		   r.name.len > 0 {
			command(
				ui,
				conn.Role_Set_Command {
					id = role.id,
					name = strings.clone(field_text(&r.name)),
					perms = r.perms,
					color = r.color,
					flags = r.flags,
				},
			)
		}
		if everyone {
			mu.label(ctx, "")
		} else if confirm_button(
			ctx,
			&r.confirm,
			"delete role",
			"Delete role...",
			"Delete it for good",
		) {
			command(ui, conn.Role_Delete_Command{id = role.id})
			r.role = 0
			return
		}
	}
	notice_row(ui, ui.roles.notice, ui.view)

	if everyone {
		return
	}
	role_members(ui, role, editable)
}

// color_picker is the row of colours a role can have, plus none, with the
// current one outlined. It is saved with the rest.
@(private = "file")
color_picker :: proc(ui: ^UI, editable: bool) {
	ctx := &ui.ctx
	r := &ui.roles
	widths := make([]i32, len(ROLE_PALETTE) + 1, context.temp_allocator)
	for &w in widths {
		w = SWATCH
	}
	widths[len(widths) - 1] = 50
	field_row(ui, 60, "Colour", widths, SWATCH)
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
			mu.draw_rect(ctx, cell, theme.strong)
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

// move_buttons move a role up or down the list immediately.
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
	field_row(ui, 60, "Place", {100, 100, -1})
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
	dim_label(ctx, "The highest coloured role colours a name.")
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

// role_members is who has a role, a page at a time, with buttons to take it
// from them and a box to find others to give it to, when we may give it.
@(private = "file")
role_members :: proc(ui: ^UI, role: conn.View_Role, editable: bool) {
	ctx := &ui.ctx
	v := ui.view
	r := &ui.roles
	holders := make([dynamic]proto.Account_Id, context.temp_allocator)
	others := make([dynamic]proto.Account_Id, context.temp_allocator)
	for id, acc in v.accounts {
		switch {
		case .Deleted in acc.flags:
		case slice.contains(acc.roles, role.id):
			append(&holders, id)
		case .Owner not_in acc.flags && len(acc.roles) < proto.MAX_ACCOUNT_ROLES:
			append(&others, id)
		}
	}

	mu.layout_row(ctx, {-1})
	mu.label(ctx, "")
	mu.label(ctx, "Who has it")
	allowed: []bool
	if !editable {
		allowed = make([]bool, len(holders), context.temp_allocator) // none
	}
	if take := people_list(ui, &r.holders, holders[:], "Take it", allowed); take != 0 {
		give(ui, take, v.accounts[take], role.id, false)
	}
	if !editable {
		return
	}

	mu.layout_row(ctx, {-1})
	mu.label(ctx, "")
	mu.label(ctx, "Give it to")
	if to := people_finder(ui, &r.giving, others[:], "Give"); to != 0 {
		give(ui, to, v.accounts[to], role.id, true)
	}
}

// give gives an account a role or takes it away, keeping the others it has.
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

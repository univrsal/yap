package conn

import log "common:wlog"
import "core:fmt"
import "core:slice"
import "core:strings"

import "client:richtext"
import "common:proto"


// Roles and managing the server (src/common/proto/roles.odin, convs.odin):
// the roles as the server reports them, and requests to change them, to change
// who has them, to allow or block an account from logging in, and to manage
// channels.
//
// What we may do is stored in Self (permissions, auth.odin). The UI offers only
// those actions, and the server checks the permissions again.

Dir_Role :: struct {
	name:     string, // owned
	perms:    proto.Permissions,
	color:    u32, // proto.ROLE_COLOR_SET | 0xRRGGBB, or 0
	position: u16,
	flags:    proto.Role_Flags,
}

// The roles in View.roles are in the server's order, top first, with the
// everyone role last.
View_Role :: richtext.Role

// Make a role (id 0) or change one. Headless, `by_name` changes the role
// called `name` and keeps its color and flags.
Role_Set_Command :: struct {
	id:      proto.Role_Id,
	name:    string, // owned by the command
	perms:   proto.Permissions,
	color:   u32,
	flags:   proto.Role_Flags,
	by_name: bool,
}

// Put the roles in this order, top first, leaving out the everyone role.
Role_Order_Command :: struct {
	roles: [proto.MAX_ROLES]proto.Role_Id,
	count: int,
}

// Delete a role (headless: by name).
Role_Delete_Command :: struct {
	id:   proto.Role_Id,
	name: string, // owned by the command
}

// An account's roles besides the everyone role. Headless, by name (`name`, and
// the roles' names in `role_names`, comma separated).
Account_Roles_Command :: struct {
	account:    proto.Account_Id,
	roles:      [proto.MAX_ACCOUNT_ROLES]proto.Role_Id,
	count:      int,
	name:       string, // owned by the command
	role_names: string, // owned by the command
}

Account_Disable_Command :: struct {
	account: proto.Account_Id,
	name:    string, // owned by the command; headless
	on:      bool,
}

// Delete an account: our own (with our password), or somebody else's if we are
// allowed to. Headless, by name.
Account_Delete_Command :: struct {
	account:  proto.Account_Id,
	name:     string, // owned by the command; headless
	own:      bool, // ours, whatever `account` says
	password: string, // owned by the command; for our own
}

// List the roles in the log (headless).
Roles_Command :: struct {}

roles_clear :: proc(a: ^Auth_Client) {
	for _, r in a.roles {
		delete(r.name)
	}
	clear(&a.roles)
}

// roles_event takes Role_Changed and Role_Removed (auth_event).
roles_event :: proc(c: ^Server_Conn, op: proto.Event_Op, body: []u8) {
	a := &c.auth
	#partial switch op {
	case .Role_Changed:
		r, ok := proto.decode_role(body)
		if !ok {
			return
		}
		_, dir, _, _ := map_entry(&a.roles, r.id)
		delete(dir.name)
		dir^ = {strings.clone(r.name), r.perms, r.color, r.position, r.flags}
		if c.view == nil && a.state == .Done {
			log.infof("[roles] %s: %v", r.name, r.perms)
		}
	case .Role_Removed:
		id, ok := proto.decode_account_id(body)
		if !ok {
			return
		}
		if dir, found := a.roles[proto.Role_Id(id)]; found {
			if c.view == nil {
				log.infof("[roles] %s is gone", dir.name)
			}
			delete(dir.name)
			delete_key(&a.roles, proto.Role_Id(id))
		}
	}
	publish_roles(c)
}

role_named :: proc(c: ^Server_Conn, name: string) -> proto.Role_Id {
	for id, r in c.auth.roles {
		if strings.equal_fold(r.name, strings.trim_space(name)) {
			return id
		}
	}
	return 0
}

roles_list :: proc(c: ^Server_Conn) {
	ids, _ := slice.map_keys(c.auth.roles, context.temp_allocator)
	slice.sort(ids)
	for id in ids {
		r := c.auth.roles[id]
		holders := make([dynamic]string, context.temp_allocator)
		for _, acc in c.auth.accounts {
			if slice.contains(acc.roles, id) {
				append(&holders, acc.username)
			}
		}
		log.infof("[roles] #%d %s: %v %v", id, r.name, r.perms, holders[:])
	}
}

role_set :: proc(c: ^Server_Conn, cmd: Role_Set_Command) {
	id, color, flags := cmd.id, cmd.color, cmd.flags
	if cmd.by_name {
		id = role_named(c, cmd.name)
		if id == 0 {
			log.warnf("there's no role called %q", cmd.name)
			return
		}
		color, flags = c.auth.roles[id].color, c.auth.roles[id].flags
	}
	buf: [proto.ROLE_MAX_SIZE]u8
	body := proto.encode_role(
		buf[:],
		{id = id, perms = cmd.perms, name = cmd.name, color = color, flags = flags},
	)
	if body == nil {
		notify(c, false, "The role name is too long.")
		return
	}
	request(c, .Role_Set, body, manage_done)
}

role_order :: proc(c: ^Server_Conn, cmd: Role_Order_Command) {
	cmd := cmd
	buf: [proto.ROLE_ORDER_MAX_SIZE]u8
	request(c, .Role_Order, proto.encode_role_order(buf[:], cmd.roles[:cmd.count]), manage_done)
}

role_delete :: proc(c: ^Server_Conn, cmd: Role_Delete_Command) {
	id := cmd.id if cmd.id != 0 else role_named(c, cmd.name)
	if id == 0 {
		log.warnf("there's no role called %q", cmd.name)
		return
	}
	buf: [4]u8
	request(c, .Role_Delete, proto.encode_account_id(&buf, proto.Account_Id(id)), manage_done)
}

account_roles_set :: proc(c: ^Server_Conn, cmd: Account_Roles_Command) {
	cmd := cmd
	if cmd.name != "" {
		cmd.account = account_named(c, cmd.name)
		cmd.count = 0
		names := cmd.role_names
		for name in strings.split_iterator(&names, ",") {
			if strings.trim_space(name) == "" {
				continue
			}
			id := role_named(c, name)
			if id == 0 || cmd.count == len(cmd.roles) {
				log.warnf("there's no role called %q", name)
				return
			}
			cmd.roles[cmd.count] = id
			cmd.count += 1
		}
	}
	if cmd.account == 0 {
		log.warn("there's no such account")
		return
	}
	buf: [proto.ACCOUNT_ROLES_MAX_SIZE]u8
	request(
		c,
		.Account_Roles_Set,
		proto.encode_account_roles(buf[:], cmd.account, cmd.roles[:cmd.count]),
		manage_done,
	)
}

account_disable :: proc(c: ^Server_Conn, cmd: Account_Disable_Command) {
	account := cmd.account if cmd.account != 0 else account_named(c, cmd.name)
	if account == 0 {
		log.warn("there's no such account")
		return
	}
	buf: [proto.ACCOUNT_DISABLE_SIZE]u8
	request(c, .Account_Disable, proto.encode_account_disable(&buf, account, cmd.on), manage_done)
}

account_delete :: proc(c: ^Server_Conn, cmd: Account_Delete_Command) {
	account := cmd.account if cmd.account != 0 else account_named(c, cmd.name)
	if cmd.own {
		account = c.auth.me
	}
	if account == 0 {
		log.warn("there's no such account")
		return
	}
	buf: [proto.ACCOUNT_BODY_MAX]u8
	body := proto.encode_account_delete(buf[:], account, cmd.password)
	if body == nil {
		notify(c, false, "The password is too long.")
		return
	}
	request(
		c,
		.Account_Delete,
		body,
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			#partial switch status {
			case .Wrong_Password:
				notify(c, false, "Wrong password. The account was not deleted.")
			case .Rate_Limited:
				notify(c, false, "Too many attempts. Wait a moment and try again.")
			case:
				manage_done(c, status, body, tag)
			}
		},
	)
}

// role_name returns a role's name, or its number if we don't know it.
role_name :: proc(c: ^Server_Conn, id: proto.Role_Id) -> string {
	if r, ok := c.auth.roles[id]; ok {
		return r.name
	}
	return fmt.tprintf("role %d", id)
}

// manage_done reports what went wrong with a change to the server's roles,
// accounts or channels. Successful changes need no message.
manage_done :: proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
	#partial switch status {
	case .Ok, .Reset:
		if c.view == nil && status == .Ok {
			log.info("[manage] done")
		}
	case .Too_Large:
		notify(c, false, "The server has reached the maximum number of roles or channels.")
	case:
		notify(c, false, status_text(status, "role, account or channel"))
	}
}

publish_roles :: proc(c: ^Server_Conn) {
	v := c.view
	if v == nil {
		return
	}
	ids, _ := slice.map_keys(c.auth.roles, context.temp_allocator)
	// As the server lists them (roles.odin there): by position, then in the
	// order they were created, with the everyone role last.
	context.user_ptr = &c.auth.roles
	slice.sort_by(ids, proc(x, y: proto.Role_Id) -> bool {
		roles := (^map[proto.Role_Id]Dir_Role)(context.user_ptr)
		xe, ye := x == proto.EVERYONE_ROLE, y == proto.EVERYONE_ROLE
		if xe != ye {
			return ye
		}
		xp, yp := roles[x].position, roles[y].position
		return xp < yp if xp != yp else x < y
	})
	view_write(v)
	view_clear_roles(v)
	for id in ids {
		r := c.auth.roles[id]
		append(&v.roles, View_Role{id, strings.clone(r.name), r.perms, r.color, r.flags})
	}
}

// dir_roles returns the roles in the form mentions expect (richtext/mentions.odin),
// built from what we know about them rather than from the View. It is allocated
// in the temp allocator and the names are not copied.
dir_roles :: proc(c: ^Server_Conn) -> []View_Role {
	list := make([dynamic]View_Role, 0, len(c.auth.roles), context.temp_allocator)
	for id, r in c.auth.roles {
		append(&list, View_Role{id, r.name, r.perms, r.color, r.flags})
	}
	return list[:]
}

// Call with the mutex held.
view_clear_roles :: proc(v: ^View) {
	for r in v.roles {
		delete(r.name)
	}
	clear(&v.roles)
}

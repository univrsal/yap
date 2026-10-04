package conn

import log "common:wlog"
import "core:fmt"
import "core:slice"
import "core:strings"

import "common:proto"

/*
Roles and managing the server (src/common/proto/roles.odin, convs.odin):
the roles there are, as the server tells them, and asking to change
them, who has them, whether an account may log in, and the channels.

What we may do is in Self (permissions, auth.odin); the UI offers only
that, and the server checks again.
*/

Dir_Role :: struct {
	name:  string, // owned
	perms: proto.Permissions,
}

View_Role :: struct {
	id:    proto.Role_Id,
	name:  string, // owned
	perms: proto.Permissions,
}

// Make a role (id 0) or change one; headless, `by_name` changes the
// one called `name`.
Role_Set_Command :: struct {
	id:      proto.Role_Id,
	name:    string, // owned by the command
	perms:   proto.Permissions,
	by_name: bool,
}
// Delete a role; headless, by name.
Role_Delete_Command :: struct {
	id:   proto.Role_Id,
	name: string, // owned by the command
}
// An account's roles besides everyone's; headless, by name (`name`, and
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
// Change a channel (0: the one we're looking at): what the mask names.
Conv_Update_Command :: struct {
	conv:     proto.Conv_Id,
	mask:     u8,
	name:     string, // owned by the command
	topic:    string, // owned by the command
	position: int,
}
Conv_Delete_Command :: struct {
	conv: proto.Conv_Id,
}
// Add somebody to a channel (0: the one we're looking at), or take them
// out of a private one; headless, by name.
Conv_Member_Command :: struct {
	conv:    proto.Conv_Id,
	account: proto.Account_Id,
	name:    string, // owned by the command
	on:      bool,
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
roles_event :: proc(c: ^Voice_Client, op: proto.Event_Op, body: []u8) {
	a := &c.auth
	#partial switch op {
	case .Role_Changed:
		r, ok := proto.decode_role(body)
		if !ok {
			return
		}
		_, dir, _, _ := map_entry(&a.roles, r.id)
		delete(dir.name)
		dir^ = {strings.clone(r.name), r.perms}
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

@(private = "file")
role_named :: proc(c: ^Voice_Client, name: string) -> proto.Role_Id {
	for id, r in c.auth.roles {
		if strings.equal_fold(r.name, strings.trim_space(name)) {
			return id
		}
	}
	return 0
}

roles_list :: proc(c: ^Voice_Client) {
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

role_set :: proc(c: ^Voice_Client, cmd: Role_Set_Command) {
	id := cmd.id
	if cmd.by_name {
		id = role_named(c, cmd.name)
		if id == 0 {
			log.warnf("there's no role called %q", cmd.name)
			return
		}
	}
	buf: [proto.ROLE_MAX_SIZE]u8
	body := proto.encode_role(buf[:], {id = id, perms = cmd.perms, name = cmd.name})
	if body == nil {
		notify(c, false, "That name is too long for a role.")
		return
	}
	request(c, .Role_Set, body, manage_done)
}

role_delete :: proc(c: ^Voice_Client, cmd: Role_Delete_Command) {
	id := cmd.id if cmd.id != 0 else role_named(c, cmd.name)
	if id == 0 {
		log.warnf("there's no role called %q", cmd.name)
		return
	}
	buf: [4]u8
	request(c, .Role_Delete, proto.encode_account_id(&buf, proto.Account_Id(id)), manage_done)
}

account_roles_set :: proc(c: ^Voice_Client, cmd: Account_Roles_Command) {
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

account_disable :: proc(c: ^Voice_Client, cmd: Account_Disable_Command) {
	account := cmd.account if cmd.account != 0 else account_named(c, cmd.name)
	if account == 0 {
		log.warn("there's no such account")
		return
	}
	buf: [proto.ACCOUNT_DISABLE_SIZE]u8
	request(c, .Account_Disable, proto.encode_account_disable(&buf, account, cmd.on), manage_done)
}

conv_update :: proc(c: ^Voice_Client, cmd: Conv_Update_Command) {
	conv := cmd.conv if cmd.conv != 0 else c.convs.viewing
	buf: [proto.CONV_UPDATE_MAX_SIZE]u8
	body := proto.encode_conv_update(
		buf[:],
		{
			conv = conv,
			mask = cmd.mask,
			name = cmd.name,
			topic = cmd.topic,
			position = cmd.position,
		},
	)
	if body == nil {
		notify(c, false, "That name or topic is too long.")
		return
	}
	request(c, .Conv_Update, body, manage_done)
}

conv_delete :: proc(c: ^Voice_Client, conv: proto.Conv_Id) {
	buf: [4]u8
	request(
		c,
		.Conv_Delete,
		proto.encode_conv_id(&buf, conv if conv != 0 else c.convs.viewing),
		manage_done,
	)
}

conv_member_set :: proc(c: ^Voice_Client, cmd: Conv_Member_Command) {
	conv := cmd.conv if cmd.conv != 0 else c.convs.viewing
	account := cmd.account if cmd.account != 0 else account_named(c, cmd.name)
	if account == 0 {
		log.warn("there's no such account")
		return
	}
	buf: [proto.CONV_MEMBER_SET_SIZE]u8
	request(
		c,
		.Conv_Member_Set,
		proto.encode_conv_member_set(&buf, conv, account, cmd.on),
		proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
			manage_done(c, status, body, tag)
			// The members shown are fetched again.
			if status == .Ok && c.profiles.members_conv != 0 {
				members_fetch(c, c.profiles.members_conv)
			}
		},
	)
}

// manage_done says what went wrong with a change to the server's roles,
// accounts or channels; what went right shows by itself.
@(private = "file")
manage_done :: proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
	#partial switch status {
	case .Ok, .Reset:
		if c.view == nil && status == .Ok {
			log.info("[manage] done")
		}
	case .Denied:
		notify(c, false, "You aren't allowed to do that.")
	case .Conflict:
		notify(c, false, "That name is taken.")
	case .Not_Found:
		notify(c, false, "That isn't there any more.")
	case .Too_Large:
		notify(c, false, "There are as many of those as there can be.")
	case .Invalid:
		notify(c, false, "That can't be done.")
	case:
		notify(c, false, fmt.tprintf("The server couldn't do that (%v).", status))
	}
}

publish_roles :: proc(c: ^Voice_Client) {
	v := c.view
	if v == nil {
		return
	}
	ids, _ := slice.map_keys(c.auth.roles, context.temp_allocator)
	slice.sort(ids)
	view_write(v)
	view_clear_roles(v)
	for id in ids {
		r := c.auth.roles[id]
		append(&v.roles, View_Role{id, strings.clone(r.name), r.perms})
	}
}

// Call with the mutex held.
view_clear_roles :: proc(v: ^View) {
	for r in v.roles {
		delete(r.name)
	}
	clear(&v.roles)
}

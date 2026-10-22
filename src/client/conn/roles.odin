package conn

import log "common:wlog"
import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"

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
View_Role :: struct {
	id:    proto.Role_Id,
	name:  string, // owned
	perms: proto.Permissions,
	color: u32, // proto.ROLE_COLOR_SET | 0xRRGGBB, or 0
	flags: proto.Role_Flags,
}

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
// Change a channel (0: the one we're looking at) as selected by the mask.
Conv_Update_Command :: struct {
	conv:     proto.Conv_Id,
	mask:     u8,
	name:     string, // owned by the command
	topic:    string, // owned by the command
	position: int,
	flags:    proto.Conv_Flags, // with proto.CONV_UPDATE_FLAGS: Default, Text_Only
}
// Fetches a channel's rights map (View.rights_map), for those who manage
// channels.
Conv_Rights_Get_Command :: struct {
	conv: proto.Conv_Id,
}
// Replaces a channel's rights map.
Conv_Rights_Set_Command :: struct {
	conv:    proto.Conv_Id,
	entries: []proto.Role_Rights, // owned by the command
}
// Headless: turns one of a channel's flags (Default or Text_Only) on or off,
// keeping the other.
Conv_Flag_Command :: struct {
	conv: proto.Conv_Id, // 0: the one we're looking at
	flag: proto.Conv_Flag,
	on:   bool,
}
// Headless: replaces a channel's rights map with one given as text, such as
// "everyone=see,react writers=see,write,edit,delete" (see conv_rights_parse).
Conv_Rights_Text_Command :: struct {
	conv: proto.Conv_Id, // 0: the one we're looking at
	text: string, // owned by the command
}
Conv_Delete_Command :: struct {
	conv: proto.Conv_Id,
}
// Add somebody to a channel (0: the one we're looking at), or remove them from
// a private one. Headless, by name.
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

role_order :: proc(c: ^Voice_Client, cmd: Role_Order_Command) {
	cmd := cmd
	buf: [proto.ROLE_ORDER_MAX_SIZE]u8
	request(c, .Role_Order, proto.encode_role_order(buf[:], cmd.roles[:cmd.count]), manage_done)
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

account_delete :: proc(c: ^Voice_Client, cmd: Account_Delete_Command) {
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
		proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
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
			flags = cmd.flags,
		},
	)
	if body == nil {
		notify(c, false, "The channel name or topic is too long.")
		return
	}
	c.convs.changing += 1
	request(c, .Conv_Update, body, conv_done)
}

// A channel's rights map, as the channel settings show it.
View_Rights_Map :: struct {
	conv:    proto.Conv_Id,
	entries: [dynamic]proto.Role_Rights,
	loading: bool,
	count:   int, // incremented whenever it arrives
}

// conv_rights_fetch asks for a channel's rights map, for the UI (or for the
// log when headless).
conv_rights_fetch :: proc(c: ^Voice_Client, conv: proto.Conv_Id) {
	if conv == 0 {
		return
	}
	publish_rights_map(c, conv, nil, true)
	buf: [4]u8
	request(
		c,
		.Conv_Rights_Get,
		proto.encode_conv_id(&buf, conv),
		proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
			conv := proto.Conv_Id(tag)
			buf: [proto.MAX_ROLES]proto.Role_Rights
			entries, ok := proto.decode_rights_map(body, buf[:])
			if status != .Ok || !ok {
				publish_rights_map(c, conv, nil, false)
				if status != .Reset {
					manage_done(c, status if status != .Ok else .Invalid, nil, 0)
				}
				return
			}
			publish_rights_map(c, conv, entries, false)
			if c.view == nil {
				for e in entries {
					log.infof("[rights] %s: %s", role_name(c, e.role), rights_text(e.rights))
				}
			}
		},
		u64(conv),
	)
}

conv_rights_set :: proc(c: ^Voice_Client, cmd: Conv_Rights_Set_Command) {
	conv := cmd.conv if cmd.conv != 0 else c.convs.viewing
	buf: [proto.CONV_RIGHTS_SET_MAX_SIZE]u8
	body := proto.encode_conv_rights_set(buf[:], conv, cmd.entries)
	if body == nil {
		notify(c, false, "There are too many roles in that.")
		return
	}
	request(
		c,
		.Conv_Rights_Set,
		body,
		proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
			manage_done(c, status, body, tag)
			if status == .Ok && c.view != nil && c.view.rights_map.conv == proto.Conv_Id(tag) {
				conv_rights_fetch(c, proto.Conv_Id(tag))
			}
		},
		u64(conv),
	)
}

conv_flag_set :: proc(c: ^Voice_Client, cmd: Conv_Flag_Command) {
	conv := cmd.conv if cmd.conv != 0 else c.convs.viewing
	info, ok := c.convs.convs[conv]
	if !ok {
		log.warn("that's not one of our channels")
		return
	}
	flags := info.flags & proto.CONV_SETTABLE_FLAGS
	if cmd.on {
		flags += {cmd.flag}
	} else {
		flags -= {cmd.flag}
	}
	conv_update(c, {conv = conv, mask = proto.CONV_UPDATE_FLAGS, flags = flags})
}

// conv_rights_parse reads a rights map written as words of role=rights, the
// rights separated by commas ("none" for none), such as
// "everyone=see,react writers=see,write". A role may be named by its name or
// its number. It returns false, having logged why, if something isn't known.
conv_rights_parse :: proc(
	c: ^Voice_Client,
	text: string,
	buf: []proto.Role_Rights,
) -> (
	entries: []proto.Role_Rights,
	ok: bool,
) {
	count := 0
	for word in strings.fields(text, context.temp_allocator) {
		name, _, list := strings.partition(word, "=")
		role := role_named(c, name)
		if role == 0 {
			if n, is_number := strconv.parse_int(name);
			   is_number && proto.Role_Id(n) in c.auth.roles {
				role = proto.Role_Id(n)
			}
		}
		if role == 0 {
			log.warnf("there's no role called %q", name)
			return
		}
		rights: proto.Conv_Rights
		for r in strings.split(list, ",", context.temp_allocator) {
			found := r == "none" || r == ""
			for right in proto.Conv_Right {
				if strings.equal_fold(r, fmt.tprint(right)) {
					rights += {right}
					found = true
				}
			}
			if !found {
				log.warnf(
					"there's no right called %q (see, write, attach, react, edit, delete, voice)",
					r,
				)
				return
			}
		}
		if count == len(buf) {
			log.warn("that's too many roles")
			return
		}
		buf[count] = {role, rights}
		count += 1
	}
	return buf[:count], true
}

conv_rights_text_set :: proc(c: ^Voice_Client, cmd: Conv_Rights_Text_Command) {
	conv := cmd.conv if cmd.conv != 0 else c.convs.viewing
	buf: [proto.MAX_ROLES]proto.Role_Rights
	if entries, ok := conv_rights_parse(c, cmd.text, buf[:]); ok {
		conv_rights_set(c, {conv = conv, entries = entries})
	}
}

// role_name returns a role's name, or its number if we don't know it.
role_name :: proc(c: ^Voice_Client, id: proto.Role_Id) -> string {
	if r, ok := c.auth.roles[id]; ok {
		return r.name
	}
	return fmt.tprintf("role %d", id)
}

// rights_text names rights for people: "see, write, react", or "none".
rights_text :: proc(rights: proto.Conv_Rights) -> string {
	if rights == {} {
		return "none"
	}
	names := make([dynamic]string, context.temp_allocator)
	for r in proto.Conv_Right {
		if r in rights {
			append(&names, strings.to_lower(fmt.tprint(r), context.temp_allocator))
		}
	}
	return strings.join(names[:], ", ", context.temp_allocator)
}

@(private = "file")
publish_rights_map :: proc(
	c: ^Voice_Client,
	conv: proto.Conv_Id,
	entries: []proto.Role_Rights,
	loading: bool,
) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	clear(&v.rights_map.entries)
	v.rights_map.conv = conv
	append(&v.rights_map.entries, ..entries)
	v.rights_map.loading = loading
	v.rights_map.count += 1
}

conv_delete :: proc(c: ^Voice_Client, conv: proto.Conv_Id) {
	buf: [4]u8
	c.convs.changing += 1
	request(
		c,
		.Conv_Delete,
		proto.encode_conv_id(&buf, conv if conv != 0 else c.convs.viewing),
		conv_done,
	)
}

// conv_done is manage_done for a change to a channel, which may change the
// lists of channels (channels_changed). Moving a channel is several changes at
// once, so that waits for the last one.
@(private = "file")
conv_done :: proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
	manage_done(c, status, body, tag)
	c.convs.changing = max(c.convs.changing - 1, 0)
	if c.convs.changing == 0 && status != .Reset {
		channels_changed(c)
	}
}

conv_member_set :: proc(c: ^Voice_Client, cmd: Conv_Member_Command) {
	conv := cmd.conv if cmd.conv != 0 else c.convs.viewing
	account := cmd.account if cmd.account != 0 else account_named(c, cmd.name)
	if account == 0 {
		log.warn("there's no such account")
		return
	}
	buf: [proto.CONV_MEMBER_SET_SIZE]u8
	c.convs.changing += 1
	request(
		c,
		.Conv_Member_Set,
		proto.encode_conv_member_set(&buf, conv, account, cmd.on),
		proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
			conv_done(c, status, body, tag)
			// Fetch the members shown again.
			if status == .Ok && c.profiles.members_conv != 0 {
				members_fetch(c, c.profiles.members_conv)
			}
		},
	)
}

// manage_done reports what went wrong with a change to the server's roles,
// accounts or channels. Successful changes need no message.
@(private = "file")
manage_done :: proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
	#partial switch status {
	case .Ok, .Reset:
		if c.view == nil && status == .Ok {
			log.info("[manage] done")
		}
	case .Denied:
		notify(c, false, "You don't have permission to do that.")
	case .Conflict:
		notify(c, false, "That name is already taken.")
	case .Not_Found:
		notify(c, false, "That role, account or channel no longer exists.")
	case .Too_Large:
		notify(c, false, "The server has reached the maximum number of roles or channels.")
	case .Invalid:
		notify(c, false, "The server rejected the change as invalid.")
	case:
		notify(c, false, fmt.tprintf("The server failed to apply the change (%v).", status))
	}
}

publish_roles :: proc(c: ^Voice_Client) {
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

// dir_roles returns the roles in the form mentions expect (mentions.odin),
// built from what we know about them rather than from the View. It is allocated
// in the temp allocator and the names are not copied.
dir_roles :: proc(c: ^Voice_Client) -> []View_Role {
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

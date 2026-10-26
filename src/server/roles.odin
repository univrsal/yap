package server

import "core:log"
import "core:slice"
import "core:strings"

import "common:proto"

// Roles (see src/common/proto/roles.odin) determine what an account may do.
// Every account has the `everyone` role. The other roles of an account are
// stored with the account (Account.roles) together with the combined
// permissions of all its roles (Account.perms), which are recalculated
// whenever a role or the roles of an account change. The owner may do
// everything regardless of its roles (see permissions in accounts.odin).
//
// Nobody can give a role more permissions than they have themselves. A role
// whose permissions aren't all held by the asker can't be created, changed,
// deleted, given or taken away by them (see outranks). The owner's account
// can't be disabled, and an account that has more permissions than the
// asker can't be disabled, given a password or have its devices revoked by
// them.
//
// A role's colour and its position in the list (Role_Order) only affect how
// names are displayed. Which role is above another when managing them is
// decided by the permissions they grant. Whether a role can be mentioned
// (Mentionable) is up to whoever may change the role. The everyone role can
// never be mentioned.
//
// What a role may do in a channel is up to that channel's rights map (see
// conv_rights in convs.odin), so a change to roles is followed by
// channel_access_changed.
//
// Like the accounts, there are only a few roles and all of them are kept in
// memory.

Role :: struct {
	id:       proto.Role_Id,
	name:     string, // owned
	perms:    proto.Permissions,
	color:    u32, // proto.ROLE_COLOR_SET | 0xRRGGBB, or 0
	position: int, // a lower number is higher up, ties are broken by id
	flags:    proto.Role_Flags,
}

// roles_load reads the roles and which accounts have them (see accounts_load).
@(require_results)
roles_load :: proc(a: ^Accounts) -> bool {
	q := db_stmt(a.db, .Role_All)
	for {
		row, ok := db_step(a.db, q)
		if !ok {
			return false
		}
		if !row {
			break
		}
		r := new(Role)
		r.id = proto.Role_Id(db_col_int(q, 0))
		r.name = db_col_text(q, 1, context.allocator)
		r.perms = transmute(proto.Permissions)u64(db_col_int(q, 2))
		r.color = u32(db_col_int(q, 3))
		r.position = int(db_col_int(q, 4))
		r.flags = transmute(proto.Role_Flags)u8(db_col_int(q, 5))
		a.roles[r.id] = r
	}
	if proto.EVERYONE_ROLE not_in a.roles {
		log.error("the database has no role for everyone")
		return false
	}
	q = db_stmt(a.db, .Account_Role_All)
	for {
		row, ok := db_step(a.db, q)
		if !ok {
			return false
		}
		if !row {
			break
		}
		acc := a.by_id[proto.Account_Id(db_col_int(q, 0))] or_else nil
		role := proto.Role_Id(db_col_int(q, 1))
		if acc != nil && role in a.roles {
			append(&acc.roles, role)
		}
	}
	for _, acc in a.by_id {
		account_perms_update(a, acc)
	}
	return true
}

roles_destroy :: proc(a: ^Accounts) {
	for _, r in a.roles {
		delete(r.name)
		free(r)
	}
	delete(a.roles)
}

// account_perms_update recalculates the permissions that an account's roles grant it.
account_perms_update :: proc(a: ^Accounts, acc: ^Account) {
	perms := a.roles[proto.EVERYONE_ROLE].perms if proto.EVERYONE_ROLE in a.roles else {}
	for id in acc.roles {
		if r := a.roles[id] or_else nil; r != nil {
			perms += r.perms
		}
	}
	acc.perms = perms
}

// roles_sorted returns the roles in the order given by role_before,
// allocated with the temp allocator.
roles_sorted :: proc(a: ^Accounts) -> []^Role {
	list := make([dynamic]^Role, 0, len(a.roles), context.temp_allocator)
	for _, r in a.roles {
		append(&list, r)
	}
	slice.sort_by(list[:], role_before)
	return list[:]
}

// role_before defines the order in which roles are listed: by position, then
// by creation order, with the everyone role last.
role_before :: proc(x, y: ^Role) -> bool {
	xe, ye := x.id == proto.EVERYONE_ROLE, y.id == proto.EVERYONE_ROLE
	if xe != ye {
		return ye
	}
	if x.position != y.position {
		return x.position < y.position
	}
	return x.id < y.id
}

// role_record converts a role to the record that is sent to clients.
role_record :: proc(r: ^Role) -> proto.Role {
	return {
		id = r.id,
		perms = r.perms,
		name = r.name,
		color = r.color,
		position = u16(clamp(r.position, 0, int(max(u16)))),
		flags = r.flags,
	}
}

role_by_name :: proc(a: ^Accounts, name: string) -> ^Role {
	for _, r in a.roles {
		if strings.equal_fold(r.name, name) {
			return r
		}
	}
	return nil
}

// outranks returns whether an account may do everything that `perms` allow.
// If so, it may manage roles and accounts that have these permissions.
outranks :: proc(acc: ^Account, perms: proto.Permissions) -> bool {
	return perms <= permissions(acc)
}

// account_roles_set gives an account these roles in addition to the
// everyone role, both in the database and in memory.
account_roles_set :: proc(a: ^Accounts, acc: ^Account, roles: []proto.Role_Id) -> bool {
	q := db_query(a.db, .Account_Roles_Clear, i64(acc.id))
	db_run(a.db, q) or_return
	for role in roles {
		q = db_query(a.db, .Account_Role_Add, i64(acc.id), i64(role))
		db_run(a.db, q) or_return
	}
	clear(&acc.roles)
	append(&acc.roles, ..roles)
	account_perms_update(a, acc)
	return true
}

// role_request handles a request about roles. Returns false if `op` isn't one.
role_request :: proc(s: ^Server, u: ^Conn, id: u32, op: proto.Request_Op, body: []u8) -> bool {
	#partial switch op {
	case .Role_Set:
		role_set(s, u, id, body)
	case .Role_Delete:
		role_delete(s, u, id, body)
	case .Account_Roles_Set:
		account_roles_request(s, u, id, body)
	case .Account_Disable:
		account_disable(s, u, id, body)
	case .Role_Order:
		role_order(s, u, id, body)
	case:
		return false
	}
	return true
}

@(private = "file")
role_set :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	in_role, ok := proto.decode_role(body)
	a := &s.accounts
	name_buf: [proto.MAX_ROLE_NAME]u8
	name := proto.sanitize_text(in_role.name, name_buf[:])
	existing := a.roles[in_role.id] or_else nil
	switch {
	case !can(u.account, .Manage_Roles):
		respond(u, id, .Denied)
		return
	case !ok || !proto.role_name_ok(name):
		respond(u, id, .Invalid)
		return
	case in_role.id != 0 && existing == nil:
		respond(u, id, .Not_Found)
		return
	case !outranks(u.account, in_role.perms),
	     existing != nil &&
	     !outranks(u.account, existing.perms):
		respond(u, id, .Denied)
		return
	case in_role.id == proto.EVERYONE_ROLE && name != existing.name:
		// The name of the everyone role can't be changed.
		respond(u, id, .Invalid)
		return
	}
	if other := role_by_name(a, name); other != nil && other != existing {
		respond(u, id, .Conflict)
		return
	}
	// Drop any bits that aren't valid permissions.
	known: proto.Permissions
	for p in proto.Permission {
		known += {p}
	}
	perms := in_role.perms & known
	// The everyone role has no colour, since it would apply to every account.
	color := in_role.color if in_role.id != proto.EVERYONE_ROLE else 0
	// It can't be mentioned either, because that is what @everyone does.
	flags := in_role.flags if in_role.id != proto.EVERYONE_ROLE else {}
	if existing == nil {
		if len(a.roles) >= proto.MAX_ROLES {
			respond(u, id, .Too_Large)
			return
		}
		// A new role is added below all the others.
		position := 0
		for _, r in a.roles {
			position = max(position, r.position + 1)
		}
		q := db_query(
			a.db,
			.Role_Add,
			name,
			i64(transmute(u64)perms),
			i64(color),
			i64(position),
			i64(transmute(u8)flags),
		)
		if !db_run(a.db, q) {
			respond(u, id, .Internal)
			return
		}
		existing = new(Role)
		existing.id = proto.Role_Id(db_last_id(a.db))
		existing.name = strings.clone(name)
		existing.perms = perms
		existing.color = color
		existing.position = position
		existing.flags = flags
		a.roles[existing.id] = existing
		log.infof("%s made the role %q", conn_label(u), name)
	} else {
		q := db_query(
			a.db,
			.Role_Update,
			i64(existing.id),
			name,
			i64(transmute(u64)perms),
			i64(color),
			i64(transmute(u8)flags),
		)
		if !db_run(a.db, q) {
			respond(u, id, .Internal)
			return
		}
		delete(existing.name)
		existing.name = strings.clone(name)
		existing.perms = perms
		existing.color = color
		existing.flags = flags
		log.infof("%s changed the role %q", conn_label(u), name)
	}
	buf: [4]u8
	respond(u, id, .Ok, encode_role_id(&buf, existing.id))
	roles_changed(s, existing)
}

@(private = "file")
encode_role_id :: proc(out: ^[4]u8, id: proto.Role_Id) -> []u8 {
	return proto.encode_account_id(out, proto.Account_Id(id))
}

// role_order puts the roles in the given order, with the top role first. The
// list must contain every role except the everyone role, each exactly once.
// The order only decides which role's colour a name is displayed with, so
// anyone with Manage_Roles may change it, regardless of what the roles allow.
@(private = "file")
role_order :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	a := &s.accounts
	buf: [proto.MAX_ROLES]proto.Role_Id
	order, ok := proto.decode_role_order(body, buf[:])
	switch {
	case !can(u.account, .Manage_Roles):
		respond(u, id, .Denied)
		return
	case !ok || len(order) != len(a.roles) - 1:
		respond(u, id, .Invalid)
		return
	}
	for role, i in order {
		if role == proto.EVERYONE_ROLE || role not_in a.roles || slice.contains(order[:i], role) {
			respond(u, id, .Invalid)
			return
		}
	}
	moved := make([dynamic]^Role, context.temp_allocator)
	for role, i in order {
		r := a.roles[role]
		if r.position == i {
			continue
		}
		if !db_write(a.db, .Role_Set_Position, i64(role), i64(i)) {
			respond(u, id, .Internal)
			return
		}
		r.position = i
		append(&moved, r)
	}
	log.infof("%s put the roles in a new order", conn_label(u))
	respond(u, id, .Ok)
	rec_buf: [proto.ROLE_MAX_SIZE]u8
	for r in moved {
		changed := proto.encode_role(rec_buf[:], role_record(r))
		for _, other in s.conns {
			if other.account != nil {
				send_event(other, .Role_Changed, changed)
			}
		}
	}
}

@(private = "file")
role_delete :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	raw, ok := proto.decode_account_id(body)
	role_id := proto.Role_Id(raw)
	a := &s.accounts
	r := a.roles[role_id] or_else nil
	switch {
	case !can(u.account, .Manage_Roles):
		respond(u, id, .Denied)
		return
	case !ok || role_id == proto.EVERYONE_ROLE:
		respond(u, id, .Invalid)
		return
	case r == nil:
		respond(u, id, .Not_Found)
		return
	case !outranks(u.account, r.perms):
		respond(u, id, .Denied)
		return
	}
	q := db_query(a.db, .Role_Unassign_All, i64(role_id))
	if !db_run(a.db, q) {
		respond(u, id, .Internal)
		return
	}
	// It leaves every channel's rights map (see conv_rights).
	if !conv_rights_role_gone(&s.convs, role_id) {
		respond(u, id, .Internal)
		return
	}
	q = db_query(a.db, .Role_Delete, i64(role_id))
	if !db_run(a.db, q) {
		respond(u, id, .Internal)
		return
	}
	log.infof("%s deleted the role %q", conn_label(u), r.name)
	delete_key(&a.roles, role_id)
	delete(r.name)
	free(r)
	respond(u, id, .Ok)
	// Accounts that had the role lose it.
	for _, acc in a.by_id {
		if i, found := slice.linear_search(acc.roles[:], role_id); found {
			ordered_remove(&acc.roles, i)
			account_perms_update(a, acc)
			account_changed(s, acc)
		}
	}
	buf: [4]u8
	gone := proto.encode_account_id(&buf, proto.Account_Id(role_id))
	for _, other in s.conns {
		if other.account != nil {
			send_event(other, .Role_Removed, gone)
		}
	}
	channel_access_changed(s)
}

@(private = "file")
account_roles_request :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	buf: [proto.MAX_ACCOUNT_ROLES]proto.Role_Id
	account, wanted, ok := proto.decode_account_roles(body, buf[:])
	a := &s.accounts
	target := account_live(a, account)
	switch {
	case !can(u.account, .Manage_Roles):
		respond(u, id, .Denied)
		return
	case !ok:
		respond(u, id, .Invalid)
		return
	case target == nil:
		respond(u, id, .Not_Found)
		return
	}
	// The roles the account is to have. Each must exist, must not be the
	// everyone role and is only counted once.
	roles := make([dynamic]proto.Role_Id, context.temp_allocator)
	for role in wanted {
		if role not_in a.roles || role == proto.EVERYONE_ROLE {
			respond(u, id, .Invalid)
			return
		}
		if !slice.contains(roles[:], role) {
			append(&roles, role)
		}
	}
	// The asker must be allowed to give or take away every role that changes.
	for role in roles {
		if !slice.contains(target.roles[:], role) && !outranks(u.account, a.roles[role].perms) {
			respond(u, id, .Denied)
			return
		}
	}
	for role in target.roles {
		if !slice.contains(roles[:], role) && !outranks(u.account, a.roles[role].perms) {
			respond(u, id, .Denied)
			return
		}
	}
	if !account_roles_set(a, target, roles[:]) {
		respond(u, id, .Internal)
		return
	}
	log.infof("%s gave %s %d role(s)", conn_label(u), target.username, len(roles))
	respond(u, id, .Ok)
	account_changed(s, target)
	// What the account may do in channels comes from its roles.
	channel_access_changed(s)
}

@(private = "file")
account_disable :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	account, on, ok := proto.decode_account_disable(body)
	target := account_live(&s.accounts, account)
	switch {
	case !can(u.account, .Manage_Accounts):
		respond(u, id, .Denied)
		return
	case !ok:
		respond(u, id, .Invalid)
		return
	case target == nil:
		respond(u, id, .Not_Found)
		return
	case .Owner in target.flags || target == u.account:
		respond(u, id, .Invalid)
		return
	case !outranks(u.account, permissions(target)):
		respond(u, id, .Denied)
		return
	}
	flags := target.flags + {.Disabled} if on else target.flags - {.Disabled}
	// Enabling a banned account ends its ban (bans.odin).
	if (!on && !ban_remove(&s.accounts, target.id)) ||
	   !account_set_flags(&s.accounts, target, flags) {
		respond(u, id, .Internal)
		return
	}
	log.infof("%s %s %s", conn_label(u), "disabled" if on else "enabled", target.username)
	respond(u, id, .Ok)
	if on {
		// The account keeps its devices, but they can't log in until the
		// account is enabled again.
		conns := make([dynamic]^Conn, context.temp_allocator)
		append(&conns, ..target.conns[:])
		for other in conns {
			conn_logout(s, other, .Disabled)
		}
	}
	account_changed(s, target)
}

// roles_changed tells everyone who is logged in about a role that was
// created or changed. The accounts that have the role are also told what
// they may do now (Self). The record that everyone has of an account
// doesn't change because it only contains the names of its roles.
roles_changed :: proc(s: ^Server, r: ^Role) {
	buf: [proto.ROLE_MAX_SIZE]u8
	body := proto.encode_role(buf[:], role_record(r))
	for _, acc in s.accounts.by_id {
		if r.id == proto.EVERYONE_ROLE || slice.contains(acc.roles[:], r.id) {
			account_perms_update(&s.accounts, acc)
		}
	}
	for _, other in s.conns {
		if other.account != nil {
			send_event(other, .Role_Changed, body)
			send_self(other)
		}
	}
	// Manage_Channels, given or taken away, decides what may be done in every
	// channel.
	channel_access_changed(s)
}

// send_roles sends every role to a connection that just logged in (see
// directory_sync).
send_roles :: proc(s: ^Server, u: ^Conn) {
	buf: [proto.ROLE_MAX_SIZE]u8
	for r in roles_sorted(&s.accounts) {
		send_event(u, .Role_Changed, proto.encode_role(buf[:], role_record(r)))
	}
}

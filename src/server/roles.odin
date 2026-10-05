package server

import "core:log"
import "core:slice"
import "core:strings"

import "common:proto"

/*
Roles (src/common/proto/roles.odin): what an account may do comes from
them. Every account has `everyone`; the others it has are kept with it
(Account.roles), and what they add up to too (Account.perms), worked
out again whenever a role or an account's roles change. The owner may
do everything whatever its roles (permissions, accounts.odin).

Nobody can make a role do more than they may themselves: a role whose
permissions aren't all the asker's can't be made, changed, deleted,
given or taken away by them (outranks). Nor can the owner's account be
disabled, and an account that may do more than the asker can't be
disabled, given a password or have its devices revoked by them.

A role's colour and its place in the list (Role_Order) are only for
showing names: which role is above another for handling them goes by
what they allow.

Like the accounts, roles are few and all kept in memory.
*/

Role :: struct {
	id:       proto.Role_Id,
	name:     string, // owned
	perms:    proto.Permissions,
	color:    u32, // proto.ROLE_COLOR_SET | 0xRRGGBB, or 0
	position: int, // lower is higher up; ties go by id
}

// roles_load reads the roles and who has them (accounts_load).
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

// account_perms_update works out again what an account's roles let it do.
account_perms_update :: proc(a: ^Accounts, acc: ^Account) {
	perms := a.roles[proto.EVERYONE_ROLE].perms if proto.EVERYONE_ROLE in a.roles else {}
	for id in acc.roles {
		if r := a.roles[id] or_else nil; r != nil {
			perms += r.perms
		}
	}
	acc.perms = perms
}

// roles_sorted is the roles, everyone's first, then by id; in the temp
// allocator.
roles_sorted :: proc(a: ^Accounts) -> []^Role {
	list := make([dynamic]^Role, 0, len(a.roles), context.temp_allocator)
	for _, r in a.roles {
		append(&list, r)
	}
	slice.sort_by(list[:], role_before)
	return list[:]
}

// role_before is the order roles are listed in: by position, then as
// they were made, with everyone's last.
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

// role_record is a role as it's told.
role_record :: proc(r: ^Role) -> proto.Role {
	return {
		id = r.id,
		perms = r.perms,
		name = r.name,
		color = r.color,
		position = u16(clamp(r.position, 0, int(max(u16)))),
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

// outranks is whether an account may do everything `perms` allow, and so
// may handle a role, or an account, with them.
outranks :: proc(acc: ^Account, perms: proto.Permissions) -> bool {
	return perms <= permissions(acc)
}

// account_roles_set gives an account these roles besides everyone's, in
// the database and here.
account_roles_set :: proc(a: ^Accounts, acc: ^Account, roles: []proto.Role_Id) -> bool {
	q := db_stmt(a.db, .Account_Roles_Clear)
	db_bind_int(q, 1, i64(acc.id))
	db_run(a.db, q) or_return
	for role in roles {
		q = db_stmt(a.db, .Account_Role_Add)
		db_bind_int(q, 1, i64(acc.id))
		db_bind_int(q, 2, i64(role))
		db_run(a.db, q) or_return
	}
	clear(&acc.roles)
	append(&acc.roles, ..roles)
	account_perms_update(a, acc)
	return true
}

// role_request handles a request about roles; false if `op` isn't one.
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
		// Its name is what it is.
		respond(u, id, .Invalid)
		return
	}
	if other := role_by_name(a, name); other != nil && other != existing {
		respond(u, id, .Conflict)
		return
	}
	// Only the bits there are.
	known: proto.Permissions
	for p in proto.Permission {
		known += {p}
	}
	perms := in_role.perms & known
	// Everyone's role has no colour: it would be everybody's.
	color := in_role.color if in_role.id != proto.EVERYONE_ROLE else 0
	if existing == nil {
		if len(a.roles) >= proto.MAX_ROLES {
			respond(u, id, .Too_Large)
			return
		}
		// A new role goes under the others.
		position := 0
		for _, r in a.roles {
			position = max(position, r.position + 1)
		}
		q := db_stmt(a.db, .Role_Add)
		db_bind_text(q, 1, name)
		db_bind_int(q, 2, i64(transmute(u64)perms))
		db_bind_int(q, 3, i64(color))
		db_bind_int(q, 4, i64(position))
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
		a.roles[existing.id] = existing
		log.infof("%s made the role %q", conn_label(u), name)
	} else {
		q := db_stmt(a.db, .Role_Update)
		db_bind_int(q, 1, i64(existing.id))
		db_bind_text(q, 2, name)
		db_bind_int(q, 3, i64(transmute(u64)perms))
		db_bind_int(q, 4, i64(color))
		if !db_run(a.db, q) {
			respond(u, id, .Internal)
			return
		}
		delete(existing.name)
		existing.name = strings.clone(name)
		existing.perms = perms
		existing.color = color
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

/*
role_order puts the roles in the order given, top first: every role but
everyone's, each once. It only changes whose colour a name takes, so
whoever has Manage_Roles may, whatever the roles allow.
*/
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
		q := db_stmt(a.db, .Role_Set_Position)
		db_bind_int(q, 1, i64(role))
		db_bind_int(q, 2, i64(i))
		if !db_run(a.db, q) {
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
	q := db_stmt(a.db, .Role_Unassign_All)
	db_bind_int(q, 1, i64(role_id))
	if !db_run(a.db, q) {
		respond(u, id, .Internal)
		return
	}
	q = db_stmt(a.db, .Role_Delete)
	db_bind_int(q, 1, i64(role_id))
	if !db_run(a.db, q) {
		respond(u, id, .Internal)
		return
	}
	log.infof("%s deleted the role %q", conn_label(u), r.name)
	delete_key(&a.roles, role_id)
	delete(r.name)
	free(r)
	respond(u, id, .Ok)
	// Whoever had it hasn't any more.
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
	// The roles it's to have: each one there is, and not everyone's,
	// once.
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
	// What changes has to be the asker's to give or take.
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
	if !account_set_flags(&s.accounts, target, flags) {
		respond(u, id, .Internal)
		return
	}
	log.infof("%s %s %s", conn_label(u), "disabled" if on else "enabled", target.username)
	respond(u, id, .Ok)
	if on {
		// Its devices stay its own, and can't get in until it's enabled.
		conns := make([dynamic]^Conn, context.temp_allocator)
		append(&conns, ..target.conns[:])
		for other in conns {
			conn_logout(s, other, .Disabled)
		}
	}
	account_changed(s, target)
}

/*
roles_changed tells everyone logged in about a role, new or changed, and
the accounts that have it what they may do now (Self). The record
everyone has of an account doesn't change: it names its roles.
*/
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
}

// send_roles tells a connection that just logged in every role
// (directory_sync).
send_roles :: proc(s: ^Server, u: ^Conn) {
	buf: [proto.ROLE_MAX_SIZE]u8
	for r in roles_sorted(&s.accounts) {
		send_event(u, .Role_Changed, proto.encode_role(buf[:], role_record(r)))
	}
}

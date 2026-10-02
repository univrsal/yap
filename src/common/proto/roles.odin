package proto

/*
Roles: what an account may do beyond what everyone may (Permission,
accounts.odin) comes from its roles, the union of theirs.

Every account has the role `everyone` (EVERYONE_ROLE), whose permissions
are what a plain member may do. The owner (Account_Flag.Owner, one
account) may do everything whatever its roles. Other roles are made by
whoever has Manage_Roles, who can't give a role a permission they don't
have themselves, nor change, delete, give or take a role that has one.

	Role_Set           [id u32][perms u64][name str8]  ->  [id u32]
	                   id 0 makes a role; else changes that one
	Role_Delete        [id u32]
	Account_Roles_Set  [account u32][count u8][role u32]...  the account's
	                   roles besides `everyone`
	Account_Disable    [account u32][on u8]: it can't log in, and its
	                   devices are logged out; never the owner

	Role_Changed       a role, new or changed
	Role_Removed       [id u32]

	role     [id u32][perms u64][name str8]

Roles are told in the login sync before the accounts (whose records name
their roles), and as they change after; Self again when a connection's
own permissions change.
*/

Role_Id :: distinct u32

// The role every account has; made with the database.
EVERYONE_ROLE :: Role_Id(1)

MIN_ROLE_NAME :: 1
MAX_ROLE_NAME :: 32
// How many roles a server may have, and an account.
MAX_ROLES :: 64
MAX_ACCOUNT_ROLES :: 16

Role :: struct {
	id:    Role_Id,
	perms: Permissions,
	name:  string,
}

ROLE_MAX_SIZE :: 4 + 8 + 1 + MAX_ROLE_NAME

encode_role :: proc(out: []u8, role: Role) -> []u8 {
	w := Writer {
		buf = out,
	}
	put_u32(&w, u32(role.id))
	put_u64(&w, transmute(u64)role.perms)
	put_str8(&w, role.name)
	return nil if w.overflow else out[:w.pos]
}

decode_role :: proc(body: []u8) -> (role: Role, ok: bool) {
	r := Reader {
		buf = body,
	}
	role.id = Role_Id(get_u32(&r))
	role.perms = transmute(Permissions)get_u64(&r)
	role.name = get_str8(&r)
	return role, !r.overflow
}

ACCOUNT_ROLES_MAX_SIZE :: 4 + 1 + 4 * MAX_ACCOUNT_ROLES

encode_account_roles :: proc(out: []u8, account: Account_Id, roles: []Role_Id) -> []u8 {
	w := Writer {
		buf = out,
	}
	put_u32(&w, u32(account))
	put_u8(&w, u8(min(len(roles), 255)))
	for role in roles {
		put_u32(&w, u32(role))
	}
	return nil if w.overflow || len(roles) > 255 else out[:w.pos]
}

// decode_account_roles reads one; the roles are in `buf`.
decode_account_roles :: proc(body: []u8, buf: []Role_Id) -> (account: Account_Id, roles: []Role_Id, ok: bool) {
	r := Reader {
		buf = body,
	}
	account = Account_Id(get_u32(&r))
	count := int(get_u8(&r))
	if r.overflow || count > len(buf) {
		return
	}
	for &role in buf[:count] {
		role = Role_Id(get_u32(&r))
	}
	return account, buf[:count], !r.overflow
}

ACCOUNT_DISABLE_SIZE :: 4 + 1

encode_account_disable :: proc(out: ^[ACCOUNT_DISABLE_SIZE]u8, account: Account_Id, on: bool) -> []u8 {
	w := Writer {
		buf = out[:],
	}
	put_u32(&w, u32(account))
	put_u8(&w, u8(on))
	return out[:]
}

decode_account_disable :: proc(body: []u8) -> (account: Account_Id, on: bool, ok: bool) {
	r := Reader {
		buf = body,
	}
	account = Account_Id(get_u32(&r))
	on = get_u8(&r) != 0
	return account, on, !r.overflow
}

// role_name_ok is whether `name` (sanitized) may be a role's.
role_name_ok :: proc(name: string) -> bool {
	return len(name) >= MIN_ROLE_NAME && len(name) <= MAX_ROLE_NAME
}

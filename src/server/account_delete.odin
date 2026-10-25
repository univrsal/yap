package server

import "core:fmt"
import "core:log"
import "core:slice"
import "core:strings"

import "common:proto"

// Deleting an account (Account_Delete, src/common/proto/accounts.odin).
//
// The account's row is kept as a tombstone so that everything it wrote
// still has an author. The row is flagged Deleted and named DELETED_NAME.
// Its username becomes `deleted#<id>`, which nobody can log in with
// because '#' is never part of a username. Its password is removed, and
// so is everything else that belonged only to it: its devices, roles,
// memberships (including what it had read), buddies (both its own list
// and its place in everyone else's), settings and pending mentions.
// Its messages, reactions and pins stay. The other side of a DM with it
// can still read the conversation but can't write to it (see dm_closed).
//
// The blob of its picture is left for retention's garbage collection
// (retention.odin), which removes unused blobs within the hour. The blob
// isn't removed here because the same picture can belong to another
// account too.
//
// The request is in auth.odin and requires the account's own password
// when an account deletes itself. The command line's `account delete`
// is in cli_account.odin.

// deleted_username is the username a deleted account is given.
deleted_username :: proc(id: proto.Account_Id, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("deleted#%d", id, allocator = allocator)
}

// account_erase_rows is the database part of deleting an account.
// Either all of the rows are changed or, if anything fails, none are.
@(require_results)
account_erase_rows :: proc(db: ^DB, id: proto.Account_Id) -> bool {
	db_begin(db)
	if !db_exec(db, "SAVEPOINT account_erase") {
		return false
	}
	ok := false
	defer if !ok {
		db_exec(db, "ROLLBACK TO account_erase")
		db_exec(db, "RELEASE account_erase")
	}
	q := db_stmt(db, .Account_Erase)
	db_bind_int(q, 1, i64(id))
	db_bind_text(q, 2, deleted_username(id))
	db_bind_text(q, 3, proto.DELETED_NAME)
	db_bind_int(q, 4, i64(transmute(u8)proto.Account_Flags{.Deleted}))
	db_run(db, q) or_return
	for stmt in ([]Stmt {
			.Device_Erase,
			.Buddy_Erase,
			.Setting_Erase,
			.Mention_Erase,
			.Member_Erase,
			.Account_Roles_Clear,
			.Invite_Erase,
		}) {
		q = db_stmt(db, stmt)
		db_bind_int(q, 1, i64(id))
		db_run(db, q) or_return
	}
	db_exec(db, "RELEASE account_erase") or_return
	ok = true
	return true
}

// account_erase deletes an account on a running server. It removes the
// rows from the database, logs out the account's connections (telling
// them why), updates the server's in-memory copy to match and finally
// tells everyone about what is left of the account.
// The caller must already have checked that the account may be deleted.
@(require_results)
account_erase :: proc(s: ^Server, acc: ^Account) -> bool {
	a := &s.accounts
	if !account_erase_rows(&s.db, acc.id) {
		return false
	}
	username := strings.clone(acc.username, context.temp_allocator)

	// Anything the connections were in the middle of ends here.
	conns := slice.clone(acc.conns[:], context.temp_allocator)
	for u in conns {
		conn_logout(s, u, .Deleted)
	}
	for key, d in a.devices {
		if d.account == acc.id {
			delete_key(&a.devices, key)
			delete(d.name)
			free(d)
		}
	}
	for _, conv in s.convs.by_id {
		if i, found := slice.linear_search(conv.members[:], acc.id); found {
			ordered_remove(&conv.members, i)
			delete_key(&conv.reads, acc.id)
			room_check(s, conv)
		}
	}
	// Remove it from everyone's buddy list and tell them.
	buf: [proto.BUDDY_SET_SIZE]u8
	gone := proto.encode_buddy(&buf, acc.id, false)
	for _, other in a.by_id {
		if i, found := slice.linear_search(other.buddies[:], acc.id); found {
			ordered_remove(&other.buddies, i)
			for c in other.conns {
				send_event(c, .Buddy_Changed, gone)
			}
		}
	}

	delete_key(&a.by_name, acc.username)
	delete(acc.username)
	acc.username = deleted_username(acc.id, context.allocator)
	a.by_name[acc.username] = acc
	delete(acc.display)
	acc.display = strings.clone(proto.DELETED_NAME)
	delete(acc.status)
	delete(acc.email)
	delete(acc.verify_code)
	acc.status, acc.status_until, acc.avatar, acc.email = "", 0, 0, ""
	acc.verify_code, acc.verify_expires = "", 0
	acc.flags = {.Deleted}
	acc.chosen = .Online
	clear(&acc.buddies)
	clear(&acc.roles)
	account_perms_update(a, acc)
	acc.failures, acc.locked_until = 0, {}
	acc.shown = activity_of(acc)
	log.infof("the account %s (%d) was deleted", username, acc.id)
	account_changed(s, acc)
	return true
}

// dm_closed is whether a conversation is a DM with an account that has
// been deleted. Such a conversation can still be read but not written to.
dm_closed :: proc(s: ^Server, conv: ^Conv) -> bool {
	if conv.kind != .DM {
		return false
	}
	for id in ([]proto.Account_Id{conv.a, conv.b}) {
		if acc := account_by_id(&s.accounts, id); acc == nil || .Deleted in acc.flags {
			return true
		}
	}
	return false
}

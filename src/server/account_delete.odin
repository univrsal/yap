package server

import "core:fmt"
import "core:log"
import "core:slice"
import "core:strings"

import "common:proto"

/*
Deleting an account (Account_Delete, src/common/proto/accounts.odin).

The account's row stays, as a tombstone, so that everything it wrote
still has an author: flagged Deleted, called DELETED_NAME, with a
username nobody can log in with (`deleted#<id>`: '#' is never in a
username), its password gone, and nothing else of its own. Its devices,
roles, memberships (with what it had read), buddies (its own, and its
place in everyone else's), settings and the mentions waiting for it go
with it. Its messages, reactions and pins stay; a DM with it can still
be read by the other side, but not written to (dm_closed).

Its picture's blob is left to retention's collection (retention.odin),
which removes blobs nothing uses within the hour: the same picture can
be somebody else's too.

The request, which takes the account's own password when it's deleting
itself, is in auth.odin; the command line's `account delete` is in
cli.odin.
*/

// deleted_username is what a deleted account's username becomes.
deleted_username :: proc(id: proto.Account_Id, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("deleted#%d", id, allocator = allocator)
}

/*
account_erase_rows is the database's part of deleting an account: all of
it or, if anything fails, none of it.
*/
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
		}) {
		q = db_stmt(db, stmt)
		db_bind_int(q, 1, i64(id))
		db_run(db, q) or_return
	}
	db_exec(db, "RELEASE account_erase") or_return
	ok = true
	return true
}

/*
account_erase deletes an account on a running server: its connections
are logged out (told why), the database's rows go, and the server's
own copy is made to match; then everyone is told what's left of it.
The caller has made sure it may be deleted.
*/
@(require_results)
account_erase :: proc(s: ^Server, acc: ^Account) -> bool {
	a := &s.accounts
	if !account_erase_rows(&s.db, acc.id) {
		return false
	}
	username := strings.clone(acc.username, context.temp_allocator)

	// Whatever its connections were in the middle of ends.
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
	// Out of everyone's buddy list, and they're told.
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
	acc.status, acc.status_until, acc.avatar, acc.email = "", 0, 0, ""
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
// been deleted: what's there can be read, but nothing more said.
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

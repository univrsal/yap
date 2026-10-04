package client

import "core:fmt"
import "core:slice"
import "core:strings"

import "client:conn"
import "client:settings"
import "common:proto"

// The buddy screen's list: our account's buddies, kept by the server,
// and everyone else we have a DM with (conn/buddies.odin).

// Buddy_Entry is someone in the buddy screen's list.
Buddy_Entry :: struct {
	account: proto.Account_Id,
	name:    string, // points into the View, or the temp allocator
	online:  bool,
	buddy:   bool, // or just someone we have a DM with
	conv:    proto.Conv_Id, // our DM with them, 0 for none yet
	unread:  int, // messages in it we haven't read
}

/*
buddy_list is every buddy and everyone else we have a DM with, online
ones first, then by name. A DM that was taken off the list (hidden, in
the settings) stays off until something new is said in it. The slice is
in the temp allocator; call with the View locked.
*/
buddy_list :: proc(s: ^settings.Settings, v: ^conn.View) -> []Buddy_Entry {
	list := make([dynamic]Buddy_Entry, 0, len(v.buddies) + len(v.dms), context.temp_allocator)
	for b in v.buddies {
		if b != v.me {
			append(&list, buddy_entry(v, b, true))
		}
	}
	for dm in v.dms {
		if slice.contains(v.buddies[:], dm.with) ||
		   settings.dm_hidden(s, v.server_key, dm.id, dm.last) {
			continue
		}
		append(&list, buddy_entry(v, dm.with, false))
	}
	slice.sort_by(list[:], proc(a, b: Buddy_Entry) -> bool {
		if a.online != b.online {
			return a.online
		}
		an := strings.to_lower(a.name, context.temp_allocator)
		bn := strings.to_lower(b.name, context.temp_allocator)
		return an < bn if an != bn else a.account < b.account
	})
	return list[:]
}

// buddy_entry is what the list says about an account. Call with the
// View locked.
buddy_entry :: proc(v: ^conn.View, account: proto.Account_Id, buddy: bool) -> Buddy_Entry {
	e := Buddy_Entry {
		account = account,
		buddy   = buddy,
	}
	if acc, ok := v.accounts[account]; ok {
		e.name = acc.display
	} else {
		e.name = fmt.tprintf("account #%d", account)
	}
	for dm in v.dms {
		if dm.with == account {
			e.conv = dm.id
			e.unread = dm.unread
			break
		}
	}
	for num, u in v.users {
		if u.account == account && num != v.my_num {
			e.online = true
			break
		}
	}
	return e
}

// dm_unread is how many messages in DMs haven't been read, in all: in
// those that aren't muted, nor taken off the list. Call with the View
// locked.
dm_unread :: proc(s: ^settings.Settings, v: ^conn.View) -> (n: int) {
	for dm in v.dms {
		if dm.notify != .None && !settings.dm_hidden(s, v.server_key, dm.id, dm.last) {
			n += dm.unread
		}
	}
	return
}

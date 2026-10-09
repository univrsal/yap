package client

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"

import "client:conn"
import "client:settings"
import "common:proto"

// The buddy screen's list: our account's buddies, kept by the server,
// and everyone else we have a DM with (conn/buddies.odin), on every
// server at once (inbox_list).

// Buddy_Entry is someone in the buddy screen's list.
Buddy_Entry :: struct {
	account:   proto.Account_Id,
	name:      string, // points into the View, or the temp allocator
	status:    string, // theirs, as a list shows it (status_line); the same
	online:    bool,
	buddy:     bool, // or just someone we have a DM with
	conv:      proto.Conv_Id, // our DM with them, 0 for none yet
	unread:    int, // messages in it we haven't read
	last_time: proto.Unix_Ms, // when the newest message in it was posted
	// The server they're on, from inbox_list: an account is only someone
	// on its own server, so the same person on two is two entries.
	ns:        ^Net_Session,
	server:    string, // its name, in the temp allocator
}

/*
buddy_list is every buddy and everyone else we have a DM with, in the
order buddy_before puts them. A DM that was taken off the list (hidden,
in the settings) stays off until something new is said in it. The
slice is in the temp allocator; call with the View locked.
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
	slice.sort_by(list[:], buddy_before)
	return list[:]
}

/*
buddy_before is the list's order: buddies, then everyone else we have
a DM with; in each, the conversation with the newest message first,
then those who are here, then by name. The newest message's time is
what's compared across servers, whose message ids aren't.
*/
buddy_before :: proc(a, b: Buddy_Entry) -> bool {
	if a.buddy != b.buddy {
		return a.buddy
	}
	if a.last_time != b.last_time {
		return a.last_time > b.last_time
	}
	if a.online != b.online {
		return a.online
	}
	an := strings.to_lower(a.name, context.temp_allocator)
	bn := strings.to_lower(b.name, context.temp_allocator)
	if an != bn {
		return an < bn
	}
	if a.ns != b.ns {
		return uintptr(rawptr(a.ns)) < uintptr(rawptr(b.ns))
	}
	return a.account < b.account
}

/*
inbox_list is buddy_list for every server we're logged in to, in one
list, in buddy_before's order. Each server's View is locked in turn, so
call it with none locked; the slice and its strings are in the temp
allocator. While it's at it, it has each server asked when those who
aren't here were last (ask_last_seen).
*/
inbox_list :: proc(ui: ^UI) -> []Buddy_Entry {
	list := make([dynamic]Buddy_Entry, context.temp_allocator)
	for ns in ui.sessions {
		if ns.joining {
			continue
		}
		v := &ns.view
		sync.guard(&v.mutex)
		if v.status != .Connected || v.login.state != .Done || v.login.must_change || v.login.unverified {
			continue
		}
		server := v.server_name if v.server_name != "" else ns.server
		server = strings.clone(server, context.temp_allocator)
		mine := buddy_list(&ui.settings, v)
		for &e in mine {
			e.name = strings.clone(e.name, context.temp_allocator)
			e.status = strings.clone(e.status, context.temp_allocator)
			e.ns, e.server = ns, server
		}
		ask_last_seen(ui, ns, mine)
		append(&list, ..mine)
	}
	slice.sort_by(list[:], buddy_before)
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
		e.status = status_line(acc)
	} else {
		e.name = fmt.tprintf("account #%d", account)
	}
	for dm in v.dms {
		if dm.with == account {
			e.conv = dm.id
			e.unread = dm.unread
			e.last_time = dm.last_time
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

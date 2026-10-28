package client

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"

import "client:conn"
import "client:settings"
import "common:proto"

// The buddy screen's list: the buddies kept by our account's server, plus
// everyone else we have a DM with and our groups (see conn/buddies.odin),
// across all servers at once (see inbox_list). Each server also has an entry
// for ourselves, the DM with ourselves for our own notes, which is there
// whether or not anything has been written in it yet.

// Buddy_Entry is someone in the buddy screen's list, or one of our groups.
Buddy_Entry :: struct {
	account:   proto.Account_Id, // 0 for a group
	// A group: its other members, in ascending order. `name` is theirs and
	// `conv` is the group.
	group:     bool,
	members:   Group_Members,
	name:      string, // points into the View, or the temp allocator
	status:    string, // their status text as shown in lists (see status_line)
	talking:   string, // whether they are in a voice chat or a call (see talking_of)
	online:    bool,
	buddy:     bool, // false if just someone we have a DM with, or a group
	self:      bool, // ourselves: the DM with ourselves
	conv:      proto.Conv_Id, // our DM with them, 0 if there is none yet
	unread:    int, // unread messages in that DM
	last_time: proto.Unix_Ms, // when the newest message in it was posted
	// The server they're on, from inbox_list. An account only exists on its own
	// server, so the same person on two servers appears as two entries.
	ns:        ^Net_Session,
	server:    string, // its name, in the temp allocator
}

// buddy_list returns every buddy, everyone else we have a DM with, our
// groups and ourselves, in the order given by buddy_before. A DM that was
// hidden in the settings stays off the list until something new is said in
// it. The slice is allocated in the temp allocator. Call with the View locked.
buddy_list :: proc(s: ^settings.Settings, v: ^conn.View) -> []Buddy_Entry {
	list := make([dynamic]Buddy_Entry, 0, len(v.buddies) + len(v.dms) + 1, context.temp_allocator)
	for b in v.buddies {
		if b != v.me {
			append(&list, buddy_entry(v, b, true))
		}
	}
	for &dm in v.dms {
		if settings.dm_hidden(s, v.server_key, dm.id, dm.last) {
			continue
		}
		if dm.count > 0 {
			append(&list, group_entry(v, &dm))
		} else if dm.with != v.me && !slice.contains(v.buddies[:], dm.with) {
			append(&list, buddy_entry(v, dm.with, false))
		}
	}
	if v.me != 0 {
		append(&list, self_entry(v))
	}
	slice.sort_by(list[:], buddy_before)
	return list[:]
}

// unhide_stale forgets that a DM is hidden if it is hidden up to a message
// newer than the DM's newest, and tells the server. A DM is only ever hidden
// up to a message it has (or up to 1 while it has none), so such a hide is
// from before the server's database was started over, when the same ids
// meant other DMs and messages. Kept, it would hide the DM while new messages
// arrive in it. Call with the View locked.
unhide_stale :: proc(ui: ^UI, ns: ^Net_Session, v: ^conn.View) {
	for dm in v.dms {
		upto, hidden := ui.settings.hidden_dms[settings.server_key(v.server_key, u64(dm.id))]
		if hidden && dm.last != 0 && upto > u64(dm.last) {
			settings.hide_dm(&ui.settings, v.server_key, dm.id, 0)
			shared_hidden_changed(ns, dm.id, 0)
			ui.settings_dirty = true
		}
	}
}

// buddy_before is the list order: buddies first, then everyone else we have
// a DM with. Within each group, the conversation with the newest message
// comes first, then people who are online, then by name. The time of the
// newest message is compared across servers because message ids are not
// comparable between servers.
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
	if a.account != b.account {
		return a.account < b.account
	}
	return a.conv < b.conv
}

// inbox_list is buddy_list for every server we're logged in to, merged into
// one list in buddy_before's order. Each server's View is locked in turn, so
// call it with none locked. The slice and its strings are allocated in the
// temp allocator. It also asks each server when the offline entries were
// last seen (see ask_last_seen).
inbox_list :: proc(ui: ^UI) -> []Buddy_Entry {
	list := make([dynamic]Buddy_Entry, context.temp_allocator)
	for ns in ui.sessions {
		if ns.joining {
			continue
		}
		v := &ns.view
		sync.guard(&v.mutex)
		if v.status != .Connected ||
		   v.login.state != .Done ||
		   v.login.must_change ||
		   v.login.unverified {
			continue
		}
		server := v.server_name if v.server_name != "" else ns.server
		server = strings.clone(server, context.temp_allocator)
		unhide_stale(ui, ns, v)
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

// buddy_entry returns what the list shows for an account. Call with the
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
	if e.online {
		e.talking = talking_of(v, account)
	}
	return e
}

// self_entry returns what the list shows for ourselves, whose DM is where our
// own notes go. Call with the View locked.
self_entry :: proc(v: ^conn.View) -> Buddy_Entry {
	e := buddy_entry(v, v.me, false)
	e.self = true
	e.name = fmt.tprintf("%s (you)", e.name)
	e.status = "notes to yourself"
	e.online = true
	e.talking = ""
	return e
}

// group_entry returns what the list shows for a group: the others' names, and
// how many are in it in place of a status. It counts as online while one of
// the others is. Call with the View locked.
group_entry :: proc(v: ^conn.View, dm: ^conn.View_DM) -> Buddy_Entry {
	e := Buddy_Entry {
		group     = true,
		conv      = dm.id,
		name      = dm_name(v, dm),
		status    = fmt.tprintf("%d people", dm.count + 1),
		unread    = dm.unread,
		last_time = dm.last_time,
	}
	e.members.count = copy(e.members.accounts[:], conn.group_members(dm))
	for num, u in v.users {
		if num != v.my_num && slice.contains(e.members.accounts[:e.members.count], u.account) {
			e.online = true
			break
		}
	}
	return e
}

// dm_name is how a DM or a group is named: the other person's name, or the
// names of the others in a group, joined with commas. The name is in the temp
// allocator. Call with the View locked.
dm_name :: proc(v: ^conn.View, dm: ^conn.View_DM) -> string {
	others := conn.group_members(dm)
	if len(others) == 0 {
		others = {dm.with}
	}
	names := make([]string, len(others), context.temp_allocator)
	for id, i in others {
		names[i] = "someone"
		if acc, ok := v.accounts[id]; ok {
			names[i] = acc.display
		}
	}
	return strings.join(names, ", ", context.temp_allocator)
}

// dm_closed is whether a DM or a group can't be written to any more: a DM with
// someone whose account was deleted, or a group in which nobody else's
// account is left (the server refuses it too). Call with the View locked.
dm_closed :: proc(v: ^conn.View, dm: ^conn.View_DM) -> bool {
	others := conn.group_members(dm)
	if len(others) == 0 {
		others = {dm.with}
	}
	for id in others {
		if acc, ok := v.accounts[id]; !ok || .Deleted not_in acc.flags {
			return false
		}
	}
	return true
}

// dm_unread is the total number of unread messages in DMs, excluding DMs
// that are muted or hidden from the list. Call with the View locked.
dm_unread :: proc(s: ^settings.Settings, v: ^conn.View) -> (n: int) {
	for dm in v.dms {
		if dm.notify != .None && !settings.dm_hidden(s, v.server_key, dm.id, dm.last) {
			n += dm.unread
		}
	}
	return
}

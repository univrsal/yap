package client

import "core:slice"
import "core:strings"

import "common:proto"
import "client:settings"
import "client:conn"

// The buddy screen's list: the buddies kept in the settings
// (settings/buddies.odin), and what the View knows of them.

// Buddy_Entry is someone in the buddy screen's list.
Buddy_Entry :: struct {
	key:    [proto.KEY_SIZE]u8,
	name:   string, // points into the settings or the View
	online: proto.User_Num, // their number on this server, or 0
	buddy:  bool, // or just someone we have a conversation with
	unread: int, // DMs from them not seen yet
}

/*
buddy_list is every buddy and everyone else we have a conversation
with, online ones first, then by name. Names come from the View where
they're online, as that's what they go by now. The slice is in the temp
allocator; call with the View locked.
*/
buddy_list :: proc(s: ^settings.Settings, v: ^conn.View) -> []Buddy_Entry {
	list := make([dynamic]Buddy_Entry, 0, len(s.buddies) + len(v.dms), context.temp_allocator)
	for k, b in s.buddies {
		key, ok := settings.parse_user_key(k)
		if !ok {
			continue
		}
		append(&list, buddy_entry(v, key, b.name, true))
	}
	for key, conv in v.dms {
		if !settings.is_buddy(s, key) {
			append(&list, buddy_entry(v, key, conv.name, false))
		}
	}
	slice.sort_by(list[:], proc(a, b: Buddy_Entry) -> bool {
		if (a.online != 0) != (b.online != 0) {
			return a.online != 0
		}
		an := strings.to_lower(a.name, context.temp_allocator)
		bn := strings.to_lower(b.name, context.temp_allocator)
		return an < bn if an != bn else settings.user_key(a.key) < settings.user_key(b.key)
	})
	return list[:]
}

@(private = "file")
buddy_entry :: proc(v: ^conn.View, key: [proto.KEY_SIZE]u8, name: string, buddy: bool) -> Buddy_Entry {
	e := Buddy_Entry {
		key   = key,
		name  = name,
		buddy = buddy,
	}
	if conv, ok := v.dms[key]; ok {
		e.unread = conv.unread
	}
	for num, u in v.users {
		if u.key == key && num != v.my_num {
			e.online = num
			if u.name != "" {
				e.name = u.name
			}
			break
		}
	}
	if e.name == "" {
		e.name = conn.fingerprint(key)
	}
	return e
}

// buddies_seen keeps the saved names up with what buddies go by on the
// server. Returns whether any changed. Call with the View locked.
buddies_seen :: proc(s: ^settings.Settings, v: ^conn.View) -> bool {
	if len(s.buddies) == 0 {
		return false
	}
	changed := false
	for _, u in v.users {
		if u.name != "" && settings.is_buddy(s, u.key) {
			changed |= settings.add_buddy(s, u.key, u.name)
		}
	}
	return changed
}

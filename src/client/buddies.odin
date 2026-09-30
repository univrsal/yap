package client

import "core:slice"
import "core:strings"

import "common:proto"

/*
Buddies: people we've chosen to keep, whether or not they're on the
server right now. A buddy is their public key, which is what identifies
a user (see proto/messages.odin), and the name they last went by, so the
list can say who they are while they're away. They're saved with the
settings, keyed like the per-user volumes.

Adding someone is our business alone: they aren't asked or told. Direct
messages (dm.odin) come from anyone, buddy or not, so the list the
buddy screen shows is the buddies and whoever else we have a
conversation with.
*/

Buddy :: struct {
	name: string, // as they last went by; owned
}

buddy_destroy :: proc(b: Buddy) {
	delete(b.name)
}

is_buddy :: proc(s: ^Settings, key: [proto.KEY_SIZE]u8) -> bool {
	return user_key(key) in s.buddies
}

// add_buddy adds (or renames) a buddy. Returns whether anything changed.
add_buddy :: proc(s: ^Settings, key: [proto.KEY_SIZE]u8, name: string) -> bool {
	k := user_key(key)
	if b, ok := &s.buddies[k]; ok {
		if b.name == name || name == "" {
			return false
		}
		set_setting(&b.name, name)
		return true
	}
	s.buddies[strings.clone(k)] = {
		name = strings.clone(name),
	}
	return true
}

remove_buddy :: proc(s: ^Settings, key: [proto.KEY_SIZE]u8) -> bool {
	k := user_key(key)
	if k not_in s.buddies {
		return false
	}
	owned, b := delete_key(&s.buddies, k)
	delete(owned)
	buddy_destroy(b)
	return true
}

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
buddy_list :: proc(s: ^Settings, v: ^View) -> []Buddy_Entry {
	list := make([dynamic]Buddy_Entry, 0, len(s.buddies) + len(v.dms), context.temp_allocator)
	for k, b in s.buddies {
		key, ok := parse_user_key(k)
		if !ok {
			continue
		}
		append(&list, buddy_entry(v, key, b.name, true))
	}
	for key, conv in v.dms {
		if !is_buddy(s, key) {
			append(&list, buddy_entry(v, key, conv.name, false))
		}
	}
	slice.sort_by(list[:], proc(a, b: Buddy_Entry) -> bool {
		if (a.online != 0) != (b.online != 0) {
			return a.online != 0
		}
		an := strings.to_lower(a.name, context.temp_allocator)
		bn := strings.to_lower(b.name, context.temp_allocator)
		return an < bn if an != bn else user_key(a.key) < user_key(b.key)
	})
	return list[:]
}

@(private = "file")
buddy_entry :: proc(v: ^View, key: [proto.KEY_SIZE]u8, name: string, buddy: bool) -> Buddy_Entry {
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
		e.name = fingerprint(key)
	}
	return e
}

// buddies_seen keeps the saved names up with what buddies go by on the
// server. Returns whether any changed. Call with the View locked.
buddies_seen :: proc(s: ^Settings, v: ^View) -> bool {
	if len(s.buddies) == 0 {
		return false
	}
	changed := false
	for _, u in v.users {
		if u.name != "" && is_buddy(s, u.key) {
			changed |= add_buddy(s, u.key, u.name)
		}
	}
	return changed
}

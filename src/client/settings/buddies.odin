package settings

import "core:strings"

import "common:proto"

/*
Buddies: people we've chosen to keep, whether or not they're on the
server right now. A buddy is their public key, which is what identifies
a user (see proto/messages.odin), and the name they last went by, so the
list can say who they are while they're away. They're saved with the
settings, keyed like the per-user volumes.

Adding someone is our business alone: they aren't asked or told. Direct
messages (conn/dm.odin) come from anyone, buddy or not, so the list the
buddy screen shows is the buddies and whoever else we have a
conversation with (buddy_list, in the client's buddies.odin).
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

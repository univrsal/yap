package client

import "core:fmt"
import "core:strings"

import "../common"
import "../proto"

/*
How users are shown. Names are chosen by users and prove nothing, so a
name that's empty, or shared with someone else in the same snapshot
(ignoring case), gets a short fingerprint of the user's public key:

	alice
	alice (8e41fa62)   when another "alice" or "Alice" is present
	c7ea6abd           no name set
*/

// fingerprint is the first 4 bytes of a public key, in hex.
fingerprint :: proc(key: [proto.KEY_SIZE]u8) -> string {
	return fmt.tprintf("%08x", common.key_id(key))
}

display_name :: proc(users: []proto.User_Info, num: proto.User_Num) -> string {
	user: ^proto.User_Info
	for &u in users {
		if u.num == num {
			user = &u
			break
		}
	}
	if user == nil {
		return fmt.tprintf("user #%d", num)
	}
	if user.name == "" {
		return fingerprint(user.key)
	}
	for &other in users {
		if other.num != num && strings.equal_fold(other.name, user.name) {
			return fmt.tprintf("%s (%s)", user.name, fingerprint(user.key))
		}
	}
	return user.name
}

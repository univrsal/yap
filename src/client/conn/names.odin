package conn

import "core:fmt"
import "core:strings"

import "common:."
import "common:proto"

// How people are shown: by the name of their account (see auth.odin for where
// accounts come from). Display names are not unique, so if another connected
// user has the same display name (ignoring case), the username is shown too:
//
// 	Alice
// 	Alice (alice2)   when another "Alice" or "alice" is here

// fingerprint is the first 4 bytes of a public key in hex, which is used to
// tell devices apart.
fingerprint :: proc(key: [proto.KEY_SIZE]u8) -> string {
	return fmt.tprintf("%08x", common.key_id(key))
}

// display_name is the name to show for the connection `num`.
display_name :: proc(c: ^Voice_Client, num: proto.User_Num) -> string {
	ch := &c.channels
	user := proto.find_user(&ch.state, num) if ch.have_state else nil
	if user == nil {
		return fmt.tprintf("user #%d", num)
	}
	acc, known := c.auth.accounts[user.account]
	if !known {
		// The snapshot arrived before the account did.
		return fmt.tprintf("account #%d", user.account)
	}
	for &other in ch.state.users {
		if other.account == user.account {
			continue
		}
		if o, ok := c.auth.accounts[other.account];
		   ok && strings.equal_fold(o.display, acc.display) {
			return fmt.tprintf("%s (%s)", acc.display, acc.username)
		}
	}
	return acc.display
}

// named is whether `name` matches the account's display name or its username,
// i.e. what somebody would type to refer to that user.
named :: proc(c: ^Voice_Client, u: ^proto.User_Info, name: string) -> bool {
	acc, known := c.auth.accounts[u.account]
	return known && (acc.display == name || acc.username == name)
}

package conn

import "core:fmt"
import "core:strings"

import "common:."
import "common:proto"

/*
How people are shown: by what their account is called (see auth.odin
for where accounts come from). Display names aren't unique, so one that
somebody else who's connected shares (ignoring case) gets its username,
which is:

	Alice
	Alice (alice2)   when another "Alice" or "alice" is here
*/

// fingerprint is the first 4 bytes of a public key, in hex: how a
// device is told from another.
fingerprint :: proc(key: [proto.KEY_SIZE]u8) -> string {
	return fmt.tprintf("%08x", common.key_id(key))
}

// display_name is what to call the connection `num`.
display_name :: proc(c: ^Voice_Client, num: proto.User_Num) -> string {
	ch := &c.channels
	user := proto.find_user(&ch.state, num) if ch.have_state else nil
	if user == nil {
		return fmt.tprintf("user #%d", num)
	}
	acc, known := c.auth.accounts[user.account]
	if !known {
		// The snapshot got here before the account did.
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

// named is whether `name` is what a connection's account is called, or
// its username: what somebody would type to mean them.
named :: proc(c: ^Voice_Client, u: ^proto.User_Info, name: string) -> bool {
	acc, known := c.auth.accounts[u.account]
	return known && (acc.display == name || acc.username == name)
}

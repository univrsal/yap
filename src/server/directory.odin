package server

import "core:slice"

import "common:proto"

/*
The directory: what a connection is told about the server's accounts,
all of them when it logs in and each change after, as events on its
stream (src/common/proto/rpc.odin). The stream keeps them in order, so
a client that takes what it's sent as it comes always has things as
they are.

	Sync_Begin
	Role_Changed      for every role (roles.odin)
	Account_Changed   for every account, whether it's here or not
	Conv_Changed      for every conversation the account is told of
	Buddy_Changed     for every one of the account's buddies
	Emoji_Sheet       the server's own emoji
	Setting_Changed   for every one of the account's settings
	Self              who the connection is, and what it may do
	Sync_End

and then Account_Changed whenever one is made or changes, Self again
when it's the connection's own, and Conv_Changed and Conv_Removed as its
account's conversations come and go (conv_requests.odin), and
Buddy_Changed as its buddies do (buddies.odin).

Who is connected right now isn't in here: that's the snapshot
(sync_state).
*/

// directory_sync tells a connection that just logged in how things are.
directory_sync :: proc(s: ^Server, u: ^Conn) {
	send_event(u, .Sync_Begin)
	send_roles(s, u)
	ids, _ := slice.map_keys(s.accounts.by_id, context.temp_allocator)
	slice.sort(ids)
	for id in ids {
		send_account(u, s.accounts.by_id[id])
	}
	send_convs(s, u)
	send_buddies(u)
	send_emoji_sheet(s, u)
	send_settings(s, u)
	send_self(u)
	send_event(u, .Sync_End)
}

@(private = "file")
send_account :: proc(u: ^Conn, acc: ^Account) {
	buf: [proto.ACCOUNT_MAX_SIZE]u8
	send_event(u, .Account_Changed, proto.encode_account(buf[:], account_record(acc)))
}

// send_self tells a connection who it is: its account, what that may
// do, and whether its password has to be changed.
send_self :: proc(u: ^Conn) {
	buf: [proto.SELF_SIZE]u8
	acc := u.account
	send_event(u, .Self, proto.encode_self(&buf, acc.id, permissions(acc), acc.flags, acc.chosen))
}

// account_told tells everyone logged in but `except` about an account,
// and nothing more.
account_told :: proc(s: ^Server, acc: ^Account, except: ^Conn = nil) {
	for _, u in s.conns {
		if u != except {
			send_account(u, acc)
		}
	}
}

// account_changed tells everyone who is logged in about an account
// that's new or has changed, and its own connections about themselves.
account_changed :: proc(s: ^Server, acc: ^Account) {
	for _, u in s.conns {
		send_account(u, acc)
	}
	for u in acc.conns {
		send_self(u)
	}
}

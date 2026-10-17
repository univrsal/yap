package server

import "core:slice"

import "common:proto"

// The directory is what a connection is told about the server's accounts: all of
// them when it logs in, and each change afterwards, as events on its stream (see
// src/common/proto/rpc.odin). The stream keeps the events in order, so a client
// that applies what it is sent as it arrives always has an up-to-date view.
//
//	Sync_Begin
//	Role_Changed      for every role (see roles.odin)
//	Account_Changed   for every account, whether it is online or not
//	Conv_Changed      for every conversation the account is told about
//	Buddy_Changed     for every one of the account's buddies
//	Emoji_Sheet       the server's own emoji
//	Setting_Changed   for every one of the account's settings
//	Self              who the connection is, and what it may do
//	Sync_End
//
// After that, Account_Changed is sent whenever an account is created or changes,
// Self again when the account is the connection's own, Conv_Changed and
// Conv_Removed as the account's conversations come and go (see
// conv_requests.odin), and Buddy_Changed as its buddies change (see
// buddies.odin).
//
// Who is connected right now isn't part of this, because that is in the snapshot
// (see sync_state).

// directory_sync tells a connection that just logged in about the current state
// of the server.
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

// send_self tells a connection about itself: its account, what the account may
// do, whether its password has to be changed, and its email address.
send_self :: proc(u: ^Conn) {
	buf: [proto.SELF_SIZE]u8
	acc := u.account
	send_event(
		u,
		.Self,
		proto.encode_self(
			&buf,
			acc.id,
			permissions(acc),
			acc.flags,
			acc.chosen,
			acc.email,
			acc.verify_code,
			proto.Unix_Ms(acc.verify_expires),
			proto.Unix_Ms(acc.chosen_at),
			proto.Unix_Ms(acc.status_at),
		),
	)
}

// account_told tells everyone who is logged in, except `except`, about an
// account, and nothing more.
account_told :: proc(s: ^Server, acc: ^Account, except: ^Conn = nil) {
	for _, u in s.conns {
		if u != except {
			send_account(u, acc)
		}
	}
}

// account_changed tells everyone who is logged in about an account that is new
// or has changed, and tells the account's own connections about themselves.
account_changed :: proc(s: ^Server, acc: ^Account) {
	for _, u in s.conns {
		send_account(u, acc)
	}
	for u in acc.conns {
		send_self(u)
	}
}

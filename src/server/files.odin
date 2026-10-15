package server

import "core:log"
import "core:time"

import "common:proto"

// File transfers in DMs (see src/common/proto/files.odin). The server only
// relays data and never stores any of it. When the recipient accepts an offer
// while the connection that made the offer is still online, the server sets up
// a route. It then passes chunks from the sender to the recipient and acks in
// the other direction until either side cancels, disconnects, or the transfer
// goes idle.
//
// An offer is a message in a DM (messages.odin). The file is on the device that
// posted it, so the server remembers which connection that was (File_Offer).
// It does so for as long as the offer can still be accepted, i.e. until the
// offer is answered and the transfer is over, or that connection goes away.
// The route connects the sender with whichever connection of the recipient's
// account accepts. The account's other connections are told that the offer
// was taken elsewhere.
//
// Each route is limited to FILE_RELAY_RATE. Chunks that arrive faster are
// dropped (the sender resends whatever the recipient is missing), so a single
// transfer can't use up all of the server's bandwidth.

// The maximum a route relays, in bytes per second, and the burst size in bytes.
FILE_RELAY_RATE :: 32 * 1024 * 1024
FILE_RELAY_BURST :: 1024 * 1024
// A route that relays nothing for this long is dropped.
FILE_IDLE :: 30 * time.Second
// The maximum number of simultaneous transfers per connection.
MAX_FILE_ROUTES :: 8

// File_Offer is a file offered in a DM that can still be accepted.
File_Offer :: struct {
	sender:   [proto.KEY_SIZE]u8, // the connection that has the file
	from, to: proto.Account_Id,
}

File_Route :: struct {
	// The connections at both ends of the route.
	sender, recipient: [proto.KEY_SIZE]u8,
	last:              time.Tick, // when something was last relayed
	tokens:            f32,
	last_refill:       time.Tick,
}

// file_offered records an offer that `u` just posted.
file_offered :: proc(s: ^Server, u: ^Conn, conv: ^Conv, m: proto.Message) {
	s.file_offers[m.id] = {
		sender = u.key,
		from   = m.sender,
		to     = dm_other(conv, m.sender),
	}
}

// file_offer_for returns the offer `id` if it can still be accepted and
// `u` belongs to the account the offer was made to.
file_offer_for :: proc(s: ^Server, u: ^Conn, id: proto.Msg_Id) -> (offer: File_Offer, ok: bool) {
	offer, ok = s.file_offers[id]
	return offer, ok && offer.to == u.account.id
}

handle_file_accept :: proc(s: ^Server, c: ^Client, pt: []u8) {
	u := c.conn
	id, _, _ := proto.decode_file_accept(pt)
	offer, offered := file_offer_for(s, u, id)
	if !offered {
		// The offer can no longer be accepted or wasn't made to this account.
		send_file_cancel(s, c, id, offer.from, .Gone)
		return
	}
	sc := online_session(s, offer.sender)
	if sc == nil {
		// The sender went offline, and the file is no longer available.
		send_file_cancel(s, c, id, offer.from, .Gone)
		forget_offer(s, id)
		return
	}
	route := s.file_routes[id] or_else nil
	if route == nil {
		if file_routes_of(s, u.key) >= MAX_FILE_ROUTES ||
		   file_routes_of(s, offer.sender) >= MAX_FILE_ROUTES {
			send_file_cancel(s, c, id, offer.from, .Failed)
			return
		}
		route = new(File_Route)
		route^ = {
			sender      = offer.sender,
			recipient   = u.key,
			tokens      = FILE_RELAY_BURST,
			last_refill = time.tick_now(),
		}
		s.file_routes[id] = route
		log.debugf("%s accepted file %d", conn_label(u), id)
		taken_elsewhere(s, u, id, offer.from)
	} else if route.recipient != u.key {
		// Another device of the account already accepted the offer.
		send_file_cancel(s, c, id, offer.from, .Elsewhere)
		return
	}
	route.last = time.tick_now()
	// Tell the sender which account accepted.
	proto.set_file_message_account(pt, u.account.id)
	send_message(s, sc, pt)
}

handle_file_chunk :: proc(s: ^Server, c: ^Client, pt: []u8) {
	id := proto.file_message_id(pt)
	route := s.file_routes[id] or_else nil
	if route == nil || route.sender != c.conn.key {
		return
	}
	now := time.tick_now()
	elapsed := f32(time.duration_seconds(time.tick_diff(route.last_refill, now)))
	route.last_refill = now
	route.tokens = min(route.tokens + elapsed * FILE_RELAY_RATE, FILE_RELAY_BURST)
	if route.tokens < f32(len(pt)) {
		return // too fast, drop the chunk; the sender resends it later
	}
	route.tokens -= f32(len(pt))
	route.last = now
	if rc := online_session(s, route.recipient); rc != nil {
		send_message(s, rc, pt)
	}
}

handle_file_ack :: proc(s: ^Server, c: ^Client, pt: []u8) {
	id := proto.file_message_id(pt)
	route := s.file_routes[id] or_else nil
	if route == nil || route.recipient != c.conn.key {
		return
	}
	route.last = time.tick_now()
	if sc := online_session(s, route.sender); sc != nil {
		send_message(s, sc, pt)
	}
}

// handle_file_cancel passes a cancel on to the other side. If there is a
// route, the cancel goes to the other end of it and the route is dropped.
// Before a route exists, the offer is either withdrawn or declined:
// - If the sender withdraws it, every connection of the recipient's account
//   is notified.
// - If one of the recipient's connections declines it, the sender is notified
//   and the recipient's other connections are told that the offer was
//   answered elsewhere.
// In both cases the offer can't be accepted anymore.
handle_file_cancel :: proc(s: ^Server, c: ^Client, pt: []u8) {
	u := c.conn
	id, _, _ := proto.decode_file_cancel(pt)
	proto.set_file_message_account(pt, u.account.id)
	if route := s.file_routes[id] or_else nil; route != nil {
		other: [proto.KEY_SIZE]u8
		switch u.key {
		case route.sender:
			other = route.recipient
		case route.recipient:
			other = route.sender
		case:
			return // not a party to this transfer
		}
		drop_file_route(s, id)
		if oc := online_session(s, other); oc != nil {
			send_message(s, oc, pt)
		}
		return
	}
	offer, offered := s.file_offers[id]
	switch {
	case !offered:
		return
	case u.key == offer.sender:
		if acc := account_by_id(&s.accounts, offer.to); acc != nil {
			for other in acc.conns {
				if oc := sending_session(s, other); oc != nil {
					send_message(s, oc, pt)
				}
			}
		}
	case u.account.id == offer.to:
		if oc := online_session(s, offer.sender); oc != nil {
			send_message(s, oc, pt)
		}
		taken_elsewhere(s, u, id, offer.from)
	case:
		return // not a party to this transfer
	}
	forget_offer(s, id)
}

// taken_elsewhere tells the other connections of `u`'s account that `u`
// has answered the offer.
@(private = "file")
taken_elsewhere :: proc(s: ^Server, u: ^Conn, id: proto.Msg_Id, from: proto.Account_Id) {
	for other in u.account.conns {
		if other == u {
			continue
		}
		if oc := sending_session(s, other); oc != nil {
			send_file_cancel(s, oc, id, from, .Elsewhere)
		}
	}
}

// files_sync drops routes that have been idle and notifies both sides.
files_sync :: proc(s: ^Server) {
	now := time.tick_now()
	idle := make([dynamic]proto.Msg_Id, context.temp_allocator)
	for id, route in s.file_routes {
		if time.tick_diff(route.last, now) > FILE_IDLE {
			append(&idle, id)
		}
	}
	for id in idle {
		route := s.file_routes[id]
		log.debugf("file %d went idle", id)
		cancel_both(s, id, route, .Failed)
		drop_file_route(s, id)
	}
}

// drop_conn_files ends the transfers of a connection that is disconnecting
// and notifies the other side. It also forgets the offers made by that
// connection since the file is no longer available.
drop_conn_files :: proc(s: ^Server, u: ^Conn) {
	gone := make([dynamic]proto.Msg_Id, context.temp_allocator)
	for id, route in s.file_routes {
		if route.sender == u.key || route.recipient == u.key {
			append(&gone, id)
		}
	}
	for id in gone {
		route := s.file_routes[id]
		cancel_both(s, id, route, .Gone)
		drop_file_route(s, id)
	}
	clear(&gone)
	for id, offer in s.file_offers {
		if offer.sender == u.key {
			append(&gone, id)
		}
	}
	for id in gone {
		delete_key(&s.file_offers, id)
	}
}

files_destroy :: proc(s: ^Server) {
	for _, route in s.file_routes {
		free(route)
	}
	delete(s.file_routes)
	delete(s.file_offers)
}

// cancel_both tells both sides of a route that it's over and names the
// other side's account. A side that is already offline isn't notified.
@(private = "file")
cancel_both :: proc(
	s: ^Server,
	id: proto.Msg_Id,
	route: ^File_Route,
	reason: proto.File_Cancel_Reason,
) {
	offer := s.file_offers[id]
	if c := online_session(s, route.sender); c != nil {
		send_file_cancel(s, c, id, offer.to, reason)
	}
	if c := online_session(s, route.recipient); c != nil {
		send_file_cancel(s, c, id, offer.from, reason)
	}
}

@(private = "file")
send_file_cancel :: proc(
	s: ^Server,
	c: ^Client,
	id: proto.Msg_Id,
	from: proto.Account_Id,
	reason: proto.File_Cancel_Reason,
) {
	buf: [proto.FILE_CANCEL_SIZE]u8
	send_message(s, c, proto.encode_file_cancel(&buf, id, from, reason))
}

// drop_file_route ends a transfer and also forgets its offer, since the
// offer has been accepted.
@(private = "file")
drop_file_route :: proc(s: ^Server, id: proto.Msg_Id) {
	if route := s.file_routes[id] or_else nil; route != nil {
		delete_key(&s.file_routes, id)
		free(route)
	}
	forget_offer(s, id)
}

// forget_offer removes an offer so it can't be accepted anymore, e.g.
// because it was answered or its message was deleted.
forget_offer :: proc(s: ^Server, id: proto.Msg_Id) {
	delete_key(&s.file_offers, id)
}

@(private = "file")
file_routes_of :: proc(s: ^Server, key: [proto.KEY_SIZE]u8) -> (n: int) {
	for _, route in s.file_routes {
		if route.sender == key || route.recipient == key {
			n += 1
		}
	}
	return
}

// online_session returns the session to reach the connection with `key` on,
// or nil if it is offline.
@(private = "file")
online_session :: proc(s: ^Server, key: [proto.KEY_SIZE]u8) -> ^Client {
	u := s.conns[key] or_else nil
	return sending_session(s, u) if u != nil else nil
}

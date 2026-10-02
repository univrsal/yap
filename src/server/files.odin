package server

import "core:log"
import "core:time"

import "common:proto"

/*
File transfers in DMs (see src/common/proto/files.odin). The server only
relays: it sets a route up when the recipient accepts an offer while the
connection that offered it is still here, and passes chunks one way and
acks the other until either side cancels, leaves, or the transfer goes
quiet. It keeps none of it.

An offer is a message in a DM (messages.odin). The file is on the device
that posted it, so the server remembers which connection that was
(File_Offer), for as long as the offer could still be taken up: until
it's answered and the transfer is over, or that connection goes. The
route is between it and whichever connection of the recipient's account
accepts; the account's others are told the offer was taken elsewhere.

Each route is paced to FILE_RELAY_RATE, dropping what comes faster
(the sender resends what the recipient misses), so no one transfer can
take the server's whole line.
*/

// The most a route relays, in bytes per second, and at once.
FILE_RELAY_RATE :: 32 * 1024 * 1024
FILE_RELAY_BURST :: 1024 * 1024
// A route with nothing going through it for this long is dropped.
FILE_IDLE :: 30 * time.Second
// How many transfers one connection may have going at once.
MAX_FILE_ROUTES :: 8

// File_Offer is a file offered in a DM that may still be taken up.
File_Offer :: struct {
	sender:    [proto.KEY_SIZE]u8, // the connection that has the file
	from, to:  proto.Account_Id,
}

File_Route :: struct {
	// The connections at either end.
	sender, recipient: [proto.KEY_SIZE]u8,
	last:              time.Tick, // anything relayed
	tokens:            f32,
	last_refill:       time.Tick,
}

// file_offered notes an offer that was just posted by `u`.
file_offered :: proc(s: ^Server, u: ^Conn, conv: ^Conv, m: proto.Message) {
	s.file_offers[m.id] = {
		sender = u.key,
		from   = m.sender,
		to     = dm_other(conv, m.sender),
	}
}

// file_offer_for is the offer `id`, if it can still be taken up and
// `u` is of the account it was made to.
file_offer_for :: proc(s: ^Server, u: ^Conn, id: proto.Msg_Id) -> (offer: File_Offer, ok: bool) {
	offer, ok = s.file_offers[id]
	return offer, ok && offer.to == u.account.id
}

handle_file_accept :: proc(s: ^Server, c: ^Client, pt: []u8) {
	u := c.conn
	id, _, _ := proto.decode_file_accept(pt)
	offer, offered := file_offer_for(s, u, id)
	if !offered {
		// Not one that can be taken up (any more), or not ours to.
		send_file_cancel(s, c, id, offer.from, .Gone)
		return
	}
	sc := online_session(s, offer.sender)
	if sc == nil {
		// Whoever offered it has gone, and the file with them.
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
		// Another of the account's devices has it.
		send_file_cancel(s, c, id, offer.from, .Elsewhere)
		return
	}
	route.last = time.tick_now()
	// The sender sees who accepted.
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
		return // too fast: dropped, and sent again later
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

/*
handle_file_cancel passes a cancel on to the other side. With a route
it's the other end of it, and the route goes. Before there's one, the
offer is withdrawn (by the connection that made it: every connection of
the recipient's account hears) or declined (by one of the recipient's:
the one that made it hears, and the recipient's others are told it was
answered elsewhere), and either way it can't be taken up any more.
*/
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
			return // someone else's
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
		return // someone else's
	}
	forget_offer(s, id)
}

// taken_elsewhere tells the other connections of `u`'s account that `u`
// has answered an offer.
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

// files_sync drops routes that have gone quiet, telling both sides.
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
		log.debugf("file %d went quiet", id)
		cancel_both(s, id, route, .Failed)
		drop_file_route(s, id)
	}
}

// drop_conn_files ends the transfers of a connection that's leaving,
// telling the other side, and forgets what it offered: the file goes
// with it.
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

// cancel_both tells each side of a route that it's over, naming the
// other's account; whoever has left just doesn't hear it.
@(private = "file")
cancel_both :: proc(s: ^Server, id: proto.Msg_Id, route: ^File_Route, reason: proto.File_Cancel_Reason) {
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

// drop_file_route ends a transfer, and with it the offer: it has been
// taken up.
@(private = "file")
drop_file_route :: proc(s: ^Server, id: proto.Msg_Id) {
	if route := s.file_routes[id] or_else nil; route != nil {
		delete_key(&s.file_routes, id)
		free(route)
	}
	forget_offer(s, id)
}

// forget_offer lets an offer go: it can't be taken up any more (and
// isn't there any more, if it was deleted).
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

// online_session is the session to reach the connection with `key` on,
// or nil if it isn't here.
@(private = "file")
online_session :: proc(s: ^Server, key: [proto.KEY_SIZE]u8) -> ^Client {
	u := s.conns[key] or_else nil
	return sending_session(s, u) if u != nil else nil
}

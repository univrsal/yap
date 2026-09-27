package server

import "core:log"
import "core:time"

import "../proto"

/*
File transfers in DMs (see src/proto/files.odin). The server only
relays: it sets a route up when a recipient accepts an offer while its
sender is online, and passes chunks one way and acks the other until
either side cancels, leaves, or the transfer goes quiet. It can't read
any of it, and keeps none of it.

Each route is paced to FILE_RELAY_RATE, dropping what comes faster
(the sender resends what the recipient misses), so no one transfer can
take the server's whole line.
*/

// The most a route relays, in bytes per second, and at once.
FILE_RELAY_RATE :: 32 * 1024 * 1024
FILE_RELAY_BURST :: 1024 * 1024
// A route with nothing going through it for this long is dropped.
FILE_IDLE :: 30 * time.Second
// How many transfers one user may have going at once.
MAX_FILE_ROUTES :: 8

File_Route :: struct {
	sender, recipient: [proto.KEY_SIZE]u8,
	last:              time.Tick, // anything relayed
	tokens:            f32,
	last_refill:       time.Tick,
}

handle_file_accept :: proc(s: ^Server, c: ^Client, pt: []u8) {
	u := c.user
	id, sender_key, _ := proto.decode_file_accept(pt)
	sender := s.users[sender_key] or_else nil
	sc := sending_session(s, sender) if sender != nil else nil
	if sc == nil || sender == u {
		// Nobody to take it from: the offer is as good as gone.
		buf: [proto.FILE_CANCEL_SIZE]u8
		send_message(s, c, proto.encode_file_cancel(&buf, id, sender_key, .Gone))
		return
	}
	route := s.file_routes[id] or_else nil
	if route == nil {
		if file_routes_of(s, u.key) >= MAX_FILE_ROUTES || file_routes_of(s, sender_key) >= MAX_FILE_ROUTES {
			buf: [proto.FILE_CANCEL_SIZE]u8
			send_message(s, c, proto.encode_file_cancel(&buf, id, sender_key, .Failed))
			return
		}
		route = new(File_Route)
		route^ = {
			sender      = sender_key,
			recipient   = u.key,
			tokens      = FILE_RELAY_BURST,
			last_refill = time.tick_now(),
		}
		s.file_routes[id] = route
		log.debugf("%s accepted file %x from %s", user_label(u), id, user_label(sender))
	} else if route.recipient != u.key || route.sender != sender_key {
		return // someone else's
	}
	route.last = time.tick_now()
	// The sender sees who accepted.
	proto.set_file_message_key(pt, u.key)
	send_message(s, sc, pt)
}

handle_file_chunk :: proc(s: ^Server, c: ^Client, pt: []u8) {
	id := proto.file_message_id(pt)
	route := s.file_routes[id] or_else nil
	if route == nil || route.sender != c.user.key {
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
	if route == nil || route.recipient != c.user.key {
		return
	}
	route.last = time.tick_now()
	if sc := online_session(s, route.sender); sc != nil {
		send_message(s, sc, pt)
	}
}

// handle_file_cancel passes a cancel on to the other side, and drops the
// route if there is one. Before an offer's accepted there's none, and it
// goes to whoever it names (a declined or withdrawn offer).
handle_file_cancel :: proc(s: ^Server, c: ^Client, pt: []u8) {
	u := c.user
	id, other, _ := proto.decode_file_cancel(pt)
	if route := s.file_routes[id] or_else nil; route != nil {
		switch u.key {
		case route.sender:
			other = route.recipient
		case route.recipient:
			other = route.sender
		case:
			return // someone else's
		}
		drop_file_route(s, id)
	}
	if other == u.key {
		return
	}
	if oc := online_session(s, other); oc != nil {
		proto.set_file_message_key(pt, u.key)
		send_message(s, oc, pt)
	}
}

// files_sync drops routes that have gone quiet, telling both sides.
files_sync :: proc(s: ^Server) {
	now := time.tick_now()
	idle := make([dynamic]u64, context.temp_allocator)
	for id, route in s.file_routes {
		if time.tick_diff(route.last, now) > FILE_IDLE {
			append(&idle, id)
		}
	}
	for id in idle {
		route := s.file_routes[id]
		log.debugf("file %x went quiet", id)
		cancel_both(s, id, route, .Failed)
		drop_file_route(s, id)
	}
}

// drop_user_files ends the transfers of someone leaving, telling the
// other side.
drop_user_files :: proc(s: ^Server, u: ^User) {
	gone := make([dynamic]u64, context.temp_allocator)
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
}

files_destroy :: proc(s: ^Server) {
	for _, route in s.file_routes {
		free(route)
	}
	delete(s.file_routes)
}

// cancel_both tells each side of a route that it's over, naming the
// other; whoever has left just doesn't hear it.
@(private = "file")
cancel_both :: proc(s: ^Server, id: u64, route: ^File_Route, reason: proto.File_Cancel_Reason) {
	buf: [proto.FILE_CANCEL_SIZE]u8
	if c := online_session(s, route.sender); c != nil {
		send_message(s, c, proto.encode_file_cancel(&buf, id, route.recipient, reason))
	}
	if c := online_session(s, route.recipient); c != nil {
		send_message(s, c, proto.encode_file_cancel(&buf, id, route.sender, reason))
	}
}

@(private = "file")
drop_file_route :: proc(s: ^Server, id: u64) {
	if route := s.file_routes[id] or_else nil; route != nil {
		delete_key(&s.file_routes, id)
		free(route)
	}
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

// online_session is the session to reach the user with `key` on, or nil
// if they aren't here.
@(private = "file")
online_session :: proc(s: ^Server, key: [proto.KEY_SIZE]u8) -> ^Client {
	u := s.users[key] or_else nil
	return sending_session(s, u) if u != nil else nil
}

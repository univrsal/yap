package http

import "core:log"
import "core:net"
import "core:sync"
import "core:thread"

import "common:."

// Only used in accept_loop, which a package that doesn't call it never
// instantiates.
_ :: log
_ :: thread

// Conn_Limit caps how many connections an accept loop has open at once, in
// total and from one address. Each connection is a thread, so more are
// closed right away rather than let a flood of connections use up the
// process's threads and sockets.
Conn_Limit :: struct {
	max:         int,
	per_address: int,
	// Addresses that only count towards `max`, such as a reverse proxy's,
	// which all connections behind it come from. nil for none.
	exempt:      proc(address: net.Address) -> bool,
	mutex:       sync.Mutex,
	open:        int,
	by_addr:     map[common.Address_Key]int,
}

// accept_loop accepts connections on `listener` forever, and serves each in
// a thread of its own with `serve`, which must end with conn_close. A
// connection over `limit` is closed at once.
accept_loop :: proc(
	listener: net.TCP_Socket,
	limit: ^Conn_Limit,
	data: $T,
	serve: proc(data: T, c: ^Conn),
) {
	for {
		free_all(context.temp_allocator)

		sock, from, accept_err := net.accept_tcp(listener)
		if accept_err != nil {
			log.warnf("accept failed: %v", accept_err)
			continue
		}
		if !conn_count(limit, from) {
			log.warnf(
				"too many connections, closing the one from %s",
				net.endpoint_to_string(from, context.temp_allocator),
			)
			net.close(sock)
			continue
		}
		c := new(Conn)
		c.sock, c.remote, c.limit = sock, from, limit
		log.debugf("connection from %s", net.endpoint_to_string(from, context.temp_allocator))
		started := thread.create_and_start_with_poly_data2(
			data,
			c,
			serve,
			init_context = context,
			self_cleanup = true,
		)
		if started == nil {
			log.warn("could not start a thread for a connection")
			conn_close(c)
		}
	}
}

// conn_close closes a connection, stops counting it if accept_loop counted
// it, and frees it.
conn_close :: proc(c: ^Conn) {
	net.close(c.sock)
	if c.limit != nil {
		conn_uncount(c.limit, c.remote)
	}
	free(c)
}

@(private = "file")
conn_count :: proc(l: ^Conn_Limit, from: net.Endpoint) -> bool {
	sync.guard(&l.mutex)
	if l.open >= l.max {
		return false
	}
	if l.exempt == nil || !l.exempt(from.address) {
		key := common.address_key(from)
		if l.by_addr[key] >= l.per_address {
			return false
		}
		l.by_addr[key] += 1
	}
	l.open += 1
	return true
}

@(private = "file")
conn_uncount :: proc(l: ^Conn_Limit, from: net.Endpoint) {
	sync.guard(&l.mutex)
	l.open -= 1
	if l.exempt != nil && l.exempt(from.address) {
		return
	}
	key := common.address_key(from)
	if n := l.by_addr[key]; n > 1 {
		l.by_addr[key] = n - 1
	} else {
		delete_key(&l.by_addr, key)
	}
}

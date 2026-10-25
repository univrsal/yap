package conn

import log "common:wlog"
import "core:crypto"
import "core:time"

import "common:proto"

// Our end of the reliable stream (src/common/proto/stream.odin). Requests go
// out on it, and their responses and the server's events come in on it
// (rpc.odin).
//
// It is paced so that a large amount of data to send cannot hold up voice, and
// it starts over whenever the server says the connection is a new one (see
// handle_welcome).

stream_destroy :: proc(c: ^Server_Conn) {
	proto.stream_destroy(&c.stream)
}

// stream_restart starts the stream over for a new connection. Anything that
// was in transit in either direction is dropped, including the requests that
// were waiting for an answer.
stream_restart :: proc(c: ^Server_Conn) {
	st := &c.stream
	proto.stream_reset(st)
	st.max_queue = proto.STREAM_CLIENT_QUEUE
	rpc_restart(c)
}

// stream_send queues a message for the server. It goes out in
// stream_step.
stream_send :: proc(c: ^Server_Conn, msg: []u8) {
	// While a new connection is being set up, nothing more goes out on this
	// one. Whoever asked gets Reset once the new connection is established.
	if c.restart || proto.stream_send(&c.stream, msg) {
		return
	}
	// More is waiting than the server will ever catch up with, so the
	// connection is as good as gone. Ask for a new one, which starts
	// everything over (handle_welcome).
	log.warnf("the stream to %s is backed up, starting the connection over", c.server_addr)
	// What was asked and not yet answered, which most likely filled the queue.
	asked: map[proto.Request_Op]int
	defer delete(asked)
	for _, p in c.rpc.pending {
		asked[p.op] += 1
	}
	for op, n in asked {
		log.warnf("  %d %v requests unanswered", n, op)
	}
	connection_restart(c)
}

// connection_restart gives up on the current connection and handshakes for a
// new one under a new conn_id, which the server takes as us having started over
// (proto/hello.odin).
connection_restart :: proc(c: ^Server_Conn) {
	if c.restart {
		return
	}
	crypto.rand_bytes(([^]byte)(&c.conn_id)[:size_of(c.conn_id)])
	// A handshake that is still in progress would still use the old conn_id.
	proto.link_abandon(&c.link)
	c.restart = true // until the Welcome (handle_welcome)
}

// stream_step sends what the stream has to send: first the acknowledgements
// that have arrived, then frames (new and due for a resend) as far as the
// pacing allows.
stream_step :: proc(c: ^Server_Conn) {
	st := &c.stream
	if !c.has_current || !c.has_instance {
		return
	}
	now := time.tick_now()
	// The round trip, once the pings have measured one, for when frames are
	// due again; only looked up when there are frames.
	rtt: time.Duration
	if !proto.stream_idle(st) {
		if stats := connection_stats(&c.ping, now); stats.quality != .Unknown {
			rtt = stats.avg_rtt
		}
	}
	send_frame :: proc(data: rawptr, msg: []u8) {
		send_data((^Server_Conn)(data), msg)
	}
	proto.stream_pace(st, now, proto.stream_resend_for(rtt), send_frame, c)
}

handle_stream :: proc(c: ^Server_Conn, pt: []byte) {
	st := &c.stream
	if c.restart {
		return
	}
	if err := proto.stream_receive(st, pt); err != .None {
		log.warnf("%s broke the stream (%v), starting the connection over", c.server_addr, err)
		connection_restart(c)
		return
	}
	for {
		msg, ok := proto.stream_next(st)
		if !ok {
			break
		}
		rpc_handle(c, msg)
	}
}

handle_stream_ack :: proc(c: ^Server_Conn, pt: []byte) {
	proto.stream_acked(&c.stream, pt)
}

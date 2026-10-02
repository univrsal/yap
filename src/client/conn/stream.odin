package conn

import log "common:wlog"
import "core:crypto"
import "core:time"

import "common:proto"

/*
Our end of the reliable stream (src/common/proto/stream.odin): requests
go out on it and their responses and the server's events come in on it
(rpc.odin).

It's paced, so that a lot to send can't hold up voice, and it starts
over whenever the server says the connection is a new one (see
handle_welcome).
*/

// What may be waiting to go out.
STREAM_QUEUE_MAX :: 1024 * 1024
// Bytes per second, and bytes that may go out at once.
STREAM_RATE :: 256 * 1024
STREAM_BURST :: 32 * 1024
// The longest a frame waits for its acknowledgement the first time,
// however long the round trip seems to be.
STREAM_RESEND_MOST :: time.Second

Stream_Client :: struct {
	using stream: proto.Stream,
	tokens:       f32, // bytes that may go out right now
	last:         time.Tick,
}

stream_destroy :: proc(c: ^Voice_Client) {
	proto.stream_destroy(&c.stream)
}

// stream_restart starts the stream over for a new connection. What was
// on its way in either direction is gone, and with it the requests that
// were waiting to be answered.
stream_restart :: proc(c: ^Voice_Client) {
	st := &c.stream
	proto.stream_reset(st)
	st.max_queue = STREAM_QUEUE_MAX
	st.tokens = STREAM_BURST
	st.last = time.tick_now()
	rpc_restart(c)
}

// stream_send queues a message for the server; it goes out in
// stream_step.
stream_send :: proc(c: ^Voice_Client, msg: []u8) {
	// While a new connection is on its way, nothing more goes out on
	// this one: whoever asked hears Reset when the new one is there.
	if c.restart || proto.stream_send(&c.stream, msg) {
		return
	}
	// More is waiting than the server will ever catch up with: the
	// connection is as good as gone. Ask for a new one, which starts
	// everything over (handle_welcome).
	log.warnf("the stream to %s is backed up, starting the connection over", c.server_addr)
	connection_restart(c)
}

/*
connection_restart gives up on the connection as it is and handshakes
for a new one: under a new conn_id, which the server takes as us having
started over (proto/names.odin).
*/
connection_restart :: proc(c: ^Voice_Client) {
	if c.restart {
		return
	}
	crypto.rand_bytes(([^]byte)(&c.conn_id)[:size_of(c.conn_id)])
	// One under way would still say the old conn_id.
	abandon_handshake(c)
	c.restart = true // until the Welcome (handle_welcome)
}

// stream_step sends what the stream has to send: what has arrived
// acknowledged, then frames, new and due again, as far as the pacing
// allows.
stream_step :: proc(c: ^Voice_Client) {
	st := &c.stream
	if !c.has_current || !c.has_instance {
		return
	}
	now := time.tick_now()
	elapsed := f32(time.duration_seconds(time.tick_diff(st.last, now)))
	st.last = now
	st.tokens = min(st.tokens + elapsed * STREAM_RATE, STREAM_BURST)

	ack_buf: [proto.STREAM_ACK_SIZE]u8
	if ack, ok := proto.stream_ack(st, &ack_buf); ok {
		send_data(c, ack)
	}
	if proto.stream_idle(st) {
		return
	}
	resend := stream_resend(c, now)
	out: [proto.MAX_PAYLOAD_SIZE]u8
	for st.tokens > 0 {
		frame, ok := proto.stream_next_frame(st, now, resend, out[:])
		if !ok {
			break
		}
		send_data(c, frame)
		st.tokens -= f32(len(frame))
	}
}

// stream_resend is how long a frame waits for its acknowledgement
// before it's sent again: twice the round trip, once the pings have
// measured one.
@(private = "file")
stream_resend :: proc(c: ^Voice_Client, now: time.Tick) -> time.Duration {
	stats := connection_stats(&c.ping, now)
	if stats.quality == .Unknown || stats.avg_rtt <= 0 {
		return proto.STREAM_RESEND
	}
	return clamp(2 * stats.avg_rtt, proto.STREAM_RESEND_MIN, STREAM_RESEND_MOST)
}

handle_stream :: proc(c: ^Voice_Client, pt: []byte) {
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

handle_stream_ack :: proc(c: ^Voice_Client, pt: []byte) {
	proto.stream_acked(&c.stream, pt)
}

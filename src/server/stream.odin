package server

import "core:log"
import "core:time"

import "common:proto"

/*
Each user's reliable stream (src/common/proto/stream.odin): requests come
in on it and are answered on it (rpc.odin), and events go out on it.

It's paced per user, like images are, so that a long answer can't crowd
out voice. A user whose queue is over its limit isn't reading what it's
sent; it's dropped, and starts over with a new connection when it
notices.
*/

// What may be waiting to go out to one user. Override for testing with
// e.g. -define:YAP_STREAM_QUEUE=50000
STREAM_QUEUE_MAX :: #config(YAP_STREAM_QUEUE, 4 * 1024 * 1024)
// Per user, bytes per second and bytes that may go out at once.
STREAM_RATE :: 256 * 1024
STREAM_BURST :: 32 * 1024

// Conn_Stream is a user's stream and what paces it.
Conn_Stream :: struct {
	using stream: proto.Stream,
	tokens:       f32, // bytes this user may be sent right now
	last:         time.Tick,
	// The stream can't go on: the client broke its rules, or fell too
	// far behind. stream_sync drops the user.
	broken:       bool,
}

stream_init :: proc(st: ^Conn_Stream) {
	st.max_queue = STREAM_QUEUE_MAX
	st.tokens = STREAM_BURST
	st.last = time.tick_now()
}

handle_stream :: proc(s: ^Server, u: ^Conn, pt: []byte) {
	st := &u.stream
	if st.broken {
		return
	}
	if err := proto.stream_receive(st, pt); err != .None {
		log.warnf("%s broke the stream: %v", conn_label(u), err)
		st.broken = true
		return
	}
	for !st.broken {
		msg, ok := proto.stream_next(st)
		if !ok {
			break
		}
		rpc_handle(s, u, msg)
	}
}

// stream_send queues a message for a user; it goes out in stream_sync.
stream_send :: proc(u: ^Conn, msg: []byte) {
	st := &u.stream
	if st.broken {
		return
	}
	if !proto.stream_send(st, msg) {
		log.warnf(
			"%s is too far behind on the stream (%d bytes waiting, %d more to send)",
			conn_label(u),
			st.queued,
			len(msg),
		)
		st.broken = true
	}
}

// stream_sync sends what each user's stream has to send: what has
// arrived acknowledged, then frames, new and due again, as far as the
// user's allowance goes.
stream_sync :: proc(s: ^Server) {
	now := time.tick_now()
	broken := make([dynamic]^Conn, context.temp_allocator)
	out: [proto.MAX_PAYLOAD_SIZE]u8
	// Those that aren't logged in have a stream too: it's how they log in.
	for conns in ([2]map[[proto.KEY_SIZE]byte]^Conn{s.conns, s.waiting}) {
		for _, u in conns {
			st := &u.stream
			if st.broken {
				append(&broken, u)
				continue
			}
			elapsed := f32(time.duration_seconds(time.tick_diff(st.last, now)))
			st.last = now
			st.tokens = min(st.tokens + elapsed * STREAM_RATE, STREAM_BURST)
			if !st.ack_due && proto.stream_idle(st) {
				continue
			}
			c := sending_session(s, u)
			if c == nil {
				continue
			}
			ack_buf: [proto.STREAM_ACK_SIZE]u8
			if ack, ok := proto.stream_ack(st, &ack_buf); ok {
				send_message(s, c, ack)
			}
			for st.tokens > 0 {
				frame, ok := proto.stream_next_frame(st, now, proto.STREAM_RESEND, out[:])
				if !ok {
					break
				}
				send_message(s, c, frame)
				st.tokens -= f32(len(frame))
			}
		}
	}
	for u in broken {
		drop_conn(s, u)
	}
}

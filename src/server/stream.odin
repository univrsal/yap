package server

import "core:log"
import "core:time"

import "common:proto"

// Each user has a reliable stream (see src/common/proto/stream.odin).
// Requests arrive on it and are answered on it (see rpc.odin), and events
// are sent on it.
//
// The stream is rate limited per user, like image transfers are, so that a
// long answer can't crowd out voice data. If a user's queue grows over its
// limit, the user isn't reading what is sent to them. Such a user is
// dropped and has to start over with a new connection once it notices.

// The maximum number of bytes that may be queued for one user. Can be
// overridden for testing with e.g. -define:YAP_STREAM_QUEUE=50000
STREAM_QUEUE_MAX :: #config(YAP_STREAM_QUEUE, 4 * 1024 * 1024)
// The rate limit per user: bytes per second and the largest burst of bytes
// that may be sent at once.
STREAM_RATE :: 256 * 1024
STREAM_BURST :: 32 * 1024

// Conn_Stream is a user's stream together with its rate limiting state.
Conn_Stream :: struct {
	using stream: proto.Stream,
	tokens:       f32, // bytes this user may be sent right now
	last:         time.Tick,
	// The stream can't continue because the client broke the protocol
	// rules or fell too far behind. stream_sync drops the user.
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

// stream_send queues a message for a user. It is sent by stream_sync.
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

// stream_sync sends the pending data of each user's stream: first the
// acknowledgement for what has been received, then new frames and frames
// that need to be resent, as far as the user's rate limit allows.
stream_sync :: proc(s: ^Server) {
	now := time.tick_now()
	broken := make([dynamic]^Conn, context.temp_allocator)
	out: [proto.MAX_PAYLOAD_SIZE]u8
	// Connections that aren't logged in have a stream too, since they use it to log in.
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

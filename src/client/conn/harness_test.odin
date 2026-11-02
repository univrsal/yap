#+build !wasi
package conn

import "core:strings"
import "core:testing"
import "core:time"

import "common:proto"

// The conn tests' harness. A Test_Conn is a Server_Conn without a socket: what
// the client sends goes onto its stream as usual, and the harness reads it from
// there the way a server would (tc_sent). Answers and events are handed to the
// client the way they come off the stream (tc_answer, tc_event).

// A request the client sent.
Test_Request :: struct {
	id:   u32,
	op:   proto.Request_Op,
	body: []u8, // temp allocator
}

Test_Conn :: struct {
	c:    Server_Conn,
	// The server's end of the client's stream.
	peer: proto.Stream,
	// Where the scripts' events go.
	sink: Event_Sink,
}

// tc_open prepares a connection that has been established and has synced.
tc_open :: proc(tc: ^Test_Conn) {
	c := &tc.c
	stream_restart(c)
	c.has_current = true
	c.has_instance = true
	c.convs.synced = true
	c.events = &tc.sink
}

// tc_restart starts the connection over, which the server's end does too (see
// handle_welcome).
tc_restart :: proc(tc: ^Test_Conn) {
	proto.stream_reset(&tc.peer)
	stream_restart(&tc.c)
}

tc_close :: proc(tc: ^Test_Conn) {
	c := &tc.c
	messages_destroy(c)
	stream_destroy(c)
	rpc_destroy(c)
	auth_destroy(c)
	convs_destroy(c)
	proto.stream_destroy(&tc.peer)
	sink_destroy(&tc.sink)
}

// tc_conv adds a channel we are a member of.
tc_conv :: proc(tc: ^Test_Conn, id: proto.Conv_Id, name: string, last := proto.Msg_Id(0)) {
	tc.c.convs.convs[id] = {
		name = strings.clone(name),
		last = last,
		read = last,
	}
}

// tc_account adds someone to the directory.
tc_account :: proc(tc: ^Test_Conn, id: proto.Account_Id, username: string, display := "") {
	tc.c.auth.accounts[id] = {
		username = strings.clone(username),
		display  = strings.clone(display if display != "" else username),
	}
}

// tc_sent returns the requests the client has sent since this was last called,
// in the order it sent them.
tc_sent :: proc(t: ^testing.T, tc: ^Test_Conn) -> []Test_Request {
	buf: [proto.MAX_PAYLOAD_SIZE]u8
	now := time.tick_now()
	for {
		frame, ok := proto.stream_next_frame(&tc.c.stream, now, proto.STREAM_RESEND, buf[:])
		if !ok {
			break
		}
		testing.expect_value(
			t,
			proto.stream_receive(&tc.peer, frame),
			proto.Stream_Error.None,
		)
		ack_buf: [proto.STREAM_ACK_SIZE]u8
		if ack, due := proto.stream_ack(&tc.peer, &ack_buf); due {
			proto.stream_acked(&tc.c.stream, ack)
		}
	}
	sent := make([dynamic]Test_Request, context.temp_allocator)
	for {
		msg, ok := proto.stream_next(&tc.peer)
		if !ok {
			break
		}
		kind, known := proto.app_kind(msg)
		testing.expect(t, known && kind == .Request)
		id, op, body := proto.decode_request(msg)
		copied := make([]u8, len(body), context.temp_allocator)
		copy(copied, body)
		append(&sent, Test_Request{id, op, copied})
	}
	return sent[:]
}

// tc_answer gives the client the server's answer to request `id`.
tc_answer :: proc(tc: ^Test_Conn, id: u32, status: proto.Status = .Ok, body: []u8 = nil) {
	rpc_handle(&tc.c, proto.encode_response(id, status, body))
}

// tc_event gives the client an event from the server.
tc_event :: proc(tc: ^Test_Conn, op: proto.Event_Op, body: []u8 = nil) {
	rpc_handle(&tc.c, proto.encode_event(op, body))
}

// tc_events takes the events scripts have been told of.
tc_events :: proc(tc: ^Test_Conn) -> []Event {
	return sink_take(&tc.sink, context.temp_allocator)
}

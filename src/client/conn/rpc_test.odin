#+build !wasi
package conn

import "core:testing"

import "common:proto"

// Tests of requests and their answers (rpc.odin), and of the stream they go
// out on (stream.odin).

// Answer is what a request's `done` was told. A request's tag points to its
// own, because the tests run in parallel and `done` has no other way to reach
// a test's state.
@(private = "file")
Answer :: struct {
	calls:  int,
	status: proto.Status,
	body:   [8]u8,
	size:   int,
	// Counts the calls of a test, to tell which came first.
	seq:    ^int,
	order:  int,
	// Ask for something else when this is called.
	again:  bool,
}

@(private = "file")
ask :: proc(
	tc: ^Test_Conn,
	op: proto.Request_Op,
	a: ^Answer,
	body: []u8 = nil,
) {
	request(&tc.c, op, body, answered, u64(uintptr(a)))
}

@(private = "file")
answered :: proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
	a := (^Answer)(uintptr(tag))
	a.calls += 1
	a.status = status
	if a.seq != nil {
		a.seq^ += 1
		a.order = a.seq^
	}
	a.size = len(body)
	copy(a.body[:], body)
	if a.again {
		request(c, .Server_Info)
	}
}

@(test)
test_request_and_answer :: proc(t: ^testing.T) {
	tc: Test_Conn
	tc_open(&tc)
	defer tc_close(&tc)

	info, convs: Answer
	ask(&tc, .Server_Info, &info)
	ask(&tc, .Device_List, &convs, {1, 2, 3})
	sent := tc_sent(t, &tc)
	testing.expect_value(t, len(sent), 2)
	testing.expect_value(t, sent[0].op, proto.Request_Op.Server_Info)
	testing.expect_value(t, sent[1].op, proto.Request_Op.Device_List)
	testing.expect(t, sent[0].id != sent[1].id, "requests share an id")
	testing.expect_value(t, len(sent[0].body), 0)
	testing.expect_value(t, len(sent[1].body), 3)
	testing.expect_value(t, len(tc.c.rpc.pending), 2)

	// Answers come in any order, and each goes to the one that asked.
	tc_answer(&tc, sent[1].id, .Denied)
	testing.expect_value(t, convs.calls, 1)
	testing.expect_value(t, convs.status, proto.Status.Denied)
	testing.expect_value(t, info.calls, 0)

	tc_answer(&tc, sent[0].id, .Ok, {9, 8, 7, 6})
	testing.expect_value(t, info.calls, 1)
	testing.expect_value(t, info.status, proto.Status.Ok)
	testing.expect_value(t, info.size, 4)
	testing.expect_value(t, info.body[0], u8(9))
	testing.expect_value(t, len(tc.c.rpc.pending), 0)

	// A second answer to the same request, or an answer to one we never asked,
	// does nothing.
	tc_answer(&tc, sent[0].id, .Ok)
	tc_answer(&tc, 12345, .Ok)
	testing.expect_value(t, info.calls, 1)
	testing.expect_value(t, convs.calls, 1)
}

@(test)
test_request_without_done :: proc(t: ^testing.T) {
	tc: Test_Conn
	tc_open(&tc)
	defer tc_close(&tc)

	request(&tc.c, .Server_Info)
	sent := tc_sent(t, &tc)
	testing.expect_value(t, len(sent), 1)
	// Nobody to tell, but the request is still answered and forgotten.
	tc_answer(&tc, sent[0].id)
	testing.expect_value(t, len(tc.c.rpc.pending), 0)
}

@(test)
test_request_too_large :: proc(t: ^testing.T) {
	tc: Test_Conn
	tc_open(&tc)
	defer tc_close(&tc)

	a: Answer
	context.logger = expected_errors() // the error is expected
	ask(&tc, .Msg_Post, &a, make([]u8, proto.MAX_BODY_SIZE + 1, context.temp_allocator))
	testing.expect_value(t, a.calls, 1)
	testing.expect_value(t, a.status, proto.Status.Too_Large)
	testing.expect_value(t, len(tc.c.rpc.pending), 0)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)

	// The largest body that fits does.
	b: Answer
	ask(&tc, .Msg_Post, &b, make([]u8, proto.MAX_BODY_SIZE, context.temp_allocator))
	testing.expect_value(t, b.calls, 0)
	testing.expect_value(t, len(tc.c.rpc.pending), 1)
}

@(test)
test_requests_are_reset_with_the_connection :: proc(t: ^testing.T) {
	tc: Test_Conn
	tc_open(&tc)
	defer tc_close(&tc)

	first, second, third: Answer
	ask(&tc, .Server_Info, &first)
	ask(&tc, .Device_List, &second)
	ask(&tc, .Invite_List, &third)
	testing.expect_value(t, len(tc_sent(t, &tc)), 3)
	sent_before := tc.c.rpc.last_id

	// A request that is asked again when it is reset is not lost with the rest.
	second.again = true
	tc_restart(&tc)
	for a in ([]Answer{first, second, third}) {
		testing.expect_value(t, a.calls, 1)
		testing.expect_value(t, a.status, proto.Status.Reset)
	}
	testing.expect_value(t, len(tc.c.rpc.pending), 1)
	testing.expect_value(t, tc.c.rpc.last_id, sent_before + 1)

	// Whatever was in transit before is gone, and the new request goes out.
	sent := tc_sent(t, &tc)
	testing.expect_value(t, len(sent), 1)
	testing.expect_value(t, sent[0].op, proto.Request_Op.Server_Info)

	// A late answer from the old connection reaches nobody.
	tc_answer(&tc, 1, .Ok)
	testing.expect_value(t, first.calls, 1)
}

@(test)
test_reset_is_in_the_order_of_asking :: proc(t: ^testing.T) {
	tc: Test_Conn
	tc_open(&tc)
	defer tc_close(&tc)

	// A map keeps no order, so the order they are told in has to be put back.
	calls: int
	answers: [8]Answer
	for &a in answers {
		a.seq = &calls
		ask(&tc, .Server_Info, &a)
	}
	rpc_restart(&tc.c)
	for a, i in answers {
		testing.expect_value(t, a.calls, 1)
		testing.expect_value(t, a.status, proto.Status.Reset)
		testing.expect_value(t, a.order, i + 1)
	}
}

@(test)
test_unknown_input_is_ignored :: proc(t: ^testing.T) {
	tc: Test_Conn
	tc_open(&tc)
	defer tc_close(&tc)

	rpc_handle(&tc.c, nil)
	rpc_handle(&tc.c, []u8{})
	rpc_handle(&tc.c, []u8{0xff})
	rpc_handle(&tc.c, []u8{0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff})
	// An event this client doesn't know comes from a newer server.
	tc_event(&tc, proto.Event_Op(0xfffe), {1, 2, 3})
	// A request is never sent to a client.
	rpc_handle(&tc.c, proto.encode_request(1, .Server_Info, nil))
	testing.expect_value(t, len(tc.c.rpc.pending), 0)
}

@(test)
test_backed_up_stream_starts_over :: proc(t: ^testing.T) {
	tc: Test_Conn
	tc_open(&tc)
	defer tc_close(&tc)
	c := &tc.c

	// Room for one request and no more.
	c.stream.max_queue = 64
	id_before := c.conn_id
	a, b: Answer
	ask(&tc, .Server_Info, &a, make([]u8, 40, context.temp_allocator))
	testing.expect(t, !c.restart)
	ask(&tc, .Server_Info, &b, make([]u8, 40, context.temp_allocator))
	testing.expect(t, c.restart, "a stream the server can't keep up with was not started over")
	testing.expect(t, c.conn_id != id_before, "a new connection needs a new id")

	// Nothing more is queued while the new connection is set up, but the
	// requests are kept for it to answer or reset.
	c.stream.max_queue = 0
	ask(&tc, .Server_Info, &b, nil)
	testing.expect_value(t, len(tc.c.rpc.pending), 3)
	testing.expect_value(t, len(tc_sent(t, &tc)), 1)

	// Once the new connection is up, they are all told to ask again.
	c.restart = false
	tc_restart(&tc)
	testing.expect_value(t, a.calls, 1)
	testing.expect_value(t, a.status, proto.Status.Reset)
	testing.expect_value(t, len(tc.c.rpc.pending), 0)
}

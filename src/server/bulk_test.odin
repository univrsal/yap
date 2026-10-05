package server

import "core:crypto/ecdh"
import "core:net"
import "core:testing"
import "core:time"

import "common:proto"

/*
Tests of a connection's two links (proto.Link): real handshakes, over
loopback UDP sockets, with the server's packet handling - the bulk link
joins the connection the main link made, heavy messages go out on it,
and it goes with the connection.
*/

@(private = "file")
Test_Link :: struct {
	sock: net.UDP_Socket,
	from: net.Endpoint,
	sess: proto.Session,
}

@(private = "file")
link_open_socket :: proc(t: ^testing.T, l: ^Test_Link) {
	sock, err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	testing.expect_value(t, err, nil)
	net.set_option(sock, .Receive_Timeout, time.Second)
	l.sock = sock
	l.from, _ = net.bound_endpoint(sock)
}

// link_recv reads the next Data packet on the link and opens it.
@(private = "file")
link_recv :: proc(t: ^testing.T, l: ^Test_Link, out: []u8) -> []u8 {
	buf: [proto.MAX_PACKET_SIZE]u8
	n, _, err := net.recv_udp(l.sock, buf[:])
	if !testing.expect_value(t, err, nil) {
		return nil
	}
	pt, ok := proto.open(&l.sess, buf[:n], out)
	testing.expect(t, ok)
	return pt
}

/*
link_handshake runs a client's side of a handshake on `l`, with the
server handling each packet as it would come off its socket, and
returns the server's answer: Welcome or Refused, of which it sends
three copies.
*/
@(private = "file")
link_handshake :: proc(
	t: ^testing.T,
	s: ^Server,
	l: ^Test_Link,
	key: ^ecdh.Private_Key,
	conn_id: u64,
	link: proto.Link,
	out: []u8,
) -> []u8 {
	ini: proto.Initiator
	init, started := proto.initiator_start(&ini, key)
	testing.expect(t, started)
	handle_packet(s, init, l.from)

	buf: [proto.MAX_PACKET_SIZE]u8
	n, _, err := net.recv_udp(l.sock, buf[:])
	testing.expect_value(t, err, nil)
	_, result := proto.initiator_read_resp(&ini, buf[:n])
	testing.expect_value(t, result, proto.Resp_Result.Ok)

	hello_buf: [proto.HELLO_MAX_SIZE]u8
	hello := proto.encode_hello(&hello_buf, conn_id, "", link)
	finish, finished := proto.initiator_finish(&ini, &l.sess, hello)
	testing.expect(t, finished)
	handle_packet(s, finish, l.from)
	answer := link_recv(t, l, out)
	copy_buf: [proto.MAX_PAYLOAD_SIZE]u8
	for _ in 1 ..< 3 {
		link_recv(t, l, copy_buf[:])
	}
	return answer
}

@(test)
test_bulk_link :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	s.max_sessions = 16
	testing.expect(t, ecdh.private_key_generate(&s.key, .X25519))
	sock, err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	testing.expect_value(t, err, nil)
	s.sock = sock
	defer net.close(sock)
	defer delete(s.sessions)

	key: ecdh.Private_Key
	testing.expect(t, ecdh.private_key_generate(&key, .X25519))
	main, bulk: Test_Link
	link_open_socket(t, &main)
	link_open_socket(t, &bulk)
	defer net.close(main.sock)
	defer net.close(bulk.sock)
	out: [proto.MAX_PAYLOAD_SIZE]u8
	CONN_ID :: 0x1234

	// Before the main link, there's no connection to join.
	pt := link_handshake(t, s, &bulk, &key, CONN_ID, .Bulk, out[:])
	kind, _ := proto.message_kind(pt)
	testing.expect_value(t, kind, proto.Message_Kind.Refused)
	testing.expect_value(t, proto.decode_refused(pt), proto.Refusal.No_Connection)
	testing.expect_value(t, len(s.sessions), 0)

	pt = link_handshake(t, s, &main, &key, CONN_ID, .Main, out[:])
	kind, _ = proto.message_kind(pt)
	testing.expect_value(t, kind, proto.Message_Kind.Welcome)
	instance, _ := proto.decode_welcome(pt)

	// Another connection's id is no good either.
	pt = link_handshake(t, s, &bulk, &key, CONN_ID + 1, .Bulk, out[:])
	testing.expect_value(t, proto.decode_refused(pt), proto.Refusal.No_Connection)

	pt = link_handshake(t, s, &bulk, &key, CONN_ID, .Bulk, out[:])
	kind, _ = proto.message_kind(pt)
	testing.expect_value(t, kind, proto.Message_Kind.Welcome)
	bulk_instance, _ := proto.decode_welcome(pt)
	testing.expect_value(t, bulk_instance, instance)
	testing.expect_value(t, len(s.sessions), 2)

	pub: [proto.KEY_SIZE]u8
	ecdh.private_key_public_bytes(&key, pub[:])
	u := conn_of(s, pub)
	testing.expect(t, u != nil)
	if u == nil {
		return
	}
	testing.expect_value(t, u.sessions, 1)
	c := sending_session(s, u)
	testing.expect(t, c != nil && !c.bulk)

	// Heavy on the bulk link, light on the main link, whichever session
	// it's handed to.
	heavy := [?]u8{u8(proto.Message_Kind.Blob_Chunk), 1, 2, 3}
	light := [?]u8{u8(proto.Message_Kind.Keyframe)}
	send_message(s, c, heavy[:])
	send_message(s, c, light[:])
	testing.expect_value(t, link_recv(t, &bulk, out[:])[0], heavy[0])
	testing.expect_value(t, link_recv(t, &main, out[:])[0], light[0])

	// A ping on the bulk link is answered there.
	ping_buf: [proto.PING_SIZE]u8
	pkt_buf: [proto.MAX_PACKET_SIZE]u8
	ping, _ := proto.seal(&bulk.sess, proto.encode_ping(&ping_buf, .Ping, 7), pkt_buf[:])
	handle_packet(s, ping, bulk.from)
	pong := link_recv(t, &bulk, out[:])
	testing.expect_value(t, proto.Message_Kind(pong[0]), proto.Message_Kind.Pong)
	testing.expect_value(t, proto.decode_ping(pong), 7)

	// The bulk link going doesn't take the connection with it...
	b := bulk_session(s, u)
	testing.expect(t, b != nil)
	drop_session(s, b.local_idx)
	testing.expect(t, conn_of(s, pub) == u)
	send_message(s, c, heavy[:]) // back on the main link
	testing.expect_value(t, link_recv(t, &main, out[:])[0], heavy[0])

	// ...but the connection going takes the bulk link.
	pt = link_handshake(t, s, &bulk, &key, CONN_ID, .Bulk, out[:])
	testing.expect_value(t, proto.Message_Kind(pt[0]), proto.Message_Kind.Welcome)
	testing.expect_value(t, len(s.sessions), 2)
	drop_session(s, c.local_idx)
	testing.expect_value(t, len(s.sessions), 0)
	testing.expect(t, conn_of(s, pub) == nil)
}

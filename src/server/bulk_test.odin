package server

import "core:crypto/ecdh"
import "core:net"
import "core:testing"

import "common:proto"

// Tests of a connection's two links (proto.Link). They use real
// handshakes over loopback UDP sockets together with the server's packet
// handling. The bulk link joins the connection the main link created,
// heavy messages are sent on it, and it is removed with the connection.

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
	handle :: proc(data: rawptr, pkt: []u8, from: net.Endpoint) {
		handle_packet((^Server)(data), pkt, from)
	}
	return link_handshake_with(t, l, key, conn_id, link, out, handle, s)
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

	// Before the main link exists, there's no connection to join.
	pt := link_handshake(t, s, &bulk, &key, CONN_ID, .Bulk, out[:])
	kind, _ := proto.message_kind(pt)
	testing.expect_value(t, kind, proto.Message_Kind.Refused)
	testing.expect_value(t, proto.decode_refused(pt), proto.Refusal.No_Connection)
	testing.expect_value(t, len(s.sessions), 0)

	pt = link_handshake(t, s, &main, &key, CONN_ID, .Main, out[:])
	kind, _ = proto.message_kind(pt)
	testing.expect_value(t, kind, proto.Message_Kind.Welcome)
	instance, _ := proto.decode_welcome(pt)

	// Another connection's id doesn't work either.
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

	// Heavy messages go out on the bulk link and light ones on the main
	// link, regardless of which session they are handed to.
	heavy := [?]u8{u8(proto.Message_Kind.Blob_Chunk), 1, 2, 3}
	light := [?]u8{u8(proto.Message_Kind.Keyframe)}
	send_message(s, c, heavy[:])
	send_message(s, c, light[:])
	testing.expect_value(t, link_recv(t, &bulk, out[:])[0], heavy[0])
	testing.expect_value(t, link_recv(t, &main, out[:])[0], light[0])

	// A ping on the bulk link is answered on the bulk link.
	ping_buf: [proto.PING_SIZE]u8
	pkt_buf: [proto.MAX_PACKET_SIZE]u8
	ping, _ := proto.seal(&bulk.sess, proto.encode_ping(&ping_buf, .Ping, 7), pkt_buf[:])
	handle_packet(s, ping, bulk.from)
	pong := link_recv(t, &bulk, out[:])
	testing.expect_value(t, proto.Message_Kind(pong[0]), proto.Message_Kind.Pong)
	testing.expect_value(t, proto.decode_ping(pong), 7)

	// Dropping the bulk link doesn't remove the connection...
	b := bulk_session(s, u)
	testing.expect(t, b != nil)
	drop_session(s, b.local_idx)
	testing.expect(t, conn_of(s, pub) == u)
	send_message(s, c, heavy[:]) // back on the main link
	testing.expect_value(t, link_recv(t, &main, out[:])[0], heavy[0])

	// ...but removing the connection also removes the bulk link.
	pt = link_handshake(t, s, &bulk, &key, CONN_ID, .Bulk, out[:])
	testing.expect_value(t, proto.Message_Kind(pt[0]), proto.Message_Kind.Welcome)
	testing.expect_value(t, len(s.sessions), 2)
	drop_session(s, c.local_idx)
	testing.expect_value(t, len(s.sessions), 0)
	testing.expect(t, conn_of(s, pub) == nil)
}

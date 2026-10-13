package server

import "core:crypto/ecdh"
import "core:net"
import "core:testing"
import "core:time"

import "common:proto"

/*
Tests of the media link (media.odin): real handshakes over loopback UDP
sockets, with the media thread's packet handling called directly - it
joins a logged in connection, carries a sharer's video to whoever
watches them in their room, and keyframe requests back.
*/

@(private = "file")
Media_Test_Link :: struct {
	sock: net.UDP_Socket,
	from: net.Endpoint,
	sess: proto.Session,
}

@(private = "file")
media_link_open :: proc(t: ^testing.T, l: ^Media_Test_Link) {
	sock, err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	testing.expect_value(t, err, nil)
	net.set_option(sock, .Receive_Timeout, time.Second)
	l.sock = sock
	l.from, _ = net.bound_endpoint(sock)
}

@(private = "file")
media_link_recv :: proc(t: ^testing.T, l: ^Media_Test_Link, out: []u8) -> []u8 {
	buf: [proto.MAX_PACKET_SIZE]u8
	n, _, err := net.recv_udp(l.sock, buf[:])
	if !testing.expect_value(t, err, nil) {
		return nil
	}
	pt, ok := proto.open(&l.sess, buf[:n], out)
	testing.expect(t, ok)
	return pt
}

// media_link_quiet says nothing more has come on the link.
@(private = "file")
media_link_quiet :: proc(l: ^Media_Test_Link) -> bool {
	net.set_option(l.sock, .Receive_Timeout, 50 * time.Millisecond)
	defer net.set_option(l.sock, .Receive_Timeout, time.Second)
	buf: [proto.MAX_PACKET_SIZE]u8
	_, _, err := net.recv_udp(l.sock, buf[:])
	return err != nil
}

@(private = "file")
media_link_send :: proc(m: ^Media, l: ^Media_Test_Link, msg: []u8) {
	pkt_buf: [proto.MAX_PACKET_SIZE]u8
	pkt, ok := proto.seal(&l.sess, msg, pkt_buf[:])
	if ok {
		media_handle_packet(m, pkt, l.from)
	}
}

// media_link_handshake runs a client's handshake on the media link and
// returns the first of the three copies of the answer, the others read.
@(private = "file")
media_link_handshake :: proc(
	t: ^testing.T,
	m: ^Media,
	l: ^Media_Test_Link,
	key: ^ecdh.Private_Key,
	conn_id: u64,
	out: []u8,
) -> []u8 {
	ini: proto.Initiator
	init, started := proto.initiator_start(&ini, key)
	testing.expect(t, started)
	media_handle_packet(m, init, l.from)
	buf: [proto.MAX_PACKET_SIZE]u8
	n, _, err := net.recv_udp(l.sock, buf[:])
	testing.expect_value(t, err, nil)
	_, result := proto.initiator_read_resp(&ini, buf[:n])
	testing.expect_value(t, result, proto.Resp_Result.Ok)
	hello_buf: [proto.HELLO_MAX_SIZE]u8
	hello := proto.encode_hello(&hello_buf, conn_id, "", .Media)
	finish, finished := proto.initiator_finish(&ini, &l.sess, hello)
	testing.expect(t, finished)
	media_handle_packet(m, finish, l.from)
	answer := media_link_recv(t, l, out)
	copy_buf: [proto.MAX_PAYLOAD_SIZE]u8
	for _ in 1 ..< 3 {
		media_link_recv(t, l, copy_buf[:])
	}
	return answer
}

@(test)
test_media_link :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	s.max_sessions = 16
	testing.expect(t, ecdh.private_key_generate(&s.key, .X25519))

	// Two devices, logged in, in the same room; one sharing.
	keys: [2]ecdh.Private_Key
	conns: [2]^Conn
	names := [2]string{"sharer", "viewer"}
	for i in 0 ..< 2 {
		testing.expect(t, ecdh.private_key_generate(&keys[i], .X25519))
		pub: [proto.KEY_SIZE]u8
		ecdh.private_key_public_bytes(&keys[i], pub[:])
		ts_account(t, &ts, names[i], "password")
		conns[i] = ts_connect(&ts, pub)
		status, _ := ts_login(t, &ts, conns[i], names[i], "password")
		testing.expect_value(t, status, proto.Status.Ok)
		conns[i].conn_id = u64(0x100 + i)
		conns[i].room = 1
	}
	sharer, viewer := conns[0], conns[1]
	sharer.flags += {.Sharing}
	bump_version(s)

	// The media thread's part, without the thread.
	m := &s.media
	sock, err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	testing.expect_value(t, err, nil)
	m.sock = sock
	m.key = s.key
	m.enabled = true
	m.max_rate = 1_000_000
	m.max_burst = proto.MAX_VIDEO_FRAME_SIZE
	m.max_sessions = 16
	m.cache_age = 500 * time.Millisecond
	defer {
		net.close(sock)
		media_free(m)
	}
	media_sync(s)

	links: [2]Media_Test_Link
	for &l in links {
		media_link_open(t, &l)
	}
	defer for l in links {
		net.close(l.sock)
	}
	out: [proto.MAX_PAYLOAD_SIZE]u8

	// A conn_id that isn't the connection's is refused.
	pt := media_link_handshake(t, m, &links[0], &keys[0], 0x999, out[:])
	testing.expect_value(t, proto.Message_Kind(pt[0]), proto.Message_Kind.Refused)
	testing.expect_value(t, proto.decode_refused(pt), proto.Refusal.No_Connection)
	testing.expect_value(t, len(m.sessions), 0)

	// The right one is welcomed, with the connection's instance.
	for i in 0 ..< 2 {
		pt = media_link_handshake(t, m, &links[i], &keys[i], conns[i].conn_id, out[:])
		testing.expect_value(t, proto.Message_Kind(pt[0]), proto.Message_Kind.Welcome)
		instance, _ := proto.decode_welcome(pt)
		testing.expect_value(t, instance, conns[i].instance)
	}
	testing.expect_value(t, len(m.sessions), 2)

	// The viewer watches the sharer, asking for a keyframe, which the
	// sharer is asked for on its media link.
	watch_buf: [proto.WATCH_SIZE]u8
	media_link_send(m, &links[1], proto.encode_watch(&watch_buf, sharer.num, true))
	pt = media_link_recv(t, &links[0], out[:])
	testing.expect_value(t, proto.Message_Kind(pt[0]), proto.Message_Kind.Keyframe)

	// A fragment of the sharer's goes to the viewer, and not back.
	data := [?]u8{1, 2, 3, 4}
	up_buf: [proto.MAX_PAYLOAD_SIZE]u8
	up := proto.encode_video_up(
		up_buf[:],
		{frame = 7, ts = 100, index = 0, count = 1, key = true, codec = .AV1, data = data[:]},
	)
	media_link_send(m, &links[0], up)
	pt = media_link_recv(t, &links[1], out[:])
	from, f, ok := proto.decode_video_down(pt)
	testing.expect(t, ok)
	testing.expect_value(t, from, sharer.num)
	testing.expect_value(t, f.frame, 7)
	testing.expect_value(t, f.codec, proto.Video_Codec.AV1)
	testing.expect_value(t, len(f.data), len(data))
	testing.expect(t, media_link_quiet(&links[0]))

	// The viewer lost it after all: asked for again, it comes from the
	// cache. What was never sent isn't.
	nack_buf: [proto.NACK_SIZE]u8
	media_link_send(m, &links[1], proto.encode_nack(&nack_buf, sharer.num, {frame = 7, first = 0, missing = 0b11}))
	pt = media_link_recv(t, &links[1], out[:])
	from, f, ok = proto.decode_video_down(pt)
	testing.expect(t, ok)
	testing.expect_value(t, from, sharer.num)
	testing.expect_value(t, f.frame, 7)
	testing.expect_value(t, f.index, 0)
	testing.expect(t, media_link_quiet(&links[1]))

	// Only of whom it watches.
	media_link_send(m, &links[1], proto.encode_nack(&nack_buf, viewer.num, {frame = 7, first = 0, missing = 1}))
	testing.expect(t, media_link_quiet(&links[1]))

	// The viewer's report reaches the sharer as the summary of one; a
	// report on somebody it doesn't watch is dropped.
	report_buf: [proto.REPORT_SIZE]u8
	media_link_send(m, &links[1], proto.encode_report_up(&report_buf, viewer.num, {loss = 900}))
	media_link_send(m, &links[1], proto.encode_report_up(&report_buf, sharer.num, {loss = 25, delay_ms = 60, kbit = 5000}))
	media_reports(m)
	pt = media_link_recv(t, &links[0], out[:])
	testing.expect_value(t, proto.Message_Kind(pt[0]), proto.Message_Kind.Report)
	summary, summary_ok := proto.decode_report_down(pt)
	testing.expect(t, summary_ok)
	testing.expect_value(t, summary, proto.Video_Reports{viewers = 1, worst = {loss = 25, delay_ms = 60, kbit = 5000}})
	testing.expect(t, media_link_quiet(&links[1]))

	// Once they've stopped sharing, their video goes nowhere.
	sharer.flags -= {.Sharing}
	bump_version(s)
	media_sync(s)
	media_link_send(m, &links[0], up)
	testing.expect(t, media_link_quiet(&links[1]))

	// Nor to someone in another room.
	sharer.flags += {.Sharing}
	viewer.room = 2
	bump_version(s)
	media_sync(s)
	media_link_send(m, &links[0], up)
	testing.expect(t, media_link_quiet(&links[1]))
}

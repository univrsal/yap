package server

import "core:crypto/ecdh"
import "core:net"
import "core:testing"
import "core:time"

import "common:proto"

// Tests of the media link (media.odin). These do real handshakes over loopback
// UDP sockets and call the media thread's packet handling directly. They check
// that the media link attaches to a logged in connection, relays a sharer's
// video to whoever watches them in their room, and relays keyframe requests
// back to the sharer.

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

// media_link_quiet reports whether nothing more has arrived on the link.
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
// returns the first of the three copies of the server's answer, after
// reading and discarding the other two.
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

	// Two logged in devices in the same room, one of which is sharing its
	// screen.
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

	// Set up the media thread's state without starting the thread itself.
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

	// A handshake with a conn_id that doesn't match the connection's is
	// refused.
	pt := media_link_handshake(t, m, &links[0], &keys[0], 0x999, out[:])
	testing.expect_value(t, proto.Message_Kind(pt[0]), proto.Message_Kind.Refused)
	testing.expect_value(t, proto.decode_refused(pt), proto.Refusal.No_Connection)
	testing.expect_value(t, len(m.sessions), 0)

	// One with the correct conn_id gets a Welcome with the connection's
	// instance.
	for i in 0 ..< 2 {
		pt = media_link_handshake(t, m, &links[i], &keys[i], conns[i].conn_id, out[:])
		testing.expect_value(t, proto.Message_Kind(pt[0]), proto.Message_Kind.Welcome)
		instance, _ := proto.decode_welcome(pt)
		testing.expect_value(t, instance, conns[i].instance)
	}
	testing.expect_value(t, len(m.sessions), 2)

	// The viewer starts watching the sharer and asks for a keyframe. The
	// request is passed on to the sharer on its media link.
	watch_buf: [proto.WATCH_TILE_SIZE]u8
	media_link_send(m, &links[1], proto.encode_watch(&watch_buf, sharer.num, true))
	pt = media_link_recv(t, &links[0], out[:])
	testing.expect_value(t, proto.Message_Kind(pt[0]), proto.Message_Kind.Keyframe)

	// A video fragment from the sharer is relayed to the viewer, but not
	// back to the sharer.
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

	// Pretend the viewer lost the fragment: when it asks for it again, it's
	// resent from the cache. Fragments that were never sent are not.
	nack_buf: [proto.NACK_CAMERA_SIZE]u8
	media_link_send(
		m,
		&links[1],
		proto.encode_nack(&nack_buf, sharer.num, {frame = 7, first = 0, missing = 0b11}),
	)
	pt = media_link_recv(t, &links[1], out[:])
	from, f, ok = proto.decode_video_down(pt)
	testing.expect(t, ok)
	testing.expect_value(t, from, sharer.num)
	testing.expect_value(t, f.frame, 7)
	testing.expect_value(t, f.index, 0)
	testing.expect(t, media_link_quiet(&links[1]))

	// Resends are only made for users the viewer is watching.
	media_link_send(
		m,
		&links[1],
		proto.encode_nack(&nack_buf, viewer.num, {frame = 7, first = 0, missing = 1}),
	)
	testing.expect(t, media_link_quiet(&links[1]))

	// Nor for a sharer in another room than the viewer's: a lease can be
	// taken on anyone, so the room is what keeps a share private.
	viewer.room = 2
	bump_version(s)
	media_sync(s)
	media_link_send(
		m,
		&links[1],
		proto.encode_nack(&nack_buf, sharer.num, {frame = 7, first = 0, missing = 1}),
	)
	testing.expect(t, media_link_quiet(&links[1]))
	viewer.room = 1
	bump_version(s)
	media_sync(s)

	// The viewer's report reaches the sharer as a summary covering one
	// viewer. A report about somebody the viewer doesn't watch is dropped.
	report_buf: [proto.REPORT_CAMERA_SIZE]u8
	media_link_send(m, &links[1], proto.encode_report_up(&report_buf, viewer.num, {loss = 900}))
	media_link_send(
		m,
		&links[1],
		proto.encode_report_up(&report_buf, sharer.num, {loss = 25, delay_ms = 60, kbit = 5000}),
	)
	media_reports(m)
	pt = media_link_recv(t, &links[0], out[:])
	testing.expect_value(t, proto.Message_Kind(pt[0]), proto.Message_Kind.Report)
	summary, _, summary_ok := proto.decode_report_down(pt)
	testing.expect(t, summary_ok)
	testing.expect_value(
		t,
		summary,
		proto.Video_Reports{viewers = 1, worst = {loss = 25, delay_ms = 60, kbit = 5000}},
	)
	testing.expect(t, media_link_quiet(&links[1]))

	// Once the sharer has stopped sharing, their video isn't relayed to
	// anyone.
	sharer.flags -= {.Sharing}
	bump_version(s)
	media_sync(s)
	media_link_send(m, &links[0], up)
	testing.expect(t, media_link_quiet(&links[1]))

	// It also isn't relayed to someone in another room.
	sharer.flags += {.Sharing}
	viewer.room = 2
	bump_version(s)
	media_sync(s)
	media_link_send(m, &links[0], up)
	testing.expect(t, media_link_quiet(&links[1]))
}

// A sharer's camera and screen are separate streams: each is watched, relayed,
// resent, reported on and asked for keyframes on its own.
@(test)
test_media_camera :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	s.max_sessions = 16
	testing.expect(t, ecdh.private_key_generate(&s.key, .X25519))

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
	sharer := conns[0]
	sharer.flags += {.Camera}
	bump_version(s)

	m := &s.media
	sock, err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	testing.expect_value(t, err, nil)
	m.sock = sock
	m.key = s.key
	m.enabled = true
	m.max_rate = 1_000_000
	m.camera_rate = 500_000
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
	for i in 0 ..< 2 {
		pt := media_link_handshake(t, m, &links[i], &keys[i], conns[i].conn_id, out[:])
		testing.expect_value(t, proto.Message_Kind(pt[0]), proto.Message_Kind.Welcome)
	}

	// Watching the camera tells the sharer at once that it has a viewer, one
	// that didn't say how big it shows it, and asks for a keyframe of it.
	watch_buf: [proto.WATCH_TILE_SIZE]u8
	media_link_send(m, &links[1], proto.encode_watch(&watch_buf, sharer.num, true, .Camera))
	pt := media_link_recv(t, &links[0], out[:])
	demand, demand_ok := proto.decode_demand(pt)
	testing.expect(t, demand_ok)
	testing.expect_value(t, demand, proto.Demand{stream = .Camera, viewers = 1})
	pt = media_link_recv(t, &links[0], out[:])
	stream, key_ok := proto.decode_keyframe(pt)
	testing.expect(t, key_ok)
	testing.expect_value(t, stream, proto.Video_Stream.Camera)

	// The camera's fragments are relayed, a screen that isn't shared isn't.
	data := [?]u8{1, 2, 3, 4}
	camera_buf, screen_buf: [proto.MAX_PAYLOAD_SIZE]u8
	camera := proto.encode_video_up(
		camera_buf[:],
		{frame = 7, index = 0, count = 1, key = true, stream = .Camera, data = data[:]},
	)
	screen := proto.encode_video_up(
		screen_buf[:],
		{frame = 30, index = 0, count = 1, key = true, data = data[:]},
	)
	media_link_send(m, &links[0], camera)
	pt = media_link_recv(t, &links[1], out[:])
	_, f, ok := proto.decode_video_down(pt)
	testing.expect(t, ok)
	testing.expect_value(t, f.stream, proto.Video_Stream.Camera)
	testing.expect_value(t, f.frame, 7)
	media_link_send(m, &links[0], screen)
	testing.expect(t, media_link_quiet(&links[1]))
	cam_sharer := m.sharers[{sharer.num, .Camera}]
	testing.expect(t, cam_sharer.cache != nil)
	testing.expect_value(t, len(cam_sharer.cache.slots), MEDIA_CAMERA_CACHE_SLOTS)

	// Once the screen is shared too, a lease on it doesn't end the one on the
	// camera, and both streams arrive.
	sharer.flags += {.Sharing}
	bump_version(s)
	media_sync(s)
	media_link_send(m, &links[1], proto.encode_watch(&watch_buf, sharer.num, false))
	media_link_send(m, &links[0], screen)
	pt = media_link_recv(t, &links[1], out[:])
	_, f, ok = proto.decode_video_down(pt)
	testing.expect(t, ok)
	testing.expect_value(t, f.stream, proto.Video_Stream.Screen)
	media_link_send(m, &links[0], camera)
	pt = media_link_recv(t, &links[1], out[:])
	_, f, ok = proto.decode_video_down(pt)
	testing.expect(t, ok)
	testing.expect_value(t, f.stream, proto.Video_Stream.Camera)

	// A Nack names the stream: the camera's frame 7 is resent, but the
	// screen has no frame 7.
	nack_buf: [proto.NACK_CAMERA_SIZE]u8
	media_link_send(
		m,
		&links[1],
		proto.encode_nack(&nack_buf, sharer.num, {frame = 7, first = 0, missing = 1}),
	)
	testing.expect(t, media_link_quiet(&links[1]))
	media_link_send(
		m,
		&links[1],
		proto.encode_nack(&nack_buf, sharer.num, {frame = 7, first = 0, missing = 1}, .Camera),
	)
	pt = media_link_recv(t, &links[1], out[:])
	_, f, ok = proto.decode_video_down(pt)
	testing.expect(t, ok)
	testing.expect_value(t, f.stream, proto.Video_Stream.Camera)
	testing.expect_value(t, f.frame, 7)

	// Reports about each stream reach the sharer separately.
	report_buf: [proto.REPORT_CAMERA_SIZE]u8
	media_link_send(
		m,
		&links[1],
		proto.encode_report_up(&report_buf, sharer.num, {loss = 10, kbit = 4000}),
	)
	media_link_send(
		m,
		&links[1],
		proto.encode_report_up(&report_buf, sharer.num, {loss = 30, kbit = 400}, .Camera),
	)
	media_reports(m)
	got: [proto.Video_Stream]proto.Video_Reports
	for _ in 0 ..< 3 {
		pt = media_link_recv(t, &links[0], out[:])
		if proto.Message_Kind(pt[0]) == .Demand {
			demand, demand_ok = proto.decode_demand(pt)
			testing.expect(t, demand_ok)
			testing.expect_value(t, demand.viewers, 1)
			continue
		}
		summary, summary_stream, summary_ok := proto.decode_report_down(pt)
		testing.expect(t, summary_ok)
		got[summary_stream] = summary
	}
	testing.expect_value(
		t,
		got[.Screen],
		proto.Video_Reports{viewers = 1, worst = {loss = 10, kbit = 4000}},
	)
	testing.expect_value(
		t,
		got[.Camera],
		proto.Video_Reports{viewers = 1, worst = {loss = 30, kbit = 400}},
	)

	// A tile that says its size, and then another, are told at once; the same
	// size again isn't.
	media_link_send(
		m,
		&links[1],
		proto.encode_watch(&watch_buf, sharer.num, false, .Camera, tile = {640, 360}),
	)
	pt = media_link_recv(t, &links[0], out[:])
	demand, demand_ok = proto.decode_demand(pt)
	testing.expect(t, demand_ok)
	testing.expect_value(
		t,
		demand,
		proto.Demand{stream = .Camera, tile = {640, 360}, viewers = 1},
	)
	media_link_send(
		m,
		&links[1],
		proto.encode_watch(&watch_buf, sharer.num, false, .Camera, tile = {640, 360}),
	)
	testing.expect(t, media_link_quiet(&links[0]))

	// Ending the camera's lease stops only the camera.
	media_link_send(
		m,
		&links[1],
		proto.encode_watch(&watch_buf, sharer.num, false, .Camera, stop = true),
	)
	media_link_send(m, &links[0], camera)
	testing.expect(t, media_link_quiet(&links[1]))
	media_link_send(m, &links[0], screen)
	pt = media_link_recv(t, &links[1], out[:])
	_, f, ok = proto.decode_video_down(pt)
	testing.expect(t, ok)
	testing.expect_value(t, f.stream, proto.Video_Stream.Screen)

	// With nobody watching it, the sharer is told so once a second.
	media_reports(m)
	for _ in 0 ..< 2 {
		pt = media_link_recv(t, &links[0], out[:])
		if proto.Message_Kind(pt[0]) == .Demand {
			demand, demand_ok = proto.decode_demand(pt)
			testing.expect(t, demand_ok)
			testing.expect_value(t, demand, proto.Demand{stream = .Camera})
		}
	}

	// Without the Camera flag, a camera isn't relayed even with a lease, and
	// what was kept for it is forgotten.
	media_link_send(m, &links[1], proto.encode_watch(&watch_buf, sharer.num, false, .Camera))
	sharer.flags -= {.Camera}
	bump_version(s)
	media_sync(s)
	media_link_send(m, &links[0], camera)
	testing.expect(t, media_link_quiet(&links[1]))
	media_housekeeping(m)
	_, kept := m.sharers[{sharer.num, .Camera}]
	testing.expect(t, !kept)
}

// The main loop keeps the number of cameras in a channel's room to the server's
// limit, by taking the Camera flag off again.
@(test)
test_camera_limit :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	s.media.enabled = true
	s.media.max_cameras = 2

	conns: [3]^Conn
	names := [3]string{"alice", "bob", "carol"}
	for i in 0 ..< 3 {
		key: ecdh.Private_Key
		testing.expect(t, ecdh.private_key_generate(&key, .X25519))
		pub: [proto.KEY_SIZE]u8
		ecdh.private_key_public_bytes(&key, pub[:])
		ts_account(t, &ts, names[i], "password")
		conns[i] = ts_connect(&ts, pub)
		status, _ := ts_login(t, &ts, conns[i], names[i], "password")
		testing.expect_value(t, status, proto.Status.Ok)
	}
	a, b, c := conns[0], conns[1], conns[2]

	// Not without a room.
	sound_set(s, a, {.Camera})
	testing.expect(t, .Camera not_in a.flags)

	for u in conns {
		u.room = 1
	}
	sound_set(s, a, {.Camera})
	sound_set(s, b, {.Camera, .Muted})
	sound_set(s, c, {.Camera, .Muted})
	testing.expect(t, .Camera in a.flags)
	testing.expect(t, .Camera in b.flags)
	// The third camera doesn't fit, but the rest of the flags are taken.
	testing.expect_value(t, c.flags, proto.User_Flags{.Muted})

	// A camera that is on stays on whatever else changes.
	sound_set(s, b, {.Camera})
	testing.expect(t, .Camera in b.flags)

	// Once there is room again, it fits.
	sound_set(s, a, {})
	sound_set(s, c, {.Camera})
	testing.expect(t, .Camera in c.flags)

	// Joining a full room with the camera on turns it off.
	a.room = 2
	sound_set(s, a, {.Camera})
	testing.expect(t, .Camera in a.flags)
	conn_set_room(s, a, 1)
	testing.expect(t, .Camera not_in a.flags)

	// Without cameras on the server, none at all.
	s.media.max_cameras = 0
	sound_set(s, a, {.Camera})
	testing.expect(t, .Camera not_in a.flags)
}

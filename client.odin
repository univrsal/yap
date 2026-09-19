package yap

import "core:crypto/ecdh"
import "core:encoding/endian"
import "core:fmt"
import "core:net"
import "core:time"

import "proto"

// Stand-in for audio until Opus is wired up: 20 ms frames of ~32 kbps.
FRAME_INTERVAL :: 20 * time.Millisecond
FAKE_FRAME_SIZE :: 80

Voice_Client :: struct {
	sock:       net.UDP_Socket,
	server:     net.Endpoint,
	key:        ecdh.Private_Key,
	server_key: ecdh.Public_Key,

	current:      proto.Session,
	has_current:  bool,
	// Kept briefly after a rekey so packets already in flight on the
	// old session still decrypt.
	previous:     proto.Session,
	has_previous: bool,

	handshake:         proto.Initiator,
	handshake_pending: bool,

	last_sent:  time.Tick,
	next_frame: time.Tick,
	seq:        u32,

	// Per-second stats, keyed by speaker id.
	recv_frames: map[u32]int,
	sent_frames: int,
	last_stats:  time.Tick,
}

run_client :: proc(key_path, server_key_hex, server_addr: string) -> bool {
	c: Voice_Client
	if !load_private_key(key_path, &c.key) {
		return false
	}
	defer ecdh.private_key_clear(&c.key)
	if !parse_public_key(server_key_hex, &c.server_key) {
		fmt.eprintln("invalid server public key")
		return false
	}

	ep, resolve_err := net.resolve_ip4(server_addr)
	if resolve_err != nil {
		fmt.eprintfln("failed to resolve %s: %v", server_addr, resolve_err)
		return false
	}
	c.server = ep

	sock, err := net.make_bound_udp_socket(net.IP4_Any, 0)
	if err != nil {
		fmt.eprintln("failed to create socket:", err)
		return false
	}
	defer net.close(sock)
	c.sock = sock
	// Short timeout so the loop can also pace outgoing frames.
	net.set_option(sock, .Receive_Timeout, 2 * time.Millisecond)

	fmt.printfln("my public key: %s", public_key_hex(&c.key))
	c.last_stats = time.tick_now()

	recv_buf: [proto.MAX_PACKET_SIZE]byte
	for {
		free_all(context.temp_allocator)

		drive_handshake(&c)

		if c.has_current {
			if time.tick_diff(c.next_frame, time.tick_now()) >= 0 {
				send_fake_frame(&c)
			} else if time.tick_since(c.last_sent) >= proto.KEEPALIVE_AFTER {
				send_data(&c, nil)
			}
		}

		n, from, recv_err := net.recv_udp(sock, recv_buf[:])
		#partial switch recv_err {
		case .None:
			if from == c.server {
				handle_server_packet(&c, recv_buf[:n])
			}
		case .Timeout, .Would_Block:
		case:
			fmt.eprintln("recv error:", recv_err)
		}

		print_stats(&c)
	}
}

// drive_handshake starts a handshake when there's no usable session or
// the current one is due for rekeying, and retransmits a lost init.
drive_handshake :: proc(c: ^Voice_Client) {
	if c.has_current && time.tick_since(c.current.created) > proto.REJECT_AFTER {
		fmt.println("session expired")
		proto.session_reset(&c.current)
		c.has_current = false
	}

	needs_session := !c.has_current || time.tick_since(c.current.created) > proto.REKEY_AFTER
	switch {
	case needs_session && !c.handshake_pending:
		packet, ok := proto.initiator_start(&c.handshake, &c.key, &c.server_key)
		if !ok {
			fmt.eprintln("failed to start handshake")
			return
		}
		c.handshake_pending = true
		c.handshake.last_sent = time.tick_now()
		net.send_udp(c.sock, packet, c.server)

	case c.handshake_pending && time.tick_since(c.handshake.last_sent) >= proto.HANDSHAKE_RETRY:
		// Resending the identical msg1 is fine: it reuses the same
		// ephemeral key, and the server just answers again.
		c.handshake.last_sent = time.tick_now()
		net.send_udp(c.sock, c.handshake.packet[:c.handshake.packet_len], c.server)
	}
}

handle_server_packet :: proc(c: ^Voice_Client, packet: []byte) {
	#partial switch proto.packet_type(packet) {
	case .Handshake_Resp:
		if !c.handshake_pending {
			return
		}
		fresh: proto.Session
		if !proto.initiator_finish(&c.handshake, packet, &fresh) {
			return
		}
		c.handshake_pending = false

		if c.has_previous {
			proto.session_reset(&c.previous)
		}
		c.previous, c.has_previous = c.current, c.has_current
		c.current, c.has_current = fresh, true

		// IK leaves the server unsure we finished the handshake; our
		// first Data packet is what confirms the session on its side.
		send_data(c, nil)
		fmt.printfln("session established (idx %08x)", c.current.local_idx)

	case .Data:
		idx := proto.data_receiver_index(packet)
		sess: ^proto.Session
		switch {
		case c.has_current && idx == c.current.local_idx:
			sess = &c.current
		case c.has_previous && idx == c.previous.local_idx:
			sess = &c.previous
		case:
			return
		}

		pt_buf: [proto.MAX_PACKET_SIZE]byte
		pt, ok := proto.open(sess, packet, pt_buf[:])
		if !ok || len(pt) == 0 {
			return
		}
		if proto.Message_Kind(pt[0]) == .Voice && len(pt) >= proto.VOICE_DOWN_HEADER_SIZE {
			speaker := endian.unchecked_get_u32le(pt[1:])
			// seq := endian.unchecked_get_u32le(pt[5:])
			// frame := pt[proto.VOICE_DOWN_HEADER_SIZE:]
			// TODO: push (speaker, seq, frame) into a per-speaker jitter buffer -> Opus decode -> mixer.
			c.recv_frames[speaker] += 1
		}
	}
}

send_fake_frame :: proc(c: ^Voice_Client) {
	msg: [proto.VOICE_UP_HEADER_SIZE + FAKE_FRAME_SIZE]byte
	msg[0] = u8(proto.Message_Kind.Voice)
	endian.unchecked_put_u32le(msg[1:], c.seq)
	for &b, i in msg[proto.VOICE_UP_HEADER_SIZE:] {
		b = byte(c.seq) + byte(i)
	}
	c.seq += 1
	// Fixed schedule rather than "now + interval" so jitter doesn't
	// accumulate; if we fell far behind, resync instead of bursting.
	c.next_frame = time.tick_add(c.next_frame, FRAME_INTERVAL)
	if time.tick_diff(c.next_frame, time.tick_now()) > 5 * FRAME_INTERVAL {
		c.next_frame = time.tick_now()
	}
	if send_data(c, msg[:]) {
		c.sent_frames += 1
	}
}

send_data :: proc(c: ^Voice_Client, plaintext: []byte) -> bool {
	pkt_buf: [proto.MAX_PACKET_SIZE]byte
	pkt, ok := proto.seal(&c.current, plaintext, pkt_buf[:])
	if !ok {
		return false
	}
	c.last_sent = time.tick_now()
	_, err := net.send_udp(c.sock, pkt, c.server)
	return err == nil
}

print_stats :: proc(c: ^Voice_Client) {
	if time.tick_since(c.last_stats) < time.Second {
		return
	}
	c.last_stats = time.tick_now()
	fmt.printf("sent %d frames", c.sent_frames)
	for speaker, n in c.recv_frames {
		fmt.printf(" | %08x: %d", speaker, n)
	}
	fmt.println()
	c.sent_frames = 0
	clear(&c.recv_frames)
}

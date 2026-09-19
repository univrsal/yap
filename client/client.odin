package client

import "core:crypto/ecdh"
import "core:encoding/endian"
import "core:encoding/hex"
import "core:fmt"
import "core:log"
import "core:net"
import "core:strings"
import "core:time"

import "../common"
import "../proto"

// Stand-in for audio until Opus is wired up: 20 ms frames of ~32 kbps.
FRAME_INTERVAL :: 20 * time.Millisecond
FAKE_FRAME_SIZE :: 80

Voice_Client :: struct {
	sock:          net.UDP_Socket,
	server:        net.Endpoint,
	server_addr:   string, // as typed; the key in known_servers
	known_servers: string,
	key:           ecdh.Private_Key,

	handshake: proto.Initiator,
	// Keys derived, Finish sent, waiting for the server's first Data
	// packet before switching to it.
	pending:     proto.Session,
	has_pending: bool,
	// The session used for sending.
	current:     proto.Session,
	has_current: bool,
	// Kept after a rekey so packets already in flight on the old session
	// still decrypt.
	previous:     proto.Session,
	has_previous: bool,

	last_sent:  time.Tick,
	next_frame: time.Tick,
	seq:        u32,

	// Per-second stats, keyed by speaker id.
	recv_frames: map[u32]int,
	sent_frames: int,
	last_stats:  time.Tick,
}

run_client :: proc(key_path, server_addr, known_servers: string) -> bool {
	c: Voice_Client
	c.server_addr = server_addr
	c.known_servers = known_servers
	if !common.load_or_create_private_key(key_path, &c.key) {
		return false
	}
	defer ecdh.private_key_clear(&c.key)

	ep, resolve_err := net.resolve_ip4(server_addr)
	if resolve_err != nil {
		log.errorf("failed to resolve %s: %v", server_addr, resolve_err)
		return false
	}
	c.server = ep

	sock, err := net.make_bound_udp_socket(net.IP4_Any, 0)
	if err != nil {
		log.errorf("failed to create socket: %v", err)
		return false
	}
	defer net.close(sock)
	c.sock = sock
	// Short timeout so the loop can also pace outgoing frames.
	net.set_option(sock, .Receive_Timeout, 2 * time.Millisecond)

	log.infof("my public key: %s", common.public_key_hex(&c.key))
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
			if from == c.server && !common.simulate_loss() && !handle_server_packet(&c, recv_buf[:n]) {
				return false
			}
		case .Timeout, .Would_Block:
		case:
			log.errorf("recv error: %v", recv_err)
		}

		log_stats(&c)
	}
}

// drive_handshake starts a handshake when there's no usable session or
// the current one is due for rekeying, retransmits lost handshake
// packets, and starts over if a handshake stalls.
drive_handshake :: proc(c: ^Voice_Client) {
	if c.has_current && time.tick_since(c.current.created) > proto.REJECT_AFTER {
		log.warn("session expired without a successful rekey")
		proto.session_reset(&c.current)
		c.has_current = false
	}

	ini := &c.handshake
	if ini.state != .Idle && time.tick_since(ini.started) > proto.HANDSHAKE_TIMEOUT {
		log.warn("handshake timed out, retrying")
		abandon_handshake(c)
	}

	switch ini.state {
	case .Idle:
		if c.has_current && time.tick_since(c.current.created) <= proto.REKEY_AFTER {
			return
		}
		packet, ok := proto.initiator_start(ini, &c.key)
		if !ok {
			log.error("failed to start handshake")
			return
		}
		ini.last_sent = time.tick_now()
		net.send_udp(c.sock, packet, c.server)

	case .Sent_Init, .Sent_Finish:
		// Resending verbatim is fine: the server answers a repeated Init
		// with the same Resp, and a repeated Finish with a new keepalive.
		if time.tick_since(ini.last_sent) >= proto.HANDSHAKE_RETRY {
			log.debugf("resending %v", proto.packet_type(proto.initiator_packet(ini)))
			ini.last_sent = time.tick_now()
			net.send_udp(c.sock, proto.initiator_packet(ini), c.server)
		}
	}
}

abandon_handshake :: proc(c: ^Voice_Client) {
	proto.initiator_reset(&c.handshake)
	if c.has_pending {
		proto.session_reset(&c.pending)
		c.has_pending = false
	}
}

// Returns false if the connection must be aborted.
handle_server_packet :: proc(c: ^Voice_Client, packet: []byte) -> bool {
	#partial switch proto.packet_type(packet) {
	case .Handshake_Resp:
		server_key, result := proto.initiator_read_resp(&c.handshake, packet)
		if result != .Ok {
			return true // ignored, or failed and will be retried
		}
		if !verify_server_key(c, server_key) {
			abandon_handshake(c)
			return false
		}
		// Only now, with the server's identity checked, send ours.
		// TODO: pass the server password as the payload here.
		finish, ok := proto.initiator_finish(&c.handshake, &c.pending)
		if !ok {
			return true
		}
		c.has_pending = true
		c.handshake.last_sent = time.tick_now()
		net.send_udp(c.sock, finish, c.server)

	case .Data:
		idx := proto.receiver_index(packet)
		sess: ^proto.Session
		switch {
		case c.has_pending && idx == c.pending.local_idx:
			sess = &c.pending
		case c.has_current && idx == c.current.local_idx:
			sess = &c.current
		case c.has_previous && idx == c.previous.local_idx:
			sess = &c.previous
		case:
			return true
		}

		pt_buf: [proto.MAX_PACKET_SIZE]byte
		pt, ok := proto.open(sess, packet, pt_buf[:])
		if !ok {
			return true
		}
		if sess == &c.pending {
			promote_pending(c)
		}
		if len(pt) > 0 && proto.Message_Kind(pt[0]) == .Voice && len(pt) >= proto.VOICE_DOWN_HEADER_SIZE {
			speaker := endian.unchecked_get_u32le(pt[1:])
			// seq := endian.unchecked_get_u32le(pt[5:])
			// frame := pt[proto.VOICE_DOWN_HEADER_SIZE:]
			// TODO: push (speaker, seq, frame) into a per-speaker jitter buffer -> Opus decode -> mixer.
			c.recv_frames[speaker] += 1
		}
	}
	return true
}

// The server has confirmed the pending session: start sending on it.
promote_pending :: proc(c: ^Voice_Client) {
	if c.has_previous {
		proto.session_reset(&c.previous)
	}
	c.previous, c.has_previous = c.current, c.has_current
	c.current, c.has_current = c.pending, true
	c.pending, c.has_pending = {}, false
	proto.initiator_reset(&c.handshake)

	if c.has_previous {
		log.debugf("rekeyed (session %08x)", c.current.local_idx)
	} else {
		c.next_frame = time.tick_now()
		c.last_stats = c.next_frame
		log.infof("connected to %s", c.server_addr)
	}
}

// verify_server_key implements trust on first use: remember the key the
// first time, and refuse to continue if it ever changes.
verify_server_key :: proc(c: ^Voice_Client, key: [proto.KEY_SIZE]byte) -> bool {
	key := key
	key_hex := string(hex.encode(key[:], context.temp_allocator))

	trust, saved := check_server_key(c.known_servers, c.server_addr, key)
	switch trust {
	case .Known:
		return true

	case .New:
		if remember_server_key(c.known_servers, c.server_addr, key) {
			log.infof("first connection to %s, trusting server key %s (saved to %s)", c.server_addr, key_hex, c.known_servers)
		} else {
			log.warnf("first connection to %s, trusting server key %s for now, but it could not be saved", c.server_addr, key_hex)
		}
		return true

	case .Mismatch:
		log.errorf("the key of %s has changed! saved %s, received %s",
			c.server_addr, string(hex.encode(saved[:], context.temp_allocator)), key_hex)
		log.error("someone may be impersonating the server, or it got a new key")
		log.errorf("if the change is expected, remove the %s line from %s", c.server_addr, c.known_servers)
		return false
	}
	return false
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

log_stats :: proc(c: ^Voice_Client) {
	if !c.has_current || time.tick_since(c.last_stats) < time.Second {
		return
	}
	c.last_stats = time.tick_now()
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "sent %d frames", c.sent_frames)
	for speaker, n in c.recv_frames {
		fmt.sbprintf(&b, " | %08x: %d", speaker, n)
	}
	log.debug(strings.to_string(b))
	c.sent_frames = 0
	clear(&c.recv_frames)
}

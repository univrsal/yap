package yap

import "core:crypto/ecdh"
import "core:encoding/endian"
import "core:fmt"
import "core:net"
import "core:time"

import "proto"

// Bounds memory used by unauthenticated Handshake_Init floods.
MAX_SESSIONS :: 256

Client :: struct {
	using session: proto.Session,
	endpoint:  net.Endpoint,
	confirmed: bool, // a valid Data packet has arrived on this session
	last_recv: time.Tick,
}

Server :: struct {
	sock:     net.UDP_Socket,
	key:      ecdh.Private_Key,
	sessions: map[u32]^Client, // by local_idx
}

run_server :: proc(key_path: string, port: int) -> bool {
	s: Server
	if !load_private_key(key_path, &s.key) {
		return false
	}
	defer ecdh.private_key_clear(&s.key)

	sock, err := net.make_bound_udp_socket(net.IP4_Any, port)
	if err != nil {
		fmt.eprintfln("failed to bind port %d: %v", port, err)
		return false
	}
	defer net.close(sock)
	s.sock = sock
	// Wake up periodically even when idle so stale sessions get reaped.
	net.set_option(sock, .Receive_Timeout, 250 * time.Millisecond)

	fmt.printfln("listening on udp :%d", port)
	fmt.printfln("server public key: %s", public_key_hex(&s.key))

	recv_buf: [proto.MAX_PACKET_SIZE]byte
	for {
		free_all(context.temp_allocator)

		n, from, recv_err := net.recv_udp(sock, recv_buf[:])
		#partial switch recv_err {
		case .None:
			handle_packet(&s, recv_buf[:n], from)
		case .Timeout, .Would_Block:
		case:
			fmt.eprintln("recv error:", recv_err)
		}

		reap_sessions(&s)
	}
}

handle_packet :: proc(s: ^Server, packet: []byte, from: net.Endpoint) {
	#partial switch proto.packet_type(packet) {
	case .Handshake_Init:
		handle_init(s, packet, from)
	case .Data:
		handle_data(s, packet, from)
	}
	// Anything else is silently dropped: never answer what we can't authenticate.
}

handle_init :: proc(s: ^Server, packet: []byte, from: net.Endpoint) {
	if len(s.sessions) >= MAX_SESSIONS {
		return
	}

	idx: u32
	for {
		idx = proto.random_index()
		if idx not_in s.sessions {
			break
		}
	}

	c := new(Client)
	resp_buf: [proto.MAX_PACKET_SIZE]byte
	resp, ok := proto.responder_accept(&s.key, packet, idx, &c.session, resp_buf[:])
	if !ok {
		free(c)
		return
	}
	// TODO: check c.peer_key against an allowlist here to restrict who can join.

	c.endpoint = from
	c.last_recv = time.tick_now()
	s.sessions[idx] = c
	net.send_udp(s.sock, resp, from)
}

handle_data :: proc(s: ^Server, packet: []byte, from: net.Endpoint) {
	c := s.sessions[proto.data_receiver_index(packet)] or_else nil
	if c == nil || time.tick_since(c.created) > proto.REJECT_AFTER {
		return
	}

	pt_buf: [proto.MAX_PACKET_SIZE]byte
	pt, ok := proto.open(&c.session, packet, pt_buf[:])
	if !ok {
		return
	}

	// Authenticated, so it's safe to follow the client to a new address.
	c.endpoint = from
	c.last_recv = time.tick_now()

	if !c.confirmed {
		c.confirmed = true
		if has_other_session(s, c) {
			retire_older_sessions(s, c)
		} else {
			fmt.printfln("%08x joined from %v", key_id(c.peer_key), net.to_string(from))
		}
	}

	if len(pt) == 0 {
		return // keepalive
	}
	if proto.Message_Kind(pt[0]) == .Voice && len(pt) >= proto.VOICE_UP_HEADER_SIZE {
		relay_voice(s, c, pt)
	}
}

// relay_voice forwards a voice frame to every other confirmed client,
// re-encrypted under each recipient's session.
relay_voice :: proc(s: ^Server, from: ^Client, pt: []byte) {
	// [kind][seq][frame] -> [kind][speaker][seq][frame]
	out_pt: [proto.MAX_PAYLOAD_SIZE]byte
	body := pt[1:] // seq + frame
	n := 1 + 4 + len(body)
	if n > len(out_pt) {
		return
	}
	out_pt[0] = u8(proto.Message_Kind.Voice)
	endian.unchecked_put_u32le(out_pt[1:], key_id(from.peer_key))
	copy(out_pt[5:], body)
	msg := out_pt[:n]

	pkt_buf: [proto.MAX_PACKET_SIZE]byte
	for _, c in s.sessions {
		if !c.confirmed || c.peer_key == from.peer_key {
			continue
		}
		if pkt, ok := proto.seal(&c.session, msg, pkt_buf[:]); ok {
			net.send_udp(s.sock, pkt, c.endpoint)
		}
	}
}

// After a rekey the client has moved to the new session, so older ones
// for the same key are dead weight (and would get duplicate relays).
retire_older_sessions :: proc(s: ^Server, current: ^Client) {
	stale := make([dynamic]u32, context.temp_allocator)
	for idx, c in s.sessions {
		if c != current && c.peer_key == current.peer_key {
			append(&stale, idx)
		}
	}
	for idx in stale {
		drop_session(s, idx)
	}
}

reap_sessions :: proc(s: ^Server) {
	stale := make([dynamic]u32, context.temp_allocator)
	for idx, c in s.sessions {
		expired: bool
		switch {
		case !c.confirmed:
			expired = time.tick_since(c.created) > proto.HANDSHAKE_TIMEOUT
		case:
			expired = time.tick_since(c.last_recv) > proto.SESSION_TIMEOUT ||
			          time.tick_since(c.created) > proto.REJECT_AFTER
		}
		if expired {
			append(&stale, idx)
		}
	}
	for idx in stale {
		c := s.sessions[idx]
		if c.confirmed && !has_other_session(s, c) {
			fmt.printfln("%08x left", key_id(c.peer_key))
		}
		drop_session(s, idx)
	}
}

has_other_session :: proc(s: ^Server, c: ^Client) -> bool {
	for _, other in s.sessions {
		if other != c && other.confirmed && other.peer_key == c.peer_key {
			return true
		}
	}
	return false
}

drop_session :: proc(s: ^Server, idx: u32) {
	c := s.sessions[idx]
	delete_key(&s.sessions, idx)
	proto.session_reset(&c.session)
	free(c)
}

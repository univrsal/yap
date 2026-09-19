package client

import "core:crypto/ecdh"
import "core:encoding/endian"
import "core:encoding/hex"
import "core:fmt"
import "core:log"
import "core:net"
import "core:strings"
import "core:sync"
import "core:time"

import "../common"
import "../proto"

Voice_Client :: struct {
	sock:          net.UDP_Socket,
	server:        net.Endpoint,
	server_addr:   string, // as typed; the key in known_servers
	known_servers: string,
	key:           ecdh.Private_Key,
	my_id:         u32,

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

	last_sent: time.Tick,
	voice:     Voice, // set up by the owner before client_open

	channels: Channel_Client,
	commands: Command_Queue,

	status:    Status,
	sock_open: bool,
	// Shared with the UI, if there is one; nil in headless mode.
	view: ^View,

	// Per-second stats, keyed by speaker id.
	last_stats: time.Tick,
}

// client_open loads our key and prepares the socket. It doesn't wait
// for the server: the handshake happens in client_step.
client_open :: proc(c: ^Voice_Client, key_path, server_addr, known_servers: string) -> bool {
	c.server_addr = strings.clone(server_addr)
	c.known_servers = strings.clone(known_servers)

	if !common.load_or_create_private_key(key_path, &c.key) {
		publish_status(c, .Failed, fmt.tprintf("Could not load the key file %s.", key_path))
		return false
	}
	pub: [proto.KEY_SIZE]byte
	ecdh.private_key_public_bytes(&c.key, pub[:])
	c.my_id = common.key_id(pub)
	log.infof("my public key: %s", common.public_key_hex(&c.key))
	publish_status(c, .Connecting)

	ep, resolve_err := net.resolve_ip4(server_addr)
	if resolve_err != nil {
		log.errorf("failed to resolve %s: %v", server_addr, resolve_err)
		publish_status(c, .Failed, fmt.tprintf("Could not resolve %s. Expected host:port.", server_addr))
		return false
	}
	c.server = ep

	sock, err := net.make_bound_udp_socket(net.IP4_Any, 0)
	if err != nil {
		log.errorf("failed to create socket: %v", err)
		publish_status(c, .Failed, "Could not open a network socket.")
		return false
	}
	c.sock = sock
	c.sock_open = true
	// Short timeout so the loop can also pace outgoing frames.
	net.set_option(sock, .Receive_Timeout, 2 * time.Millisecond)
	c.last_stats = time.tick_now()
	return true
}

// client_close says goodbye to the server (if connected) and releases
// everything client_open and the connection acquired.
client_close :: proc(c: ^Voice_Client) {
	if c.has_current {
		// Unreliable, so send a few; the server times us out otherwise.
		leave := [1]byte{u8(proto.Message_Kind.Leave)}
		for _ in 0 ..< 3 {
			send_data(c, leave[:])
		}
	}
	if c.sock_open {
		net.close(c.sock)
		c.sock_open = false
	}

	proto.initiator_reset(&c.handshake)
	proto.session_reset(&c.pending)
	proto.session_reset(&c.current)
	proto.session_reset(&c.previous)
	ecdh.private_key_clear(&c.key)

	delete(c.server_addr)
	delete(c.known_servers)
	delete(c.channels.wanted)
	commands_destroy(&c.commands)
}

// client_step runs one iteration of the network loop, waiting up to a
// couple of milliseconds for a packet. It returns false once the
// connection has failed for good.
client_step :: proc(c: ^Voice_Client) -> bool {
	free_all(context.temp_allocator)

	drive_handshake(c)
	process_commands(c)
	drive_join(c)

	if c.has_current {
		voice_step(c)
		if time.tick_since(c.last_sent) >= proto.KEEPALIVE_AFTER {
			send_data(c, nil)
		}
	}

	recv_buf: [proto.MAX_PACKET_SIZE]byte
	n, from, recv_err := net.recv_udp(c.sock, recv_buf[:])
	#partial switch recv_err {
	case .None:
		if from == c.server && !common.simulate_loss() && !handle_server_packet(c, recv_buf[:n]) {
			return false
		}
	case .Timeout, .Would_Block:
	case:
		log.errorf("recv error: %v", recv_err)
	}

	log_stats(c)
	return true
}

// run_headless is the command-line client: commands come from stdin.
// With tone_hz > 0 it "talks" by sending that tone and logs what it hears
// (see Fake_Audio), which exercises the whole voice path without devices.
run_headless :: proc(key_path, server_addr, known_servers, initial_channel: string, tone_hz: f32) -> bool {
	// Heap-allocated: the channel state buffers make it fairly large.
	c := new(Voice_Client)
	defer free(c)
	if !voice_init(&c.voice) {
		return false
	}
	defer voice_destroy(&c.voice)
	fake: Fake_Audio
	if tone_hz > 0 {
		fake_audio_start(&fake, &c.voice, tone_hz)
	}
	defer fake_audio_stop(&fake)
	defer client_close(c)
	if !client_open(c, key_path, server_addr, known_servers) {
		return false
	}

	if initial_channel != "" {
		request_join(c, initial_channel)
	}
	start_command_reader(&c.commands)

	for client_step(c) {}
	return false
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
			publish_status(c, .Failed, fmt.tprintf(
				"The key of %s has changed, so the connection was refused. See the log for details.", c.server_addr))
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
		kind, kind_ok := proto.message_kind(pt)
		if !kind_ok {
			return true // keepalive, or malformed
		}
		#partial switch kind {
		case .Voice:
			if len(pt) >= proto.VOICE_DOWN_HEADER_SIZE && in_settled_channel(c) {
				speaker := endian.unchecked_get_u32le(pt[1:])
				seq := endian.unchecked_get_u32le(pt[5:])
				voice_receive(c, speaker, seq, pt[proto.VOICE_DOWN_HEADER_SIZE:])
			}
		case .State:
			handle_state_message(c, pt)
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
		c.last_stats = time.tick_now()
		log.infof("connected to %s", c.server_addr)
		publish_status(c, .Connected)
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
	v := &c.voice
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "voice: captured %d, sent %d frames (%d B)", v.captured, v.sent_frames, v.sent_bytes)
	for speaker, n in v.received {
		fmt.sbprintf(&b, " | %08x: %d", speaker, n)
	}
	if v.concealed > 0 {
		fmt.sbprintf(&b, " | concealed %d", v.concealed)
	}
	if underruns := sync.atomic_exchange(&v.underruns, 0); underruns > 0 {
		fmt.sbprintf(&b, " | %d output underruns", underruns)
	}
	log.debug(strings.to_string(b))
	v.captured, v.sent_frames, v.sent_bytes, v.concealed = 0, 0, 0, 0
	clear(&v.received)
}

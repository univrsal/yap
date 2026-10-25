package server

import "core:crypto"
import "core:crypto/ecdh"
import "core:crypto/hash"
import "core:net"
import "core:time"

import "common:proto"
import "gate"

// Session_Base is what a session has on the server, on the main port (Client)
// and on the media port (Media_Session) alike: the handshake it came from, the
// keys, and where and how recently the client was heard. The procedures here
// are the parts of handling Init, Finish and Data that the two ports share, so
// that a fix to one is a fix to both.
Session_Base :: struct {
	using session: proto.Session,
	handshake:     proto.Responder, // in use until keyed
	endpoint:      net.Endpoint,
	started:       time.Tick, // when the Handshake_Init arrived
	last_recv:     time.Tick,
	// Handshake_Finish was verified: the client proved it holds its key.
	keyed:         bool,
	// The client has sent Data on this session, so it has switched over
	// to it and any older sessions with the same key can be dropped.
	confirmed:     bool,
	// A newer session with the same client key exists. This one is still
	// accepted for receiving (packets may still be in flight), but never
	// used for sending.
	superseded:    bool,
	// When the Welcome was last sent again for a resent Handshake_Finish.
	rewelcomed:    time.Tick,
}

// How often a keyed session answers a resent Handshake_Finish with another
// Welcome at most. The Finish isn't checked again, so anyone who knows the
// session's index could otherwise make the server send Welcomes as fast as
// they send Finishes.
REWELCOME_EVERY :: 500 * time.Millisecond

// How many copies of Welcome and Refused are sent, since they are sent
// unreliably (like Leave).
WELCOME_COPIES :: 3
REFUSED_COPIES :: 3

// session_init handles a Handshake_Init: it turns away a flood cheaply, asks
// for a cookie when the server is busy, answers a retransmitted Init with the
// same Resp, and otherwise starts a session in `sessions`, which it returns.
session_init :: proc(
	sock: net.UDP_Socket,
	key: ^ecdh.Private_Key,
	g: ^gate.Gate,
	sessions: ^map[proto.Session_Id]^$S,
	max_sessions: int,
	packet: []byte,
	from: net.Endpoint,
) -> (
	started: ^S,
) {
	sender_idx := proto.init_sender_index(packet)
	// This comes first so that a flood of Inits is turned away cheaply.
	verdict, cookie := gate.check(g, packet, from, len(sessions), max_sessions)
	if verdict == .Cookie {
		buf: [proto.COOKIE_PACKET_SIZE]byte
		net.send_udp(sock, proto.encode_cookie_packet(&buf, sender_idx, cookie), from)
		return
	}

	// A retransmitted Init (because our Resp got lost) gets the same Resp
	// again rather than starting a second handshake.
	for _, c in sessions {
		if !c.keyed && c.handshake.remote_idx == sender_idx && c.endpoint == from {
			net.send_udp(sock, c.handshake.packet[:], from)
			return
		}
	}
	if verdict != .Accept {
		return
	}

	idx: proto.Session_Id
	for {
		idx = proto.random_index()
		if idx not_in sessions {
			break
		}
	}

	c := new(S)
	resp, ok := proto.responder_start(&c.handshake, key, packet, idx)
	if !ok {
		free(c)
		return
	}
	c.endpoint = from
	c.started = time.tick_now()
	sessions[idx] = c
	gate.opened(g, from)
	net.send_udp(sock, resp, from)
	return c
}

Finish_Result :: enum {
	Ok,
	Invalid, // the handshake failed: the session is dropped
	Version, // the hello can't be read: refuse
	Wrong_Password, // refuse
}

// session_finish checks a Handshake_Finish and reads the hello in it (which of
// the client's connections this is, and which of the connection's links the
// session is for), and the server password. The caller then refuses, or goes
// on with session_keyed. On failure the handshake state is used up, so the
// session is dropped too, and the client will time out and start a fresh
// handshake.
session_finish :: proc(
	b: ^Session_Base,
	g: ^gate.Gate,
	password: string,
	packet: []byte,
	from: net.Endpoint,
) -> (
	conn_id: u64,
	link: proto.Link,
	result: Finish_Result,
) {
	payload, ok := proto.responder_finish(&b.handshake, packet, &b.session)
	if !ok {
		return 0, {}, .Invalid
	}
	id, got_password, hello_link, hello_ok := proto.decode_hello(payload)
	switch {
	case !hello_ok:
		return 0, {}, .Version
	case password != "" && !password_matches(password, got_password):
		gate.wrong_password(g, from)
		return 0, {}, .Wrong_Password
	}
	return id, hello_link, .Ok
}

// session_keyed marks a session whose handshake has just finished.
session_keyed :: proc(b: ^Session_Base, g: ^gate.Gate, from: net.Endpoint) {
	gate.closed(g, b.endpoint)
	b.keyed = true
	b.endpoint = from
	b.last_recv = time.tick_now()
}

// session_rewelcome_due says whether a keyed session may answer a resent
// Handshake_Finish (its Welcome got lost) with another Welcome now.
session_rewelcome_due :: proc(b: ^Session_Base) -> bool {
	now := time.tick_now()
	if b.rewelcomed != {} && time.tick_diff(b.rewelcomed, now) < REWELCOME_EVERY {
		return false
	}
	b.rewelcomed = now
	return true
}

// session_send seals `msg` for the session and sends it to `to`.
session_send :: proc(sock: net.UDP_Socket, b: ^Session_Base, msg: []byte, to: net.Endpoint) {
	pkt_buf: [proto.MAX_PACKET_SIZE]byte
	if pkt, ok := proto.seal(&b.session, msg, pkt_buf[:]); ok {
		net.send_udp(sock, pkt, to)
	}
}

// session_refuse tells a client that just finished its handshake why it can't
// join, with the session created by that handshake. The caller drops the
// session after this.
session_refuse :: proc(
	sock: net.UDP_Socket,
	b: ^Session_Base,
	from: net.Endpoint,
	reason: proto.Refusal,
) {
	msg_buf: [proto.REFUSED_SIZE]byte
	msg := proto.encode_refused(&msg_buf, reason)
	for _ in 0 ..< REFUSED_COPIES {
		session_send(sock, b, msg, from)
	}
}

// session_receive opens a Data packet for a keyed session. The packet is
// authenticated then, so it is safe to follow the client to a new address,
// with `follow` (not before the client has logged in, though: the handshake can
// be made by anyone who knows the server password, and packets with the source
// address of somebody else would make the server send its answers there).
session_receive :: proc(
	b: ^Session_Base,
	packet: []byte,
	from: net.Endpoint,
	out: []byte,
	follow: bool,
) -> (
	pt: []byte,
	ok: bool,
) {
	if !b.keyed || time.tick_since(b.created) > proto.REJECT_AFTER {
		return
	}
	pt = proto.open(&b.session, packet, out) or_return
	if from != b.endpoint {
		if !follow {
			return nil, false
		}
		b.endpoint = from
	}
	b.last_recv = time.tick_now()
	return pt, true
}

// session_confirm notes that the client has sent Data on the session, and says
// whether that is the first time (and the session is not superseded), when the
// older sessions of the same client can be dropped.
session_confirm :: proc(b: ^Session_Base) -> bool {
	if b.confirmed || b.superseded {
		return false
	}
	b.confirmed = true
	return true
}

// session_expired says whether a session has outlived its handshake, its
// silence, or its keys.
session_expired :: proc(b: ^Session_Base) -> bool {
	if !b.keyed {
		return time.tick_since(b.started) > proto.HANDSHAKE_TIMEOUT
	}
	return(
		time.tick_since(b.last_recv) > proto.SESSION_TIMEOUT ||
		time.tick_since(b.created) > proto.REJECT_AFTER \
	)
}

// session_release closes a session's handshake and wipes its keys. The caller
// has taken it out of its map, and frees it.
session_release :: proc(g: ^gate.Gate, b: ^Session_Base) {
	if !b.keyed {
		gate.closed(g, b.endpoint)
	}
	proto.responder_reset(&b.handshake)
	proto.session_reset(&b.session)
}

// password_matches compares the hashes of both passwords, so the time it
// takes reveals nothing about the password, not even its length.
password_matches :: proc(want, got: string) -> bool {
	a := hash.hash_string(.SHA256, want, context.temp_allocator)
	b := hash.hash_string(.SHA256, got, context.temp_allocator)
	return crypto.compare_constant_time(a, b) == 1
}

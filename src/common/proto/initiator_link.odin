package proto

import "core:crypto/ecdh"
import "core:time"

// Initiator_Link is the client's side of one link to a server: the handshake
// that is going on and the sessions it makes. Every link (the main, bulk and
// media links of the client, and the lite client's) drives it the same way and
// differs only in where the packets go and what it does with a refusal:
//
//   link_step      starts a handshake when there is no usable session, when the
//                  current one is due for rekeying or the server has gone quiet
//                  on it (it may have restarted and no longer know the session),
//                  resends a lost handshake packet and gives up on a stalled one
//   link_cookie    answers a busy server's cookie
//   link_resp      reads the server's Resp, and link_finish answers it with the hello
//   link_open      opens a Data packet with whichever session it is for
//   link_promote   switches to the pending session once the server has confirmed it
Initiator_Link :: struct {
	handshake:    Initiator,
	// The keys are derived and Finish has been sent. We are waiting for the
	// server's first Data packet before switching to this session.
	pending:      Session,
	has_pending:  bool,
	// The session used for sending.
	current:      Session,
	has_current:  bool,
	// Kept after a rekey so that packets that are still in flight on the old
	// session can be decrypted.
	previous:     Session,
	has_previous: bool,
	// When the server was last heard from, on any session.
	last_recv:    time.Tick,
}

// Link_Step is what link_step did, for the link to act on and log.
Link_Step :: struct {
	// A handshake packet to send: the first one, or a resend.
	packet:  []byte,
	started: bool, // `packet` begins a new handshake
	expired: bool, // the current session was too old and has been dropped
	stalled: bool, // the handshake took too long and has been abandoned
	silent:  bool, // the handshake was started because the server went quiet
}

// link_step moves the link's handshake along. With `restart` a new handshake
// is started even though the session is fine, and with `hold` none is started
// (the link is waiting to retry). After a stalled handshake nothing is started
// in the same step, so that the link can decide how long to wait.
link_step :: proc(
	l: ^Initiator_Link,
	key: ^ecdh.Private_Key,
	now: time.Tick,
	restart := false,
	hold := false,
) -> (
	s: Link_Step,
) {
	if l.has_current && time.tick_diff(l.current.created, now) > REJECT_AFTER {
		session_reset(&l.current)
		l.has_current = false
		s.expired = true
	}
	ini := &l.handshake
	if ini.state != .Idle && time.tick_diff(ini.started, now) > HANDSHAKE_TIMEOUT {
		link_abandon(l)
		s.stalled = true
		return
	}
	switch ini.state {
	case .Idle:
		silent := l.has_current && time.tick_diff(l.last_recv, now) > SERVER_SILENT
		if l.has_current &&
		   time.tick_diff(l.current.created, now) <= REKEY_AFTER &&
		   !silent &&
		   !restart {
			return
		}
		if hold {
			return
		}
		packet, ok := initiator_start(ini, key)
		if !ok {
			return
		}
		ini.last_sent = now
		s.packet, s.started, s.silent = packet, true, silent
	case .Sent_Init, .Sent_Finish:
		// Resending the packet unchanged is fine. The server answers a repeated
		// Init with the same Resp, and a repeated Finish with a new keepalive.
		if time.tick_diff(ini.last_sent, now) >= HANDSHAKE_RETRY {
			ini.last_sent = now
			s.packet = initiator_packet(ini)
		}
	}
	return
}

// link_cookie reads the cookie of a server that is busy and wants to know that
// we can be reached here. It returns the Init to send again, with the cookie.
link_cookie :: proc(l: ^Initiator_Link, packet: []byte) -> (resend: []byte, ok: bool) {
	if !initiator_read_cookie(&l.handshake, packet) {
		return
	}
	l.handshake.last_sent = time.tick_now()
	return initiator_packet(&l.handshake), true
}

// link_resp reads the server's answer to our Init. It returns the server's key
// if the answer was good (and false if it was ignored or failed and will be
// retried later). The link then checks the key, and link_finish answers.
link_resp :: proc(l: ^Initiator_Link, packet: []byte) -> (server_key: [KEY_SIZE]byte, ok: bool) {
	key, result := initiator_read_resp(&l.handshake, packet)
	return key, result == .Ok
}

// link_finish answers a Resp whose key is the server's, with the hello for the
// link, and returns the Finish to send. The session it makes is the pending one.
link_finish :: proc(l: ^Initiator_Link, hello: []byte) -> (finish: []byte, ok: bool) {
	finish = initiator_finish(&l.handshake, &l.pending, hello) or_return
	l.has_pending = true
	l.handshake.last_sent = time.tick_now()
	return finish, true
}

// link_abandon drops the handshake that is going on, and the session it made.
link_abandon :: proc(l: ^Initiator_Link) {
	initiator_reset(&l.handshake)
	if l.has_pending {
		session_reset(&l.pending)
		l.has_pending = false
	}
}

// link_reset forgets a link's handshake and sessions.
link_reset :: proc(l: ^Initiator_Link) {
	initiator_reset(&l.handshake)
	session_reset(&l.pending)
	session_reset(&l.current)
	session_reset(&l.previous)
	l.has_pending, l.has_current, l.has_previous = false, false, false
}

// link_open opens a Data packet that came over the link, using whichever of the
// link's sessions it is addressed to. `pending` is true if it was the pending
// session, which the caller has to promote once it is sure of the packet.
link_open :: proc(
	l: ^Initiator_Link,
	packet: []byte,
	out: []byte,
) -> (
	pt: []byte,
	pending: bool,
	ok: bool,
) {
	idx := receiver_index(packet)
	sess: ^Session
	switch {
	case l.has_pending && idx == l.pending.local_idx:
		sess = &l.pending
	case l.has_current && idx == l.current.local_idx:
		sess = &l.current
	case l.has_previous && idx == l.previous.local_idx:
		sess = &l.previous
	case:
		return
	}
	pt = open(sess, packet, out) or_return
	l.last_recv = time.tick_now()
	return pt, sess == &l.pending, true
}

// link_promote switches the link over to its pending session, which the server
// has confirmed. It returns whether this is the link's first session.
link_promote :: proc(l: ^Initiator_Link) -> (first: bool) {
	if l.has_previous {
		session_reset(&l.previous)
	}
	l.previous, l.has_previous = l.current, l.has_current
	l.current, l.has_current = l.pending, true
	l.pending, l.has_pending = {}, false
	initiator_reset(&l.handshake)
	return !l.has_previous
}

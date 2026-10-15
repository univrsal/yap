package conn

import log "common:wlog"
import "core:time"

import "common:."
import "common:proto"

// The bulk link (proto.Link in proto/names.odin) is a second transport to the
// server with its own sessions. It carries the heavy traffic: video and the
// chunks of blobs, attachments and files (proto.HEAVY_KINDS). Voice and
// everything else that is small stays on the main link, so it never has to wait
// behind heavy traffic in a WebSocket's buffer, in TCP retransmissions, in the
// relay, or in the web client's packet queue (which handles only a frame's
// worth of packets at a time).
//
// The bulk link is opened once the main link has been welcomed. It performs its
// own handshake, whose hello names the same connection, and it renews that
// handshake on its own schedule. It ends together with the connection: a
// Welcome for a new connection starts it over (see bulk_restart). Until the bulk
// link is up, send_data sends heavy messages over the main link.
//
// The server only sends heavy traffic over this link. A client that only sends
// (for example while sharing its screen) never receives any, so the link pings
// the server to detect whether it is still reachable. The answers have no
// other use.

Bulk_Link :: struct {
	using link: Link,
	// The time at which to try again after a refusal or a failure.
	retry_at:   time.Tick,
	last_ping:  time.Tick,
}

// How often the bulk link pings the server to check that it still answers.
BULK_PING :: 1 * time.Second
// How long to wait before asking again after the server refused the bulk
// link, because the main link may not be ready yet.
BULK_RETRY :: 1 * time.Second
// The maximum number of packets read from the bulk link per loop iteration.
BULK_RECV_MAX :: 64

// bulk_step opens the bulk link when it is time to do so and keeps it running.
bulk_step :: proc(c: ^Voice_Client) {
	b := &c.bulk
	if !c.has_current || !c.has_instance || c.restart {
		return
	}
	if !b.transport.open {
		if b.retry_at != {} && time.tick_diff(time.tick_now(), b.retry_at) > 0 {
			return
		}
		if !transport_open(&b.transport, c.server_addr, c.slot, bulk = true) {
			b.retry_at = time.tick_add(time.tick_now(), BULK_RETRY)
			return
		}
	}
	transport_revive(&b.transport)
	bulk_handshake(c)
	if b.has_current && time.tick_since(b.last_ping) >= BULK_PING {
		buf: [proto.PING_SIZE]u8
		link_send(&b.link, proto.encode_ping(&buf, .Ping, 0))
		b.last_ping = time.tick_now()
	}
}

// bulk_handshake is drive_handshake for the bulk link.
@(private = "file")
bulk_handshake :: proc(c: ^Voice_Client) {
	b := &c.bulk
	if b.has_current && time.tick_since(b.current.created) > proto.REJECT_AFTER {
		log.warn("bulk link expired without a successful rekey")
		proto.session_reset(&b.current)
		b.has_current = false
	}
	ini := &b.handshake
	if ini.state != .Idle && time.tick_since(ini.started) > proto.HANDSHAKE_TIMEOUT {
		log.debug("bulk link handshake timed out, retrying")
		abandon_handshake(&b.link)
	}
	switch ini.state {
	case .Idle:
		silent := b.has_current && time.tick_since(b.last_recv) > proto.SERVER_SILENT
		if b.has_current && time.tick_since(b.current.created) <= proto.REKEY_AFTER && !silent {
			return
		}
		if b.retry_at != {} && time.tick_diff(time.tick_now(), b.retry_at) > 0 {
			return
		}
		if silent {
			log.debug("nothing on the bulk link for a while, connecting it again")
		}
		packet, ok := proto.initiator_start(ini, &c.key)
		if !ok {
			return
		}
		ini.last_sent = time.tick_now()
		transport_send(&b.transport, packet)
	case .Sent_Init, .Sent_Finish:
		if time.tick_since(ini.last_sent) >= proto.HANDSHAKE_RETRY {
			ini.last_sent = time.tick_now()
			transport_send(&b.transport, proto.initiator_packet(ini))
		}
	}
}

// bulk_receive handles packets that arrived over the bulk link, up to
// BULK_RECV_MAX packets at a time.
bulk_receive :: proc(c: ^Voice_Client) {
	b := &c.bulk
	if !b.transport.open {
		return
	}
	recv_buf: [proto.MAX_PACKET_SIZE]byte
	for _ in 0 ..< BULK_RECV_MAX {
		packet := transport_recv(&b.transport, recv_buf[:]) or_break
		if !common.simulate_loss() {
			handle_bulk_packet(c, packet)
		}
	}
}

@(private = "file")
handle_bulk_packet :: proc(c: ^Voice_Client, packet: []byte) {
	b := &c.bulk
	#partial switch proto.packet_type(packet) {
	case .Handshake_Resp:
		server_key, result := proto.initiator_read_resp(&b.handshake, packet)
		if result != .Ok {
			return
		}
		// The main link has already verified the server, so this link must reach the same one.
		if server_key != c.server_key {
			log.warn("the bulk link reached a server with another key")
			bulk_retry_later(b)
			return
		}
		hello_buf: [proto.HELLO_MAX_SIZE]u8
		hello := proto.encode_hello(&hello_buf, c.conn_id, c.password, .Bulk)
		finish, ok := proto.initiator_finish(&b.handshake, &b.pending, hello)
		if !ok {
			return
		}
		b.has_pending = true
		b.handshake.last_sent = time.tick_now()
		transport_send(&b.transport, finish)

	case .Data:
		pt_buf: [proto.MAX_PACKET_SIZE]byte
		pt, pending, ok := link_open(&b.link, packet, pt_buf[:])
		if !ok {
			return
		}
		kind, kind_ok := proto.message_kind(pt)
		if pending {
			// The Welcome must belong to the connection of the main link.
			if kind_ok && kind == .Refused {
				log.debugf("the bulk link was refused: %v", proto.decode_refused(pt))
				bulk_retry_later(b)
				return
			}
			if !kind_ok || kind != .Welcome {
				return
			}
			if instance, _ := proto.decode_welcome(pt); instance != c.instance {
				bulk_retry_later(b)
				return
			}
			if link_promote(&b.link) {
				log.debug("bulk link up")
			}
			b.retry_at = {}
		}
		if !kind_ok {
			return
		}
		#partial switch kind {
		case .Welcome, .Pong:
		// Handshake and ping answers only matter because they arrived.
		case:
			handle_message(c, kind, pt)
		}
	}
}

@(private = "file")
bulk_retry_later :: proc(b: ^Bulk_Link) {
	abandon_handshake(&b.link)
	b.retry_at = time.tick_add(time.tick_now(), BULK_RETRY)
}

// bulk_restart forgets the bulk link's sessions when the connection is a new
// one, because the server dropped them together with the old connection. The
// transport stays open for the next handshake.
bulk_restart :: proc(c: ^Voice_Client) {
	link_reset(&c.bulk.link)
	c.bulk.retry_at = {}
}

bulk_close :: proc(c: ^Voice_Client) {
	transport_close(&c.bulk.transport)
	bulk_restart(c)
}

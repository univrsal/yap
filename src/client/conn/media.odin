package conn

import "core:fmt"
import "core:strings"
import "core:time"

import "client:platform"
import "common:."
import "common:proto"
import log "common:wlog"

// The media link (proto.Link.Media, server/media.odin) is a third transport to
// the server, using a port of its own, for screen sharing from the desktop with
// the yap_video library. The server serves it on a separate thread, so a shared
// screen's video never queues in its main loop, and our video stays away from
// the traffic on the other links. Video shared on this link only reaches
// viewers that are on it too, so the browser has one as well, through the
// relay (server/relay.odin).
//
// The link is opened once we are logged in (auth state Done), the server has
// announced its media port (Server_Info), and there is a library available to
// share or watch with. Like the bulk link, it performs a handshake of its own
// whose hello names the connection. All of screen sharing goes over it (see
// video.odin): our video and Watch leases, the video we watch, and the keyframe
// requests for ours. Without the link, there is no screen sharing.

Media_Link :: struct {
	using link: Link,
	port:       u16, // the server's media port, once it has announced it
	retry_at:   time.Tick,
	last_ping:  time.Tick,
	refusals:   int, // consecutive refusals; the link is given up on after MEDIA_GIVE_UP
	timeouts:   int, // consecutive handshakes without an answer, warned about at MEDIA_WARN_SILENT
}

// How often the media link pings the server to check that it still answers.
@(private = "file")
MEDIA_PING :: 1 * time.Second
@(private = "file")
MEDIA_RETRY :: 2 * time.Second
// The number of refusals after which the media link is not tried again for this
// connection, because something is wrong that retrying won't fix (for example
// a password that the main link accepted but this link doesn't).
@(private = "file")
MEDIA_GIVE_UP :: 5
// The number of unanswered handshakes after which the media port is said to be
// unreachable. The main link works by then, so it is usually a UDP port that
// isn't forwarded (for example not published by a container, or published as
// another port than the one the server announces).
@(private = "file")
MEDIA_WARN_SILENT :: 3
// The maximum number of packets read from the media link per loop iteration.
@(private = "file")
MEDIA_RECV_MAX :: 256

// media_step opens the media link when it is time to do so and keeps it running.
media_step :: proc(c: ^Voice_Client) {
	m := &c.media
	port := c.rpc.server.media_port
	if !c.has_current || !c.has_instance || c.restart || c.auth.state != .Done || port == 0 {
		return
	}
	if m.refusals >= MEDIA_GIVE_UP || !video_can_watch() {
		return
	}
	if m.transport.open && m.port != port {
		// The server moved its media port (for example it restarted with another config).
		media_close(c)
	}
	if !m.transport.open {
		if m.retry_at != {} && time.tick_diff(time.tick_now(), m.retry_at) > 0 {
			return
		}
		// The relay knows the media port, so the address is only used for its log.
		addr := c.server_addr when platform.WEB else with_port(c.server_addr, port)
		if !transport_open(&m.transport, addr, c.slot, bulk = true, media = true) {
			m.retry_at = time.tick_add(time.tick_now(), MEDIA_RETRY)
			return
		}
		m.port = port
		log.debugf("media link to %s", addr)
	}
	media_handshake(c)
	if m.has_current && time.tick_since(m.last_ping) >= MEDIA_PING {
		buf: [proto.PING_SIZE]u8
		link_send(&m.link, proto.encode_ping(&buf, .Ping, 0))
		m.last_ping = time.tick_now()
	}
}

// with_port returns `addr` (host:port, as made by with_default_port) with
// another port, allocated in the temp allocator.
@(private = "file")
with_port :: proc(addr: string, port: u16) -> string {
	host := addr
	if strings.has_prefix(addr, "[") {
		if end := strings.index_byte(addr, ']'); end >= 0 {
			host = addr[:end + 1]
		}
	} else if colon := strings.last_index_byte(addr, ':'); colon >= 0 {
		host = addr[:colon]
	}
	return fmt.tprintf("%s:%d", host, port)
}

// media_handshake is drive_handshake for the media link.
@(private = "file")
media_handshake :: proc(c: ^Voice_Client) {
	m := &c.media
	if m.has_current && time.tick_since(m.current.created) > proto.REJECT_AFTER {
		log.warn("media link expired without a successful rekey")
		proto.session_reset(&m.current)
		m.has_current = false
	}
	ini := &m.handshake
	if ini.state != .Idle && time.tick_since(ini.started) > proto.HANDSHAKE_TIMEOUT {
		log.debug("media link handshake timed out, retrying")
		m.timeouts += 1
		if m.timeouts == MEDIA_WARN_SILENT {
			when platform.WEB {
				log.warn(
					"the relay doesn't answer on the media link, so screen sharing is unavailable",
				)
			} else {
				log.warnf(
					"no answer from the media link at %s, so screen sharing is unavailable: is udp port %d reachable?",
					with_port(c.server_addr, m.port),
					m.port,
				)
			}
		}
		abandon_handshake(&m.link)
		m.retry_at = time.tick_add(time.tick_now(), MEDIA_RETRY)
	}
	switch ini.state {
	case .Idle:
		silent := m.has_current && time.tick_since(m.last_recv) > proto.SERVER_SILENT
		if m.has_current && time.tick_since(m.current.created) <= proto.REKEY_AFTER && !silent {
			return
		}
		if m.retry_at != {} && time.tick_diff(time.tick_now(), m.retry_at) > 0 {
			return
		}
		if silent {
			log.debug("nothing on the media link for a while, connecting it again")
		}
		packet, ok := proto.initiator_start(ini, &c.key)
		if !ok {
			return
		}
		ini.last_sent = time.tick_now()
		transport_send(&m.transport, packet)
	case .Sent_Init, .Sent_Finish:
		if time.tick_since(ini.last_sent) >= proto.HANDSHAKE_RETRY {
			ini.last_sent = time.tick_now()
			transport_send(&m.transport, proto.initiator_packet(ini))
		}
	}
}

// media_receive handles packets that arrived over the media link.
media_receive :: proc(c: ^Voice_Client) {
	m := &c.media
	if !m.transport.open {
		return
	}
	recv_buf: [proto.MAX_PACKET_SIZE]byte
	for _ in 0 ..< MEDIA_RECV_MAX {
		packet := transport_recv(&m.transport, recv_buf[:]) or_break
		if !common.simulate_loss() {
			handle_media_packet(c, packet)
		}
	}
}

@(private = "file")
handle_media_packet :: proc(c: ^Voice_Client, packet: []byte) {
	m := &c.media
	#partial switch proto.packet_type(packet) {
	case .Handshake_Cookie:
		if proto.initiator_read_cookie(&m.handshake, packet) {
			m.handshake.last_sent = time.tick_now()
			transport_send(&m.transport, proto.initiator_packet(&m.handshake))
		}
	case .Handshake_Resp:
		server_key, result := proto.initiator_read_resp(&m.handshake, packet)
		if result != .Ok {
			return
		}
		if server_key != c.server_key {
			log.warn("the media link reached a server with another key")
			media_retry_later(m)
			return
		}
		hello_buf: [proto.HELLO_MAX_SIZE]u8
		hello := proto.encode_hello(&hello_buf, c.conn_id, c.password, .Media)
		finish, ok := proto.initiator_finish(&m.handshake, &m.pending, hello)
		if !ok {
			return
		}
		m.has_pending = true
		m.handshake.last_sent = time.tick_now()
		transport_send(&m.transport, finish)

	case .Data:
		pt_buf: [proto.MAX_PACKET_SIZE]byte
		pt, pending, ok := link_open(&m.link, packet, pt_buf[:])
		if !ok {
			return
		}
		kind, kind_ok := proto.message_kind(pt)
		if pending {
			if kind_ok && kind == .Refused {
				m.refusals += 1
				log.debugf("the media link was refused: %v", proto.decode_refused(pt))
				if m.refusals == MEDIA_GIVE_UP {
					log.warn(
						"the server keeps refusing the media link, so screen sharing is unavailable",
					)
				}
				media_retry_later(m)
				return
			}
			if !kind_ok || kind != .Welcome {
				return
			}
			if instance, _ := proto.decode_welcome(pt); instance != c.instance {
				media_retry_later(m)
				return
			}
			if link_promote(&m.link) {
				log.info("media link up")
			}
			m.retry_at = {}
			m.refusals = 0
			m.timeouts = 0
		}
		if !kind_ok {
			return
		}
		#partial switch kind {
		case .Video:
			handle_video(c, pt)
		case .Keyframe:
			if stream, key_ok := proto.decode_keyframe(pt); key_ok {
				video_keyframe_requested(c, stream)
			}
		case .Report:
			if s, stream, report_ok := proto.decode_report_down(pt); report_ok {
				video_reports(c, stream, s)
			}
		case .Demand:
			if d, demand_ok := proto.decode_demand(pt); demand_ok {
				video_demand(c, d)
			}
		case .Welcome, .Pong:
		// Handshake and ping answers only matter because they arrived.
		}
	}
}

@(private = "file")
media_retry_later :: proc(m: ^Media_Link) {
	abandon_handshake(&m.link)
	m.retry_at = time.tick_add(time.tick_now(), MEDIA_RETRY)
}

// media_restart forgets the media link's sessions when the connection is a new
// one, because the server dropped them together with the old connection. The
// transport stays open for the next handshake.
media_restart :: proc(c: ^Voice_Client) {
	link_reset(&c.media.link)
	c.media.retry_at = {}
	c.media.refusals = 0
	c.media.timeouts = 0
}

media_close :: proc(c: ^Voice_Client) {
	transport_close(&c.media.transport)
	media_restart(c)
}

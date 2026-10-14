package conn

import "core:fmt"
import "core:strings"
import "core:time"

import "client:platform"
import "common:."
import "common:proto"
import log "common:wlog"

/*
The media link (proto.Link.Media, server/media.odin): a third transport
to the server, to a port of its own, for screen sharing from the desktop
with the yap_video library. The server serves it on a thread of its
own, so a shared screen's video never queues in its main loop, and our
video goes nowhere near what's on the other links. Video shared on it
only reaches viewers on it, so the browser has one too, through the
relay (server/relay.odin).

It's opened once we are logged in (auth state Done), the server has named its
media port (Server_Info), and there's a library to share or watch with;
like the bulk link, with a handshake of its own whose hello names the
connection. Our video goes over it once it's up, and Watch leases go
over it as well as the main link (video.odin); the video we watch and
the keyframe requests for ours come back on it.
*/

Media_Link :: struct {
	using link: Link,
	port:       u16, // the server's media port, once it has said
	retry_at:   time.Tick,
	last_ping:  time.Tick,
	refusals:   int, // in a row; it's given up on after MEDIA_GIVE_UP
}

// How often the media link pings the server, to hear back from it.
@(private = "file")
MEDIA_PING :: 1 * time.Second
@(private = "file")
MEDIA_RETRY :: 2 * time.Second
// Refusals after which the media link isn't tried again for this
// connection: something's wrong that trying won't fix (a password the
// main link got past but this doesn't, say).
@(private = "file")
MEDIA_GIVE_UP :: 5
// The most packets taken off the media link in a turn of the loop.
@(private = "file")
MEDIA_RECV_MAX :: 256

// media_step opens the media link when it's time, and keeps it going.
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
		// The server moved it (restarted with another config).
		media_close(c)
	}
	if !m.transport.open {
		if m.retry_at != {} && time.tick_diff(time.tick_now(), m.retry_at) > 0 {
			return
		}
		// The relay knows the media port; the address is only for its log.
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

// with_port is `addr` (host:port, as with_default_port makes it) with
// another port, in the temp allocator.
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

// media_receive handles what has come over the media link.
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
						"the server keeps refusing the media link; video goes over the bulk link",
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
		}
		if !kind_ok {
			return
		}
		#partial switch kind {
		case .Video:
			handle_video(c, pt)
		case .Keyframe:
			video_keyframe_requested(c)
		case .Report:
			if s, report_ok := proto.decode_report_down(pt); report_ok {
				video_reports(c, s)
			}
		case .Welcome, .Pong:
		// Answers to the handshake and the pings: that they came is all.
		}
	}
}

@(private = "file")
media_retry_later :: proc(m: ^Media_Link) {
	abandon_handshake(&m.link)
	m.retry_at = time.tick_add(time.tick_now(), MEDIA_RETRY)
}

/*
media_restart forgets the media link's sessions when the connection is
a new one: the server dropped them with the old one. The transport
stays open for the next handshake.
*/
media_restart :: proc(c: ^Voice_Client) {
	link_reset(&c.media.link)
	c.media.retry_at = {}
	c.media.refusals = 0
}

media_close :: proc(c: ^Voice_Client) {
	transport_close(&c.media.transport)
	media_restart(c)
}

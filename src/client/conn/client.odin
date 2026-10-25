package conn

import log "common:wlog"
import "core:crypto"
import "core:crypto/ecdh"
import "core:encoding/endian"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"

import "client:audio"
import "common:."
import "common:proto"

// Link is one of the connection's two ways to the server (proto.Link). It
// consists of a transport and the sessions over it. The main link is the
// connection itself. The bulk link joins it once it is established and carries
// the heavy traffic (see bulk.odin).
Link :: struct {
	using sessions: proto.Initiator_Link,
	transport:      Transport,
	last_sent:      time.Tick,
}

// Server_Conn is everything we have going with one server: its links, our
// account there, and the channels, conversations, voice and video of it.
// client_step drives it: on the session's network thread (net_native.odin), or
// from the main loop on the web and when headless.
Server_Conn :: struct {
	// The main link: the connection itself.
	using link:      Link,
	// The bulk link, used for heavy messages (proto.HEAVY_KINDS, see bulk.odin).
	bulk:            Bulk_Link,
	// The media link, used for screen sharing on the desktop (see media.odin).
	media:           Media_Link,
	server_addr:     string, // as typed by the user; this is the key in known_servers
	// The first of this connection's three WebSocket slots in a web build
	// (see transport_web.odin). The owner sets it before client_open.
	slot:            i32,
	known_servers:   string,
	password:        string, // sent in every hello; empty if there is none
	key:             ecdh.Private_Key,
	my_key:          [proto.KEY_SIZE]u8,
	// The server's key, once the handshake has revealed it. It is used to tell
	// the accounts of this server apart from those of another server (for the
	// per-user settings).
	server_key:      [proto.KEY_SIZE]u8,
	// Which connection this is (see the hello and Welcome in proto/hello.odin).
	// conn_id is our identifier, which is the same in every handshake. instance
	// is the server's identifier for the connection, which changes whenever the
	// server treats it as a new connection.
	conn_id:         u64,
	instance:        u64,
	has_instance:    bool,
	// We have given up on the connection and are handshaking for a new one
	// (see connection_restart).
	restart:         bool,
	// The server is unreachable (see connection_lost). A new connection is tried
	// every RECONNECT_EVERY, with the next attempt at retry_at, until one
	// succeeds.
	lost:            bool,
	retry_at:        time.Tick,
	stream:          proto.Stream, // requests and events (see stream.odin and rpc.odin)
	rpc:             Rpc_Client,
	auth:            Auth_Client, // our account and the others (see auth.odin)
	voice:           audio.Voice, // set up by the owner before client_open
	channels:        Channel_Client, // who is here (see presence.odin)
	convs:           Conv_Client, // our channels (see convs.odin)
	msgs:            Message_Client, // messages (see messages.odin)
	search:          Search_Client, // searching them (see search.odin)
	blobs:           Blob_Client, // pictures (see blobs.odin)
	buddies:         Buddy_Client, // our buddies, and when people were last online (see buddies.odin)
	emoji:           Emoji_Client, // the server's own emoji (see emoji.odin)
	profiles:        Profile_Client, // statuses, pictures and settings (see profiles.odin)
	call:            Call_Client, // the call we're in (see calls.odin)
	// Our voice is in a room or a call on another server (see loop_sounds).
	voice_elsewhere: bool,
	// The connection going bad while in voice (see sounds.odin).
	trouble:         Trouble,
	video:           Video_Client,
	ping:            Ping_Tracker,
	files:           File_Client, // files in DMs (see files.odin)
	attach:          Attach_Client, // files sent with messages (see attachments.odin)
	commands:        Command_Queue,
	status:          Status,
	// Shared with the UI, if there is one. nil in headless mode.
	view:            ^View,

	// Per-second stats, keyed by speaker id.
	last_stats:      time.Tick,
	// When client_step last ran, used to detect that the computer was asleep
	// rather than the loop running normally.
	last_step:       time.Tick,
}

// client_open loads our key and opens the transport. It doesn't wait for the
// server, because the handshake happens in client_step. `password` is the
// server's password, if it has one. The credentials for logging in to an
// account are given with auth_credentials or a Login_Command.
client_open :: proc(
	c: ^Server_Conn,
	key_path, typed_addr, known_servers: string,
	password := "",
) -> bool {
	server_addr := with_default_port(typed_addr)
	c.server_addr = strings.clone(server_addr)
	c.known_servers = strings.clone(known_servers)
	c.password = strings.clone(password)

	if !common.load_or_create_private_key(key_path, &c.key) {
		publish_status(c, .Failed, fmt.tprintf("Could not load the key file %s.", key_path))
		return false
	}
	ecdh.private_key_public_bytes(&c.key, c.my_key[:])
	log.infof("my public key: %s", common.public_key_hex(&c.key))
	crypto.rand_bytes(([^]byte)(&c.conn_id)[:size_of(c.conn_id)])
	publish_status(c, .Connecting)

	if !transport_open(&c.transport, server_addr, c.slot) {
		// For example we are offline, so the name does not resolve. It is tried
		// again with the handshake.
		connection_lost(
			c,
			fmt.tprintf(
				"Could not reach %s. The address must have the form host:port.",
				server_addr,
			),
		)
	}
	c.last_stats = time.tick_now()
	c.last_recv = time.tick_now()
	c.last_step = c.last_recv
	return true
}

// client_close says goodbye to the server (if connected) and releases everything
// that client_open and the connection acquired.
client_close :: proc(c: ^Server_Conn) {
	if c.has_current {
		// The transport is unreliable, so send a few. Otherwise the server times us out.
		leave := [1]byte{u8(proto.Message_Kind.Leave)}
		for _ in 0 ..< 3 {
			send_data(c, leave[:])
		}
	}
	transport_close(&c.transport)
	proto.link_reset(&c.link)
	bulk_close(c)
	media_close(c)
	ecdh.private_key_clear(&c.key)

	delete(c.server_addr)
	delete(c.known_servers)
	delete(c.password)
	commands_destroy(&c.commands)
	messages_destroy(c)
	search_destroy(c)
	profiles_destroy(c)
	blobs_destroy(c)
	video_destroy(c)
	buddies_destroy(c)
	emoji_destroy(c)
	files_destroy(c)
	attachments_destroy(c)
	stream_destroy(c)
	rpc_destroy(c)
	auth_destroy(c)
	convs_destroy(c)
}

// client_step runs one iteration of the network loop and waits up to a couple
// of milliseconds for a packet. It returns false once the connection has failed
// for good.
client_step :: proc(c: ^Server_Conn) -> bool {
	free_all(context.temp_allocator)

	check_alive(c)
	// An unreachable server is only retried every RECONNECT_EVERY.
	if !c.lost || c.handshake.state != .Idle {
		transport_revive(&c.transport)
	}
	drive_handshake(c)
	process_commands(c)
	drive_sound(c)
	drive_outbox(c)
	drive_pictures(c)
	blobs_step(c)
	files_step(c)
	attachments_step(c)
	rpc_step(c)
	convs_step(c)
	stream_step(c)

	if c.has_current {
		voice_step(c)
		ping_step(c)
		if time.tick_since(c.last_sent) >= proto.KEEPALIVE_AFTER {
			send_data(c, nil)
		}
	}
	// This comes after the voice, which it must not hold up.
	video_step(c)
	bulk_step(c)
	media_step(c)

	// The main link comes first, because what is on it cannot wait.
	recv_buf: [proto.MAX_PACKET_SIZE]byte
	if packet, ok := transport_recv(&c.transport, recv_buf[:]); ok {
		if !common.simulate_loss() && !handle_server_packet(c, packet) {
			// The server refused us. Trying again won't help unless the user asks.
			c.lost = false
			publish_retry(c)
			return false
		}
	}
	bulk_receive(c)
	media_receive(c)

	log_stats(c)
	return true
}

// check_alive gives up on the connection once nothing has come from the server
// for CONNECTION_LOST. By then it is not coming back soon, and it is better to
// tell the user than to leave them looking at a connection that never recovers.
// Until then, handshaking again (see drive_handshake) carries on, so a server
// that restarts in the meantime is picked up without anyone noticing. After
// that, a new connection is tried every RECONNECT_EVERY for as long as the
// server stays unreachable.
CONNECTION_LOST :: 30 * time.Second
RECONNECT_EVERY :: 30 * time.Second
// If the loop did not run for this long, the computer was asleep (or the tab
// was in the background), so the silence is not the server's fault.
LOOP_STALLED :: 5 * time.Second

check_alive :: proc(c: ^Server_Conn) {
	now := time.tick_now()
	if time.tick_diff(c.last_step, now) > LOOP_STALLED {
		c.last_recv = now
	}
	c.last_step = now
	if !c.lost && transport_never_opened(&c.transport) {
		// A browser doesn't tell a page why, so this says what it usually is.
		log.warnf(
			"could not open a WebSocket to %s, trying again every %v",
			c.server_addr,
			RECONNECT_EVERY,
		)
		connection_lost(
			c,
			"Could not connect. Check the address, and that the server allows web clients from this site.",
		)
		return
	}
	if c.lost || time.tick_diff(c.last_recv, now) <= CONNECTION_LOST {
		return
	}
	log.warnf(
		"nothing from %s for %v, trying again every %v",
		c.server_addr,
		CONNECTION_LOST,
		RECONNECT_EVERY,
	)
	why := "Lost the connection to %s." if c.has_instance else "Could not connect to %s."
	connection_lost(c, fmt.tprintf(why, c.server_addr))
}

// connection_lost drops the main link, publishes the reason, and makes
// drive_handshake try for a new connection every RECONNECT_EVERY.
connection_lost :: proc(c: ^Server_Conn, why: string) {
	proto.link_reset(&c.link)
	c.lost = true
	trouble_end(c)
	c.retry_at = time.tick_add(time.tick_now(), RECONNECT_EVERY)
	publish_status(c, .Failed, why)
}

// drive_handshake starts a handshake when there is no usable session, when the
// current session is due for rekeying, or when the server has gone quiet on it
// (it may have restarted and no longer know our session). It also retransmits
// lost handshake packets and starts over if a handshake stalls.
drive_handshake :: proc(c: ^Server_Conn) {
	now := time.tick_now()
	if c.handshake.state == .Idle && c.lost {
		if time.tick_diff(now, c.retry_at) > 0 {
			return
		}
		c.retry_at = time.tick_add(now, RECONNECT_EVERY)
		if !c.transport.open && !transport_open(&c.transport, c.server_addr, c.slot) {
			publish_retry(c)
			return
		}
		log.infof("trying %s again", c.server_addr)
		transport_revive(&c.transport)
	}
	s := proto.link_step(&c.link, &c.key, now, restart = c.restart)
	if s.expired {
		log.warn("session expired without a successful rekey")
	}
	if s.stalled {
		log.warn("handshake timed out, retrying")
		publish_retry(c)
	}
	if s.silent {
		log.warnf("nothing from %s for a while, connecting again", c.server_addr)
	}
	if s.packet != nil {
		if !s.started {
			log.debugf("resending %v", proto.packet_type(s.packet))
		}
		transport_send(&c.transport, s.packet)
		if s.started && c.lost {
			publish_retry(c)
		}
	}
}

// handle_server_packet returns false if the connection must be aborted.
handle_server_packet :: proc(c: ^Server_Conn, packet: []byte) -> bool {
	#partial switch proto.packet_type(packet) {
	case .Handshake_Cookie:
		// The server is busy and wants to know that we can be reached
		// here: the Init goes again, with the cookie.
		if resend, ok := proto.link_cookie(&c.link, packet); ok {
			transport_send(&c.transport, resend)
		}
	case .Handshake_Resp:
		server_key, resp_ok := proto.link_resp(&c.link, packet)
		if !resp_ok {
			return true // ignored, or failed and will be retried later
		}
		if trusted, why := verify_server_key(c, server_key); !trusted {
			proto.link_abandon(&c.link)
			publish_status(c, .Failed, why)
			return false
		}
		// Only now that the server's identity is verified do we send ours, together
		// with the server's password in the (encrypted) hello.
		hello_buf: [proto.HELLO_MAX_SIZE]u8
		hello := proto.encode_hello(&hello_buf, c.conn_id, c.password)
		finish, ok := proto.link_finish(&c.link, hello)
		if !ok {
			return true
		}
		transport_send(&c.transport, finish)

	case .Data:
		pt_buf: [proto.MAX_PACKET_SIZE]byte
		pt, pending, ok := proto.link_open(&c.link, packet, pt_buf[:])
		if !ok {
			return true
		}
		kind, kind_ok := proto.message_kind(pt)
		if pending {
			// The server's answer to our hello is either the Welcome or the reason
			// why it refuses us. Nothing else counts until one of them arrives,
			// because the Welcome says which connection everything else belongs to.
			if kind_ok && kind == .Refused {
				proto.link_abandon(&c.link)
				publish_status(c, .Failed, refusal_text(c, proto.decode_refused(pt)))
				return false
			}
			if !kind_ok || kind != .Welcome {
				return true
			}
			promote_pending(c)
		}
		if !kind_ok {
			return true // a keepalive or a malformed message
		}
		if kind == .Welcome {
			handle_welcome(c, pt)
		} else {
			handle_message(c, kind, pt)
		}
	}
	return true
}

// handle_message handles a message from the server, from either link.
handle_message :: proc(c: ^Server_Conn, kind: proto.Message_Kind, pt: []byte) {
	#partial switch kind {
	case .Stream:
		handle_stream(c, pt)
	case .Stream_Ack:
		handle_stream_ack(c, pt)
	case .Voice:
		if len(pt) >= proto.VOICE_DOWN_HEADER_SIZE && in_room(c) {
			speaker := proto.User_Num(endian.unchecked_get_u32le(pt[1:]))
			seq := endian.unchecked_get_u32le(pt[5:])
			publish_voice(c, speaker)
			audio.voice_receive(&c.voice, speaker, seq, pt[proto.VOICE_DOWN_HEADER_SIZE:])
		}
	case .State:
		handle_state_message(c, pt)
	case .Typing:
		handle_typing(c, pt)
	case .Blob_Chunk:
		handle_blob_chunk(c, pt)
	case .Blob_Need:
		handle_blob_need(c, pt)
	case .Pong:
		handle_pong(c, pt)
	case .File_Accept:
		handle_file_accept(c, pt)
	case .File_Chunk:
		handle_file_chunk(c, pt)
	case .File_Ack:
		handle_file_ack(c, pt)
	case .File_Cancel:
		handle_file_cancel(c, pt)
	case .Upload_Ack:
		handle_upload_ack(c, pt)
	case .Download_Chunk:
		handle_download_chunk(c, pt)
	case .Transfer_Cancel:
		handle_transfer_cancel(c, pt)
	}
}

// The server has confirmed the pending session, so start sending on it.
promote_pending :: proc(c: ^Server_Conn) {
	if !proto.link_promote(&c.link) {
		log.debugf("rekeyed (session %08x)", c.current.local_idx)
	} else {
		c.last_stats = time.tick_now()
		log.infof("connected to %s", c.server_addr)
		c.lost = false
		publish_status(c, .Connected)
	}
}

// handle_welcome handles the server's answer to our hello (see
// proto/hello.odin). After a rekey the answer names the connection we already
// have, and nothing changes. Any other answer means the server has made a new
// connection for us, either because this is our first handshake, or the server
// restarted, or it had given up on us. Everything we knew about the old
// connection is then void.
handle_welcome :: proc(c: ^Server_Conn, pt: []byte) {
	instance, logged_in := proto.decode_welcome(pt)
	if c.has_instance && instance == c.instance {
		return
	}
	if c.has_instance {
		log.infof("%s has started a new connection for us", c.server_addr)
	}
	c.instance, c.has_instance = instance, true

	// Nothing from the old connection may arrive anymore.
	if c.has_previous {
		proto.session_reset(&c.previous)
		c.has_previous = false
	}
	// Its bulk and media links are gone together with it.
	bulk_restart(c)
	media_restart(c)
	// This must happen before the list of who is here is forgotten, because it
	// holds the room our voice was in.
	convs_restart(c)
	channels_restart(c)
	messages_restart(c)
	calls_restart(c)
	stream_restart(c)
	c.restart = false
	server_info_ask(c)
	auth_restart(c, logged_in)
}

refusal_text :: proc(c: ^Server_Conn, reason: proto.Refusal) -> string {
	log.warnf("%s refused the connection: %v", c.server_addr, reason)
	#partial switch reason {
	case .Wrong_Password:
		if c.password == "" {
			return fmt.tprintf("%s requires a password.", c.server_addr)
		}
		return fmt.tprintf("The password for %s is wrong.", c.server_addr)
	case .Version:
		return fmt.tprintf("%s runs an incompatible version of yap.", c.server_addr)
	case .Already_Connected:
		return fmt.tprintf(
			"Another client is already connected to %s with this key. Close it and try again.",
			c.server_addr,
		)
	}
	return fmt.tprintf("%s refused the connection.", c.server_addr)
}

// verify_server_key implements trust on first use. It remembers the key the
// first time and refuses to continue if the key ever changes. A change is handed
// to the UI (see publish_key_change), which lets the user trust the new key once
// they know why it changed.
verify_server_key :: proc(
	c: ^Server_Conn,
	key: [proto.KEY_SIZE]byte,
) -> (
	trusted: bool,
	why: string,
) {
	trust, saved := check_server_key(c.known_servers, c.server_addr, key)
	if trust == .Known || trust == .New {
		c.server_key = key
		publish_server_key(c)
	}
	switch trust {
	case .Known:
		return true, ""

	case .New:
		if remember_server_key(c.known_servers, c.server_addr, key) {
			log.infof(
				"first connection to %s, trusting server key %s (saved to %s)",
				c.server_addr,
				common.key_hex(key),
				c.known_servers,
			)
		} else {
			log.warnf(
				"first connection to %s, trusting server key %s for now, but it could not be saved",
				c.server_addr,
				common.key_hex(key),
			)
		}
		return true, ""

	case .Unreadable:
		log.errorf(
			"could not read %s, so the key of %s can't be checked",
			c.known_servers,
			c.server_addr,
		)
		return false, fmt.tprintf(
			"The saved server keys (%s) could not be read, so the key of %s can't be checked.",
			c.known_servers,
			c.server_addr,
		)

	case .Mismatch:
		log.errorf(
			"the key of %s has changed! saved %s, received %s",
			c.server_addr,
			common.key_hex(saved),
			common.key_hex(key),
		)
		log.error("someone may be impersonating the server, or it got a new key")
		log.errorf(
			"if the change is expected, trust the new key on the connect screen, or remove the %s line from %s",
			c.server_addr,
			c.known_servers,
		)
		publish_key_change(c, saved, key)
		return false, fmt.tprintf(
			"The key of %s has changed, so the connection was refused.",
			c.server_addr,
		)
	}
	return false, ""
}

// send_data sends a message to the server. A heavy message (proto.HEAVY_KINDS)
// goes over the bulk link once that is available, and anything else goes over
// the main link.
send_data :: proc(c: ^Server_Conn, plaintext: []byte) -> bool {
	l := &c.link
	if c.bulk.has_current && proto.is_heavy(plaintext) {
		l = &c.bulk.link
	}
	return link_send(l, plaintext)
}

link_send :: proc(l: ^Link, plaintext: []byte) -> bool {
	pkt_buf: [proto.MAX_PACKET_SIZE]byte
	pkt, ok := proto.seal(&l.current, plaintext, pkt_buf[:])
	if !ok {
		return false
	}
	l.last_sent = time.tick_now()
	return transport_send(&l.transport, pkt)
}

log_stats :: proc(c: ^Server_Conn) {
	if !c.has_current || time.tick_since(c.last_stats) < time.Second {
		return
	}
	c.last_stats = time.tick_now()
	v := &c.voice
	defer {
		v.captured, v.gated, v.sent_frames, v.sent_bytes, v.concealed, v.dropouts =
			0, 0, 0, 0, 0, 0
		v.skipped = 0
		clear(&v.received)
		c.video.bytes_out, c.video.bytes_in = 0, 0
	}
	// The counters are only for this line, so without debug logging it isn't
	// built and they just start over.
	if context.logger.lowest_level > .Debug {
		return
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&b,
		"voice: captured %d, sent %d frames (%d B)",
		v.captured,
		v.sent_frames,
		v.sent_bytes,
	)
	if v.gated > 0 {
		fmt.sbprintf(&b, ", %d held by the gate", v.gated)
	}
	if v.skipped > 0 {
		fmt.sbprintf(
			&b,
			", %d ms of capture skipped",
			v.skipped * 1000 / (audio.SAMPLE_RATE * audio.CHANNELS),
		)
	}
	for speaker, n in v.received {
		fmt.sbprintf(&b, " | %08x: %d", speaker, n)
		if sp := v.speakers[speaker] or_else nil; sp != nil {
			fmt.sbprintf(
				&b,
				" (prefill %d ms, late up to %.0f ms)",
				audio.speaker_prefill(sp) * 1000 / (audio.SAMPLE_RATE * audio.CHANNELS),
				time.duration_milliseconds(sp.late_peak),
			)
			sp.late_peak = 0
		}
	}
	if v.concealed > 0 {
		fmt.sbprintf(&b, " | concealed %d", v.concealed)
	}
	if v.dropouts > 0 {
		fmt.sbprintf(&b, " | %d dropouts", v.dropouts)
	}
	// This should be about the application's sample rate while sharing.
	if received := sync.atomic_exchange(&v.app_received, 0); sync.atomic_load(&v.app_input) {
		fmt.sbprintf(&b, " | app audio %d frames in", received)
	}
	if underruns := sync.atomic_exchange(&v.underruns, 0); underruns > 0 {
		fmt.sbprintf(&b, " | %d output underruns", underruns)
	}
	if ping := connection_stats(&c.ping, c.last_stats); ping.quality != .Unknown {
		fmt.sbprintf(
			&b,
			" | ping %.1f ms (up to %.1f), loss %.1f%%",
			time.duration_milliseconds(ping.avg_rtt),
			time.duration_milliseconds(ping.max_rtt),
			connection_loss(ping),
		)
	}
	if c.video.bytes_out > 0 || c.video.bytes_in > 0 {
		fmt.sbprintf(
			&b,
			" | video %d kB out, %d kB in",
			c.video.bytes_out / 1000,
			c.video.bytes_in / 1000,
		)
		if d := video_log_counts(c); d[0] > 0 || d[2] > 0 {
			fmt.sbprintf(
				&b,
				" (%d fragments asked for again, %d frames saved, %d lost)",
				d[0],
				d[1],
				d[2],
			)
		}
	}
	log.debug(strings.to_string(b))
}

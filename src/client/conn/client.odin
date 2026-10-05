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

/*
Link is one of the connection's two ways to the server (proto.Link): a
transport and the sessions over it. The main link is the connection;
the bulk link joins it once it's there, for what's heavy (bulk.odin).
*/
Link :: struct {
	transport:    Transport,
	handshake:    proto.Initiator,
	// Keys derived, Finish sent, waiting for the server's first Data
	// packet before switching to it.
	pending:      proto.Session,
	has_pending:  bool,
	// The session used for sending.
	current:      proto.Session,
	has_current:  bool,
	// Kept after a rekey so packets already in flight on the old session
	// still decrypt.
	previous:     proto.Session,
	has_previous: bool,
	last_sent:    time.Tick,
	// When the server was last heard from, on any session.
	last_recv:    time.Tick,
}

Voice_Client :: struct {
	// The main link: the connection itself.
	using link:    Link,
	// The bulk link, for heavy messages (proto.HEAVY_KINDS, bulk.odin).
	bulk:          Bulk_Link,
	server_addr:   string, // as typed; the key in known_servers
	known_servers: string,
	password:      string, // sent in every hello; empty for none
	key:           ecdh.Private_Key,
	my_key:        [proto.KEY_SIZE]u8,
	// The server's key, once the handshake has shown it: what this
	// server's accounts are told apart from another's by (the per-user
	// settings).
	server_key:    [proto.KEY_SIZE]u8,
	// Which connection this is (see the hello and Welcome in
	// proto/names.odin): ours, the same in every handshake, and the
	// server's for it, which changes when the connection is new to it.
	conn_id:       u64,
	instance:      u64,
	has_instance:  bool,
	// We've given up on the connection and are handshaking for a new
	// one (connection_restart).
	restart:       bool,
	stream:        Stream_Client, // requests and events (stream.odin, rpc.odin)
	rpc:           Rpc_Client,
	auth:          Auth_Client, // our account and the others (auth.odin)
	voice:         audio.Voice, // set up by the owner before client_open
	channels:      Channel_Client, // who is here (channels.odin)
	convs:         Conv_Client, // our channels (convs.odin)
	msgs:          Message_Client, // messages (messages.odin)
	search:        Search_Client, // searching them (search.odin)
	blobs:         Blob_Client, // pictures (blobs.odin)
	buddies:       Buddy_Client, // our buddies, and when people were last here (buddies.odin)
	emoji:         Emoji_Client, // the server's own emoji (emoji.odin)
	profiles:      Profile_Client, // statuses, pictures, settings (profiles.odin)
	call:          Call_Client, // the call we're in (calls.odin)
	video:         Video_Client,
	ping:          Ping_Tracker,
	files:         File_Client, // files in DMs (files.odin)
	attach:        Attach_Client, // files sent with messages (attachments.odin)
	commands:      Command_Queue,
	status:        Status,
	// Shared with the UI, if there is one; nil in headless mode.
	view:          ^View,

	// Per-second stats, keyed by speaker id.
	last_stats:    time.Tick,
}

// client_open loads our key and opens the transport. It doesn't wait
// for the server: the handshake happens in client_step. `password` is
// the server's, if it has one; what to log in to an account with is
// given with auth_credentials or a Login_Command.
client_open :: proc(
	c: ^Voice_Client,
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

	if !transport_open(&c.transport, server_addr) {
		publish_status(
			c,
			.Failed,
			fmt.tprintf("Could not reach %s. Expected host:port.", server_addr),
		)
		return false
	}
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
	transport_close(&c.transport)
	link_reset(&c.link)
	bulk_close(c)
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

// client_step runs one iteration of the network loop, waiting up to a
// couple of milliseconds for a packet. It returns false once the
// connection has failed for good.
client_step :: proc(c: ^Voice_Client) -> bool {
	free_all(context.temp_allocator)

	drive_handshake(c)
	process_commands(c)
	drive_sound(c)
	drive_outbox(c)
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
	// After the voice, which it mustn't hold up.
	video_step(c)
	bulk_step(c)

	// The main link first: what's on it is what can't wait.
	recv_buf: [proto.MAX_PACKET_SIZE]byte
	if packet, ok := transport_recv(&c.transport, recv_buf[:]); ok {
		if !common.simulate_loss() && !handle_server_packet(c, packet) {
			return false
		}
	}
	bulk_receive(c)

	log_stats(c)
	return true
}

// drive_handshake starts a handshake when there's no usable session, the
// current one is due for rekeying, or the server has gone quiet on it (it
// may have restarted, and knows nothing of our session); retransmits lost
// handshake packets, and starts over if a handshake stalls.
drive_handshake :: proc(c: ^Voice_Client) {
	if c.has_current && time.tick_since(c.current.created) > proto.REJECT_AFTER {
		log.warn("session expired without a successful rekey")
		proto.session_reset(&c.current)
		c.has_current = false
	}

	ini := &c.handshake
	if ini.state != .Idle && time.tick_since(ini.started) > proto.HANDSHAKE_TIMEOUT {
		log.warn("handshake timed out, retrying")
		abandon_handshake(&c.link)
	}

	switch ini.state {
	case .Idle:
		silent := c.has_current && time.tick_since(c.last_recv) > proto.SERVER_SILENT
		if c.has_current &&
		   time.tick_since(c.current.created) <= proto.REKEY_AFTER &&
		   !silent &&
		   !c.restart {
			return
		}
		if silent {
			log.warnf("nothing from %s for a while, connecting again", c.server_addr)
		}
		packet, ok := proto.initiator_start(ini, &c.key)
		if !ok {
			log.error("failed to start handshake")
			return
		}
		ini.last_sent = time.tick_now()
		transport_send(&c.transport, packet)

	case .Sent_Init, .Sent_Finish:
		// Resending verbatim is fine: the server answers a repeated Init
		// with the same Resp, and a repeated Finish with a new keepalive.
		if time.tick_since(ini.last_sent) >= proto.HANDSHAKE_RETRY {
			log.debugf("resending %v", proto.packet_type(proto.initiator_packet(ini)))
			ini.last_sent = time.tick_now()
			transport_send(&c.transport, proto.initiator_packet(ini))
		}
	}
}

abandon_handshake :: proc(l: ^Link) {
	proto.initiator_reset(&l.handshake)
	if l.has_pending {
		proto.session_reset(&l.pending)
		l.has_pending = false
	}
}

// link_reset forgets a link's handshake and sessions; its transport
// stays as it is.
link_reset :: proc(l: ^Link) {
	proto.initiator_reset(&l.handshake)
	proto.session_reset(&l.pending)
	proto.session_reset(&l.current)
	proto.session_reset(&l.previous)
	l.has_pending, l.has_current, l.has_previous = false, false, false
}

/*
link_open opens a Data packet that came over the link, on whichever of
its sessions it's addressed to. `pending` says it was the pending one,
which the caller has to promote once it's sure of it.
*/
link_open :: proc(
	l: ^Link,
	packet: []byte,
	out: []byte,
) -> (
	pt: []byte,
	pending: bool,
	ok: bool,
) {
	idx := proto.receiver_index(packet)
	sess: ^proto.Session
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
	pt = proto.open(sess, packet, out) or_return
	l.last_recv = time.tick_now()
	return pt, sess == &l.pending, true
}

// link_promote switches the link over to its pending session, which the
// server has confirmed. It says whether this is the link's first.
link_promote :: proc(l: ^Link) -> (first: bool) {
	if l.has_previous {
		proto.session_reset(&l.previous)
	}
	l.previous, l.has_previous = l.current, l.has_current
	l.current, l.has_current = l.pending, true
	l.pending, l.has_pending = {}, false
	proto.initiator_reset(&l.handshake)
	return !l.has_previous
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
			abandon_handshake(&c.link)
			publish_status(
				c,
				.Failed,
				fmt.tprintf(
					"The key of %s has changed, so the connection was refused.",
					c.server_addr,
				),
			)
			return false
		}
		// Only now, with the server's identity checked, send ours, along
		// with the server's password in the (encrypted) hello.
		hello_buf: [proto.HELLO_MAX_SIZE]u8
		hello := proto.encode_hello(&hello_buf, c.conn_id, c.password)
		finish, ok := proto.initiator_finish(&c.handshake, &c.pending, hello)
		if !ok {
			return true
		}
		c.has_pending = true
		c.handshake.last_sent = time.tick_now()
		transport_send(&c.transport, finish)

	case .Data:
		pt_buf: [proto.MAX_PACKET_SIZE]byte
		pt, pending, ok := link_open(&c.link, packet, pt_buf[:])
		if !ok {
			return true
		}
		kind, kind_ok := proto.message_kind(pt)
		if pending {
			// The server's answer to our hello: the Welcome, or why it
			// won't have us. Nothing else counts until one of them comes:
			// the Welcome says what the rest belongs to.
			if kind_ok && kind == .Refused {
				abandon_handshake(&c.link)
				publish_status(c, .Failed, refusal_text(c, proto.decode_refused(pt)))
				return false
			}
			if !kind_ok || kind != .Welcome {
				return true
			}
			promote_pending(c)
		}
		if !kind_ok {
			return true // keepalive, or malformed
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
handle_message :: proc(c: ^Voice_Client, kind: proto.Message_Kind, pt: []byte) {
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
	case .Poke:
		handle_poke(c, pt)
	case .Video:
		handle_video(c, pt)
	case .Keyframe:
		video_keyframe_requested(c)
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

// The server has confirmed the pending session: start sending on it.
promote_pending :: proc(c: ^Voice_Client) {
	if !link_promote(&c.link) {
		log.debugf("rekeyed (session %08x)", c.current.local_idx)
	} else {
		c.last_stats = time.tick_now()
		log.infof("connected to %s", c.server_addr)
		publish_status(c, .Connected)
		audio.voice_notification_play(&c.voice, .Welcome)
	}
}

/*
handle_welcome takes the server's answer to our hello (proto/names.odin).
After a rekey it names the connection we already have, and nothing
changes. Any other means the server has made a new one for us - this is
our first handshake, or the server restarted, or it had given up on us -
so whatever we knew of the old one is void.
*/
handle_welcome :: proc(c: ^Voice_Client, pt: []byte) {
	instance, logged_in := proto.decode_welcome(pt)
	if c.has_instance && instance == c.instance {
		return
	}
	if c.has_instance {
		log.infof("%s has started a new connection for us", c.server_addr)
	}
	c.instance, c.has_instance = instance, true

	// Nothing from the old connection may arrive any more.
	if c.has_previous {
		proto.session_reset(&c.previous)
		c.has_previous = false
	}
	// Its bulk link went with it.
	bulk_restart(c)
	// Before who is here is forgotten: it's where our voice was.
	convs_restart(c)
	channels_restart(c)
	messages_restart(c)
	calls_restart(c)
	stream_restart(c)
	c.restart = false
	server_info_ask(c)
	auth_restart(c, logged_in)
}

refusal_text :: proc(c: ^Voice_Client, reason: proto.Refusal) -> string {
	log.warnf("%s refused the connection: %v", c.server_addr, reason)
	#partial switch reason {
	case .Wrong_Password:
		if c.password == "" {
			return fmt.tprintf("%s needs a password.", c.server_addr)
		}
		return fmt.tprintf("Wrong password for %s.", c.server_addr)
	case .Version:
		return fmt.tprintf("%s runs a different version of yap.", c.server_addr)
	}
	return fmt.tprintf("%s refused the connection.", c.server_addr)
}

// verify_server_key implements trust on first use: remember the key the
// first time, and refuse to continue if it ever changes. A change is
// handed to the UI (publish_key_change), which lets the user trust the
// new key once they know why it changed.
verify_server_key :: proc(c: ^Voice_Client, key: [proto.KEY_SIZE]byte) -> bool {
	trust, saved := check_server_key(c.known_servers, c.server_addr, key)
	if trust != .Mismatch {
		c.server_key = key
		publish_server_key(c)
	}
	switch trust {
	case .Known:
		return true

	case .New:
		if remember_server_key(c.known_servers, c.server_addr, key) {
			log.infof(
				"first connection to %s, trusting server key %s (saved to %s)",
				c.server_addr,
				key_hex(key),
				c.known_servers,
			)
		} else {
			log.warnf(
				"first connection to %s, trusting server key %s for now, but it could not be saved",
				c.server_addr,
				key_hex(key),
			)
		}
		return true

	case .Mismatch:
		log.errorf(
			"the key of %s has changed! saved %s, received %s",
			c.server_addr,
			key_hex(saved),
			key_hex(key),
		)
		log.error("someone may be impersonating the server, or it got a new key")
		log.errorf(
			"if the change is expected, trust the new key on the connect screen, or remove the %s line from %s",
			c.server_addr,
			c.known_servers,
		)
		publish_key_change(c, saved, key)
		return false
	}
	return false
}

// send_data sends a message to the server: a heavy one (proto.HEAVY_KINDS)
// on the bulk link once it's there, anything else on the main link.
send_data :: proc(c: ^Voice_Client, plaintext: []byte) -> bool {
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

log_stats :: proc(c: ^Voice_Client) {
	if !c.has_current || time.tick_since(c.last_stats) < time.Second {
		return
	}
	c.last_stats = time.tick_now()
	v := &c.voice
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
	// Should be about the application's sample rate while sharing.
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
		c.video.bytes_out, c.video.bytes_in = 0, 0
	}
	log.debug(strings.to_string(b))
	v.captured, v.gated, v.sent_frames, v.sent_bytes, v.concealed, v.dropouts = 0, 0, 0, 0, 0, 0
	v.skipped = 0
	clear(&v.received)
}

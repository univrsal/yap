package stress

import "core:crypto"
import "core:crypto/ecdh"
import "core:encoding/endian"
import "core:log"
import "core:net"
import "core:time"

import "common:."
import "common:proto"

/*
A bot is one connection to the server, as lean as it can be and still
look like a client to it: the handshake and its sessions, the stream for
requests and events, the snapshots acked, and voice. Only the main link:
the server sends heavy messages on it when there's no bulk link.

Its voice frames aren't Opus, which the server never looks into: they
carry when they were sent and are padded to the size of one. Every bot
runs in this one process, on one clock, so a frame that arrives says how
long the server took to pass it on.
*/

// Pacing the stream as the client does (client/conn/stream.odin).
STREAM_QUEUE_MAX :: 1024 * 1024
STREAM_RATE :: 256 * 1024
STREAM_BURST :: 32 * 1024
// How long a bot whose login was turned down waits to ask again.
LOGIN_RETRY :: time.Second
// What a voice frame carries before its padding: when it was sent.
FRAME_STAMP_SIZE :: 8
FRAME_TIME :: 20 * time.Millisecond

Bot_Phase :: enum {
	Waiting, // for its turn to connect
	Connecting, // handshaking for its first session
	Logging_In, // asked to, and waiting
	Syncing, // logged in; being told everything
	Ready, // and joined the voice room, if it's to
}

Bot :: struct {
	run:          ^Run,
	name:         string,
	key:          ecdh.Private_Key,
	sock:         net.UDP_Socket,
	phase:        Bot_Phase,
	connect_at:   time.Tick, // when it may start
	started:      time.Tick, // when it did
	login_at:     time.Tick, // when to ask to log in (again)
	conn_id:      u64,
	instance:     u64,
	has_instance: bool,

	// The sessions, as the client keeps them (client/conn/client.odin).
	handshake:    proto.Initiator,
	pending:      proto.Session,
	current:      proto.Session,
	previous:     proto.Session,
	has_pending:  bool,
	has_current:  bool,
	has_previous: bool,
	last_sent:    time.Tick,
	stream:       proto.Stream,
	tokens:       f32,
	stream_last:  time.Tick,
	last_id:      u32,
	asked:        map[u32]Asked,
	home:         proto.Conv_Id, // the channel everyone is in
	synced:       bool,
	wants_voice:  bool,
	talker:       bool,
	in_voice:     bool,
	join_asked:   bool,
	seq:          u32,
	next_frame:   time.Tick,
	// The snapshot being put together: its version and the chunks of it
	// that have come.
	state_ver:    u32,
	state_have:   u32,
	// The last sequence number heard from each speaker, for the gaps.
	heard:        map[proto.User_Num]u32,
}

// A request on its way, for its round trip.
Asked :: struct {
	op:   proto.Request_Op,
	sent: time.Tick,
}

bot_open :: proc(b: ^Bot, key_path: string) -> bool {
	if !common.load_or_create_private_key(key_path, &b.key) {
		log.errorf("%s: could not load or make the key %s", b.name, key_path)
		return false
	}
	sock, err := net.make_bound_udp_socket(net.IP4_Any, 0)
	if err != nil {
		log.errorf("%s: no socket: %v", b.name, err)
		return false
	}
	net.set_blocking(sock, false)
	// Room for what the fan-out of a busy room brings between two looks.
	net.set_option(sock, .Receive_Buffer_Size, 1024 * 1024)
	b.sock = sock
	crypto.rand_bytes(([^]byte)(&b.conn_id)[:size_of(b.conn_id)])
	b.stream.max_queue = STREAM_QUEUE_MAX
	return true
}

bot_close :: proc(b: ^Bot) {
	if b.has_current {
		leave := [1]u8{u8(proto.Message_Kind.Leave)}
		for _ in 0 ..< 3 {
			bot_send(b, leave[:])
		}
	}
	net.close(b.sock)
	proto.initiator_reset(&b.handshake)
	proto.session_reset(&b.pending)
	proto.session_reset(&b.current)
	proto.session_reset(&b.previous)
	proto.stream_destroy(&b.stream)
	ecdh.private_key_clear(&b.key)
	delete(b.asked)
	delete(b.heard)
}

// bot_step does what's due: handshakes, the login, the voice room, its
// voice, the stream.
bot_step :: proc(b: ^Bot, now: time.Tick) {
	switch b.phase {
	case .Waiting:
		if time.tick_diff(b.connect_at, now) < 0 {
			return
		}
		b.phase = .Connecting
		b.started = now
	case .Connecting, .Syncing, .Ready:
	case .Logging_In:
		if b.login_at != {} && time.tick_diff(b.login_at, now) >= 0 {
			b.login_at = {}
			bot_login(b)
		}
	}
	drive_handshake(b, now)
	if b.has_current {
		if b.synced && b.wants_voice && !b.join_asked && b.home != 0 {
			b.join_asked = true
			room_buf: [4]u8
			bot_ask(b, .Voice_Join, proto.encode_room(&room_buf, proto.Room(b.home)), now)
		}
		if b.talker && b.in_voice {
			send_voice(b, now)
		}
		stream_step(b, now)
		if time.tick_diff(b.last_sent, now) >= proto.KEEPALIVE_AFTER {
			bot_send(b, nil)
		}
	}
}

// bot_receive takes in whatever has come.
bot_receive :: proc(b: ^Bot) {
	recv_buf: [proto.MAX_PACKET_SIZE]u8
	for {
		n, _, err := net.recv_udp(b.sock, recv_buf[:])
		if err != nil || n == 0 {
			break
		}
		handle_packet(b, recv_buf[:n])
	}
}

// drive_handshake starts one when there's no session or the one there
// is is due to be rekeyed, and resends or starts over a stalled one.
@(private = "file")
drive_handshake :: proc(b: ^Bot, now: time.Tick) {
	ini := &b.handshake
	if ini.state != .Idle && time.tick_diff(ini.started, now) > proto.HANDSHAKE_TIMEOUT {
		b.run.stats.handshake_timeouts += 1
		abandon_handshake(b)
	}
	switch ini.state {
	case .Idle:
		if b.has_current && time.tick_diff(b.current.created, now) <= proto.REKEY_AFTER {
			return
		}
		packet, ok := proto.initiator_start(ini, &b.key)
		if !ok {
			return
		}
		ini.last_sent = now
		net.send_udp(b.sock, packet, b.run.server)
	case .Sent_Init, .Sent_Finish:
		if time.tick_diff(ini.last_sent, now) >= proto.HANDSHAKE_RETRY {
			ini.last_sent = now
			net.send_udp(b.sock, proto.initiator_packet(ini), b.run.server)
		}
	}
}

@(private = "file")
abandon_handshake :: proc(b: ^Bot) {
	proto.initiator_reset(&b.handshake)
	if b.has_pending {
		proto.session_reset(&b.pending)
		b.has_pending = false
	}
}

@(private = "file")
handle_packet :: proc(b: ^Bot, packet: []u8) {
	#partial switch proto.packet_type(packet) {
	case .Handshake_Resp:
		if _, result := proto.initiator_read_resp(&b.handshake, packet); result != .Ok {
			return
		}
		hello_buf: [proto.HELLO_MAX_SIZE]u8
		hello := proto.encode_hello(&hello_buf, b.conn_id, b.run.opt.password)
		finish, ok := proto.initiator_finish(&b.handshake, &b.pending, hello)
		if !ok {
			return
		}
		b.has_pending = true
		b.handshake.last_sent = time.tick_now()
		net.send_udp(b.sock, finish, b.run.server)

	case .Data:
		idx := proto.receiver_index(packet)
		sess: ^proto.Session
		switch {
		case b.has_pending && idx == b.pending.local_idx:
			sess = &b.pending
		case b.has_current && idx == b.current.local_idx:
			sess = &b.current
		case b.has_previous && idx == b.previous.local_idx:
			sess = &b.previous
		case:
			return
		}
		pt_buf: [proto.MAX_PACKET_SIZE]u8
		pt, ok := proto.open(sess, packet, pt_buf[:])
		if !ok {
			return
		}
		kind, kind_ok := proto.message_kind(pt)
		if sess == &b.pending {
			if kind_ok && kind == .Refused {
				log.errorf("%s: the server refused us: %v", b.name, proto.decode_refused(pt))
				abandon_handshake(b)
				return
			}
			if !kind_ok || kind != .Welcome {
				return
			}
			promote_pending(b)
		}
		if kind_ok {
			handle_message(b, kind, pt)
		}
	}
}

@(private = "file")
promote_pending :: proc(b: ^Bot) {
	if b.has_previous {
		proto.session_reset(&b.previous)
	}
	b.previous, b.has_previous = b.current, b.has_current
	b.current, b.has_current = b.pending, true
	b.pending, b.has_pending = {}, false
	proto.initiator_reset(&b.handshake)
}

@(private = "file")
handle_message :: proc(b: ^Bot, kind: proto.Message_Kind, pt: []u8) {
	#partial switch kind {
	case .Welcome:
		handle_welcome(b, pt)
	case .Stream:
		if proto.stream_receive(&b.stream, pt) != .None {
			log.errorf("%s: the server broke the stream", b.name)
			return
		}
		for {
			msg := proto.stream_next(&b.stream) or_break
			handle_app(b, msg)
		}
	case .Stream_Ack:
		proto.stream_acked(&b.stream, pt)
	case .State:
		handle_state(b, pt)
	case .Voice:
		if len(pt) >= proto.VOICE_DOWN_HEADER_SIZE + FRAME_STAMP_SIZE {
			speaker := proto.User_Num(endian.unchecked_get_u32le(pt[1:]))
			seq := endian.unchecked_get_u32le(pt[5:])
			sent := time.Tick {
				_nsec = i64(endian.unchecked_get_u64le(pt[proto.VOICE_DOWN_HEADER_SIZE:])),
			}
			voice_heard(b, speaker, seq, sent)
		}
	}
}

// handle_welcome: a new connection for us starts the stream over and
// logs in; one we have already is a rekey.
@(private = "file")
handle_welcome :: proc(b: ^Bot, pt: []u8) {
	instance, logged_in := proto.decode_welcome(pt)
	if b.has_instance && instance == b.instance {
		return
	}
	if b.has_instance {
		log.warnf("%s: the server started a new connection for us", b.name)
		b.run.stats.reconnects += 1
	}
	b.instance, b.has_instance = instance, true
	proto.stream_reset(&b.stream)
	b.tokens = STREAM_BURST
	b.stream_last = time.tick_now()
	clear(&b.asked)
	b.synced, b.in_voice, b.join_asked = false, false, false
	if logged_in {
		b.phase = .Syncing
	} else {
		b.phase = .Logging_In
		bot_login(b)
	}
}

@(private = "file")
bot_login :: proc(b: ^Bot) {
	buf: [proto.ACCOUNT_BODY_MAX]u8
	body := proto.encode_auth_login(buf[:], b.name, b.run.opt.bot_password, "stress", "yap-stress")
	bot_ask(b, .Auth_Login, body, time.tick_now())
}

// handle_app takes one message off the stream.
@(private = "file")
handle_app :: proc(b: ^Bot, msg: []u8) {
	kind, ok := proto.app_kind(msg)
	if !ok {
		return
	}
	#partial switch kind {
	case .Response:
		id, status, _ := proto.decode_response(msg)
		asked, known := b.asked[id]
		if !known {
			return
		}
		delete_key(&b.asked, id)
		answered(b.run, asked.op, status, time.tick_since(asked.sent))
		#partial switch asked.op {
		case .Auth_Login:
			switch {
			case status == .Ok:
				b.phase = .Syncing
			case status == .Wrong_Password || status == .Denied:
				log.errorf(
					"%s can't log in (%v): make the bots with yap-server account bots",
					b.name,
					status,
				)
			case:
				b.login_at = time.tick_add(time.tick_now(), LOGIN_RETRY)
			}
		case .Voice_Join:
			if status == .Ok {
				b.in_voice = true
				b.next_frame = time.tick_now()
			} else {
				log.errorf("%s could not join the voice room: %v", b.name, status)
			}
		}
	case .Event:
		op, body := proto.decode_event(msg)
		#partial switch op {
		case .Conv_Changed:
			if c, conv_ok := proto.decode_conv(body); conv_ok && .Home in c.flags {
				b.home = c.id
			}
		case .Sync_End:
			if !b.synced {
				b.synced = true
				b.phase = .Ready
				bot_ready(b.run, b, time.tick_since(b.started))
			}
		}
	}
}

// handle_state acks a snapshot once all its chunks have come.
@(private = "file")
handle_state :: proc(b: ^Bot, pt: []u8) {
	version := endian.unchecked_get_u32le(pt[1:])
	chunk, count := u32(pt[5]), u32(pt[6])
	if chunk >= count || count > 32 {
		return
	}
	if version != b.state_ver {
		b.state_ver, b.state_have = version, 0
	}
	b.state_have |= 1 << chunk
	if b.state_have == (1 << count) - 1 {
		ack_buf: [proto.STATE_ACK_SIZE]u8
		bot_send(b, proto.encode_state_ack(&ack_buf, version))
	}
}

// send_voice sends the frames due by now, 20 ms apart.
@(private = "file")
send_voice :: proc(b: ^Bot, now: time.Tick) {
	size := clamp(b.run.opt.frame, FRAME_STAMP_SIZE, 1000)
	buf: [proto.VOICE_UP_HEADER_SIZE + 1000]u8
	for time.tick_diff(b.next_frame, now) >= 0 {
		b.next_frame = time.tick_add(b.next_frame, FRAME_TIME)
		buf[0] = u8(proto.Message_Kind.Voice)
		endian.unchecked_put_u32le(buf[1:], b.seq)
		b.seq += 1
		stamp := time.tick_now()
		endian.unchecked_put_u64le(buf[proto.VOICE_UP_HEADER_SIZE:], u64(stamp._nsec))
		bot_send(b, buf[:proto.VOICE_UP_HEADER_SIZE + size])
		b.run.stats.frames_sent += 1
	}
}

@(private = "file")
voice_heard :: proc(b: ^Bot, speaker: proto.User_Num, seq: u32, sent: time.Tick) {
	if last, ok := b.heard[speaker]; ok && seq > last + 1 {
		b.run.stats.frames_missing += int(seq - last - 1)
	}
	if last, ok := b.heard[speaker]; !ok || seq > last {
		b.heard[speaker] = seq
	}
	frame_heard(b.run, time.tick_since(sent))
}

// bot_ask sends a request and remembers it for its round trip.
bot_ask :: proc(b: ^Bot, op: proto.Request_Op, body: []u8, now: time.Tick) {
	b.last_id += 1
	msg := proto.encode_request(b.last_id, op, body)
	if msg == nil || !proto.stream_send(&b.stream, msg) {
		log.errorf("%s: the stream is backed up; %v not sent", b.name, op)
		return
	}
	b.asked[b.last_id] = {op, now}
}

@(private = "file")
stream_step :: proc(b: ^Bot, now: time.Tick) {
	if !b.has_instance {
		return
	}
	st := &b.stream
	elapsed := f32(time.duration_seconds(time.tick_diff(b.stream_last, now)))
	b.stream_last = now
	b.tokens = min(b.tokens + elapsed * STREAM_RATE, STREAM_BURST)
	ack_buf: [proto.STREAM_ACK_SIZE]u8
	if ack, ok := proto.stream_ack(st, &ack_buf); ok {
		bot_send(b, ack)
	}
	out: [proto.MAX_PAYLOAD_SIZE]u8
	for b.tokens > 0 && !proto.stream_idle(st) {
		frame := proto.stream_next_frame(st, now, proto.STREAM_RESEND, out[:]) or_break
		bot_send(b, frame)
		b.tokens -= f32(len(frame))
	}
}

bot_send :: proc(b: ^Bot, pt: []u8) {
	pkt_buf: [proto.MAX_PACKET_SIZE]u8
	pkt, ok := proto.seal(&b.current, pt, pkt_buf[:])
	if !ok {
		return
	}
	b.last_sent = time.tick_now()
	net.send_udp(b.sock, pkt, b.run.server)
}

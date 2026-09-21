package server

import "core:crypto/ecdh"
import "core:encoding/endian"
import "core:fmt"
import "core:log"
import "core:net"
import "core:time"

import "../common"
import "../proto"

// Bounds memory used by unauthenticated Handshake_Init floods.
MAX_SESSIONS :: 256

// Client is one session: a keyed connection from one client instance.
// A user has more than one briefly while rekeying.
Client :: struct {
	using session: proto.Session,
	handshake:     proto.Responder, // in use until keyed
	user:          ^User, // set once keyed
	endpoint:      net.Endpoint,
	started:       time.Tick, // when the Handshake_Init arrived
	last_recv:     time.Tick,

	// Handshake_Finish verified: the client proved it holds its key.
	keyed:         bool,
	// The client has sent Data on this session, so it has switched over
	// and any older sessions with the same key can go.
	confirmed:     bool,
	// A newer session with the same client key exists. Still accepted
	// for receiving (packets in flight), never used for sending.
	superseded:    bool,
}

// User is a connected identity (static key). Channel membership lives
// here rather than on the session so it survives rekeys.
User :: struct {
	key:             [proto.KEY_SIZE]byte,
	num:             u32, // how clients refer to this user (see proto)
	id:              u32, // common.key_id(key), for logs
	name:            string, // sanitized; points into name_buf
	name_buf:        [proto.MAX_NAME_SIZE]u8,
	// What they've switched off for themselves, to pass on to the others
	// (see proto.User_Flags). The server doesn't act on it.
	flags:           proto.User_Flags,
	channel:         u16,
	join_ack:        u32, // newest Join request handled
	sessions:        int, // keyed sessions pointing here

	// State sync: the newest snapshot version the client confirmed, and
	// when we last sent it one.
	acked_version:   u32,
	sent_version:    u32,
	last_state_sent: time.Tick,
	chat:            Chat_Stream,
	last_poke:       time.Tick, // see handle_poke
	upload:          Upload, // an image on its way in (images.odin)
	download:        Download, // an image on its way out
}

Server :: struct {
	sock:          net.UDP_Socket,
	key:           ecdh.Private_Key,
	sessions:      map[u32]^Client, // by local_idx
	users:         map[[proto.KEY_SIZE]byte]^User,
	channels:      []string,
	chats:         []Chat_Log, // one per channel
	// Chat images by id, with the id last handed out (images.odin).
	images:        map[u32]^Stored_Image,
	last_image_id: u32,
	// Bumped on every change clients should hear about. Never 0, which
	// means "nothing acked yet".
	version:       u32,
	// The last user number handed out; numbers are never reused.
	last_num:      u32,
}

run_server :: proc(key_path: string, port: int, channels_path: string) -> bool {
	s := Server {
		version = 1,
	}
	if !common.load_or_create_private_key(key_path, &s.key) {
		return false
	}
	defer ecdh.private_key_clear(&s.key)

	channels, channels_ok := load_channels(channels_path)
	if !channels_ok {
		return false
	}
	s.channels = channels
	s.chats = make([]Chat_Log, len(channels))

	sock, err := net.make_bound_udp_socket(net.IP4_Any, port)
	if err != nil {
		log.errorf("failed to bind port %d: %v", port, err)
		return false
	}
	defer net.close(sock)
	s.sock = sock
	// Wake up periodically even when idle so stale sessions get reaped
	// and unacked state gets resent.
	net.set_option(sock, .Receive_Timeout, 100 * time.Millisecond)

	log.infof("listening on udp :%d", port)
	log.infof("server public key: %s", common.public_key_hex(&s.key))

	recv_buf: [proto.MAX_PACKET_SIZE]byte
	for {
		free_all(context.temp_allocator)

		n, from, recv_err := net.recv_udp(sock, recv_buf[:])
		#partial switch recv_err {
		case .None:
			if !common.simulate_loss() {
				handle_packet(&s, recv_buf[:n], from)
			}
		case .Timeout, .Would_Block:
		case:
			log.errorf("recv error: %v", recv_err)
		}

		reap_sessions(&s)
		sync_state(&s)
		chat_sync(&s)
		images_sync(&s)
	}
}

handle_packet :: proc(s: ^Server, packet: []byte, from: net.Endpoint) {
	#partial switch proto.packet_type(packet) {
	case .Handshake_Init:
		handle_init(s, packet, from)
	case .Handshake_Finish:
		handle_finish(s, packet, from)
	case .Data:
		handle_data(s, packet, from)
	}
	// Anything else is silently dropped: never answer what we can't authenticate.
}

handle_init :: proc(s: ^Server, packet: []byte, from: net.Endpoint) {
	// A retransmitted Init (our Resp got lost) gets the same Resp again
	// rather than a second handshake.
	sender_idx := proto.init_sender_index(packet)
	for _, c in s.sessions {
		if !c.keyed && c.handshake.remote_idx == sender_idx && c.endpoint == from {
			net.send_udp(s.sock, c.handshake.packet[:], from)
			return
		}
	}

	if len(s.sessions) >= MAX_SESSIONS {
		log.warnf("session table full, ignoring handshake from %v", net.to_string(from))
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
	resp, ok := proto.responder_start(&c.handshake, &s.key, packet, idx)
	if !ok {
		free(c)
		return
	}
	c.endpoint = from
	c.started = time.tick_now()
	s.sessions[idx] = c
	net.send_udp(s.sock, resp, from)
}

handle_finish :: proc(s: ^Server, packet: []byte, from: net.Endpoint) {
	idx := proto.receiver_index(packet)
	c := s.sessions[idx] or_else nil
	if c == nil {
		return
	}
	if c.keyed {
		// Our confirmation got lost and the client resent Finish. Confirm
		// again, to the address we know rather than the (unauthenticated)
		// source of this packet.
		send_keepalive(s, c)
		return
	}

	// On failure the handshake state is spent, so the session goes too.
	// The client will time out and start a fresh handshake.
	payload, ok := proto.responder_finish(&c.handshake, packet, &c.session)
	if !ok {
		log.debugf("invalid handshake finish from %v", net.to_string(from))
		drop_session(s, idx)
		return
	}
	// The msg3 payload is the client's hello: its name, and where a server
	// password will be checked.
	// TODO: check c.peer_key against an allowlist here to restrict who can join.
	hello_name, hello_ok := proto.decode_hello(payload)
	if !hello_ok {
		log.debugf("ignoring malformed hello from %v", net.to_string(from))
	}

	c.keyed = true
	c.endpoint = from
	c.last_recv = time.tick_now()

	for _, other in s.sessions {
		if other != c && other.keyed && other.peer_key == c.peer_key {
			other.superseded = true
		}
	}

	u := s.users[c.peer_key] or_else nil
	if u == nil {
		u = new(User)
		u.key = c.peer_key
		u.id = common.key_id(u.key)
		s.last_num += 1
		u.num = s.last_num
		set_name(u, hello_name)
		s.users[u.key] = u
		bump_version(s)
		log.infof(
			"%s joined from %v, in %q",
			user_label(u),
			net.to_string(from),
			s.channels[u.channel],
		)
	} else {
		log.debugf("%s has a new session", user_label(u))
		if hello_ok && rename(s, u, hello_name) {
			bump_version(s)
		}
	}
	u.sessions += 1
	c.user = u
	// This may be a restarted client that has never seen a snapshot, so
	// make sure the current one gets sent on the new session.
	u.acked_version = 0
	chat_restart(u)

	send_keepalive(s, c)
}

handle_data :: proc(s: ^Server, packet: []byte, from: net.Endpoint) {
	c := s.sessions[proto.receiver_index(packet)] or_else nil
	if c == nil || !c.keyed || time.tick_since(c.created) > proto.REJECT_AFTER {
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

	if !c.confirmed && !c.superseded {
		c.confirmed = true
		retire_superseded(s, c)
	}

	kind, kind_ok := proto.message_kind(pt)
	if !kind_ok {
		return // keepalive, or malformed
	}
	switch kind {
	case .Voice:
		if len(pt) >= proto.VOICE_UP_HEADER_SIZE {
			relay_voice(s, c, pt)
		}
	case .Join:
		handle_join(s, c.user, pt)
	case .State_Ack:
		if version := proto.decode_state_ack(pt); version == s.version {
			c.user.acked_version = version
		}
	case .Leave:
		drop_user(s, c.user)
	case .Set_Name:
		if rename(s, c.user, proto.decode_set_name(pt)) {
			bump_version(s)
		}
	case .Poke:
		handle_poke(s, c.user, pt)
	case .Sound:
		if flags := proto.decode_sound(pt); flags != c.user.flags {
			c.user.flags = flags
			log.debugf("%s sound state %v", user_label(c.user), flags)
			bump_version(s)
		}
	case .Chat_Send:
		handle_chat_send(s, c, pt)
	case .Image_Send:
		handle_image_send(s, c, pt)
	case .Image_Get:
		handle_image_get(s, c, pt)
	case .Blob_Chunk:
		handle_blob_chunk(s, c, pt)
	case .Blob_Need:
		handle_blob_need(c.user, pt)
	case .Chat_Received:
		handle_chat_received(c.user, pt)
	case .Typing:
		if len(pt) == proto.TYPING_UP_SIZE {
			handle_typing(s, c.user)
		}
	case .State, .Chat_Sent, .Chat, .Image_Gone:
	// Server-to-client only.
	}
}

// set_name stores a sanitized copy of `raw`. Returns whether it changed.
set_name :: proc(u: ^User, raw: string) -> bool {
	buf: [proto.MAX_NAME_SIZE]u8
	name := proto.sanitize_name(raw, &buf)
	if name == u.name {
		return false
	}
	n := copy(u.name_buf[:], name)
	u.name = string(u.name_buf[:n])
	return true
}

@(private = "file")
rename :: proc(s: ^Server, u: ^User, raw: string) -> bool {
	old := user_label(u)
	if !set_name(u, raw) {
		return false
	}
	log.infof("%s is now %s", old, user_label(u))
	return true
}

// user_label is how logs refer to a user: their name and key id.
user_label :: proc(u: ^User) -> string {
	if u.name == "" {
		return fmt.tprintf("%08x", u.id)
	}
	return fmt.tprintf("%s (%08x)", u.name, u.id)
}

handle_join :: proc(s: ^Server, u: ^User, pt: []byte) {
	request, channel := proto.decode_join(pt)
	if !proto.serial_newer(request, u.join_ack) {
		return // a retransmit of something already handled
	}
	u.join_ack = request

	switch {
	case int(channel) >= len(s.channels):
		log.debugf("%s asked for unknown channel %d", user_label(u), channel)
	case channel != u.channel:
		log.infof(
			"%s moved from %q to %q",
			user_label(u),
			s.channels[u.channel],
			s.channels[channel],
		)
		u.channel = channel
	}
	// Even a refused join changes join_ack, which the client waits for.
	bump_version(s)
}

bump_version :: proc(s: ^Server) {
	s.version += 1
	if s.version == 0 {
		s.version = 1
	}
}

// sync_state sends the current snapshot to every user who hasn't acked
// it: immediately after a change, then every CONTROL_RESEND until acked.
sync_state :: proc(s: ^Server) {
	now := time.tick_now()
	needs_state :: proc(s: ^Server, u: ^User, now: time.Tick) -> bool {
		return(
			u.acked_version != s.version &&
			(u.sent_version != s.version ||
					time.tick_diff(u.last_state_sent, now) >= proto.CONTROL_RESEND) \
		)
	}

	any_due := false
	for _, u in s.users {
		if needs_state(s, u, now) {
			any_due = true
			break
		}
	}
	if !any_due {
		return
	}

	// The channel list and rosters are the same for everyone.
	members := make([][dynamic]u32, len(s.channels), context.temp_allocator)
	for &m in members {
		m = make([dynamic]u32, context.temp_allocator)
	}
	users := make([]proto.User_Info, len(s.users), context.temp_allocator)
	next_user := 0
	for _, u in s.users {
		append(&members[u.channel], u.num)
		users[next_user] = {
			num   = u.num,
			key   = u.key,
			name  = u.name,
			flags = u.flags,
		}
		next_user += 1
	}
	infos := make([]proto.Channel_Info, len(s.channels), context.temp_allocator)
	for &info, i in infos {
		info = {
			name    = s.channels[i],
			members = members[i][:],
		}
	}

	body_buf: [proto.MAX_STATE_SIZE]byte
	for _, u in s.users {
		if !needs_state(s, u, now) {
			continue
		}
		c := sending_session(s, u)
		if c == nil {
			continue
		}
		state := proto.Channel_State {
			your_channel = u.channel,
			your_user    = u.num,
			join_ack     = u.join_ack,
			users        = users,
			channels     = infos,
		}
		body, ok := proto.encode_state(state, body_buf[:])
		if !ok {
			log.errorf("channel state doesn't fit in %d bytes", proto.MAX_STATE_SIZE)
			continue
		}
		count := proto.state_chunk_count(len(body))
		log.debugf(
			"sending state v%d to %s (%d bytes, %d chunks)",
			s.version,
			user_label(u),
			len(body),
			count,
		)

		chunk_buf: [proto.MAX_PAYLOAD_SIZE]byte
		pkt_buf: [proto.MAX_PACKET_SIZE]byte
		for i in 0 ..< count {
			chunk := proto.encode_state_chunk(chunk_buf[:], s.version, body, i)
			if pkt, sealed := proto.seal(&c.session, chunk, pkt_buf[:]); sealed {
				net.send_udp(s.sock, pkt, c.endpoint)
			}
		}
		u.sent_version = s.version
		u.last_state_sent = now
	}
}

// sending_session returns the user's newest session.
sending_session :: proc(s: ^Server, u: ^User) -> ^Client {
	for _, c in s.sessions {
		if c.user == u && c.keyed && !c.superseded {
			return c
		}
	}
	return nil
}

send_keepalive :: proc(s: ^Server, c: ^Client) {
	pkt_buf: [proto.MAX_PACKET_SIZE]byte
	if pkt, ok := proto.seal(&c.session, nil, pkt_buf[:]); ok {
		net.send_udp(s.sock, pkt, c.endpoint)
	}
}

// relay_voice forwards a voice frame to everyone else in the speaker's
// channel, re-encrypted under each recipient's newest session.
relay_voice :: proc(s: ^Server, from: ^Client, pt: []byte) {
	// [kind][seq][frame] -> [kind][speaker][seq][frame]
	out_pt: [proto.MAX_PAYLOAD_SIZE]byte
	body := pt[1:] // seq + frame
	n := 1 + 4 + len(body)
	if n > len(out_pt) {
		return
	}
	out_pt[0] = u8(proto.Message_Kind.Voice)
	endian.unchecked_put_u32le(out_pt[1:], from.user.num)
	copy(out_pt[5:], body)
	msg := out_pt[:n]

	pkt_buf: [proto.MAX_PACKET_SIZE]byte
	for _, c in s.sessions {
		if !c.keyed || c.superseded || c.user == from.user || c.user.channel != from.user.channel {
			continue
		}
		if pkt, ok := proto.seal(&c.session, msg, pkt_buf[:]); ok {
			net.send_udp(s.sock, pkt, c.endpoint)
		}
	}
}

// Once the client is using its new session, the ones it replaced are
// dead weight.
retire_superseded :: proc(s: ^Server, current: ^Client) {
	stale := make([dynamic]u32, context.temp_allocator)
	for idx, c in s.sessions {
		if c != current && c.superseded && c.user == current.user {
			append(&stale, idx)
		}
	}
	for idx in stale {
		drop_session(s, idx)
	}
}

// drop_user ends every session of a user who said goodbye.
drop_user :: proc(s: ^Server, u: ^User) {
	stale := make([dynamic]u32, context.temp_allocator)
	for idx, c in s.sessions {
		if c.user == u {
			append(&stale, idx)
		}
	}
	for idx in stale {
		drop_session(s, idx) // the last one frees u
	}
}

reap_sessions :: proc(s: ^Server) {
	stale := make([dynamic]u32, context.temp_allocator)
	for idx, c in s.sessions {
		expired: bool
		switch {
		case !c.keyed:
			expired = time.tick_since(c.started) > proto.HANDSHAKE_TIMEOUT
		case:
			expired =
				time.tick_since(c.last_recv) > proto.SESSION_TIMEOUT ||
				time.tick_since(c.created) > proto.REJECT_AFTER
		}
		if expired {
			append(&stale, idx)
		}
	}
	for idx in stale {
		drop_session(s, idx)
	}
}

drop_session :: proc(s: ^Server, idx: u32) {
	c := s.sessions[idx]
	delete_key(&s.sessions, idx)

	if u := c.user; u != nil {
		u.sessions -= 1
		if u.sessions == 0 {
			log.infof("%s left", user_label(u))
			drop_user_transfers(u)
			delete_key(&s.users, u.key)
			free(u)
			bump_version(s)
		}
	}

	proto.responder_reset(&c.handshake)
	proto.session_reset(&c.session)
	free(c)
}

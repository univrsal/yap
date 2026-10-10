package server

import "core:crypto"
import "core:crypto/ecdh"
import "core:crypto/hash"
import "core:encoding/endian"
import "core:fmt"
import "core:log"
import "core:net"
import "core:slice"
import "core:time"

import "common:."
import "common:proto"

// How many sessions there may be unless the config says otherwise
// (max_sessions). It bounds the memory unauthenticated Handshake_Init
// floods can take up, and with it how many clients can be connected:
// each has two links (proto.Link), so about half this many.
DEFAULT_MAX_SESSIONS :: 512

// Client is one session: a keyed connection from one client instance,
// on one of its links (proto.Link). A connection has one of each, and
// more briefly while rekeying.
Client :: struct {
	using session: proto.Session,
	handshake:     proto.Responder, // in use until keyed
	conn:          ^Conn, // set once keyed
	// The connection's bulk link (proto.Link): heavy messages to the
	// client go out on it (send_message). Only the main link's sessions
	// keep a connection.
	bulk:          bool,
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

/*
Conn is a connection: one client, known by its device's static key, for
as long as it has a session. (Not to be confused with a Client, which is
one of those sessions.) Channel membership lives here rather than on the
session so it survives rekeys.

A connection starts out not logged in, in Server.waiting, where it can
do nothing but log in (auth.odin). Once it is, it has an account and is
in Server.conns, which is where everything else looks: whatever goes
through the connections there only ever meets ones that are logged in.
*/
Conn :: struct {
	key:             [proto.KEY_SIZE]byte,
	num:             proto.User_Num, // how clients refer to this connection
	// Whose it is; nil until it's logged in.
	account:         ^Account,
	// Its user hasn't done anything for a while, as its client says
	// (activity.odin).
	idle:            bool,
	// A request of its that needs a password hashed is with the hashing
	// thread (auth.odin): one at a time.
	auth_busy:       bool,
	// Which of the client's connections this is, and which of ours: see
	// the hello and Welcome in proto/names.odin. A handshake with the same
	// conn_id is a rekey; with another, the client has started over.
	conn_id:         u64,
	instance:        u64,
	id:              u32, // common.key_id(key), for logs
	// What they've switched off for themselves and whether they're
	// sharing their screen, to pass on to the others (see
	// proto.User_Flags). Only screen sharing (video.odin) acts on it.
	flags:           proto.User_Flags,
	// The voice room it's in, 0 for none (conv_requests.odin).
	room:            proto.Room,
	sessions:        int, // keyed sessions of the main link pointing here

	// State sync: the newest snapshot version the client confirmed, and
	// when we last sent it one.
	acked_version:   u32,
	sent_version:    u32,
	last_state_sent: time.Tick,
	last_typing:     time.Tick, // see handle_typing
	last_poke:       time.Tick, // see handle_poke
	upload:          Upload, // a blob on its way in (transfers.odin)
	download:        Download, // a blob on its way out
	video:           Video_State, // screen sharing (video.odin)
	stream:          Conn_Stream, // requests and events (stream.odin, rpc.odin)
}

Server :: struct {
	// When statuses were last looked at for ones that have ended
	// (profiles.odin).
	status_checked: time.Tick,
	// When the memory was last logged (memory.odin).
	memory_log:     Memory_Log,
	// The calls going on (calls.odin).
	calls:          Calls,
	sock:           net.UDP_Socket,
	key:            ecdh.Private_Key,
	// What clients show for this server: its name (may be empty), what
	// it's for, and its picture (server_info.odin). Owned.
	name:           string,
	description:    string,
	icon:           proto.Blob_Id,
	password:       string, // empty: anyone may join
	sessions:       map[proto.Session_Id]^Client, // by local_idx
	max_sessions:   int,
	// The connections that are logged in, and those that aren't yet, by
	// their device's key (see Conn).
	conns:          map[[proto.KEY_SIZE]byte]^Conn,
	waiting:        map[[proto.KEY_SIZE]byte]^Conn,
	// Accounts and their devices (accounts.odin), and logging in to them
	// (auth.odin), which has a thread hash the passwords (hash_worker.odin).
	accounts:       Accounts,
	auth:           Auth,
	hasher:         Hash_Worker,
	// The channels and who is in each (convs.odin); their messages are in
	// the database (messages.odin).
	convs:          Convs,
	// Bumped on every change clients should hear about. Never 0, which
	// means "nothing acked yet".
	version:        u32,
	// The last user number handed out; numbers are never reused.
	last_num:       proto.User_Num,
	// Files offered in DMs, by the message that offers them, and the
	// transfers being relayed, by the same (files.odin).
	file_offers:    map[proto.Msg_Id]File_Offer,
	file_routes:    map[proto.Msg_Id]^File_Route,
	// What the server keeps for good: its database (db.odin) and the
	// files that go with it (blobs.odin).
	db:             DB,
	blobs:          Blob_Store,
	// Files uploaded with messages, and on their way in and out
	// (attachments.odin).
	attach:         Attachments,
	// The server's own emoji (emoji.odin).
	emoji:          Custom_Emoji,
	// Removing what's old (retention.odin).
	retention:      Retention,
	// What the loop is handling this time round, and how long its turns
	// take (loop_stats.odin).
	handling:       proto.Message_Kind,
	loop:           Loop_Stats,
	// The server's own email account, if it has one (email.odin).
	email:          Email,
	// Who may register, and how fast registrations are taken
	// (register.odin).
	registration:   Registration_Config,
	register_rate:  Register_Rate,
	// Deleting registrations whose addresses weren't verified
	// (verify.odin).
	verify:         Verify_State,
}

// How long the loop waits for a packet before it comes round anyway.
IDLE_WAIT :: 100 * time.Millisecond

run_server :: proc(settings: Settings, initial_admin_password := "") -> bool {
	s := Server {
		version = 1,
		password = settings.password,
		max_sessions = settings.max_sessions,
		auth = {params = HASH_PARAMS_NOW},
		registration = settings.registration,
	}
	if !common.parse_private_key(settings.key, &s.key) {
		log.error("the key in the config is not a valid private key")
		return false
	}
	defer ecdh.private_key_clear(&s.key)
	defer files_destroy(&s)
	if !db_open(&s.db, settings.db_path) {
		return false
	}
	defer db_close(&s.db)
	if !blob_store_open(&s.blobs, &s.db, settings.blobs_dir) {
		return false
	}
	defer blob_store_close(&s.blobs)
	attachments_open(&s, settings.attachments)
	defer attachments_close(&s)
	retention_open(&s.retention, &s.db, settings.retention)
	defer retention_close(&s.retention)
	emoji_open(&s, settings.emoji_dir)
	defer emoji_close(&s)
	server_info_load(&s, settings.name)
	defer server_info_destroy(&s)
	if !accounts_load(&s.accounts, &s.db) {
		return false
	}
	defer accounts_destroy(&s.accounts)
	if !ensure_first_admin(&s.accounts, initial_password = initial_admin_password) {
		return false
	}
	// The config's channels are only what a new database starts with.
	if !convs_load(&s.convs, &s.db, settings.channels, &s.accounts) {
		return false
	}
	defer convs_destroy(&s.convs)
	defer calls_destroy(&s)
	db_commit(&s.db)
	if !hash_worker_start(&s.hasher) {
		log.error("could not start the thread that hashes passwords")
		return false
	}
	defer hash_worker_stop(&s.hasher)
	defer auth_destroy(&s.auth)
	email_open(&s.email, settings.email)
	defer email_close(&s.email)
	memory_log_open(&s, settings.memory_log)
	loop_stats_open(&s)
	if s.registration.verify_email && !s.email.enabled {
		log.warn(
			"registration asks for addresses to be verified, but there's no email, so they aren't",
		)
	}

	port := settings.port
	sock, err := net.make_bound_udp_socket(net.IP4_Any, port)
	if err != nil {
		log.errorf("failed to bind port %d: %v", port, err)
		return false
	}
	defer net.close(sock)
	s.sock = sock
	// Wake up periodically even when idle so stale sessions get reaped
	// and unacked state gets resent; and more often while old messages
	// are being purged, a little at a time (retention.odin).
	wait := IDLE_WAIT
	net.set_option(sock, .Receive_Timeout, wait)

	log.infof("listening on udp :%d", port)
	log.infof("server public key: %s", common.public_key_hex(&s.key))
	if s.password != "" {
		log.info("clients need the password to join")
	}

	// What every turn does after its packet, in this order.
	syncs := [?]struct {
		phase: Loop_Phase,
		run:   proc(s: ^Server),
	} {
		{.Reap, reap_sessions},
		{.Auth, auth_sync},
		// Before the snapshots: a connection that has just logged in is
		// told who everyone is (on its stream) before it's told who is
		// here.
		{.Stream, stream_sync},
		{.State, sync_state},
		{.Transfers, transfers_sync},
		{.Attachments, attachments_sync},
		{.Files, files_sync},
		{.Emoji, emoji_sync},
		{.Profiles, profiles_sync},
		{.Calls, calls_sync},
		{.Retention, retention_sync},
		{.Verify, verify_sync},
		{.Exercise, db_exercise},
		{.Memory, memory_sync},
	}

	recv_buf: [proto.MAX_PACKET_SIZE]byte
	for {
		free_all(context.temp_allocator)

		n, from, recv_err := net.recv_udp(sock, recv_buf[:])
		// From here on, not from before the wait for a packet.
		loop_turn_begin(&s)
		s.handling = {}
		// Nothing arrived for as long as the socket waits: nobody is
		// talking, and what's slow can be done without anyone hearing it.
		idle := false
		#partial switch recv_err {
		case .None:
			if !common.simulate_loss() {
				handle_packet(&s, recv_buf[:n], from)
			}
		case .Timeout, .Would_Block:
			idle = true
		case:
			log.errorf("recv error: %v", recv_err)
		}
		loop_mark(&s, .Packet)

		for sync in syncs {
			sync.run(&s)
			loop_mark(&s, sync.phase)
		}
		// What this turn wrote, in one go.
		db_commit(&s.db)
		loop_mark(&s, .Commit)
		loop_turn_end(&s, packet = recv_err == .None)

		if idle {
			db_idle(&s.db)
		}
		busy := retention_busy(&s) || attachments_busy(&s)
		if want := min(RETENTION_WAIT, ATTACH_WAIT) if busy else IDLE_WAIT; want != wait {
			wait = want
			net.set_option(sock, .Receive_Timeout, wait)
		}
	}
}

/*
users_seen_by is who is here as `viewer`'s account is shown it: in a
private channel's room only to its members, and anyone else sees those in
it in no room (room_hidden); and without those who appear offline
(`hidden`, by index; activity.odin) but for the viewer's own account, or
while their voice is in a room the viewer can see. `users` is returned
as it is when nothing differs, else a copy in the temp allocator.
*/
users_seen_by :: proc(
	s: ^Server,
	users: []proto.User_Info,
	hidden: []bool,
	viewer: proto.Account_Id,
) -> []proto.User_Info {
	shown := users
	left_out := 0
	for user, i in users {
		room := user.room
		if room_hidden(s, room, viewer) {
			room = 0
		}
		out := hidden[i] && room == 0 && user.account != viewer
		if room == user.room && !out {
			if left_out > 0 {
				shown[i - left_out] = user
			}
			continue
		}
		if raw_data(shown) == raw_data(users) {
			shown = slice.clone(users, context.temp_allocator)
		}
		if out {
			left_out += 1
			continue
		}
		shown[i - left_out] = user
		shown[i - left_out].room = room
	}
	return shown[:len(shown) - left_out]
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

	if len(s.sessions) >= s.max_sessions {
		log.warnf("session table full, ignoring handshake from %v", net.to_string(from))
		return
	}

	idx: proto.Session_Id
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
		// Our Welcome got lost and the client resent Finish. Welcome it
		// again, at the address we know rather than the (unauthenticated)
		// source of this packet.
		send_welcome(s, c)
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
	// The msg3 payload is the client's hello: which of its connections
	// this is, which of the connection's links, and the server's password.
	conn_id, hello_password, link, hello_ok := proto.decode_hello(payload)
	switch {
	case !hello_ok:
		refuse(s, c, from, .Version)
		return
	case s.password != "" && !password_matches(s.password, hello_password):
		refuse(s, c, from, .Wrong_Password)
		return
	}

	u := conn_of(s, c.peer_key)
	if link == .Bulk {
		bind_bulk(s, c, u, conn_id, from)
		return
	}

	c.keyed = true
	c.endpoint = from
	c.last_recv = time.tick_now()

	if u != nil && u.conn_id != conn_id {
		// Not a rekey: the client has started over, and knows nothing of
		// what this connection was. It goes, as if they had left, and
		// they get a new one.
		log.infof("%s started over", conn_label(u))
		drop_conn(s, u)
		u = nil
	}

	supersede(s, c)

	if u == nil {
		u = new(Conn)
		u.key = c.peer_key
		u.conn_id = conn_id
		stream_init(&u.stream)
		for u.instance == 0 {
			crypto.rand_bytes(([^]byte)(&u.instance)[:size_of(u.instance)])
		}
		u.id = common.key_id(u.key)
		s.last_num += 1
		u.num = s.last_num
		s.waiting[u.key] = u
		log.infof("%s connected from %v", conn_label(u), net.to_string(from))
	} else {
		log.debugf("%s has a new session", conn_label(u))
	}
	fresh := u.sessions == 0
	u.sessions += 1
	c.conn = u

	// A device that has logged in before is logged in by its key: that
	// it holds it is what the handshake just proved.
	if fresh {
		auth_known_device(s, u)
	}
	// After the Welcome, which a client waits for on a new session: what
	// logging in has queued for it goes out later in this turn.
	send_welcome(s, c)
}

/*
bind_bulk makes a session that has just finished its handshake the
bulk link of the device's connection `u` (proto.Link), if the hello
names it. Otherwise there's nothing to bind it to - the connection has
gone, or the main link's handshake hasn't got this far - and the client
is told so, to try again later.
*/
@(private = "file")
bind_bulk :: proc(s: ^Server, c: ^Client, u: ^Conn, conn_id: u64, from: net.Endpoint) {
	if u == nil || u.conn_id != conn_id {
		refuse(s, c, from, .No_Connection)
		return
	}
	c.keyed = true
	c.bulk = true
	c.endpoint = from
	c.last_recv = time.tick_now()
	c.conn = u
	supersede(s, c)
	log.debugf("%s has a new bulk link", conn_label(u))
	send_welcome(s, c)
}

// supersede marks the older sessions of a new session's link as
// superseded: still there for what's in flight, never sent on.
@(private = "file")
supersede :: proc(s: ^Server, c: ^Client) {
	for _, other in s.sessions {
		if other != c && other.keyed && other.peer_key == c.peer_key && other.bulk == c.bulk {
			other.superseded = true
		}
	}
}

// conn_of is the connection from the device with this key, logged in
// or not; nil if it has none.
conn_of :: proc(s: ^Server, key: [proto.KEY_SIZE]byte) -> ^Conn {
	if u := s.conns[key] or_else nil; u != nil {
		return u
	}
	return s.waiting[key] or_else nil
}

/*
conn_login makes a connection its account's: from here on it's one of
the connections everyone sees - unless its account is Unverified
(verify.odin), when it stays out of sight, in Server.waiting, and is
told nothing but who it is until it's verified. The caller has made
sure it may log in.
*/
conn_login :: proc(s: ^Server, u: ^Conn, acc: ^Account) {
	u.account = acc
	append(&acc.conns, u)
	if .Unverified in acc.flags {
		log.infof("%s logged in, unverified", conn_label(u))
		send_event(u, .Sync_Begin)
		send_self(u)
		send_event(u, .Sync_End)
		return
	}
	conn_seen(s, u)
}

// conn_seen puts a logged in connection where everyone sees it, and
// tells it everything a login is told.
conn_seen :: proc(s: ^Server, u: ^Conn) {
	acc := u.account
	delete_key(&s.waiting, u.key)
	s.conns[u.key] = u
	bump_version(s)
	log.infof("%s logged in", conn_label(u))
	// Here now, which its own sync already says; everyone else is told.
	now := activity_of(acc)
	changed := now != acc.shown
	acc.shown = now
	directory_sync(s, u)
	if changed {
		account_told(s, acc, except = u)
	}
}

/*
conn_unseen takes a connection out of everyone's sight, still logged in,
because its account has become Unverified (verify.odin): whatever it was
in the middle of ends, as if it had left.
*/
conn_unseen :: proc(s: ^Server, u: ^Conn) {
	calls_conn_gone(s, u)
	drop_conn_transfers(u)
	attachments_conn_gone(s, u)
	delete_key(&s.conns, u.key)
	drop_conn_files(s, u)
	s.waiting[u.key] = u
	u.room, u.flags = 0, {}
	u.acked_version, u.sent_version = 0, 0
	u.last_typing, u.video = {}, {}
}

/*
conn_left is a connection ceasing to be its account's, because it went
or was logged out: whatever it was in the middle of ends, and everyone
else sees it go.
*/
@(private = "file")
conn_left :: proc(s: ^Server, u: ^Conn) {
	log.infof("%s left", conn_label(u))
	calls_conn_gone(s, u)
	drop_conn_transfers(u)
	attachments_conn_gone(s, u)
	delete_key(&s.conns, u.key)
	// After it's gone from `conns`, so only the other side hears about it.
	drop_conn_files(s, u)
	acc := u.account
	for other, i in acc.conns {
		if other == u {
			unordered_remove(&acc.conns, i)
			break
		}
	}
	if len(acc.conns) == 0 {
		account_seen(&s.accounts, acc)
	}
	u.account = nil
	u.idle = false
	activity_check(s, acc)
	bump_version(s)
}

/*
conn_logout takes a connection's account from it without ending the
connection: it's back to where it can only log in. With a `reason` it
wasn't the client's own doing, and it's told why.
*/
conn_logout :: proc(s: ^Server, u: ^Conn, reason: proto.Logout_Reason = {}) {
	if u.account == nil {
		return
	}
	conn_left(s, u)
	// As new, for whoever logs in on it next.
	u.room, u.flags = 0, {}
	u.acked_version, u.sent_version = 0, 0
	u.last_typing, u.video = {}, {}
	s.waiting[u.key] = u
	if reason != {} {
		body := [1]u8{u8(reason)}
		send_event(u, .Logged_Out, body[:])
	}
}

// How many copies of a Welcome go out; it's unreliable, like Refused.
@(private = "file")
WELCOME_COPIES :: 3

// send_welcome tells a client whose hello was accepted which connection
// its new session belongs to (see proto/names.odin).
@(private = "file")
send_welcome :: proc(s: ^Server, c: ^Client) {
	buf: [proto.WELCOME_SIZE]u8
	msg := proto.encode_welcome(&buf, c.conn.instance, c.conn.account != nil)
	for _ in 0 ..< WELCOME_COPIES {
		send_message(s, c, msg)
	}
}

// How many copies of Refused go out; it's unreliable, like Leave.
@(private = "file")
REFUSED_COPIES :: 3

/*
refuse tells a client that just finished its handshake why it can't
join, on the session that handshake made, and forgets the session. The
client never gets a connection: nobody else ever hears of it.
*/
@(private = "file")
refuse :: proc(s: ^Server, c: ^Client, from: net.Endpoint, reason: proto.Refusal) {
	log.infof("refused %08x from %v: %v", common.key_id(c.peer_key), net.to_string(from), reason)
	msg_buf: [proto.REFUSED_SIZE]byte
	msg := proto.encode_refused(&msg_buf, reason)
	pkt_buf: [proto.MAX_PACKET_SIZE]byte
	for _ in 0 ..< REFUSED_COPIES {
		if pkt, ok := proto.seal(&c.session, msg, pkt_buf[:]); ok {
			net.send_udp(s.sock, pkt, from)
		}
	}
	drop_session(s, c.local_idx)
}

// password_matches compares hashes of the two, so how long it takes
// says nothing about the password, not even its length.
@(private = "file")
password_matches :: proc(want, got: string) -> bool {
	a := hash.hash_string(.SHA256, want, context.temp_allocator)
	b := hash.hash_string(.SHA256, got, context.temp_allocator)
	return crypto.compare_constant_time(a, b) == 1
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
	s.handling = kind
	if c.conn.account == nil || .Unverified in c.conn.account.flags {
		// Not logged in: nothing but what it takes to stay connected and
		// to log in, which goes over the stream (rpc.odin has the same
		// gate for what's asked there).
		#partial switch kind {
		case .Ping, .Leave, .Stream, .Stream_Ack:
		case:
			return
		}
	}
	switch kind {
	case .Voice:
		if len(pt) >= proto.VOICE_UP_HEADER_SIZE {
			relay_voice(s, c, pt)
		}
	case .State_Ack:
		if version := proto.decode_state_ack(pt); version == s.version {
			c.conn.acked_version = version
		}
	case .Leave:
		drop_conn(s, c.conn)
	case .Poke:
		handle_poke(s, c.conn, pt)
	case .Sound:
		if flags := proto.decode_sound(pt); flags != c.conn.flags {
			c.conn.flags = flags
			log.debugf("%s sound state %v", conn_label(c.conn), flags)
			bump_version(s)
		}
	case .Blob_Chunk:
		handle_blob_chunk(s, c, pt)
	case .Blob_Need:
		handle_blob_need(s, c.conn, pt)
	case .Typing:
		if len(pt) == proto.TYPING_UP_SIZE {
			handle_typing(s, c.conn, pt)
		}
	case .Video:
		relay_video(s, c, pt)
	case .Watch:
		handle_watch(s, c.conn, pt)
	case .Ping:
		// Back on the session it came on, so the client times the path
		// it measured.
		pong_buf: [proto.PING_SIZE]byte
		pong := proto.encode_ping(&pong_buf, .Pong, proto.decode_ping(pt))
		pkt_buf: [proto.MAX_PACKET_SIZE]byte
		if pkt, sealed := proto.seal(&c.session, pong, pkt_buf[:]); sealed {
			net.send_udp(s.sock, pkt, c.endpoint)
		}
	case .File_Accept:
		handle_file_accept(s, c, pt)
	case .File_Chunk:
		handle_file_chunk(s, c, pt)
	case .File_Ack:
		handle_file_ack(s, c, pt)
	case .File_Cancel:
		handle_file_cancel(s, c, pt)
	case .Upload_Chunk:
		handle_upload_chunk(s, c.conn, pt)
	case .Download_Ack:
		handle_download_ack(s, c.conn, pt)
	case .Transfer_Cancel:
		handle_transfer_cancel(s, c.conn, pt)
	case .State, .Refused, .Keyframe, .Pong, .Welcome, .Upload_Ack, .Download_Chunk:
	// Server-to-client only.
	case .Set_Name,
	     .Join,
	     .Chat_Send,
	     .Chat_Sent,
	     .Chat,
	     .Chat_Received,
	     .Image_Send,
	     .Image_Get,
	     .Image_Gone,
	     .DM_Send,
	     .DM_Sent,
	     .DM,
	     .DM_Ack,
	     .DM_Delivered,
	     .DM_Typing,
	     .DM_Image_Send,
	     .DM_Image_Get,
	     .DM_Image_Gone,
	     .Last_Seen_Get,
	     .Last_Seen:
	// Retired.
	case .Stream:
		handle_stream(s, c.conn, pt)
	case .Stream_Ack:
		proto.stream_acked(&c.conn.stream, pt)
	}
}

/*
send_message sends a message on a session of `c`'s connection: a heavy
one (proto.HEAVY_KINDS) on its bulk link if it has one, anything else
on `c`.
*/
send_message :: proc(s: ^Server, c: ^Client, msg: []byte) {
	c := c
	if proto.is_heavy(msg) && !c.bulk && c.conn != nil {
		if b := bulk_session(s, c.conn); b != nil {
			c = b
		}
	}
	pkt_buf: [proto.MAX_PACKET_SIZE]byte
	if pkt, ok := proto.seal(&c.session, msg, pkt_buf[:]); ok {
		net.send_udp(s.sock, pkt, c.endpoint)
	}
}

// conn_name is what a connection's account is called; "" for one
// that isn't logged in.
conn_name :: proc(u: ^Conn) -> string {
	return u.account.display if u.account != nil else ""
}

// conn_label is how logs refer to a connection: its account, if it has
// one, and its device's key id.
conn_label :: proc(u: ^Conn) -> string {
	if u.account == nil {
		return fmt.tprintf("%08x", u.id)
	}
	return fmt.tprintf("%s (%08x)", u.account.username, u.id)
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
	needs_state :: proc(s: ^Server, u: ^Conn, now: time.Tick) -> bool {
		return(
			u.acked_version != s.version &&
			(u.sent_version != s.version ||
					time.tick_diff(u.last_state_sent, now) >= proto.CONTROL_RESEND) \
		)
	}

	any_due := false
	for _, u in s.conns {
		if needs_state(s, u, now) {
			any_due = true
			break
		}
	}
	if !any_due {
		return
	}

	// Who is here, and in which room, is the same for everyone; but for
	// those who appear offline (activity.odin), whom only their own
	// account sees, or anyone who can see the room their voice is in.
	users := make([]proto.User_Info, len(s.conns), context.temp_allocator)
	hidden := make([]bool, len(s.conns), context.temp_allocator)
	next_user := 0
	for _, u in s.conns {
		users[next_user] = {
			num     = u.num,
			account = u.account.id,
			flags   = u.flags,
			room    = u.room,
		}
		hidden[next_user] = appears_offline(u.account)
		next_user += 1
	}

	body_buf: [proto.MAX_STATE_SIZE]byte
	for _, u in s.conns {
		if !needs_state(s, u, now) {
			continue
		}
		c := sending_session(s, u)
		if c == nil {
			continue
		}
		// A private channel's room is only shown to its members: anyone
		// else sees those in it in no room (room_hidden).
		shown := users_seen_by(s, users, hidden, u.account.id)
		state := proto.Presence {
			your_user = u.num,
			users     = shown,
		}
		body, ok := proto.encode_state(state, body_buf[:])
		if !ok {
			log.errorf("who is here doesn't fit in %d bytes", proto.MAX_STATE_SIZE)
			continue
		}
		count := proto.state_chunk_count(len(body))
		log.debugf(
			"sending state v%d to %s (%d bytes, %d chunks)",
			s.version,
			conn_label(u),
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

// sending_session returns the newest session of the connection's main
// link.
sending_session :: proc(s: ^Server, u: ^Conn) -> ^Client {
	for _, c in s.sessions {
		if c.conn == u && c.keyed && !c.superseded && !c.bulk {
			return c
		}
	}
	return nil
}

// bulk_session returns the newest session of the connection's bulk
// link, nil while it has none.
bulk_session :: proc(s: ^Server, u: ^Conn) -> ^Client {
	for _, c in s.sessions {
		if c.conn == u && c.keyed && !c.superseded && c.bulk {
			return c
		}
	}
	return nil
}

// relay_voice forwards a voice frame to everyone else in the speaker's
// room, re-encrypted under each recipient's newest session. Someone in
// no room is talking to nobody.
relay_voice :: proc(s: ^Server, from: ^Client, pt: []byte) {
	if from.conn.room == 0 {
		return
	}
	// [kind][seq][frame] -> [kind][speaker][seq][frame]
	out_pt: [proto.MAX_PAYLOAD_SIZE]byte
	body := pt[1:] // seq + frame
	n := 1 + 4 + len(body)
	if n > len(out_pt) {
		return
	}
	out_pt[0] = u8(proto.Message_Kind.Voice)
	endian.unchecked_put_u32le(out_pt[1:], u32(from.conn.num))
	copy(out_pt[5:], body)
	msg := out_pt[:n]

	pkt_buf: [proto.MAX_PACKET_SIZE]byte
	for _, c in s.sessions {
		if !c.keyed ||
		   c.superseded ||
		   c.bulk ||
		   c.conn == from.conn ||
		   c.conn.account == nil ||
		   c.conn.room != from.conn.room {
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
	stale := make([dynamic]proto.Session_Id, context.temp_allocator)
	for idx, c in s.sessions {
		if c != current && c.superseded && c.conn == current.conn && c.bulk == current.bulk {
			append(&stale, idx)
		}
	}
	for idx in stale {
		drop_session(s, idx)
	}
}

// drop_conn ends every session of a connection, and with the last of
// them the connection.
drop_conn :: proc(s: ^Server, u: ^Conn) {
	stale := make([dynamic]proto.Session_Id, context.temp_allocator)
	for idx, c in s.sessions {
		if c.conn == u {
			append(&stale, idx)
		}
	}
	for idx in stale {
		drop_session(s, idx) // the last one frees u
	}
}

reap_sessions :: proc(s: ^Server) {
	stale := make([dynamic]proto.Session_Id, context.temp_allocator)
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

// drop_session ends a session; one already gone (with its connection's
// main link) is left be.
drop_session :: proc(s: ^Server, idx: proto.Session_Id) {
	c := s.sessions[idx] or_else nil
	if c == nil {
		return
	}
	delete_key(&s.sessions, idx)

	if u := c.conn; u != nil && !c.bulk {
		u.sessions -= 1
		if u.sessions == 0 {
			// Its bulk link goes with it, before it's freed.
			bulk := make([dynamic]proto.Session_Id, context.temp_allocator)
			for other_idx, other in s.sessions {
				if other.conn == u {
					append(&bulk, other_idx)
				}
			}
			for other_idx in bulk {
				drop_session(s, other_idx)
			}
			if u.account != nil {
				conn_left(s, u)
			} else {
				log.debugf("%s went without logging in", conn_label(u))
			}
			delete_key(&s.waiting, u.key)
			proto.stream_destroy(&u.stream)
			free(u)
		}
	}

	proto.responder_reset(&c.handshake)
	proto.session_reset(&c.session)
	free(c)
}

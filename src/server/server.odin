package server

import "core:crypto"
import "core:crypto/ecdh"
import "core:encoding/endian"
import "core:fmt"
import "core:log"
import "core:net"
import "core:slice"
import "core:time"

import "common:."
import "common:proto"
import "gate"
import "mail"
import "webpush"

// The default maximum number of sessions, unless the config sets one
// (max_sessions). It limits how much memory the sessions use, and with
// that also how many clients can be connected: each client has two links
// (proto.Link), so roughly half this many. Handshake_gate.odin keeps a flood
// of unauthenticated Handshake_Init packets from taking them all.
DEFAULT_MAX_SESSIONS :: 512

// Client is a single session: a keyed connection from one client instance
// on one of its links (proto.Link). A connection normally has one session
// per link, and briefly more while rekeying.
Client :: struct {
	using base: Session_Base,
	conn:       ^Conn, // set once keyed
	// Whether this session is the connection's bulk link (proto.Link).
	// Heavy messages to the client are sent on it (see send_message).
	// Only the main link's sessions count towards keeping a connection
	// alive.
	bulk:       bool,
}

// Conn is a connection: one client, identified by its device's static key,
// which lives for as long as it has a session. (Not to be confused with a
// Client, which is one of those sessions.) Channel membership is stored here
// rather than on the session so that it survives rekeys.
//
// A connection starts out logged out, in Server.waiting, where the only thing
// it can do is log in (auth.odin). Once it has logged in, it has an account and
// moves to Server.conns, which is where everything else looks. That way any
// code iterating over the connections there only ever sees logged in ones.
Conn :: struct {
	key:             [proto.KEY_SIZE]byte,
	num:             proto.User_Num, // how clients refer to this connection
	// The account this connection is logged in to; nil until it logs in.
	account:         ^Account,
	// The user hasn't done anything for a while, as reported by their
	// client (activity.odin). `hidden` means the client is out of sight (a
	// hidden web page), which doesn't make the user away, but makes the
	// server send them push notifications (push_notify.odin).
	idle:            bool,
	hidden:          bool,
	// One of this connection's requests that needs a password hashed is
	// currently with the hashing thread (auth.odin). Only one is allowed at
	// a time.
	auth_busy:       bool,
	// Identify the client's connection and our side of it: see the hello and
	// Welcome in proto/hello.odin. A handshake with the same conn_id is a
	// rekey; one with a different conn_id means the client has started over.
	conn_id:         u64,
	instance:        u64,
	id:              u32, // common.key_id(key), for logs
	// Whether the user has muted or deafened themselves and whether they're
	// sharing their screen, which is passed on to the other users (see
	// proto.User_Flags). Only screen sharing (video.odin) acts on it.
	flags:           proto.User_Flags,
	// The voice room the connection is in, 0 for none (conv_requests.odin).
	room:            proto.Room,
	sessions:        int, // keyed sessions of the main link pointing here

	// State sync: the newest snapshot version the client confirmed, and
	// when we last sent it one.
	acked_version:   u32,
	sent_version:    u32,
	last_state_sent: time.Tick,
	last_typing:     time.Tick, // see handle_typing
	// How many requests it may still make (request_take in rpc.odin).
	requests:        proto.Bucket, // see request_take
	request_warned:  bool, // that it's over the limit, until it's not
	upload:          Upload, // a blob on its way in (transfers.odin)
	download:        Download, // a blob on its way out
	stream:          Conn_Stream, // requests and events (stream.odin, rpc.odin)
}

Server :: struct {
	// When statuses were last checked for ones that have expired
	// (profiles.odin).
	status_checked:     time.Tick,
	// When memory usage was last logged (memory.odin).
	memory_log:         Memory_Log,
	// The ongoing calls (calls.odin).
	calls:              Calls,
	sock:               net.UDP_Socket,
	key:                ecdh.Private_Key,
	// What clients display for this server: its name (may be empty), its
	// description, and its icon (server_info.odin). Owned.
	name:               string,
	description:        string,
	icon:               proto.Blob_Id,
	password:           string, // empty: anyone may join
	sessions:           map[proto.Session_Id]^Client, // by local_idx
	max_sessions:       int,
	// Only for tests, which make requests much faster than any client
	// (request_take).
	requests_unlimited: bool,
	gate:               gate.Gate, // which Inits may start a session
	// The connections that are logged in, and those that aren't yet, keyed
	// by their device's key (see Conn).
	conns:              map[[proto.KEY_SIZE]byte]^Conn,
	waiting:            map[[proto.KEY_SIZE]byte]^Conn,
	// Accounts and their devices (accounts.odin), and logging in to them
	// (auth.odin), which uses a separate thread to hash passwords
	// (hash_worker.odin).
	accounts:           Accounts,
	auth:               Auth,
	hasher:             Hash_Worker,
	// The channels and their members (convs.odin). Their messages are
	// stored in the database (messages.odin).
	convs:              Convs,
	// Incremented on every change that clients should be told about. Never
	// 0, which means "nothing acked yet".
	version:            u32,
	// The last user number handed out; numbers are never reused.
	last_num:           proto.User_Num,
	// Files offered in DMs, keyed by the message that offers them, and the
	// transfers being relayed, keyed the same way (files.odin).
	file_offers:        map[proto.Msg_Id]File_Offer,
	file_routes:        map[proto.Msg_Id]^File_Route,
	// The server's persistent storage: its database (db.odin) and the
	// files that belong to it (blobs.odin).
	db:                 DB,
	blobs:              Blob_Store,
	// Files uploaded with messages, including uploads and downloads in
	// progress (attachments.odin).
	attach:             Attachments,
	// The server's custom emoji (emoji.odin).
	emoji:              Custom_Emoji,
	// Deleting old data (retention.odin).
	retention:          Retention,
	// The message kind the loop is currently handling, and how long its
	// iterations take (loop_stats.odin).
	handling:           proto.Message_Kind,
	loop:               Loop_Stats,
	// The server's own email account, if it has one (mail/mail.odin).
	email:              mail.Mailer,
	// Who is allowed to register, and how quickly registrations are
	// accepted (register.odin).
	registration:       Registration_Config,
	register_rate:      proto.Bucket,
	// Deleting registrations whose email addresses weren't verified
	// (verify.odin).
	verify:             Verify_State,
	// Emailing accounts a digest of what they missed (digest.odin).
	digest:             Digest_State,
	// Sends notifications to browsers through their push services (webpush/webpush.odin).
	push:               webpush.Pusher,
	// Screen sharing's own port and thread (media.odin).
	media:              Media,
}

// How long the loop waits for a packet before it runs an iteration anyway.
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
	// The default channels are only created when the database is new.
	if !convs_load(&s.convs, &s.db, []string{DEFAULT_CHANNEL_NAME}, &s.accounts) {
		return false
	}
	defer convs_destroy(&s.convs)
	defer calls_destroy(&s)
	defer gate.destroy(&s.gate)
	db_commit(&s.db)
	if !hash_worker_start(&s.hasher) {
		log.error("could not start the thread that hashes passwords")
		return false
	}
	defer hash_worker_stop(&s.hasher)
	defer auth_destroy(&s.auth)
	mail.open(&s.email, settings.email)
	defer mail.close(&s.email)
	webpush.open(&s.push, settings.push)
	defer webpush.close(&s.push)
	memory_log_open(&s, settings.memory_log)
	loop_stats_open(&s)
	if s.registration.verify_email && !s.email.enabled {
		log.warn(
			"registration requires email verification, but no email is configured, so it is skipped",
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
	// Leave room for packets that arrive while an iteration is busy: a
	// shared screen's keyframe can arrive as hundreds of packets.
	net.set_option(sock, .Receive_Buffer_Size, 4 * 1024 * 1024)
	net.set_option(sock, .Send_Buffer_Size, 4 * 1024 * 1024)
	// Wake up periodically even when idle so that stale sessions get reaped
	// and unacked state gets resent. Wake up more often while old messages
	// are being purged, since that happens a little at a time
	// (retention.odin).
	wait := IDLE_WAIT
	net.set_option(sock, .Receive_Timeout, wait)

	log.infof("listening on udp :%d", port)
	log.infof("server public key: %s", common.public_key_hex(&s.key))
	media_open(&s, settings)
	defer media_close(&s)
	if s.password != "" {
		log.info("clients need the password to join")
	}

	// The work every loop iteration does after handling its packet, in this
	// order.
	syncs := [?]struct {
		phase: Loop_Phase,
		run:   proc(s: ^Server),
	} {
		{.Reap, reap_sessions},
		{.Auth, auth_sync},
		// This runs before the state snapshots, so that a connection that
		// has just logged in learns who everyone is (on its stream) before
		// it learns who is online.
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
		{.Digest, digest_sync},
		{.Push, push_sync},
		{.Media, media_sync},
		{.Exercise, db_exercise},
		{.Memory, memory_sync},
	}

	recv_buf: [proto.MAX_PACKET_SIZE]byte
	for {
		free_all(context.temp_allocator)

		n, from, recv_err := net.recv_udp(sock, recv_buf[:])
		// Start timing the iteration here, so the wait for a packet isn't
		// counted.
		loop_turn_begin(&s)
		s.handling = {}
		// Nothing arrived during the socket's whole wait time: nobody is
		// talking, so slow work can be done without anyone noticing.
		idle := false
		#partial switch recv_err {
		case .None:
			if !common.simulate_loss() {
				handle_packet(&s, recv_buf[:n], from)
			}
		case .Timeout, .Would_Block:
			idle = true
		case .Connection_Refused:
			// An ICMP "port unreachable" for something we sent earlier to a
			// client that went away without sending a Leave (on Windows this
			// shows up as WSAECONNRESET). It doesn't tell us which client it
			// was, so their session just times out as usual.
			log.debug("recv: a client's port is closed")
		case:
			log.errorf("recv error: %v", recv_err)
		}
		loop_mark(&s, .Packet)

		for sync in syncs {
			sync.run(&s)
			loop_mark(&s, sync.phase)
		}
		// Commit everything this iteration wrote in one go.
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

// users_seen_by returns the list of online users as `viewer`'s account should
// see it:
// - Users in a private channel's voice room are only shown in that room to its
//   members. Everyone else sees them in no room (room_hidden).
// - Users who appear offline (`hidden`, by index; activity.odin) are left out,
//   unless they are the viewer's own account or they're in a voice room the
//   viewer can see.
//
// `users` is returned unchanged when nothing differs, otherwise a copy
// allocated with the temp allocator.
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
	// Anything else is silently dropped: never respond to packets we can't
	// authenticate.
}

handle_init :: proc(s: ^Server, packet: []byte, from: net.Endpoint) {
	session_init(s.sock, &s.key, &s.gate, &s.sessions, s.max_sessions, packet, from)
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
		if session_rewelcome_due(c) {
			send_welcome(s, c)
		}
		return
	}

	conn_id, link, result := session_finish(c, &s.gate, s.password, packet, from)
	switch result {
	case .Ok:
	case .Invalid:
		log.debugf("invalid handshake finish from %v", net.to_string(from))
		drop_session(s, idx)
		return
	case .Version:
		refuse(s, c, from, .Version)
		return
	case .Wrong_Password:
		refuse(s, c, from, .Wrong_Password)
		return
	}

	u := conn_of(s, c.peer_key)
	if link == .Bulk {
		bind_bulk(s, c, u, conn_id, from)
		return
	}

	session_keyed(c, &s.gate, from)

	if u != nil && u.conn_id != conn_id && conn_in_use(s, u, from) {
		// A second client with the same key, while the first one is still
		// there. Taking the key over would only make the two of them take it
		// from each other in turn.
		log.infof("%s is already connected, refusing another client", conn_label(u))
		refuse(s, c, from, .Already_Connected)
		return
	}
	if u != nil && u.conn_id != conn_id {
		// This is not a rekey: the client has started over and knows
		// nothing about the old connection. Drop it as if the client had
		// left, and give them a new one.
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

	// A device that has logged in before is logged in automatically by its
	// key, since the handshake just proved that it holds that key.
	if fresh {
		auth_known_device(s, u)
	}
	// The client waits for the Welcome on a new session. Anything that
	// logging in queued for it is sent after this, later in this iteration.
	send_welcome(s, c)
}

// bind_bulk makes a session that has just finished its handshake the bulk
// link (proto.Link) of the device's connection `u`, if the hello refers to
// that connection. Otherwise there's nothing to bind it to (the connection is
// gone, or the main link's handshake hasn't got this far yet), so the client
// is refused and told to try again later.
@(private = "file")
bind_bulk :: proc(s: ^Server, c: ^Client, u: ^Conn, conn_id: u64, from: net.Endpoint) {
	if u == nil || u.conn_id != conn_id {
		refuse(s, c, from, .No_Connection)
		return
	}
	session_keyed(c, &s.gate, from)
	c.bulk = true
	c.conn = u
	supersede(s, c)
	log.debugf("%s has a new bulk link", conn_label(u))
	send_welcome(s, c)
}

// How recently a connection's main link must have been heard from for it to
// count as in use. Clients ping several times this often (at least once a
// second), so a connection that is silent for this long has most likely
// crashed or been closed.
CONN_IN_USE :: 2 * time.Second

// conn_in_use says whether the connection `u` is still being used by a client
// other than the one at `from`: one of its main link's sessions was heard
// from recently, at another address. A client that starts over itself does so
// from the same socket, so it isn't refused.
@(private = "file")
conn_in_use :: proc(s: ^Server, u: ^Conn, from: net.Endpoint) -> bool {
	for _, other in s.sessions {
		if other.conn == u &&
		   !other.bulk &&
		   other.endpoint != from &&
		   time.tick_since(other.last_recv) < CONN_IN_USE {
			return true
		}
	}
	return false
}

// supersede marks the older sessions on the same link as a new session as
// superseded: they're kept to receive packets still in flight, but never
// used for sending.
@(private = "file")
supersede :: proc(s: ^Server, c: ^Client) {
	for _, other in s.sessions {
		if other != c && other.keyed && other.peer_key == c.peer_key && other.bulk == c.bulk {
			other.superseded = true
		}
	}
}

// conn_of returns the connection from the device with this key, whether it
// is logged in or not, or nil if there is none.
conn_of :: proc(s: ^Server, key: [proto.KEY_SIZE]byte) -> ^Conn {
	if u := s.conns[key] or_else nil; u != nil {
		return u
	}
	return s.waiting[key] or_else nil
}

// conn_login logs a connection in to an account. From then on it's one of
// the connections everyone can see, unless its account is Unverified
// (verify.odin). In that case it stays hidden in Server.waiting, and is told
// nothing except its own account details until it's verified. The caller has
// already checked that it is allowed to log in.
conn_login :: proc(s: ^Server, u: ^Conn, acc: ^Account) {
	u.account = acc
	u.stream.max_queue = STREAM_QUEUE_MAX
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

// conn_seen makes a logged in connection visible to everyone, and sends it
// everything a newly logged in connection needs to know.
conn_seen :: proc(s: ^Server, u: ^Conn) {
	acc := u.account
	delete_key(&s.waiting, u.key)
	s.conns[u.key] = u
	bump_version(s)
	log.infof("%s logged in", conn_label(u))
	// The account is online now. Its own sync already says so, so only
	// everyone else needs to be told.
	now := activity_of(acc)
	changed := now != acc.shown
	acc.shown = now
	directory_sync(s, u)
	calls_conn_seen(s, u)
	if changed {
		account_told(s, acc, except = u)
	}
}

// conn_unseen hides a connection from everyone while keeping it logged in,
// because its account has become Unverified (verify.odin). Whatever it was in
// the middle of is ended, as if it had left.
conn_unseen :: proc(s: ^Server, u: ^Conn) {
	calls_conn_gone(s, u)
	drop_conn_transfers(u)
	attachments_conn_gone(s, u)
	delete_key(&s.conns, u.key)
	drop_conn_files(s, u)
	s.waiting[u.key] = u
	u.room, u.flags = 0, {}
	u.acked_version, u.sent_version = 0, 0
	u.last_typing = {}
}

// conn_left detaches a connection from its account, because it disconnected
// or was logged out. Whatever it was in the middle of is ended, and everyone
// else sees it leave.
@(private = "file")
conn_left :: proc(s: ^Server, u: ^Conn) {
	log.infof("%s left", conn_label(u))
	calls_conn_gone(s, u)
	drop_conn_transfers(u)
	attachments_conn_gone(s, u)
	delete_key(&s.conns, u.key)
	// This must happen after it's removed from `conns`, so that only the
	// other side of a transfer is told about it.
	drop_conn_files(s, u)
	acc := u.account
	for other, i in acc.conns {
		if other == u {
			unordered_remove(&acc.conns, i)
			break
		}
	}
	// An account that appears offline was last seen when it disappeared
	// (activity_set), and leaving now mustn't give away that it was here.
	if len(acc.conns) == 0 && !appears_offline(acc) {
		account_seen(&s.accounts, acc)
	}
	u.account = nil
	u.idle = false
	u.hidden = false
	activity_check(s, acc)
	bump_version(s)
}

// conn_logout logs a connection out of its account without closing the
// connection, so it's back to only being able to log in. A `reason` means the
// logout wasn't requested by the client, and the client is told why.
conn_logout :: proc(s: ^Server, u: ^Conn, reason: proto.Logout_Reason = {}) {
	if u.account == nil {
		return
	}
	conn_left(s, u)
	// Reset it to a fresh state for whoever logs in on it next.
	u.room, u.flags = 0, {}
	u.acked_version, u.sent_version = 0, 0
	u.last_typing = {}
	s.waiting[u.key] = u
	if reason != {} {
		body := [1]u8{u8(reason)}
		send_event(u, .Logged_Out, body[:])
	}
}

// How many copies of a Welcome are sent, since it's sent unreliably (like
// Refused).
@(private = "file")
WELCOME_COPIES :: 3

// send_welcome tells a client whose hello was accepted which connection
// its new session belongs to (see proto/hello.odin).
@(private = "file")
send_welcome :: proc(s: ^Server, c: ^Client) {
	buf: [proto.WELCOME_SIZE]u8
	msg := proto.encode_welcome(&buf, c.conn.instance, c.conn.account != nil)
	for _ in 0 ..< WELCOME_COPIES {
		send_message(s, c, msg)
	}
}

// refuse tells a client that just finished its handshake why it can't join,
// using the session created by that handshake, and then drops the session.
// The client never gets a connection, so nobody else ever hears about it.
@(private = "file")
refuse :: proc(s: ^Server, c: ^Client, from: net.Endpoint, reason: proto.Refusal) {
	log.infof("refused %08x from %v: %v", common.key_id(c.peer_key), net.to_string(from), reason)
	session_refuse(s.sock, c, from, reason)
	drop_session(s, c.local_idx)
}

handle_data :: proc(s: ^Server, packet: []byte, from: net.Endpoint) {
	c := s.sessions[proto.receiver_index(packet)] or_else nil
	if c == nil || !c.keyed {
		return
	}

	pt_buf: [proto.MAX_PACKET_SIZE]byte
	pt, ok := session_receive(c, packet, from, pt_buf[:], follow = c.conn.account != nil)
	if !ok {
		return
	}
	if session_confirm(c) {
		retire_superseded(s, c)
	}

	kind, kind_ok := proto.message_kind(pt)
	if !kind_ok {
		return // keepalive, or malformed
	}
	s.handling = kind
	if c.conn.account == nil || .Unverified in c.conn.account.flags {
		// Not logged in: only allow what's needed to stay connected and to
		// log in, which happens over the stream (rpc.odin applies the same
		// check to requests sent there).
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
	case .Sound:
		sound_set(s, c.conn, proto.decode_sound(pt))
	case .Blob_Chunk:
		handle_blob_chunk(s, c, pt)
	case .Blob_Need:
		handle_blob_need(s, c.conn, pt)
	case .Typing:
		if len(pt) == proto.TYPING_UP_SIZE {
			handle_typing(s, c.conn, pt)
		}
	case .Ping:
		// Reply on the session the ping came in on, so the client measures
		// the round trip of the same path.
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
	case .State, .Refused, .Keyframe, .Demand, .Pong, .Welcome, .Upload_Ack, .Download_Chunk:
	// Server-to-client only.
	case .Video, .Watch, .Nack, .Report:
	// Screen sharing only uses the media link (media.odin).
	case .Stream:
		handle_stream(s, c.conn, pt)
	case .Stream_Ack:
		proto.stream_acked(&c.conn.stream, pt)
	}
}

// send_message sends a message on a session of `c`'s connection. Heavy
// messages (proto.HEAVY_KINDS) go out on the connection's bulk link if it has
// one; everything else is sent on `c`.
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

// conn_name returns the display name of a connection's account, or "" if
// the connection isn't logged in.
conn_name :: proc(u: ^Conn) -> string {
	return u.account.display if u.account != nil else ""
}

// conn_label returns how logs refer to a connection: its account's username,
// if it has one, and its device's key id.
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

// sound_set takes the flags a client sent in Sound. In_Voice and In_Call
// there mean that it is talking on another server; presence_list decides
// what is shown. A call is the one shown if it claims both.
sound_set :: proc(s: ^Server, u: ^Conn, flags: proto.User_Flags) {
	flags := flags
	if .In_Call in flags {
		flags -= {.In_Voice}
	}
	if .Camera in flags && .Camera not_in u.flags && !camera_allowed(s, u) {
		flags -= {.Camera}
	}
	if flags != u.flags {
		u.flags = flags
		log.debugf("%s sound state %v", conn_label(u), flags)
		bump_version(s)
	}
}

// camera_allowed tells whether a connection may turn its camera on (see
// proto.Video_Stream): only in a room, and in a channel's room only while fewer
// than the server's max_cameras others have theirs on. A call's room only ever
// has the two of them. Without the media link there are no cameras at all.
camera_allowed :: proc(s: ^Server, u: ^Conn) -> bool {
	if !s.media.enabled || s.media.max_cameras == 0 || u.room == 0 {
		return false
	}
	if proto.room_call(u.room) != 0 {
		return true
	}
	on := 0
	for _, other in s.conns {
		if other != u && other.room == u.room && .Camera in other.flags {
			on += 1
		}
	}
	return on < s.media.max_cameras
}

// presence_list returns the list of online users and their rooms, which is
// the same for everyone, except for users who appear offline (activity.odin):
// those are only visible to their own account, or to anyone who can see the
// voice room they're in (`hidden`, by index; see users_seen_by). Both are
// allocated with the temp allocator.
presence_list :: proc(s: ^Server) -> (users: []proto.User_Info, hidden: []bool) {
	users = make([]proto.User_Info, len(s.conns), context.temp_allocator)
	hidden = make([]bool, len(s.conns), context.temp_allocator)
	next_user := 0
	for _, u in s.conns {
		flags := u.flags - proto.TALKING
		switch {
		case u.account.voice_hidden:
		case u.room != 0:
			// Everyone may know that they are busy talking, even those who
			// may not know where (room_hidden).
			flags += {.In_Call} if proto.room_call(u.room) != 0 else {.In_Voice}
		case:
			// Talking on another server, as their client says.
			flags += u.flags & proto.TALKING
		}
		users[next_user] = {
			num     = u.num,
			account = u.account.id,
			flags   = flags,
			room    = u.room,
		}
		hidden[next_user] = appears_offline(u.account)
		next_user += 1
	}
	return
}

// How often a connection is sent a snapshot at most. Every change of
// anyone's sound flags, voice room or activity makes a new one, which goes to
// everyone, so without this a client that toggles its flags as fast as it
// can send packets would make the server send that many snapshots to each
// connection. Changes that come closer together than this go out together.
STATE_EVERY :: 50 * time.Millisecond

// sync_state sends the current snapshot to every user who hasn't acked
// it: soon after a change (at most every STATE_EVERY), then every
// CONTROL_RESEND until acked.
sync_state :: proc(s: ^Server) {
	now := time.tick_now()
	needs_state :: proc(s: ^Server, u: ^Conn, now: time.Tick) -> bool {
		since := time.tick_diff(u.last_state_sent, now)
		return(
			u.acked_version != s.version &&
			(u.sent_version != s.version && since >= STATE_EVERY ||
					since >= proto.CONTROL_RESEND) \
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

	users, hidden := presence_list(s)

	body_buf: [proto.MAX_STATE_SIZE]byte
	for _, u in s.conns {
		if !needs_state(s, u, now) {
			continue
		}
		c := sending_session(s, u)
		if c == nil {
			continue
		}
		// A private channel's voice room is only shown to its members.
		// Everyone else sees the users in it as being in no room
		// (room_hidden).
		shown := users_seen_by(s, users, hidden, u.account.id)
		state := proto.Presence {
			your_user = u.num,
			users     = shown,
		}
		body, ok := proto.encode_state(state, body_buf[:])
		if !ok {
			log.errorf("the list of online users doesn't fit in %d bytes", proto.MAX_STATE_SIZE)
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
// link, or nil if it has none.
bulk_session :: proc(s: ^Server, u: ^Conn) -> ^Client {
	for _, c in s.sessions {
		if c.conn == u && c.keyed && !c.superseded && c.bulk {
			return c
		}
	}
	return nil
}

// relay_voice forwards a voice frame to everyone else in the speaker's
// room, re-encrypted for each recipient's newest session. Voice from
// someone who isn't in a room is not sent to anyone.
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

// retire_superseded drops the sessions a client's new session replaced,
// since they're no longer needed once the client is using the new one.
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

// drop_conn ends every session of a connection. Ending the last one also
// ends the connection itself.
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
	drop_departed_browsers(s)
	stale := make([dynamic]proto.Session_Id, context.temp_allocator)
	for idx, c in s.sessions {
		if session_expired(c) {
			append(&stale, idx)
		}
	}
	for idx in stale {
		drop_session(s, idx)
	}
}

// drop_session ends a session. It does nothing if the session is already
// gone (e.g. a bulk session dropped along with its connection's main link).
drop_session :: proc(s: ^Server, idx: proto.Session_Id) {
	c := s.sessions[idx] or_else nil
	if c == nil {
		return
	}
	delete_key(&s.sessions, idx)
	session_release(&s.gate, c)

	if u := c.conn; u != nil && !c.bulk {
		u.sessions -= 1
		if u.sessions == 0 {
			// Drop the connection's bulk link too, before it's freed.
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

	free(c)
}

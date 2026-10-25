package lite

import "core:crypto"
import "core:crypto/ecdh"
import "core:log"
import "core:net"
import "core:slice"
import "core:strings"
import "core:time"

import "common:proto"

// A headless client: a single connection to a server without UI, audio or
// rendering, for use by programs such as the bot API's gateway
// (docs/bot-api) and yap-stress. It does everything a client has to do for
// the server to accept it as one: the handshake and its sessions, rekeys,
// the stream for requests and events, pings, logging in and acknowledging
// snapshots. When the server starts a new connection for it (because the
// server restarted or had given up on the client), the client starts over
// on that connection. When the server goes quiet, the client handshakes
// again.
//
// It has no thread of its own. Its owner calls receive when the socket has
// data (or simply often) and calls step every few milliseconds, all from one
// thread, which any number of clients can share. Results are handed to the
// owner's procedures (Handlers) on that thread, from inside those calls:
//
// - a request's answer, passed to the `done` it was given. This is the
//   server's response, or Status.Reset if the connection started over,
//   failed or was closed first. Each request accepted by `request` gets
//   exactly one answer.
// - the events, as they come off the stream: Sync_Begin..Sync_End after
//   every login, which describes the current state (anything known about
//   the connection before is void), followed by changes after that.
// - who is online: each snapshot, once logged in and synced.
// - any other message the server sends (voice, typing, transfers), passed
//   on unchanged.
// - the phase, whenever it changes. Failed is permanent and gives the
//   reason.
//
// Bodies handed to the handlers are only valid during the call, and a
// handler must not close the client it is called for.
//
// This only uses the main link (proto.Link). Without a bulk link, the
// server sends heavy messages on the main link too.

// Pings measure the round trip time (used for the stream's resends) and
// make the server answer, so that a quiet server is noticed
// (proto.SERVER_SILENT).
PING_INTERVAL :: time.Second
// If nothing comes from the server for this long, we give up on it.
CONNECTION_LOST :: 30 * time.Second
// How long to wait before retrying a login that was rejected for now
// (Rate_Limited, Internal).
LOGIN_RETRY :: time.Second

Phase :: enum {
	Connecting, // handshaking to establish a connection
	Logging_In, // the login request is sent; waiting for the answer
	Syncing, // logged in; the server is sending everything
	// Everything has been sent; changes arrive as events. A guest is Ready
	// as soon as it's connected.
	Ready,
	Failed, // permanent; Client.failure gives the reason
}

Failure :: enum {
	None,
	// The server refused the connection (see Client.refusal).
	Refused,
	// The server's key isn't the one we were told to expect.
	Wrong_Server_Key,
	// The key isn't a device the server knows, and there's no password to
	// log in with.
	Not_Logged_In,
	// The password login was rejected (see Client.login_status).
	Login_Failed,
	// The device was logged out (see Client.logout_reason), for example
	// because it was revoked, the password changed or the account was
	// disabled or deleted.
	Logged_Out,
	// Nothing was received from the server for CONNECTION_LOST.
	Lost,
}

// Answer is what a request's `done` is called with.
Answer :: struct {
	op:     proto.Request_Op,
	status: proto.Status,
	body:   []u8,
	tag:    u64, // the tag that was passed to request
	took:   time.Duration,
}

Request_Done :: #type proc(c: ^Client, a: Answer)

// Handlers are the owner's callbacks. Any of them may be nil.
Handlers :: struct {
	phase:   proc(c: ^Client, phase: Phase),
	event:   proc(c: ^Client, op: proto.Event_Op, body: []u8),
	state:   proc(c: ^Client, state: proto.Presence),
	message: proc(c: ^Client, kind: proto.Message_Kind, pt: []u8),
}

Options :: struct {
	server:         net.Endpoint,
	// The key the server must have; all zeroes accepts any key.
	server_key:     [proto.KEY_SIZE]u8,
	password:       string, // the server's password, if it has one
	// The credentials to log in with when our key isn't a device of an
	// account yet. Without a username, the key must already be one.
	username:       string,
	login_password: string,
	device:         string, // the device's name in the account's device list
	agent:          string,
	// How many times a login that was rejected for now (Rate_Limited,
	// Internal) is retried before giving up.
	login_retries:  int,
	// Stay connected without logging in, which allows the requests that
	// work before logging in (Server_Info, Server_Icon, Register), even
	// with a key that isn't a device.
	guest:          bool,
	name:           string, // used in log messages
	handlers:       Handlers,
	user:           rawptr, // for the owner's own use
}

Client :: struct {
	opt:           Options, // the strings in it are owned by the client
	key:           ecdh.Private_Key,
	public_key:    [proto.KEY_SIZE]u8,
	sock:          net.UDP_Socket,
	phase:         Phase,
	failure:       Failure,
	refusal:       proto.Refusal,
	login_status:  proto.Status,
	logout_reason: proto.Logout_Reason,
	// Identifies the connection (see the hello and Welcome in
	// proto/hello.odin): conn_id is ours and stays the same in every
	// handshake, instance is the server's id for the connection.
	conn_id:       u64,
	instance:      u64,
	has_instance:  bool,
	// We gave up on the connection and are handshaking for a new one with a
	// new conn_id, until its Welcome arrives.
	restart:       bool,

	// The handshake and sessions, managed as the client does (proto.Initiator_Link).
	using link:    proto.Initiator_Link,
	last_sent:     time.Tick,
	login_at:      time.Tick, // when to retry the login; 0 for never
	login_tries:   int,
	stream:        proto.Stream,
	last_id:       u32,
	asked:         map[u32]Asked,
	ping_id:       u32,
	ping_sent:     time.Tick,
	rtt:           time.Duration, // smoothed; 0 until the first pong
	// Snapshots: the one being assembled and the version of the last one
	// received.
	assembler:     ^proto.State_Assembler,
	state_version: u32,
	has_state:     bool,
}

// Asked is a request that is waiting for its answer.
@(private)
Asked :: struct {
	op:   proto.Request_Op,
	done: Request_Done,
	tag:  u64,
	sent: time.Tick,
}

// open creates a client that connects with `key`, a device's private key
// (a bot's token is one: see proto.bot_token_parse). It doesn't wait for
// the server; the handshake happens in step.
open :: proc(c: ^Client, key: ^ecdh.Private_Key, opt: Options) -> bool {
	family := net.family_from_address(opt.server.address)
	sock, err := net.make_bound_udp_socket(net.IP6_Any if family == .IP6 else net.IP4_Any, 0)
	if err != nil {
		log.errorf("%s: no socket: %v", opt.name, err)
		return false
	}
	net.set_blocking(sock, false)
	// Leave room for what a busy server sends between two reads.
	net.set_option(sock, .Receive_Buffer_Size, 1024 * 1024)
	c^ = {
		opt   = opt,
		key   = key^,
		sock  = sock,
		phase = .Connecting,
	}
	o := &c.opt
	o.password = strings.clone(opt.password)
	o.username = strings.clone(opt.username)
	o.login_password = strings.clone(opt.login_password)
	o.device = strings.clone(opt.device)
	o.agent = strings.clone(opt.agent)
	o.name = strings.clone(opt.name)
	ecdh.private_key_public_bytes(&c.key, c.public_key[:])
	crypto.rand_bytes(([^]byte)(&c.conn_id)[:size_of(c.conn_id)])
	c.stream.max_queue = proto.STREAM_CLIENT_QUEUE
	c.assembler = new(proto.State_Assembler)
	c.last_recv = time.tick_now()
	return true
}

// close says goodbye to the server and frees the client. Requests that are
// still waiting are answered with Reset. Closing a client that is already
// closed does nothing.
close :: proc(c: ^Client) {
	if c.assembler == nil {
		return
	}
	leave(c)
	answer_all(c, .Reset)
	net.close(c.sock)
	ecdh.private_key_clear(&c.key)
	proto.stream_destroy(&c.stream)
	delete(c.asked)
	free(c.assembler)
	o := &c.opt
	crypto.zero_explicit(raw_data(o.login_password), len(o.login_password))
	delete(o.password)
	delete(o.username)
	delete(o.login_password)
	delete(o.device)
	delete(o.agent)
	delete(o.name)
	c^ = {}
}

// receive handles all packets that have arrived and returns whether there
// were any.
receive :: proc(c: ^Client) -> (got: bool) {
	recv_buf: [proto.MAX_PACKET_SIZE]u8
	for c.phase != .Failed {
		n, _, err := net.recv_udp(c.sock, recv_buf[:])
		if err != nil || n == 0 {
			break
		}
		got = true
		handle_packet(c, recv_buf[:n])
	}
	return
}

// step does whatever is due: handshakes, the login, pings and the stream.
step :: proc(c: ^Client, now: time.Tick) {
	if c.phase == .Failed {
		return
	}
	if time.tick_diff(c.last_recv, now) > CONNECTION_LOST {
		log.warnf("%s: nothing from the server for %v, giving up", c.opt.name, CONNECTION_LOST)
		fail(c, .Lost)
		return
	}
	if c.phase == .Logging_In && c.login_at != {} && time.tick_diff(c.login_at, now) >= 0 {
		c.login_at = {}
		login(c)
	}
	drive_handshake(c, now)
	if !c.has_current {
		return
	}
	if c.has_instance && time.tick_diff(c.ping_sent, now) >= PING_INTERVAL {
		c.ping_id += 1
		c.ping_sent = now
		ping_buf: [proto.PING_SIZE]u8
		send(c, proto.encode_ping(&ping_buf, .Ping, c.ping_id))
	}
	stream_step(c, now)
	if time.tick_diff(c.last_sent, now) >= proto.KEEPALIVE_AFTER {
		send(c, nil)
	}
}

// request sends the server a request for `op`. `done`, if given, is called
// with the result. It returns false if the request couldn't be sent
// (because there is no connection yet or a new one is being established),
// in which case `done` is never called. Otherwise `done` is called once.
request :: proc(
	c: ^Client,
	op: proto.Request_Op,
	body: []u8 = nil,
	done: Request_Done = nil,
	tag: u64 = 0,
) -> bool {
	if !c.has_instance || c.restart || c.phase == .Failed {
		return false
	}
	msg := proto.encode_request(c.last_id + 1, op, body)
	if msg == nil {
		log.errorf("%s: a %v request of %d bytes doesn't fit", c.opt.name, op, len(body))
		return false
	}
	if !proto.stream_send(&c.stream, msg) {
		// More is queued than the server can ever catch up with, so the
		// connection is as good as gone. Starting a new one resets
		// everything.
		log.warnf("%s: the stream is backed up, starting the connection over", c.opt.name)
		restart(c)
		return false
	}
	c.last_id += 1
	c.asked[c.last_id] = {op, done, tag, time.tick_now()}
	return true
}

// send sends an unreliable datagram (typing, voice) on the connection. It
// does nothing until a connection exists.
send :: proc(c: ^Client, pt: []u8) -> bool {
	if !c.has_current {
		return false
	}
	pkt_buf: [proto.MAX_PACKET_SIZE]u8
	pkt, ok := proto.seal(&c.current, pt, pkt_buf[:])
	if !ok {
		return false
	}
	c.last_sent = time.tick_now()
	_, err := net.send_udp(c.sock, pkt, c.opt.server)
	return err == nil
}

// restart gives up on the current connection and handshakes for a new one
// with a new conn_id, which the server treats as the client starting over
// (see proto/hello.odin). Waiting requests are answered with Reset once the
// new connection exists, and the server sends everything again.
restart :: proc(c: ^Client) {
	if c.restart || c.phase == .Failed {
		return
	}
	crypto.rand_bytes(([^]byte)(&c.conn_id)[:size_of(c.conn_id)])
	// A handshake in progress would still use the old conn_id.
	proto.link_abandon(&c.link)
	c.restart = true
	set_phase(c, .Connecting)
}

// forget_login wipes the username and password that were given to log in
// with. Once logged in, the key is a device and is enough on its own. If the
// server stops knowing the device, the client fails (Not_Logged_In) instead
// of logging in again.
forget_login :: proc(c: ^Client) {
	o := &c.opt
	crypto.zero_explicit(raw_data(o.login_password), len(o.login_password))
	delete(o.login_password)
	delete(o.username)
	o.login_password, o.username = "", ""
}

// ready returns whether requests can be made and the answers concern a
// logged-in account that has been sent everything.
ready :: proc(c: ^Client) -> bool {
	return c.phase == .Ready && !c.restart
}

@(private)
set_phase :: proc(c: ^Client, phase: Phase) {
	if c.phase == phase {
		return
	}
	c.phase = phase
	if c.opt.handlers.phase != nil {
		c.opt.handlers.phase(c, phase)
	}
}

// fail gives up permanently and tells the server.
@(private)
fail :: proc(c: ^Client, why: Failure) {
	if c.phase == .Failed {
		return
	}
	leave(c)
	c.failure = why
	answer_all(c, .Reset)
	set_phase(c, .Failed)
}

// leave says goodbye if there is a connection to say it on, and then
// forgets the sessions.
@(private)
leave :: proc(c: ^Client) {
	if c.has_current {
		// The datagram is unreliable, so send it a few times. Otherwise the
		// server only notices after a timeout.
		bye := [1]u8{u8(proto.Message_Kind.Leave)}
		for _ in 0 ..< 3 {
			send(c, bye[:])
		}
	}
	proto.link_reset(&c.link)
	c.has_instance = false
}

// answer_all answers every request that is still waiting with `status`, in
// the order they were sent, because their connection is gone.
@(private)
answer_all :: proc(c: ^Client, status: proto.Status) {
	if len(c.asked) == 0 {
		return
	}
	// Iterate over a copy because a `done` may send new requests.
	ids, _ := slice.map_keys(c.asked, context.temp_allocator)
	slice.sort(ids)
	waiting := make([]Asked, len(ids), context.temp_allocator)
	for id, i in ids {
		waiting[i] = c.asked[id]
	}
	clear(&c.asked)
	for a in waiting {
		if a.done != nil {
			a.done(c, {op = a.op, status = status, tag = a.tag, took = time.tick_since(a.sent)})
		}
	}
}

// drive_handshake starts a handshake when there is no session, when the
// current session is due for a rekey, when the server has gone quiet (it may
// have restarted and know nothing about the session) or when we are starting
// over. It also resends a stalled handshake or starts it over.
@(private)
drive_handshake :: proc(c: ^Client, now: time.Tick) {
	s := proto.link_step(&c.link, &c.key, now, restart = c.restart)
	if s.expired {
		log.warnf("%s: the session expired without a rekey", c.opt.name)
	}
	if s.silent {
		log.warnf("%s: nothing from the server for a while, connecting again", c.opt.name)
	}
	if s.packet != nil {
		net.send_udp(c.sock, s.packet, c.opt.server)
	}
}

@(private)
handle_packet :: proc(c: ^Client, packet: []u8) {
	#partial switch proto.packet_type(packet) {
	case .Handshake_Cookie:
		// The server is busy: the Init goes again, with the cookie.
		if resend, ok := proto.link_cookie(&c.link, packet); ok {
			net.send_udp(c.sock, resend, c.opt.server)
		}
	case .Handshake_Resp:
		server_key, resp_ok := proto.link_resp(&c.link, packet)
		if !resp_ok {
			return
		}
		if c.opt.server_key != {} && server_key != c.opt.server_key {
			log.warnf("%s: the server's key isn't the one expected", c.opt.name)
			proto.link_abandon(&c.link)
			fail(c, .Wrong_Server_Key)
			return
		}
		hello_buf: [proto.HELLO_MAX_SIZE]u8
		hello := proto.encode_hello(&hello_buf, c.conn_id, c.opt.password)
		finish, ok := proto.link_finish(&c.link, hello)
		if !ok {
			return
		}
		net.send_udp(c.sock, finish, c.opt.server)

	case .Data:
		pt_buf: [proto.MAX_PACKET_SIZE]u8
		pt, pending, ok := proto.link_open(&c.link, packet, pt_buf[:])
		if !ok {
			return
		}
		kind, kind_ok := proto.message_kind(pt)
		if pending {
			// This is the answer to our hello: either the Welcome or the
			// reason we aren't welcome. Nothing else counts until one of
			// them arrives.
			if kind_ok && kind == .Refused {
				c.refusal = proto.decode_refused(pt)
				log.warnf("%s: the server refused us: %v", c.opt.name, c.refusal)
				proto.link_abandon(&c.link)
				fail(c, .Refused)
				return
			}
			if !kind_ok || kind != .Welcome {
				return
			}
			proto.link_promote(&c.link)
		}
		if kind_ok {
			handle_message(c, kind, pt)
		}
	}
}

@(private)
handle_message :: proc(c: ^Client, kind: proto.Message_Kind, pt: []u8) {
	#partial switch kind {
	case .Welcome:
		handle_welcome(c, pt)
	case .Refused, .Leave:
	case .Stream:
		if c.restart || !c.has_instance {
			return
		}
		if err := proto.stream_receive(&c.stream, pt); err != .None {
			log.warnf("%s: the server broke the stream (%v), starting over", c.opt.name, err)
			restart(c)
			return
		}
		for c.has_instance && !c.restart && c.phase != .Failed {
			msg := proto.stream_next(&c.stream) or_break
			handle_app(c, msg)
		}
	case .Stream_Ack:
		proto.stream_acked(&c.stream, pt)
	case .State:
		handle_state(c, pt)
	case .Pong:
		if proto.decode_ping(pt) == c.ping_id {
			took := time.tick_since(c.ping_sent)
			c.rtt = took if c.rtt == 0 else (7 * c.rtt + took) / 8
		}
	case:
		if c.opt.handlers.message != nil {
			c.opt.handlers.message(c, kind, pt)
		}
	}
}

// handle_welcome handles the server's Welcome. After a rekey it names the
// connection we already have, and nothing changes. Any other Welcome
// announces a new connection (our first, or because the server restarted,
// gave up on us or we started over), and whatever was in transit on the old
// one is lost.
@(private)
handle_welcome :: proc(c: ^Client, pt: []u8) {
	instance, logged_in := proto.decode_welcome(pt)
	if c.has_instance && instance == c.instance {
		return
	}
	if c.has_instance {
		log.infof("%s: the server started a new connection for us", c.opt.name)
	}
	c.instance, c.has_instance = instance, true
	c.restart = false
	if c.has_previous {
		proto.session_reset(&c.previous)
		c.has_previous = false
	}
	proto.stream_reset(&c.stream)
	c.stream.max_queue = proto.STREAM_CLIENT_QUEUE
	c.has_state = false
	c.assembler^ = {}
	c.login_at, c.login_tries = {}, 0
	// This happens before the phase changes, because whoever is notified
	// of the change may send new requests on this connection.
	answer_all(c, .Reset)
	switch {
	case logged_in:
		set_phase(c, .Syncing)
	case c.opt.guest:
		set_phase(c, .Ready)
	case c.opt.username != "":
		set_phase(c, .Logging_In)
		login(c)
	case:
		log.warnf("%s: the key is no device the server knows", c.opt.name)
		fail(c, .Not_Logged_In)
	}
}

@(private)
login :: proc(c: ^Client) {
	buf: [proto.ACCOUNT_BODY_MAX]u8
	body := proto.encode_auth_login(
		buf[:],
		c.opt.username,
		c.opt.login_password,
		c.opt.device,
		c.opt.agent,
	)
	defer crypto.zero_explicit(&buf, size_of(buf))
	request(c, .Auth_Login, body, login_done)
}

@(private)
login_done :: proc(c: ^Client, a: Answer) {
	#partial switch a.status {
	case .Ok:
		set_phase(c, .Syncing)
	case .Reset:
	// Lost along with its connection; the next connection logs in again.
	case .Rate_Limited, .Internal:
		if c.login_tries < c.opt.login_retries {
			c.login_tries += 1
			c.login_at = time.tick_add(time.tick_now(), LOGIN_RETRY)
			return
		}
		fallthrough
	case:
		log.warnf("%s: can't log in as %s: %v", c.opt.name, c.opt.username, a.status)
		c.login_status = a.status
		fail(c, .Login_Failed)
	}
}

// handle_app takes one message off the stream.
@(private)
handle_app :: proc(c: ^Client, msg: []u8) {
	kind, ok := proto.app_kind(msg)
	if !ok {
		return // from a server that is newer than this client
	}
	#partial switch kind {
	case .Response:
		id, status, body := proto.decode_response(msg)
		a, waiting := c.asked[id]
		if !waiting {
			return
		}
		delete_key(&c.asked, id)
		if a.done != nil {
			a.done(c, {a.op, status, body, a.tag, time.tick_since(a.sent)})
		}
	case .Event:
		op, body := proto.decode_event(msg)
		#partial switch op {
		case .Sync_Begin:
			if c.phase == .Ready {
				set_phase(c, .Syncing)
			}
		case .Logged_Out:
			c.logout_reason, _ = proto.decode_logged_out(body)
			log.warnf("%s: logged out: %v", c.opt.name, c.logout_reason)
		}
		if c.opt.handlers.event != nil {
			c.opt.handlers.event(c, op, body)
		}
		#partial switch op {
		case .Sync_End:
			if c.phase == .Syncing {
				set_phase(c, .Ready)
			}
		case .Logged_Out:
			fail(c, .Logged_Out)
		}
	}
}

// handle_state takes one part of a snapshot. Once all parts have arrived it
// acks the snapshot and hands it on. The list of who is online only makes
// sense once we know who everyone is, so a snapshot that arrives earlier is
// left unacked and will be sent again.
@(private)
handle_state :: proc(c: ^Client, pt: []u8) {
	if c.phase != .Ready {
		return
	}
	version := proto.state_message_version(pt)
	if c.has_state && !proto.serial_newer(version, c.state_version) {
		// The server sent it again because our ack got lost or there was a
		// rekey.
		if version == c.state_version {
			ack_buf: [proto.STATE_ACK_SIZE]u8
			send(c, proto.encode_state_ack(&ack_buf, version))
		}
		return
	}
	v, body, complete := proto.assembler_add(
		c.assembler,
		pt,
		c.state_version if c.has_state else 0,
	)
	if !complete {
		return
	}
	users := make([]proto.User_Info, len(body) / proto.USER_SIZE + 1, context.temp_allocator)
	state, ok := proto.decode_state(body, users)
	if !ok {
		log.warnf("%s: an invalid snapshot from the server", c.opt.name)
		return
	}
	c.state_version, c.has_state = v, true
	ack_buf: [proto.STATE_ACK_SIZE]u8
	send(c, proto.encode_state_ack(&ack_buf, v))
	if c.opt.handlers.state != nil {
		c.opt.handlers.state(c, state)
	}
}

// stream_step sends what the stream needs to send: an ack for what has
// arrived, then new frames and frames due for a resend, as far as the pacing
// allows.
@(private)
stream_step :: proc(c: ^Client, now: time.Tick) {
	if !c.has_instance || c.restart {
		return
	}
	send_frame :: proc(data: rawptr, msg: []u8) {
		send((^Client)(data), msg)
	}
	proto.stream_pace(&c.stream, now, proto.stream_resend_for(c.rtt), send_frame, c)
}

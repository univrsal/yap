package lite

import "core:crypto"
import "core:crypto/ecdh"
import "core:log"
import "core:net"
import "core:slice"
import "core:strings"
import "core:time"

import "common:proto"

/*
A headless client: one connection to a server without UI, audio or
rendering, for programs - the bot API's gateway (docs/bot-api) and
yap-stress. It does what a client has to for the server to take it for
one: the handshake and its sessions, rekeys, the stream for requests and
events, pings, logging in, and the snapshots acked. When the server
starts a new connection for it (it restarted, or had given up on us) it
starts over with it, and when the server goes quiet it handshakes again.

It has no thread of its own. Its owner calls receive when the socket has
something (or just often) and step every few milliseconds, from one
thread, which any number of clients can share. What happens is handed to
the owner's procedures (Handlers) on that thread, from inside those
calls:

- a request's answer, to the `done` it was given: the server's response,
  or Status.Reset if the connection started over first, failed or was
  closed. Exactly one for each request that `request` took;
- the events, as they come off the stream: Sync_Begin..Sync_End after
  every login, which is how things are now (what was known of the
  connection before is void), and changes after that;
- who is here: each snapshot, once logged in and synced;
- whatever else the server sends (voice, typing, transfers) as it is;
- the phase, whenever it changes. Failed is for good, and says why.

Bodies handed to them are only valid during the call, and a handler
mustn't close the client it's called for.

Only the main link (proto.Link): with no bulk link, the server sends
heavy messages on it too.
*/

// Pacing the stream as the client does (client/conn/stream.odin).
STREAM_QUEUE_MAX :: 1024 * 1024
STREAM_RATE :: 256 * 1024
STREAM_BURST :: 32 * 1024
STREAM_RESEND_MOST :: time.Second
// Pings: what the round trip is, for the stream's resends, and what the
// server answers, so a quiet server is noticed (proto.SERVER_SILENT).
PING_INTERVAL :: time.Second
// Nothing from the server for this long, and we give up on it.
CONNECTION_LOST :: 30 * time.Second
// How long a login turned down for now (Rate_Limited, Internal) waits
// to ask again.
LOGIN_RETRY :: time.Second

Phase :: enum {
	Connecting, // handshaking for a connection
	Logging_In, // asked to, with the password, and waiting
	Syncing, // logged in, and being told everything
	// Told everything; changes come as events. A guest is Ready as soon
	// as it's connected.
	Ready,
	Failed, // for good: Client.failure says why
}

Failure :: enum {
	None,
	// The server won't have us (Client.refusal).
	Refused,
	// Its key isn't the one we were told to expect.
	Wrong_Server_Key,
	// The key isn't a device the server knows, and there's no password
	// to log in with.
	Not_Logged_In,
	// The password login was turned down (Client.login_status).
	Login_Failed,
	// The device was logged out (Client.logout_reason): revoked, the
	// password changed, the account disabled or deleted.
	Logged_Out,
	// Nothing came from the server for CONNECTION_LOST.
	Lost,
}

// What a request's `done` is told.
Answer :: struct {
	op:     proto.Request_Op,
	status: proto.Status,
	body:   []u8,
	tag:    u64, // as given to request
	took:   time.Duration,
}

Request_Done :: #type proc(c: ^Client, a: Answer)

// What the owner hears; any may be nil.
Handlers :: struct {
	phase:   proc(c: ^Client, phase: Phase),
	event:   proc(c: ^Client, op: proto.Event_Op, body: []u8),
	state:   proc(c: ^Client, state: proto.Presence),
	message: proc(c: ^Client, kind: proto.Message_Kind, pt: []u8),
}

Options :: struct {
	server:         net.Endpoint,
	// The key the server must have; all zero for whichever it has.
	server_key:     [proto.KEY_SIZE]u8,
	password:       string, // the server's, if it has one
	// What to log in with when our key isn't a device of an account yet;
	// with no username, it has to be one already.
	username:       string,
	login_password: string,
	device:         string, // what the device is called in the account's list
	agent:          string,
	// How many times a login turned down for now (Rate_Limited,
	// Internal) is asked again before giving up.
	login_retries:  int,
	// Stay connected without logging in, for what may be asked before
	// (Server_Info, Server_Icon, Register): with a key that's no device.
	guest:          bool,
	name:           string, // for the log
	handlers:       Handlers,
	user:           rawptr, // the owner's
}

Client :: struct {
	opt:           Options, // its strings owned
	key:           ecdh.Private_Key,
	public_key:    [proto.KEY_SIZE]u8,
	sock:          net.UDP_Socket,
	phase:         Phase,
	failure:       Failure,
	refusal:       proto.Refusal,
	login_status:  proto.Status,
	logout_reason: proto.Logout_Reason,
	// Which connection this is (see the hello and Welcome in
	// proto/names.odin): ours, the same in every handshake, and the
	// server's for it.
	conn_id:       u64,
	instance:      u64,
	has_instance:  bool,
	// Given up on the connection, and handshaking for a new one under a
	// new conn_id, until its Welcome.
	restart:       bool,

	// The sessions, as the client keeps them (client/conn/client.odin).
	handshake:     proto.Initiator,
	pending:       proto.Session,
	current:       proto.Session,
	previous:      proto.Session,
	has_pending:   bool,
	has_current:   bool,
	has_previous:  bool,
	last_sent:     time.Tick,
	last_recv:     time.Tick,
	login_at:      time.Tick, // when to ask to log in again; 0 for not
	login_tries:   int,
	stream:        proto.Stream,
	tokens:        f32, // bytes the stream may send right now
	stream_last:   time.Tick,
	last_id:       u32,
	asked:         map[u32]Asked,
	ping_id:       u32,
	ping_sent:     time.Tick,
	rtt:           time.Duration, // smoothed; 0 until a pong has come
	// Snapshots: being put together, and the last one taken.
	assembler:     ^proto.State_Assembler,
	state_version: u32,
	has_state:     bool,
}

// A request waiting for its answer.
@(private)
Asked :: struct {
	op:   proto.Request_Op,
	done: Request_Done,
	tag:  u64,
	sent: time.Tick,
}

/*
open makes a client that connects with `key`, a device's private key
(a bot's token is one: proto.bot_token_parse). It doesn't wait for the
server: the handshake happens in step.
*/
open :: proc(c: ^Client, key: ^ecdh.Private_Key, opt: Options) -> bool {
	family := net.family_from_address(opt.server.address)
	sock, err := net.make_bound_udp_socket(net.IP6_Any if family == .IP6 else net.IP4_Any, 0)
	if err != nil {
		log.errorf("%s: no socket: %v", opt.name, err)
		return false
	}
	net.set_blocking(sock, false)
	// Room for what a busy server sends between two looks.
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
	c.stream.max_queue = STREAM_QUEUE_MAX
	c.assembler = new(proto.State_Assembler)
	c.last_recv = time.tick_now()
	return true
}

// close says goodbye to the server and frees the client. Requests still
// waiting are answered Reset. A client closed already is left be.
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

// receive takes in what has come; it says whether anything had.
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

// step does what's due: handshakes, the login, pings, the stream.
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

/*
request asks the server for `op`; `done`, if given, hears how it went.
It's false when the request couldn't be sent - there's no connection
yet, or a new one is on its way - and then `done` is never called;
otherwise it's called once.
*/
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
		// More is waiting than the server will ever catch up with: the
		// connection is as good as gone. A new one starts it all over.
		log.warnf("%s: the stream is backed up, starting the connection over", c.opt.name)
		restart(c)
		return false
	}
	c.last_id += 1
	c.asked[c.last_id] = {op, done, tag, time.tick_now()}
	return true
}

// send sends a datagram (typing, voice) on the connection: unreliable,
// and only once there is one.
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

/*
restart gives up on the connection as it is and handshakes for a new
one, under a new conn_id, which the server takes as us having started
over (proto/names.odin): requests waiting are answered Reset when it's
there, and everything is told again.
*/
restart :: proc(c: ^Client) {
	if c.restart || c.phase == .Failed {
		return
	}
	crypto.rand_bytes(([^]byte)(&c.conn_id)[:size_of(c.conn_id)])
	// One under way would still say the old conn_id.
	abandon_handshake(c)
	c.restart = true
	set_phase(c, .Connecting)
}

/*
forget_login wipes the username and password given to log in with: once
logged in, the key is a device, and enough on its own. Should the
server stop knowing it, the client fails (Not_Logged_In) rather than
log in again.
*/
forget_login :: proc(c: ^Client) {
	o := &c.opt
	crypto.zero_explicit(raw_data(o.login_password), len(o.login_password))
	delete(o.login_password)
	delete(o.username)
	o.login_password, o.username = "", ""
}

// ready says whether requests can be made and their answers are about
// a logged in account told everything.
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

// fail gives up for good, telling the server so.
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

// leave says goodbye, if there's anyone to say it to, and forgets the
// sessions.
@(private)
leave :: proc(c: ^Client) {
	if c.has_current {
		// Unreliable, so a few; the server times us out otherwise.
		bye := [1]u8{u8(proto.Message_Kind.Leave)}
		for _ in 0 ..< 3 {
			send(c, bye[:])
		}
	}
	proto.initiator_reset(&c.handshake)
	proto.session_reset(&c.pending)
	proto.session_reset(&c.current)
	proto.session_reset(&c.previous)
	c.has_pending, c.has_current, c.has_previous = false, false, false
	c.has_instance = false
}

// answer_all answers every request still waiting with `status`, in the
// order they were asked: their connection is gone.
@(private)
answer_all :: proc(c: ^Client, status: proto.Status) {
	if len(c.asked) == 0 {
		return
	}
	// From a copy: a `done` may well ask again.
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

/*
drive_handshake starts one when there's no session, the one there is is
due to be rekeyed, the server has gone quiet on it (it may have
restarted, and know nothing of it), or we're starting over; and resends
or starts over one that has stalled.
*/
@(private)
drive_handshake :: proc(c: ^Client, now: time.Tick) {
	if c.has_current && time.tick_diff(c.current.created, now) > proto.REJECT_AFTER {
		log.warnf("%s: the session expired without a rekey", c.opt.name)
		proto.session_reset(&c.current)
		c.has_current = false
	}
	ini := &c.handshake
	if ini.state != .Idle && time.tick_diff(ini.started, now) > proto.HANDSHAKE_TIMEOUT {
		abandon_handshake(c)
	}
	switch ini.state {
	case .Idle:
		silent := c.has_current && time.tick_diff(c.last_recv, now) > proto.SERVER_SILENT
		if c.has_current &&
		   time.tick_diff(c.current.created, now) <= proto.REKEY_AFTER &&
		   !silent &&
		   !c.restart {
			return
		}
		if silent {
			log.warnf("%s: nothing from the server for a while, connecting again", c.opt.name)
		}
		packet, ok := proto.initiator_start(ini, &c.key)
		if !ok {
			return
		}
		ini.last_sent = now
		net.send_udp(c.sock, packet, c.opt.server)
	case .Sent_Init, .Sent_Finish:
		// Resending as it was is fine: the server answers a repeated Init
		// with the same Resp, and a repeated Finish with a Welcome.
		if time.tick_diff(ini.last_sent, now) >= proto.HANDSHAKE_RETRY {
			ini.last_sent = now
			net.send_udp(c.sock, proto.initiator_packet(ini), c.opt.server)
		}
	}
}

@(private)
abandon_handshake :: proc(c: ^Client) {
	proto.initiator_reset(&c.handshake)
	if c.has_pending {
		proto.session_reset(&c.pending)
		c.has_pending = false
	}
}

@(private)
handle_packet :: proc(c: ^Client, packet: []u8) {
	#partial switch proto.packet_type(packet) {
	case .Handshake_Resp:
		server_key, result := proto.initiator_read_resp(&c.handshake, packet)
		if result != .Ok {
			return
		}
		if c.opt.server_key != {} && server_key != c.opt.server_key {
			log.warnf("%s: the server's key isn't the one expected", c.opt.name)
			abandon_handshake(c)
			fail(c, .Wrong_Server_Key)
			return
		}
		hello_buf: [proto.HELLO_MAX_SIZE]u8
		hello := proto.encode_hello(&hello_buf, c.conn_id, c.opt.password)
		finish, ok := proto.initiator_finish(&c.handshake, &c.pending, hello)
		if !ok {
			return
		}
		c.has_pending = true
		c.handshake.last_sent = time.tick_now()
		net.send_udp(c.sock, finish, c.opt.server)

	case .Data:
		idx := proto.receiver_index(packet)
		sess: ^proto.Session
		switch {
		case c.has_pending && idx == c.pending.local_idx:
			sess = &c.pending
		case c.has_current && idx == c.current.local_idx:
			sess = &c.current
		case c.has_previous && idx == c.previous.local_idx:
			sess = &c.previous
		case:
			return
		}
		pt_buf: [proto.MAX_PACKET_SIZE]u8
		pt, ok := proto.open(sess, packet, pt_buf[:])
		if !ok {
			return
		}
		c.last_recv = time.tick_now()
		kind, kind_ok := proto.message_kind(pt)
		if sess == &c.pending {
			// The answer to our hello: the Welcome, or why we're not
			// welcome. Nothing else counts until one of them comes.
			if kind_ok && kind == .Refused {
				c.refusal = proto.decode_refused(pt)
				log.warnf("%s: the server refused us: %v", c.opt.name, c.refusal)
				abandon_handshake(c)
				fail(c, .Refused)
				return
			}
			if !kind_ok || kind != .Welcome {
				return
			}
			promote_pending(c)
		}
		if kind_ok {
			handle_message(c, kind, pt)
		}
	}
}

@(private)
promote_pending :: proc(c: ^Client) {
	if c.has_previous {
		proto.session_reset(&c.previous)
	}
	c.previous, c.has_previous = c.current, c.has_current
	c.current, c.has_current = c.pending, true
	c.pending, c.has_pending = {}, false
	proto.initiator_reset(&c.handshake)
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

/*
handle_welcome: after a rekey it names the connection we have, and
nothing changes. Any other is a new connection - our first, or the
server restarted, gave up on us, or we started over - and what was on
its way on the old one is lost.
*/
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
	c.stream.max_queue = STREAM_QUEUE_MAX
	c.tokens = STREAM_BURST
	c.stream_last = time.tick_now()
	c.has_state = false
	c.assembler^ = {}
	c.login_at, c.login_tries = {}, 0
	// Before the phase changes: whoever is told of it may ask again, on
	// this connection.
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
	// Lost with its connection; the next one logs in again.
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
		return // from a server that knows more than we do
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
			c.logout_reason =
				proto.Logout_Reason(body[0]) if len(body) > 0 else proto.Logout_Reason{}
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

/*
handle_state takes a part of a snapshot, and once it has all of one,
acks it and hands it on. Who is here only means something once we know
who everyone is, so one that comes before that is left unacked, and
comes again.
*/
@(private)
handle_state :: proc(c: ^Client, pt: []u8) {
	if c.phase != .Ready {
		return
	}
	version := proto.state_message_version(pt)
	if c.has_state && !proto.serial_newer(version, c.state_version) {
		// Sent again: our ack got lost, or there was a rekey.
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

// stream_step sends what the stream has to: an ack for what has come,
// then frames, new and due again, as far as the pacing lets it.
@(private)
stream_step :: proc(c: ^Client, now: time.Tick) {
	if !c.has_instance || c.restart {
		return
	}
	st := &c.stream
	elapsed := f32(time.duration_seconds(time.tick_diff(c.stream_last, now)))
	c.stream_last = now
	c.tokens = min(c.tokens + elapsed * STREAM_RATE, STREAM_BURST)
	ack_buf: [proto.STREAM_ACK_SIZE]u8
	if ack, ok := proto.stream_ack(st, &ack_buf); ok {
		send(c, ack)
	}
	// Twice the round trip, once the pings have measured one.
	resend := proto.STREAM_RESEND
	if c.rtt > 0 {
		resend = clamp(2 * c.rtt, proto.STREAM_RESEND_MIN, STREAM_RESEND_MOST)
	}
	out: [proto.MAX_PAYLOAD_SIZE]u8
	for c.tokens > 0 && !proto.stream_idle(st) {
		frame := proto.stream_next_frame(st, now, resend, out[:]) or_break
		send(c, frame)
		c.tokens -= f32(len(frame))
	}
}

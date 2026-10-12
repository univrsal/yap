package gateway

import "core:crypto/ecdh"
import "core:log"
import "core:net"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "common:."
import "common:lite"
import "common:proto"

/*
The bot API's gateway (docs/bot-api): HTTP and JSON for programs, served
by being, to the server, nothing but more clients. For each token in use
it keeps a connection (common/lite), made on the token's first request,
and turns requests into the protocol's and its answers into JSON.

A token is a device's private key (proto.bot_token_parse), so the
gateway keeps nothing of its own: a request with a token it has no
connection for opens one, and the server says whether the key is a
device of an account. A connection goes once it has been idle for
Config.idle, and with it everything the gateway knew through it.

Two kinds of thread:

- HTTP threads, one per TCP connection (serve.odin), as the relay has:
  each reads a request, makes a Job of it and waits for the Job's reply.
- The gateway thread, here, which owns every connection: it takes the
  Jobs, runs them on their token's connection once that's logged in and
  synced, and drives the connections (lite.receive, lite.step). Nothing
  of a connection is touched by another thread.

A Job always gets a reply, exactly one, which is what the HTTP thread
waiting on it relies on: from the endpoint, or an error if the
connection fails, starts over under it or the gateway stops.
*/

DEFAULT_MAX_CONNECTIONS :: 64
// How long a connection is kept after its last request (GATEWAY_IDLE in
// the plan).
DEFAULT_IDLE :: 5 * time.Minute
// How long the gateway thread waits between looks at its connections.
LOOP_WAIT :: time.Millisecond
// What a token's device is called when /login isn't told, and what it
// says it is.
DEFAULT_DEVICE :: "API"
AGENT :: "yap API"

Config :: struct {
	server:          net.Endpoint,
	// The key the server must have; all zero for whichever it has.
	server_key:      [proto.KEY_SIZE]u8,
	password:        string, // the server's, if it has one
	max_connections: int, // 0 for DEFAULT_MAX_CONNECTIONS
	idle:            time.Duration, // 0 for DEFAULT_IDLE
	// Requests a second a token may make, and how many at once
	// (limits.odin); a rate of 0 for no limit.
	rate:            f64,
	burst:           f64,
	// Behind a reverse proxy, whose X-Forwarded-Proto is believed
	// (login_allowed).
	behind_proxy:    bool,
}

Gateway :: struct {
	cfg:     Config, // password owned
	// Jobs handed over by HTTP threads, under the lock.
	mutex:   sync.Mutex,
	jobs:    [dynamic]^Job,
	stop:    bool, // under the lock
	thread:  ^thread.Thread,
	// Each token's bucket of requests (limits.odin), the HTTP threads'.
	limits_mutex: sync.Mutex,
	buckets: map[[proto.KEY_SIZE]u8]Bucket,
	// The gateway thread's own, from here on.
	conns:   map[[proto.KEY_SIZE]u8]^Conn, // by the device's public key
	// The connection for what needs no token: logged in to nothing.
	guest:   ^Conn,
}

// Conn is a token's connection, and what the gateway knows through it.
Conn :: struct {
	g:         ^Gateway,
	client:    lite.Client,
	// Jobs waiting for it to be logged in and synced.
	waiting:   [dynamic]^Job,
	// The /login that made it, until it's logged in or not.
	login:     ^Job,
	token:     string, // that /login's, to answer it with; owned
	last_used: time.Tick,
	// It's to go: failed, logged out, or its token given up.
	done:      bool,
	transfers: Transfers, // files.odin
	announced: bool, // its account logged
	ready_once: bool, // it has been synced before
	// Its event socket, if it has one, and what was told it (events.odin):
	// from the first socket on, every event is numbered and the last
	// EVENT_LOG kept, for a socket that comes back to resume.
	feed:      ^Feed,
	logging:   bool,
	seq:       u64,
	log:       [dynamic]Logged,

	model:     Model, // model.odin
}

/*
A Job is a request, from an HTTP thread to the gateway thread. What it
carries in is the HTTP thread's, and stays valid until it has its reply.
*/
Job :: struct {
	reply:     Reply,
	replied:   sync.Sema,
	kind:      Job_Kind,
	// Which connection: the token's key (.Call), or none (.Guest).
	key:       ecdh.Private_Key,
	// What to do on it once it's ready, on the gateway thread. It
	// replies, there or later from the answer to a request it makes
	// (ask).
	run:       proc(c: ^Conn, j: ^Job),
	// .Login's.
	username:  string,
	password:  string,
	device:    string,
	// The request's body, already read, its query (still encoded:
	// query_param), and the {} parts of its path, decoded.
	body:      []u8,
	query:     string,
	params:    [4]string,
	// What `run` asks the server, and what to make of the answer.
	answer:    proc(c: ^Conn, j: ^Job, a: lite.Answer),
	// What to do once the events of what was asked have come
	// (after_events), and what an endpoint of more than one step keeps
	// between them.
	then:      proc(c: ^Conn, j: ^Job),
	scratch:   [3]u64,
	// An event socket's Feed, for its HTTP thread (events_attach), and
	// a streaming upload's or download's Ring (files.odin).
	feed:      ^Feed,
	ring:      ^Ring,
}

Job_Kind :: enum {
	Call, // with a token
	Guest, // without
	Login, // a new token, with a username and password
}

// An HTTP answer: its status, JSON (owned, from context.allocator; ""
// for none) and when to try again, for 429.
Reply :: struct {
	status:      int,
	json:        string,
	retry_after: int, // seconds; 0 for none
	allow:       string, // for 405: the methods there are
	// Bytes rather than JSON (owned), and what they are.
	body:        []u8,
	content_type: string,
}

// start makes the gateway and its thread. `cfg.password` is copied.
start :: proc(cfg: Config) -> ^Gateway {
	g := new(Gateway)
	g.cfg = cfg
	g.cfg.password = strings.clone(cfg.password)
	if g.cfg.max_connections <= 0 {
		g.cfg.max_connections = DEFAULT_MAX_CONNECTIONS
	}
	if g.cfg.idle <= 0 {
		g.cfg.idle = DEFAULT_IDLE
	}
	g.thread = thread.create_and_start_with_poly_data(g, run_gateway, init_context = context)
	return g
}

// stop replies to every Job still waiting, closes the connections and
// frees the gateway. No HTTP thread may submit after it.
stop :: proc(g: ^Gateway) {
	{
		sync.guard(&g.mutex)
		g.stop = true
	}
	thread.join(g.thread)
	thread.destroy(g.thread)
	delete(g.jobs)
	delete(g.conns)
	delete(g.buckets)
	delete(g.cfg.password)
	free(g)
}

/*
submit hands a Job to the gateway thread and waits for its reply. The
key in it is wiped once it's been taken.
*/
submit :: proc(g: ^Gateway, j: ^Job) -> Reply {
	submit_start(g, j)
	return submit_wait(j)
}

// submit_start hands a Job over, for an HTTP thread that has more to do
// before it waits for its reply (submit_wait).
submit_start :: proc(g: ^Gateway, j: ^Job) {
	sync.guard(&g.mutex)
	if g.stop {
		reply(j, error_reply(503, "unavailable", "The API is stopping."))
		return
	}
	append(&g.jobs, j)
}

submit_wait :: proc(j: ^Job) -> Reply {
	sync.sema_wait(&j.replied)
	return j.reply
}

/*
reply answers a Job, which then belongs to its HTTP thread again. An
error gives up on the file it streams, if it does, which is how its HTTP
thread knows to stop.
*/
reply :: proc(j: ^Job, r: Reply) {
	if r.status >= 300 && j.ring != nil {
		ring_fail(j.ring)
	}
	j.reply = r
	sync.sema_post(&j.replied)
}

/*
ask makes a request on the Job's connection, whose answer goes to
j.answer. If it can't be sent, the Job is answered that the connection
is starting over.
*/
ask :: proc(c: ^Conn, j: ^Job, op: proto.Request_Op, body: []u8 = nil) {
	if !lite.request(&c.client, op, body, answered, u64(uintptr(j))) {
		reply(j, error_reply(503, "reset", "The connection to the server is starting over; try again."))
	}
}

/*
after_events runs `then` once every event of what the Job asked before
has come, so the model has it: it asks the server something that costs
it nothing, whose answer comes after them on the stream, as the server
handles requests in turn and tells what one did before taking the next.
*/
after_events :: proc(c: ^Conn, j: ^Job, then: proc(c: ^Conn, j: ^Job)) {
	j.then = then
	j.answer = proc(c: ^Conn, j: ^Job, a: lite.Answer) {
		j.then(c, j)
	}
	ask(c, j, .Server_Info)
}

@(private)
answered :: proc(client: ^lite.Client, a: lite.Answer) {
	c := (^Conn)(client.opt.user)
	j := (^Job)(uintptr(a.tag))
	if a.status == .Reset {
		reply(j, status_reply(.Reset))
		return
	}
	j.answer(c, j, a)
}

@(private)
run_gateway :: proc(g: ^Gateway) {
	jobs: [dynamic]^Job
	defer delete(jobs)
	for {
		free_all(context.temp_allocator)
		stopping: bool
		{
			sync.guard(&g.mutex)
			stopping = g.stop
			jobs, g.jobs = g.jobs, jobs
		}
		// What has come first, so a Job is answered from the model as
		// it is by now.
		for _, c in g.conns {
			lite.receive(&c.client)
		}
		if g.guest != nil {
			lite.receive(&g.guest.client)
		}
		for j in jobs {
			dispatch(g, j)
		}
		clear(&jobs)
		if stopping {
			break
		}
		now := time.tick_now()
		for _, c in g.conns {
			lite.step(&c.client, now)
			files_step(c, now)
		}
		if g.guest != nil {
			lite.step(&g.guest.client, now)
		}
		sweep(g, now)
		time.sleep(LOOP_WAIT)
	}
	for _, c in g.conns {
		conn_close(c, "the API stopped")
	}
	if g.guest != nil {
		conn_close(g.guest, "")
	}
}

/*
dispatch takes a Job to its connection, made for it if need be. Once
it's replied to, the Job is the HTTP thread's again, and gone as soon as
that's answered: nothing here may touch it after.
*/
@(private)
dispatch :: proc(g: ^Gateway, j: ^Job) {
	// Off the Job first, while it's certainly still there.
	token_key := j.key
	defer ecdh.private_key_clear(&token_key)
	ecdh.private_key_clear(&j.key)
	c: ^Conn
	switch j.kind {
	case .Guest:
		if g.guest == nil || g.guest.done {
			key: ecdh.Private_Key
			defer ecdh.private_key_clear(&key)
			if !ecdh.private_key_generate(&key, .X25519) {
				reply(j, error_reply(500, "internal", "No key could be made."))
				return
			}
			if g.guest != nil {
				conn_close(g.guest, "")
			}
			g.guest = conn_open(g, &key, {guest = true, name = "api guest"})
			if g.guest == nil {
				reply(j, error_reply(500, "internal", "No socket for the server."))
				return
			}
		}
		c = g.guest
	case .Call:
		pub: [proto.KEY_SIZE]u8
		ecdh.private_key_public_bytes(&token_key, pub[:])
		c = g.conns[pub] or_else nil
		if c == nil || c.done {
			opened: bool
			c, opened = new_conn(g, j, &token_key, {name = common_name(pub)})
			if !opened {
				return
			}
		}
	case .Login:
		token, pub, made := proto.bot_token_make()
		if !made {
			reply(j, error_reply(500, "internal", "No key could be made."))
			return
		}
		key: ecdh.Private_Key
		defer ecdh.private_key_clear(&key)
		proto.bot_token_parse(token, &key)
		opened: bool
		c, opened = new_conn(
			g,
			j,
			&key,
			{
				username = j.username,
				login_password = j.password,
				device = j.device if j.device != "" else DEFAULT_DEVICE,
				agent = AGENT,
				name = common_name(pub),
			},
		)
		if !opened {
			crypto_wipe(&token)
			return
		}
		c.login = j
		c.token = token
		c.last_used = time.tick_now()
		return
	}
	c.last_used = time.tick_now()
	// Last: it may reply.
	if lite.ready(&c.client) {
		j.run(c, j)
	} else {
		append(&c.waiting, j)
	}
}

// new_conn opens a token's connection, if there's room for one.
@(private)
new_conn :: proc(
	g: ^Gateway,
	j: ^Job,
	key: ^ecdh.Private_Key,
	opt: lite.Options,
) -> (
	c: ^Conn,
	ok: bool,
) {
	pub: [proto.KEY_SIZE]u8
	ecdh.private_key_public_bytes(key, pub[:])
	if old := g.conns[pub] or_else nil; old != nil {
		// One that's on its way out: it goes now.
		conn_close(old, "")
		delete_key(&g.conns, pub)
	}
	if len(g.conns) >= g.cfg.max_connections {
		reply(j, error_reply(503, "unavailable", "The API has as many connections as it takes."))
		return
	}
	c = conn_open(g, key, opt)
	if c == nil {
		reply(j, error_reply(500, "internal", "No socket for the server."))
		return
	}
	g.conns[pub] = c
	return c, true
}

@(private)
conn_open :: proc(g: ^Gateway, key: ^ecdh.Private_Key, opt: lite.Options) -> ^Conn {
	c := new(Conn)
	c.g = g
	o := opt
	o.server = g.cfg.server
	o.server_key = g.cfg.server_key
	o.password = g.cfg.password
	o.handlers = HANDLERS
	o.user = c
	if !lite.open(&c.client, key, o) {
		free(c)
		return nil
	}
	c.last_used = time.tick_now()
	return c
}

// conn_close replies to what's waiting with `why` (503), says goodbye
// to the server and frees the connection.
@(private)
conn_close :: proc(c: ^Conn, why: string) {
	if c.model.self != 0 && why != "" {
		log.infof("api: %s's connection closed: %s", account_name(c), why)
	}
	for j in c.waiting {
		reply(j, error_reply(503, "unavailable", "The connection to the server closed."))
	}
	if c.login != nil {
		reply(c.login, error_reply(503, "unavailable", "The connection to the server closed."))
	}
	files_destroy(c)
	lite.close(&c.client) // what's in flight is answered Reset
	if c.feed != nil {
		feed_close(c.feed, CLOSE_GOING, "the API's connection closed")
		feed_release(c.feed)
	}
	for e in c.log {
		delete(e.frame)
	}
	delete(c.log)
	delete(c.waiting)
	delete(c.token)
	model_destroy(&c.model)
	free(c)
}

// sweep closes the connections that are done, and those that have been
// idle long enough.
@(private)
sweep :: proc(g: ^Gateway, now: time.Tick) {
	gone := make([dynamic][proto.KEY_SIZE]u8, context.temp_allocator)
	for key, c in g.conns {
		if c.feed != nil {
			if !feed_gone(c.feed) {
				// Listened to, so not idle; and from when it goes, it has
				// as long as any to come back and resume.
				c.last_used = now
				continue
			}
			log.infof("api: %s's event socket closed", account_name(c))
			feed_release(c.feed)
			c.feed = nil
			c.last_used = now
		}
		idle :=
			len(c.waiting) == 0 &&
			len(c.client.asked) == 0 &&
			c.login == nil &&
			time.tick_diff(c.last_used, now) > g.cfg.idle
		if c.done || idle {
			append(&gone, key)
		}
	}
	for key in gone {
		c := g.conns[key]
		delete_key(&g.conns, key)
		conn_close(c, "idle" if !c.done else "")
	}
	if g.guest != nil &&
	   (g.guest.done || time.tick_diff(g.guest.last_used, now) > g.cfg.idle) &&
	   len(g.guest.waiting) == 0 &&
	   len(g.guest.client.asked) == 0 {
		conn_close(g.guest, "")
		g.guest = nil
	}
}

@(private)
HANDLERS :: lite.Handlers {
	phase   = conn_phase,
	event   = conn_event,
	state   = conn_state,
	message = conn_message,
}

@(private)
conn_phase :: proc(client: ^lite.Client, phase: lite.Phase) {
	c := (^Conn)(client.opt.user)
	if phase != .Ready {
		// Starting over, or failed: what was on its way went with it.
		files_reset(c)
	}
	#partial switch phase {
	case .Ready:
		if c.login != nil {
			j := c.login
			c.login = nil
			reply(j, json_reply(200, Token_JSON{token = c.token}))
			crypto_wipe(&c.token)
			lite.forget_login(&c.client)
		}
		if c.model.self != 0 && !c.announced {
			c.announced = true
			log.infof("api: a connection for %s", account_name(c))
		}
		if !c.model.server_known && !c.client.opt.guest {
			lite.request(&c.client, .Server_Info, nil, server_info_done)
		}
		// Synced again, on a new connection to the server: everything
		// may have changed while it was gone.
		if c.ready_once {
			emit(c, "READY", ready_json(c))
		}
		c.ready_once = true
		// From a copy: what runs may well wait again.
		waiting := c.waiting
		c.waiting = {}
		for j in waiting {
			j.run(c, j)
		}
		delete(waiting)
	case .Failed:
		c.done = true
		if c.feed != nil {
			#partial switch c.client.failure {
			case .Logged_Out, .Not_Logged_In:
				feed_close(c.feed, CLOSE_LOGGED_OUT, "the token doesn't work any more")
			case:
				feed_close(c.feed, CLOSE_SERVER, "the server can't be reached")
			}
		}
		// One each: a reply belongs to the HTTP thread that sends it.
		if c.login != nil {
			reply(c.login, failure_reply(&c.client))
			c.login = nil
		}
		for j in c.waiting {
			reply(j, failure_reply(&c.client))
		}
		clear(&c.waiting)
	}
}

@(private)
conn_state :: proc(client: ^lite.Client, state: proto.Presence) {
	c := (^Conn)(client.opt.user)
	before := make(map[proto.Account_Id]int, len(c.model.online), context.temp_allocator)
	for id, n in c.model.online {
		before[id] = n
	}
	model_state(&c.model, state)
	events_presence(c, before)
}

@(private)
conn_event :: proc(client: ^lite.Client, op: proto.Event_Op, body: []u8) {
	c := (^Conn)(client.opt.user)
	model_event(&c.model, op, body)
	events_event(c, op, body)
}

@(private)
conn_message :: proc(client: ^lite.Client, kind: proto.Message_Kind, pt: []u8) {
	c := (^Conn)(client.opt.user)
	if kind == .Typing {
		events_typing(c, pt)
	} else {
		files_message(c, kind, pt)
	}
}

// server_info_done keeps what the server says about itself, for READY.
@(private)
server_info_done :: proc(client: ^lite.Client, a: lite.Answer) {
	c := (^Conn)(client.opt.user)
	if a.status == .Ok {
		model_server(&c.model, a.body)
	}
}

// What the log calls a connection before it knows whose it is.
@(private)
common_name :: proc(pub: [proto.KEY_SIZE]u8) -> string {
	return strings.clone(
		strings.concatenate({"api ", key_hex(common.key_id(pub))}, context.temp_allocator),
		context.temp_allocator,
	)
}

@(private)
key_hex :: proc(id: u32) -> string {
	DIGITS := "0123456789abcdef"
	buf := make([]u8, 8, context.temp_allocator)
	for i in 0 ..< 8 {
		buf[i] = DIGITS[(id >> (28 - 4 * uint(i))) & 0xF]
	}
	return string(buf)
}

// crypto_wipe zeroes and frees a string that held a secret.
@(private)
crypto_wipe :: proc(s: ^string) {
	b := transmute([]u8)s^
	for &x in b {
		x = 0
	}
	delete(s^)
	s^ = ""
}

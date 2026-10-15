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

// The bot API's gateway (docs/bot-api) offers HTTP and JSON for programs. To
// the server it looks like just another client. For each token in use it keeps
// a connection (common/lite), which is made on the token's first request. It
// translates requests into protocol messages and the server's answers into
// JSON.
//
// A token is a device's private key (proto.bot_token_parse), so the gateway
// stores no accounts of its own. A request with a token that has no connection
// yet opens one, and the server decides whether the key belongs to a device of
// an account. A connection is closed once it has been idle for Config.idle,
// and everything the gateway knew through it is dropped with it.
//
// There are two kinds of thread:
//
// - HTTP threads, one per TCP connection (serve.odin), as in the relay. Each
//   reads a request, turns it into a Job and waits for the Job's reply.
// - The gateway thread, in this file, which owns every connection. It takes
//   the Jobs, runs them on their token's connection once that is logged in
//   and synced, and drives the connections (lite.receive, lite.step). No
//   other thread touches a connection.
//
// Every Job gets exactly one reply, which the HTTP thread waiting on it relies
// on. The reply comes either from the endpoint or is an error if the
// connection fails, starts over or the gateway stops.

DEFAULT_MAX_CONNECTIONS :: 64
// How long a connection is kept after its last request (GATEWAY_IDLE in
// the plan).
DEFAULT_IDLE :: 5 * time.Minute
// How long the gateway thread waits between checks of its connections.
LOOP_WAIT :: time.Millisecond
// The device name used when /login doesn't specify one, and the agent
// string the gateway reports to the server.
DEFAULT_DEVICE :: "API"
AGENT :: "yap API"

Config :: struct {
	server:          net.Endpoint,
	// The key the server must have. All zeros accepts any key.
	server_key:      [proto.KEY_SIZE]u8,
	password:        string, // the server's password, if it has one
	max_connections: int, // 0 for DEFAULT_MAX_CONNECTIONS
	idle:            time.Duration, // 0 for DEFAULT_IDLE
	// How many requests per second a token may make and how many may
	// come at once (limits.odin). A rate of 0 means no limit.
	rate:            f64,
	burst:           f64,
	// Set when running behind a reverse proxy, whose X-Forwarded-Proto
	// header is trusted (login_allowed). If the proxy's address is known,
	// only requests from it are believed.
	behind_proxy:    bool,
	trusted_proxy:   net.Address, // nil: this machine and private networks
}

Gateway :: struct {
	cfg:          Config, // owns the password
	// Jobs handed over by HTTP threads, guarded by the mutex.
	mutex:        sync.Mutex,
	jobs:         [dynamic]^Job,
	stop:         bool, // guarded by the mutex
	thread:       ^thread.Thread,
	// Each token's bucket of requests (limits.odin), used by the HTTP threads.
	limits_mutex: sync.Mutex,
	buckets:      map[[proto.KEY_SIZE]u8]Bucket,
	// The fields below are only used by the gateway thread.
	conns:        map[[proto.KEY_SIZE]u8]^Conn, // by the device's public key
	// Connections opened to the server, by the address they were for
	// (opens_take).
	opens:        map[Address_Key]Bucket,
	// The connection for requests that need no token. It isn't logged in to
	// any account.
	guest:        ^Conn,
}

// Conn is a token's connection and everything the gateway knows through it.
Conn :: struct {
	g:          ^Gateway,
	client:     lite.Client,
	// Jobs waiting for the connection to be logged in and synced.
	waiting:    [dynamic]^Job,
	// The /login that created the connection, until the login succeeds or
	// fails.
	login:      ^Job,
	token:      string, // the token to answer that /login with; owned
	last_used:  time.Tick,
	// The connection is to be closed: it failed, was logged out or its
	// token was given up.
	done:       bool,
	transfers:  Transfers, // files.odin
	announced:  bool, // the account has been written to the log
	ready_once: bool, // the connection has been synced before
	// The connection's event socket, if it has one, and the events sent
	// to it (events.odin). From the first socket on, every event is
	// numbered and the last EVENT_LOG events are kept so a socket that
	// comes back can resume.
	feed:       ^Feed,
	logging:    bool,
	seq:        u64,
	log:        [dynamic]Logged,
	model:      Model, // model.odin
}

// A Job is a request passed from an HTTP thread to the gateway thread. The
// data it carries in belongs to the HTTP thread and stays valid until the Job
// has been replied to.
Job :: struct {
	reply:    Reply,
	replied:  sync.Sema,
	kind:     Job_Kind,
	// Which connection to use: the token's key (.Call) or none (.Guest).
	key:      ecdh.Private_Key,
	// What to do on the connection once it is ready, run on the gateway
	// thread. It replies directly or later, from the answer to a request
	// it makes (ask).
	run:      proc(c: ^Conn, j: ^Job),
	// Where the request came from (client_address), to limit the
	// connections opened for it (opens_take).
	remote:   net.Address,
	// Used by .Login jobs.
	username: string,
	password: string,
	device:   string,
	// The request's body (already read), its query (still encoded, see
	// query_param) and the decoded {} parts of its path.
	body:     []u8,
	query:    string,
	params:   [4]string,
	// What to do with the server's answer to a request made by `run`.
	answer:   proc(c: ^Conn, j: ^Job, a: lite.Answer),
	// What to do once the events caused by the request have arrived
	// (after_events), and the state an endpoint with more than one step
	// keeps between its steps.
	then:     proc(c: ^Conn, j: ^Job),
	scratch:  [3]u64,
	// An event socket's Feed, handed to its HTTP thread (events_attach), and
	// the Ring of a streaming upload or download (files.odin).
	feed:     ^Feed,
	ring:     ^Ring,
}

Job_Kind :: enum {
	Call, // a request with a token
	Guest, // a request without a token
	Login, // a new token, with a username and password
}

// An HTTP answer: the status, the JSON (owned, allocated with
// context.allocator, or "" for none) and, for 429, when to try again.
Reply :: struct {
	status:       int,
	json:         string,
	retry_after:  int, // in seconds, 0 for none
	allow:        string, // for 405: the methods that are allowed
	// Raw bytes instead of JSON (owned) and their content type.
	body:         []u8,
	content_type: string,
}

// start creates the gateway and its thread. `cfg.password` is copied.
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

// stop replies to every Job that is still waiting, closes the connections and
// frees the gateway. No HTTP thread may submit a Job after this.
stop :: proc(g: ^Gateway) {
	{
		sync.guard(&g.mutex)
		g.stop = true
	}
	thread.join(g.thread)
	thread.destroy(g.thread)
	delete(g.jobs)
	delete(g.conns)
	delete(g.opens)
	delete(g.buckets)
	delete(g.cfg.password)
	free(g)
}

// submit hands a Job to the gateway thread and waits for its reply. The key
// in the Job is wiped once the gateway thread has taken it.
submit :: proc(g: ^Gateway, j: ^Job) -> Reply {
	submit_start(g, j)
	return submit_wait(j)
}

// submit_start hands a Job over. It is for an HTTP thread that has more to do
// before it waits for the reply (submit_wait).
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

// reply answers a Job, after which the Job belongs to its HTTP thread again.
// An error status marks the Job's streamed file as failed (if it has one),
// which is how the HTTP thread knows to stop.
reply :: proc(j: ^Job, r: Reply) {
	if r.status >= 300 && j.ring != nil {
		ring_fail(j.ring)
	}
	j.reply = r
	sync.sema_post(&j.replied)
}

// ask makes a request on the Job's connection and sends the answer to
// j.answer. If the request can't be sent, the Job is answered with an error
// saying that the connection is starting over.
ask :: proc(c: ^Conn, j: ^Job, op: proto.Request_Op, body: []u8 = nil) {
	if !lite.request(&c.client, op, body, answered, u64(uintptr(j))) {
		reply(
			j,
			error_reply(
				503,
				"reset",
				"The connection to the server is restarting. Please try again.",
			),
		)
	}
}

// after_events runs `then` once every event caused by the Job's earlier
// requests has arrived, so the model is up to date. It does this by asking the
// server something cheap. The server handles requests one at a time and sends
// the events of a request before taking the next one, so the answer arrives
// after those events on the stream.
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
		// Receive first, so that a Job is answered from the current state
		// of the model.
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

// dispatch takes a Job to its connection, which is created if necessary.
// Once the Job has been replied to it belongs to the HTTP thread again and may
// be freed right away, so nothing here may touch it afterwards.
@(private)
dispatch :: proc(g: ^Gateway, j: ^Job) {
	// Copy the key off the Job first, while the Job is certainly still valid.
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
				reply(j, error_reply(500, "internal", "The gateway failed to generate a key."))
				return
			}
			if g.guest != nil {
				conn_close(g.guest, "")
			}
			g.guest = conn_open(g, &key, {guest = true, name = "api guest"})
			if g.guest == nil {
				reply(
					j,
					error_reply(
						500,
						"internal",
						"The gateway failed to open a socket to the server.",
					),
				)
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
			reply(j, error_reply(500, "internal", "The gateway failed to generate a key."))
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
	// This comes last because running the Job may reply to it.
	if lite.ready(&c.client) {
		j.run(c, j)
	} else {
		append(&c.waiting, j)
	}
}

// new_conn opens a token's connection if the connection limit allows it.
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
	if r, limited := opens_take(g, j.remote); limited {
		reply(j, r)
		return
	}
	pub: [proto.KEY_SIZE]u8
	ecdh.private_key_public_bytes(key, pub[:])
	if old := g.conns[pub] or_else nil; old != nil {
		// An old connection that is about to be removed is closed immediately.
		conn_close(old, "")
		delete_key(&g.conns, pub)
	}
	if len(g.conns) >= g.cfg.max_connections {
		reply(
			j,
			error_reply(
				503,
				"unavailable",
				"The API has reached its maximum number of connections. Please try again later.",
			),
		)
		return
	}
	c = conn_open(g, key, opt)
	if c == nil {
		reply(
			j,
			error_reply(500, "internal", "The gateway failed to open a socket to the server."),
		)
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

// conn_close replies to all waiting Jobs with a 503, says goodbye to the
// server and frees the connection. `why` is only used for the log.
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

// sweep closes the connections that are done and the ones that have been
// idle long enough.
@(private)
sweep :: proc(g: ^Gateway, now: time.Tick) {
	gone := make([dynamic][proto.KEY_SIZE]u8, context.temp_allocator)
	for key, c in g.conns {
		if c.feed != nil {
			if !feed_gone(c.feed) {
				// Someone is listening, so the connection isn't idle. Once the
				// socket goes away, the bot gets the full idle time to come back
				// and resume.
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
		// The connection is starting over or failed, so transfers in progress
		// are lost.
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
		// Synced again over a new connection to the server. Everything may
		// have changed while the connection was gone.
		if c.ready_once {
			emit(c, "READY", ready_json(c))
		}
		c.ready_once = true
		// Iterate over a copy because a Job that runs may end up waiting again.
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
		// Each Job is replied to separately, as a reply belongs to the HTTP
		// thread that sends it.
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

// server_info_done stores what the server reports about itself, for READY.
@(private)
server_info_done :: proc(client: ^lite.Client, a: lite.Answer) {
	c := (^Conn)(client.opt.user)
	if a.status == .Ok {
		model_server(&c.model, a.body)
	}
}

// The name used in the log for a connection before its account is known.
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

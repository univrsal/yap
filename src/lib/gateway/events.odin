package gateway

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:net"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "lib:http"
import "common:proto"

// Events (docs/bot-api, "Events: the WebSocket"): GET /api/v1/events
// upgrades to a WebSocket over which the gateway sends text frames, each
// containing one JSON object:
//
//	{"t": "MESSAGE_CREATE", "s": 118, "d": {...}}
//
// The first frame is READY (everything the model has). After that every
// event is sent as it happens, numbered consecutively in `s`.
//
// Once a token has had an event socket, its connection keeps the last
// EVENT_LOG events. A bot whose socket dropped can reconnect with
// `?resume=<the last s it received>` and receive the events it missed, as
// long as the connection still exists (it is kept for Config.idle after
// its socket goes away). If resuming is not possible, the bot receives
// INVALID_SESSION followed by READY. (The plan was to send resume as a
// first frame, but with a URL parameter the gateway knows right away
// whether to resume and has nothing to wait for.)
//
// There is one socket per token: a new socket closes the previous one
// (code 4000). The socket closes with 4001 when the token stops working
// (after LOGGED_OUT), 4002 when the server can't be reached and 1001 when
// the API shuts down. If the server restarts and the connection starts
// over, the bot is sent everything again as READY, in the same stream.
//
// The bot sends nothing. WebSocket pings from either side keep the socket
// open (the gateway pings every PING_EVERY).
//
// Threads: the HTTP thread the socket arrived on reads from it (pings,
// close). A separate writer thread sends what is in the socket's Feed,
// which the gateway thread fills.

EVENT_LOG :: 500
PING_EVERY :: 30 * time.Second

// The close codes, besides WebSocket's own.
CLOSE_GOING :: 1001
CLOSE_REPLACED :: 4000
CLOSE_LOGGED_OUT :: 4001
CLOSE_SERVER :: 4002

// Feed is an event socket's queue. The gateway thread puts frames in and
// closes it, the socket's writer takes them out, and each side reports when
// it has gone away. Whichever side releases it last frees it.
Feed :: struct {
	mutex:        sync.Mutex,
	cond:         sync.Cond,
	frames:       [dynamic]string, // owned
	closing:      bool, // set by the gateway: send close_code and stop
	close_code:   u16,
	close_reason: string, // a constant
	gone:         bool, // set by the socket: it has gone away
	refs:         int,
	// The socket's two threads both write to it.
	write_mutex:  sync.Mutex,
}

// A logged event: its sequence number and the frame that was sent.
@(private)
Logged :: struct {
	s:     u64,
	frame: string, // owned
}

@(private)
feed_push :: proc(f: ^Feed, frame: string) {
	sync.guard(&f.mutex)
	if f.closing || f.gone {
		return
	}
	append(&f.frames, strings.clone(frame))
	sync.cond_signal(&f.cond)
}

@(private)
feed_close :: proc(f: ^Feed, code: u16, reason: string) {
	sync.guard(&f.mutex)
	if !f.closing {
		f.closing, f.close_code, f.close_reason = true, code, reason
	}
	sync.cond_signal(&f.cond)
}

@(private)
feed_gone :: proc(f: ^Feed) -> bool {
	sync.guard(&f.mutex)
	return f.gone
}

@(private)
feed_release :: proc(f: ^Feed) {
	last: bool
	{
		sync.guard(&f.mutex)
		f.refs -= 1
		last = f.refs == 0
	}
	if last {
		for frame in f.frames {
			delete(frame)
		}
		delete(f.frames)
		free(f)
	}
}

// emit numbers an event, logs it and sends it to the socket if there is one.
// It does nothing until the token has had a socket (nobody would hear it) and
// while a sync is in progress (READY covers that state).
@(private)
emit :: proc(c: ^Conn, t: string, d: any) {
	if !c.logging || c.client.phase != .Ready {
		return
	}
	c.seq += 1
	frame := event_frame(t, c.seq, d)
	if c.feed != nil {
		feed_push(c.feed, frame)
	}
	if len(c.log) == EVENT_LOG {
		delete(c.log[0].frame)
		ordered_remove(&c.log, 0)
	}
	append(&c.log, Logged{c.seq, strings.clone(frame)})
}

// event_frame builds the text frame for an event, in the temp allocator.
@(private)
event_frame :: proc(t: string, s: u64, d: any) -> string {
	data, err := json.marshal(d, allocator = context.temp_allocator)
	if err != nil {
		log.errorf("api: could not make JSON of a %s: %v", t, err)
		data = transmute([]u8)string("null")
	}
	return strings.concatenate(
		{`{"t":"`, t, `","s":`, fmt.tprint(s), `,"d":`, string(data), "}"},
		context.temp_allocator,
	)
}

Ready_JSON :: struct {
	me:       Me_JSON,
	server:   Maybe(Server_JSON),
	roles:    []Role_JSON,
	accounts: []Account_JSON,
	convs:    []Conv_JSON,
	online:   []string, // ids of the accounts that are online
}

@(private)
ready_json :: proc(c: ^Conn) -> Ready_JSON {
	m := &c.model
	r := Ready_JSON {
		me       = me_json(m),
		roles    = roles_json(m),
		accounts = accounts_json(m),
		convs    = convs_json(m),
	}
	if m.server_known {
		r.server = server_json(&m.server)
	}
	online, _ := slice.map_keys(m.online, context.temp_allocator)
	slice.sort(online)
	r.online = make([]string, len(online), context.temp_allocator)
	for id, i in online {
		r.online[i] = id_string(id)
	}
	return r
}

// events_attach is the Job that sets up an event socket, run on the gateway
// thread. It creates the socket's Feed and fills it with READY or with the
// events that were missed. j.scratch is [resume s, whether to resume].
@(private)
events_attach :: proc(c: ^Conn, j: ^Job) {
	f := new(Feed)
	f.refs = 2 // one for the connection, one for the socket
	if c.feed != nil {
		feed_close(c.feed, CLOSE_REPLACED, "another socket took over")
		feed_release(c.feed)
	}
	c.feed = f
	c.logging = true
	log.infof("api: %s's event socket opened, from %s", account_name(c), j.params[0])
	resume, resuming := j.scratch[0], j.scratch[1] != 0
	if resuming {
		oldest := c.log[0].s if len(c.log) > 0 else c.seq + 1
		if resume <= c.seq && resume + 1 >= oldest {
			for e in c.log {
				if e.s > resume {
					feed_push(f, e.frame)
				}
			}
			j.feed = f
			reply(j, {status = 101})
			return
		}
		feed_push(f, event_frame("INVALID_SESSION", c.seq, struct{}{}))
	}
	feed_push(f, event_frame("READY", c.seq, ready_json(c)))
	j.feed = f
	reply(j, {status = 101})
}

// events_event turns a message from the server into events. The model has
// already applied it.
@(private)
events_event :: proc(c: ^Conn, op: proto.Event_Op, body: []u8) {
	if !c.logging {
		return
	}
	m := &c.model
	#partial switch op {
	case .Msg_New, .Msg_Changed:
		msg, ok := proto.decode_message(body)
		if !ok {
			return
		}
		switch {
		case op == .Msg_New:
			emit(c, "MESSAGE_CREATE", message_json(m, &msg))
		case .Deleted in msg.flags:
			emit(c, "MESSAGE_DELETE", Message_Ref_JSON{id_string(msg.id), id_string(msg.conv)})
		case:
			emit(c, "MESSAGE_UPDATE", message_json(m, &msg))
		}
	case .Reaction_Changed:
		r, ok := proto.decode_reaction_changed(body)
		if !ok {
			return
		}
		emit(
			c,
			"MESSAGE_REACTION_ADD" if r.on else "MESSAGE_REACTION_REMOVE",
			Reaction_Event_JSON {
				message_id = id_string(r.id),
				conv_id = id_string(r.conv),
				emoji = r.emoji,
				count = r.count,
				account = author_json(m, r.account),
			},
		)
	case .Msgs_Purged:
		p, ok := proto.decode_msgs_purged(body)
		if !ok {
			return
		}
		emit(
			c,
			"MESSAGES_PURGED",
			Purged_JSON{id_string(p.conv), id_string(p.before), enum_name(p.what)},
		)
	case .Conv_Changed:
		conv, ok := proto.decode_conv(body)
		if !ok {
			return
		}
		if known, in_it := &m.convs[conv.id]; in_it {
			emit(c, "CONV_UPDATE", conv_json(m, &known.conv))
		}
	case .Conv_Removed:
		id, ok := proto.decode_conv_id(body)
		if ok {
			emit(c, "CONV_DELETE", Id_JSON{id_string(id)})
		}
	case .Read_Changed:
		s, ok := proto.decode_read_changed(body)
		if !ok {
			return
		}
		r := Read_JSON {
			conv_id  = id_string(s.conv),
			unread   = s.unread,
			mentions = s.mentions,
		}
		if s.read != 0 {
			r.last_read_id = id_string(s.read)
		}
		emit(c, "READ_UPDATE", r)
	case .Account_Changed:
		a, ok := proto.decode_account(body)
		if !ok {
			return
		}
		if known, there := &m.accounts[a.id]; there {
			emit(c, "ACCOUNT_UPDATE", account_json(m, &known.account))
		}
	case .Role_Changed:
		r, ok := proto.decode_role(body)
		if !ok {
			return
		}
		if known, there := &m.roles[r.id]; there {
			emit(c, "ROLE_UPDATE", role_json(&known.role))
		}
	case .Role_Removed:
		id, ok := proto.decode_conv_id(body)
		if ok {
			emit(c, "ROLE_DELETE", Id_JSON{id_string(id)})
		}
	case .Self:
		emit(c, "SELF_UPDATE", me_json(m))
	case .Server_Info:
		if m.server_known {
			emit(c, "SERVER_UPDATE", server_json(&m.server))
		}
	case .Logged_Out:
		reason := proto.Logout_Reason(body[0]) if len(body) > 0 else proto.Logout_Reason{}
		// The connection is failing at this point, so the phase is
		// no longer Ready and emit would drop the event.
		c.seq += 1
		frame := event_frame("LOGGED_OUT", c.seq, struct {
			reason: string,
		}{enum_name(reason)})
		if c.feed != nil {
			feed_push(c.feed, frame)
		}
	}
}

// events_presence emits an update for each account whose online state
// differs between the snapshot before and the current one.
@(private)
events_presence :: proc(c: ^Conn, before: map[proto.Account_Id]int) {
	m := &c.model
	changed := make([dynamic]proto.Account_Id, context.temp_allocator)
	for id in m.online {
		if id not_in before {
			append(&changed, id)
		}
	}
	for id in before {
		if id not_in m.online {
			append(&changed, id)
		}
	}
	slice.sort(changed[:])
	for id in changed {
		emit(c, "PRESENCE_UPDATE", Presence_JSON{id_string(id), id in m.online})
	}
}

// events_typing emits TYPING_START for a typing datagram (which is not an
// event from the server).
@(private)
events_typing :: proc(c: ^Conn, pt: []u8) {
	if !c.logging || len(pt) != proto.TYPING_DOWN_SIZE {
		return
	}
	conv, thread, account := proto.decode_typing_down(pt)
	if account == c.model.self {
		return
	}
	t := Typing_JSON {
		conv_id = id_string(conv),
		account = author_json(&c.model, account),
	}
	if thread != 0 {
		t.thread = id_string(thread)
	}
	emit(c, "TYPING_START", t)
}

Id_JSON :: struct {
	id: string,
}

Message_Ref_JSON :: struct {
	id:      string,
	conv_id: string,
}

Reaction_Event_JSON :: struct {
	message_id: string,
	conv_id:    string,
	emoji:      string,
	count:      int, // how many reactions of this emoji there are now
	account:    Author_JSON, // who added or removed the reaction
}

Purged_JSON :: struct {
	conv_id:   string,
	before_id: string, // the messages older than this were purged
	what:      string, // messages, or files (only the files were purged)
}

Read_JSON :: struct {
	conv_id:      string,
	last_read_id: Maybe(string),
	unread:       int,
	mentions:     int,
}

Presence_JSON :: struct {
	account_id: string,
	online:     bool,
}

Typing_JSON :: struct {
	conv_id: string,
	thread:  Maybe(string),
	account: Author_JSON,
}

// events_serve handles an event socket on its HTTP thread. It reads the token
// and whether to resume, performs the upgrade and then reads from the socket
// until it closes, while a writer thread sends what the gateway puts in its
// Feed.
@(private)
events_serve :: proc(g: ^Gateway, c: ^http.Conn, req: ^http.Request) {
	j := Job {
		kind   = .Call,
		run    = events_attach,
		remote = client_address(g, c, req),
	}
	token: string
	auth := http.header(req, "Authorization")
	if auth != "" {
		scheme, _, rest := strings.partition(auth, " ")
		if strings.equal_fold(scheme, "Bot") {
			token = rest
		}
	} else {
		token, _ = http.query_value(req.query, "token")
	}
	if token == "" || !proto.bot_token_parse(token, &j.key) {
		send(
			c,
			error_reply(
				401,
				"unauthenticated",
				"A token is required: send Authorization: Bot <token> or add ?token=<token>.",
			),
			false,
		)
		return
	}
	if r, limited := rate_take(g, &j.key); limited {
		send(c, r, false)
		return
	}
	j.params[0] = net.endpoint_to_string(c.remote, context.temp_allocator)
	key := http.header(req, "Sec-WebSocket-Key")
	if !strings.equal_fold(http.header(req, "Upgrade"), "websocket") || key == "" {
		send(
			c,
			error_reply(
				400,
				"invalid",
				"This endpoint is a WebSocket: send a GET request with the header Upgrade: websocket.",
			),
			false,
		)
		return
	}
	if resume, given := http.query_value(req.query, "resume"); given {
		s, ok := parse_u64(resume)
		if !ok {
			send(
				c,
				error_reply(
					400,
					"invalid",
					"resume must be the last s value the socket received.",
				),
				false,
			)
			return
		}
		j.scratch = {s, 1, 0}
	}
	r := submit(g, &j)
	if r.status != 101 {
		send(c, r, false)
		return
	}
	f := j.feed
	defer feed_release(f)
	accept := strings.concatenate(
		{
			"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ",
			http.accept_key(key),
			"\r\n\r\n",
		},
		context.temp_allocator,
	)
	if !http.send_all(c.sock, transmute([]u8)accept) {
		feed_set_gone(f)
		return
	}
	// A live client answers pings, so one that stays silent has gone away.
	idle_timeout(c, EVENTS_IDLE)
	writer := thread.create_and_start_with_poly_data2(
		f,
		c.sock,
		feed_writer,
		init_context = context,
	)
	payload: [http.MAX_FRAME]u8
	loop: for {
		op, n, ok := http.read_frame(c, payload[:])
		if !ok {
			break
		}
		#partial switch op {
		case .Ping:
			sync.guard(&f.write_mutex)
			http.write_frame(c.sock, .Pong, payload[:n])
		case .Close:
			{
				sync.guard(&f.write_mutex)
				http.write_frame(c.sock, .Close, payload[:min(n, 2)])
			}
			break loop
		case .Text, .Binary, .Pong:
		// Anything the bot sends is ignored.
		case:
			break loop
		}
	}
	feed_set_gone(f)
	thread.join(writer)
	thread.destroy(writer)
}

@(private)
feed_set_gone :: proc(f: ^Feed) {
	sync.guard(&f.mutex)
	f.gone = true
	sync.cond_signal(&f.cond)
}

// feed_writer sends the frames put in the Feed, a ping after PING_EVERY
// without any frames, and the close frame when the gateway closes the Feed.
// After the close it shuts down the socket so the reader stops too.
@(private)
feed_writer :: proc(f: ^Feed, sock: net.TCP_Socket) {
	frames: [dynamic]string
	defer delete(frames)
	for {
		closing, gone, ping: bool
		code: u16
		reason: string
		{
			sync.guard(&f.mutex)
			for len(f.frames) == 0 && !f.closing && !f.gone {
				if !sync.cond_wait_with_timeout(&f.cond, &f.mutex, PING_EVERY) {
					ping = true
					break
				}
			}
			frames, f.frames = f.frames, frames
			closing, gone, code, reason = f.closing, f.gone, f.close_code, f.close_reason
		}
		ok := !gone
		for frame in frames {
			if ok {
				sync.guard(&f.write_mutex)
				ok = http.write_frame(sock, .Text, transmute([]u8)frame)
			}
			delete(frame)
		}
		clear(&frames)
		if ok && ping {
			sync.guard(&f.write_mutex)
			ok = http.write_frame(sock, .Ping, nil)
		}
		if !ok || gone {
			break
		}
		if closing {
			payload := make([]u8, 2 + len(reason), context.temp_allocator)
			payload[0], payload[1] = u8(code >> 8), u8(code)
			copy(payload[2:], reason)
			{
				sync.guard(&f.write_mutex)
				http.write_frame(sock, .Close, payload)
			}
			net.shutdown(sock, .Both)
			break
		}
	}
}

@(private)
parse_u64 :: proc(s: string) -> (u64, bool) {
	n: u64
	if len(s) == 0 || len(s) > 20 {
		return 0, false
	}
	for ch in transmute([]u8)s {
		if ch < '0' || ch > '9' {
			return 0, false
		}
		n = n * 10 + u64(ch - '0')
	}
	return n, true
}

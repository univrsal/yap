package conn

import log "common:wlog"
import "core:slice"
import "core:time"

import "common:proto"

_ :: time // only used when proto.STREAM_FLOOD

/*
Requests to the server and what comes back (src/common/proto/rpc.odin).

request sends one and remembers who wants the answer. Each gets exactly
one: the server's response, or Status.Reset if the connection started
over first. Either way `done` is called on the network thread, with the
response's body only valid during the call.
*/

// What a request's answer is handed to. `tag` is whatever was given to
// request, for telling one request from another of the same kind.
Request_Done :: #type proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64)

@(private = "file")
Request_Pending :: struct {
	op:   proto.Request_Op,
	done: Request_Done, // may be nil
	tag:  u64,
}

Rpc_Client :: struct {
	last_id: u32,
	pending: map[u32]Request_Pending,
	// What the server says about itself, once it has (Server_Info).
	server:  Server_Details,
}

Server_Details :: struct {
	known:          bool,
	name:           string, // owned; may be empty
	version:        string, // owned
	// How big a file attached to a message may be; 0 if it takes none.
	max_attachment: u64,
	registration:   proto.Registration_Flags,
	email:          string, // where verifying mail goes; owned
	// What it's for (owned), and its picture: the id it goes by, and its
	// JPEG once fetched (owned; nil until then). See server_info.odin.
	description:    string,
	icon:           proto.Blob_Id,
	icon_jpeg:      []u8,
}

rpc_destroy :: proc(c: ^Voice_Client) {
	delete(c.rpc.pending)
	delete(c.rpc.server.name)
	delete(c.rpc.server.version)
	delete(c.rpc.server.email)
	delete(c.rpc.server.description)
	delete(c.rpc.server.icon_jpeg)
	c.rpc = {}
}

// request asks the server for `op`. `done` hears how it went.
request :: proc(
	c: ^Voice_Client,
	op: proto.Request_Op,
	body: []u8 = nil,
	done: Request_Done = nil,
	tag: u64 = 0,
) {
	r := &c.rpc
	r.last_id += 1
	id := r.last_id
	r.pending[id] = {op, done, tag}
	msg := proto.encode_request(id, op, body)
	if msg == nil {
		log.errorf("a %v request of %d bytes doesn't fit in a message", op, len(body))
		delete_key(&r.pending, id)
		if done != nil {
			done(c, .Too_Large, nil, tag)
		}
		return
	}
	stream_send(c, msg)
}

// rpc_restart gives up on every request still waiting: the connection
// they were sent on is gone.
rpc_restart :: proc(c: ^Voice_Client) {
	r := &c.rpc
	if len(r.pending) == 0 {
		return
	}
	// In the order they were asked, and from a copy: a `done` may well
	// ask again.
	ids, _ := slice.map_keys(r.pending, context.temp_allocator)
	slice.sort(ids)
	waiting := make([]Request_Pending, len(ids), context.temp_allocator)
	for id, i in ids {
		waiting[i] = r.pending[id]
	}
	clear(&r.pending)
	for p in waiting {
		log.debugf("request %v was lost with the connection", p.op)
		if p.done != nil {
			p.done(c, .Reset, nil, p.tag)
		}
	}
}

// rpc_handle takes one message off the stream.
rpc_handle :: proc(c: ^Voice_Client, msg: []u8) {
	kind, ok := proto.app_kind(msg)
	if !ok {
		return // from a server that knows more than we do
	}
	switch kind {
	case .Response:
		id, status, body := proto.decode_response(msg)
		p, waiting := c.rpc.pending[id]
		if !waiting {
			return
		}
		delete_key(&c.rpc.pending, id)
		if status != .Ok {
			log.debugf("request %v: %v", p.op, status)
		}
		if p.done != nil {
			p.done(c, status, body, p.tag)
		}
	case .Event:
		// One we don't know is from a newer server, and left alone.
		op, body := proto.decode_event(msg)
		if !auth_event(c, op, body) &&
		   !server_info_event(c, op, body) &&
		   !conv_event(c, op, body) &&
		   !messages_event(c, op, body) &&
		   !buddies_event(c, op, body) &&
		   !emoji_event(c, op, body) &&
		   !profiles_event(c, op, body) &&
		   !calls_event(c, op, body) {
			log.debugf("ignoring event %d", u16(op))
		}
	case .Request:
	// Servers don't ask.
	}
}

// server_info_ask asks the server what it calls itself; the answer
// ends up in the View.
server_info_ask :: proc(c: ^Voice_Client) {
	c.rpc.server.known = false
	request(c, .Server_Info, nil, server_info_done)
}

// rpc_step is the requests' turn in the network loop. They need none,
// except when testing (see proto.STREAM_FLOOD).
rpc_step :: proc(c: ^Voice_Client) {
	when proto.STREAM_FLOOD {
		@(static) last: time.Tick
		if !c.has_instance || time.tick_since(last) < 2 * time.Second {
			return
		}
		last = time.tick_now()
		body := make([]u8, proto.STREAM_FLOOD_SIZE, context.temp_allocator)
		request(c, .Server_Info, body, server_info_done)
	}
}

@(private = "file")
server_info_done :: proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
	if status != .Ok {
		return // Reset: it's asked again on the new connection
	}
	if !server_info_take(c, body) {
		return
	}
	s := &c.rpc.server
	when proto.STREAM_FLOOD {
		log.infof("flood: %d bytes came back", len(body))
		if s.known {
			return
		}
	}
	s.known = true
	if s.name != "" {
		log.infof("%s is %q, yap-server %s", c.server_addr, s.name, s.version)
	} else {
		log.infof("%s runs yap-server %s", c.server_addr, s.version)
	}
	if .Open in s.registration {
		log.infof(
			"%s takes registrations%s%s",
			c.server_addr,
			", with an email address" if .Email in s.registration else "",
			", with an invite code" if .Invite in s.registration else "",
		)
	}
	publish_server(c)
}

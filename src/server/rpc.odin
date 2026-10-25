package server

import "core:log"
import "core:time"

import "common:proto"

// Requests are defined in src/common/proto/rpc.odin. They arrive on a user's
// stream and each is answered exactly once with respond. Events are sent to
// the user on the same stream.

// Each connection may make REQUEST_BURST worth of requests at once, then
// REQUEST_RATE worth a second (request_cost says what a request is worth).
// Requests beyond that are answered with Rate_Limited without being handled.
// The server handles every request in its one loop, which also relays
// everybody's voice, so one client mustn't be able to keep it busy: a search
// can take up to SEARCH_BUDGET, and all of a stream's window can arrive at
// once.
REQUEST_BURST :: 200
REQUEST_RATE :: 40

// request_cost says how much of a connection's requests (REQUEST_BURST) a
// request uses up.
request_cost :: proc(op: proto.Request_Op) -> f32 {
	#partial switch op {
	case .Msg_Search:
		return 10 // up to SEARCH_BUDGET of the loop's time
	case .Server_Icon:
		return 4 // up to MAX_SERVER_ICON_SIZE to send
	case .Msg_Post, .Msg_Forward:
		return 3 // stored, sent to every member, maybe pushed
	case .Msg_History:
		return 2
	}
	return 1
}

// request_take takes what a request costs from the connection's requests,
// if there's enough left.
request_take :: proc(u: ^Conn, op: proto.Request_Op) -> bool {
	proto.bucket_refill(&u.requests, time.tick_now(), REQUEST_RATE, REQUEST_BURST)
	return proto.bucket_take(&u.requests, f64(request_cost(op)))
}

// rpc_handle takes one message off a user's stream.
rpc_handle :: proc(s: ^Server, u: ^Conn, msg: []byte) {
	kind, ok := proto.app_kind(msg)
	if !ok || kind != .Request {
		// Clients only send requests. Anything else comes from a newer
		// build that knows more message kinds than this one, so it is ignored.
		log.debugf("%s sent something that isn't a request", conn_label(u))
		return
	}
	id, op, request := proto.decode_request(msg)
	if !s.requests_unlimited && !request_take(u, op) {
		if !u.request_warned {
			log.warnf("%s makes too many requests, refusing some", conn_label(u))
			u.request_warned = true
		}
		respond(u, id, .Rate_Limited)
		return
	}
	u.request_warned = false
	// A connection that isn't logged in may only request server info,
	// log in and register. Everything else is denied (traffic outside
	// the stream is restricted the same way, see handle_data).
	if u.account == nil &&
	   op != .Server_Info &&
	   op != .Server_Icon &&
	   op != .Auth_Login &&
	   op != .Register {
		respond(u, id, .Unauthenticated)
		return
	}
	// An account whose email address isn't verified yet may only change its
	// address, log out or delete the account (see verify.odin).
	if u.account != nil && .Unverified in u.account.flags {
		#partial switch op {
		case .Server_Info, .Server_Icon, .Email_Set, .Auth_Logout, .Account_Delete:
		case:
			respond(u, id, .Denied)
			return
		}
	}
	#partial switch op {
	case .Server_Info:
		body := server_info_body(s) // server_info.odin
		if body == nil {
			respond(u, id, .Internal)
			break
		}
		when proto.STREAM_FLOOD {
			// The data that came with the request is sent back after the answer.
			padded := make([]u8, len(body) + len(request), context.temp_allocator)
			copy(padded, body)
			copy(padded[len(body):], request)
			body = padded
		} else {
			_ = request
		}
		respond(u, id, .Ok, body)
	case .Server_Icon:
		server_icon_request(s, u, id, request)
	case:
		if !auth_request(s, u, id, op, request) &&
		   !server_info_request(s, u, id, op, request) &&
		   !conv_request(s, u, id, op, request) &&
		   !buddy_request(s, u, id, op, request) &&
		   !message_request(s, u, id, op, request) &&
		   !role_request(s, u, id, op, request) &&
		   !moderation_request(s, u, id, op, request) &&
		   !bot_request(s, u, id, op, request) &&
		   !call_request(s, u, id, op, request) &&
		   !push_request(s, u, id, op, request) {
			log.debugf("%s asked for unknown op %d", conn_label(u), u16(op))
			respond(u, id, .Unknown_Op)
		}
	}
}

// respond sends the answer to request `id` of a user.
respond :: proc(u: ^Conn, id: u32, status: proto.Status, body: []byte = nil) {
	msg := proto.encode_response(id, status, body)
	if msg == nil {
		log.errorf("a response of %d bytes doesn't fit in a message", len(body))
		msg = proto.encode_response(id, .Internal, nil)
	}
	stream_send(u, msg)
}

// send_event notifies a user that something happened.
send_event :: proc(u: ^Conn, op: proto.Event_Op, body: []byte = nil) {
	msg := proto.encode_event(op, body)
	if msg == nil {
		log.errorf("an event of %d bytes doesn't fit in a message", len(body))
		return
	}
	stream_send(u, msg)
}

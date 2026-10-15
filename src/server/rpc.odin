package server

import "core:log"

import "common:proto"

// Requests are defined in src/common/proto/rpc.odin. They arrive on a user's
// stream and each is answered exactly once with respond. Events are sent to
// the user on the same stream.

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

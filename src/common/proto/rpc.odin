package proto

import "core:encoding/endian"

/*
What travels on the reliable stream (stream.odin): requests from the
client, each answered by one response, and events from the server. The
first byte of a stream message says which it is.

	client -> server  Request   [1][id u32][op u16][body]
	server -> client  Response  [2][id u32][status u8][body]
	server -> client  Event     [3][op u16][body]

`id` counts up from 1 for each connection, and the response to a request
carries its id. Responses can come in another order than the requests
went: some take the server longer than others.

The stream delivers each message once, so none of this is resent or
checked for duplicates. When a connection starts over (see Welcome in
names.odin) the requests still waiting for their responses are lost with
it, and the client gives up on them with Status.Reset.

A server answers a request whose op it doesn't know with Unknown_Op, and
a client ignores an event whose op it doesn't know, so either end can be
a little older than the other.

A body's layout goes by its op:

	Server_Info  request   (nothing)
	             response  [name str8][version str8]

where str8 is [len u8][bytes]; the rest are in accounts.odin,
buddies.odin, convs.odin and msgs.odin. A body may grow at its end: a decoder
ignores what follows the fields it knows.
*/

App_Kind :: enum u8 {
	Request  = 1,
	Response = 2,
	Event    = 3,
}

Request_Op :: enum u16 {
	Server_Info          = 0x0001,
	// Accounts and devices, see accounts.odin.
	Auth_Login           = 0x0010,
	Account_Create       = 0x0011,
	Auth_Logout          = 0x0012,
	Password_Change      = 0x0013,
	Device_List          = 0x0014,
	Device_Revoke        = 0x0015,
	Account_Password_Set = 0x0016,
	Profile_Set          = 0x0020,
	Setting_Set          = 0x0021,
	// Buddies and when people were last here, see buddies.odin.
	Buddy_Set            = 0x0022,
	Last_Seen            = 0x0023,
	// Online, away, busy or offline, see activity.odin.
	Activity_Set         = 0x0024,
	Idle_Set             = 0x0025,
	// Conversations and voice rooms, see convs.odin.
	Conv_Create          = 0x0030,
	Conv_Update          = 0x0031,
	Conv_Delete          = 0x0032,
	Conv_Browse          = 0x0033,
	Conv_Subscribe       = 0x0034,
	Conv_Member_Set      = 0x0035,
	Conv_Members         = 0x0036,
	Conv_Notify          = 0x0037,
	DM_Open              = 0x0038,
	Voice_Join           = 0x0039,
	// 0x003A was Conv_View, while chat was still streamed per channel.
	// Messages, see msgs.odin.
	Msg_Post             = 0x0040,
	Msg_History          = 0x0041,
	Msg_Edit             = 0x0042,
	Msg_Delete           = 0x0043,
	Msg_React            = 0x0044,
	Msg_Pin              = 0x0045,
	Pins_Get             = 0x0046,
	Mark_Read            = 0x0047,
	Reactors_Get         = 0x0048,
	Msg_Forward          = 0x0049,
	Msg_Search           = 0x004A, // search.odin
	// Roles, see roles.odin.
	Role_Set             = 0x0070,
	Role_Delete          = 0x0071,
	Account_Roles_Set    = 0x0072,
	Account_Disable      = 0x0073,
	// Calls, see calls.odin.
	Call_Start           = 0x0080,
	Call_Accept          = 0x0081,
	Call_End             = 0x0082,
	// Purging old messages, see purge.odin.
	Purge                = 0x0090,
	Blob_Put             = 0x0050,
	Blob_Get             = 0x0051,
}

Event_Op :: enum u16 {
	// Around what a connection is told when it logs in: everything
	// between them is how things are, not news.
	Sync_Begin      = 0x0001,
	Sync_End        = 0x0002,
	// See accounts.odin.
	Self            = 0x0003,
	Account_Changed = 0x0010,
	Role_Changed    = 0x0011,
	Role_Removed    = 0x0012,
	Setting_Changed = 0x0020,
	Logged_Out      = 0x0013,
	// See buddies.odin.
	Buddy_Changed   = 0x0021,
	// See convs.odin.
	Conv_Changed    = 0x0030,
	Conv_Removed    = 0x0031,
	Read_Changed    = 0x0032,
	Voice_Moved     = 0x0033,
	// See msgs.odin.
	Msg_New         = 0x0040,
	Msg_Changed     = 0x0041,
	Reaction_Changed = 0x0042,
	// See purge.odin.
	Msgs_Purged     = 0x0043,
	// See emoji.odin.
	Emoji_Sheet     = 0x0060,
	// See calls.odin.
	Call_Ring       = 0x0080,
	Call_Changed    = 0x0081,
}

Status :: enum u8 {
	Ok              = 0,
	Unknown_Op      = 1,
	Invalid         = 2, // malformed, or a value out of range
	Unauthenticated = 3, // not logged in
	Denied          = 4, // lacks the permission
	Not_Found       = 5,
	Conflict        = 6, // name taken, already exists
	Too_Large       = 7,
	Rate_Limited    = 8,
	Wrong_Password  = 9,
	Closed          = 10,
	Internal        = 11,
	// Never sent: what a client makes of a request whose connection
	// started over before the response came.
	Reset           = 255,
}

REQUEST_HEADER_SIZE :: 1 + 4 + 2
RESPONSE_HEADER_SIZE :: 1 + 4 + 1
EVENT_HEADER_SIZE :: 1 + 2
// The most a body can be, whichever of them it's in.
MAX_BODY_SIZE :: STREAM_MAX_MESSAGE - REQUEST_HEADER_SIZE

/*
Testing aid: built with -define:YAP_STREAM_FLOOD=true, a client sends a
Server_Info request with STREAM_FLOOD_SIZE bytes of body every couple of
seconds, and a server built the same way sends them back after its
answer (where a decoder ignores them). That puts large messages on the
stream in both directions, to see what it does to voice.
*/
STREAM_FLOOD :: #config(YAP_STREAM_FLOOD, false)
STREAM_FLOOD_SIZE :: 60_000

// What a server calls itself, in bytes of UTF-8.
MAX_SERVER_NAME :: 64

// app_kind is which of the three a stream message is.
app_kind :: proc(msg: []u8) -> (kind: App_Kind, ok: bool) {
	if len(msg) == 0 {
		return
	}
	kind = App_Kind(msg[0])
	switch kind {
	case .Request:
		ok = len(msg) >= REQUEST_HEADER_SIZE
	case .Response:
		ok = len(msg) >= RESPONSE_HEADER_SIZE
	case .Event:
		ok = len(msg) >= EVENT_HEADER_SIZE
	}
	return
}

// encode_request returns a Request as a new slice; nil if the body is
// longer than one may be.
encode_request :: proc(
	id: u32,
	op: Request_Op,
	body: []u8,
	allocator := context.temp_allocator,
) -> []u8 {
	if len(body) > MAX_BODY_SIZE {
		return nil
	}
	out := make([]u8, REQUEST_HEADER_SIZE + len(body), allocator)
	out[0] = u8(App_Kind.Request)
	endian.unchecked_put_u32le(out[1:], id)
	endian.unchecked_put_u16le(out[5:], u16(op))
	copy(out[REQUEST_HEADER_SIZE:], body)
	return out
}

// decode_request reads a Request (see app_kind); the body points into
// `msg`. The op may be one this build has no name for.
decode_request :: proc(msg: []u8) -> (id: u32, op: Request_Op, body: []u8) {
	return endian.unchecked_get_u32le(msg[1:]),
		Request_Op(endian.unchecked_get_u16le(msg[5:])),
		msg[REQUEST_HEADER_SIZE:]
}

encode_response :: proc(
	id: u32,
	status: Status,
	body: []u8,
	allocator := context.temp_allocator,
) -> []u8 {
	if len(body) > MAX_BODY_SIZE {
		return nil
	}
	out := make([]u8, RESPONSE_HEADER_SIZE + len(body), allocator)
	out[0] = u8(App_Kind.Response)
	endian.unchecked_put_u32le(out[1:], id)
	out[5] = u8(status)
	copy(out[RESPONSE_HEADER_SIZE:], body)
	return out
}

decode_response :: proc(msg: []u8) -> (id: u32, status: Status, body: []u8) {
	return endian.unchecked_get_u32le(msg[1:]), Status(msg[5]), msg[RESPONSE_HEADER_SIZE:]
}

encode_event :: proc(op: Event_Op, body: []u8, allocator := context.temp_allocator) -> []u8 {
	if len(body) > MAX_BODY_SIZE {
		return nil
	}
	out := make([]u8, EVENT_HEADER_SIZE + len(body), allocator)
	out[0] = u8(App_Kind.Event)
	endian.unchecked_put_u16le(out[1:], u16(op))
	copy(out[EVENT_HEADER_SIZE:], body)
	return out
}

decode_event :: proc(msg: []u8) -> (op: Event_Op, body: []u8) {
	return Event_Op(endian.unchecked_get_u16le(msg[1:])), msg[EVENT_HEADER_SIZE:]
}

// Server_Info is what a server says about itself.
Server_Info :: struct {
	name:    string, // may be empty
	version: string, // of yap-server, as its log says when it starts
}

SERVER_INFO_MAX_SIZE :: 1 + MAX_SERVER_NAME + 1 + 255

// encode_server_info writes a Server_Info response's body.
@(require_results)
encode_server_info :: proc(out: []u8, info: Server_Info) -> (body: []u8, ok: bool) {
	if len(info.name) > MAX_SERVER_NAME {
		return
	}
	w := Writer {
		buf = out,
	}
	put_str8(&w, info.name)
	put_str8(&w, info.version)
	if w.overflow {
		return
	}
	return out[:w.pos], true
}

// decode_server_info reads one; the strings point into `body`, and
// are as the server sent them: sanitize before showing them.
@(require_results)
decode_server_info :: proc(body: []u8) -> (info: Server_Info, ok: bool) {
	r := Reader {
		buf = body,
	}
	info.name = get_str8(&r)
	info.version = get_str8(&r)
	if r.overflow || len(info.name) > MAX_SERVER_NAME {
		return {}, false
	}
	return info, true
}

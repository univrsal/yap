package proto

import "core:encoding/endian"

// This is what travels on the reliable stream (stream.odin): requests from
// the client, each answered by exactly one response, and events from the
// server. The first byte of a stream message says which of them it is.
//
//	client -> server  Request   [1][id u32][op u16][body]
//	server -> client  Response  [2][id u32][status u8][body]
//	server -> client  Event     [3][op u16][body]
//
// `id` counts up from 1 for each connection, and a response carries the id
// of its request. Responses can arrive in a different order than the
// requests were sent, because some requests take the server longer than
// others.
//
// The stream delivers each message exactly once, so nothing here is resent
// or checked for duplicates. When a connection starts over (see Welcome in
// hello.odin), the requests that are still waiting for a response are lost
// with it, and the client gives up on them with Status.Reset.
//
// A server answers a request with an op it doesn't know with Unknown_Op, and
// a client ignores an event with an op it doesn't know, so either side can
// be somewhat older than the other.
//
// The layout of a body depends on its op:
//
//	Server_Info      request   (nothing)
//	                 response  [name str8][version str8][max_attachment u64]
//	                           [registration u8] (register.odin)[email str8]
//	                           [description str16][icon u64][digests u8]
//	                           [media_port u16][video_kbit u32][push_key str8]
//	                           [max_cameras u8][camera_kbit u32][demand u8]
//	Server_Icon      request   [icon u64]
//	                 response  [the icon's JPEG]
//	Server_Info_Set  request   [name str8][description str16][icon u64]
//	                 response  (nothing)
//	Server_Info      event     as Server_Info's response, when it changes
//	Server_Memory    request   (nothing; the owner only)
//	                 response  [a memory report, as text] (common/memtrack/report.odin)
//
// where str8 is [len u8][bytes] and str16 is [len u16][bytes]. The remaining
// ops are described in accounts.odin, buddies.odin, convs.odin, messages.odin,
// moderation.odin and push.odin. A body may grow at its end: a decoder ignores whatever follows
// the fields it knows.

App_Kind :: enum u8 {
	Request  = 1,
	Response = 2,
	Event    = 3,
}

Request_Op :: enum u16 {
	Server_Info          = 0x0001,
	// The server's icon, which can be requested before logging in, and
	// changing what Server_Info says (the owner only).
	Server_Icon          = 0x0002,
	Server_Info_Set      = 0x0003,
	// The server's memory usage report (the owner only).
	Server_Memory        = 0x0004,
	// Accounts and devices, see accounts.odin.
	Auth_Login           = 0x0010,
	Account_Create       = 0x0011,
	Auth_Logout          = 0x0012,
	Password_Change      = 0x0013,
	Device_List          = 0x0014,
	Device_Revoke        = 0x0015,
	Account_Password_Set = 0x0016,
	Account_Delete       = 0x0017,
	Email_Set            = 0x0018,
	// Registering and invite codes, see register.odin.
	Register             = 0x0019,
	Invite_Create        = 0x001A,
	Invite_List          = 0x001B,
	Invite_Revoke        = 0x001C,
	Invite_Of            = 0x001D,
	// Bot accounts and their tokens, see bots.odin.
	Bot_Create           = 0x001E,
	Bot_Token_Add        = 0x001F,
	Profile_Set          = 0x0020,
	Setting_Set          = 0x0021,
	// Buddies and when people were last online, see buddies.odin.
	Buddy_Set            = 0x0022,
	Last_Seen            = 0x0023,
	// Online, away, busy or offline, see activity.odin.
	Activity_Set         = 0x0024,
	Idle_Set             = 0x0025,
	// Web Push subscriptions, see push.odin.
	Push_Subscribe       = 0x0026,
	Push_Unsubscribe     = 0x0027,
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
	Conv_Rights_Get      = 0x003B,
	Group_Open           = 0x003F,
	Conv_Rights_Set      = 0x003C,
	// Moving and muting people in voice, see moderation.odin.
	Voice_Move           = 0x003D,
	Voice_Mute           = 0x003E,
	// Messages, see messages.odin.
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
	Role_Order           = 0x0074,
	// Bans, see moderation.odin.
	Ban_Set              = 0x0075,
	Ban_List             = 0x0076,
	// Calls, see calls.odin.
	Call_Start           = 0x0080,
	Call_Accept          = 0x0081,
	Call_End             = 0x0082,
	// Purging old messages, see purge.odin.
	Purge                = 0x0090,
	Blob_Put             = 0x0050,
	Blob_Get             = 0x0051,
	// Attachments, see attachments.odin.
	Attach_Put           = 0x0052,
	Attach_Get           = 0x0053,
}

Event_Op :: enum u16 {
	// These two mark the start and end of what a connection is told when it
	// logs in. Everything between them describes the current state and is not
	// news.
	Sync_Begin       = 0x0001,
	Sync_End         = 0x0002,
	// See accounts.odin.
	Self             = 0x0003,
	// What the server says about itself has changed (Server_Info_Set).
	Server_Info      = 0x0004,
	Account_Changed  = 0x0010,
	Role_Changed     = 0x0011,
	Role_Removed     = 0x0012,
	Setting_Changed  = 0x0020,
	Logged_Out       = 0x0013,
	// See buddies.odin.
	Buddy_Changed    = 0x0021,
	// See convs.odin.
	Conv_Changed     = 0x0030,
	Conv_Removed     = 0x0031,
	Read_Changed     = 0x0032,
	Voice_Moved      = 0x0033,
	// See messages.odin.
	Msg_New          = 0x0040,
	Msg_Changed      = 0x0041,
	Reaction_Changed = 0x0042,
	// See purge.odin.
	Msgs_Purged      = 0x0043,
	// See emoji.odin.
	Emoji_Sheet      = 0x0060,
	// See calls.odin.
	Call_Ring        = 0x0080,
	Call_Changed     = 0x0081,
}

Status :: enum u8 {
	Ok              = 0,
	Unknown_Op      = 1,
	Invalid         = 2, // malformed or a value is out of range
	Unauthenticated = 3, // not logged in
	Denied          = 4, // the permission is missing
	Not_Found       = 5,
	Conflict        = 6, // the name is taken or the thing already exists
	Too_Large       = 7,
	Rate_Limited    = 8,
	Wrong_Password  = 9,
	Closed          = 10,
	Internal        = 11,
	Quota           = 12, // the account has used its allowance, such as for uploads
	// The account is banned (moderation.odin). It answers a login with the
	// right password, and the body is [reason str8].
	Banned          = 13,
	// Never sent by a server. A client uses it for a request whose
	// connection started over before the response arrived.
	Reset           = 255,
}

REQUEST_HEADER_SIZE :: 1 + 4 + 2
RESPONSE_HEADER_SIZE :: 1 + 4 + 1
EVENT_HEADER_SIZE :: 1 + 2
// The maximum size of a body, for requests, responses and events alike.
MAX_BODY_SIZE :: STREAM_MAX_MESSAGE - REQUEST_HEADER_SIZE

// Testing aid: when built with -define:YAP_STREAM_FLOOD=true, a client sends
// a Server_Info request with STREAM_FLOOD_SIZE bytes of body every couple of
// seconds, and a server built the same way sends that many bytes back after
// its answer (where a decoder ignores them). This puts large messages on the
// stream in both directions to test how that affects voice.
STREAM_FLOOD :: #config(YAP_STREAM_FLOOD, false)
STREAM_FLOOD_SIZE :: 60_000

// The maximum length of a server's name in bytes of UTF-8.
MAX_SERVER_NAME :: 64

// app_kind returns which of the three kinds a stream message is.
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

// encode_request returns a Request as a new slice, or nil if the body is
// too long.
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

// decode_request reads a Request (see app_kind). The body points into
// `msg`. The op may be one that this build doesn't know.
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
	name:           string, // may be empty
	version:        string, // the yap-server version, as it is logged on startup
	max_attachment: u64, // maximum size in bytes of a file attached to a message, 0 for no attachments
	registration:   Registration_Flags, // what registering requires, if it's open
	email:          string, // the server's own email address, "" for none (verify.odin)
	description:    string, // what the server says it is for, may be empty
	icon:           Blob_Id, // the server's icon (Server_Icon), 0 for none
	digests:        bool, // the server emails missed messages to users who want them (SETTING_EMAIL_DIGEST)
	// The port of the server's media link (Link.Media, server/media.odin),
	// 0 for none. Screen sharing then goes over the bulk link.
	media_port:     u16,
	// The maximum video bitrate of one sharer in kbit/s, 0 if the server didn't say.
	video_kbit:     u32,
	// The server's VAPID public key (push.odin), empty if it doesn't support push.
	push_key:       []u8,
	// The most cameras that may be on at once in a channel's room (video.odin),
	// at most MAX_CAMERAS. 0 if cameras are off or the server doesn't know
	// about them.
	max_cameras:    int,
	// The maximum bitrate of one camera in kbit/s.
	camera_kbit:    u32,
	// The server takes the size of a viewer's tile on Watch and tells a
	// camera's sharer what its viewers want (Demand, video.odin).
	demand:         bool,
}

SERVER_INFO_MAX_SIZE ::
	1 +
	MAX_SERVER_NAME +
	1 +
	255 +
	8 +
	1 +
	1 +
	MAX_EMAIL_SIZE +
	2 +
	MAX_SERVER_DESCRIPTION +
	8 +
	1 +
	2 +
	4 +
	1 +
	PUSH_KEY_SIZE +
	1 +
	4 +
	1

// The maximum length of a server's description in bytes of UTF-8.
MAX_SERVER_DESCRIPTION :: 512

// A server's icon is a square JPEG, created like a profile picture
// (Blob_Kind.Avatar) but smaller, so that it fits in one response.
MAX_SERVER_ICON_SIDE :: 128
MAX_SERVER_ICON_SIZE :: 32 * 1024

// Server_Info_Set is what the server should say about itself.
Server_Info_Set :: struct {
	name:        string,
	description: string,
	icon:        Blob_Id, // 0 for none
}

SERVER_INFO_SET_MAX_SIZE :: 1 + MAX_SERVER_NAME + 2 + MAX_SERVER_DESCRIPTION + 8

@(require_results)
encode_server_info_set :: proc(out: []u8, set: Server_Info_Set) -> (body: []u8, ok: bool) {
	if len(set.name) > MAX_SERVER_NAME || len(set.description) > MAX_SERVER_DESCRIPTION {
		return
	}
	w := Writer {
		buf = out,
	}
	put_str8(&w, set.name)
	put_str16(&w, set.description)
	put_u64(&w, u64(set.icon))
	if w.overflow {
		return
	}
	return out[:w.pos], true
}

// decode_server_info_set reads a Server_Info_Set body. The strings point into
// `body` and are unsanitized.
@(require_results)
decode_server_info_set :: proc(body: []u8) -> (set: Server_Info_Set, ok: bool) {
	r := Reader {
		buf = body,
	}
	set.name = get_str8(&r)
	set.description = get_str16(&r)
	set.icon = Blob_Id(get_u64(&r))
	if r.overflow ||
	   len(set.name) > MAX_SERVER_NAME ||
	   len(set.description) > MAX_SERVER_DESCRIPTION {
		return {}, false
	}
	return set, true
}

// encode_server_info writes a Server_Info response's body.
@(require_results)
encode_server_info :: proc(out: []u8, info: Server_Info) -> (body: []u8, ok: bool) {
	if len(info.name) > MAX_SERVER_NAME ||
	   len(info.description) > MAX_SERVER_DESCRIPTION ||
	   (len(info.push_key) != 0 && len(info.push_key) != PUSH_KEY_SIZE) ||
	   info.max_cameras < 0 ||
	   info.max_cameras > MAX_CAMERAS {
		return
	}
	w := Writer {
		buf = out,
	}
	put_str8(&w, info.name)
	put_str8(&w, info.version)
	put_u64(&w, info.max_attachment)
	put_u8(&w, transmute(u8)info.registration)
	put_str8(&w, info.email)
	put_str16(&w, info.description)
	put_u64(&w, u64(info.icon))
	put_u8(&w, 1 if info.digests else 0)
	put_u16(&w, info.media_port)
	put_u32(&w, info.video_kbit)
	put_u8(&w, u8(len(info.push_key)))
	put_bytes(&w, info.push_key)
	put_u8(&w, u8(info.max_cameras))
	put_u32(&w, info.camera_kbit)
	put_u8(&w, 1 if info.demand else 0)
	if w.overflow {
		return
	}
	return out[:w.pos], true
}

// decode_server_info reads a Server_Info body. The strings point into `body`
// and are exactly as the server sent them, so sanitize them before showing
// them.
@(require_results)
decode_server_info :: proc(body: []u8) -> (info: Server_Info, ok: bool) {
	r := Reader {
		buf = body,
	}
	info.name = get_str8(&r)
	info.version = get_str8(&r)
	info.max_attachment = get_u64(&r)
	info.registration = transmute(Registration_Flags)get_u8(&r)
	info.email = get_str8(&r)
	// A server older than these fields doesn't send them.
	if has_more(&r) {
		info.description = get_str16(&r)
		info.icon = Blob_Id(get_u64(&r))
	}
	if has_more(&r) {
		info.digests = get_u8(&r) != 0
	}
	if has_more(&r) {
		info.media_port = get_u16(&r)
		info.video_kbit = get_u32(&r)
	}
	if has_more(&r) {
		info.push_key = get_bytes(&r, int(get_u8(&r)))
	}
	if has_more(&r) {
		info.max_cameras = min(int(get_u8(&r)), MAX_CAMERAS)
		info.camera_kbit = get_u32(&r)
	}
	if has_more(&r) {
		info.demand = get_u8(&r) != 0
	}
	if r.overflow ||
	   (len(info.push_key) != 0 && len(info.push_key) != PUSH_KEY_SIZE) ||
	   len(info.name) > MAX_SERVER_NAME ||
	   len(info.description) > MAX_SERVER_DESCRIPTION {
		return {}, false
	}
	return info, true
}

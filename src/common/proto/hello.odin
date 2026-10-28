package proto

import "core:encoding/endian"

// Hello is the encrypted payload of Handshake_Finish (msg3). It says which
// of the client's connections this is and carries the server password if
// the server asks for one.
//
//	[version u8 = 12][conn_id u64][link u8][password_len u8][password]
//
// The version prevents a client and a server that disagree about the wire
// format from misreading each other's messages: the server refuses a hello
// it can't read (see Refused in datagrams.odin).
// Version 2 added the sound flags to a snapshot's users (see datagrams.odin).
// Version 3 widened a chat entry's time to 64 bits (chat entries were
// retired in version 8).
// Version 4 added the password, and Refused.
// Version 5 added conn_id, and Welcome.
// Version 6 removed the name from the hello because it belongs to the account
// now (accounts.odin). The snapshot's users no longer carry names and
// reference their account instead.
// Version 7 removed the channels from the snapshot. Its users now say which
// voice room they are in (convs.odin), and Join was retired.
// Version 8 retired the chat and image kinds for messages stored by the
// server (messages.odin), and Typing now names a conversation.
// Version 9 retired the direct message and last-seen kinds (DMs are
// conversations now), removed the device's key from the snapshot's users,
// and made file transfers name accounts (files.odin).
// Version 10 added attachments, which are a message's files (messages.odin), and
// the datagrams that carry them (transfer.odin, attachments.odin).
// Version 12 added `link`, which says which of the connection's two links the
// handshake is for (see Link below).
// Version 13 retired the picture kind of message and purging only pictures,
// because a picture in a message is an attachment (messages.odin).
// Version 14 added the time of the newest message to a conversation's record,
// which a list of DMs from several servers is put in order by (convs.odin).
// Version 16 added groups (convs.odin): a conversation's record lists the
// accounts a DM or a group is between instead of a DM's two accounts.
// Version 17 raised the limits to Mattermost's: longer messages, names,
// topics and statuses (which now have 2-byte lengths), longer stream messages,
// and Pins_Get answering a page at a time.
// Version 18 gave system messages a text and kinds about channels and the
// server (Conv_System, messages.odin).
// Version 19 added the <@here> mention (mentions.odin).
// Link.Media was added without a new version because it is only ever sent to
// a client by a server that names a media port in Server_Info, and only on
// that port.
//
// `conn_id` is a random number the client picks when it opens a connection
// and sends in every handshake of that connection. A client handshakes again
// every so often to rekey, and the server has to distinguish that from a
// client that started over: a connection has state (such as the reliable
// stream, see stream.odin) that must be kept on a rekey but discarded when
// the client starts over. A `conn_id` that matches the connection the server
// already has for that client is a rekey. Any other `conn_id` means the
// client started over, and the old connection is removed as if the client
// had left. The exception is a second client using the same key: if the old
// connection was heard from within the last couple of seconds at another
// address, it is still in use, and the new hello is refused with
// Already_Connected instead.
//
// Each connection has two links. Each link has its own transport (a UDP
// socket, or a WebSocket on the web) and its own sessions, so that light
// traffic never queues behind heavy traffic:
//
//	Main  voice, pings, the reliable stream, snapshots, typing, watch
//	      leases and keyframe requests, i.e. everything small and urgent
//	Bulk  video fragments, and the chunks of blobs, attachments and
//	      file transfers (HEAVY_KINDS)
//
// A desktop client that shares or watches screens with the yap_video
// library has a third link on its own port (Server_Info's media_port),
// which is served by a separate server thread (server/media.odin):
//
//	Media video fragments, Watch leases and Keyframe requests, nothing
//	      else. Once it is up, video and leases use it instead of the
//	      bulk link (leases are also sent on the main link for sharers
//	      that are on bulk links)
//
// The main link is the connection itself: its hello's conn_id creates or
// continues the connection, and the server times it out. The bulk link joins
// a connection that the main link has already created. It does so with a
// hello that has the same conn_id and link = Bulk, sent through a handshake
// of its own with the same device key. The server binds it to that
// connection, or refuses it with No_Connection so the client can try again
// later. The bulk link is removed when its connection is. Until it is
// established, heavy messages go over the main link.
//
// Welcome is the server's answer to a hello it accepts, the first Data on
// the new session:
//
//	server -> client  Welcome  [kind][instance u64][flags u8]
//
// `instance` is a random number the server gives each connection when it
// creates it. A client that receives the instance it already has simply
// continues, because it has rekeyed. A different instance (or the first one)
// means the connection is new on the server's side: the client just started,
// the server restarted, or the server had given up on the client. The client
// then starts over too and forgets the old connection's state.
// WELCOME_LOGGED_IN in `flags` says that the server knows this device and has
// logged it in to its account. Without it, the client has to log in
// (accounts.odin) before it can do anything else.
//
// Like Refused, it is unreliable, so the server sends a few copies and sends
// them again whenever the client repeats its Handshake_Finish. A client
// accepts nothing else on a new session until the Welcome arrives.
HELLO_VERSION :: 19
MAX_PASSWORD_SIZE :: 64 // bytes
HELLO_MAX_SIZE :: 1 + 8 + 1 + 1 + MAX_PASSWORD_SIZE

// Which of a connection's links a handshake is for.
Link :: enum u8 {
	Main  = 0,
	Bulk  = 1,
	Media = 2, // on the media port
}

// The message kinds that go over the bulk link once there is one.
HEAVY_KINDS :: bit_set[Message_Kind] {
	.Video,
	.Blob_Chunk,
	.Upload_Chunk,
	.Download_Chunk,
	.File_Chunk,
}

// is_heavy says whether a message goes over the bulk link.
is_heavy :: proc(msg: []u8) -> bool {
	return len(msg) > 0 && Message_Kind(msg[0]) in HEAVY_KINDS
}
WELCOME_SIZE :: 1 + 8 + 1

// Welcome flags.
WELCOME_LOGGED_IN :: 1 << 0

// encode_hello writes a hello. A password longer than MAX_PASSWORD_SIZE
// is truncated (and therefore won't match).
encode_hello :: proc(
	out: ^[HELLO_MAX_SIZE]u8,
	conn_id: u64,
	password := "",
	link := Link.Main,
) -> []u8 {
	p := min(len(password), MAX_PASSWORD_SIZE)
	out[0] = HELLO_VERSION
	endian.unchecked_put_u64le(out[1:], conn_id)
	out[9] = u8(link)
	out[10] = u8(p)
	copy(out[11:], password[:p])
	return out[:11 + p]
}

// decode_hello reads a hello. The password is returned unchanged.
decode_hello :: proc(payload: []u8) -> (conn_id: u64, password: string, link: Link, ok: bool) {
	if len(payload) < 11 || payload[0] != HELLO_VERSION || payload[9] > u8(max(Link)) {
		return
	}
	password_len := int(payload[10])
	if len(payload) != 11 + password_len {
		return
	}
	conn_id = endian.unchecked_get_u64le(payload[1:])
	link = Link(payload[9])
	password = string(payload[11:][:password_len])
	return conn_id, password, link, true
}

encode_welcome :: proc(out: ^[WELCOME_SIZE]u8, instance: u64, logged_in: bool) -> []u8 {
	out[0] = u8(Message_Kind.Welcome)
	endian.unchecked_put_u64le(out[1:], instance)
	out[9] = WELCOME_LOGGED_IN if logged_in else 0
	return out[:]
}

decode_welcome :: proc(pt: []u8) -> (instance: u64, logged_in: bool) {
	return endian.unchecked_get_u64le(pt[1:]), pt[9] & WELCOME_LOGGED_IN != 0
}

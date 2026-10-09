package server

import "core:log"
import "core:strings"

import "common:."
import "common:proto"

/*
What the server says about itself (Server_Info): its name, a description
and a picture, besides what it says of its build and of registering.

The name, the description and the picture are the owner's to change
(Server_Info_Set), and every connection that's logged in is told when
they do (the Server_Info event). They're kept in the database's meta
table; the config's name is only what a database starts with.

The picture is a JPEG uploaded the way a profile picture is (a blob of
kind Avatar, transfers.odin), but smaller (MAX_SERVER_ICON_SIZE), so it
fits in the one response to Server_Icon. That may be asked before
logging in, as the client shows it on its login screen; it gives the
server's picture and no other blob. The blob sweep leaves it alone
(retention.odin).
*/

SERVER_NAME_META :: "server_name"
SERVER_DESCRIPTION_META :: "server_description"
SERVER_ICON_META :: "server_icon"

/*
server_info_load takes the name, the description and the picture from
the database, or, from one that has none yet, the config's name. The
strings are owned (server_info_destroy).
*/
server_info_load :: proc(s: ^Server, config_name: string) {
	if name, found := db_meta_text(&s.db, SERVER_NAME_META); found {
		s.name = strings.clone(name)
	} else {
		s.name = strings.clone(config_name)
	}
	description, _ := db_meta_text(&s.db, SERVER_DESCRIPTION_META)
	s.description = strings.clone(description)
	icon, _ := db_meta(&s.db, SERVER_ICON_META)
	s.icon = proto.Blob_Id(icon)
}

server_info_destroy :: proc(s: ^Server) {
	delete(s.name)
	delete(s.description)
	s.name, s.description, s.icon = "", "", 0
}

// server_info_body is Server_Info's answer, and its event, in the temp
// allocator; nil if it doesn't fit (it always should).
server_info_body :: proc(s: ^Server) -> []u8 {
	buf := make([]u8, proto.SERVER_INFO_MAX_SIZE, context.temp_allocator)
	info := proto.Server_Info {
		name           = s.name,
		version        = common.version_string(),
		max_attachment = s.attach.max_size,
		registration   = registration_flags(s),
		email          = s.email.config.address if verify_on(s) else "",
		description    = s.description,
		icon           = s.icon,
	}
	body, ok := proto.encode_server_info(buf, info)
	return body if ok else nil
}

// server_info_request handles the requests about the server itself
// that come after logging in; false if `op` isn't one.
server_info_request :: proc(
	s: ^Server,
	u: ^Conn,
	id: u32,
	op: proto.Request_Op,
	body: []u8,
) -> bool {
	#partial switch op {
	case .Server_Info_Set:
		server_info_set(s, u, id, body)
	case:
		return false
	}
	return true
}

// server_icon_request sends the server's picture: asked for by its id,
// so a client that has it from before can tell whether it changed. May
// be asked before logging in.
server_icon_request :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	blob, ok := proto.decode_blob_id(body)
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	if blob == 0 || blob != s.icon {
		respond(u, id, .Not_Found)
		return
	}
	data, read := blob_read(&s.blobs, blob, context.temp_allocator)
	if !read {
		respond(u, id, .Internal)
		return
	}
	respond(u, id, .Ok, data)
}

@(private = "file")
server_info_set :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	if .Owner not_in u.account.flags {
		respond(u, id, .Denied)
		return
	}
	set, ok := proto.decode_server_info_set(body)
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	if set.icon != 0 {
		if status := icon_ok(s, set.icon); status != .Ok {
			respond(u, id, status)
			return
		}
	}
	name_buf: [proto.MAX_SERVER_NAME]u8
	description_buf: [proto.MAX_SERVER_DESCRIPTION]u8
	name := proto.sanitize_text(set.name, name_buf[:])
	description := proto.sanitize_message(set.description, description_buf[:])
	if !db_meta_set_text(&s.db, SERVER_NAME_META, name) ||
	   !db_meta_set_text(&s.db, SERVER_DESCRIPTION_META, description) ||
	   !db_meta_set(&s.db, SERVER_ICON_META, i64(set.icon)) {
		respond(u, id, .Internal)
		return
	}
	delete(s.name)
	delete(s.description)
	s.name, s.description, s.icon = strings.clone(name), strings.clone(description), set.icon
	log.infof("%s changed what the server says about itself", conn_label(u))
	respond(u, id, .Ok)

	event := server_info_body(s)
	for _, other in s.conns {
		send_event(other, .Server_Info, event)
	}
}

// icon_ok is whether a blob may be the server's picture: a stored JPEG,
// square, and small enough to send in one response.
@(private = "file")
icon_ok :: proc(s: ^Server, blob: proto.Blob_Id) -> proto.Status {
	b, found := blob_get(&s.blobs, blob)
	switch {
	case !found:
		return .Not_Found
	case b.kind != .Avatar || b.width != b.height:
		return .Invalid
	case b.size > proto.MAX_SERVER_ICON_SIZE || b.width > proto.MAX_SERVER_ICON_SIDE:
		return .Too_Large
	}
	return .Ok
}

package server

import "core:log"
import "core:strings"

import "common:."
import "common:proto"

// Information the server provides about itself (Server_Info): its name, a
// description and a picture, plus its build version and registration
// settings.
//
// Only the owner can change the name, description and picture
// (Server_Info_Set). All logged in connections are notified about the
// change with the Server_Info event. The values are stored in the meta table
// of the database. The name in the config is only the initial name for a
// new database.
//
// The picture is a JPEG that is uploaded like a profile picture (a blob of
// kind Avatar, see transfers.odin) but is limited to a smaller size
// (MAX_SERVER_ICON_SIZE) so that it fits in the single response to
// Server_Icon. It can be requested before logging in because the client
// shows it on the login screen. That request only returns the server's
// picture and no other blob. The blob sweep doesn't delete it (see
// retention.odin).

SERVER_NAME_META :: "server_name"
SERVER_DESCRIPTION_META :: "server_description"
SERVER_ICON_META :: "server_icon"

// server_info_load loads the name, description and picture from the
// database. If the database has no name yet, the name from the config is
// used. The strings are owned and freed by server_info_destroy.
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

// server_info_body returns the encoded body of the Server_Info answer and
// event, allocated with the temp allocator. It returns nil if the body
// doesn't fit, which should never happen.
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
		digests        = digest_on(s),
		media_port     = u16(s.media.port) if s.media.enabled else 0,
		video_kbit     = u32(s.media.max_rate * 8 / 1000) if s.media.enabled else 0,
		push_key       = s.push.public[:] if s.push.enabled else nil,
		max_cameras    = s.media.max_cameras if s.media.enabled else 0,
		camera_kbit    = u32(s.media.camera_rate * 8 / 1000) if s.media.enabled else 0,
	}
	body, ok := proto.encode_server_info(buf, info)
	return body if ok else nil
}

// server_info_request handles the requests about the server itself that are
// only allowed after logging in. Returns false if `op` isn't one of them.
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
	case .Server_Memory:
		memory_request(s, u, id) // memory.odin
	case:
		return false
	}
	return true
}

// server_icon_request sends the server's picture. The client asks for it by
// its id so that a client that already has an older picture can tell
// whether it changed. This is allowed before logging in.
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

// icon_ok checks whether a blob can be used as the server's picture, i.e.
// it is a stored square JPEG that is small enough to send in one response.
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

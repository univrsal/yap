package conn

import log "common:wlog"
import "core:crypto/hash"
import "core:strings"

import "common:memtrack"
import "common:proto"

/*
What the server says about itself (Server_Info, rpc.odin): its name,
description and picture, which the UI shows on the rail and on the
login screen. It's asked once a connection is up, before logging in,
and the server says again when it changes (the Server_Info event).

The picture comes from its own request (Server_Icon), which may be asked
before logging in too: only when the server names one we don't have,
so a reconnect doesn't fetch it again.

The owner changes all three with Server_Info_Command. A new picture
goes through the outbox like our own picture does (avatar_set,
profiles.odin): uploaded as a blob first, then named in the
Server_Info_Set that follows (server_info_post).
*/

// Change what the server says about itself (the owner only). With
// `image`, a new picture (taken over); with `remove`, none; with
// neither, the one it has stays.
Server_Info_Command :: struct {
	name:        string, // owned by the command
	description: string, // owned by the command
	image:       Chat_Image,
	remove:      bool,
}

/*
server_info_take reads what the server says about itself, from the
answer to Server_Info or its event, and fetches its picture if it's a
new one. False if it can't be read.
*/
server_info_take :: proc(c: ^Voice_Client, body: []u8) -> bool {
	info, ok := proto.decode_server_info(body)
	if !ok {
		log.warnf("%s sent a Server_Info we can't read", c.server_addr)
		return false
	}
	name_buf: [proto.MAX_SERVER_NAME]u8
	version_buf: [64]u8
	description_buf: [proto.MAX_SERVER_DESCRIPTION]u8
	s := &c.rpc.server
	delete(s.name)
	delete(s.version)
	delete(s.description)
	s.name = strings.clone(proto.sanitize_text(info.name, name_buf[:]))
	s.version = strings.clone(proto.sanitize_text(info.version, version_buf[:]))
	s.description = strings.clone(proto.sanitize_message(info.description, description_buf[:]))
	s.max_attachment = info.max_attachment
	s.registration = info.registration
	delete(s.email)
	email_buf: [proto.MAX_EMAIL_SIZE]u8
	email, email_ok := proto.email_clean(info.email, &email_buf)
	s.email = strings.clone(email if email_ok else "")

	if info.icon != s.icon {
		s.icon = info.icon
		delete(s.icon_jpeg)
		s.icon_jpeg = nil
		if info.icon != 0 {
			buf: [proto.BLOB_GET_SIZE]u8
			request(
				c,
				.Server_Icon,
				proto.encode_blob_id(&buf, info.icon),
				icon_done,
				u64(info.icon),
			)
		}
	}
	return true
}

// server_info_event takes the event that says the server changed what
// it says about itself; false if `op` isn't it.
server_info_event :: proc(c: ^Voice_Client, op: proto.Event_Op, body: []u8) -> bool {
	if op != .Server_Info {
		return false
	}
	if server_info_take(c, body) {
		publish_server(c)
	}
	return true
}

@(private = "file")
icon_done :: proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
	s := &c.rpc.server
	// Gone, or another since: whatever came is no longer it.
	if status != .Ok || proto.Blob_Id(tag) != s.icon {
		if status != .Ok && status != .Reset {
			log.warnf("%s wouldn't send its picture: %v", c.server_addr, status)
		}
		return
	}
	if len(body) == 0 || len(body) > proto.MAX_SERVER_ICON_SIZE {
		log.warnf("%s sent a picture of %d bytes", c.server_addr, len(body))
		return
	}
	delete(s.icon_jpeg)
	s.icon_jpeg = make([]u8, len(body))
	copy(s.icon_jpeg, body)
	publish_server(c)
}

/*
server_info_set changes what the server says about itself. A new picture
goes in the outbox, to be uploaded and then set with the rest
(server_info_post); otherwise it's set right away. Takes over the
command's strings and JPEG.
*/
server_info_set :: proc(c: ^Voice_Client, cmd: Server_Info_Command) {
	if len(cmd.image.jpeg) == 0 {
		icon := proto.Blob_Id(0) if cmd.remove else c.rpc.server.icon
		info_set_ask(c, cmd.name, cmd.description, icon, 0)
		delete(cmd.name)
		delete(cmd.description)
		return
	}
	image := cmd.image
	if len(image.jpeg) > proto.MAX_SERVER_ICON_SIZE ||
	   image.width != image.height ||
	   image.width > proto.MAX_SERVER_ICON_SIDE {
		log.warnf(
			"not setting a server picture of %d bytes, %dx%d",
			len(image.jpeg),
			image.width,
			image.height,
		)
		delete(image.jpeg)
		delete(cmd.name)
		delete(cmd.description)
		return
	}
	p := Pending {
		nonce = new_nonce(),
		avatar = true,
		server = true,
		text = cmd.name,
		about = cmd.description,
		jpeg = image.jpeg,
		state = .Put,
		put = {kind = .Avatar, size = len(image.jpeg), width = image.width, height = image.height},
	}
	hash.hash_bytes_to_buffer(.SHA256, image.jpeg, p.put.hash[:])
	append(&c.msgs.outbox, p)
	publish_outbox(c)
}

// server_info_post sets the server's picture that's just been uploaded,
// with its name and description (the outbox's last step for one).
server_info_post :: proc(c: ^Voice_Client, p: ^Pending) {
	info_set_ask(c, p.text, p.about, p.blob, p.nonce)
}

// info_set_ask sends Server_Info_Set; `nonce` is the outbox's entry it
// finishes, or 0 for none.
@(private = "file")
info_set_ask :: proc(
	c: ^Voice_Client,
	name, description: string,
	icon: proto.Blob_Id,
	nonce: u64,
) {
	buf: [proto.SERVER_INFO_SET_MAX_SIZE]u8
	body, ok := proto.encode_server_info_set(
		buf[:],
		{name = name, description = description, icon = icon},
	)
	if !ok {
		notify(c, false, "The server's name or description is too long.")
		return
	}
	request(c, .Server_Info_Set, body, info_set_done, nonce)
}

@(private = "file")
info_set_done :: proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
	p: ^Pending
	if tag != 0 {
		p = outbox_head(c, tag)
		if p == nil || !p.server {
			return
		}
		p.asking = false
	}
	#partial switch status {
	case .Ok:
		notify(c, true, "The server's details were changed.")
	case .Reset:
		return // set again on the new connection, if it was a picture
	case .Not_Found:
		if p != nil {
			// The picture has gone from the server; send it again.
			p.blob, p.state = 0, .Put
			return
		}
		notify(c, false, status_text(status))
	case:
		if p != nil {
			outbox_give_up(c, "The server's details weren't changed: it wouldn't take them.")
			return
		}
		notify(c, false, status_text(status))
	}
	if p != nil {
		pending_destroy(p)
		ordered_remove(&c.msgs.outbox, 0)
		publish_outbox(c)
	}
}

// Ask where the server's memory goes (the owner only): the report
// (common/memtrack) comes to the View, or, headless, the log.
Server_Memory_Command :: struct {}

View_Server_Memory :: struct {
	report: string, // owned; as the server sent it
	status: proto.Status, // the last answer's: Ok, or why there's none
	count:  int, // bumped each time an answer arrives
}

view_clear_server_memory :: proc(v: ^View) {
	delete(v.server_memory.report)
	v.server_memory = {}
}

server_memory :: proc(c: ^Voice_Client) {
	request(
		c,
		.Server_Memory,
		nil,
		proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
			if status == .Reset {
				return
			}
			v := c.view
			if v == nil {
				if status == .Ok {
					log.infof(
						"%s's memory:\n%s",
						c.server_addr,
						memtrack.log_text(string(body), context.temp_allocator),
					)
				} else {
					log.warnf("%s wouldn't say where its memory goes: %v", c.server_addr, status)
				}
				return
			}
			// Shown as it is, so nothing in it but text, tabs and lines.
			report := strings.to_valid_utf8(string(body), "?")
			for &b in transmute([]u8)report {
				if b < ' ' && b != '\t' && b != '\n' {
					b = ' '
				}
			}
			view_write(v)
			delete(v.server_memory.report)
			v.server_memory.report = report if status == .Ok else ""
			if status != .Ok {
				delete(report)
			}
			v.server_memory.status = status
			v.server_memory.count += 1
		},
	)
}

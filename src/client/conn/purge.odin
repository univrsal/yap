package conn

import "core:fmt"

import "common:proto"

// Purging (src/common/proto/purge.odin) is for users with Permission.Purge.
// It asks the server to remove a conversation's messages (or all messages)
// from before a given time, or only their pictures. The answer arrives when the
// server is done, which can take a while. The removed messages disappear from
// our windows when the server says so (Msgs_Purged, messages.odin).

// Purge_Command purges a conversation (`all`: every conversation; headless,
// `here`: the conversation we are looking at) up to `before`.
Purge_Command :: struct {
	conv:   proto.Conv_Id,
	all:    bool,
	here:   bool,
	before: proto.Unix_Ms,
	what:   proto.Purge_What,
}

purge_start :: proc(c: ^Server_Conn, cmd: Purge_Command) {
	conv := cmd.conv
	if cmd.here {
		conv = c.convs.viewing
	}
	if conv == 0 && !cmd.all {
		notify(c, false, "Choose a conversation to purge.")
		return
	}
	if cmd.all {
		conv = 0
	}
	buf: [proto.PURGE_SIZE]u8
	body := proto.encode_purge(&buf, {conv = conv, before = cmd.before, what = cmd.what})
	request(c, .Purge, body, proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			files := proto.Purge_What(tag) == .Files
			#partial switch status {
			case .Ok:
				messages, blobs, _ := proto.decode_purge_answer(body)
				notify(
					c,
					true,
					fmt.tprintf(
						"Purged %d %s; %d stored file(s) removed.",
						messages,
						"messages' files" if files else "message(s)",
						blobs,
					),
				)
			case .Reset:
				notify(
					c,
					false,
					"The connection was reset during the purge. The purge continues on the server.",
				)
			case .Conflict:
				notify(c, false, "A purge is already running. Try again when it has finished.")
			case .Denied:
				notify(c, false, "You don't have permission to purge.")
			case .Not_Found:
				notify(c, false, "That conversation does not exist.")
			case:
				notify(
					c,
					false,
					fmt.tprintf("The server failed to purge the messages (%v).", status),
				)
			}
		}, u64(cmd.what))
	notify(c, true, "Purging... this can take a while.")
}

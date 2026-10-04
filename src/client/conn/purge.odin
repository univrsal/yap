package conn

import "core:fmt"

import "common:proto"

/*
Purging (src/common/proto/purge.odin), for whoever has Permission.Purge:
asking the server to remove a conversation's messages, or all of them,
from before a time, or only their pictures. The answer comes when it's
done, which can take a while; what it removed leaves our windows when
the server says so (Msgs_Purged, messages.odin).
*/

// Purge a conversation (`all`: every one; headless, `here`: the one
// we're looking at) up to `before`.
Purge_Command :: struct {
	conv:   proto.Conv_Id,
	all:    bool,
	here:   bool,
	before: proto.Unix_Ms,
	what:   proto.Purge_What,
}

purge_start :: proc(c: ^Voice_Client, cmd: Purge_Command) {
	conv := cmd.conv
	if cmd.here {
		conv = c.convs.viewing
	}
	if conv == 0 && !cmd.all {
		notify(c, false, "Which conversation is to be purged?")
		return
	}
	if cmd.all {
		conv = 0
	}
	buf: [proto.PURGE_SIZE]u8
	body := proto.encode_purge(&buf, {conv = conv, before = cmd.before, what = cmd.what})
	request(c, .Purge, body, proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
			pictures := proto.Purge_What(tag) == .Images
			#partial switch status {
			case .Ok:
				messages, blobs, _ := proto.decode_purge_answer(body)
				notify(
					c,
					true,
					fmt.tprintf(
						"Purged %d %s; %d stored file(s) removed.",
						messages,
						"picture(s)" if pictures else "message(s)",
						blobs,
					),
				)
			case .Reset:
				notify(
					c,
					false,
					"The connection started over during the purge; it goes on on the server.",
				)
			case .Conflict:
				notify(c, false, "A purge is under way already; try again when it's done.")
			case .Denied:
				notify(c, false, "You aren't allowed to purge.")
			case .Not_Found:
				notify(c, false, "That conversation isn't there.")
			case:
				notify(c, false, fmt.tprintf("The server wouldn't purge (%v).", status))
			}
		}, u64(cmd.what))
	notify(c, true, "Purging... this can take a while.")
}

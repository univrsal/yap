package conn

import "core:fmt"
import "core:slice"
import "core:strings"

import "client:richtext"
import "common:proto"
import log "common:wlog"

// What the command-line client (client/headless) shows. It has no View, so the
// log is where everything goes: each of these says what just happened in the
// way a person typing commands wants to read it, and does nothing when there
// is a View to show it. The protocol code calls them where the UI would be
// told (publish_*) and doesn't need to know which one it is talking to.

report_status :: proc(c: ^Server_Conn, display, status: string, until: proto.Unix_Ms) {
	if c.view != nil {
		return
	}
	if status == "" {
		log.infof("[status] %s has no status", display)
	} else {
		log.infof("[status] %s: %s%s", display, status, " (for a while)" if until != 0 else "")
	}
}

report_device :: proc(c: ^Server_Conn, d: proto.Device) {
	if c.view != nil {
		return
	}
	log.infof(
		"device %s %q%s%s",
		fingerprint(d.key),
		d.name,
		" (this one)" if .Current in d.flags else "",
		" online" if .Online in d.flags else "",
	)
}

report_call_active :: proc(c: ^Server_Conn, peer: proto.Account_Id, here: bool) {
	if c.view != nil {
		return
	}
	log.infof(
		"[call] in a call with %s%s",
		account_display(c, peer),
		"" if here else " (on another device)",
	)
}

report_call_over :: proc(c: ^Server_Conn, peer: proto.Account_Id, reason: proto.Call_End_Reason) {
	if c.view != nil {
		return
	}
	log.infof("[call] the call with %s is over (%v)", account_display(c, peer), reason)
}

// report_browse lists a page of the channels that can be subscribed to. `shown`
// is how many there are in all so far.
report_browse :: proc(
	c: ^Server_Conn,
	query: string,
	shown: int,
	found: []proto.Conv,
	more: bool,
) {
	if c.view != nil {
		return
	}
	if shown == 0 {
		log.info(
			"there are no other channels to subscribe to" if query == "" else "no other channel has that in its name or topic",
		)
	}
	for record in found {
		log.infof(
			"can subscribe to %q%s%s",
			record.name,
			": " if record.topic != "" else "",
			record.topic,
		)
	}
	if more {
		log.info("and more (/browse more)")
	}
}

// report_history says what a page of history added to a window, which holds
// `total` messages now.
report_history :: proc(
	c: ^Server_Conn,
	key: Timeline_Key,
	got: []proto.Message,
	have_oldest: bool,
	total: int,
) {
	if c.view != nil {
		return
	}
	place := room_name(c, proto.Room(key.conv))
	if key.root != 0 {
		place = fmt.tprintf("%s, thread #%d", place, key.root)
	}
	if len(got) > 0 {
		log.infof(
			"[history] %s: %d messages (%d to %d)%s, %d in all",
			place,
			len(got),
			got[0].id,
			got[len(got) - 1].id,
			", back to the first" if have_oldest else "",
			total,
		)
	} else {
		log.infof("[history] %s: no messages", place)
	}
}

report_mention :: proc(c: ^Server_Conn, m: proto.Message, shown: string) {
	if c.view != nil {
		return
	}
	log.infof(
		"[mention] %s mentioned you in %s: %s",
		account_display(c, m.sender),
		room_name(c, proto.Room(m.conv)),
		shown,
	)
}

// report_message is a message that arrived.
report_message :: proc(c: ^Server_Conn, m: proto.Message) {
	if c.view != nil {
		return
	}
	place := room_name(c, proto.Room(m.conv))
	who := account_display(c, m.sender)
	if .Persona in m.flags {
		who = fmt.tprintf("%s (via %s)", m.persona.name, who)
	}
	if m.thread_root != 0 {
		log.infof(
			"[chat] %s %s (#%d, in the thread of #%d): %s",
			place,
			who,
			m.id,
			m.thread_root,
			describe(c, m),
		)
	} else {
		log.infof("[chat] %s %s (#%d): %s", place, who, m.id, describe(c, m))
	}
}

report_changed :: proc(c: ^Server_Conn, m: proto.Message) {
	if c.view != nil {
		return
	}
	log.infof(
		"[chat] %s, message #%d is now: %s",
		room_name(c, proto.Room(m.conv)),
		m.id,
		describe(c, m),
	)
}

report_purged :: proc(c: ^Server_Conn, p: proto.Msgs_Purged) {
	if c.view != nil {
		return
	}
	if p.author != 0 {
		log.infof(
			"[chat] %s: %s's messages from #%d on were purged",
			room_name(c, proto.Room(p.conv)),
			account_display(c, p.author),
			p.from,
		)
		return
	}
	log.infof(
		"[chat] %s: the messages below #%d were purged",
		room_name(c, proto.Room(p.conv)),
		p.before,
	)
}

report_pins :: proc(c: ^Server_Conn, conv: proto.Conv_Id, pins: []proto.Message, first: bool) {
	if c.view != nil {
		return
	}
	if len(pins) == 0 && first {
		log.infof("[pins] %s: nothing pinned", room_name(c, proto.Room(conv)))
	}
	for m in pins {
		log.infof(
			"[pins] %s %s (#%d): %s",
			room_name(c, proto.Room(conv)),
			account_display(c, m.sender),
			m.id,
			describe(c, m),
		)
	}
}

report_typing :: proc(
	c: ^Server_Conn,
	conv: proto.Conv_Id,
	root: proto.Msg_Id,
	who: proto.Account_Id,
) {
	if c.view != nil {
		return
	}
	if root != 0 {
		log.infof(
			"[chat] %s is typing in %s, in the thread of #%d",
			account_display(c, who),
			room_name(c, proto.Room(conv)),
			root,
		)
	} else {
		log.infof(
			"[chat] %s is typing in %s",
			account_display(c, who),
			room_name(c, proto.Room(conv)),
		)
	}
}

report_members :: proc(
	c: ^Server_Conn,
	conv: proto.Conv_Id,
	members: []proto.Account_Id,
	admins: []proto.Account_Id,
) {
	if c.view != nil {
		return
	}
	for m in members {
		acc := c.auth.accounts[m] or_else {}
		log.infof(
			"[members] %s: %s%s%s%s",
			room_name(c, proto.Room(conv)),
			account_display(c, m),
			" (admin)" if slice.contains(admins, m) else "",
			" (here)" if is_online(c, m) else "",
			fmt.tprintf(" - %s", acc.status) if acc.status != "" else "",
		)
	}
}

report_rights :: proc(c: ^Server_Conn, entries: []proto.Role_Rights) {
	if c.view != nil {
		return
	}
	for e in entries {
		log.infof("[rights] %s: %s", role_name(c, e.role), rights_text(e.rights))
	}
}

// report_search lists a page of search results. `last` is the oldest message
// looked at so far, which is 0 if that was the first page and it found nothing.
report_search :: proc(
	c: ^Server_Conn,
	query: string,
	last: proto.Msg_Id,
	found: []proto.Message,
	more: bool,
) {
	if c.view != nil {
		return
	}
	if len(found) == 0 && last == 0 {
		log.infof("[search] nothing has %q", query)
	}
	for m in found {
		log.infof(
			"[search] %s %s (#%d): %s",
			room_name(c, proto.Room(m.conv)),
			account_display(c, m.sender),
			m.id,
			m.text,
		)
	}
	if more {
		log.info("[search] and maybe more (/search more)")
	}
}

// describe returns a message as the log shows it.
describe :: proc(c: ^Server_Conn, m: proto.Message) -> string {
	if .Deleted in m.flags {
		return "(deleted)"
	}
	text: string
	#partial switch m.kind {
	case .System:
		text = system_text(
			m.system,
			m.system_arg,
			m.text,
			account_display(c, m.sender),
			account_display(c, proto.Account_Id(m.system_arg)),
			m.sender == c.auth.me,
		)
	case .Text:
		text, _ = richtext.mentions_display(m.text, c.auth.accounts, dir_roles(c), c.auth.me)
		if .Has_Attachments in m.flags {
			b := strings.builder_make(context.temp_allocator)
			strings.write_string(&b, text)
			for i in 0 ..< m.attachment_count {
				a := m.attachments[i]
				if a.blob == 0 {
					fmt.sbprintf(&b, " [file %d: %q, no longer kept]", i + 1, a.name)
				} else {
					fmt.sbprintf(&b, " [file %d: %q, %s]", i + 1, a.name, format_bytes(a.size))
				}
			}
			text = strings.to_string(b)
		}
	case .File:
		text = fmt.tprintf("offers the file %q (%s)", m.file_name, format_bytes(m.file_size))
	}
	if m.edited != 0 {
		text = fmt.tprintf("%s (edited)", text)
	}
	if .Pinned in m.flags {
		text = fmt.tprintf("%s (pinned)", text)
	}
	if .Has_Thread in m.flags {
		text = fmt.tprintf("%s (%d replies)", text, m.reply_count)
	}
	if .Forwarded in m.flags {
		text = fmt.tprintf(
			"%s (forwarded from %s, #%d)",
			text,
			account_display(c, m.forward.sender),
			m.forward.conv,
		)
	}
	return text
}

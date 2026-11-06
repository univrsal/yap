package main

import "core:fmt"
import "core:strings"

import "client:conn"
import "client:richtext"

// What asks for attention when the screen isn't being looked at: mentions, DMs
// that aren't being read, and calls. The app collects them; the terminal loop
// turns them into a bell and a desktop notification (OSC 777 or 9, whichever the
// terminal is known for), and sets the window title to the unread count.

Notice :: struct {
	title, body: string, // owned
}

notices_destroy :: proc(a: ^App) {
	for n in a.notices {
		delete(n.title)
		delete(n.body)
	}
	delete(a.notices)
	delete(a.title)
}

// notices_update makes notices of the mentions that came in since the last
// frame (taken from the View by the caller) and of calls. Call with the View
// locked.
notices_update :: proc(a: ^App, mentions: []conn.View_Mention) {
	v := a.view
	for m in mentions {
		// A DM that is open and read needs no notice; a mention does, wherever it is.
		if (m.dm || m.group) && m.conv == v.viewing && a.scroll == 0 {
			continue
		}
		append(&a.notices, Notice{strings.clone(conn.mention_title(m, "")), strings.clone(richtext.markdown_plain(m.text))})
	}
	switch v.call.status {
	case .Ringing_In:
		if v.call.id != a.call_announced {
			a.call_announced = v.call.id
			name := "someone"
			if acc, ok := v.accounts[v.call.peer]; ok {
				name = acc.display
			}
			append(&a.notices, Notice{fmt.aprintf("%s is calling you", name), strings.clone("/answer to pick up, /hangup to decline")})
		}
	case .None:
		a.call_announced = 0
	case .Ringing_Out, .Active:
	}
	// The title.
	unread, mentions := 0, 0
	for row in list_rows(v) {
		if row.kind != .Header {
			unread += row.unread
			mentions += row.mentions
		}
	}
	title: string
	switch {
	case mentions > 0:
		title = fmt.aprintf("(%d @) yap", mentions)
	case unread > 0:
		title = fmt.aprintf("(%d) yap", unread)
	case:
		title = strings.clone("yap")
	}
	delete(a.title)
	a.title = title
}

// take_notices gives the notices waiting and forgets them; the caller frees them.
take_notices :: proc(a: ^App) -> [dynamic]Notice {
	out := a.notices
	a.notices = nil
	return out
}

// An incoming call is told on the info line as well.
incoming_call_text :: proc(v: ^conn.View) -> string {
	if v.call.status != .Ringing_In {
		return ""
	}
	name := "someone"
	if acc, ok := v.accounts[v.call.peer]; ok {
		name = acc.display
	}
	return fmt.tprintf("📞 %s is calling — /answer or /hangup", name)
}


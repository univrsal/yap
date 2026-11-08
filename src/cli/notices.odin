package main

import "core:fmt"
import "core:strings"
import "core:sync"

import "client:conn"
import "client:richtext"
import "client:script"

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
	on := fmt.tprintf(" on %s", server_name(v)) if len(a.servers) > 1 else ""
	for m in mentions {
		// A DM that is open and read needs no notice; a mention does, wherever it is.
		if (m.dm || m.group) && m.conv == v.viewing && a.scroll == 0 {
			continue
		}
		append(
			&a.notices,
			Notice {
				strings.clone(conn.mention_title(m, on)),
				strings.clone(richtext.markdown_plain(m.text)),
			},
		)
	}
	switch v.call.status {
	case .Ringing_In:
		if v.call.id != a.call_announced {
			a.call_announced = v.call.id
			name := "someone"
			if acc, ok := v.accounts[v.call.peer]; ok {
				name = acc.display
			}
			append(
				&a.notices,
				Notice {
					fmt.aprintf("%s is calling you%s", name, on),
					strings.clone("/answer to pick up, /hangup to decline"),
				},
			)
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
	for s, i in a.servers {
		if i != a.cur {
			u, m := server_unread(s)
			unread, mentions = unread + u, mentions + m
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


// notices_background makes notices of what happened on the servers that are not
// shown: mentions, DMs (none of them is being read) and calls. Call with the
// shown server's View locked; the others are locked in turn.
notices_background :: proc(a: ^App) {
	for s, i in a.servers {
		if i == a.cur {
			continue
		}
		mentions := conn.view_take_mentions(s.view)
		sync.mutex_lock(&s.view.mutex)
		defer sync.mutex_unlock(&s.view.mutex)
		on := fmt.tprintf(" on %s", server_name(s.view))
		for m in mentions {
			append(
				&a.notices,
				Notice {
					strings.clone(conn.mention_title(m, on)),
					strings.clone(richtext.markdown_plain(m.text)),
				},
			)
		}
		#partial switch s.view.call.status {
		case .Ringing_In:
			if s.view.call.id != s.ui.call_announced {
				s.ui.call_announced = s.view.call.id
				name := "someone"
				if acc, ok := s.view.accounts[s.view.call.peer]; ok {
					name = acc.display
				}
				append(
					&a.notices,
					Notice {
						fmt.aprintf("%s is calling you%s", name, on),
						strings.clone("switch to that server and /answer"),
					},
				)
			}
		case .None:
			s.ui.call_announced = 0
		}
	}
}

// script_notices takes what scripts asked to be notified of (yap.notify), the way
// the window client shows it: with the server named when there are several.
script_notices :: proc(a: ^App) {
	if a.scripts == nil {
		return
	}
	for n in script.runtime_take_notifications(a.scripts) {
		title := n.title
		if n.server != "" && len(a.servers) > 1 {
			title = fmt.tprintf("%s on %s", n.title, n.server)
		}
		append(&a.notices, Notice{strings.clone(title), strings.clone(n.text)})
	}
}

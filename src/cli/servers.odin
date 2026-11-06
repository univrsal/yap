package main

import "core:fmt"
import "core:strings"
import "core:sync"

import "client:conn"
import "tui"

// Several servers. Each is a Server: its connection (a Session, when the loop
// made it), its View and what the app keeps for it (Server_UI). The app shows
// one at a time; the others go on in the background, with their unread counts
// in the list on the left, and mentions and calls announced with the server's
// name.
//
// The loop owns the connections, so connecting, disconnecting and connecting
// again are asked for in `requests`, and the loop does them (run.odin). The
// joined servers of the window client (settings.json) are read at the start but
// never written back: that file is the window client's.

Server :: struct {
	view:    ^conn.View,
	client:  ^conn.Server_Conn,
	session: ^conn.Session, // nil when something else owns the connection (tests)
	target:  conn.Net_Target, // where it goes; its server, password, channel and look_at are owned
	ui:      Server_UI, // what the app kept for it while it isn't shown
}

Server_Request_Kind :: enum {
	Connect,
	Disconnect,
	Reconnect,
}

Server_Request :: struct {
	kind:     Server_Request_Kind,
	index:    int, // of the server to disconnect or connect again
	address:  string, // for Connect (owned)
	password: string, // (owned)
}

server_ui_destroy :: proc(u: ^Server_UI) {
	layout_destroy(&u.layout)
	layout_destroy(&u.thread_layout)
	completion_destroy(&u.completion)
	tui.editor_destroy(&u.editor)
	delete(u.reply_name)
	for f in u.attached {
		delete(f)
	}
	delete(u.attached)
	u^ = {}
}

// app_add_server adds a server to the list; the first one is shown.
app_add_server :: proc(a: ^App, v: ^conn.View, client: ^conn.Server_Conn, session: ^conn.Session = nil) -> int {
	s := new(Server)
	s.view, s.client, s.session = v, client, session
	s.target.server = strings.clone(v.server)
	append(&a.servers, s)
	if len(a.servers) == 1 {
		a.view, a.client = v, client
	}
	return len(a.servers) - 1
}

// server_name is how a server is called in lists. Call with its View locked.
server_name :: proc(v: ^conn.View) -> string {
	return v.server_name if v.server_name != "" else v.server
}

// app_switch shows another server. What was being written, scrolled to and
// opened stays with the server it belongs to.
app_switch :: proc(a: ^App, index: int) {
	if index < 0 || index >= len(a.servers) || index == a.cur {
		return
	}
	// The one we leave is no longer being read.
	if a.reading_told != 0 {
		push(a, conn.Reading_Command{conv = 0})
		a.reading_told = 0
	}
	dialog_close(a)
	menu_close(a)
	a.sel.active = false
	a.press = nil
	a.servers[a.cur].ui, a.ui = a.ui, a.servers[index].ui
	a.servers[index].ui = {}
	a.cur = index
	a.view, a.client = a.servers[index].view, a.servers[index].client
	a.reading_told = 0 // told again by the next frame
}

// app_remove_server forgets a server (its connection is for the loop to end).
// Call after the loop has freed the session, or with none.
app_remove_server :: proc(a: ^App, index: int) {
	if index < 0 || index >= len(a.servers) {
		return
	}
	if index == a.cur {
		next := 0 if index > 0 else 1
		if next >= len(a.servers) {
			// The last one: nothing to show.
			a.quit = true
			return
		}
		app_switch(a, next)
	}
	s := a.servers[index]
	server_ui_destroy(&s.ui)
	target_destroy(&s.target)
	free(s)
	ordered_remove(&a.servers, index)
	if index < a.cur {
		a.cur -= 1
	}
}

request_reconnect :: proc(a: ^App) {
	append(&a.requests, Server_Request{kind = .Reconnect, index = a.cur})
}

// switch_server shows the next or previous server.
switch_server :: proc(a: ^App, dir: int) {
	n := len(a.servers)
	if n > 1 {
		app_switch(a, (a.cur + dir + n) % n)
	}
}

// server_unread is the unread messages and mentions of a server, which is not
// the one shown. It takes the server's own lock.
server_unread :: proc(s: ^Server) -> (unread, mentions: int) {
	sync.mutex_lock(&s.view.mutex)
	defer sync.mutex_unlock(&s.view.mutex)
	for row in list_rows(s.view) {
		if row.kind != .Header {
			unread += row.unread
			mentions += row.mentions
		}
	}
	return
}

// rail_height is how many rows the list of servers takes at the top of the
// channel list; none for a single server.
rail_height :: proc(a: ^App) -> int {
	return len(a.servers) + 1 if len(a.servers) > 1 else 0
}

// draw_rail draws the servers, one to a row, with what is unread in the others.
draw_rail :: proc(a: ^App, b: ^tui.Buffer, r: tui.Rect) {
	if len(a.servers) < 2 {
		return
	}
	for s, i in a.servers {
		y := r.y + i
		name: string
		unread, mentions: int
		status := conn.Status.Connected
		if i == a.cur {
			name, status = server_name(a.view), a.view.status
		} else {
			sync.mutex_lock(&s.view.mutex)
			name, status = strings.clone(server_name(s.view), context.temp_allocator), s.view.status
			sync.mutex_unlock(&s.view.mutex)
			unread, mentions = server_unread(s)
		}
		picked := i == a.cur
		style := theme.selected if picked else tui.Style{}
		tui.fill(b, {r.x, y, r.w, 1}, style)
		mark, mark_style := "●", theme.online
		if status != .Connected {
			mark, mark_style = "○", theme.error
		}
		tui.put_string(b, r.x + 1, y, mark, style if picked else mark_style, r.x + r.w)
		badge, badge_style := channel_badge(unread, mentions)
		badge_w := tui.string_width(badge)
		name_w := r.w - 4 - (badge_w + 1 if badge_w > 0 else 0)
		tui.put_string(b, r.x + 3, y, tui.cut_to_width(name, name_w), style, r.x + r.w)
		if badge_w > 0 {
			tui.put_string(b, r.x + r.w - badge_w - 1, y, badge, badge_style)
		}
		append(&a.hits, Hit{{r.x, y, r.w, 1}, .Server, u64(i), ""})
	}
	for x in r.x ..< r.x + r.w {
		tui.set_cell(b, x, r.y + len(a.servers), '─', 1, theme.border)
	}
}

// servers_text lists the servers for /servers.
servers_text :: proc(a: ^App) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	for s, i in a.servers {
		name, status: string
		if i == a.cur {
			name = server_name(a.view)
			status = fmt.tprint(a.view.status)
		} else {
			sync.mutex_lock(&s.view.mutex)
			name = strings.clone(server_name(s.view), context.temp_allocator)
			status = fmt.tprint(s.view.status)
			sync.mutex_unlock(&s.view.mutex)
		}
		fmt.sbprintfln(&b, "%s%d  %s  (%s)", "*" if i == a.cur else " ", i + 1, name, status)
	}
	return strings.to_string(b)
}

target_destroy :: proc(t: ^conn.Net_Target) {
	delete(t.server)
	delete(t.password)
	delete(t.channel)
	delete(t.look_at)
	t.server, t.password, t.channel, t.look_at = "", "", "", ""
}

// app_set_target remembers where a server goes, for connecting to it again.
app_set_target :: proc(a: ^App, index: int, t: conn.Net_Target) {
	s := a.servers[index]
	target_destroy(&s.target)
	s.target = t
	s.target.server = strings.clone(t.server)
	s.target.password = strings.clone(t.password)
	s.target.channel = strings.clone(t.channel)
	s.target.look_at = strings.clone(t.look_at)
}

// app_replace_connection puts a new connection in place of a server's (after it
// was connected to again), and hands back the old session to be freed.
app_replace_connection :: proc(a: ^App, index: int, v: ^conn.View, client: ^conn.Server_Conn, session: ^conn.Session) -> ^conn.Session {
	s := a.servers[index]
	old := s.session
	s.view, s.client, s.session = v, client, session
	if index == a.cur {
		a.view, a.client = v, client
		// Whatever was open there is not there any more.
		a.viewing, a.reading_told, a.members_asked = 0, 0, 0
		a.thread = 0
	} else {
		s.ui.viewing, s.ui.reading_told, s.ui.members_asked = 0, 0, 0
		s.ui.thread = 0
	}
	return old
}

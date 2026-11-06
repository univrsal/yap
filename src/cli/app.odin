package main

import "core:strings"
import "core:sync"
import "core:time"
import "core:time/datetime"

import "client:conn"
import "common:proto"
import "tui"

// The terminal client's state and screen. It works on a View and a command
// queue, not on a terminal or a Session, so tests can drive it with a View
// filled in by hand. The terminal loop is in run.odin.
//
// The screen:
//
//	server  ┬ # channel  topic                 (title bar)
//	channel │ messages
//	list    │ ...
//	        │ info line: reply, edit, typing, notices
//	        │ > the message being written
//	status bar

Focus :: enum {
	Composer,
	Timeline, // a message is picked with the keys
}

Hit_Kind :: enum {
	Channel, // id: the conversation
	Message, // id: the message
	Thread, // id: the thread's root
	Border, // between the channel list and the chat
	Member, // id: the account
	Reaction, // id: the message; text: the emoji
	Close_Thread,
	List_Item, // id: its index in the list dialog
	Emoji, // id: its index in the picker
	Composer,
	Menu_Item, // id: its index
	Dialog,
}

// A place on the screen that does something when clicked. The ones drawn last
// are on top.
Hit :: struct {
	rect: tui.Rect,
	kind: Hit_Kind,
	id:   u64,
	text: string,
}

Drag :: enum {
	None,
	Border,
}

App :: struct {
	view:          ^conn.View,
	client:        ^conn.Server_Conn, // what commands are queued for
	attached:      [dynamic]string, // files for the next message (owned)
	known_servers: string, // the file of trusted server keys, to trust a new key into
	device:        string, // what to call this device when logging in
	tz:            ^datetime.TZ_Region,
	// Asked of the loop: end the program, or connect again (after a key was
	// trusted or a login).
	quit:          bool,
	reconnect:     bool,

	size:          [2]int,
	channel_w:     int,
	chan_scroll:   int,
	hide_members:  bool, // the member list is on unless asked off
	members_scroll: int,
	members_asked: proto.Conv_Id, // the conversation whose members were requested
	focus:         Focus,
	drag:          Drag,

	// The conversation shown, and what the timeline knows about it.
	viewing:       proto.Conv_Id,
	layout:        Timeline_Layout,
	thread:        proto.Msg_Id, // the root of the thread that is open, 0 for none
	thread_layout: Timeline_Layout,
	thread_scroll: int,
	thread_asked:  proto.Msg_Id,
	jump_conv:     proto.Conv_Id, // a message being gone to, and whether the page around it was asked for
	jump_msg:      proto.Msg_Id,
	jump_asked:    bool,
	jump_at:       time.Tick,
	scroll:        int, // rows above the newest that the bottom of the timeline is at
	unread_from:   proto.Msg_Id, // the newest message read when the conversation was opened
	cursor_msg:    proto.Msg_Id, // the message picked with the keys or the mouse
	asked_older:   proto.Msg_Id,
	asked_newer:   proto.Msg_Id,
	appended:      int,
	rows_before:   int,
	reading_told:  proto.Conv_Id,

	// The message box.
	editor:        tui.Editor,
	reply_to:      proto.Msg_Id, // posting as a reply in this message's thread
	reply_name:    string, // who that is, for the banner (owned)
	editing:       proto.Msg_Id, // changing this message of ours
	notice:        string, // owned
	notice_error:  bool,
	notice_at:     time.Tick,

	// Windows over the screen.
	dialog:        Dialog,
	menu:          Menu,

	// Where things are, as of the last frame.
	hits:          [dynamic]Hit,
	cursor:        [2]int, // where the text cursor goes
	cursor_shown:  bool,
	clipboard:     string, // asked to be copied (owned); the loop writes it out
}

// The member list needs this much room, and is this wide.
WIDE :: 100
MEMBERS_W :: 24
THREAD_W :: 46
CHANNEL_W_DEFAULT :: 26
CHANNEL_W_MIN :: 12
// Under this width the channel list is hidden.
NARROW :: 60

app_init :: proc(a: ^App, v: ^conn.View, client: ^conn.Server_Conn) {
	a.view, a.client = v, client
	a.channel_w = CHANNEL_W_DEFAULT
	a.size = {80, 24}
}

app_destroy :: proc(a: ^App) {
	layout_destroy(&a.layout)
	layout_destroy(&a.thread_layout)
	tui.editor_destroy(&a.editor)
	delete(a.reply_name)
	delete(a.notice)
	delete(a.clipboard)
	delete(a.hits)
	for f in a.attached {
		delete(f)
	}
	delete(a.attached)
	dialog_close(a)
	menu_close(a)
}

// push queues a command for the connection.
push :: proc(a: ^App, cmd: conn.Command) {
	conn.push_command(&a.client.commands, cmd)
}

// say shows a line in the info line for a while.
say :: proc(a: ^App, text: string, is_error := false) {
	delete(a.notice)
	a.notice = strings.clone(text)
	a.notice_error = is_error
	a.notice_at = time.tick_now()
}

NOTICE_SHOWN :: 8 * time.Second
JUMP_WAIT :: 10 * time.Second

tick_now :: proc() -> time.Tick {
	return time.tick_now()
}

tick_since :: proc(t: time.Tick) -> time.Duration {
	return time.tick_since(t)
}

Geometry :: struct {
	channels: tui.Rect, // empty when hidden
	border:   tui.Rect,
	thread:   tui.Rect, // the open thread, empty when none
	thread_border: tui.Rect,
	thread_over: bool, // it covers the messages (on a screen too narrow to share)
	members:  tui.Rect, // the list of who is here, empty when hidden
	members_border: tui.Rect,
	title:    tui.Rect,
	timeline: tui.Rect,
	info:     tui.Rect,
	composer: tui.Rect,
	status:   tui.Rect,
}

// COMPOSER_MAX is the most lines the message box grows to.
COMPOSER_MAX :: 6

geometry :: proc(a: ^App) -> Geometry {
	w, h := a.size.x, a.size.y
	g: Geometry
	cw := 0
	if w >= NARROW {
		cw = clamp(a.channel_w, CHANNEL_W_MIN, w / 2)
		g.channels = {0, 0, cw, h - 1}
		g.border = {cw, 0, 1, h - 1}
		cw += 1
	}
	rw := w - cw
	if a.thread != 0 && w >= WIDE {
		// Beside the messages, in place of the member list.
		g.thread = {w - THREAD_W, 0, THREAD_W, h - 1}
		g.thread_border = {w - THREAD_W - 1, 0, 1, h - 1}
		rw -= THREAD_W + 1
	} else if w >= WIDE && !a.hide_members {
		g.members = {w - MEMBERS_W, 0, MEMBERS_W, h - 1}
		g.members_border = {w - MEMBERS_W - 1, 0, 1, h - 1}
		rw -= MEMBERS_W + 1
	}
	// The message box is as tall as what is written in it.
	lines := make([dynamic]tui.Line, context.temp_allocator)
	tui.wrap(tui.editor_text(&a.editor), max(rw - 2, 1), &lines)
	ch := clamp(len(lines), 1, min(COMPOSER_MAX, max(h / 3, 1)))
	g.status = {0, h - 1, w, 1}
	g.composer = {cw, h - 1 - ch, rw, ch}
	g.info = {cw, h - 2 - ch, rw, 1}
	g.title = {cw, 0, rw, 1}
	g.timeline = {cw, 1, rw, max(g.info.y - 1, 0)}
	if a.thread != 0 && g.thread.w == 0 {
		// No room beside: the thread covers the messages.
		g.thread = {g.timeline.x, g.timeline.y - 1, g.timeline.w, g.timeline.h + 1}
		g.thread_over = true
	}
	return g
}

// hit_at is what is clicked at x, y.
hit_at :: proc(a: ^App, x, y: int) -> (Hit, bool) {
	#reverse for h in a.hits {
		if tui.rect_contains(h.rect, x, y) {
			return h, true
		}
	}
	return {}, false
}

// find_message gives the message with that id in the conversation shown. Call
// with the View locked.
find_message :: proc(a: ^App, id: proto.Msg_Id) -> (^conn.View_Message, bool) {
	if m, ok := find_in(a.view, {a.view.viewing, 0}, id); ok {
		return m, true
	}
	if a.thread != 0 {
		if m, ok := find_in(a.view, {a.view.viewing, a.thread}, id); ok {
			return m, true
		}
		if r, ok := &a.view.roots[id]; ok {
			return &r.msg, true
		}
	}
	return nil, false
}

@(private = "file")
find_in :: proc(v: ^conn.View, key: conn.Timeline_Key, id: proto.Msg_Id) -> (^conn.View_Message, bool) {
	tl, have := &v.timelines[key]
	if !have {
		return nil, false
	}
	// Ordered by id.
	lo, hi := 0, len(tl.messages)
	for lo < hi {
		mid := (lo + hi) / 2
		if tl.messages[mid].id < id {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < len(tl.messages) && tl.messages[lo].id == id {
		return &tl.messages[lo], true
	}
	return nil, false
}

// app_frame brings the state up to date with the View (the timeline's rows,
// what has been read, older messages to ask for) and draws the screen. The
// View is locked while it does.
app_frame :: proc(a: ^App, b: ^tui.Buffer) {
	v := a.view
	sync.guard(&v.mutex)
	a.size = {b.w, b.h}
	app_sync(a)
	tui.buffer_clear(b)
	clear(&a.hits)
	a.cursor_shown = false
	g := geometry(a)
	draw_channels(a, b, g)
	draw_chat(a, b, g)
	draw_members(a, b, g)
	draw_status(a, b, g)
	draw_overlays(a, b)
}

// app_sync follows what the View says. Call with it locked.
app_sync :: proc(a: ^App) {
	v := a.view
	g := geometry(a)
	if v.viewing != a.viewing {
		// Another conversation: start at its newest message, with a line above
		// the unread ones.
		a.viewing = v.viewing
		a.scroll, a.cursor_msg = 0, 0
		a.asked_older, a.asked_newer, a.appended, a.rows_before = 0, 0, 0, 0
		a.focus = .Composer
		cancel_reply(a)
		cancel_edit(a)
		menu_close(a)
		a.thread, a.thread_scroll, a.thread_asked = 0, 0, 0
		unread, read, _ := conn.viewed_unread(v)
		a.unread_from = read if unread > 0 else 0
	}
	dialog_update(a)
	// Who is here, for the member list.
	if g.members.w > 0 && a.members_asked != a.viewing && a.viewing != 0 {
		a.members_asked = a.viewing
		push(a, conn.Members_Command{conv = a.viewing})
	}
	key := conn.Timeline_Key{a.viewing, 0}
	layout_update(&a.layout, v, key, g.timeline.w, a.tz, a.unread_from)

	tl, have := &v.timelines[key]
	rows := len(a.layout.rows)
	if have && tl.appended != a.appended {
		// Something came in at the end: stay on what is being read.
		if a.scroll > 0 && tl.appended > a.appended && a.rows_before > 0 {
			a.scroll += max(rows - a.rows_before, 0)
		}
		a.appended = tl.appended
	}
	a.rows_before = rows
	a.scroll = clamp(a.scroll, 0, max(rows - g.timeline.h, 0))
	jump_step(a, g)
	if a.thread != 0 {
		tkey := conn.Timeline_Key{a.viewing, a.thread}
		layout_update(&a.thread_layout, v, tkey, g.thread.w - 1, a.tz, 0)
		trows := len(a.thread_layout.rows)
		a.thread_scroll = clamp(a.thread_scroll, 0, max(trows - (g.thread.h - 1), 0))
		if ttl, ok := &v.timelines[tkey]; ok && !ttl.loading && len(ttl.messages) > 0 && !ttl.have_oldest {
			if a.thread_scroll + g.thread.h - 1 >= trows && a.thread_asked != ttl.messages[0].id {
				a.thread_asked = ttl.messages[0].id
				push(a, conn.History_Command{conv = a.viewing, root = a.thread})
			}
		}
	}

	// What is read is what is in view at the newest message.
	reading := a.viewing if a.scroll == 0 else 0
	if reading != a.reading_told {
		a.reading_told = reading
		push(a, conn.Reading_Command{conv = reading})
	}
	if have && a.viewing != 0 && !tl.loading && len(tl.messages) > 0 {
		// Near the top of what we have, ask for older messages; at the bottom of
		// a window that stops short, newer ones.
		if !tl.have_oldest && a.scroll + g.timeline.h >= rows && a.asked_older != tl.messages[0].id {
			a.asked_older = tl.messages[0].id
			push(a, conn.History_Command{conv = a.viewing})
		} else if !tl.have_newest && a.scroll == 0 && a.asked_newer != tl.messages[len(tl.messages) - 1].id {
			a.asked_newer = tl.messages[len(tl.messages) - 1].id
			push(a, conn.History_Command{conv = a.viewing, newer = true})
		}
	}
	if a.notice != "" && time.tick_since(a.notice_at) > NOTICE_SHOWN {
		delete(a.notice)
		a.notice = ""
	}
}

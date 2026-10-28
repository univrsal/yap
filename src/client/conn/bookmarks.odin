package conn

import log "common:wlog"
import "core:fmt"

import "common:proto"

// Bookmarks (src/common/proto/bookmarks.odin): messages we marked to come back
// to. Which ones are bookmarked arrives at login and as it changes, and goes
// to the UI (View.bookmarks.ids) so that it can mark them. The list itself,
// with the messages, is fetched when the UI shows it (Bookmarks_Command), a
// page at a time, newest first, and fetched again while it is shown whenever
// a bookmark comes or goes. A bookmarked message that changes meanwhile is
// replaced in it.

// Bookmark a message (`on`) or remove its bookmark.
Bookmark_Command :: struct {
	id: proto.Msg_Id,
	on: bool,
}

// Fetch the list of bookmarks for the UI and keep it up to date, or with
// `more` fetch its next page, or with `close` stop keeping it up to date.
Bookmarks_Command :: struct {
	more:  bool,
	close: bool,
}

// View_Bookmark is one entry of the list: a message, the conversation it is
// in, and when it was bookmarked.
View_Bookmark :: struct {
	time: proto.Unix_Ms,
	conv: proto.Conv_Id,
	msg:  View_Message,
}

View_Bookmarks :: struct {
	// Every message we bookmarked.
	ids:     map[proto.Msg_Id]bool,
	// The list, as far as it has been fetched.
	list:    [dynamic]View_Bookmark,
	listed:  bool, // whether `list` has arrived since it was asked for
	more:    bool, // there are older bookmarks than those in `list`
	loading: bool,
	count:   int, // incremented whenever any of this changes
}

Bookmarks_Client :: struct {
	ids:       map[proto.Msg_Id]bool,
	listing:   bool, // the UI shows the list
	// Where the next page starts: after the last bookmark fetched.
	next_time: proto.Unix_Ms,
	next:      proto.Msg_Id,
	asked:     u64, // identifies the latest request for a page
}

bookmark_set :: proc(c: ^Server_Conn, id: proto.Msg_Id, on: bool) {
	buf: [proto.BOOKMARK_SET_SIZE]u8
	request(
		c,
		.Bookmark_Set,
		proto.encode_bookmark_set(&buf, id, on),
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			// One that succeeded arrives as Bookmark_Changed.
			#partial switch status {
			case .Ok, .Reset:
			case .Too_Large:
				notify(
					c,
					false,
					fmt.tprintf("You can't have more than %d bookmarks.", proto.MAX_BOOKMARKS),
				)
			case .Not_Found:
				notify(c, false, "That message no longer exists.")
			case .Invalid:
				notify(c, false, "A deleted message can't be bookmarked.")
			case:
				notify(c, false, fmt.tprintf("The server failed to change the bookmark (%v).", status))
			}
		},
	)
}

bookmarks_command :: proc(c: ^Server_Conn, cmd: Bookmarks_Command) {
	b := &c.bookmarks
	switch {
	case cmd.close:
		b.listing = false
		b.asked += 1 // a page still on its way is dropped
	case cmd.more:
		if b.listing && b.next != 0 {
			bookmarks_fetch(c, false)
		}
	case:
		b.listing = true
		bookmarks_fetch(c, true)
	}
}

// bookmarks_fetch asks for the first page of the list (`fresh`), or for the
// page after the last one.
@(private = "file")
bookmarks_fetch :: proc(c: ^Server_Conn, fresh: bool) {
	b := &c.bookmarks
	if fresh {
		b.next_time, b.next = 0, 0
	}
	b.asked += 1
	publish_bookmarks_loading(c)
	buf: [proto.BOOKMARKS_GET_SIZE]u8
	request(
		c,
		.Bookmarks_Get,
		proto.encode_bookmarks_get(&buf, b.next_time, b.next),
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			b := &c.bookmarks
			if tag != b.asked {
				return
			}
			if status != .Ok {
				if status != .Reset {
					notify(c, false, fmt.tprintf("The server failed to list the bookmarks (%v).", status))
				}
				publish_bookmarks(c, nil, false, b.next == 0)
				return
			}
			buf := make([]proto.Bookmark, proto.BOOKMARKS_PAGE, context.temp_allocator)
			list, more, ok := proto.decode_bookmarks_page(body, buf)
			if !ok {
				return
			}
			first := b.next == 0
			if len(list) > 0 {
				last := list[len(list) - 1]
				b.next_time, b.next = last.time, last.msg.id
			}
			publish_bookmarks(c, list, more && len(list) > 0, first)
		},
		b.asked,
	)
}

// bookmarks_event handles an event about bookmarks. It returns false if `op`
// isn't one.
bookmarks_event :: proc(c: ^Server_Conn, op: proto.Event_Op, body: []u8) -> bool {
	b := &c.bookmarks
	#partial switch op {
	case .Bookmarks:
		buf := new([proto.MAX_BOOKMARKS]proto.Msg_Id, context.temp_allocator)
		ids, ok := proto.decode_bookmarks(body, buf)
		if !ok {
			return true
		}
		clear(&b.ids)
		for id in ids {
			b.ids[id] = true
		}
		publish_bookmark_ids(c)
	case .Bookmark_Changed:
		id, _, on, ok := proto.decode_bookmark_changed(body)
		if !ok {
			return true
		}
		if on {
			b.ids[id] = true
		} else {
			delete_key(&b.ids, id)
		}
		publish_bookmark_ids(c)
		if c.view == nil {
			log.infof("[bookmarks] #%d %s", id, "bookmarked" if on else "no longer bookmarked")
		}
	case:
		return false
	}
	if b.listing {
		bookmarks_fetch(c, true)
	}
	return true
}

// bookmarked_changed passes a message that changed on to the list, if it is
// bookmarked.
bookmarked_changed :: proc(c: ^Server_Conn, m: Msg) {
	if !c.bookmarks.listing || !c.bookmarks.ids[m.id] {
		return
	}
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	for &e in v.bookmarks.list {
		if e.msg.id == m.id {
			view_message_destroy(e.msg)
			e.msg = view_message_of(m)
			v.bookmarks.count += 1
		}
	}
}

bookmarks_destroy :: proc(c: ^Server_Conn) {
	delete(c.bookmarks.ids)
	c.bookmarks = {}
}

@(private = "file")
publish_bookmark_ids :: proc(c: ^Server_Conn) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	clear(&v.bookmarks.ids)
	for id in c.bookmarks.ids {
		v.bookmarks.ids[id] = true
	}
	v.bookmarks.count += 1
}

@(private = "file")
publish_bookmarks_loading :: proc(c: ^Server_Conn) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	v.bookmarks.loading = true
	v.bookmarks.count += 1
}

// publish_bookmarks shows a page of the list: the first one (`first`), which
// replaces what was shown, or the next.
@(private = "file")
publish_bookmarks :: proc(c: ^Server_Conn, list: []proto.Bookmark, more, first: bool) {
	v := c.view
	if v == nil {
		if first && len(list) == 0 {
			log.info("[bookmarks] none")
		}
		for e in list {
			log.infof(
				"[bookmarks] %s %s (#%d): %s",
				room_name(c, proto.Room(e.msg.conv)),
				account_display(c, e.msg.sender),
				e.msg.id,
				describe(c, e.msg),
			)
		}
		if more {
			log.info("[bookmarks] and more (/bookmarks more)")
		}
		return
	}
	view_write(v)
	bm := &v.bookmarks
	if first {
		view_clear_bookmark_list(v)
	}
	for e in list {
		kept := msg_of(e.msg)
		append(&bm.list, View_Bookmark{e.time, e.msg.conv, view_message_of(kept)})
		msg_destroy(&kept)
	}
	bm.listed, bm.more, bm.loading = true, more, false
	bm.count += 1
}

// Call with the mutex held.
view_clear_bookmark_list :: proc(v: ^View) {
	bm := &v.bookmarks
	for e in bm.list {
		view_message_destroy(e.msg)
	}
	clear(&bm.list)
	bm.listed, bm.more, bm.loading = false, false, false
}

// Call with the mutex held.
view_clear_bookmarks :: proc(v: ^View) {
	view_clear_bookmark_list(v)
	clear(&v.bookmarks.ids)
	v.bookmarks.count += 1
}

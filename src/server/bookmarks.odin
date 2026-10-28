package server

import "core:log"

import "common:proto"
import "sqlite"

// Bookmarks (src/common/proto/bookmarks.odin): the messages an account
// marked to come back to. Each is a row of `bookmarks`, which a message's
// purge removes (a trigger, db_schema.odin). Whether a message is bookmarked
// isn't part of the message: a connection is told which ones are at login
// (Bookmarks) and as that changes (Bookmark_Changed).

// The column of Bookmarks_Of that holds the bookmark's time, after the
// message's own (MSG_COLS).
@(private = "file")
BOOKMARK_TIME_COL :: 15

bookmark_set :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	msg_id, on, ok := proto.decode_bookmark_set(body)
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	acc := u.account
	now := proto.Unix_Ms(unix_ms())
	if on {
		m, _, readable := msg_readable(s, u, msg_id)
		switch {
		case !readable:
			respond(u, id, .Not_Found)
			return
		case .Deleted in m.flags:
			respond(u, id, .Invalid)
			return
		case bookmark_count(s, acc) >= proto.MAX_BOOKMARKS:
			respond(u, id, .Too_Large)
			return
		}
		q := db_query(&s.db, .Bookmark_Add, i64(acc.id), i64(msg_id), i64(now))
		if !db_run(&s.db, q) {
			respond(u, id, .Internal)
			return
		}
		if db_changed(&s.db) == 0 {
			respond(u, id, .Ok) // bookmarked already
			return
		}
	} else {
		if !db_write(&s.db, .Bookmark_Remove, i64(acc.id), i64(msg_id)) {
			respond(u, id, .Internal)
			return
		}
		if db_changed(&s.db) == 0 {
			respond(u, id, .Ok)
			return
		}
	}
	respond(u, id, .Ok)
	log.debugf("%s %s message %d", conn_label(u), "bookmarked" if on else "unbookmarked", msg_id)
	buf: [proto.BOOKMARK_CHANGED_SIZE]u8
	event := proto.encode_bookmark_changed(&buf, msg_id, now, on)
	for other in acc.conns {
		send_event(other, .Bookmark_Changed, event)
	}
}

@(private = "file")
bookmark_count :: proc(s: ^Server, acc: ^Account) -> int {
	q := db_query(&s.db, .Bookmark_Count, i64(acc.id))
	row, _ := db_step(&s.db, q)
	n := int(db_col_int(q, 0)) if row else 0
	sqlite.reset(q)
	return n
}

// bookmarks_get answers with a page of the account's bookmarks, the newest
// first, leaving out those in conversations it can't read.
bookmarks_get :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	before_time, before, ok := proto.decode_bookmarks_get(body)
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	// One more than a page, to know whether there are more.
	list := make([dynamic]proto.Bookmark, 0, proto.BOOKMARKS_PAGE + 1, context.temp_allocator)
	q := db_query(&s.db, .Bookmarks_Of, i64(u.account.id), i64(before_time), i64(before))
	for len(list) <= proto.BOOKMARKS_PAGE {
		row, stepped := db_step(&s.db, q)
		if !stepped {
			respond(u, id, .Internal)
			return
		}
		if !row {
			break
		}
		m := msg_of_row(q)
		conv := conv_by_id(&s.convs, m.conv)
		if conv == nil || !conv_reader(conv, u.account) {
			continue
		}
		append(&list, proto.Bookmark{proto.Unix_Ms(db_col_int(q, BOOKMARK_TIME_COL)), m})
	}
	sqlite.reset(q)
	more := len(list) > proto.BOOKMARKS_PAGE
	if more {
		resize(&list, proto.BOOKMARKS_PAGE)
	}
	for &b in list {
		attach_reactions(s, &b.msg, u.account.id)
		attach_files(s, &b.msg)
	}
	out := make([]u8, proto.MAX_BODY_SIZE, context.temp_allocator)
	page, _ := proto.encode_bookmarks_page(out, list[:], more)
	respond(u, id, .Ok, page)
}

// send_bookmarks tells a connection that just logged in which messages its
// account bookmarked (see directory_sync).
send_bookmarks :: proc(s: ^Server, u: ^Conn) {
	ids := make([dynamic]proto.Msg_Id, 0, 64, context.temp_allocator)
	q := db_query(&s.db, .Bookmark_Ids, i64(u.account.id))
	for len(ids) < proto.MAX_BOOKMARKS {
		row, ok := db_step(&s.db, q)
		if !ok || !row {
			break
		}
		append(&ids, proto.Msg_Id(db_col_int(q, 0)))
	}
	sqlite.reset(q)
	buf := new([proto.BOOKMARKS_MAX_SIZE]u8, context.temp_allocator)
	send_event(u, .Bookmarks, proto.encode_bookmarks(buf, ids[:]))
}

package conn

import log "common:wlog"
import "core:fmt"
import "core:strings"

import "common:proto"

// Searching messages (src/common/proto/search.odin), either in the conversation
// being looked at or in all of our conversations. The results go to the UI
// (View.search), newest first and one page at a time: More asks for the page
// older than the last one shown. Only the answer to the latest search is used.

// Search for `query` in the conversation being looked at, or with `all` in
// every one of our conversations. With `more`, fetch the next page of the last
// search.
Search_Command :: struct {
	query: string, // owned by the command
	all:   bool,
	more:  bool,
}

// View_Found is a message that a search found, and where it was found.
View_Found :: struct {
	conv: proto.Conv_Id,
	msg:  View_Message,
}

View_Search :: struct {
	query:   string, // owned; the query these results belong to
	conv:    proto.Conv_Id, // 0: all of our conversations
	found:   [dynamic]View_Found,
	more:    bool, // there may be more (older) results
	loading: bool,
	error:   string, // static; why there are no results, if there is a reason
	count:   int, // incremented whenever it changes
}

Search_Client :: struct {
	query: string, // owned; the latest search
	conv:  proto.Conv_Id,
	last:  proto.Msg_Id, // the oldest message looked at so far
	asked: u64, // identifies the latest search request
}

// How many results a page asks for.
SEARCH_PAGE :: 30

search_start :: proc(c: ^Server_Conn, cmd: Search_Command) {
	sc := &c.search
	if !cmd.more {
		delete(sc.query)
		sc.query = strings.clone(strings.trim_space(cmd.query))
		sc.conv = 0 if cmd.all else c.convs.viewing
		sc.last = 0
	}
	if sc.query == "" {
		return
	}
	sc.asked += 1
	buf: [proto.MSG_SEARCH_MAX_SIZE]u8
	body := proto.encode_msg_search(
		&buf,
		{conv = sc.conv, before = sc.last, limit = SEARCH_PAGE, query = sc.query},
	)
	publish_search(c, nil, false, true, "", !cmd.more)
	request(
		c,
		.Msg_Search,
		body,
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			sc := &c.search
			if tag != sc.asked {
				return
			}
			#partial switch status {
			case .Ok:
			case .Invalid:
				publish_search(c, nil, false, false, "Enter a search term.", false)
				return
			case .Reset:
				publish_search(c, nil, false, false, "", false)
				return
			case:
				publish_search(c, nil, false, false, "The server failed to run the search.", false)
				return
			}
			buf: [proto.MAX_SEARCH_LIMIT + 1]proto.Message
			searched_to, more, found, ok := proto.decode_search_answer(body, buf[:])
			if !ok {
				return
			}
			// Where the next page continues from.
			sc.last = searched_to
			report_search(c, sc.query, sc.last, found, more & proto.MORE_BEFORE != 0)
			publish_search(c, found, more & proto.MORE_BEFORE != 0, false, "", false)
		},
		sc.asked,
	)
}

search_destroy :: proc(c: ^Server_Conn) {
	delete(c.search.query)
	c.search = {}
}

// publish_search tells the UI how the latest search is going: `found` is added
// to what is shown (after clearing it, with `fresh`), whether there may be
// more results, whether the search is still running, and what went wrong.
@(private = "file")
publish_search :: proc(
	c: ^Server_Conn,
	found: []proto.Message,
	more, loading: bool,
	error: string,
	fresh: bool,
) {
	v := c.view
	if v == nil {
		if error != "" {
			log.warnf("[search] %s", error)
		}
		return
	}
	sc := &c.search
	view_write(v)
	s := &v.search
	if fresh {
		view_clear_search(v)
		s.query = strings.clone(sc.query)
		s.conv = sc.conv
	}
	for m in found {
		kept := msg_of(m)
		append(&s.found, View_Found{m.conv, view_message_of(kept)})
		msg_destroy(&kept)
	}
	s.more, s.loading, s.error = more, loading, error
	s.count += 1
}

// Call with the mutex held.
view_clear_search :: proc(v: ^View) {
	s := &v.search
	for f in s.found {
		view_message_destroy(f.msg)
	}
	clear(&s.found)
	delete(s.query)
	s.query, s.conv, s.more, s.loading, s.error = "", 0, false, false, ""
}

_ :: fmt

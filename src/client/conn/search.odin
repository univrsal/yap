package conn

import log "common:wlog"
import "core:fmt"
import "core:strings"
import "core:sync"

import "common:proto"

/*
Searching messages (src/common/proto/search.odin): in the conversation
being looked at, or in all of ours. The results go to the UI (View.search)
newest first, a page at a time: More asks for the page older than the
last one shown. Only the answer to the latest search is taken.
*/

// Search for `query`: in the conversation being looked at, or with
// `all`, in every one of ours; with `more`, the next page of the last
// search.
Search_Command :: struct {
	query: string, // owned by the command
	all:   bool,
	more:  bool,
}

// View_Found is a message a search found, and where.
View_Found :: struct {
	conv: proto.Conv_Id,
	msg:  View_Message,
}

View_Search :: struct {
	query:   string, // owned; what the results are of
	conv:    proto.Conv_Id, // 0: all of ours
	found:   [dynamic]View_Found,
	more:    bool, // there may be more, older
	loading: bool,
	error:   string, // static; why there's nothing, if there's a why
	count:   int, // bumped whenever it changes
}

Search_Client :: struct {
	query:  string, // owned; the latest search
	conv:   proto.Conv_Id,
	last:   proto.Msg_Id, // the oldest looked at so far
	asked:  u64, // which asking is the latest
}

// How many a page asks for.
SEARCH_PAGE :: 30

search_start :: proc(c: ^Voice_Client, cmd: Search_Command) {
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
	body := proto.encode_msg_search(&buf, {conv = sc.conv, before = sc.last, limit = SEARCH_PAGE, query = sc.query})
	publish_search(c, nil, false, true, "", !cmd.more)
	request(c, .Msg_Search, body, proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
		sc := &c.search
		if tag != sc.asked {
			return
		}
		#partial switch status {
		case .Ok:
		case .Invalid:
			publish_search(c, nil, false, false, "Type a word to look for.", false)
			return
		case .Reset:
			publish_search(c, nil, false, false, "", false)
			return
		case:
			publish_search(c, nil, false, false, "The server wouldn't search there.", false)
			return
		}
		buf: [proto.MAX_SEARCH_LIMIT + 1]proto.Message
		searched_to, more, found, ok := proto.decode_search_answer(body, buf[:])
		if !ok {
			return
		}
		// Where the next page goes on from.
		sc.last = searched_to
		if c.view == nil {
			if len(found) == 0 && sc.last == 0 {
				log.infof("[search] nothing has %q", sc.query)
			}
			for m in found {
				log.infof("[search] %s %s (#%d): %s", room_name(c, proto.Room(m.conv)), account_display(c, m.sender), m.id, m.text)
			}
			if more & proto.MORE_BEFORE != 0 {
				log.info("[search] and maybe more (/search more)")
			}
		}
		publish_search(c, found, more & proto.MORE_BEFORE != 0, false, "", false)
	}, sc.asked)
}

search_destroy :: proc(c: ^Voice_Client) {
	delete(c.search.query)
	c.search = {}
}

/*
publish_search tells the UI how the latest search is going: `found` added
to what's shown (after clearing it, with `fresh`), whether there may be
more, whether it's still being looked for, and what went wrong.
*/
@(private = "file")
publish_search :: proc(c: ^Voice_Client, found: []proto.Message, more, loading: bool, error: string, fresh: bool) {
	v := c.view
	if v == nil {
		if error != "" {
			log.warnf("[search] %s", error)
		}
		return
	}
	sc := &c.search
	sync.guard(&v.mutex)
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

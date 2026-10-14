package gateway

import "core:fmt"
import "core:strconv"

import "common:http"
import "common:lite"
import "common:proto"

/*
Reading (docs/bot-api, phase 4): what the model has, answered from it,
and history, pins, search, members, browsing and reactors, asked of the
server. Lists are JSON arrays; where there's more to say about a page
than its items (search, browse, reactors), an object.

History comes oldest first, as the protocol has it, and a page may be
shorter than asked for when its messages wouldn't fit in one stream
message; there's nothing more that way only once a page is empty.
*/

// GET /accounts: every account on the server, by id.
@(private)
accounts_run :: proc(c: ^Conn, j: ^Job) {
	reply(j, json_reply(200, accounts_json(&c.model)))
}

// GET /accounts/{id}
@(private)
account_run :: proc(c: ^Conn, j: ^Job) {
	id, ok := param_id(j, 0)
	if !ok {
		reply(j, bad_id(j.params[0]))
		return
	}
	a, found := &c.model.accounts[proto.Account_Id(id)]
	if !found {
		reply(j, error_reply(404, "not_found", "There's no such account."))
		return
	}
	reply(j, json_reply(200, account_json(&c.model, &a.account)))
}

// GET /roles: every role, top first, everyone's last.
@(private)
roles_run :: proc(c: ^Conn, j: ^Job) {
	reply(j, json_reply(200, roles_json(&c.model)))
}

// GET /convs: the conversations the account is in.
@(private)
convs_run :: proc(c: ^Conn, j: ^Job) {
	reply(j, json_reply(200, convs_json(&c.model)))
}

// GET /convs/{id}: one of them.
@(private)
conv_run :: proc(c: ^Conn, j: ^Job) {
	id, ok := param_id(j, 0)
	if !ok {
		reply(j, bad_id(j.params[0]))
		return
	}
	conv, found := &c.model.convs[proto.Conv_Id(id)]
	if !found {
		reply(j, error_reply(404, "not_found", "The account isn't in such a conversation."))
		return
	}
	reply(j, json_reply(200, conv_json(&c.model, &conv.conv)))
}

Browse_JSON :: struct {
	convs: []Conv_JSON,
	more:  bool, // there are more after these: ask with offset
}

// GET /convs/browse?q=&offset=&limit=: the channels there are to join.
@(private)
browse_run :: proc(c: ^Conn, j: ^Job) {
	b := proto.Browse {
		limit = proto.BROWSE_PAGE,
	}
	ok: bool
	b.query, _ = query_param(j, "q")
	if len(b.query) > proto.MAX_BROWSE_QUERY {
		reply(
			j,
			error_reply(
				400,
				"invalid",
				fmt.tprintf("q is at most %d bytes.", proto.MAX_BROWSE_QUERY),
			),
		)
		return
	}
	if b.offset, ok = query_int(j, "offset", 0, 0, int(max(u16))); !ok {
		reply(j, error_reply(400, "invalid", "offset is a number from 0."))
		return
	}
	if b.limit, ok = query_int(j, "limit", proto.BROWSE_PAGE, 1, proto.MAX_BROWSE_LIMIT); !ok {
		reply(
			j,
			error_reply(400, "invalid", fmt.tprintf("limit is 1 to %d.", proto.MAX_BROWSE_LIMIT)),
		)
		return
	}
	j.answer = proc(c: ^Conn, j: ^Job, a: lite.Answer) {
		if a.status != .Ok {
			reply(j, status_reply(a.status))
			return
		}
		buf := make([]proto.Conv, proto.MAX_BROWSE_LIMIT, context.temp_allocator)
		more, convs, ok := proto.decode_browse_page(a.body, buf)
		if !ok {
			reply(j, status_reply(.Internal))
			return
		}
		out := Browse_JSON {
			convs = make([]Conv_JSON, len(convs), context.temp_allocator),
			more  = more,
		}
		for &conv, i in convs {
			out.convs[i] = conv_json(&c.model, &conv)
		}
		reply(j, json_reply(200, out))
	}
	body_buf: [proto.CONV_BROWSE_MAX_SIZE]u8
	ask(c, j, .Conv_Browse, proto.encode_conv_browse(&body_buf, b))
}

// GET /convs/{id}/members: its members, as accounts.
@(private)
members_run :: proc(c: ^Conn, j: ^Job) {
	id, ok := param_id(j, 0)
	if !ok {
		reply(j, bad_id(j.params[0]))
		return
	}
	j.answer = proc(c: ^Conn, j: ^Job, a: lite.Answer) {
		if a.status != .Ok {
			reply(j, status_reply(a.status))
			return
		}
		buf := make([]proto.Account_Id, len(a.body) / 4 + 1, context.temp_allocator)
		members, ok := proto.decode_conv_members(a.body, buf)
		if !ok {
			reply(j, status_reply(.Internal))
			return
		}
		reply(j, json_reply(200, some_accounts_json(&c.model, members)))
	}
	body_buf: [4]u8
	ask(c, j, .Conv_Members, proto.encode_conv_id(&body_buf, proto.Conv_Id(id)))
}

/*
GET /convs/{id}/messages?before=&after=&around=&limit=&thread=: a page
of history, oldest first. One of before, after or around (a message's
id, which around includes); none is the newest. `thread` is a thread's
first message, for its replies. `limit` is 1 to 50 (50).
*/
@(private)
history_run :: proc(c: ^Conn, j: ^Job) {
	conv, ok := param_id(j, 0)
	if !ok {
		reply(j, bad_id(j.params[0]))
		return
	}
	h := proto.Msg_History {
		conv = proto.Conv_Id(conv),
		dir  = .Before,
	}
	anchors := 0
	for dir in proto.History_Dir {
		name := enum_name(dir)
		value, given := query_param(j, name)
		if !given {
			continue
		}
		anchor, anchor_ok := strconv.parse_u64(value, 10)
		if !anchor_ok || anchor == 0 {
			reply(j, bad_id(value))
			return
		}
		h.anchor, h.dir = proto.Msg_Id(anchor), dir
		anchors += 1
	}
	if anchors > 1 {
		reply(j, error_reply(400, "invalid", "One of before, after or around, not more."))
		return
	}
	if thread, given := query_param(j, "thread"); given {
		root, root_ok := strconv.parse_u64(thread, 10)
		if !root_ok || root == 0 {
			reply(j, bad_id(thread))
			return
		}
		h.thread_root = proto.Msg_Id(root)
	}
	if h.limit, ok = query_int(j, "limit", proto.MAX_HISTORY_LIMIT, 1, proto.MAX_HISTORY_LIMIT);
	   !ok {
		reply(
			j,
			error_reply(400, "invalid", fmt.tprintf("limit is 1 to %d.", proto.MAX_HISTORY_LIMIT)),
		)
		return
	}
	j.answer = proc(c: ^Conn, j: ^Job, a: lite.Answer) {
		if a.status != .Ok {
			reply(j, status_reply(a.status))
			return
		}
		buf := make([]proto.Message, proto.MAX_HISTORY_LIMIT, context.temp_allocator)
		_, msgs, ok := proto.decode_history_page(a.body, buf)
		if !ok {
			reply(j, status_reply(.Internal))
			return
		}
		reply(j, json_reply(200, messages_json(&c.model, msgs)))
	}
	body_buf: [proto.MSG_HISTORY_SIZE]u8
	ask(c, j, .Msg_History, proto.encode_msg_history(&body_buf, h))
}

// GET /convs/{id}/pins: its pinned messages, the newest pin first.
@(private)
pins_run :: proc(c: ^Conn, j: ^Job) {
	conv, ok := param_id(j, 0)
	if !ok {
		reply(j, bad_id(j.params[0]))
		return
	}
	j.answer = proc(c: ^Conn, j: ^Job, a: lite.Answer) {
		if a.status != .Ok {
			reply(j, status_reply(a.status))
			return
		}
		buf := make([]proto.Message, proto.MAX_PINS, context.temp_allocator)
		msgs, ok := proto.decode_message_list(a.body, buf)
		if !ok {
			reply(j, status_reply(.Internal))
			return
		}
		reply(j, json_reply(200, messages_json(&c.model, msgs)))
	}
	body_buf: [4]u8
	ask(c, j, .Pins_Get, proto.encode_conv_id(&body_buf, proto.Conv_Id(conv)))
}

Search_JSON :: struct {
	messages:    []Message_JSON, // newest first
	// The oldest message looked at, to ask again `before`, if `more`.
	searched_to: Maybe(string),
	more:        bool,
}

/*
GET /search?q=&conv=&before=&limit=: text messages with every word of
`q` in them (as the client's search: "a phrase", from:username), in one
conversation or all the account's, older than `before`, newest first.
*/
@(private)
search_run :: proc(c: ^Conn, j: ^Job) {
	s := proto.Msg_Search{}
	given: bool
	if s.query, given = query_param(j, "q"); !given || s.query == "" {
		reply(j, error_reply(400, "invalid", "q is what to search for."))
		return
	}
	if len(s.query) > proto.MAX_SEARCH_QUERY {
		reply(
			j,
			error_reply(
				400,
				"invalid",
				fmt.tprintf("q is at most %d bytes.", proto.MAX_SEARCH_QUERY),
			),
		)
		return
	}
	for name in ([2]string{"conv", "before"}) {
		value, there := query_param(j, name)
		if !there {
			continue
		}
		id, ok := strconv.parse_u64(value, 10)
		if !ok || id == 0 {
			reply(j, bad_id(value))
			return
		}
		if name == "conv" {
			s.conv = proto.Conv_Id(id)
		} else {
			s.before = proto.Msg_Id(id)
		}
	}
	ok: bool
	if s.limit, ok = query_int(j, "limit", 25, 1, proto.MAX_SEARCH_LIMIT); !ok {
		reply(
			j,
			error_reply(400, "invalid", fmt.tprintf("limit is 1 to %d.", proto.MAX_SEARCH_LIMIT)),
		)
		return
	}
	j.answer = proc(c: ^Conn, j: ^Job, a: lite.Answer) {
		if a.status != .Ok {
			reply(j, status_reply(a.status))
			return
		}
		buf := make([]proto.Message, proto.MAX_SEARCH_LIMIT, context.temp_allocator)
		searched_to, more, msgs, ok := proto.decode_search_answer(a.body, buf)
		if !ok {
			reply(j, status_reply(.Internal))
			return
		}
		out := Search_JSON {
			messages = messages_json(&c.model, msgs),
			more     = more & proto.MORE_BEFORE != 0,
		}
		if searched_to != 0 {
			out.searched_to = id_string(searched_to)
		}
		reply(j, json_reply(200, out))
	}
	body_buf: [proto.MSG_SEARCH_MAX_SIZE]u8
	ask(c, j, .Msg_Search, proto.encode_msg_search(&body_buf, s))
}

Reactors_JSON :: struct {
	total:    int, // how many reacted with it
	// The first of them (at most 50), the earliest first.
	accounts: []Account_JSON,
}

// GET /messages/{id}/reactions/{emoji}: who reacted with it. The emoji is
// the character, URL-encoded, or :name: of one of the server's own.
@(private)
reactors_run :: proc(c: ^Conn, j: ^Job) {
	id, ok := param_id(j, 0)
	if !ok {
		reply(j, bad_id(j.params[0]))
		return
	}
	emoji := j.params[1]
	if len(emoji) > proto.MAX_REACTION_EMOJI {
		reply(j, error_reply(400, "invalid", "That's no emoji."))
		return
	}
	j.answer = proc(c: ^Conn, j: ^Job, a: lite.Answer) {
		if a.status != .Ok {
			reply(j, status_reply(a.status))
			return
		}
		buf: [proto.MAX_REACTORS]proto.Account_Id
		total, accounts, ok := proto.decode_reactors(a.body, &buf)
		if !ok {
			reply(j, status_reply(.Internal))
			return
		}
		reply(j, json_reply(200, Reactors_JSON{total, some_accounts_json(&c.model, accounts)}))
	}
	body_buf: [proto.REACTORS_GET_MAX_SIZE]u8
	ask(c, j, .Reactors_Get, proto.encode_reactors_get(&body_buf, proto.Msg_Id(id), emoji))
}

// some_accounts_json is those accounts, as the model has them; one it
// doesn't know has only its id.
@(private)
some_accounts_json :: proc(m: ^Model, ids: []proto.Account_Id) -> []Account_JSON {
	out := make([]Account_JSON, len(ids), context.temp_allocator)
	for id, i in ids {
		if a, known := &m.accounts[id]; known {
			out[i] = account_json(m, &a.account)
		} else {
			out[i] = {
				id = id_string(id),
			}
		}
	}
	return out
}

// param_id is the job's nth path parameter as an id.
@(private)
param_id :: proc(j: ^Job, n: int) -> (id: u64, ok: bool) {
	id, ok = strconv.parse_u64(j.params[n], 10)
	return id, ok && id != 0
}

@(private)
bad_id :: proc(s: string) -> Reply {
	return error_reply(400, "invalid", fmt.tprintf("%q isn't an id.", s))
}

// query_param is a query parameter of the job's request, decoded.
@(private)
query_param :: proc(j: ^Job, name: string) -> (string, bool) {
	return http.query_value(j.query, name)
}

// query_int is a number from the query, `default` if it isn't there;
// false if it's there and not one from `least` to `most`.
@(private)
query_int :: proc(j: ^Job, name: string, default, least, most: int) -> (n: int, ok: bool) {
	value, given := query_param(j, name)
	if !given {
		return default, true
	}
	n, ok = strconv.parse_int(value, 10)
	return n, ok && n >= least && n <= most
}

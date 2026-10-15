package gateway

import "core:fmt"
import "core:strconv"

import "common:http"
import "common:lite"
import "common:proto"

// Reading (docs/bot-api, phase 4): some requests are answered from the model,
// while history, pins, search, members, browsing and reactors are requested
// from the server. Lists are returned as JSON arrays, except where a page
// carries more information than its items (search, browse, reactors), in
// which case an object is returned.
//
// History comes oldest first, as in the protocol. A page may be shorter than
// requested when its messages wouldn't fit in one stream message, so there is
// nothing more in that direction only once a page is empty.

// GET /accounts returns every account on the server, sorted by id.
@(private)
accounts_run :: proc(c: ^Conn, j: ^Job) {
	reply(j, json_reply(200, accounts_json(&c.model)))
}

// GET /accounts/{id} returns one account.
@(private)
account_run :: proc(c: ^Conn, j: ^Job) {
	id, ok := param_id(j, 0)
	if !ok {
		reply(j, bad_id(j.params[0]))
		return
	}
	a, found := &c.model.accounts[proto.Account_Id(id)]
	if !found {
		reply(j, error_reply(404, "not_found", "There is no account with this id."))
		return
	}
	reply(j, json_reply(200, account_json(&c.model, &a.account)))
}

// GET /roles returns every role, top first, with the everyone role last.
@(private)
roles_run :: proc(c: ^Conn, j: ^Job) {
	reply(j, json_reply(200, roles_json(&c.model)))
}

// GET /convs returns the conversations the account is in.
@(private)
convs_run :: proc(c: ^Conn, j: ^Job) {
	reply(j, json_reply(200, convs_json(&c.model)))
}

// GET /convs/{id} returns one of those conversations.
@(private)
conv_run :: proc(c: ^Conn, j: ^Job) {
	id, ok := param_id(j, 0)
	if !ok {
		reply(j, bad_id(j.params[0]))
		return
	}
	conv, found := &c.model.convs[proto.Conv_Id(id)]
	if !found {
		reply(
			j,
			error_reply(404, "not_found", "The account is not in a conversation with this id."),
		)
		return
	}
	reply(j, json_reply(200, conv_json(&c.model, &conv.conv)))
}

Browse_JSON :: struct {
	convs: []Conv_JSON,
	more:  bool, // there are more results after these, request them with offset
}

// GET /convs/browse?q=&offset=&limit= returns the channels that can be
// joined.
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
				fmt.tprintf("q can be at most %d bytes long.", proto.MAX_BROWSE_QUERY),
			),
		)
		return
	}
	if b.offset, ok = query_int(j, "offset", 0, 0, int(max(u16))); !ok {
		reply(j, error_reply(400, "invalid", "offset must be a number that is 0 or greater."))
		return
	}
	if b.limit, ok = query_int(j, "limit", proto.BROWSE_PAGE, 1, proto.MAX_BROWSE_LIMIT); !ok {
		reply(
			j,
			error_reply(
				400,
				"invalid",
				fmt.tprintf("limit must be between 1 and %d.", proto.MAX_BROWSE_LIMIT),
			),
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

// GET /convs/{id}/members returns the members of the conversation as
// accounts.
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

// GET /convs/{id}/messages?before=&after=&around=&limit=&thread= returns a
// page of history, oldest first. At most one of before, after or around may
// be given, each as a message id (around includes that message). Without any
// of them the newest messages are returned. `thread` is the first message of
// a thread, which makes the page contain that thread's replies. `limit` is
// 1 to 50 and defaults to 50.
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
		reply(j, error_reply(400, "invalid", "Only one of before, after or around may be given."))
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
			error_reply(
				400,
				"invalid",
				fmt.tprintf("limit must be between 1 and %d.", proto.MAX_HISTORY_LIMIT),
			),
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

// GET /convs/{id}/pins returns the pinned messages of the conversation, with
// the most recent pin first.
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
	// The oldest message that was searched. If `more` is set, pass it as
	// `before` to continue the search.
	searched_to: Maybe(string),
	more:        bool,
}

// GET /search?q=&conv=&before=&limit= returns text messages that contain every
// word of `q`, using the same syntax as the client's search ("a phrase",
// from:username). It searches one conversation or all of the account's
// conversations, only considers messages older than `before` and returns the
// newest first.
@(private)
search_run :: proc(c: ^Conn, j: ^Job) {
	s := proto.Msg_Search{}
	given: bool
	if s.query, given = query_param(j, "q"); !given || s.query == "" {
		reply(j, error_reply(400, "invalid", "q is required and contains the text to search for."))
		return
	}
	if len(s.query) > proto.MAX_SEARCH_QUERY {
		reply(
			j,
			error_reply(
				400,
				"invalid",
				fmt.tprintf("q can be at most %d bytes long.", proto.MAX_SEARCH_QUERY),
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
			error_reply(
				400,
				"invalid",
				fmt.tprintf("limit must be between 1 and %d.", proto.MAX_SEARCH_LIMIT),
			),
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
	total:    int, // how many accounts reacted with it
	// The first accounts that reacted (at most 50), earliest first.
	accounts: []Account_JSON,
}

// GET /messages/{id}/reactions/{emoji} returns who reacted with the emoji. The
// emoji is the URL-encoded character, or :name: for one of the server's own
// emoji.
@(private)
reactors_run :: proc(c: ^Conn, j: ^Job) {
	id, ok := param_id(j, 0)
	if !ok {
		reply(j, bad_id(j.params[0]))
		return
	}
	emoji := j.params[1]
	if len(emoji) > proto.MAX_REACTION_EMOJI {
		reply(j, error_reply(400, "invalid", "The emoji is too long to be valid."))
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

// some_accounts_json returns the given accounts as the model has them. An
// account that the model doesn't know only has its id.
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

// param_id returns the job's nth path parameter as an id.
@(private)
param_id :: proc(j: ^Job, n: int) -> (id: u64, ok: bool) {
	id, ok = strconv.parse_u64(j.params[n], 10)
	return id, ok && id != 0
}

@(private)
bad_id :: proc(s: string) -> Reply {
	return error_reply(400, "invalid", fmt.tprintf("%q is not a valid id.", s))
}

// query_param returns the decoded value of a query parameter of the job's
// request.
@(private)
query_param :: proc(j: ^Job, name: string) -> (string, bool) {
	return http.query_value(j.query, name)
}

// query_int returns a number from the query, or `default` if the parameter
// isn't there. ok is false if the parameter is there but isn't a number from
// `least` to `most`.
@(private)
query_int :: proc(j: ^Job, name: string, default, least, most: int) -> (n: int, ok: bool) {
	value, given := query_param(j, name)
	if !given {
		return default, true
	}
	n, ok = strconv.parse_int(value, 10)
	return n, ok && n >= least && n <= most
}

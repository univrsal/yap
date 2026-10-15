package proto

// Searching messages (polish 13).
//
//	Msg_Search  [conv u32][before u64][limit u8][query str8]
//	            ->  [searched_to u64][more u8][count u16] messages,
//	                newest first
//
// A search finds text messages that contain every word of the query. It
// searches either one conversation that the account is a member of, or all
// of them with conv 0. Only messages older than `before` (0 means starting
// from the newest) are searched, and at most `limit` are returned
// (MAX_SEARCH_LIMIT). Words only match whole words, ignoring case and
// accents (prefix searches are not supported, see server/search.odin).
// A phrase in double quotes matches those words in that order, and
// `from:username` keeps only messages from that account.
// `more` (MORE_BEFORE) says there may be more messages older than
// `searched_to`, which is the oldest message that was looked at. To
// continue, ask again with it as `before`. A search that takes too long
// stops where it got to and signals that in the same way, whether or not it
// found anything, so that asking again continues from there. A query
// without any word is `Invalid`.

MAX_SEARCH_LIMIT :: 50
MAX_SEARCH_QUERY :: 200
MSG_SEARCH_MAX_SIZE :: 4 + 8 + 1 + 1 + MAX_SEARCH_QUERY

Msg_Search :: struct {
	conv:   Conv_Id, // 0 for all of the account's conversations
	before: Msg_Id, // 0 to start from the newest
	limit:  int,
	query:  string,
}

encode_msg_search :: proc(out: ^[MSG_SEARCH_MAX_SIZE]u8, s: Msg_Search) -> []u8 {
	w := Writer {
		buf = out[:],
	}
	put_u32(&w, u32(s.conv))
	put_u64(&w, u64(s.before))
	put_u8(&w, u8(clamp(s.limit, 1, MAX_SEARCH_LIMIT)))
	put_str8(&w, s.query[:min(len(s.query), MAX_SEARCH_QUERY)])
	return nil if w.overflow else out[:w.pos]
}

// encode_search_answer writes a Msg_Search answer, which consists of how far
// back the search looked and a page like Msg_History's. It contains as many
// of `msgs` as fit, and `fitted` says how many that is.
encode_search_answer :: proc(
	out: []u8,
	searched_to: Msg_Id,
	more: u8,
	msgs: []Message,
) -> (
	body: []u8,
	fitted: int,
) {
	if len(out) < 8 {
		return
	}
	w := Writer {
		buf = out[:8],
	}
	put_u64(&w, u64(searched_to))
	page: []u8
	page, fitted = encode_history_page(out[8:], more, msgs)
	if page == nil {
		return
	}
	return out[:8 + len(page)], fitted
}

decode_search_answer :: proc(
	body: []u8,
	buf: []Message,
) -> (
	searched_to: Msg_Id,
	more: u8,
	msgs: []Message,
	ok: bool,
) {
	if len(body) < 8 {
		return
	}
	r := Reader {
		buf = body[:8],
	}
	searched_to = Msg_Id(get_u64(&r))
	more, msgs, ok = decode_history_page(body[8:], buf)
	return
}

decode_msg_search :: proc(body: []u8) -> (s: Msg_Search, ok: bool) {
	r := Reader {
		buf = body,
	}
	s.conv = Conv_Id(get_u32(&r))
	s.before = Msg_Id(get_u64(&r))
	s.limit = int(get_u8(&r))
	s.query = get_str8(&r)
	if r.overflow ||
	   s.limit == 0 ||
	   s.limit > MAX_SEARCH_LIMIT ||
	   len(s.query) > MAX_SEARCH_QUERY {
		return {}, false
	}
	return s, true
}

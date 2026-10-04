package proto

/*
Searching messages (polish 13).

	Msg_Search  [conv u32][before u64][limit u8][query str8]
	            ->  [searched_to u64][more u8][count u16] messages,
	                newest first

finds text messages with every word of the query in them: in one
conversation the account is a member of, or with conv 0 in all of them;
of those older than `before` (0: from the newest), at most `limit`
(MAX_SEARCH_LIMIT). Words match whole words, ignoring case and accents
(there are no prefix searches: see server/search.odin); "a phrase" in
double quotes matches the words in a row; `from:username` keeps only
that account's.
`more` (MORE_BEFORE) says there may be more older than `searched_to`,
the oldest message looked at: ask again with it as `before`. A search
that takes too long stops where it got to and says so the same way,
having found something or not, so asking again goes on from there. A
query with no word in it is `Invalid`.
*/

MAX_SEARCH_LIMIT :: 50
MAX_SEARCH_QUERY :: 200
MSG_SEARCH_MAX_SIZE :: 4 + 8 + 1 + 1 + MAX_SEARCH_QUERY

Msg_Search :: struct {
	conv:   Conv_Id, // 0 for all of ours
	before: Msg_Id, // 0 for from the newest
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

// encode_search_answer writes a Msg_Search answer: how far back it
// looked, and a page as Msg_History's (as many of `msgs` as fit; `fitted`
// says how many).
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

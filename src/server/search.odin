package server

import "core:c"
import "core:log"
import "core:strings"
import "core:time"
import "core:unicode"

import "common:proto"
import "sqlite"

/*
Searching messages (src/common/proto/search.odin), with SQLite's full
text search: the index `messages_fts` (schema step 14) has the words of
every text message, kept by triggers as messages are posted, edited,
deleted and purged.

What's typed is never handed to FTS5's own query language as it is: it's
taken apart into words, "phrases" and from:username, and put together
again with every word quoted, so nothing typed can be an operator or a
syntax error.

There are no prefix searches (word*): FTS5 merges the lists of every
word a prefix matches before it gives the first row, inside one step of
the statement where the progress handler can't stop it, and for a
common prefix in a big history that held the loop for tens of
milliseconds (14 ms for jump* over a million messages). Whole words and
phrases are read lazily, newest first, and stop when they have enough.
A trailing * is dropped: the word is looked for whole.

A search runs in the server's loop like everything else, so it's cut
short: SQLite's progress handler stops it after SEARCH_BUDGET, and what
it found by then is the answer, with `more` set so the client can go on
from the last.
*/

// Within a turn of the loop's 5 ms, with room for the rest of the turn.
SEARCH_BUDGET :: 4 * time.Millisecond

// fts_query turns a search as typed into an FTS5 query (in the temp
// allocator), and the username after from:, if there's one. `ok` is false
// if there isn't a word to look for.
fts_query :: proc(raw: string) -> (query: string, from: string, ok: bool) {
	b := strings.builder_make(context.temp_allocator)
	terms := 0
	has_word :: proc(s: string) -> bool {
		for r in s {
			if unicode.is_letter(r) || unicode.is_digit(r) {
				return true
			}
		}
		return false
	}
	add :: proc(b: ^strings.Builder, terms: ^int, words: string) {
		if terms^ > 0 {
			strings.write_byte(b, ' ')
		}
		strings.write_byte(b, '"')
		for r in words {
			if r != '"' {
				strings.write_rune(b, r)
			}
		}
		strings.write_byte(b, '"')
		terms^ += 1
	}
	rest := raw
	for {
		rest = strings.trim_left_space(rest)
		if rest == "" {
			break
		}
		if rest[0] == '"' {
			// A phrase, to its closing quote or the end.
			end := strings.index_byte(rest[1:], '"')
			phrase := rest[1:] if end < 0 else rest[1:][:end]
			rest = "" if end < 0 else rest[end + 2:]
			if has_word(phrase) {
				add(&b, &terms, phrase)
			}
			continue
		}
		end := strings.index_any(rest, " \t")
		word := rest if end < 0 else rest[:end]
		rest = "" if end < 0 else rest[end:]
		if strings.has_prefix(word, "from:") && len(word) > len("from:") {
			from = strings.trim_prefix(strings.trim_prefix(word, "from:"), "@")
			continue
		}
		word = strings.trim_right(word, "*")
		if has_word(word) {
			add(&b, &terms, word)
		}
	}
	return strings.to_string(b), from, terms > 0
}

// msg_search answers a Msg_Search: a page of what matches, newest first.
msg_search :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	req, ok := proto.decode_msg_search(body)
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	query, from, has_words := fts_query(req.query)
	if !has_words {
		respond(u, id, .Invalid)
		return
	}
	if req.conv != 0 {
		if conv, status := conv_of_member(s, u, req.conv); conv == nil {
			respond(u, id, status)
			return
		}
	}
	sender: proto.Account_Id
	if from != "" {
		acc := account_find(&s.accounts, strings.to_lower(from, context.temp_allocator))
		if acc == nil {
			// Nobody by that name wrote anything.
			out: [8 + proto.HISTORY_HEADER_SIZE]u8
			empty, _ := proto.encode_search_answer(out[:], 0, 0, nil)
			respond(u, id, .Ok, empty)
			return
		}
		sender = acc.id
	}
	before := req.before if req.before != 0 else max(proto.Msg_Id)
	me := u.account.id

	q := db_stmt(&s.db, .Msg_Search)
	db_bind_text(q, 1, query)
	db_bind_int(q, 2, i64(min(before, proto.Msg_Id(max(i64)))))

	// Stopped once it has taken its share of the loop.
	deadline := time.tick_add(time.tick_now(), SEARCH_BUDGET)
	sqlite.progress_handler(s.db.conn, 1000, proc "c" (arg: rawptr) -> c.int {
		return 1 if time.tick_diff(time.tick_now(), (^time.Tick)(arg)^) < 0 else 0
	}, &deadline)
	defer sqlite.progress_handler(s.db.conn, 0, nil, nil)

	// Every match comes, newest first; those of the conversations asked
	// about, by whom it was asked, are kept. Where it got to is the
	// oldest it looked at, from where the next search goes on.
	found := make([dynamic]proto.Message, 0, req.limit, context.temp_allocator)
	more: u8
	searched_to := before
	for {
		rc := sqlite.step(q)
		if rc == sqlite.ROW {
			id := proto.Msg_Id(db_col_int(q, 0))
			conv_id := proto.Conv_Id(db_col_int(q, 1))
			author := proto.Account_Id(db_col_int(q, 2))
			flags := transmute(proto.Msg_Flags)u8(db_col_int(q, 5))
			wanted := .Deleted not_in flags && (sender == 0 || author == sender)
			if wanted {
				if req.conv != 0 {
					wanted = conv_id == req.conv
				} else {
					conv := conv_by_id(&s.convs, conv_id)
					wanted = conv != nil && conv_is_member(conv, me) && .Archived not_in conv.flags
				}
			}
			if wanted && len(found) == req.limit {
				more = proto.MORE_BEFORE
				break
			}
			searched_to = id
			if wanted {
				append(&found, msg_of_row(q))
			}
			continue
		}
		switch rc {
		case sqlite.DONE:
		case sqlite.INTERRUPT:
			// Out of time: what's found so far, and maybe more older than
			// where it got to.
			more = proto.MORE_BEFORE
			log.debugf("%s's search stopped after %d, at message %d", conn_label(u), len(found), searched_to)
		case:
			// FTS5 says no to the query: nothing typed should get here.
			log.warnf("search for %q: %s", query, db_error(&s.db))
			sqlite.reset(q)
			respond(u, id, .Invalid)
			return
		}
		break
	}
	sqlite.reset(q)
	for &m in found {
		attach_reactions(s, &m, me)
		attach_files(s, &m)
	}
	out := make([]u8, proto.MAX_BODY_SIZE, context.temp_allocator)
	page, fitted := proto.encode_search_answer(out, searched_to, more, found[:])
	if fitted < len(found) {
		// The rest didn't fit: the next search goes on from the last.
		page, _ = proto.encode_search_answer(out, found[fitted - 1].id, proto.MORE_BEFORE, found[:fitted])
	}
	respond(u, id, .Ok, page)
}

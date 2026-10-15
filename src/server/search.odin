package server

import "core:c"
import "core:log"
import "core:strings"
import "core:time"
import "core:unicode"

import "common:proto"
import "sqlite"

// Searching messages (see src/common/proto/search.odin) uses SQLite's full
// text search. The index `messages_fts` (schema step 14) contains the words
// of every text message and is kept up to date by triggers when messages
// are posted, edited, deleted and purged. The index `files_fts` (schema
// step 16) contains the names of the files that messages carry (see
// attachments.odin). Both are read side by side, newest first, and a message
// is only found once even if it matches in both ways.
//
// The text typed by the user is never passed to the query language of FTS5
// as is. It is split into words, "phrases" and from:username, and then
// assembled again with every word quoted. This way nothing that is typed
// can be interpreted as an operator or cause a syntax error.
//
// Prefix searches (word*) are not supported. FTS5 merges the lists of all
// words matching a prefix before it returns the first row. This happens in a
// single step of the statement, where the progress handler can't interrupt
// it, and for a common prefix in a big history it blocked the main loop for
// tens of milliseconds (14 ms for jump* over a million messages). Whole
// words and phrases are read lazily, newest first, and reading stops as soon
// as enough results are found. A trailing * is dropped and the word is
// searched for as a whole.
//
// A search runs in the server's main loop like everything else, so it is
// cut short. SQLite's progress handler stops it after SEARCH_BUDGET and the
// results found by then are the answer. `more` is set so that the client can
// continue from the last result.

// The time budget of a search, short enough to fit within a slow iteration
// of the main loop (SLOW_TURN) while leaving room for the rest of it.
SEARCH_BUDGET :: 4 * time.Millisecond

// fts_query converts a search as typed by the user into an FTS5 query
// (allocated with the temp allocator) and the username after from:, if there
// is one. `ok` is false if there is no word to search for.
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
			// A phrase, up to its closing quote or the end of the text.
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

// msg_search answers a Msg_Search with a page of the matching messages, newest first.
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
			// There is no such account, so there are no results.
			out: [8 + proto.HISTORY_HEADER_SIZE]u8
			empty, _ := proto.encode_search_answer(out[:], 0, 0, nil)
			respond(u, id, .Ok, empty)
			return
		}
		sender = acc.id
	}
	before := req.before if req.before != 0 else max(proto.Msg_Id)
	me := u.account.id

	// Two result lists, one for the message words and one for the file
	// names, each sorted newest first.
	qs := [2]^sqlite.Stmt{db_stmt(&s.db, .Msg_Search), db_stmt(&s.db, .File_Search)}
	for q in qs {
		db_bind_text(q, 1, query)
		db_bind_int(q, 2, i64(min(before, proto.Msg_Id(max(i64)))))
	}
	// The next message of each list: its id, 0 once the list has run out,
	// or -1 if the list still has to be advanced.
	heads := [2]i64{-1, -1}

	// Stop the search once it has used up its share of the main loop.
	deadline := time.tick_add(time.tick_now(), SEARCH_BUDGET)
	sqlite.progress_handler(s.db.conn, 1000, proc "c" (arg: rawptr) -> c.int {
			return 1 if time.tick_diff(time.tick_now(), (^time.Tick)(arg)^) < 0 else 0
		}, &deadline)
	defer sqlite.progress_handler(s.db.conn, 0, nil, nil)

	// All matches are visited newest first, and only those in the
	// conversations the asker is searching (and may see) are kept. The
	// oldest message looked at is where the search got to, and the next
	// search continues from there.
	found := make([dynamic]proto.Message, 0, req.limit, context.temp_allocator)
	more: u8
	searched_to := before
	for {
		rc: c.int = sqlite.ROW
		for &head, i in heads {
			if head != -1 {
				continue
			}
			step := sqlite.step(qs[i])
			switch step {
			case sqlite.ROW:
				head = db_col_int(qs[i], 0)
			case sqlite.DONE:
				head = 0
			case:
				rc = step
			}
		}
		if rc == sqlite.ROW && heads == {0, 0} {
			rc = sqlite.DONE
		}
		if rc == sqlite.ROW {
			// Take the newer of the two heads. A message that is in both
			// lists is only taken once.
			pick := 0 if heads[0] >= heads[1] else 1
			if heads[0] == heads[1] {
				heads[1] = -1
			}
			q := qs[pick]
			heads[pick] = -1
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
			// Out of time. Return what was found so far. There may be more
			// results older than where the search got to.
			more = proto.MORE_BEFORE
			log.debugf(
				"%s's search stopped after %d, at message %d",
				conn_label(u),
				len(found),
				searched_to,
			)
		case:
			// FTS5 rejected the query. This shouldn't happen for any typed text.
			log.warnf("search for %q: %s", query, db_error(&s.db))
			for q in qs {
				sqlite.reset(q)
			}
			respond(u, id, .Invalid)
			return
		}
		break
	}
	for q in qs {
		sqlite.reset(q)
	}
	for &m in found {
		attach_reactions(s, &m, me)
		attach_files(s, &m)
	}
	out := make([]u8, proto.MAX_BODY_SIZE, context.temp_allocator)
	page, fitted := proto.encode_search_answer(out, searched_to, more, found[:])
	if fitted < len(found) {
		// Not all results fit, so the next search continues from the last one that did.
		page, _ = proto.encode_search_answer(
			out,
			found[fitted - 1].id,
			proto.MORE_BEFORE,
			found[:fitted],
		)
	}
	respond(u, id, .Ok, page)
}

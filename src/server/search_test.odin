package server

import "core:os"
import "core:testing"

import "common:proto"

// Tests of searching (search.odin), on the Test_Server of auth_test.odin.

@(private = "file")
search :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	conv: proto.Conv_Id,
	query: string,
	before: proto.Msg_Id = 0,
	limit := 20,
) -> (
	status: proto.Status,
	ids: [dynamic]proto.Msg_Id,
	more: bool,
	searched_to: proto.Msg_Id,
) {
	buf: [proto.MSG_SEARCH_MAX_SIZE]u8
	body: []u8
	status, body = ts_ask(t, ts, u, .Msg_Search, proto.encode_msg_search(&buf, {conv = conv, before = before, limit = limit, query = query}))
	ids = make([dynamic]proto.Msg_Id, context.temp_allocator)
	if status != .Ok {
		return
	}
	msgs := make([]proto.Message, proto.MAX_SEARCH_LIMIT + 1, context.temp_allocator)
	to, flags, got, ok := proto.decode_search_answer(body, msgs)
	testing.expect(t, ok)
	for m in got {
		append(&ids, m.id)
	}
	return status, ids, flags & proto.MORE_BEFORE != 0, to
}

@(test)
test_fts_query :: proc(t: ^testing.T) {
	Case :: struct {
		typed, query, from: string,
		ok:                 bool,
	}
	for c in ([]Case {
			{"hello world", `"hello" "world"`, "", true},
			{`say "good morning" now`, `"say" "good morning" "now"`, "", true},
			{"walk* from:Alice", `"walk"`, "Alice", true},
			{`AND OR NOT ( ) "`, `"AND" "OR" "NOT"`, "", true},
			{`quo"te`, `"quote"`, "", true},
			{"  ... !!! ", "", "", false},
			{"from:alice", "", "alice", false},
		}) {
		query, from, ok := fts_query(c.typed)
		testing.expectf(t, ok == c.ok && query == c.query && from == c.from, "%q: got %q %q %v", c.typed, query, from, ok)
	}
}

@(test)
test_search :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "yap-test-*", context.temp_allocator)
	defer os.remove_all(dir)
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	testing.expect(t, blob_store_open(&s.blobs, &s.db, dir))
	home := s.convs.home.id
	gaming := conv_by_name(&s.convs, "Gaming")
	ts_account(t, &ts, "admin", "a password", {.Owner})
	alice_acc := ts_account(t, &ts, "alice", "a password")
	ts_account(t, &ts, "bob", "a password")
	admin := logged_in(t, &ts, "admin")
	alice := logged_in(t, &ts, "alice")
	bob := logged_in(t, &ts, "bob")
	testing.expect(t, conv_member_add(&s.convs, gaming, alice_acc.id))

	_, coffee := post(t, &ts, alice, home, "Let's meet at the Café tomorrow", 1)
	_, walking := post(t, &ts, bob, home, "I was walking the dog", 2)
	_, morning := post(t, &ts, bob, home, "good morning everyone", 3)
	_, mixed := post(t, &ts, alice, home, "morning is good", 4)
	_, secret := post(t, &ts, alice, gaming.id, "the secret cafe plan", 5)

	// Words, whatever their case and accents; in the channel asked about.
	status, ids, _, _ := search(t, &ts, bob, home, "CAFE")
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect(t, len(ids) == 1 && ids[0] == coffee)
	// Whole words only (no prefixes); a phrase, the words in a row;
	// every word.
	_, ids, _, _ = search(t, &ts, bob, home, "walk*")
	testing.expect_value(t, len(ids), 0)
	_, ids, _, _ = search(t, &ts, bob, home, "walking")
	testing.expect(t, len(ids) == 1 && ids[0] == walking)
	_, ids, _, _ = search(t, &ts, bob, home, `"good morning"`)
	testing.expect(t, len(ids) == 1 && ids[0] == morning)
	_, ids, _, _ = search(t, &ts, bob, home, "morning good")
	testing.expect_value(t, len(ids), 2)
	// Newest first.
	testing.expect(t, len(ids) == 2 && ids[0] == mixed && ids[1] == morning)
	// From someone.
	_, ids, _, _ = search(t, &ts, bob, home, "morning from:alice")
	testing.expect(t, len(ids) == 1 && ids[0] == mixed)
	_, ids, _, _ = search(t, &ts, bob, home, "morning from:nobody")
	testing.expect_value(t, len(ids), 0)

	// Everywhere one is: alice finds Gaming's too, bob doesn't, and bob
	// can't search Gaming at all.
	_, ids, _, _ = search(t, &ts, alice, 0, "cafe")
	testing.expect_value(t, len(ids), 2)
	testing.expect(t, len(ids) == 2 && ids[0] == secret)
	_, ids, _, _ = search(t, &ts, bob, 0, "cafe")
	testing.expect(t, len(ids) == 1 && ids[0] == coffee)
	status, _, _, _ = search(t, &ts, bob, gaming.id, "cafe")
	testing.expect(t, status != .Ok)

	// Nothing to look for.
	status, _, _, _ = search(t, &ts, bob, home, "!!!")
	testing.expect_value(t, status, proto.Status.Invalid)

	// A page at a time, older than the last.
	more: bool
	to: proto.Msg_Id
	_, ids, more, to = search(t, &ts, bob, home, "morning", limit = 1)
	testing.expect(t, more && len(ids) == 1 && ids[0] == mixed && to == mixed)
	_, ids, more, _ = search(t, &ts, bob, home, "morning", before = to, limit = 1)
	testing.expect(t, !more && len(ids) == 1 && ids[0] == morning)

	// Edited: found by what it says now. Deleted: not found.
	testing.expect_value(t, edit_as(t, &ts, bob, walking, "I was running"), proto.Status.Ok)
	_, ids, _, _ = search(t, &ts, bob, home, "walking")
	testing.expect_value(t, len(ids), 0)
	_, ids, _, _ = search(t, &ts, bob, home, "running")
	testing.expect(t, len(ids) == 1 && ids[0] == walking)
	testing.expect_value(t, delete_as(t, &ts, alice, mixed), proto.Status.Ok)
	_, ids, _, _ = search(t, &ts, bob, home, "morning")
	testing.expect(t, len(ids) == 1 && ids[0] == morning)

	// Purged: gone from the index too.
	testing.expect(t, db_exec(&s.db, "UPDATE messages SET time = 1"))
	buf: [proto.PURGE_SIZE]u8
	ts.requests += 1
	rpc_handle(s, admin, proto.encode_request(ts.requests, .Purge, proto.encode_purge(&buf, {conv = home, before = proto.Unix_Ms(unix_ms())})))
	retention_drain(&s.retention, &s.blobs, s)
	_, ids, _, _ = search(t, &ts, bob, home, "running")
	testing.expect_value(t, len(ids), 0)
	n, _ := db_pragma_int(&s.db, "SELECT count(*) FROM messages_fts WHERE messages_fts MATCH 'morning'")
	testing.expect_value(t, n, 0)
}

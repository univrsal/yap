package server

import "core:fmt"
import "core:os"
import "core:testing"

import "common:proto"

// Tests of conversations and voice rooms, on the Test_Server of
// auth_test.odin.

// logged_in is a new connection of an account with the password "a
// password", logged in, with what it was told on logging in taken.
logged_in :: proc(t: ^testing.T, ts: ^Test_Server, username: string) -> ^Conn {
	u := ts_connect(ts)
	status, _ := ts_login(t, ts, u, username, "a password")
	testing.expect_value(t, status, proto.Status.Ok)
	ts_events(t, ts, u)
	return u
}

@(private = "file")
conv_id_body :: proc(conv: proto.Conv_Id) -> []u8 {
	buf := new([4]u8, context.temp_allocator)
	return proto.encode_conv_id(buf, conv)
}

@(private = "file")
room_body :: proc(room: proto.Room) -> []u8 {
	buf := new([4]u8, context.temp_allocator)
	return proto.encode_room(buf, room)
}

@(private = "file")
subscribe_body :: proc(conv: proto.Conv_Id, on: bool) -> []u8 {
	buf := new([proto.CONV_SUBSCRIBE_SIZE]u8, context.temp_allocator)
	return proto.encode_conv_subscribe(buf, conv, on)
}

@(private = "file")
browse :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn) -> []proto.Conv {
	status, body := ts_ask(t, ts, u, .Conv_Browse)
	testing.expect_value(t, status, proto.Status.Ok)
	buf := make([]proto.Conv, proto.MAX_BROWSE_LIMIT, context.temp_allocator)
	_, convs, ok := proto.decode_browse_page(body, buf)
	testing.expect(t, ok)
	return convs
}

@(test)
test_convs_seeded_once :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "yap-test-*", context.temp_allocator)
	defer os.remove_all(dir)
	path, _ := os.join_path({dir, DB_FILE}, context.temp_allocator)

	gaming: proto.Conv_Id
	{
		// A new database takes the config's channels, the first as home.
		ts: Test_Server
		ts_open(t, &ts, path)
		defer ts_close(&ts)
		c := &ts.s.convs
		testing.expect_value(t, len(c.by_id), 2)
		testing.expect(t, c.home != nil && c.home.name == "Lobby")
		testing.expect_value(t, c.home.flags, proto.Conv_Flags{.Home})
		sorted := convs_sorted(c)
		testing.expect_value(t, sorted[0].name, "Lobby")
		testing.expect_value(t, sorted[1].name, "Gaming")
		testing.expect(t, conv_by_name(c, "gaming") == sorted[1])
		testing.expect(t, conv_by_name(c, "nothing") == nil)
		gaming = sorted[1].id

		// An account is in the home channel, and in what it subscribes to.
		alice := ts_account(t, &ts, "alice", "a password")
		testing.expect(t, conv_is_member(c.home, alice.id))
		testing.expect(t, !conv_is_member(sorted[1], alice.id))
		testing.expect(t, conv_member_add(c, sorted[1], alice.id))
		testing.expect(t, conv_member_add(c, sorted[1], alice.id)) // again is nothing
		testing.expect_value(t, len(sorted[1].members), 1)
		testing.expect(t, !conv_member_remove(c, c.home, 999))
		db_commit(&ts.s.db)
	}

	// Opened again, the channels are the database's: what the config
	// says by then isn't looked at, and who was in what still is.
	db: DB
	testing.expect(t, db_open(&db, path))
	defer db_close(&db)
	a: Accounts
	testing.expect(t, accounts_load(&a, &db))
	defer accounts_destroy(&a)
	c: Convs
	testing.expect(t, convs_load(&c, &db, []string{"Other", "Names"}, &a))
	defer convs_destroy(&c)
	testing.expect_value(t, len(c.by_id), 2)
	testing.expect_value(t, c.home.name, "Lobby")
	alice := account_find(&a, "alice")
	testing.expect(t, conv_is_member(c.home, alice.id))
	testing.expect(t, conv_is_member(conv_by_id(&c, gaming), alice.id))
}

@(test)
test_home_for_accounts_without :: proc(t: ^testing.T) {
	// An account made where there were no channels to be in (before
	// there were any, or from the command line) is put in the home
	// channel when the server next starts.
	db: DB
	testing.expect(t, db_open(&db, DB_MEMORY))
	defer db_close(&db)
	a: Accounts
	testing.expect(t, accounts_load(&a, &db))
	defer accounts_destroy(&a)
	p := password_of("a password")
	secret, _ := secret_make(&p, HASH_PARAMS_TEST)
	acc := account_add(&a, "early", "Early", secret, {})
	testing.expect(t, acc != nil)

	c: Convs
	testing.expect(t, convs_load(&c, &db, TEST_CHANNELS, &a))
	defer convs_destroy(&c)
	testing.expect(t, conv_is_member(c.home, acc.id))
}

@(test)
test_subscribe :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	ts_account(t, &ts, "alice", "a password")
	laptop := logged_in(t, &ts, "alice")
	phone := logged_in(t, &ts, "alice")
	gaming := conv_by_name(&s.convs, "Gaming")

	// What there is to subscribe to: the channels one isn't in.
	found := browse(t, &ts, laptop)
	testing.expect_value(t, len(found), 1)
	testing.expect_value(t, found[0].id, gaming.id)
	testing.expect(t, !found[0].member)

	// Subscribing on one device shows on the other.
	status, _ := ts_ask(t, &ts, laptop, .Conv_Subscribe, subscribe_body(gaming.id, true))
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect(t, conv_is_member(gaming, laptop.account.id))
	for u in ([]^Conn{laptop, phone}) {
		e, told := has_event(ts_events(t, &ts, u), .Conv_Changed)
		testing.expect(t, told)
		conv, _ := proto.decode_conv(e.body)
		testing.expect_value(t, conv.name, "Gaming")
		testing.expect(t, conv.member)
	}
	testing.expect_value(t, len(browse(t, &ts, laptop)), 0)
	// Again changes nothing, and is no news.
	status, _ = ts_ask(t, &ts, laptop, .Conv_Subscribe, subscribe_body(gaming.id, true))
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, len(ts_events(t, &ts, phone)), 0)
	testing.expect_value(t, len(gaming.members), 1)

	// A device that connects later is told of both its channels.
	tablet := ts_connect(&ts)
	status, _ = ts_login(t, &ts, tablet, "alice", "a password")
	testing.expect_value(t, status, proto.Status.Ok)
	names := make([dynamic]string, context.temp_allocator)
	for e in ts_events(t, &ts, tablet) {
		if e.op == .Conv_Changed {
			conv, _ := proto.decode_conv(e.body)
			append(&names, conv.name)
		}
	}
	testing.expect_value(t, len(names), 2)
	testing.expect_value(t, names[0], "Lobby")
	testing.expect_value(t, names[1], "Gaming")

	// Reading a channel takes being in it; leaving it ends the reading.
	status, _ = ts_ask(t, &ts, phone, .Msg_History, history_body(gaming.id))
	testing.expect_value(t, status, proto.Status.Ok)
	status, _ = ts_ask(t, &ts, laptop, .Conv_Subscribe, subscribe_body(gaming.id, false))
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect(t, !conv_is_member(gaming, laptop.account.id))
	e, told := has_event(ts_events(t, &ts, phone), .Conv_Removed)
	testing.expect(t, told)
	gone, _ := proto.decode_conv_id(e.body)
	testing.expect_value(t, gone, gaming.id)
	status, _ = ts_ask(t, &ts, phone, .Msg_History, history_body(gaming.id))
	testing.expect_value(t, status, proto.Status.Denied)

	// Nobody leaves the home channel, or joins one that isn't there.
	status, _ = ts_ask(t, &ts, laptop, .Conv_Subscribe, subscribe_body(s.convs.home.id, false))
	testing.expect_value(t, status, proto.Status.Denied)
	testing.expect(t, conv_is_member(s.convs.home, laptop.account.id))
	status, _ = ts_ask(t, &ts, laptop, .Conv_Subscribe, subscribe_body(999, true))
	testing.expect_value(t, status, proto.Status.Not_Found)
	status, _ = ts_ask(t, &ts, laptop, .Conv_Subscribe, []u8{1})
	testing.expect_value(t, status, proto.Status.Invalid)
}

@(test)
test_conv_create :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	ts_account(t, &ts, "admin", "a password", {.Owner})
	ts_account(t, &ts, "alice", "a password")
	admin := logged_in(t, &ts, "admin")
	alice := logged_in(t, &ts, "alice")

	buf: [proto.CONV_CREATE_MAX_SIZE]u8
	// Only who may makes channels, and only ones that could be.
	status, _ := ts_ask(
		t,
		&ts,
		alice,
		.Conv_Create,
		proto.encode_conv_create(buf[:], "Music", "", false),
	)
	testing.expect_value(t, status, proto.Status.Denied)
	status, _ = ts_ask(
		t,
		&ts,
		admin,
		.Conv_Create,
		proto.encode_conv_create(buf[:], " \t ", "", false),
	)
	testing.expect_value(t, status, proto.Status.Invalid)
	status, _ = ts_ask(
		t,
		&ts,
		admin,
		.Conv_Create,
		proto.encode_conv_create(buf[:], "GAMING", "", false),
	)
	testing.expect_value(t, status, proto.Status.Conflict)
	testing.expect_value(t, len(s.convs.by_id), 2)

	body: []u8
	status, body = ts_ask(
		t,
		&ts,
		admin,
		.Conv_Create,
		proto.encode_conv_create(buf[:], "  Music\n", "what we're\tlistening to", false),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	id, ok := proto.decode_conv_id(body)
	testing.expect(t, ok)
	music := conv_by_id(&s.convs, id)
	testing.expect(t, music != nil)
	testing.expect_value(t, music.name, "Music")
	testing.expect_value(t, music.topic, "what we're listening to")
	testing.expect_value(t, music.created_by, admin.account.id)

	// Whoever made it is in it and told so; the others find it when
	// they look for channels.
	testing.expect(t, conv_is_member(music, admin.account.id))
	_, told := has_event(ts_events(t, &ts, admin), .Conv_Changed)
	testing.expect(t, told)
	testing.expect_value(t, len(ts_events(t, &ts, alice)), 0)
	found := browse(t, &ts, alice)
	testing.expect_value(t, len(found), 2)
	testing.expect_value(t, found[1].name, "Music")
	testing.expect_value(t, found[1].topic, "what we're listening to")

	// Who is in a channel can be asked about any channel one may see.
	accounts_buf: [8]proto.Account_Id
	status, body = ts_ask(t, &ts, alice, .Conv_Members, conv_id_body(music.id))
	testing.expect_value(t, status, proto.Status.Ok)
	members, members_ok := proto.decode_conv_members(body, accounts_buf[:])
	testing.expect(t, members_ok)
	testing.expect_value(t, len(members), 1)
	testing.expect_value(t, members[0], admin.account.id)
	status, body = ts_ask(t, &ts, alice, .Conv_Members, conv_id_body(s.convs.home.id))
	members, _ = proto.decode_conv_members(body, accounts_buf[:])
	testing.expect_value(t, len(members), 2)
	status, _ = ts_ask(t, &ts, alice, .Conv_Members, conv_id_body(999))
	testing.expect_value(t, status, proto.Status.Not_Found)
}

@(test)
test_voice_rooms :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	ts_account(t, &ts, "alice", "a password")
	ts_account(t, &ts, "bob", "a password")
	laptop := logged_in(t, &ts, "alice")
	phone := logged_in(t, &ts, "alice")
	bob := logged_in(t, &ts, "bob")
	home := proto.Room(s.convs.home.id)
	gaming := proto.Room(conv_by_name(&s.convs, "Gaming").id)

	// Nobody is put in a room for connecting.
	testing.expect_value(t, laptop.room, 0)
	testing.expect_value(t, bob.room, 0)

	// A room is joined by asking, and everyone gets to see who's in it.
	version := s.version
	status, _ := ts_ask(t, &ts, laptop, .Voice_Join, room_body(home))
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, laptop.room, home)
	testing.expect(t, s.version != version)
	// A channel's room is open to whoever may see the channel,
	// subscribed or not; looking at it isn't joining it.
	status, _ = ts_ask(t, &ts, bob, .Voice_Join, room_body(gaming))
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, bob.room, gaming)
	status, _ = ts_ask(t, &ts, bob, .Voice_Join, room_body(999))
	testing.expect_value(t, status, proto.Status.Not_Found)
	testing.expect_value(t, bob.room, gaming)

	// An account talks from one device at a time: joining on the phone
	// takes the laptop out, and tells it where its account went.
	status, _ = ts_ask(t, &ts, phone, .Voice_Join, room_body(gaming))
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, phone.room, gaming)
	testing.expect_value(t, laptop.room, 0)
	e, told := has_event(ts_events(t, &ts, laptop), .Voice_Moved)
	testing.expect(t, told)
	moved, _ := proto.decode_room(e.body)
	testing.expect_value(t, moved, gaming)
	// Bob's is his own business.
	testing.expect_value(t, bob.room, gaming)
	_, told = has_event(ts_events(t, &ts, bob), .Voice_Moved)
	testing.expect(t, !told)

	// And leaving is joining nothing.
	status, _ = ts_ask(t, &ts, phone, .Voice_Join, room_body(0))
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, phone.room, 0)
	// Logging out leaves the room too.
	conn_logout(s, bob)
	testing.expect_value(t, bob.room, 0)
}

// browse_page asks for a page of channels to subscribe to.
@(private = "file")
browse_page :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	b: proto.Browse,
) -> (
	status: proto.Status,
	more: bool,
	convs: []proto.Conv,
) {
	req := new([proto.CONV_BROWSE_MAX_SIZE]u8, context.temp_allocator)
	body: []u8
	status, body = ts_ask(t, ts, u, .Conv_Browse, proto.encode_conv_browse(req, b))
	if status != .Ok {
		return
	}
	buf := make([]proto.Conv, proto.MAX_BROWSE_LIMIT, context.temp_allocator)
	ok: bool
	more, convs, ok = proto.decode_browse_page(body, buf)
	testing.expect(t, ok)
	return
}

@(test)
test_browse_search :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	owner := ts_account(t, &ts, "owner", "a password", {.Owner})
	ts_account(t, &ts, "alice", "a password")
	alice := logged_in(t, &ts, "alice")
	// Lobby and Gaming, and 130 more: every tenth about music.
	for i in 0 ..< 130 {
		topic := "all about music" if i % 10 == 0 else ""
		testing.expect(
			t,
			conv_add(&s.convs, fmt.tprintf("room-%03d", i), topic, {}, owner.id) != nil,
		)
	}
	testing.expect(t, conv_add(&s.convs, "Gamers Corner", "", {}, owner.id) != nil)

	// All of them, a page at a time, and the last says there are no more.
	seen := 0
	for offset := 0;; offset += proto.BROWSE_PAGE {
		status, more, convs := browse_page(
			t,
			&ts,
			alice,
			{offset = offset, limit = proto.BROWSE_PAGE},
		)
		testing.expect_value(t, status, proto.Status.Ok)
		seen += len(convs)
		if !more {
			break
		}
		testing.expect_value(t, len(convs), proto.BROWSE_PAGE)
	}
	// Not Lobby, which alice is in.
	testing.expect_value(t, seen, 1 + 130 + 1)

	// By name, ignoring case; by topic.
	_, more, convs := browse_page(t, &ts, alice, {query = "GAM", limit = 10})
	testing.expect(t, !more)
	testing.expect_value(t, len(convs), 2) // Gaming, Gamers Corner
	_, more, convs = browse_page(t, &ts, alice, {query = "music", limit = 10})
	testing.expect(t, more)
	testing.expect_value(t, len(convs), 10)
	_, more, convs = browse_page(t, &ts, alice, {query = "music", offset = 10, limit = 10})
	testing.expect(t, !more)
	testing.expect_value(t, len(convs), 3)
	_, _, convs = browse_page(t, &ts, alice, {query = "nothing like it", limit = 10})
	testing.expect_value(t, len(convs), 0)

	// Too many asked for at once.
	req: [proto.CONV_BROWSE_MAX_SIZE]u8
	body := proto.encode_conv_browse(&req, {limit = 1})
	body[len(body) - 2] = proto.MAX_BROWSE_LIMIT + 1
	status, _ := ts_ask(t, &ts, alice, .Conv_Browse, body)
	testing.expect_value(t, status, proto.Status.Invalid)
}

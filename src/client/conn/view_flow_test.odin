#+build !wasi
package conn

import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

import "common:proto"

// Tests of what the UI is shown (view.odin): the channels, DMs and who is in
// which room, the connection's status, the server's details, what a new
// connection or a logout clears, who is speaking, and the log lines.

@(private = "file")
open_view :: proc(tc: ^Test_Conn) -> ^View {
	tc_open(tc)
	tc.c.auth.me = 1
	tc.c.auth.state = .Done
	tc_account(tc, 1, "bob", "Bob")
	tc_account(tc, 2, "alice", "Alice")
	tc_account(tc, 3, "carol", "Carol")
	return tc_view(tc)
}

// people_again tells the client who everyone is, as a sync does after it begins.
@(private = "file")
people_again :: proc(tc: ^Test_Conn) {
	tc_account(tc, 1, "bob", "Bob")
	tc_account(tc, 2, "alice", "Alice")
	tc_account(tc, 3, "carol", "Carol")
}

@(private = "file")
conv_record :: proc(id: proto.Conv_Id, name: string, flags := proto.Conv_Flags{}) -> proto.Conv {
	return {id = id, kind = .Channel, name = name, member = true, flags = flags, rights = proto.CONV_RIGHTS_ALL}
}

@(private = "file")
told :: proc(tc: ^Test_Conn, record: proto.Conv) {
	buf := make([]u8, 1024, context.temp_allocator)
	tc_event(tc, .Conv_Changed, proto.encode_conv(buf, record))
}

@(test)
test_channels_and_dms_are_shown :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_view(&tc)
	defer tc_close(&tc)
	defer view_reset(v)
	c := &tc.c

	tc_event(&tc, .Sync_Begin)
	people_again(&tc)
	late := conv_record(12, "Zebra")
	late.position = 2
	early := conv_record(11, "Apple")
	early.position = 1
	lobby := conv_record(10, "Lobby", {.Home, .Private})
	lobby.unread, lobby.mentions, lobby.notify, lobby.admin = 4, 1, .Mentions, true
	text_only := conv_record(13, "Notes", {.Text_Only})
	text_only.rights = {.See, .Write}
	told(&tc, late)
	told(&tc, early)
	told(&tc, lobby)
	told(&tc, text_only)
	dm := proto.Conv {
		id            = 20,
		kind          = .DM,
		member        = true,
		account_count = 2,
		last          = 9,
		unread        = 2,
		notify        = .None,
	}
	dm.accounts[0], dm.accounts[1] = 1, 2
	told(&tc, dm)
	group := proto.Conv {
		id            = 21,
		kind          = .Group,
		member        = true,
		account_count = 3,
	}
	group.accounts[0], group.accounts[1], group.accounts[2] = 1, 2, 3
	told(&tc, group)
	tc_event(&tc, .Sync_End)

	// Channels in the order lists show them, with what is unread and what we may do.
	testing.expect_value(t, len(v.channels), 4)
	if len(v.channels) == 4 {
		testing.expect_value(t, v.channels[0].name, "Lobby")
		testing.expect(t, v.channels[0].home && v.channels[0].private && v.channels[0].admin)
		testing.expect_value(t, v.channels[0].unread, 4)
		testing.expect_value(t, v.channels[0].mentions, 1)
		testing.expect_value(t, v.channels[0].notify, proto.Notify_Level.Mentions)
		// (then by position, and by id for the same position)
		testing.expect_value(t, v.channels[1].name, "Notes")
		testing.expect_value(t, v.channels[2].name, "Apple")
		testing.expect_value(t, v.channels[3].name, "Zebra")
		testing.expect(t, .Voice not_in v.channels[1].rights)
		testing.expect(t, .Text_Only in v.channels[1].flags)
	}
	// DMs and groups are listed apart, with whom they are with.
	testing.expect_value(t, len(v.dms), 2)
	for &d in v.dms {
		switch d.id {
		case 20:
			testing.expect_value(t, d.with, proto.Account_Id(2))
			testing.expect_value(t, len(group_members(&d)), 0)
			testing.expect_value(t, d.unread, 2)
			testing.expect_value(t, d.notify, proto.Notify_Level.None)
		case 21:
			testing.expect_value(t, d.with, proto.Account_Id(0))
			others := group_members(&d)
			testing.expect_value(t, len(others), 2)
			if len(others) == 2 {
				testing.expect_value(t, others[0], proto.Account_Id(2))
				testing.expect_value(t, others[1], proto.Account_Id(3))
			}
		case:
			testing.expectf(t, false, "an unexpected DM %d", d.id)
		}
	}
	testing.expect_value(t, v.my_name, "Bob")
	testing.expect_value(t, v.viewing, c.convs.viewing)

	// Publishing again replaces everything instead of adding to it.
	publish_channels(c)
	testing.expect_value(t, len(v.channels), 4)
	testing.expect_value(t, len(v.dms), 2)
}

@(test)
test_the_voice_rooms_are_shown :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_view(&tc)
	defer tc_close(&tc)
	defer view_reset(v)
	c := &tc.c
	tc_event(&tc, .Sync_Begin)
	people_again(&tc)
	lobby := conv_record(10, "Lobby", {.Home})
	quiet := conv_record(11, "Quiet")
	quiet.rights = {.See, .Write, .Voice} // may join, not speak
	told(&tc, lobby)
	told(&tc, quiet)
	tc_event(&tc, .Sync_End)

	tc_snapshot(
		&tc,
		1,
		11,
		{
			{num = 11, account = 1, room = 11, flags = {.Muted, .In_Voice}},
			{num = 12, account = 2, room = 10, flags = {.Sharing, .Camera}},
			{num = 13, account = 3, room = 0},
		},
	)
	testing.expect_value(t, v.my_num, proto.User_Num(11))
	testing.expect_value(t, v.my_room, proto.Conv_Id(11))
	testing.expect(t, !v.may_speak, "may speak in a room where the rights say not")
	testing.expect(t, !v.may_video)
	testing.expect_value(t, len(v.users), 3)
	testing.expect_value(t, v.users[11].name, "Bob")
	testing.expect(t, v.users[11].muted && v.users[11].in_voice && !v.users[11].deafened)
	testing.expect(t, v.users[12].sharing && v.users[12].camera)
	testing.expect_value(t, v.users[12].room, proto.Room(10))
	testing.expect_value(t, v.users[13].room, proto.Room(0))

	// Who is in each channel's room, and what a user named is the account's display name.
	for ch in v.channels {
		switch ch.id {
		case 10:
			testing.expect_value(t, len(ch.members), 1)
		case 11:
			testing.expect_value(t, len(ch.members), 1)
		}
	}

	// A room we were moved into by a moderator is named from what they told us.
	c.convs.guest_room, c.convs.guest_name = 9, strings.clone("Secret")
	tc_snapshot(&tc, 2, 11, {{num = 11, account = 1, room = 9}})
	testing.expect_value(t, v.guest_name, "Secret")
	tc_snapshot(&tc, 3, 11, {{num = 11, account = 1, room = 10}})
	testing.expect_value(t, v.guest_name, "")
	testing.expect(t, v.may_speak && v.may_video)
	// A guest room we are not in is not ours to show.
	c.convs.guest_room, c.convs.guest_name = 9, strings.clone("Secret")
	publish_channels(c)
	testing.expect_value(t, v.guest_name, "")
}

// ---- the connection's state ----

@(test)
test_status_is_shown :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_view(&tc)
	defer tc_close(&tc)
	c := &tc.c
	c.server_addr = strings.clone("chat.example.org:7777")
	defer delete(c.server_addr)
	defer view_reset(v)

	publish_status(c, .Connecting)
	testing.expect_value(t, v.status, Status.Connecting)
	testing.expect_value(t, v.server, "chat.example.org:7777")
	publish_status(c, .Failed, "no route to host")
	testing.expect_value(t, v.status, Status.Failed)
	testing.expect_value(t, v.error, "no route to host")
	publish_status(c, .Connecting)
	testing.expect_value(t, v.error, "")
	// The address is taken once.
	c.server_addr = "elsewhere"
	publish_status(c, .Connected)
	testing.expect_value(t, v.server, "chat.example.org:7777")
	c.server_addr = ""
	c.server_addr = strings.clone("chat.example.org:7777")
}

@(test)
test_losing_the_connection_is_told_to_scripts :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_view(&tc)
	defer tc_close(&tc)
	c := &tc.c
	defer view_reset(c.view)

	// Logged in and then disconnected: scripts are told, with why.
	c.status = .Connected
	publish_status(c, .Failed, "timed out")
	events := tc_events(&tc)
	testing.expect_value(t, len(events), 1)
	if len(events) == 1 {
		d, is_disc := events[0].(Event_Disconnected)
		testing.expect(t, is_disc)
		testing.expect_value(t, d.why, "timed out")
	}
	for &e in events {
		event_destroy(&e)
	}

	// Not if we never got as far as logging in, nor if we were not connected.
	c.status = .Connected
	c.auth.state = .Working
	publish_status(c, .Failed, "x")
	c.auth.state = .Done
	c.status = .Connecting
	publish_status(c, .Failed, "x")
	c.status = .Connected
	publish_status(c, .Connected, "")
	testing.expect_value(t, len(tc_events(&tc)), 0)
}

@(test)
test_when_a_new_connection_will_be_tried :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_view(&tc)
	defer tc_close(&tc)
	c := &tc.c
	defer view_reset(v)

	c.lost = false
	publish_retry(c)
	testing.expect(t, !v.retrying)
	testing.expect_value(t, v.retry_at, time.Tick{})

	c.lost = true
	c.retry_at = time.tick_now()
	publish_retry(c)
	testing.expect(t, v.retrying)
	testing.expect(t, v.retry_at != {})
	// While a handshake is going on there is no time to wait for.
	c.handshake.state = .Sent_Init
	publish_retry(c)
	testing.expect(t, v.retrying)
	testing.expect_value(t, v.retry_at, time.Tick{})
}

@(test)
test_the_servers_details_are_copied :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_view(&tc)
	defer tc_close(&tc)
	c := &tc.c
	defer view_reset(v)
	defer delete(c.rpc.server.icon_jpeg)

	s := &c.rpc.server
	s.name = strings.clone("Our Server")
	s.description = strings.clone("for friends")
	s.email = strings.clone("admin@example.org")
	s.max_attachment = 4096
	s.registration = {.Open}
	s.digests, s.push = true, true
	s.push_key[0] = 7
	s.icon = 9
	s.icon_jpeg = make([]u8, 20)
	s.icon_jpeg[0] = 0xff
	publish_server(c)

	testing.expect_value(t, v.server_name, "Our Server")
	testing.expect_value(t, v.server_about, "for friends")
	testing.expect_value(t, v.server_email, "admin@example.org")
	testing.expect_value(t, v.max_attachment, u64(4096))
	testing.expect_value(t, v.registration, proto.Registration_Flags{.Open})
	testing.expect(t, v.server_digests && v.server_push)
	testing.expect_value(t, v.server_push_key[0], u8(7))
	testing.expect_value(t, v.server_icon, proto.Blob_Id(9))
	testing.expect_value(t, len(v.icon_jpeg), 20)
	// The UI has bytes of its own, not the connection's.
	testing.expect(t, raw_data(v.icon_jpeg) != raw_data(s.icon_jpeg))

	// The same picture again isn't copied again; a different one is.
	before := raw_data(v.icon_jpeg)
	publish_server(c)
	testing.expect(t, raw_data(v.icon_jpeg) == before, "the same picture was copied again")
	delete(s.icon_jpeg)
	s.icon = 10
	s.icon_jpeg = make([]u8, 30)
	publish_server(c)
	testing.expect_value(t, len(v.icon_jpeg), 30)
	testing.expect_value(t, v.server_icon, proto.Blob_Id(10))
	// No picture any more.
	delete(s.icon_jpeg)
	s.icon, s.icon_jpeg = 0, nil
	publish_server(c)
	testing.expect_value(t, len(v.icon_jpeg), 0)
	testing.expect_value(t, v.server_icon, proto.Blob_Id(0))
	delete(s.name)
	delete(s.description)
	delete(s.email)
}

@(test)
test_a_changed_server_key_is_shown :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_view(&tc)
	defer tc_close(&tc)
	c := &tc.c
	c.server_addr = strings.clone("chat.example.org")
	defer delete(c.server_addr)
	defer view_reset(v)

	saved, received: [proto.KEY_SIZE]u8
	saved[0], received[0] = 1, 2
	publish_key_change(c, saved, received)
	testing.expect(t, v.key_change.changed)
	testing.expect_value(t, v.key_change.server, "chat.example.org")
	testing.expect_value(t, v.key_change.saved, saved)
	testing.expect_value(t, v.key_change.received, received)
	// A later one replaces it.
	received[0] = 3
	publish_key_change(c, saved, received)
	testing.expect_value(t, v.key_change.received, received)
	view_clear_key_change(v)
	testing.expect(t, !v.key_change.changed)

	c.server_key = {0 = 5}
	publish_server_key(c)
	testing.expect_value(t, v.server_key, c.server_key)
}

// ---- starting over ----

@(test)
test_a_new_connection_clears_what_was_shown :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_view(&tc)
	defer tc_close(&tc)
	c := &tc.c
	tc_event(&tc, .Sync_Begin)
	told(&tc, conv_record(10, "Lobby", {.Home}))
	tc_event(&tc, .Sync_End)
	tc_snapshot(&tc, 1, 11, {{num = 11, account = 1, room = 10}})
	arrive_for_view(&tc)
	v.me, v.permissions = 1, {.Invite}
	v.error = strings.clone("something")
	v.notice.text = strings.clone("a notice")
	v.status = .Connected
	v.viewing = 10

	view_reset(v)
	testing.expect_value(t, len(v.channels), 0)
	testing.expect_value(t, len(v.users), 0)
	testing.expect_value(t, len(v.timelines), 0)
	testing.expect_value(t, len(v.mentioned), 0)
	testing.expect_value(t, v.status, Status.Disconnected)
	testing.expect_value(t, v.error, "")
	testing.expect_value(t, v.notice.text, "")
	testing.expect_value(t, v.me, proto.Account_Id(0))
	testing.expect_value(t, v.permissions, proto.Permissions{})
	testing.expect_value(t, v.viewing, proto.Conv_Id(0))
	testing.expect_value(t, v.my_name, "")
	_ = c
}

@(private = "file")
arrive_for_view :: proc(tc: ^Test_Conn) {
	buf := make([]u8, 1024, context.temp_allocator)
	m := proto.Message {
		id     = 5,
		conv   = 10,
		sender = 2,
		kind   = .Text,
		text   = "hey <@1>",
	}
	tc_event(tc, .Msg_New, proto.encode_message(buf, m))
}

@(test)
test_a_logout_keeps_the_server_but_clears_the_account :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_view(&tc)
	defer tc_close(&tc)
	c := &tc.c
	defer view_reset(v)
	tc_event(&tc, .Sync_Begin)
	told(&tc, conv_record(10, "Lobby", {.Home}))
	tc_event(&tc, .Sync_End)
	v.server = strings.clone("chat.example.org")
	v.server_name = strings.clone("Our Server")
	append(&v.buddies, 2)
	v.last_seen[2] = 100
	v.me, v.permissions, v.my_num = 1, {.Invite}, 11
	v.viewing, v.my_room = 10, 10

	publish_logged_out(c)
	// What the account had is gone ...
	testing.expect_value(t, len(v.channels), 0)
	testing.expect_value(t, len(v.buddies), 0)
	testing.expect_value(t, len(v.last_seen), 0)
	testing.expect_value(t, v.me, proto.Account_Id(0))
	testing.expect_value(t, v.permissions, proto.Permissions{})
	testing.expect_value(t, v.viewing, proto.Conv_Id(0))
	testing.expect_value(t, v.my_num, proto.User_Num(0))
	// ... and the server is still the one we are connected to.
	testing.expect_value(t, v.server, "chat.example.org")
	testing.expect_value(t, v.server_name, "Our Server")
}

// ---- who is speaking ----

var_wakes: i32

@(private = "file")
count_wake :: proc "c" () {
	sync.atomic_add(&var_wakes, 1)
}

@(test)
test_who_is_speaking :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_view(&tc)
	defer tc_close(&tc)
	c := &tc.c
	defer view_reset(v)

	testing.expect(t, !is_speaking(v, 11))
	testing.expect_value(t, speaking_until(v), time.Tick{})

	// Hearing a user starts them speaking, and wakes the UI only then (it
	// wakes itself for when they stop).
	v.wake = count_wake
	before := sync.atomic_load(&var_wakes)
	publish_voice(c, 11)
	testing.expect(t, is_speaking(v, 11))
	testing.expect(t, !is_speaking(v, 12))
	testing.expect_value(t, sync.atomic_load(&var_wakes), before + 1)
	publish_voice(c, 11)
	publish_voice(c, 11)
	testing.expect_value(t, sync.atomic_load(&var_wakes), before + 1)
	publish_voice(c, 12)
	testing.expect_value(t, sync.atomic_load(&var_wakes), before + 2)
	v.wake = nil

	// The one who stops being shown first is the one who spoke first.
	now := time.tick_now()
	v.speaking[11] = time.tick_add(now, -100 * time.Millisecond)
	v.speaking[12] = now
	testing.expect(t, speaking_until(v) == time.tick_add(v.speaking[11], SPEAKING_HOLD))

	// Some time after the last voice they are no longer shown.
	v.speaking[11] = time.tick_add(time.tick_now(), -(SPEAKING_HOLD + time.Millisecond))
	testing.expect(t, !is_speaking(v, 11))
	testing.expect(t, is_speaking(v, 12))
	v.speaking[12] = time.tick_add(time.tick_now(), -(SPEAKING_HOLD + time.Millisecond))
	testing.expect_value(t, speaking_until(v), time.Tick{})
}

@(test)
test_the_mic_level_does_not_wake_the_ui :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_view(&tc)
	defer tc_close(&tc)
	c := &tc.c
	v.wake = count_wake
	before := sync.atomic_load(&var_wakes)
	publish_mic(c, -23.5, true)
	testing.expect_value(t, v.mic_level, f32(-23.5))
	testing.expect(t, v.mic_open)
	testing.expect(t, v.mic_time != {})
	testing.expect_value(t, sync.atomic_load(&var_wakes), before)
	v.wake = nil
}

// ---- transfers and the log ----

@(test)
test_transfer_progress_is_published_at_a_pace :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_view(&tc)
	defer tc_close(&tc)
	c := &tc.c
	defer view_reset(v)

	transfer := File_Transfer {
		id       = 9,
		name     = strings.clone("photo.png"),
		path     = strings.clone("/tmp/photo.png"),
		size     = 1000,
		outgoing = false,
		state    = .Transferring,
		done     = 100,
	}
	defer delete(transfer.name)
	defer delete(transfer.path)
	publish_file(c, &transfer)
	testing.expect_value(t, v.files[9].name, "photo.png")
	testing.expect_value(t, v.files[9].done, u64(100))
	testing.expect_value(t, v.files[9].path, "/tmp/photo.png")

	// Progress is not published more often than the interval, unless it is a change of state.
	transfer.done = 200
	publish_file(c, &transfer)
	testing.expect_value(t, v.files[9].done, u64(100))
	transfer.state = .Done
	publish_file(c, &transfer, force = true)
	testing.expect_value(t, v.files[9].done, u64(200))
	testing.expect_value(t, v.files[9].state, File_State.Done)
	// The UI has copies of the strings.
	testing.expect(t, raw_data(v.files[9].name) != raw_data(transfer.name))
}

@(test)
test_log_lines_are_kept_in_a_bounded_list :: proc(t: ^testing.T) {
	l: Log_Lines
	defer {
		for line in l.lines {
			delete(line.text)
		}
		delete(l.lines)
	}
	log_lines_sink(&l, .Info, "first")
	log_lines_sink(&l, .Warning, "second")
	testing.expect_value(t, len(l.lines), 2)
	testing.expect_value(t, l.total, 2)
	testing.expect(t, l.lines[0].level != l.lines[1].level, "the level was not kept")
	testing.expect_value(t, l.lines[1].text, "second")

	// Past the most, the oldest tenth goes together, and the total keeps counting
	// so that the UI can tell something new arrived.
	for i in 0 ..< MAX_LOG_LINES + 10 {
		log_lines_sink(&l, .Info, "line")
		_ = i
	}
	testing.expect(t, len(l.lines) <= MAX_LOG_LINES)
	testing.expect(t, len(l.lines) > MAX_LOG_LINES - MAX_LOG_LINES / 10 - 1)
	testing.expect_value(t, l.total, MAX_LOG_LINES + 12)
	testing.expect_value(t, l.lines[len(l.lines) - 1].text, "line")
	// The first ones are the ones that went.
	testing.expect(t, l.lines[0].text != "first")
}

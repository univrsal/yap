#+build !wasi
package conn

import "core:strings"
import "core:testing"

import "common:proto"

// Tests of what the server says about itself (server_info.odin): reading it,
// fetching its picture, changing it, and the report of where its memory goes.

@(private = "file")
info_body :: proc(info: proto.Server_Info) -> []u8 {
	buf := make([]u8, proto.SERVER_INFO_MAX_SIZE, context.temp_allocator)
	body, ok := proto.encode_server_info(buf, info)
	if !ok {
		return nil
	}
	return body
}

@(private = "file")
open_info :: proc(tc: ^Test_Conn) -> ^View {
	tc_open(tc)
	return tc_view(tc)
}

@(private = "file")
info_destroy :: proc(tc: ^Test_Conn) {
	// tc_close frees the rest.
	s := &tc.c.rpc.server
	delete(s.icon_jpeg)
	s.icon_jpeg = nil
}

@(test)
test_server_info_is_read :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_info(&tc)
	defer tc_close(&tc)
	c := &tc.c
	key: [proto.PUSH_KEY_SIZE]u8
	for &b, i in key {
		b = u8(i)
	}

	ok := server_info_take(
		c,
		info_body(
			{
				name = "Our Server",
				version = "1.4.0",
				max_attachment = 50_000_000,
				registration = {.Open, .Email},
				email = "Admin@Example.org",
				description = "For friends.",
				digests = true,
				media_port = 7778,
				video_kbit = 12000,
				push_key = key[:],
				max_cameras = 4,
				camera_kbit = 2500,
				demand = true,
			},
		),
	)
	testing.expect(t, ok)
	s := &c.rpc.server
	testing.expect_value(t, s.name, "Our Server")
	testing.expect_value(t, s.version, "1.4.0")
	testing.expect_value(t, s.description, "For friends.")
	testing.expect_value(t, s.max_attachment, u64(50_000_000))
	testing.expect_value(t, s.registration, proto.Registration_Flags{.Open, .Email})
	testing.expect_value(t, s.email, "admin@example.org") // cleaned
	testing.expect(t, s.digests && s.demand && s.push)
	testing.expect_value(t, s.push_key, key)
	testing.expect_value(t, s.media_port, u16(7778))
	testing.expect_value(t, s.video_kbit, u32(12000))
	testing.expect_value(t, s.max_cameras, 4)
	testing.expect_value(t, s.camera_kbit, u32(2500))
	// The limits are shown to the UI too.
	testing.expect_value(t, v.video_limit_kbit, 12000)
	testing.expect_value(t, v.max_cameras, 4)
	testing.expect_value(t, v.camera_limit_kbit, 2500)

	// A second one replaces the first, including what it no longer says.
	ok = server_info_take(c, info_body({name = "Renamed", version = "1.5.0"}))
	testing.expect(t, ok)
	testing.expect_value(t, s.name, "Renamed")
	testing.expect_value(t, s.email, "")
	testing.expect_value(t, s.description, "")
	testing.expect(t, !s.push && !s.digests)
	testing.expect_value(t, s.push_key, [proto.PUSH_KEY_SIZE]u8{})
	testing.expect_value(t, s.media_port, u16(0))
	testing.expect_value(t, v.max_cameras, 0)
}

@(test)
test_server_info_is_cleaned :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_info(&tc)
	defer tc_close(&tc)
	s := &tc.c.rpc.server

	// What the server says is shown to the user, so it may not hold control
	// characters; an email address that isn't one is dropped.
	ok := server_info_take(
		&tc.c,
		info_body(
			{
				name = "Evil\x1b[31m Server\n",
				version = "1.0\x00",
				description = "line one\nline two\x07",
				email = "not an address",
			},
		),
	)
	testing.expect(t, ok)
	testing.expect(t, !strings.contains_any(s.name, "\x1b\n"), "control characters in the name")
	testing.expect(t, !strings.contains_any(s.version, "\x00"))
	testing.expect(t, !strings.contains(s.description, "\x07"))
	testing.expect(t, strings.contains(s.description, "line two"))
	testing.expect_value(t, s.email, "")

	// What can't be read changes nothing.
	before := s.name
	testing.expect(t, !server_info_take(&tc.c, nil))
	testing.expect(t, !server_info_take(&tc.c, []u8{1, 2, 3}))
	testing.expect_value(t, s.name, before)
}

@(test)
test_server_info_event :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_info(&tc)
	defer tc_close(&tc)

	tc_event(&tc, .Server_Info, info_body({name = "Announced", version = "2"}))
	testing.expect_value(t, tc.c.rpc.server.name, "Announced")
	// Other events are not its business.
	testing.expect(t, !server_info_event(&tc.c, .Sync_End, nil))
	testing.expect(
		t,
		server_info_event(&tc.c, .Server_Info, info_body({name = "Again", version = "2"})),
	)
	testing.expect_value(t, tc.c.rpc.server.name, "Again")
	// One that can't be read is still its event, and changes nothing.
	testing.expect(t, server_info_event(&tc.c, .Server_Info, []u8{9}))
	testing.expect_value(t, tc.c.rpc.server.name, "Again")
}

@(test)
test_server_icon_is_fetched_once :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_info(&tc)
	defer tc_close(&tc)
	defer info_destroy(&tc)
	c := &tc.c
	s := &c.rpc.server

	testing.expect(t, server_info_take(c, info_body({name = "S", version = "1", icon = 77})))
	r, ok := tc_one(t, &tc, .Server_Icon)
	testing.expect(t, ok)
	blob, dec := proto.decode_blob_id(r.body)
	testing.expect(t, dec)
	testing.expect_value(t, blob, proto.Blob_Id(77))
	picture := []u8{0xff, 0xd8, 1, 2, 3, 0xff, 0xd9}
	tc_answer(&tc, r.id, .Ok, picture)
	testing.expect_value(t, string(s.icon_jpeg), string(picture))

	// The same picture again (a reconnect, or an unrelated change) is not fetched again.
	testing.expect(t, server_info_take(c, info_body({name = "S2", version = "1", icon = 77})))
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	testing.expect_value(t, string(s.icon_jpeg), string(picture))

	// A different one is, and the old one is let go at once.
	testing.expect(t, server_info_take(c, info_body({name = "S3", version = "1", icon = 78})))
	testing.expect_value(t, len(s.icon_jpeg), 0)
	r, ok = tc_one(t, &tc, .Server_Icon)
	testing.expect(t, ok)

	// Having no picture any more asks for nothing.
	testing.expect(t, server_info_take(c, info_body({name = "S4", version = "1", icon = 0})))
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	testing.expect_value(t, s.icon, proto.Blob_Id(0))
	// ... and the answer to the earlier question is out of date and dropped.
	tc_answer(&tc, r.id, .Ok, picture)
	testing.expect_value(t, len(s.icon_jpeg), 0)
}

@(test)
test_server_icon_answers :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_info(&tc)
	defer tc_close(&tc)
	defer info_destroy(&tc)
	s := &tc.c.rpc.server

	ask :: proc(t: ^testing.T, tc: ^Test_Conn, icon: proto.Blob_Id) -> Test_Request {
		testing.expect(
			t,
			server_info_take(&tc.c, info_body({name = "S", version = "1", icon = icon})),
		)
		r, _ := tc_one(t, tc, .Server_Icon)
		return r
	}
	// A failure, an empty picture and one over the size the protocol allows are not kept.
	r := ask(t, &tc, 1)
	tc_answer(&tc, r.id, .Not_Found)
	testing.expect_value(t, len(s.icon_jpeg), 0)
	r = ask(t, &tc, 2)
	tc_answer(&tc, r.id, .Ok, nil)
	testing.expect_value(t, len(s.icon_jpeg), 0)
	r = ask(t, &tc, 3)
	tc_answer(&tc, r.id, .Ok, make([]u8, proto.MAX_SERVER_ICON_SIZE + 1, context.temp_allocator))
	testing.expect_value(t, len(s.icon_jpeg), 0)
	// One that is as large as is allowed is.
	r = ask(t, &tc, 4)
	tc_answer(&tc, r.id, .Ok, make([]u8, proto.MAX_SERVER_ICON_SIZE, context.temp_allocator))
	testing.expect_value(t, len(s.icon_jpeg), proto.MAX_SERVER_ICON_SIZE)
}

// ---- changing it ----

@(test)
test_server_info_set_without_a_picture :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_info(&tc)
	defer tc_close(&tc)
	defer info_destroy(&tc)
	c := &tc.c
	testing.expect(t, server_info_take(c, info_body({name = "Old", version = "1", icon = 55})))
	_, _ = tc_one(t, &tc, .Server_Icon)

	// The picture stays unless the command says otherwise.
	server_info_set(c, {name = strings.clone("New"), description = strings.clone("About us")})
	r, ok := tc_one(t, &tc, .Server_Info_Set)
	testing.expect(t, ok)
	set, dec := proto.decode_server_info_set(r.body)
	testing.expect(t, dec)
	testing.expect_value(t, set.name, "New")
	testing.expect_value(t, set.description, "About us")
	testing.expect_value(t, set.icon, proto.Blob_Id(55))

	server_info_set(c, {name = strings.clone("New"), remove = true})
	r, _ = tc_one(t, &tc, .Server_Info_Set)
	set, _ = proto.decode_server_info_set(r.body)
	testing.expect_value(t, set.icon, proto.Blob_Id(0))

	// The answers.
	tc_answer(&tc, r.id, .Ok)
	testing.expect_value(t, v.notice.text, "The server details were updated.")
	testing.expect(t, v.notice.ok)
	server_info_set(c, {name = strings.clone("x")})
	r, _ = tc_one(t, &tc, .Server_Info_Set)
	tc_answer(&tc, r.id, .Denied)
	testing.expect_value(t, v.notice.text, status_text(.Denied))
	testing.expect(t, !v.notice.ok)
	count := v.notice.count
	server_info_set(c, {name = strings.clone("x")})
	r, _ = tc_one(t, &tc, .Server_Info_Set)
	tc_restart(&tc)
	testing.expect_value(t, v.notice.count, count)

	// A name or description over the limits is not sent.
	server_info_set(
		c,
		{name = strings.repeat("n", proto.MAX_SERVER_NAME + 1), description = strings.clone("")},
	)
	server_info_set(
		c,
		{
			name = strings.clone(""),
			description = strings.repeat("d", proto.MAX_SERVER_DESCRIPTION + 1),
		},
	)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	testing.expect_value(t, v.notice.text, "The server's name or description is too long.")
}

@(test)
test_server_info_set_with_a_picture :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_info(&tc)
	defer tc_close(&tc)
	defer blobs_destroy(&tc.c)
	c := &tc.c

	image :: proc(size, width, height: int) -> Chat_Image {
		return {jpeg = make([]u8, size), width = width, height = height}
	}
	cmd :: proc(img: Chat_Image) -> Server_Info_Command {
		return {name = strings.clone("N"), description = strings.clone("D"), image = img}
	}
	// A picture that isn't a square within the limits is refused outright.
	server_info_set(c, cmd(image(100, 64, 32)))
	server_info_set(
		c,
		cmd(image(100, proto.MAX_SERVER_ICON_SIDE + 1, proto.MAX_SERVER_ICON_SIDE + 1)),
	)
	server_info_set(c, cmd(image(proto.MAX_SERVER_ICON_SIZE + 1, 64, 64)))
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	testing.expect_value(t, len(c.blobs.pictures), 0)

	// A good one is uploaded first, with the name and description to set after it.
	server_info_set(c, cmd(image(100, 64, 64)))
	server_info_set(
		c,
		cmd(
			image(
				proto.MAX_SERVER_ICON_SIZE,
				proto.MAX_SERVER_ICON_SIDE,
				proto.MAX_SERVER_ICON_SIDE,
			),
		),
	)
	testing.expect_value(t, len(c.blobs.pictures), 2)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	if len(c.blobs.pictures) == 2 {
		p := &c.blobs.pictures[0]
		testing.expect(t, p.server)
		testing.expect_value(t, p.name, "N")
		testing.expect_value(t, p.about, "D")

		// Once it is uploaded, its blob is named in the change.
		p.blob = 900
		server_info_post(c, p)
		r, ok := tc_one(t, &tc, .Server_Info_Set)
		testing.expect(t, ok)
		set, dec := proto.decode_server_info_set(r.body)
		testing.expect(t, dec)
		testing.expect_value(t, set.name, "N")
		testing.expect_value(t, set.icon, proto.Blob_Id(900))
		tag := p.tag
		// The answer finishes that picture and goes on to the next.
		tc_answer(&tc, r.id, .Ok)
		testing.expect_value(t, len(c.blobs.pictures), 1)
		testing.expect(t, len(c.blobs.pictures) == 0 || c.blobs.pictures[0].tag != tag)
	}
}

@(test)
test_server_info_set_picture_answers :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_info(&tc)
	defer tc_close(&tc)
	defer blobs_destroy(&tc.c)
	c := &tc.c

	image :: proc() -> Chat_Image {
		return {jpeg = make([]u8, 100), width = 64, height = 64}
	}
	post :: proc(t: ^testing.T, tc: ^Test_Conn) -> Test_Request {
		server_info_set(
			&tc.c,
			{name = strings.clone("N"), description = strings.clone("D"), image = image()},
		)
		p := &tc.c.blobs.pictures[0]
		p.blob = 900
		p.state = .Put
		server_info_post(&tc.c, p)
		r, _ := tc_one(t, tc, .Server_Info_Set)
		return r
	}

	// The picture has gone from the server: it is uploaded again.
	r := post(t, &tc)
	tc_answer(&tc, r.id, .Not_Found)
	testing.expect_value(t, len(c.blobs.pictures), 1)
	testing.expect_value(t, c.blobs.pictures[0].blob, proto.Blob_Id(0))
	testing.expect_value(t, c.blobs.pictures[0].state, Picture_State.Put)
	c.blobs.pictures[0].asking = false
	picture_done(c)

	// Refused: it is given up on, and the user told.
	r = post(t, &tc)
	tc_answer(&tc, r.id, .Denied)
	testing.expect_value(t, len(c.blobs.pictures), 0)
	testing.expect_value(t, v.notice.text, "The server rejected the new server details.")

	// A lost connection: it is sent again, so it stays queued.
	r = post(t, &tc)
	tc_restart(&tc)
	testing.expect_value(t, len(c.blobs.pictures), 1)
	picture_done(c)

	// An answer for a picture that is no longer at the head is not for it.
	r = post(t, &tc)
	picture_done(c)
	tc_answer(&tc, r.id, .Ok)
	testing.expect_value(t, len(c.blobs.pictures), 0)
}

// ---- memory ----

@(test)
test_server_memory_report :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_info(&tc)
	defer tc_close(&tc)
	defer view_clear_server_memory(v)

	server_memory(&tc.c)
	r, ok := tc_one(t, &tc, .Server_Memory)
	testing.expect(t, ok)
	tc_answer(&tc, r.id, .Ok, transmute([]u8)string("heap\t1 MB\nstack\t2 MB\n"))
	testing.expect_value(t, v.server_memory.report, "heap\t1 MB\nstack\t2 MB\n")
	testing.expect_value(t, v.server_memory.status, proto.Status.Ok)
	testing.expect_value(t, v.server_memory.count, 1)

	// It is shown as text: control characters become spaces, bad UTF-8 a question mark.
	server_memory(&tc.c)
	r, _ = tc_one(t, &tc, .Server_Memory)
	tc_answer(&tc, r.id, .Ok, []u8{'a', 0x1b, '[', '3', '1', 'm', 'b', '\r', 0xff, 'c', '\n'})
	report := v.server_memory.report
	testing.expect(
		t,
		!strings.contains_any(report, "\x1b\r\x00"),
		"control characters in the report",
	)
	testing.expect(t, strings.contains(report, "?"))
	testing.expect(t, strings.has_suffix(report, "c\n"))
	testing.expect_value(t, v.server_memory.count, 2)

	// A refusal clears the report and says why; a lost connection says nothing.
	server_memory(&tc.c)
	r, _ = tc_one(t, &tc, .Server_Memory)
	tc_answer(&tc, r.id, .Denied, transmute([]u8)string("not for you"))
	testing.expect_value(t, v.server_memory.report, "")
	testing.expect_value(t, v.server_memory.status, proto.Status.Denied)
	testing.expect_value(t, v.server_memory.count, 3)
	server_memory(&tc.c)
	_ = tc_sent(t, &tc)
	tc_restart(&tc)
	testing.expect_value(t, v.server_memory.count, 3)
}

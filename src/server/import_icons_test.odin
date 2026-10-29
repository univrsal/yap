package server

import "base:runtime"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:testing"
import "core:thread"

import "common:avatar"
import "common:proto"
import "curl"

// Fetching the pictures that integrations pose with (import_icons.odin), against
// a small web server that this test runs on this machine. A test can't connect
// to the public internet, and this machine's own addresses are what the check
// refuses, so the fetches that succeed are allowed to use them.

@(private = "file")
Web :: struct {
	socket:    net.TCP_Socket,
	requests:  int, // how many to answer
	picture:   []u8,
	seen:      [dynamic]string, // the paths asked for
	// The test's, which the thread uses for what the test frees.
	allocator: runtime.Allocator,
}

@(private = "file")
serve :: proc(data: rawptr) {
	w := (^Web)(data)
	for _ in 0 ..< w.requests {
		client, _, accept_err := net.accept_tcp(w.socket)
		if accept_err != nil {
			return
		}
		buf: [4096]u8
		n, _ := net.recv_tcp(client, buf[:])
		request := string(buf[:max(n, 0)])
		path := ""
		if first, _, _ := strings.partition(request, "\r\n"); strings.has_prefix(first, "GET ") {
			path, _, _ = strings.partition(first[4:], " ")
		}
		append(&w.seen, strings.clone(path, w.allocator))
		body: []u8
		status := "200 OK"
		extra := ""
		switch path {
		case "/ok.png":
			body = w.picture
		case "/redirect":
			status, extra = "302 Found", "Location: /ok.png\r\n"
		case "/missing":
			status = "404 Not Found"
		case "/text":
			body = transmute([]u8)string("not a picture")
		case "/huge":
			body = make([]u8, 2 * 1024 * 1024 + 1000)
		}
		head := fmt.tprintf(
			"HTTP/1.1 %s\r\nContent-Length: %d\r\n%sConnection: close\r\n\r\n",
			status,
			len(body),
			extra,
		)
		net.send_tcp(client, transmute([]u8)head)
		sent := 0
		for sent < len(body) {
			wrote, err := net.send_tcp(client, body[sent:])
			if err != nil || wrote <= 0 {
				break
			}
			sent += wrote
		}
		net.close(client)
	}
}

@(private = "file")
web_start :: proc(
	t: ^testing.T,
	w: ^Web,
	requests: int,
	picture: []u8,
) -> (
	url: string,
	th: ^thread.Thread,
) {
	socket, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	testing.expect(t, err == nil)
	endpoint, _ := net.bound_endpoint(socket)
	w^ = {
		socket    = socket,
		requests  = requests,
		picture   = picture,
		allocator = context.allocator,
	}
	w.seen.allocator = context.allocator
	return fmt.tprintf(
		"http://127.0.0.1:%d",
		endpoint.port,
	), thread.create_and_start_with_data(w, serve)
}

@(private = "file")
web_stop :: proc(w: ^Web, th: ^thread.Thread) {
	thread.join(th)
	thread.destroy(th)
	net.close(w.socket)
	for p in w.seen {
		delete(p)
	}
	delete(w.seen)
}

@(test)
test_icon_fetch :: proc(t: ^testing.T) {
	lib: curl.Lib
	if !curl.load(&lib, "the test") {
		return // no libcurl here, so nothing to try
	}
	h := lib.easy_init()
	defer lib.easy_cleanup(h)
	picture, _ := avatar.to_png(avatar_rgba(24, 24), context.temp_allocator)

	// Without the allowance, this machine's own address is refused, whatever the
	// scheme, and so is anything that isn't a web address.
	_, why := icon_fetch(&lib, h, "http://127.0.0.1:9/x.png", {})
	testing.expect_value(t, why, "not on the public internet")
	_, why = icon_fetch(&lib, h, "http://localhost:9/x.png", {})
	testing.expect_value(t, why, "not on the public internet")
	_, why = icon_fetch(&lib, h, "http://[::1]:9/x.png", {})
	testing.expect_value(t, why, "not on the public internet")
	_, why = icon_fetch(&lib, h, "http://10.1.2.3/x.png", {})
	testing.expect(t, why != "")
	for url in ([]string {
			"file:///etc/passwd",
			"ftp://example.org/x.png",
			"gopher://example.org/",
			"example.org/x.png",
			"",
		}) {
		_, why = icon_fetch(&lib, h, url, {})
		testing.expectf(t, why == "not a web address", "%q: %q", url, why)
	}

	// And with it: a picture, one after a redirect, a missing one, one that is too big.
	web: Web
	base, th := web_start(t, &web, 5, picture)
	defer web_stop(&web, th)
	allowed := Icon_Options {
		allow_private = true,
	}
	data, got_why := icon_fetch(
		&lib,
		h,
		strings.concatenate({base, "/ok.png"}, context.temp_allocator),
		allowed,
	)
	testing.expect_value(t, got_why, "")
	testing.expect(t, string(data) == string(picture))
	data, got_why = icon_fetch(
		&lib,
		h,
		strings.concatenate({base, "/redirect"}, context.temp_allocator),
		allowed,
	)
	testing.expect_value(t, got_why, "")
	testing.expect(t, string(data) == string(picture))
	_, got_why = icon_fetch(
		&lib,
		h,
		strings.concatenate({base, "/missing"}, context.temp_allocator),
		allowed,
	)
	testing.expect_value(t, got_why, "answered 404")
	_, got_why = icon_fetch(
		&lib,
		h,
		strings.concatenate({base, "/huge"}, context.temp_allocator),
		allowed,
	)
	testing.expect_value(t, got_why, "bigger than 2 MB")
}

// avatar_rgba makes the pixels of a plain picture.
@(private = "file")
avatar_rgba :: proc(w, h: int) -> []u8 {
	rgb := make([]u8, w * h * 3, context.temp_allocator)
	for &b, i in rgb {
		b = u8(i * 5)
	}
	jpeg, _ := avatar.encode_jpeg(rgb, w, h, 90, context.temp_allocator)
	return jpeg
}

@(test)
test_import_icons :: proc(t: ^testing.T) {
	lib: curl.Lib
	if !curl.load(&lib, "the test") {
		return
	}
	picture, _ := avatar.to_png(avatar_rgba(300, 200), context.temp_allocator) // bigger than a profile picture may be
	web: Web
	base, th := web_start(t, &web, 3, picture)
	defer web_stop(&web, th)

	// Two webhook posts that pose with pictures: one that is there, one that isn't a picture, and a bot's that isn't found.
	version := `{"type":"version","version":1,"info":{"generator":"mattermost-server","version":"x","created":"2026-01-01T00:00:00Z"}}`
	post :: proc(message, props: string, at: int) -> string {
		return fmt.tprintf(
			`{{"type":"post","post":{{"team":"acme","channel":"a","user":"root","message":"%s","create_at":%d,"props":%s}}}}`,
			message,
			at,
			props,
		)
	}
	lines := []string {
		version,
		`{"type":"team","team":{"name":"acme","display_name":"Acme","type":"O"}}`,
		`{"type":"channel","channel":{"team":"acme","name":"a","display_name":"a","type":"O"}}`,
		`{"type":"user","user":{"username":"root","roles":"system_admin","teams":[{"name":"acme","roles":"team_user","channels":[]}]}}`,
		post(
			"one",
			fmt.tprintf(
				`{{"from_webhook":"true","webhook_display_name":"hook","override_username":"Jenkins","override_icon_url":"%s/ok.png"}}`,
				base,
			),
			100,
		),
		post(
			"two",
			fmt.tprintf(
				`{{"from_webhook":"true","webhook_display_name":"hook","override_username":"Other","override_icon_url":"%s/text"}}`,
				base,
			),
			200,
		),
		post(
			"three",
			fmt.tprintf(
				`{{"from_webhook":"true","webhook_display_name":"hook","override_username":"Third","override_icon_url":"%s/missing"}}`,
				base,
			),
			300,
		),
		post(
			"again",
			fmt.tprintf(
				`{{"from_webhook":"true","webhook_display_name":"hook","override_username":"Jenkins again","override_icon_url":"%s/ok.png"}}`,
				base,
			),
			400,
		),
	}
	dir := export_of(t, ..lines)
	defer {
		remove_tree(dir)
		delete(dir)
	}
	it: Import_Test
	if !it_open(t, &it, dir) {
		return
	}
	defer it_close(&it)
	testing.expect_value(t, len(it.scan.icons), 3)
	it.im.emoji_dir = file_in(it.dir, "emoji")
	testing.expect(t, import_accounts(&it.im) && import_channels(&it.im))
	testing.expect(t, import_icons(&it.im, {allow_private = true}))
	testing.expect(t, import_messages(&it.im))
	db_commit(&it.db)

	// Each address once, however many posts use it.
	testing.expect_value(t, len(web.seen), 3)
	// A picture of the server's own, of the size that a profile picture has.
	testing.expect_value(t, len(it.im.icons), 1)
	one, _ := it_message(&it, "SELECT id FROM messages WHERE text = 'one'")
	testing.expect(t, .Persona in one.flags)
	testing.expect(t, one.persona.avatar != 0)
	blob, found := blob_get(&it.blobs, one.persona.avatar)
	testing.expect(t, found)
	testing.expect_value(t, blob.kind, Blob_Kind.Avatar)
	testing.expect(
		t,
		blob.width == 200 && blob.height == 200 && blob.size <= proto.MAX_AVATAR_SIZE,
	) // 300 by 200: the square in the middle
	again, _ := it_message(&it, "SELECT id FROM messages WHERE text = 'again'")
	testing.expect_value(t, again.persona.avatar, one.persona.avatar) // the same picture
	// The two that failed have none, and the reasons are told of.
	for text in ([]string{"two", "three"}) {
		m, _ := it_message(&it, fmt.tprintf("SELECT id FROM messages WHERE text = '%s'", text))
		testing.expect(t, .Persona in m.flags)
		testing.expect_value(t, m.persona.avatar, proto.Blob_Id(0))
	}
	testing.expect_value(t, it.scan.issues[.Icon_Failed].count, 2)
	reasons := strings.join(it.scan.issues[.Icon_Failed].examples[:], "; ", context.temp_allocator)
	testing.expect(
		t,
		strings.contains(reasons, "not a picture") && strings.contains(reasons, "answered 404"),
	)
	// And a message uses it, which is what lets anyone fetch it (persona_avatar_known).
	testing.expect_value(
		t,
		it_count(
			&it,
			fmt.tprintf(
				"SELECT count(*) FROM messages WHERE persona_avatar = %d",
				one.persona.avatar,
			),
		),
		2,
	)
}

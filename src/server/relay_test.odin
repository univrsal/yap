package server

import "core:fmt"
import "core:log"
import "core:os"
import "core:testing"

// Tests of which pages may connect through the relay (relay_site_allowed)
// and of the config's allow_sites.

@(test)
test_relay_site_allowed :: proc(t: ^testing.T) {
	R :: Relay_Request
	// Not a browser: nothing to protect a visitor from.
	testing.expect(t, relay_site_allowed(nil, R{host = "relay.example.org"}))

	// Chrome says nothing but Origin: the page's host has to be the relay's,
	// whatever the ports.
	testing.expect(
		t,
		relay_site_allowed(nil, R{origin = "http://localhost:8080", host = "localhost:8080"}),
	)
	testing.expect(
		t,
		relay_site_allowed(nil, R{origin = "https://Chat.Example.org", host = "chat.example.org"}),
	)
	testing.expect(
		t,
		relay_site_allowed(nil, R{origin = "http://localhost:8080", host = "localhost:8081"}),
	)
	testing.expect(
		t,
		relay_site_allowed(nil, R{origin = "http://[::1]:8080", host = "[::1]:8080"}),
	)
	testing.expect(
		t,
		!relay_site_allowed(nil, R{origin = "http://localhost:8080", host = "127.0.0.1:8081"}),
	)
	testing.expect(
		t,
		!relay_site_allowed(nil, R{origin = "https://evil.example", host = "chat.example.org"}),
	)
	testing.expect(
		t,
		!relay_site_allowed(
			nil,
			R{origin = "https://chat.example.org.evil", host = "chat.example.org"},
		),
	)
	// Behind a proxy that replaced Host with its own, X-Forwarded-Host says
	// what the browser asked for.
	behind := R {
		origin = "https://chat.example.org",
		host   = "127.0.0.1:8080",
	}
	testing.expect(t, !relay_site_allowed(nil, behind))
	behind.forwarded_host = "chat.example.org, proxy.internal"
	testing.expect(t, relay_site_allowed(nil, behind))

	// Browsers that say whether it's the same site are taken at their word,
	// which also lets other subdomains in.
	testing.expect(
		t,
		relay_site_allowed(
			nil,
			R{origin = "https://a.example.org", fetch_site = "same-site", host = "b.example.org"},
		),
	)
	testing.expect(
		t,
		!relay_site_allowed(
			nil,
			R{origin = "https://evil.example", fetch_site = "cross-site", host = "evil.example"},
		),
	)

	// Other sites only if they are allowed.
	allowed := []string{"https://chat.example.org", "http://localhost:9000"}
	other := R {
		origin = "https://chat.example.org",
		host   = "voice.other.net",
	}
	testing.expect(t, relay_site_allowed(allowed, other))
	other.fetch_site = "cross-site"
	testing.expect(t, relay_site_allowed(allowed, other))
	testing.expect(
		t,
		relay_site_allowed(allowed, R{origin = "HTTPS://Chat.Example.org/", host = "x"}),
	)
	testing.expect(
		t,
		!relay_site_allowed(allowed, R{origin = "http://chat.example.org", host = "x"}),
	)
	testing.expect(
		t,
		relay_site_allowed([]string{"*"}, R{origin = "https://anything.example", host = "x"}),
	)
	// A page without a real origin ("null", from a sandboxed frame) never is.
	testing.expect(t, !relay_site_allowed([]string{"*"}, R{origin = "null", host = "null"}))
}

// load_relay writes a config with the relay enabled and `allow_sites` (JSON)
// to a file in `dir`, and loads it.
@(private = "file")
load_relay :: proc(dir, allow_sites: string) -> (s: Settings, ok: bool) {
	path, _ := os.join_path({dir, "config.json"}, context.temp_allocator)
	json := fmt.tprintf(
		`{{"port": 28799, "data_dir": %q, "relay": {{"enabled": true, "port": 28798, "allow_sites": %s}}}}`,
		dir,
		allow_sites,
	)
	if os.write_entire_file(path, transmute([]u8)json) != nil {
		return
	}
	// What a config holds is kept for as long as the server runs.
	context.allocator = context.temp_allocator
	return load_config(path)
}

@(test)
test_relay_allow_sites_config :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "yap-test-*", context.temp_allocator)
	defer remove_tree(dir)

	s, ok := load_relay(dir, `[" HTTPS://Chat.Example.org/ ", "http://localhost:9000", "*"]`)
	testing.expect(t, ok)
	if ok && testing.expect_value(t, len(s.relay.allow_sites), 3) {
		testing.expect_value(t, s.relay.allow_sites[0], "https://chat.example.org")
		testing.expect_value(t, s.relay.allow_sites[1], "http://localhost:9000")
		testing.expect_value(t, s.relay.allow_sites[2], "*")
	}

	// Each of these is refused, with an error in the log that isn't wanted here.
	context.logger = log.nil_logger()
	for bad in ([]string {
			`["chat.example.org"]`,
			`["https://"]`,
			`["https://chat.example.org/path"]`,
			`["ftp://x"]`,
		}) {
		_, ok = load_relay(dir, bad)
		testing.expectf(t, !ok, "%s was accepted", bad)
	}
}

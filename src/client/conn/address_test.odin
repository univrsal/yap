#+build !wasi
package conn

import "core:testing"

@(test)
test_with_default_port :: proc(t: ^testing.T) {
	cases := []struct {
		input, want: string,
	} {
		{"example.com", "example.com:7777"},
		{"  example.com  ", "example.com:7777"},
		{"example.com:1234", "example.com:1234"},
		{"example.com:", "example.com:7777"},
		{"10.0.0.5", "10.0.0.5:7777"},
		{"10.0.0.5:7778", "10.0.0.5:7778"},
		{"[::1]", "[::1]:7777"},
		{"[::1]:", "[::1]:7777"},
		{"[::1]:5000", "[::1]:5000"},
		{"::1", "[::1]:7777"},
		{"ws://relay.example.com/yap/x", "ws://relay.example.com/yap/x"},
		{"wss://relay.example.com/yap/x", "wss://relay.example.com/yap/x"},
		// A server's web page means its relay.
		{"https://chat.example.org", "wss://chat.example.org/yap/chat.example.org"},
		{"https://chat.example.org/", "wss://chat.example.org/yap/chat.example.org"},
		{"http://localhost:8081", "ws://localhost:8081/yap/localhost:8081"},
		{"http://localhost:8081/?server=localhost:7779", "ws://localhost:8081/yap/localhost:8081"},
		{"https://example.org/chat/index.html", "wss://example.org/chat/yap/example.org"},
		{"", ""},
		{"   ", ""},
	}
	for c in cases {
		testing.expect_value(t, with_default_port(c.input), c.want)
	}
}

@(test)
test_is_web_address :: proc(t: ^testing.T) {
	good := []string {
		"https://chat.example.org",
		"http://localhost:8081",
		"  http://localhost:8081/  ",
		"http://localhost:8081/?server=localhost:7779",
		"https://chat.example.org#x",
		"http://10.0.0.5:8080",
		"http://[::1]:8080",
		"https://[::1]",
	}
	for a in good {
		testing.expectf(t, is_web_address(a), "%q was refused", a)
	}
	bad := []string {
		"",
		"localhost:7779",
		"chat.example.org",
		"ws://localhost:8081/yap/localhost:7779",
		"wss://chat.example.org",
		"ftp://chat.example.org",
		"https://",
		"https://chat.example.org/chat",
		"http://localhost:",
		"http://localhost:99999",
		"http://localhost:80a",
		"http://user@chat.example.org",
		"http://[::1",
	}
	for a in bad {
		testing.expectf(t, !is_web_address(a), "%q was accepted", a)
	}
}

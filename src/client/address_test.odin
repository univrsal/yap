#+build !wasi
package client

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
		{"", ""},
		{"   ", ""},
	}
	for c in cases {
		testing.expect_value(t, with_default_port(c.input), c.want)
	}
}

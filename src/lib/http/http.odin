package http

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"

// A minimal HTTP/1.1 implementation for the relay (server/relay.odin) and
// the bot API's gateway (lib/gateway), which share a port. It supports
// reading a request's line and headers, reading a body by its
// Content-Length, keep-alive and responses with a Content-Length. Chunked
// bodies and TLS are not supported (a reverse proxy in front handles TLS).
//
// A connection is read through Conn's buffer. Whatever comes after the
// headers (a body, the next request or WebSocket frames) is taken from that
// buffer piece by piece.

// A request's line and headers must fit in a Conn's buffer.
MAX_HEAD :: 8192

// Conn reads a TCP socket through a buffer.
Conn :: struct {
	sock:   net.TCP_Socket,
	remote: net.Endpoint, // the peer's address, as reported by accept
	limit:  ^Conn_Limit, // what counts it (accept_loop), or nil
	buf:    [MAX_HEAD]u8,
	start:  int,
	end:    int,
}

Header :: struct {
	name:  string,
	value: string,
}

// Request is a parsed request head, allocated with the temp allocator.
Request :: struct {
	method:         string,
	path:           string, // without the query
	query:          string, // after the '?', still encoded; "" for none
	headers:        []Header,
	// The body's size, or -1 if the request didn't give one.
	content_length: int,
	// Whether the body is sent in chunks, which isn't supported here.
	chunked:        bool,
	// Whether the client wants the connection kept for another request.
	keep_alive:     bool,
}

// read_head reads up to the end of the next request's headers and returns
// them, allocated with the temp allocator. Anything received after the
// headers stays in the buffer for later reads. It fails if the peer
// disconnects or the head doesn't fit in MAX_HEAD.
read_head :: proc(c: ^Conn) -> (head: string, ok: bool) {
	for {
		if i := strings.index(string(c.buf[c.start:c.end]), "\r\n\r\n"); i >= 0 {
			head = strings.clone(string(c.buf[c.start:c.start + i]), context.temp_allocator)
			c.start += i + 4
			return head, true
		}
		// Make room for more data by moving what's left in the buffer to its front.
		if c.start > 0 {
			copy(c.buf[:], c.buf[c.start:c.end])
			c.end -= c.start
			c.start = 0
		}
		if c.end >= len(c.buf) {
			return "", false
		}
		n, err := net.recv_tcp(c.sock, c.buf[c.end:])
		if err != nil || n == 0 {
			return "", false
		}
		c.end += n
	}
}

// MAX_PRINTABLE is the most bytes of a string that printable keeps.
MAX_PRINTABLE :: 200

// printable returns `s` made safe to log: every byte that isn't printable
// ASCII is written as \xNN, so a path from a request can't carry terminal
// escapes, and it is cut to MAX_PRINTABLE bytes.
printable :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(0, min(len(s), MAX_PRINTABLE) + 3, allocator)
	for i in 0 ..< len(s) {
		if i == MAX_PRINTABLE {
			strings.write_string(&b, "...")
			break
		}
		c := s[i]
		if c >= 0x20 && c < 0x7f && c != '\\' {
			strings.write_byte(&b, c)
		} else {
			fmt.sbprintf(&b, "\\x%02x", c)
		}
	}
	return strings.to_string(b)
}

// parse_request parses a request head. It fails if the head has no valid
// request line.
parse_request :: proc(head: string) -> (req: Request, ok: bool) {
	lines := strings.split_lines(head, context.temp_allocator)
	if len(lines) == 0 {
		return
	}
	parts := strings.fields(lines[0], context.temp_allocator)
	if len(parts) < 2 {
		return
	}
	req.method = parts[0]
	req.path = parts[1]
	if i := strings.index_byte(req.path, '?'); i >= 0 {
		req.query = req.path[i + 1:]
		req.path = req.path[:i]
	}
	version := parts[2] if len(parts) >= 3 else "HTTP/1.0"
	req.keep_alive = version == "HTTP/1.1"
	req.content_length = -1
	seen_length := false
	headers := make([dynamic]Header, 0, len(lines) - 1, context.temp_allocator)
	for line in lines[1:] {
		colon := strings.index_byte(line, ':')
		if colon < 0 {
			continue
		}
		h := Header {
			name  = strings.trim_space(line[:colon]),
			value = strings.trim_space(line[colon + 1:]),
		}
		append(&headers, h)
		switch {
		case strings.equal_fold(h.name, "Content-Length"):
			// Only digits, and not so many that the number could wrap:
			// parse_int would also take a sign or "_" between digits. Two
			// lengths that differ make the request ambiguous.
			if len(h.value) == 0 || len(h.value) > 15 {
				return
			}
			for d in transmute([]u8)h.value {
				if d < '0' || d > '9' {
					return
				}
			}
			n, _ := strconv.parse_int(h.value, 10)
			if seen_length && n != req.content_length {
				return
			}
			seen_length = true
			req.content_length = n
		case strings.equal_fold(h.name, "Transfer-Encoding"):
			req.chunked = !strings.equal_fold(h.value, "identity")
		case strings.equal_fold(h.name, "Connection"):
			if has_token(h.value, "close") {
				req.keep_alive = false
			} else if has_token(h.value, "keep-alive") {
				req.keep_alive = true
			}
		}
	}
	req.headers = headers[:]
	return req, true
}

// header returns the value of the request's header `name`, or "" if the
// request doesn't have it.
header :: proc(req: ^Request, name: string) -> string {
	for h in req.headers {
		if strings.equal_fold(h.name, name) {
			return h.value
		}
	}
	return ""
}

// read_some reads up to len(out) bytes. It returns what is already buffered
// or, if the buffer is empty, the result of a single socket read. ok is
// false if the peer has disconnected.
read_some :: proc(c: ^Conn, out: []u8) -> (n: int, ok: bool) {
	if len(out) == 0 {
		return 0, true
	}
	if c.start < c.end {
		n = copy(out, c.buf[c.start:c.end])
		c.start += n
		return n, true
	}
	got, err := net.recv_tcp(c.sock, out)
	if err != nil || got == 0 {
		return
	}
	return got, true
}

// read_body reads `size` bytes of body into `out`.
read_body :: proc(c: ^Conn, out: []u8) -> bool {
	return read_exact(c, out)
}

// respond sends a complete response with its body, with an HTTP status code
// (status_line). `extra` holds additional header lines, each ending in
// "\r\n". With `keep_alive` the connection stays open for another request.
// Without it, the client is told that the connection will be closed.
respond :: proc(
	sock: net.TCP_Socket,
	status: int,
	content_type: string,
	body: string,
	keep_alive := false,
	extra := "",
) -> bool {
	head := fmt.tprintf(
		"HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-cache\r\nConnection: %s\r\n%s\r\n",
		status_line(status),
		content_type,
		len(body),
		"keep-alive" if keep_alive else "close",
		extra,
	)
	return send_all(sock, transmute([]u8)head) && send_all(sock, transmute([]u8)body)
}

// status_line is the status line's code and reason for an HTTP status code;
// one it doesn't know reads as 500's.
status_line :: proc(status: int) -> string {
	text: string
	switch status {
	case 200:
		text = "OK"
	case 201:
		text = "Created"
	case 204:
		text = "No Content"
	case 400:
		text = "Bad Request"
	case 401:
		text = "Unauthorized"
	case 403:
		text = "Forbidden"
	case 404:
		text = "Not Found"
	case 405:
		text = "Method Not Allowed"
	case 409:
		text = "Conflict"
	case 410:
		text = "Gone"
	case 411:
		text = "Length Required"
	case 413:
		text = "Content Too Large"
	case 429:
		text = "Too Many Requests"
	case 501:
		text = "Not Implemented"
	case 502:
		text = "Bad Gateway"
	case 503:
		text = "Service Unavailable"
	case:
		text = "Internal Server Error"
	}
	return fmt.tprintf("%d %s", status, text)
}

// has_token returns whether the comma-separated header value contains
// `token`.
@(private)
has_token :: proc(value, token: string) -> bool {
	rest := value
	for part in strings.split_iterator(&rest, ",") {
		if strings.equal_fold(strings.trim_space(part), token) {
			return true
		}
	}
	return false
}

// query_value returns the value of `name` in a query string ("a=1&b=two"),
// percent-decoded and with '+' as a space, allocated with the temp
// allocator. `found` is false if the name isn't there or can't be decoded.
query_value :: proc(query, name: string) -> (value: string, found: bool) {
	rest := query
	for pair in strings.split_iterator(&rest, "&") {
		key, _, raw := strings.partition(pair, "=")
		k := percent_decode(key, true) or_continue
		if k == name {
			return percent_decode(raw, true)
		}
	}
	return
}

// percent_decode decodes %XX escapes (and, with `plus`, turns '+' into a
// space), allocated with the temp allocator. ok is false for an invalid
// escape.
percent_decode :: proc(s: string, plus := false) -> (out: string, ok: bool) {
	if strings.index_byte(s, '%') < 0 && (!plus || strings.index_byte(s, '+') < 0) {
		return s, true
	}
	buf := make([]u8, len(s), context.temp_allocator)
	n := 0
	for i := 0; i < len(s); i += 1 {
		switch {
		case s[i] == '%':
			if i + 2 >= len(s) {
				return
			}
			hi, hi_ok := hex_digit(s[i + 1])
			lo, lo_ok := hex_digit(s[i + 2])
			if !hi_ok || !lo_ok {
				return
			}
			buf[n] = hi << 4 | lo
			i += 2
		case plus && s[i] == '+':
			buf[n] = ' '
		case:
			buf[n] = s[i]
		}
		n += 1
	}
	return string(buf[:n]), true
}

@(private)
hex_digit :: proc(c: u8) -> (v: u8, ok: bool) {
	switch c {
	case '0' ..= '9':
		return c - '0', true
	case 'a' ..= 'f':
		return c - 'a' + 10, true
	case 'A' ..= 'F':
		return c - 'A' + 10, true
	}
	return
}

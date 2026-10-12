package http

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"

/*
Just enough of HTTP/1.1 for the relay (server/relay.odin) and the bot
API's gateway (common/gateway), which share a port: a request's line and
headers, a body by its Content-Length, keep-alive, and answers with a
Content-Length. No chunked bodies, no TLS (a reverse proxy in front
does that).

A connection is read through Conn's buffer, so what comes after the
headers - a body, the next request, WebSocket frames - is taken off it
piece by piece.
*/

// A request's line and headers have to fit in a Conn's buffer.
MAX_HEAD :: 8192

// Conn reads a TCP socket through a buffer.
Conn :: struct {
	sock:   net.TCP_Socket,
	remote: net.Endpoint, // who's at the other end, as accept said
	buf:   [MAX_HEAD]u8,
	start: int,
	end:   int,
}

Header :: struct {
	name:  string,
	value: string,
}

// A request's head, in the temp allocator.
Request :: struct {
	method:         string,
	path:           string, // without the query
	query:          string, // after the '?', still encoded; "" for none
	headers:        []Header,
	// The body's size; -1 for none said.
	content_length: int,
	// Its body comes in chunks, which isn't supported here.
	chunked:        bool,
	// Whether the client wants the connection kept for another request.
	keep_alive:     bool,
}

/*
read_head reads up to the end of the next request's headers and returns
them, in the temp allocator. Whatever came in after them stays in the
buffer for what follows. It fails when the peer goes, or the head
doesn't fit in MAX_HEAD.
*/
read_head :: proc(c: ^Conn) -> (head: string, ok: bool) {
	for {
		if i := strings.index(string(c.buf[c.start:c.end]), "\r\n\r\n"); i >= 0 {
			head = strings.clone(string(c.buf[c.start:c.start + i]), context.temp_allocator)
			c.start += i + 4
			return head, true
		}
		// Room for more: what's left of the buffer goes to its front.
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

// parse_request takes a head apart; it fails on one without a request
// line.
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
			n, n_ok := strconv.parse_int(h.value, 10)
			if !n_ok || n < 0 {
				return
			}
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

// header is the value of a request's header `name`; "" if it has none.
header :: proc(req: ^Request, name: string) -> string {
	for h in req.headers {
		if strings.equal_fold(h.name, name) {
			return h.value
		}
	}
	return ""
}

/*
read_some reads what there is, up to len(out): what's buffered already,
or else what one read of the socket brings. False if the peer has gone.
*/
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

/*
respond sends an answer with its body whole. `extra` is more header
lines, each ending in "\r\n". With `keep_alive` the connection stays
open for another request; without, the client is told it closes.
*/
respond :: proc(
	sock: net.TCP_Socket,
	status, content_type: string,
	body: string,
	keep_alive := false,
	extra := "",
) -> bool {
	head := fmt.tprintf(
		"HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-cache\r\nConnection: %s\r\n%s\r\n",
		status,
		content_type,
		len(body),
		"keep-alive" if keep_alive else "close",
		extra,
	)
	return send_all(sock, transmute([]u8)head) && send_all(sock, transmute([]u8)body)
}

// has_token says whether a comma separated header value has `token`.
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

/*
query_value is the value of `name` in a query string ("a=1&b=two"),
percent-decoded, with '+' as a space, in the temp allocator. `found` is
false if it isn't there, or doesn't decode.
*/
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

/*
percent_decode undoes %XX escapes (and with `plus`, '+' for a space), in
the temp allocator; false for a broken escape.
*/
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

#+build wasi
package client

import log "../common/wlog"
import "core:strings"

/*
A WebSocket to the relay, which puts the packets back on a UDP socket
at the far end (see src/server/relay.odin). One packet per message, so the protocol
still sees datagram boundaries.

The socket is opened by the page and the arriving messages are queued
there; this side takes them one at a time, the same way the desktop
client takes them off a UDP socket. Nothing is sent until the socket is
open, which costs a round trip at the start of a connection - the
handshake is resent until it gets through, so that sorts itself out.
*/

@(default_calling_convention = "c")
foreign _ {
	// Opens the socket, dropping whatever was open before. The address
	// is a ws:// or wss:// URL.
	yap_ws_open :: proc(url: cstring) -> i32 ---
	yap_ws_close :: proc() ---
	// 1 once the socket is open, 0 while it's connecting, -1 if it has
	// failed or closed.
	yap_ws_state :: proc() -> i32 ---
	yap_ws_send :: proc(data: [^]u8, size: i32) -> i32 ---
	// Copies the oldest queued message into buf and returns its size,
	// or -1 if there is nothing waiting.
	yap_ws_recv :: proc(buf: [^]u8, buf_size: i32) -> i32 ---
}

Transport :: struct {
	open: bool,
}

/*
transport_open turns the address the user typed into a URL for the
relay. A plain host:port becomes a WebSocket to the relay beside this
page - ws://<page host>/yap/<host:port> - so the usual "localhost:7777"
still works; anything that already looks like a URL is used as it is.
*/
transport_open :: proc(t: ^Transport, server_addr: string) -> bool {
	url := server_addr
	if !strings.has_prefix(url, "ws://") && !strings.has_prefix(url, "wss://") {
		url = strings.concatenate(
			{relay_url_prefix(), "/yap/", server_addr},
			context.temp_allocator,
		)
	}
	if yap_ws_open(strings.clone_to_cstring(url, context.temp_allocator)) == 0 {
		log.errorf("could not open a WebSocket to %s", url)
		return false
	}
	log.infof("connecting through %s", url)
	t.open = true
	return true
}

transport_close :: proc(t: ^Transport) {
	if t.open {
		yap_ws_close()
		t.open = false
	}
}

transport_send :: proc(t: ^Transport, packet: []byte) -> bool {
	// Anything sent before the socket is open is dropped; the protocol
	// resends what matters (handshakes, joins, names, state acks).
	if !t.open || yap_ws_state() != 1 {
		return false
	}
	return yap_ws_send(raw_data(packet), i32(len(packet))) != 0
}

transport_recv :: proc(t: ^Transport, buf: []byte) -> (packet: []byte, ok: bool) {
	if !t.open {
		return nil, false
	}
	n := yap_ws_recv(raw_data(buf), i32(len(buf)))
	if n < 0 {
		return nil, false
	}
	return buf[:n], true
}

@(private = "file", default_calling_convention = "c")
foreign _ {
	// ws:// or wss:// for the page this was served from, followed by
	// its host - whatever the relay is reachable at.
	yap_ws_origin :: proc(buf: [^]u8, buf_size: i32) -> i32 ---
}

@(private = "file")
relay_url_prefix :: proc() -> string {
	buf: [256]u8
	n := yap_ws_origin(raw_data(buf[:]), len(buf))
	if n <= 0 {
		return "ws://localhost:8080"
	}
	return strings.clone(string(buf[:n]), context.temp_allocator)
}

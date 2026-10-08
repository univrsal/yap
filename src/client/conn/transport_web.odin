#+build wasi
package conn

import log "common:wlog"
import "core:strings"
import "core:time"

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
	// Each takes the socket's slot: a connection's main link has an even
	// one (Voice_Client.slot), its bulk link (bulk.odin) the one after.
	// Opens the socket, dropping whatever was open before in that slot.
	// The address is a ws:// or wss:// URL.
	yap_ws_open :: proc(slot: i32, url: cstring) -> i32 ---
	yap_ws_close :: proc(slot: i32) ---
	// 1 once the socket is open, 0 while it's connecting, -1 if it has
	// failed or closed.
	yap_ws_state :: proc(slot: i32) -> i32 ---
	yap_ws_send :: proc(slot: i32, data: [^]u8, size: i32) -> i32 ---
	// Copies the oldest queued message into buf and returns its size,
	// or -1 if there is nothing waiting.
	yap_ws_recv :: proc(slot: i32, buf: [^]u8, buf_size: i32) -> i32 ---
	// Bytes handed to the socket that it hasn't sent yet.
	yap_ws_buffered :: proc(slot: i32) -> i32 ---
	// How many messages have arrived and wait for yap_ws_recv.
	yap_ws_pending :: proc(slot: i32) -> i32 ---
}

Transport :: struct {
	open:     bool,
	slot:     i32,
	url:      string, // owned; what transport_revive opens again
	retry_at: time.Tick,
}

// How long to wait before opening a socket that has died again.
REVIVE_AFTER :: 2 * time.Second

/*
transport_open turns the address the user typed into a URL for the
relay. A plain host:port becomes a WebSocket to the relay beside this
page - ws://<page host>/yap/<host:port> - so the usual "localhost:7777"
still works; anything that already looks like a URL is used as it is.
*/
transport_open :: proc(t: ^Transport, server_addr: string, slot: i32, bulk := false) -> bool {
	t.slot = slot + 1 if bulk else slot
	url := server_addr
	if !strings.has_prefix(url, "ws://") && !strings.has_prefix(url, "wss://") {
		url = strings.concatenate(
			{relay_url_prefix(), "/yap/", server_addr},
			context.temp_allocator,
		)
	}
	delete(t.url)
	t.url = strings.clone(url)
	if yap_ws_open(t.slot, strings.clone_to_cstring(url, context.temp_allocator)) == 0 {
		log.errorf("could not open a WebSocket to %s", url)
		return false
	}
	if !bulk {
		log.infof("connecting through %s", url)
	}
	t.open = true
	return true
}

transport_close :: proc(t: ^Transport) {
	if t.open {
		yap_ws_close(t.slot)
		t.open = false
	}
	delete(t.url)
	t.url = ""
}

/*
transport_revive opens the socket again once it has died - the server
went away, or the network did - which a UDP socket never needs: there the
packets just stop arriving. Without it the page would sit behind a closed
socket for good. It tries again every REVIVE_AFTER for as long as the
connection lasts; client_step gives up on it when that's too long.
*/
transport_revive :: proc(t: ^Transport) {
	if !t.open || yap_ws_state(t.slot) != -1 {
		return
	}
	if t.retry_at != {} && time.tick_diff(time.tick_now(), t.retry_at) > 0 {
		return
	}
	t.retry_at = time.tick_add(time.tick_now(), REVIVE_AFTER)
	log.debugf("the WebSocket on slot %d is closed, opening it again", t.slot)
	yap_ws_open(t.slot, strings.clone_to_cstring(t.url, context.temp_allocator))
}

transport_send :: proc(t: ^Transport, packet: []byte) -> bool {
	// Anything sent before the socket is open is dropped; the protocol
	// resends what matters (handshakes, joins, names, state acks).
	if !t.open || yap_ws_state(t.slot) != 1 {
		return false
	}
	return yap_ws_send(t.slot, raw_data(packet), i32(len(packet))) != 0
}

transport_recv :: proc(t: ^Transport, buf: []byte) -> (packet: []byte, ok: bool) {
	if !t.open {
		return nil, false
	}
	n := yap_ws_recv(t.slot, raw_data(buf), i32(len(buf)))
	if n < 0 {
		return nil, false
	}
	return buf[:n], true
}

// transport_backlog is how much the socket still has to send, which is
// how the video queue knows to hold back (see video.odin).
transport_backlog :: proc(t: ^Transport) -> int {
	return int(yap_ws_buffered(t.slot)) if t.open else 0
}

// transport_pending says whether packets are waiting to be received.
transport_pending :: proc(t: ^Transport) -> bool {
	return t.open && yap_ws_pending(t.slot) > 0
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

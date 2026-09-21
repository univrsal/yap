#+build !wasi
package client

import log "../common/wlog"
import "core:net"
import "core:time"

// A UDP socket, which is what the protocol was written for.
Transport :: struct {
	sock:   net.UDP_Socket,
	server: net.Endpoint,
	open:   bool,
}

transport_open :: proc(t: ^Transport, server_addr: string) -> bool {
	ep, resolve_err := net.resolve_ip4(server_addr)
	if resolve_err != nil {
		log.errorf("failed to resolve %s: %v", server_addr, resolve_err)
		return false
	}
	t.server = ep

	sock, err := net.make_bound_udp_socket(net.IP4_Any, 0)
	if err != nil {
		log.errorf("failed to create socket: %v", err)
		return false
	}
	t.sock = sock
	t.open = true
	// Short timeout so the loop can also pace outgoing frames.
	net.set_option(sock, .Receive_Timeout, 2 * time.Millisecond)
	return true
}

transport_close :: proc(t: ^Transport) {
	if t.open {
		net.close(t.sock)
		t.open = false
	}
}

transport_send :: proc(t: ^Transport, packet: []byte) -> bool {
	if !t.open {
		return false
	}
	_, err := net.send_udp(t.sock, packet, t.server)
	if err != nil {
		log.errorf("send failed: %v", err)
		return false
	}
	return true
}

transport_recv :: proc(t: ^Transport, buf: []byte) -> (packet: []byte, ok: bool) {
	if !t.open {
		return nil, false
	}
	n, from, err := net.recv_udp(t.sock, buf)
	#partial switch err {
	case .None:
		// Anything from somewhere else is not this conversation.
		if from != t.server {
			return nil, false
		}
		return buf[:n], true
	case .Timeout, .Would_Block:
	case:
		log.errorf("recv error: %v", err)
	}
	return nil, false
}

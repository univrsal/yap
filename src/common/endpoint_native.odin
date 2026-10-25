#+build !wasi
package common

import log "common:wlog"
import "core:net"

// resolve_endpoint turns host:port (or an address) into an endpoint, with
// `port` if it names none. It logs why it can't.
resolve_endpoint :: proc(address: string, port: int) -> (ep: net.Endpoint, ok: bool) {
	if parsed, parsed_ok := net.parse_endpoint(address); parsed_ok {
		ep = parsed
	} else {
		resolved, err := net.resolve_ip4(address)
		if err != nil {
			log.errorf("can't find %s: %v", address, err)
			return
		}
		ep = resolved
	}
	if ep.port == 0 {
		ep.port = port
	}
	return ep, true
}

// Address_Key is an address (without the port) as bytes, to count
// connections or requests by. net.Address itself can't be a map key: the
// bytes an IPv4 address leaves unused in the union are undefined.
Address_Key :: [17]byte

// address_key returns the address of an endpoint, without the port, as bytes.
address_key :: proc(from: net.Endpoint) -> (key: Address_Key) {
	switch a in from.address {
	case net.IP4_Address:
		key[0] = 4
		b := a
		copy(key[1:], b[:])
	case net.IP6_Address:
		key[0] = 6
		b := transmute([16]u8)a
		copy(key[1:17], b[:])
	}
	return
}

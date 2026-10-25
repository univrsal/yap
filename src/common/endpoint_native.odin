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

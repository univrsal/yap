package relay

import "core:flags"
import "core:log"
import "core:os"
import "core:strings"

import "../common"

/*
yap-relay: lets the web client reach a yap server.

A browser can't send UDP, so the web client sends its packets over a
WebSocket instead, and this puts them back on UDP at the other end - one
UDP socket per WebSocket, so the server sees each browser as a client of
its own. It also serves the web build itself, so one address is all a
browser needs:

	yap-relay localhost:7777
	open http://localhost:8080/?server=localhost:7777

The relay can't read what it carries: the session is end-to-end between
the web client and the server, and the relay only ever sees sealed
packets. It will only relay to the servers it was started with, so it
can't be turned into a way to send UDP anywhere.
*/

DEFAULT_PORT :: 8080
DEFAULT_WEB_DIR :: "web/out"

Options :: struct {
	servers:   string `args:"pos=0,required" usage:"Server(s) to relay to, host:port, comma-separated. Nothing else is relayed to."`,
	port:      int `usage:"TCP port to listen on for browsers (default 8080)."`,
	web:       string `usage:"Directory holding the web build to serve (default web/out)."`,
	log_level: common.Log_Level `usage:"Lowest level to log: debug, info, warn, error (default info)."`,
}

main :: proc() {
	opt := Options {
		port      = DEFAULT_PORT,
		web       = DEFAULT_WEB_DIR,
		log_level = .info,
	}
	flags.parse_or_exit(&opt, os.args, .Odin)

	logger, ok := common.init_logging(opt.log_level)
	if !ok {
		os.exit(1)
	}
	defer common.destroy_logging(logger)
	context.logger = logger

	if opt.port <= 0 || opt.port > 65535 {
		log.errorf("invalid port: %d", opt.port)
		os.exit(2)
	}
	servers: [dynamic]string
	for s in strings.split(opt.servers, ",", context.temp_allocator) {
		if server := strings.trim_space(s); server != "" {
			append(&servers, strings.clone(server))
		}
	}
	if len(servers) == 0 {
		log.error("no server to relay to")
		os.exit(2)
	}

	if !run_relay(servers[:], opt.port, opt.web) {
		os.exit(1)
	}
}

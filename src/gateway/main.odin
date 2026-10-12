package yap_gateway

import "core:encoding/hex"
import "core:flags"
import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:thread"

import "common:."
import "common:gateway"
import "common:http"
import "common:proto"

/*
yap-gateway: the bot API (docs/bot-api) on its own, for any yap server,
including one that doesn't enable it: a bot author runs it next to their
bot. It's the same gateway yap-server runs with "api" enabled, to which
the server is just more clients.

It isn't part of build.sh:

	odin build src/gateway -collection:common=src/common -out:bin/yap-gateway
	bin/yap-gateway -server:chat.example.org:7777 -server-key:<64 hex digits>

The server's key is in its log when it starts ("server public key");
given, the gateway won't talk to a server without it. It listens on
this machine only unless told otherwise: it's plain HTTP, and a token
or a password going over it to anywhere else should go through a
reverse proxy with TLS.
*/

Options :: struct {
	server:          string `usage:"host:port of the yap server (default 127.0.0.1:7777)"`,
	server_key:      string `usage:"the server's public key, 64 hex digits; without, whichever it has is taken"`,
	password:        string `usage:"the server's password, if it has one"`,
	listen:          string `usage:"where to serve the API (default 127.0.0.1:8080)"`,
	max_connections: int `usage:"how many tokens may be in use at once (default 64)"`,
	rate:            f64 `usage:"requests a second a token may make (default 10; 0 for no limit)"`,
	burst:           f64 `usage:"how many of them at once (default 30)"`,
	behind_proxy:    bool `usage:"it's behind a reverse proxy with TLS, whose X-Forwarded-Proto says what a request came over"`,
}

main :: proc() {
	logger, logger_ok := common.init_logging(.info)
	if !logger_ok {
		os.exit(1)
	}
	context.logger = logger

	opt := Options {
		server = "127.0.0.1:7777",
		listen = "127.0.0.1:8080",
		rate   = gateway.DEFAULT_RATE,
		burst  = gateway.DEFAULT_BURST,
	}
	flags.parse_or_exit(&opt, os.args, .Odin)

	if opt.rate < 0 || opt.burst < 0 || (opt.rate > 0 && opt.burst < 1) {
		fmt.eprintln("-rate and -burst can't be negative, and -burst is at least 1 with a rate")
		os.exit(2)
	}
	cfg := gateway.Config {
		password        = opt.password,
		max_connections = opt.max_connections,
		rate            = opt.rate,
		burst           = opt.burst,
		behind_proxy    = opt.behind_proxy,
	}
	server, server_ok := resolve(opt.server, proto.DEFAULT_PORT)
	if !server_ok {
		os.exit(2)
	}
	cfg.server = server
	if opt.server_key != "" {
		key, key_ok := hex.decode(transmute([]u8)opt.server_key, context.temp_allocator)
		if !key_ok || len(key) != proto.KEY_SIZE {
			fmt.eprintln("-server-key is 64 hex digits: the server's public key")
			os.exit(2)
		}
		copy(cfg.server_key[:], key)
	} else {
		log.warn("no -server-key: whichever key the server has is taken")
	}
	listen, listen_ok := resolve(opt.listen, 8080)
	if !listen_ok {
		os.exit(2)
	}
	listener, err := net.listen_tcp(listen)
	if err != nil {
		log.errorf("could not listen on %s: %v", opt.listen, err)
		os.exit(1)
	}
	g := gateway.start(cfg)
	log.infof(
		"serving the bot API of %s on http://%s/api/v1/",
		net.to_string(server),
		net.to_string(listen),
	)
	for {
		free_all(context.temp_allocator)
		sock, from, accept_err := net.accept_tcp(listener)
		if accept_err != nil {
			log.warnf("accept failed: %v", accept_err)
			continue
		}
		c := new(http.Conn)
		c.sock, c.remote = sock, from
		thread.create_and_start_with_poly_data2(
			g,
			c,
			gateway.serve_connection,
			init_context = context,
			self_cleanup = true,
		)
	}
}

// resolve is host:port as an endpoint, `port` if it doesn't say.
resolve :: proc(address: string, port: int) -> (ep: net.Endpoint, ok: bool) {
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

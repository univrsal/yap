package yap_gateway

import "core:flags"
import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:thread"

import "common:."
import "lib:gateway"
import "lib:http"
import "common:proto"

// yap-gateway runs the bot API (docs/bot-api) as a standalone program. It
// works with any yap server, even one that doesn't enable the API itself, so a
// bot author can run it next to their bot. It is the same gateway that
// yap-server runs when "api" is enabled, and the server sees it as just
// another client.
//
// It isn't part of build.sh:
//
//	odin build src/gateway -collection:common=src/common -collection:lib=src/lib -out:bin/yap-gateway
//	bin/yap-gateway -server:chat.example.org:7777 -server-key:<64 hex digits>
//
// The server's key is printed in its log on startup ("server public key").
// If a key is given, the gateway refuses to talk to a server that has a
// different one. By default the gateway only listens on this machine. It
// serves plain HTTP, so if a token or password has to travel to anywhere
// else, it should go through a reverse proxy with TLS.

Options :: struct {
	server:          string `usage:"host:port of the yap server (default 127.0.0.1:7777)"`,
	server_key:      string `usage:"the server's public key as 64 hex digits (if omitted, any server key is accepted)"`,
	password:        string `usage:"the server's password, if it has one"`,
	listen:          string `usage:"address to serve the API on (default 127.0.0.1:8080)"`,
	max_connections: int `usage:"maximum number of tokens that may be in use at once (default 64)"`,
	rate:            f64 `usage:"maximum requests per second for each token (default 10, 0 for no limit)"`,
	burst:           f64 `usage:"maximum number of requests a token may make in a burst (default 30)"`,
	behind_proxy:    bool `usage:"set when running behind a TLS reverse proxy; its X-Forwarded-Proto header tells whether a request came over HTTPS"`,
	trusted_proxy:   string `usage:"with -behind-proxy, the proxy's IP address: only its X-Forwarded-Proto is believed (default: this machine and private networks)"`,
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
		fmt.eprintln(
			"-rate and -burst can't be negative, and -burst must be at least 1 when -rate is set",
		)
		os.exit(2)
	}
	cfg := gateway.Config {
		password        = opt.password,
		max_connections = opt.max_connections,
		rate            = opt.rate,
		burst           = opt.burst,
		behind_proxy    = opt.behind_proxy,
	}
	if opt.trusted_proxy != "" {
		cfg.trusted_proxy = net.parse_address(opt.trusted_proxy)
		if cfg.trusted_proxy == nil {
			fmt.eprintln("-trusted-proxy must be an IP address")
			os.exit(2)
		}
	}
	server, server_ok := common.resolve_endpoint(opt.server, proto.DEFAULT_PORT)
	if !server_ok {
		os.exit(2)
	}
	cfg.server = server
	if opt.server_key != "" {
		key, key_ok := common.parse_key_hex(opt.server_key)
		if !key_ok {
			fmt.eprintln("-server-key must be the server's public key as 64 hex digits")
			os.exit(2)
		}
		cfg.server_key = key
	} else {
		log.warn("no -server-key given, so any server key will be accepted")
	}
	listen, listen_ok := common.resolve_endpoint(opt.listen, 8080)
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

package server

import "core:flags"
import "core:log"
import "core:os"

import "../common"

DEFAULT_PORT :: 7777

Options :: struct {
	key:       string           `args:"pos=0,required" usage:"Private key file, created if missing. Keep it: clients remember this key and refuse to connect if it changes."`,
	port:      int              `args:"pos=1" usage:"UDP port to listen on (default 7777)."`,
	log_level: common.Log_Level `usage:"Lowest level to log: debug, info, warn, error (default info)."`,
	log_file:  string           `usage:"Also append the log to this file."`,
}

main :: proc() {
	opt := Options{port = DEFAULT_PORT, log_level = .info}
	flags.parse_or_exit(&opt, os.args, .Odin)

	logger, ok := common.init_logging(opt.log_level, opt.log_file)
	if !ok {
		os.exit(1)
	}
	defer common.destroy_logging(logger)
	context.logger = logger

	if opt.port <= 0 || opt.port > 65535 {
		log.errorf("invalid port: %d", opt.port)
		os.exit(2)
	}

	if !run_server(opt.key, opt.port) {
		os.exit(1)
	}
}

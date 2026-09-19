package client

import "core:flags"
import "core:log"
import "core:os"

import "../common"

Options :: struct {
	key:           string           `args:"pos=0,required" usage:"Private key file, created if missing."`,
	server:        string           `args:"pos=1,required" usage:"Server address, host:port."`,
	known_servers: string           `usage:"Trusted server keys, filled in on first connect (default <config dir>/yap/known_servers)."`,
	log_level:     common.Log_Level `usage:"Lowest level to log: debug, info, warn, error (default info)."`,
	log_file:      string           `usage:"Also append the log to this file."`,
}

main :: proc() {
	opt := Options{log_level = .info}
	flags.parse_or_exit(&opt, os.args, .Odin)

	logger, ok := common.init_logging(opt.log_level, opt.log_file)
	if !ok {
		os.exit(1)
	}
	defer common.destroy_logging(logger)
	context.logger = logger

	if opt.known_servers == "" {
		opt.known_servers = default_known_servers_path()
		if opt.known_servers == "" {
			log.error("could not determine the config directory; pass -known-servers:<file>")
			os.exit(2)
		}
	}

	if !run_client(opt.key, opt.server, opt.known_servers) {
		os.exit(1)
	}
}

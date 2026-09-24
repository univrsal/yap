package server

import "core:flags"
import "core:log"
import "core:os"

import "../common"

Options :: struct {
	config: string `args:"pos=0" usage:"Config file (default config.json): port, key, password, relay, channels... Created with defaults and a new key if missing."`,
}

main :: proc() {
	opt := Options {
		config = DEFAULT_CONFIG_FILE,
	}
	flags.parse_or_exit(&opt, os.args, .Odin)

	// The config says how to log, so until it's read, log at the
	// default level to the terminal.
	early, early_ok := common.init_logging(.info)
	if !early_ok {
		os.exit(1)
	}
	context.logger = early
	log.infof("yap-server %s", common.version_string())
	settings, config_ok := load_config(opt.config)
	common.destroy_logging(early)
	context.logger = {}
	if !config_ok {
		os.exit(2)
	}

	logger, ok := common.init_logging(settings.log_level, settings.log_file)
	if !ok {
		os.exit(1)
	}
	defer common.destroy_logging(logger)
	context.logger = logger

	if settings.relay.enabled && !start_relay(settings.relay.port, settings.port, settings.relay.web_dir) {
		os.exit(1)
	}
	if !run_server(settings) {
		os.exit(1)
	}
}

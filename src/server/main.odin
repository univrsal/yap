package server

import "core:flags"
import "core:fmt"
import "core:log"
import "core:os"

import "common:."

Options :: struct {
	config: string `args:"pos=0" usage:"Config file (default config.json): port, key, password, relay, channels... Created with defaults and a new key if missing. For the accounts, see: yap-server account; to purge old messages: yap-server purge"`,
}

main :: proc() {
	// `yap-server account ...` works on the accounts and exits (cli.odin).
	// And `yap-server role list`, which is its `roles`.
	if len(os.args) > 1 && (os.args[1] == "account" || os.args[1] == "role") {
		quiet, quiet_ok := common.init_logging(.warn)
		if !quiet_ok {
			os.exit(1)
		}
		context.logger = quiet
		args := os.args[2:]
		if os.args[1] == "role" {
			if len(args) == 0 || args[0] != "list" {
				fmt.eprintln(ACCOUNT_USAGE)
				os.exit(2)
			}
			list := make([dynamic]string, context.temp_allocator)
			append(&list, "roles")
			append(&list, ..args[1:])
			args = list[:]
		}
		os.exit(run_account_command(args))
	}

	// `yap-server purge ...` purges and exits (cli_purge.odin). Nobody
	// is talking then, so a slow checkpoint isn't worth a word.
	if len(os.args) > 1 && os.args[1] == "purge" {
		quiet, quiet_ok := common.init_logging(.error)
		if !quiet_ok {
			os.exit(1)
		}
		context.logger = quiet
		os.exit(run_purge_command(os.args[2:]))
	}

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

	if settings.relay.enabled &&
	   !start_relay(settings.relay.port, settings.port, settings.relay.web_dir) {
		os.exit(1)
	}
	if !run_server(settings) {
		os.exit(1)
	}
}

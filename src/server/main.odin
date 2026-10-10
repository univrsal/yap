package server

import "core:flags"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"

import "common:."
import "common:memtrack"
import "common:proto"

Options :: struct {
	config: string `args:"pos=0" usage:"Config file (default config.json): port, key, password, relay, channels... Created with defaults and a new key if missing. For the accounts, see: yap-server account; to purge old messages: yap-server purge; to try the email config: yap-server email test"`,
}

main :: proc() {
	// Before anything allocates, so that it's all counted (memory.odin).
	context.allocator = memtrack.init()

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

	// `yap-server email test` tries the email config out (cli_email.odin).
	if len(os.args) > 1 && os.args[1] == "email" {
		quiet, quiet_ok := common.init_logging(.warn)
		if !quiet_ok {
			os.exit(1)
		}
		context.logger = quiet
		os.exit(run_email_command(os.args[2:]))
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
	first_run := !os.exists(opt.config)
	bootstrap: Config_Bootstrap
	if first_run {
		bootstrap_ok: bool
		bootstrap, bootstrap_ok = bootstrap_from_env()
		if !bootstrap_ok {
			os.exit(2)
		}
	}
	settings, config_ok := load_config(opt.config, bootstrap)
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
	if !run_server(settings, bootstrap.initial_admin_password) {
		os.exit(1)
	}
}

// bootstrap_from_env reads settings used only while creating a new server.
// Existing server data is never changed from the environment.
bootstrap_from_env :: proc() -> (bootstrap: Config_Bootstrap, ok: bool) {
	if text := os.get_env("YAP_RELAY_ENABLED", context.allocator); text != "" {
		bootstrap.relay_enabled_set = true
		switch text {
		case "true", "1":
			bootstrap.relay_enabled = true
		case "false", "0":
			bootstrap.relay_enabled = false
		case:
			log.errorf("YAP_RELAY_ENABLED must be true, false, 1, or 0")
			return
		}
	}

	if text := os.get_env("YAP_RELAY_PORT", context.allocator); text != "" {
		port, port_ok := strconv.parse_int(text, 10)
		if !port_ok || port <= 0 || port > 65535 {
			log.errorf("YAP_RELAY_PORT must be a port from 1 to 65535")
			return
		}
		bootstrap.relay_port_set = true
		bootstrap.relay_port = port
	}

	if password := os.get_env("YAP_INITIAL_ADMIN_PASSWORD", context.allocator); password != "" {
		if !proto.account_password_ok(password) {
			log.errorf(
				"YAP_INITIAL_ADMIN_PASSWORD must be from %d to %d bytes",
				proto.MIN_ACCOUNT_PASSWORD,
				proto.MAX_ACCOUNT_PASSWORD,
			)
			return
		}
		bootstrap.initial_admin_password = password
	}
	return bootstrap, true
}

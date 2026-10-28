package server

import "core:crypto/ecdh"
import "core:flags"
import "core:log"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"

import "common:."
import "common:memtrack"
import "common:proto"
import "lib:gateway"

Options :: struct {
	config: string `args:"pos=0" usage:"Config file (default config.json): port, key, password, relay, channels... Created with defaults and a new key if missing. For the accounts, see: yap-server account; to purge old messages: yap-server purge; to try the email config: yap-server email test"`,
}

main :: proc() {
	// This must happen before anything allocates so that all allocations
	// are counted (see memory.odin).
	context.allocator = memtrack.init()

	// The commands do their work and exit: `yap-server account ...`
	// (cli_account.odin; `role list` is short for `account roles`), `email
	// test` (cli_email.odin), `push test` (cli_push.odin) and `purge ...`
	// (cli_purge.odin). No clients are connected to a purge, so it logs only
	// errors, and slow checkpoints are not reported.
	Command :: struct {
		name:  string,
		level: common.Log_Level,
		run:   proc(args: []string) -> int,
	}
	commands := [?]Command {
		{"account", .warn, run_account_command},
		{"role", .warn, run_role_command},
		{"email", .warn, run_email_command},
		{"push", .warn, run_push_command},
		{"purge", .error, run_purge_command},
	}
	for c in commands {
		if len(os.args) > 1 && os.args[1] == c.name {
			quiet, quiet_ok := common.init_logging(c.level)
			if !quiet_ok {
				os.exit(1)
			}
			context.logger = quiet
			os.exit(c.run(os.args[2:]))
		}
	}

	opt := Options {
		config = DEFAULT_CONFIG_FILE,
	}
	flags.parse_or_exit(&opt, os.args, .Odin)

	// The config decides how to log, so until it has been read the
	// server logs to the terminal at the default level.
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
	ports, ports_ok := ports_from_env()
	if !ports_ok {
		os.exit(2)
	}
	settings, config_ok := load_config(opt.config, bootstrap, ports)
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

	api: ^gateway.Gateway
	if settings.api.enabled {
		api_ok: bool
		api, api_ok = start_api(settings)
		if !api_ok {
			os.exit(1)
		}
	}
	if (settings.relay.enabled || api != nil) &&
	   !start_relay(
			   settings.relay.port,
			   settings.relay.bind,
			   settings.port,
			   media_port(settings),
			   settings.relay.web_dir,
			   settings.relay.enabled,
			   api,
			   settings.relay.allow_sites,
		   ) {
		os.exit(1)
	}
	if !run_server(settings, bootstrap.initial_admin_password) {
		os.exit(1)
	}
}

// start_api starts the gateway of the bot API (docs/bot-api). To the server
// the gateway is just another client: it connects from this machine and
// refuses to talk to any server that doesn't have this server's key.
start_api :: proc(settings: Settings) -> (^gateway.Gateway, bool) {
	key: ecdh.Private_Key
	defer ecdh.private_key_clear(&key)
	if !common.parse_private_key(settings.key, &key) {
		log.error("the key in the config is not a valid private key")
		return nil, false
	}
	cfg := gateway.Config {
		server          = {net.IP4_Loopback, settings.port},
		password        = settings.password,
		max_connections = settings.api.max_connections,
		rate            = settings.api.rate,
		burst           = settings.api.burst,
		behind_proxy    = settings.api.behind_proxy,
		trusted_proxy   = net.parse_address(settings.api.trusted_proxy),
	}
	ecdh.private_key_public_bytes(&key, cfg.server_key[:])
	return gateway.start(cfg), true
}

// bootstrap_from_env reads the settings that are only used when a new server
// is created. The environment never changes an existing server's data. The
// ports, which it does change, are read by ports_from_env.
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

// ports_from_env reads the ports and the relay's allow_sites, which override
// the config's on every start (see Config_Ports).
ports_from_env :: proc() -> (ports: Config_Ports, ok: bool) {
	env_port :: proc(name: string, port: ^int) -> bool {
		text := os.get_env(name, context.temp_allocator)
		if text == "" {
			return true
		}
		value, value_ok := strconv.parse_int(text, 10)
		if !value_ok || value <= 0 || value > 65535 {
			log.errorf("%s must be a port from 1 to 65535", name)
			return false
		}
		port^ = value
		return true
	}
	env_port("YAP_PORT", &ports.port) or_return
	env_port("YAP_VIDEO_PORT", &ports.video_port) or_return
	env_port("YAP_RELAY_PORT", &ports.relay_port) or_return

	switch os.get_env("YAP_VIDEO_ENABLED", context.temp_allocator) {
	case "":
	case "true", "1":
		ports.video_enabled_set, ports.video_enabled = true, true
	case "false", "0":
		ports.video_enabled_set, ports.video_enabled = true, false
	case:
		log.errorf("YAP_VIDEO_ENABLED must be true, false, 1, or 0")
		return
	}

	// YAP_RELAY_ALLOW_SITES: origins (or *) separated by commas or whitespace.
	// check_config validates them like the config file's.
	if text := os.get_env("YAP_RELAY_ALLOW_SITES", context.allocator); text != "" {
		sites := make([dynamic]string)
		for site in strings.split_multi(text, {",", " ", "\t", "\n"}, context.allocator) {
			if site != "" {
				append(&sites, site)
			}
		}
		ports.allow_sites = sites[:]
	}
	return ports, true
}

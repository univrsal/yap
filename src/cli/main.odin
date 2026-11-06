#+build linux, darwin, freebsd, openbsd, netbsd
package main

import log "common:wlog"
import "core:flags"
import "core:fmt"
import "core:os"

import "client:conn"
import "client:platform"
import "common:."
import "common:memtrack"

// yap-cli: a terminal client for yap. It is a second front end on client/conn,
// next to the window in src/client (see docs/design/cli-client.md).
//
// By default it is a terminal UI (run.odin). With -print it only connects and
// prints the channels it is in (run_print), which needs no terminal.

Options :: struct {
	server:        string `args:"pos=0,required" usage:"Server to connect to, host or host:port (default port 7777)."`,
	key:           string `usage:"Our private key file (default: the same one the window client uses)."`,
	known_servers: string `usage:"File with the servers' keys that were trusted (default: the same one the window client uses)."`,
	password:      string `usage:"The server's password, if it has one."`,
	channel:       string `usage:"Channel to join on connecting."`,
	user:          string `usage:"The account to log in to, if this device isn't logged in yet."`,
	user_password: string `usage:"That account's password."`,
	device:        string `usage:"What to call this device in the account's list (default: your OS user name)."`,
	log_level:     common.Log_Level `usage:"Log level (debug, info, warn, error)."`,
	log_file:      string `usage:"Append the log to this file (default: cli.log in the config folder, unless -print)."`,
	download_dir:  string `usage:"Save files from messages to this folder (default: the downloads folder)."`,
	print:         bool `usage:"No screen: print the channels and what is unread in them, as they change, until Ctrl+C."`,
}

main :: proc() {
	platform.malloc_tune()
	context.allocator = memtrack.init()

	opt := Options {
		log_level = .warn,
	}
	flags.parse_or_exit(&opt, os.args, .Odin)

	// The screen has no room for the log: it goes to a file.
	if !opt.print && opt.log_file == "" {
		opt.log_file = platform.default_config_path("cli.log")
	}
	logger, ok := common.init_logging(opt.log_level, opt.log_file)
	if !ok {
		os.exit(1)
	}
	defer common.destroy_logging(logger)
	context.logger = logger

	if opt.key == "" {
		opt.key = platform.default_config_path("client.key")
	}
	if opt.known_servers == "" {
		opt.known_servers = platform.default_config_path("known_servers")
	}
	if opt.key == "" || opt.known_servers == "" {
		log.error(
			"could not determine the config directory; pass -key:<file> and -known-servers:<file>",
		)
		os.exit(2)
	}
	if opt.device == "" {
		opt.device = platform.default_name()
	}

	ok = run_print(opt) if opt.print else run_ui(opt)
	if !ok {
		os.exit(1)
	}
}

// run_print connects and shows what the view has until Ctrl+C, or the connection fails
// for good.
run_print :: proc(opt: Options) -> bool {
	interrupt_install()
	s := conn.session_new(
		{
			key_path = opt.key,
			server = opt.server,
			password = opt.password,
			known_servers = opt.known_servers,
			channel = opt.channel,
		},
		wake,
	)
	defer conn.session_free(s)
	conn.auth_credentials(s.client, opt.user, opt.user_password, opt.device)
	conn.session_start(s)

	shown: string
	defer delete(shown)
	for !interrupted() {
		text, failed := snapshot(&s.view)
		if text != shown {
			fmt.print(text)
			delete(shown)
			shown = text
		} else {
			delete(text)
		}
		if failed {
			return false
		}
		wait(100)
	}
	return true
}

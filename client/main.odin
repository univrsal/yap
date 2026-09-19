package client

import "core:flags"
import "core:fmt"
import "core:log"
import "core:os"

import "../common"

Options :: struct {
	server:             string `args:"pos=0" usage:"Server to connect to, host:port. Required with -headless; otherwise the UI connects to it right away."`,
	headless:           bool `usage:"No window: log to the terminal and read /join and /channels from stdin."`,
	list_audio_devices: bool `usage:"Print the audio input and output devices, then exit."`,
	tone:               f32 `usage:"With -headless: send a sine tone of this frequency (Hz) as voice and log what is heard. For testing."`,
	input_file:         string `usage:"With -headless: loop this raw 48 kHz mono f32 file as the microphone. For testing."`,
	denoise:            bool `usage:"With -headless: enable noise suppression and the voice gate (the UI has a setting for it)."`,
	channel:            string `usage:"Channel to join after connecting (default: wherever the server puts you)."`,
	name:               string `usage:"With -headless: the name to go by (default: your OS user name). The UI has a field for it."`,
	key:                string `usage:"Private key file, created if missing (default <config dir>/yap/client.key)."`,
	known_servers:      string `usage:"Trusted server keys, filled in on first connect (default <config dir>/yap/known_servers)."`,
	log_level:          common.Log_Level `usage:"Lowest level to log: debug, info, warn, error (default info)."`,
	log_file:           string `usage:"Also append the log to this file."`,
}

main :: proc() {
	opt := Options {
		log_level = .info,
	}
	flags.parse_or_exit(&opt, os.args, .Odin)

	// In the UI, log lines also go to the log panel.
	logs: Log_Lines
	sink: common.Log_Sink
	if !opt.headless {
		sink = {log_lines_sink, &logs}
	}
	logger, ok := common.init_logging(opt.log_level, opt.log_file, sink)
	if !ok {
		os.exit(1)
	}
	defer common.destroy_logging(logger)
	context.logger = logger

	if opt.key == "" {
		opt.key = default_config_path("client.key")
	}
	if opt.known_servers == "" {
		opt.known_servers = default_config_path("known_servers")
	}
	if opt.key == "" || opt.known_servers == "" {
		log.error(
			"could not determine the config directory; pass -key:<file> and -known-servers:<file>",
		)
		os.exit(2)
	}

	if opt.list_audio_devices {
		os.exit(0 if list_audio_devices() else 1)
	}

	if opt.headless {
		if opt.server == "" {
			log.error("-headless needs a server address")
			os.exit(2)
		}
		if !run_headless(
			opt.key,
			opt.server,
			opt.known_servers,
			opt.channel,
			opt.name if opt.name != "" else default_name(),
			opt.tone,
			opt.input_file,
			opt.denoise,
		) {
			os.exit(1)
		}
		return
	}

	ui_ok := run_ui(
		{
			key_path = opt.key,
			known_servers = opt.known_servers,
			server = opt.server,
			channel = opt.channel,
			logs = &logs,
			settings_path = default_config_path("settings.json"),
		},
	)
	if !ui_ok {
		os.exit(1)
	}
}

@(private = "file")
list_audio_devices :: proc() -> bool {
	a: Audio
	defer audio_destroy(&a)
	if !audio_init(&a) {
		return false
	}
	print_list :: proc(title: string, devices: []Audio_Device) {
		fmt.println(title)
		if len(devices) == 0 {
			fmt.println("  (none)")
		}
		for d in devices {
			fmt.printfln("  %s%s", d.name, "  [default]" if d.is_default else "")
		}
	}
	print_list("Input devices:", a.inputs[:])
	print_list("Output devices:", a.outputs[:])
	return true
}

// default_name is the OS user name, as a starting point for the name
// field; "" if there isn't one.
default_name :: proc() -> string {
	for env in ([]string{"USER", "USERNAME", "LOGNAME"}) {
		if name := os.get_env(env, context.temp_allocator); name != "" {
			return name
		}
	}
	return ""
}

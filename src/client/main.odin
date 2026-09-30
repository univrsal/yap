#+build !wasi
package client

import log "common:wlog"
import "core:flags"
import "core:fmt"
import "core:os"

import "common:."
import "client:audio"
import "client:platform"

Options :: struct {
	server:             string `args:"pos=0" usage:"Server to connect to, host or host:port (default port 7777). Required with -headless; otherwise the UI connects to it right away."`,
	headless:           bool `usage:"No window: log to the terminal and read commands (/join, /say, ...) from stdin."`,
	list_audio_devices: bool `usage:"Print the audio input and output devices, then exit."`,
	tone:               f32 `usage:"With -headless: send a sine tone of this frequency (Hz) as voice and log what is heard. For testing."`,
	input_file:         string `usage:"With -headless: loop this raw 48 kHz mono f32 file as the microphone. For testing."`,
	image_dir:          string `usage:"With -headless: save chat images that arrive to this directory."`,
	download_dir:       string `usage:"With -headless: save files accepted in DMs to this directory (default: the downloads folder)."`,
	upload_limit:       f32 `usage:"With -headless: send files in DMs at most this fast, in MB/s (default: no limit). The UI has a setting for it."`,
	download_limit:     f32 `usage:"With -headless: receive files in DMs at most this fast, in MB/s (default: no limit). The UI has a setting for it."`,
	denoise:            bool `usage:"With -headless: enable noise suppression (the UI has a setting for it)."`,
	quality:            string `usage:"With -headless: send quality, voice, high or music (default voice). The UI has a setting for it."`,
	gate:               bool `usage:"With -headless: enable the voice gate, at the default thresholds (the UI has settings for it)."`,
	channel:            string `usage:"Channel to join after connecting (default: wherever the server puts you)."`,
	name:               string `usage:"With -headless: the name to go by (default: your OS user name). The UI has a field for it."`,
	password:           string `usage:"The server's password, if it has one. The UI has a field for it."`,
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
	log.infof("yap %s", common.version_string())

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

	if opt.list_audio_devices {
		os.exit(0 if list_audio_devices() else 1)
	}

	quality := audio.Quality.Voice
	if opt.quality != "" {
		q, known := audio.parse_quality(opt.quality)
		if !known {
			log.errorf("unknown quality %q (voice, high or music)", opt.quality)
			os.exit(2)
		}
		quality = q
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
			opt.name if opt.name != "" else platform.default_name(),
			opt.password,
			opt.tone,
			opt.input_file,
			opt.image_dir,
			opt.download_dir,
			{upload_limit = opt.upload_limit, download_limit = opt.download_limit},
			opt.denoise,
			opt.gate,
			quality,
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
			password = opt.password,
			channel = opt.channel,
			logs = &logs,
			settings_path = platform.default_config_path("settings.json"),
		},
	)
	if !ui_ok {
		os.exit(1)
	}
}

@(private = "file")
list_audio_devices :: proc() -> bool {
	a: audio.Audio
	defer audio.audio_destroy(&a)
	if !audio.audio_init(&a) {
		return false
	}
	print_list :: proc(title: string, devices: []audio.Audio_Device) {
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

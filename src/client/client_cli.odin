#+build !wasi
package client

import log "common:wlog"
import "core:os"
import "core:slice"
import "core:strings"
import "client:audio"
import "client:settings"


// run_headless is the command-line client: commands come from stdin.
// With tone_hz > 0 it "talks" by sending that tone and logs what it hears
// (see Fake_Audio), which exercises the whole voice path without devices.
// input_file (raw 48 kHz mono f32) is looped as the microphone instead.
run_headless :: proc(
	key_path, server_addr, known_servers, initial_channel, name, password: string,
	tone_hz: f32,
	input_file: string,
	image_dir: string,
	download_dir: string,
	limits: settings.Settings, // only the transfer limits are read
	denoise: bool,
	gate: bool,
	quality: audio.Quality,
) -> bool {
	// Heap-allocated: the channel state buffers make it fairly large.
	c := new(Voice_Client)
	defer free(c)
	if !audio.voice_init(&c.voice) {
		return false
	}
	defer audio.voice_destroy(&c.voice)
	c.voice.denoise = denoise
	c.voice.gate.enabled = gate
	c.images.dir = image_dir
	c.files.download_dir = strings.clone(download_dir)
	limits := limits
	lim := transfer_limits_command(&limits)
	c.files.upload_limit, c.files.download_limit = lim.upload, lim.download
	if quality != .Voice && !audio.encoder_setup(&c.voice, quality) {
		return false
	}
	fake: audio.Fake_Audio
	input: []f32
	if input_file != "" {
		data, err := os.read_entire_file(input_file, context.allocator)
		if err != nil || len(data) < size_of(f32) {
			log.errorf("could not read %s: %v", input_file, err)
			return false
		}
		input = slice.reinterpret([]f32, data[:len(data) - len(data) % size_of(f32)])
	}
	defer delete(input)
	if tone_hz > 0 || len(input) > 0 {
		audio.fake_audio_start(&fake, &c.voice, tone_hz, input)
	}
	defer audio.fake_audio_stop(&fake)
	defer client_close(c)
	if !client_open(c, key_path, server_addr, known_servers, name, password) {
		return false
	}

	if initial_channel != "" {
		request_join(c, initial_channel)
	}
	start_command_reader(&c.commands)

	for client_step(c) {}
	return false
}

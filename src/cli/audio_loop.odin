#+build linux, darwin, freebsd, openbsd, netbsd
package main

import "core:strings"
import "core:sync"

import "client:audio"
import "client:conn"

// The audio devices, which belong to the program and not to a screen: they are
// opened while a connection is in a voice room or a call and closed when it is
// not, so a client that only chats never touches the sound system. If there is no
// sound system, voice and calls still work as far as the server is concerned
// (others hear nothing from us, and we nothing from them) and the settings say why.

Audio_Host :: struct {
	audio:   audio.Audio,
	tried:   bool, // an attempt to start the audio system was made
	ok:      bool,
	// For testing without a sound system: a sine tone of this many Hz is the
	// microphone, and what is played is only counted (see audio.Fake_Audio).
	tone_hz: f32,
}

audio_host_destroy :: proc(h: ^Audio_Host) {
	if h.ok {
		audio.audio_destroy(&h.audio)
	}
}

// audio_host_ensure starts the audio system the first time it is needed.
@(private = "file")
audio_host_ensure :: proc(a: ^App, h: ^Audio_Host) -> bool {
	if !h.tried {
		h.tried = true
		h.ok = audio.audio_init(&h.audio)
		if !h.ok {
			delete(a.audio_error)
			a.audio_error = strings.clone(
				h.audio.error if h.audio.error != "" else "No audio system could be started.",
			)
		}
	}
	return h.ok
}

// service_audio opens and closes the devices as connections go into and out of
// voice, lists the devices for the settings, and moves to new ones when they were
// changed there. It is called every turn of the loop, with no View locked.
service_audio :: proc(a: ^App, h: ^Audio_Host) {
	if a.want_devices {
		a.want_devices = false
		if audio_host_ensure(a, h) {
			audio.audio_refresh(&h.audio)
			fill_names(&a.input_devices, h.audio.inputs[:])
			fill_names(&a.output_devices, h.audio.outputs[:])
		}
	}
	for s in a.servers {
		if s.session == nil {
			continue
		}
		sync.mutex_lock(&s.view.mutex)
		want := in_voice(s.view)
		sync.mutex_unlock(&s.view.mutex)
		switch {
		case h.tone_hz > 0:
			if want && !s.audio_on {
				audio.fake_audio_start(&s.fake, &s.client.voice, h.tone_hz)
				s.audio_on = true
			} else if !want && s.audio_on {
				audio.fake_audio_stop(&s.fake)
				s.audio_on = false
			}
		case want && !s.audio_on:
			if !audio_host_ensure(a, h) {
				continue
			}
			audio.audio_refresh(&h.audio)
			audio.open_playback(
				&h.audio,
				&s.streams,
				&s.client.voice,
				a.voice_settings.output_device,
			)
			audio.open_capture(
				&h.audio,
				&s.streams,
				&s.client.voice,
				a.voice_settings.input_device,
			)
			s.audio_on = true
		case !want && s.audio_on:
			audio.close_streams(&s.streams, &s.client.voice)
			s.audio_on = false
		case want && a.devices_changed && h.ok:
			audio.open_playback(
				&h.audio,
				&s.streams,
				&s.client.voice,
				a.voice_settings.output_device,
			)
			audio.open_capture(
				&h.audio,
				&s.streams,
				&s.client.voice,
				a.voice_settings.input_device,
			)
		}
	}
	a.devices_changed = false
}

// stop_audio closes what a connection has open, before it goes.
stop_audio :: proc(s: ^Server) {
	if s.audio_on && s.client != nil {
		audio.fake_audio_stop(&s.fake) // (does nothing if it was not started)
		audio.close_streams(&s.streams, &s.client.voice)
		s.audio_on = false
	}
}

@(private = "file")
fill_names :: proc(names: ^[dynamic]string, devices: []audio.Audio_Device) {
	for n in names {
		delete(n)
	}
	clear(names)
	for d in devices {
		append(names, strings.clone(d.name))
	}
}

// start_voice tells a new connection how the user wants to sound and hear.
start_voice :: proc(a: ^App, c: ^conn.Server_Conn) {
	apply_voice_settings(c, a.voice_settings)
	if a.muted {
		conn.push_command(&c.commands, conn.Mute_Command{muted = true})
	}
	if a.deafened {
		conn.push_command(&c.commands, conn.Deafen_Command{deafened = true})
	}
}

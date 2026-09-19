package client

import "core:log"
import "core:strings"

import ma "miniaudio"

/*
Audio device discovery, through our trimmed-down miniaudio (see
miniaudio/yap_audio.c). It picks the platform's backend itself: WASAPI on
Windows; PulseAudio (which PipeWire provides) or ALSA on Linux, loaded at
runtime, so there's nothing extra to link or ship.

The context lives for the whole run: devices are opened through it, and
device ids are only meaningful to the context that listed them.
*/

Audio_Device :: struct {
	name:       string, // owned
	is_default: bool,   // the system's current default
	id:         ma.Device_Id,
}

Audio :: struct {
	ctx:     ^ma.Context, // nil if audio is unavailable
	backend: string,
	error:   string, // why audio is unavailable, for the UI
	inputs:  [dynamic]Audio_Device,
	outputs: [dynamic]Audio_Device,
}

audio_init :: proc(a: ^Audio) -> bool {
	res: ma.Result
	a.ctx = ma.create(&res)
	if a.ctx == nil {
		log.errorf("audio: could not initialize any audio backend: %s", ma.result_string(res))
		a.error = "No audio backend could be initialized."
		return false
	}
	a.backend = string(ma.backend_name(a.ctx))
	log.infof("audio: using %s", a.backend)
	return audio_refresh(a)
}

audio_destroy :: proc(a: ^Audio) {
	clear_devices(&a.inputs)
	clear_devices(&a.outputs)
	delete(a.inputs)
	delete(a.outputs)
	if a.ctx != nil {
		ma.destroy(a.ctx)
		a.ctx = nil
	}
}

// audio_refresh re-lists the devices, e.g. after something was plugged in.
audio_refresh :: proc(a: ^Audio) -> bool {
	if a.ctx == nil {
		return false
	}
	clear_devices(&a.inputs)
	clear_devices(&a.outputs)

	if res := ma.refresh(a.ctx); res != ma.SUCCESS {
		log.errorf("audio: could not list devices: %s", ma.result_string(res))
		return false
	}
	copy_devices(a, .Capture, &a.inputs)
	copy_devices(a, .Playback, &a.outputs)
	log.debugf("audio: %d input and %d output devices", len(a.inputs), len(a.outputs))
	return true
}

// find_device returns the device called `name`, or nil if there's none
// (or `name` is "", meaning the system default).
find_device :: proc(devices: []Audio_Device, name: string) -> ^Audio_Device {
	if name == "" {
		return nil
	}
	for &d in devices {
		if d.name == name {
			return &d
		}
	}
	return nil
}

@(private = "file")
copy_devices :: proc(a: ^Audio, dir: ma.Direction, dst: ^[dynamic]Audio_Device) {
	for i in 0 ..< ma.device_count(a.ctx, dir) {
		name: [ma.NAME_SIZE]u8
		is_default: i32
		d: Audio_Device
		if ma.device_info(a.ctx, dir, i, &name, &is_default, &d.id) != ma.SUCCESS {
			continue
		}
		d.name = strings.clone_from_cstring(cstring(&name[0]))
		d.is_default = is_default != 0
		append(dst, d)
	}
}

@(private = "file")
clear_devices :: proc(devices: ^[dynamic]Audio_Device) {
	for d in devices {
		delete(d.name)
	}
	clear(devices)
}

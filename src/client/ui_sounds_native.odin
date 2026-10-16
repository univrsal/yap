#+build !wasi
package client

import log "common:wlog"
import "core:bytes"
import "core:fmt"
import "core:os"
import "core:strings"

import "client:audio"
import "client:settings"
import "common:proto"

// Sound files of the user's own on a desktop: copied into the "sounds" folder
// next to settings.json (see ui_sounds.odin).

@(private = "file")
sounds_dir :: proc(ui: ^UI) -> string {
	dir, _ := os.split_path(ui.opts.settings_path)
	path, _ := os.join_path({dir, "sounds"}, context.temp_allocator)
	return path
}

// sounds_load decodes the files of the user's own that the settings name, at
// start.
sounds_load :: proc(ui: ^UI) {
	for kind in audio.Sound_Event {
		name := settings.sound_name(&ui.settings, kind)
		if !strings.has_prefix(name, audio.CUSTOM_SOUND_PREFIX) ||
		   audio.sound_custom_loaded(name) {
			continue
		}
		file := name[len(audio.CUSTOM_SOUND_PREFIX):]
		path, _ := os.join_path({sounds_dir(ui), file}, context.temp_allocator)
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil {
			log.warnf("sounds: can't read %s: %v", path, err)
			sound_note(ui, kind, fmt.tprintf("%s is gone, so the default sound plays.", file))
			continue
		}
		samples, channels, why := audio.sound_decode(data, file)
		if why != "" {
			log.warnf("sounds: %s: %s", path, why)
			sound_note(
				ui,
				kind,
				fmt.tprintf("%s can't be played (%s), so the default sound plays.", file, why),
			)
			continue
		}
		audio.sound_custom_add(name, samples, channels)
		delete(samples)
	}
}

// sound_file_picked takes the file picked for an event: if it can be played,
// it is copied and chosen.
sound_file_picked :: proc(ui: ^UI, kind: audio.Sound_Event, path: string) {
	info, err := os.stat(path, context.temp_allocator)
	switch {
	case err != nil:
		sound_note(ui, kind, fmt.tprintf("%s can't be read.", path))
		return
	case info.size > audio.SOUND_FILE_MAX:
		sound_note(
			ui,
			kind,
			fmt.tprintf(
				"That file is too big: a sound can be at most %d MB.",
				audio.SOUND_FILE_MAX / (1024 * 1024),
			),
		)
		return
	}
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		sound_note(ui, kind, fmt.tprintf("%s can't be read.", path))
		return
	}
	samples, channels, why := audio.sound_decode(data, path)
	if why != "" {
		sound_note(ui, kind, fmt.tprintf("That file can't be played (%s).", why))
		return
	}
	defer delete(samples)
	file := sound_file_store(ui, os.base(path), data)
	if file == "" {
		sound_note(ui, kind, "That file couldn't be copied to the settings folder.")
		return
	}
	name := strings.concatenate({audio.CUSTOM_SOUND_PREFIX, file}, context.temp_allocator)
	audio.sound_custom_add(name, samples, channels)
	sound_choose(ui, kind, name)
}

// sound_file_store copies a file into the sounds folder under a name of its
// own, and returns that name ("" if it couldn't). A file of the same name
// with the same contents is the same file.
@(private = "file")
sound_file_store :: proc(ui: ^UI, name: string, data: []u8) -> string {
	dir := sounds_dir(ui)
	if err := os.make_directory_all(dir); err != nil && !os.exists(dir) {
		log.errorf("sounds: can't make %s: %v", dir, err)
		return ""
	}
	buf: [proto.MAX_FILE_NAME]u8
	clean := proto.sanitize_file_name(name, &buf)
	if clean == "" {
		clean = "sound"
	}
	clean = sound_file_name_fit(clean)
	stem, ext := os.split_filename(clean)
	dotted := "" if ext == "" else strings.concatenate({".", ext}, context.temp_allocator)
	for n in 1 ..= 100 {
		file := clean
		if n > 1 {
			file = sound_file_name_fit(fmt.tprintf("%s-%d%s", stem, n, dotted))
		}
		path, _ := os.join_path({dir, file}, context.temp_allocator)
		if os.exists(path) {
			old, err := os.read_entire_file(path, context.temp_allocator)
			if err == nil && bytes.equal(old, data) {
				return strings.clone(file, context.temp_allocator)
			}
			continue
		}
		if err := os.write_entire_file(path, data); err != nil {
			log.errorf("sounds: can't write %s: %v", path, err)
			return ""
		}
		return strings.clone(file, context.temp_allocator)
	}
	return ""
}

// sound_file_delete deletes a copy that no event plays any more.
sound_file_delete :: proc(ui: ^UI, file: string) {
	path, _ := os.join_path({sounds_dir(ui), file}, context.temp_allocator)
	if err := os.remove(path); err != nil {
		log.warnf("sounds: can't delete %s: %v", path, err)
	}
}

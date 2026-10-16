#+build wasi
package client

import log "common:wlog"
import "core:fmt"
import "core:strings"

import "client:audio"
import "client:platform"
import "client:settings"

// Sound files of the user's own in a browser (see ui_sounds.odin): the page
// decodes them and keeps them in its storage (web/sounds.js), and hands the
// samples over. Loading them at start takes a moment; until a file is in,
// its events play their default sounds, and the sessions are told again once
// it is (web_sound_loaded).

@(default_calling_convention = "c")
foreign _ {
	// See web/shell.c.
	yap_sound_pick :: proc(kind: i32) ---
	yap_sound_load :: proc(name: cstring) ---
	yap_sound_remove :: proc(name: cstring) ---
}

// sounds_load asks the page for the files of the user's own that the
// settings name.
sounds_load :: proc(ui: ^UI) {
	asked := make([dynamic]string, context.temp_allocator)
	for kind in audio.Sound_Event {
		name := settings.sound_name(&ui.settings, kind)
		if !strings.has_prefix(name, audio.CUSTOM_SOUND_PREFIX) || audio.sound_custom_loaded(name) {
			continue
		}
		file := name[len(audio.CUSTOM_SOUND_PREFIX):]
		already := false
		for a in asked {
			already ||= a == file
		}
		if !already {
			append(&asked, file)
			yap_sound_load(strings.clone_to_cstring(file, context.temp_allocator))
		}
	}
}

// sound_pick_start opens the page's file input, for an event's sound.
sound_pick_start :: proc(ui: ^UI, kind: audio.Sound_Event) {
	yap_sound_pick(i32(kind))
}

// sound_file_delete forgets a file no event plays any more.
sound_file_delete :: proc(ui: ^UI, file: string) {
	yap_sound_remove(strings.clone_to_cstring(file, context.temp_allocator))
}

// A file was picked for an event, decoded and kept under `name`. The
// samples (`channels` interleaved) are copied (sound_custom_add).
@(export)
web_sound_picked :: proc "c" (
	kind: i32,
	name: [^]u8,
	name_len: i32,
	samples: [^]f32,
	frames: i32,
	channels: i32,
) {
	context = platform.callback_context()
	if g_ui == nil || kind <= 0 || kind > i32(max(audio.Sound_Event)) {
		return
	}
	full := strings.concatenate(
		{audio.CUSTOM_SOUND_PREFIX, string(name[:name_len])},
		context.temp_allocator,
	)
	audio.sound_custom_add(full, samples[:frames * channels], int(channels))
	sound_choose(g_ui, audio.Sound_Event(kind), full)
	ui_wake()
}

// A file picked for an event won't do, and `why`.
@(export)
web_sound_failed :: proc "c" (kind: i32, why: [^]u8, why_len: i32) {
	context = platform.callback_context()
	if g_ui == nil || kind <= 0 || kind > i32(max(audio.Sound_Event)) {
		return
	}
	sound_note(g_ui, audio.Sound_Event(kind), string(why[:why_len]))
	ui_wake()
}

// A file the settings name is decoded: its events play it from now on.
@(export)
web_sound_loaded :: proc "c" (
	name: [^]u8,
	name_len: i32,
	samples: [^]f32,
	frames: i32,
	channels: i32,
) {
	context = platform.callback_context()
	if g_ui == nil {
		return
	}
	full := strings.concatenate(
		{audio.CUSTOM_SOUND_PREFIX, string(name[:name_len])},
		context.temp_allocator,
	)
	audio.sound_custom_add(full, samples[:frames * channels], int(channels))
	sounds_send_all(g_ui)
	ui_wake()
}

// A file the settings name isn't in the page's storage, or doesn't decode.
@(export)
web_sound_missing :: proc "c" (name: [^]u8, name_len: i32, why: [^]u8, why_len: i32) {
	context = platform.callback_context()
	if g_ui == nil {
		return
	}
	file := string(name[:name_len])
	log.warnf("sounds: %s %s", file, string(why[:why_len]))
	full := strings.concatenate({audio.CUSTOM_SOUND_PREFIX, file}, context.temp_allocator)
	for kind in audio.Sound_Event {
		if settings.sound_name(&g_ui.settings, kind) == full {
			sound_note(
				g_ui,
				kind,
				fmt.tprintf("%s %s, so the default sound plays.", file, string(why[:why_len])),
			)
		}
	}
	ui_wake()
}

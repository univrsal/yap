package client

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:unicode/utf8"
import mu "vendor:microui"

import "client:audio"
import "client:conn"
import "client:platform"
import "client:settings"
import "common:proto"

// The Sounds page: which sound each event plays (see audio/sound_packs.odin),
// from a dropdown with the built-in packs, no sound, and a file of the user's
// own; presets that set them all at once; and the volume.
//
// A file of the user's own is copied, so that moving or deleting the original
// doesn't take the sound away: into the config folder's "sounds" folder on a
// desktop (ui_sounds_native.odin), into the browser's storage on the web
// (ui_sounds_web.odin). It is decoded once it is picked and at start, and
// handed to the sound store (audio/sound_store.odin) by its name in the
// settings, "custom:<file>". Until it is, or if it can't be, the event plays
// its default sound.

Sounds_UI :: struct {
	// What is wrong with an event's file, if anything (owned).
	notes: [audio.Sound_Event]string,
}

// The longest name of a file of one's own, so that its sound's name fits in a
// conn.Sound_Command.
SOUND_FILE_NAME_MAX :: 64

// How wide the button that plays a sound is.
@(private = "file")
PLAY_WIDTH :: 30

// The dropdown's item that opens the file dialog.
@(private = "file")
PICK_FILE :: "?pick"

// The headings on the page, over the first event of each group.
@(private = "file")
SOUND_HEADINGS := #partial [audio.Sound_Event]string {
	.Message = "Messages",
	.Join    = "Voice",
	.Ring    = "Calls",
	.Welcome = "The client",
}

// sound_effective returns the sound an event plays now: the user's choice,
// unless that is a file of their own that isn't loaded (yet), which plays the
// default instead.
sound_effective :: proc(ui: ^UI, kind: audio.Sound_Event) -> string {
	name := settings.sound_name(&ui.settings, kind)
	if strings.has_prefix(name, audio.CUSTOM_SOUND_PREFIX) && !audio.sound_custom_loaded(name) {
		return audio.DEFAULT_SOUNDS[kind]
	}
	return name
}

// sounds_session_init gives a new session's Voice the sounds, before its
// thread starts.
sounds_session_init :: proc(ui: ^UI, ns: ^Net_Session) {
	for kind in audio.Sound_Event {
		if kind != .None && kind not_in audio.APP_SOUNDS {
			audio.notifications_set(
				&ns.client.voice.notifications,
				kind,
				sound_effective(ui, kind),
			)
		}
	}
}

// sounds_send_all tells every session the sound of every event.
sounds_send_all :: proc(ui: ^UI) {
	for kind in audio.Sound_Event {
		if kind != .None && kind not_in audio.APP_SOUNDS {
			command_all(ui, conn.sound_command(kind, sound_effective(ui, kind)))
		}
	}
}

// sound_choose gives an event a sound ("" for none), and plays it.
sound_choose :: proc(ui: ^UI, kind: audio.Sound_Event, name: string) {
	old := strings.clone(settings.sound_name(&ui.settings, kind), context.temp_allocator)
	settings.set_sound_name(&ui.settings, kind, name)
	save_settings(ui)
	sound_note(ui, kind, "")
	now := sound_effective(ui, kind)
	if kind not_in audio.APP_SOUNDS {
		command_all(ui, conn.sound_command(kind, now))
	}
	sound_forget_unused(ui, old)
	app_sound_preview(ui, now)
}

// sound_preset_choose applies a preset (audio.SOUND_PRESETS).
@(private = "file")
sound_preset_choose :: proc(ui: ^UI, preset: audio.Sound_Preset) {
	before: [audio.Sound_Event]string
	for &name, kind in before {
		name = strings.clone(settings.sound_name(&ui.settings, kind), context.temp_allocator)
	}
	settings.sound_preset_use(&ui.settings, preset)
	save_settings(ui)
	for kind in audio.Sound_Event {
		sound_note(ui, kind, "")
	}
	sounds_send_all(ui)
	for name in before {
		sound_forget_unused(ui, name)
	}
}

// sound_forget_unused lets go of a file of the user's own that no event plays
// any more, and deletes the copy.
@(private = "file")
sound_forget_unused :: proc(ui: ^UI, name: string) {
	if !strings.has_prefix(name, audio.CUSTOM_SOUND_PREFIX) ||
	   settings.sound_in_use(&ui.settings, name) {
		return
	}
	audio.sound_custom_remove(name)
	sound_file_delete(ui, name[len(audio.CUSTOM_SOUND_PREFIX):])
}

// sound_note sets what is wrong with an event's file ("" for nothing).
sound_note :: proc(ui: ^UI, kind: audio.Sound_Event, note: string) {
	delete(ui.sounds.notes[kind])
	ui.sounds.notes[kind] = strings.clone(note) if note != "" else ""
}

sounds_destroy :: proc(ui: ^UI) {
	for &note in ui.sounds.notes {
		delete(note)
		note = ""
	}
}

// sound_file_name_fit makes a file's name short enough for a sound's name
// (SOUND_FILE_NAME_MAX), keeping its extension. The result is in the temp
// allocator.
sound_file_name_fit :: proc(name: string) -> string {
	if len(name) <= SOUND_FILE_NAME_MAX {
		return name
	}
	dot := strings.last_index_byte(name, '.')
	ext := name[dot:] if dot > 0 && len(name) - dot <= 8 else ""
	stem := name[:len(name) - len(ext)]
	cut := SOUND_FILE_NAME_MAX - len(ext)
	for cut > 0 && !utf8.rune_start(stem[cut]) {
		cut -= 1
	}
	return strings.concatenate({stem[:cut], ext}, context.temp_allocator)
}

// sounds_frame tells each session whether our voice is busy on another
// server, for its calls to knock instead of ring (conn/sounds.odin), and
// whether we are talking on another server, for the server to show it to the
// people there. Talking is only told between servers that share our status
// (status_shared).
sounds_frame :: proc(ui: ^UI) {
	busy_count := 0
	for ns in ui.sessions {
		ns.voice_busy = in_voice(ns)
		if ns.voice_busy {
			busy_count += 1
		}
		ns.talking, ns.status_shared = talking_in(ns)
	}
	for ns in ui.sessions {
		elsewhere := busy_count > (1 if ns.voice_busy else 0)
		talking: proto.User_Flags
		if ns.status_shared {
			for other in ui.sessions {
				if other != ns && other.status_shared {
					talking += other.talking
				}
			}
		}
		if elsewhere != ns.voice_elsewhere || talking != ns.talking_told {
			ns.voice_elsewhere, ns.talking_told = elsewhere, talking
			conn.push_command(
				&ns.client.commands,
				conn.Voice_Elsewhere_Command{busy = elsewhere, talking = talking},
			)
		}
	}
}

// talking_in returns In_Voice or In_Call if we are talking in a voice room or
// a call on the session's server, as its own state says rather than the
// flags the server shows for us, which include talking elsewhere, and
// whether the server shares our status (status_shared).
@(private = "file")
talking_in :: proc(ns: ^Net_Session) -> (talking: proto.User_Flags, shared: bool) {
	v := &ns.view
	sync.guard(&v.mutex)
	shared = status_shared(v)
	switch {
	case ns.joining || v.status != .Connected || v.my_room == 0:
	case proto.room_call(proto.Room(v.my_room)) != 0:
		talking = {.In_Call}
	case:
		talking = {.In_Voice}
	}
	return
}

// sound_settings is the client's Sounds category.
sound_settings :: proc(ui: ^UI) {
	ctx := &ui.ctx

	volume := settings.notification_gain(&ui.settings) * 100
	field_row(ui, 150, "Volume", {-1})
	if .CHANGE in mu.slider(ctx, &volume, 0, settings.MAX_USER_VOLUME * 100, 5, "%.0f%%") {
		ui.settings.notification_volume = volume / 100
		ui.settings_dirty = true
		command_all(ui, conn.Notification_Volume_Command{ui.settings.notification_volume})
	}

	widths := make([]i32, len(audio.SOUND_PRESETS), context.temp_allocator)
	for &w in widths {
		w = 80
	}
	field_row(ui, 150, "Presets", widths)
	for preset, i in audio.SOUND_PRESETS {
		if .SUBMIT in
		   stable_button(ctx, fmt.tprintf("sound preset %d", i), preset.label, {.ALIGN_CENTER}) {
			sound_preset_choose(ui, preset)
		}
	}

	for kind in audio.Sound_Event {
		if kind == .None {
			continue
		}
		when platform.WEB {
			// A page makes no sound before it is clicked, and has no quitting
			// to wait for (ui_app_sounds.odin).
			if kind == .Welcome || kind == .Goodbye {
				continue
			}
		}
		if heading := SOUND_HEADINGS[kind]; heading != "" {
			mu.layout_row(ctx, {-1})
			mu.label(ctx, "")
			mu.layout_row(ctx, {-1})
			dim_label(ctx, heading)
		}
		info := audio.SOUND_EVENTS[kind]
		// The dropdown takes what the play button leaves.
		field_row(ui, 150, info.label, {-(PLAY_WIDTH + ctx.style.spacing), -1})
		items, names, current, label := sound_choices(ui, kind)
		if i, picked := dropdown(ui, fmt.tprintf("sound %s", info.key), label, items, current);
		   picked {
			if names[i] == PICK_FILE {
				sound_pick_start(ui, kind)
			} else {
				sound_choose(ui, kind, names[i])
			}
		}
		if .SUBMIT in
		   stable_button(ctx, fmt.tprintf("try sound %s", info.key), "⏵", {.ALIGN_CENTER}) {
			app_sound_preview(ui, sound_effective(ui, kind))
		}
		if note := ui.sounds.notes[kind]; note != "" {
			mu.layout_row(ctx, {-1})
			with_text_color(ctx, theme.warning, note, wrap_text)
		}
	}
}

// sound_choices returns an event's dropdown: no sound, the packs' sounds,
// the file of the user's own that it plays (if it does), and the item that
// opens the file dialog. `names` are the sounds' names, `current` is the
// sound the event plays and `button` what its dropdown shows. All of it is in
// the temp allocator.
@(private = "file")
sound_choices :: proc(
	ui: ^UI,
	kind: audio.Sound_Event,
) -> (
	items: []Dropdown_Item,
	names: []string,
	current: int,
	button: string,
) {
	its := make([dynamic]Dropdown_Item, context.temp_allocator)
	all := make([dynamic]string, context.temp_allocator)
	chosen := settings.sound_name(&ui.settings, kind)
	current = -1
	add :: proc(
		its: ^[dynamic]Dropdown_Item,
		all: ^[dynamic]string,
		item: Dropdown_Item,
		name: string,
	) {
		append(its, item)
		append(all, name)
	}
	add(&its, &all, {label = "No sound"}, "")
	for pack in audio.SOUND_PACKS {
		add(&its, &all, {label = pack.label, header = true}, "")
		for f in pack.files {
			file := strings.trim_suffix(f.name, ".opus")
			name := strings.concatenate({pack.name, "/", file}, context.temp_allocator)
			label, _ := strings.replace_all(file, "_", " ", context.temp_allocator)
			add(&its, &all, {label = label}, name)
		}
	}
	if strings.has_prefix(chosen, audio.CUSTOM_SOUND_PREFIX) {
		add(&its, &all, {label = "Your own", header = true}, "")
		add(&its, &all, {label = chosen[len(audio.CUSTOM_SOUND_PREFIX):]}, chosen)
	}
	add(&its, &all, {label = "Choose a file…"}, PICK_FILE)
	for name, i in all {
		if name == chosen && !its[i].header {
			current = i
			break
		}
	}
	// The button shows the pack too, which the list has in its headings.
	switch {
	case current < 0 || chosen == "":
		button = "No sound"
	case strings.has_prefix(chosen, audio.CUSTOM_SOUND_PREFIX):
		button = its[current].label
	case:
		button = audio.sound_label(chosen)
	}
	return its[:], all[:], current, button
}

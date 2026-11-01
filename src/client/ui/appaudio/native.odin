#+build !wasi
package appaudio

import "client:ui/core"
import "client:ui/widgets"
import log "common:wlog"
import "core:os"
import "core:strings"
import "core:sync"
import mu "vendor:microui"

import "client:audio"
import "client:audio/aac"
import "client:conn"
import "client:settings"
import "client:video"

// Sharing an application's audio with the channel, next to the
// microphone (native clients; see audio/aac/aac.odin for which systems
// support it).
//
// The header's button opens a menu of the applications that are playing audio.
// Picking one captures it (on tinyaac's thread) into the Voice's app ring,
// converted to 48 kHz stereo on the way (see audio/app_audio_native.odin). The
// network thread mixes it into every frame it sends, after noise
// suppression and the voice gate, which only ever see the microphone (see
// capture_frame in audio/voice.odin). Muting the microphone also mutes the
// application, unless the settings say otherwise
// (mute_app_audio_with_mic). In that case it keeps being heard until the share
// is stopped.
//
// Like the audio devices, the capture belongs to the UI thread and to one
// connection: disconnecting stops it.
//
// A screen share can bring a playback device's audio along (the share
// menu's choice, settings.share_audio; see share_audio_choice). That is
// everything the device plays except our own sound, shared the same way and
// in place of an application. It ends with the screen share, and picking
// an application instead ends it.

@(private = "file")
MENU_NAME :: "app audio"
// As wide as the user menu.
@(private = "file")
MENU_WIDTH :: 240

State :: struct {
	hooks:     Hooks,
	available: bool, // tinyaac came up
	share:     ^audio.App_Share, // nil while nothing is shared
	owner:     rawptr, // the session whose voice it goes into (Target.owner)
	name:      string, // what's being shared; owned
	device:    bool, // the share is a playback device's, along with the screen
	// The menu's applications, as they were when it was opened.
	list:      ^aac.App_List,
	requested: bool, // open the menu (see user_menu for why it's deferred)
	volume:    mu.Real, // the menu's slider, percent
	error:     string, // why the last share didn't start; owned
	// The share menu's playback devices, as they were when it was opened.
	devices:   ^aac.App_List,
}

init :: proc(a: ^State, hooks: Hooks) {
	a.hooks = hooks
	if aac.init() != .Ok {
		why := string(aac.last_error())
		if why == "" {
			why = "libpipewire-0.3 could not be loaded" // the one failure that has nothing more to say
		}
		log.infof("app audio: unavailable: %s", why)
		return
	}
	a.available = true
}

destroy :: proc(a: ^State) {
	stop(a)
	if a.list != nil {
		aac.app_list_destroy(a.list)
		a.list = nil
	}
	if a.devices != nil {
		aac.app_list_destroy(a.devices)
		a.devices = nil
	}
	delete(a.error)
	a.error = ""
	if a.available {
		aac.shutdown()
		a.available = false
	}
}

available :: proc(a: ^State) -> bool {
	return a.available
}

// app_audio_on is whether an application's audio is being shared.
on :: proc(a: ^State) -> bool {
	return a.share != nil
}

// app_audio_setting is whether the settings show how shared audio is sent.
setting :: proc(a: ^State) -> bool {
	return a.available
}

// app_audio_frame ends a share whose application has gone away, and a
// device's share whose screen share has ended.
frame :: proc(env: ^core.Env, a: ^State) {
	s := a.share
	if s == nil {
		return
	}
	if audio.app_share_ended(s) {
		log.infof("app audio: %s stopped: %s", a.name, cstring(&s.why[0]))
		stop(a)
		core.redraw_now(env)
	} else if state := video.share_state(); a.device && state != .Starting && state != .Live {
		stop(a)
		core.redraw_now(env)
	}
}

// app_audio_stop stops sharing, if anything is shared.
// app_audio_session_gone stops sharing into a session about to be freed.
session_gone :: proc(a: ^State, owner: rawptr) {
	if a.owner == owner {
		stop(a)
	}
}

stop :: proc(a: ^State) {
	s := a.share
	if s == nil {
		return
	}
	audio.app_share_stop(s)
	a.share, a.owner, a.device = nil, nil, false
	log.infof("app audio: stopped sharing %s", a.name)
	delete(a.name)
	a.name = ""
}

// app_audio_button opens the menu. It is green while something is shared.
button :: proc(env: ^core.Env, a: ^State) {
	hint := "Share an application's audio"
	color := mu.Color{}
	if a.share != nil {
		hint = strings.concatenate(
			{"Sharing the audio of ", a.name, " (with your screen)" if a.device else ""},
			context.temp_allocator,
		)
		color = core.theme.speaking
	}
	if .SUBMIT in widgets.icon_button(env, "app audio", .App_Audio, hint, color) {
		refresh(a)
		a.volume = settings.app_audio_gain(&env.settings) * 100
		a.requested = true
	}
}

// app_audio_menu shows the menu while it is open: what is shared, how
// loud it is, and the applications to pick from.
menu :: proc(env: ^core.Env, a: ^State) {
	ctx := &env.ctx
	if a.requested {
		a.requested = false
		mu.open_popup(ctx, MENU_NAME)
	}
	if cnt := mu.get_container(ctx, MENU_NAME, {.CLOSED}); cnt != nil && cnt.open {
		w, h := i32(env.metrics.logical_w), i32(env.metrics.logical_h)
		cnt.rect.x = clamp(cnt.rect.x, 0, max(w - cnt.rect.w, 0))
		cnt.rect.y = clamp(cnt.rect.y, 0, max(h - cnt.rect.h, 0))
	}
	if !core.begin_popup(env, MENU_NAME) {
		return
	}
	defer mu.end_popup(ctx)

	if a.share != nil {
		mu.layout_row(ctx, {MENU_WIDTH})
		mu.label(ctx, strings.concatenate({"Sharing ", a.name}, context.temp_allocator))
		mu.layout_row(ctx, {MENU_WIDTH})
		if .SUBMIT in widgets.stable_button(ctx, "stop", "Stop sharing") {
			stop(a)
		}
	}

	mu.layout_row(ctx, {60, MENU_WIDTH - 60 - ctx.style.spacing})
	mu.label(ctx, "Volume")
	if .CHANGE in widgets.slider(ctx, &a.volume, 0, settings.MAX_USER_VOLUME * 100, 5, "%.0f%%") {
		env.settings.app_audio_volume = a.volume / 100
		env.settings_dirty = true
		a.hooks.send_all(a.hooks.user, conn.app_audio_command(&env.settings))
	}

	mu.layout_row(ctx, {MENU_WIDTH})
	widgets.dim_label(ctx, "Share the audio of:")
	// Not ourselves, because everyone would hear themselves back.
	me := u32(os.get_pid())
	count := 0
	if a.list != nil {
		for i in 0 ..< aac.app_list_count(a.list) {
			if aac.app_list_get(a.list, i).process_id != me {
				count += 1
			}
		}
	}
	if count > 0 {
		widgets.menu_list_begin(env, "apps", MENU_WIDTH, count)
		menu := mu.get_container(ctx, MENU_NAME)
		for i in 0 ..< aac.app_list_count(a.list) {
			app := aac.app_list_get(a.list, i)
			if app.process_id == me {
				continue
			}
			name := app_label(app)
			mu.push_id(ctx, uintptr(i))
			mu.layout_row(ctx, {-1})
			if .SUBMIT in widgets.stable_button(ctx, "app", name) {
				start(env, a, i, name)
				menu.open = false
			}
			mu.pop_id(ctx)
		}
		mu.end_panel(ctx)
	} else {
		mu.layout_row(ctx, {MENU_WIDTH})
		widgets.dim_label(ctx, "Nothing is playing audio.")
	}
	mu.layout_row(ctx, {MENU_WIDTH})
	if .SUBMIT in widgets.stable_button(ctx, "refresh", "Refresh") {
		refresh(a)
	}
	if a.error != "" {
		mu.layout_row(ctx, {MENU_WIDTH})
		widgets.with_text_color(ctx, core.theme.off, a.error, widgets.label_proc)
	}
}

// app_label is what the menu calls an application: its name and, after it,
// what it says it is playing, where that tells two applications apart. For example
// mpv's title ("mpv: Some Show S01E02", from "Some Show S01E02 - mpv"), but
// not a browser's "Playback". Allocated in the temp allocator.
@(private = "file")
app_label :: proc(app: ^aac.App_Info) -> string {
	name := string(app.display_name)
	media := strings.trim_space(string(app.media_name))
	// Players that put their own name after the title.
	for sep in ([]string{" - ", " — ", " | "}) {
		tail := len(sep) + len(name)
		if len(media) > tail &&
		   strings.equal_fold(
			   media[len(media) - tail:],
			   strings.concatenate({sep, name}, context.temp_allocator),
		   ) {
			media = strings.trim_space(media[:len(media) - tail])
			break
		}
	}
	// What a stream is called when the application doesn't give it a
	// meaningful name (Chromium, Firefox), or just the application's own name.
	for g in ([]string{"", "playback", "audiostream", "audio stream", "audio", "output", name}) {
		if strings.equal_fold(media, g) {
			return name
		}
	}
	return strings.concatenate({name, ": ", media}, context.temp_allocator)
}

// app_audio_refresh lists the applications that are playing audio now.
@(private = "file")
refresh :: proc(a: ^State) {
	if a.list != nil {
		aac.app_list_destroy(a.list)
		a.list = nil
	}
	if st := aac.app_list_create(&a.list); st != .Ok {
		a.list = nil
		log.errorf("app audio: could not list applications: %s", aac.last_error())
	}
}

// app_audio_start shares the application at `index` in the menu list (called
// `name`) with the connection, instead of whatever was shared before.
@(private = "file")
start :: proc(env: ^core.Env, a: ^State, index: uint, name: string) {
	stop(a)
	delete(a.error)
	a.error = ""
	// Share it into the voice it goes with: the server it is in, wherever that is.
	t := a.hooks.target(a.hooks.user)
	if t.conn == nil || !t.conn.voice.ready || a.list == nil {
		return
	}
	s, st, why := audio.app_share_start(&t.conn.voice, a.list, index)
	share_begun(env, a, t, s, st, why, name)
}

// share_begun takes over a share that was just started (`s`, or the reason
// in `st` and `why` why it wasn't), of what is called `name`.
@(private = "file")
share_begun :: proc(
	env: ^core.Env,
	a: ^State,
	t: Target,
	s: ^audio.App_Share,
	st: aac.Status,
	why, name: string,
	device := false,
) {
	if st != .Ok {
		log.errorf("app audio: could not share %s: %s", name, why)
		if st == .Permission_Denied {
			a.error = strings.clone(
				"Not allowed to capture its audio. Check the system's privacy settings.",
			)
		} else {
			a.error = strings.concatenate({"Could not share the audio: ", why})
		}
		return
	}
	conn.push_command(&t.conn.commands, conn.app_audio_command(&env.settings))
	sync.atomic_store(&s.voice.app_input, true)
	a.share, a.owner, a.device = s, t.owner, device
	a.name = strings.clone(name)
	log.infof("app audio: sharing %s", name)
}

// share_audio_refresh lists the playback devices for the share menu.
share_audio_refresh :: proc(a: ^State) {
	if !a.available {
		return
	}
	if a.devices != nil {
		aac.app_list_destroy(a.devices)
		a.devices = nil
	}
	if st := aac.device_list_create(&a.devices); st != .Ok {
		a.devices = nil
		log.errorf("app audio: could not list playback devices: %s", aac.last_error())
	}
}

// share_audio_index is the device settings.share_audio picks from the share
// menu's list, or -1 for no audio. A device that isn't listed anymore
// means the default one.
@(private = "file")
share_audio_index :: proc(env: ^core.Env, a: ^State) -> int {
	choice := env.settings.share_audio
	if choice == "" || a.devices == nil {
		return -1
	}
	fallback := -1
	for i in 0 ..< aac.app_list_count(a.devices) {
		d := aac.app_list_get(a.devices, i)
		if choice != "default" && string(d.display_name) == choice {
			return int(i)
		}
		if d.is_default || fallback < 0 {
			fallback = int(i)
		}
	}
	return fallback
}

// share_audio_choice is the share menu's audio choice: no audio, or one of
// the playback devices. It is only there where devices can be captured.
share_audio_choice :: proc(env: ^core.Env, a: ^State, width: i32) {
	if !a.available || a.devices == nil {
		return
	}
	ctx := &env.ctx
	current := share_audio_index(env, a)
	count := int(aac.app_list_count(a.devices))
	mu.layout_row(ctx, {width})
	widgets.dim_label(ctx, "Share the audio of:")
	widgets.menu_list_begin(env, "audio", width, 1 + count)
	mu.layout_row(ctx, {-1})
	if .SUBMIT in widgets.list_row(ctx, "none", "No audio", current < 0) {
		settings.set_setting(&env.settings.share_audio, "")
		env.settings_dirty = true
	}
	for i in 0 ..< count {
		d := aac.app_list_get(a.devices, uint(i))
		name := string(d.display_name)
		label := strings.concatenate(
			{name, " (default)" if d.is_default else ""},
			context.temp_allocator,
		)
		mu.push_id(ctx, uintptr(i))
		if .SUBMIT in widgets.list_row(ctx, "device", label, i == current) {
			// The default device is followed to wherever the system moves it.
			settings.set_setting(&env.settings.share_audio, "default" if d.is_default else name)
			env.settings_dirty = true
		}
		mu.pop_id(ctx)
	}
	mu.end_panel(ctx)
}

// share_audio_start shares the playback device chosen in the share menu, if
// any, along with a screen share that was just started, in place of an
// application.
share_audio_start :: proc(env: ^core.Env, a: ^State) {
	index := share_audio_index(env, a)
	if index < 0 {
		return
	}
	stop(a)
	delete(a.error)
	a.error = ""
	t := a.hooks.target(a.hooks.user)
	if t.conn == nil || !t.conn.voice.ready {
		return
	}
	d := aac.app_list_get(a.devices, uint(index))
	name := string(d.display_name)
	// Without our own sound, or everyone would hear themselves back.
	exclude := u32(os.get_pid())
	when ODIN_OS == .Windows {
		// Windows can only leave us out of every device at once (see
		// aac.capture_create_device). That is what's wanted for the device we
		// play on, while any other device can be captured on its own.
		if !plays_on(env, a, d) {
			exclude = 0
		}
	}
	s, st, why := audio.app_share_start_device(&t.conn.voice, a.devices, uint(index), exclude)
	share_begun(env, a, t, s, st, why, name, true)
}

// plays_on says whether our own sound goes to the playback device `d`: the
// output device in the settings, or the default one.
@(private = "file")
plays_on :: proc(env: ^core.Env, a: ^State, d: ^aac.App_Info) -> bool {
	if audio.find_device(a.hooks.outputs(a.hooks.user), env.settings.output_device) == nil {
		return bool(d.is_default)
	}
	return string(d.display_name) == env.settings.output_device
}

package client

import "base:intrinsics"
import "client:audio"
import "client:conn"
import "client:platform"
import "client:settings"
import "client:video"
import log "common:wlog"
import "core:strings"
import "core:sync"

// Sessions: connecting to servers and disconnecting from them, and what
// every session shares, like being muted or deafened and the audio
// devices.

// connect_joined connects to every joined server at startup, in the rail's
// order, and shows the first one. If a server was given when the client was
// started, it instead joins that server (if it isn't joined yet), shows it and
// looks at the channel given with it.
connect_joined :: proc(ui: ^UI) {
	first := conn.with_default_port(ui.opts.server)
	if first != "" {
		password := ui.opts.password
		if password == "" {
			password = settings.joined_password(&ui.settings, first)
		}
		settings.join_server(&ui.settings, first, password)
		save_settings(ui)
	} else if len(ui.settings.joined_servers) > 0 {
		first = ui.settings.joined_servers[0].address
	}
	when platform.WEB {
		relay_claim(ui, first)
		for r in ui.settings.joined_servers {
			relay_claim(ui, r.address)
		}
	}
	for r in ui.settings.joined_servers {
		this := r.address == first
		connect_to(ui, r.address, r.password, ui.opts.channel if this else "", show = this)
	}
}

// connect connects again to the server on the connect screen, which is a
// server on the rail that isn't connected, possibly with a different
// password now. The new connection takes the old one's place.
connect :: proc(ui: ^UI) {
	server := conn.with_default_port(field_text(&ui.server))
	if server == "" {
		return
	}
	// Show the port that was assumed, because that is also what gets saved.
	field_set(&ui.server, server)
	// Taken as typed, because spaces may well be part of a password.
	password := field_text(&ui.password)
	settings.join_server(&ui.settings, server, password)
	save_settings(ui)
	connect_to(ui, server, password)
}

// connect_to connects to a server. This creates a new session at the end of the
// rail. If a session for that server already exists (for example one that
// failed, or one whose key was just trusted), a new one replaces it and
// carries on with what the UI had kept for it. With `show`, the server is shown.
connect_to :: proc(
	ui: ^UI,
	server, password: string,
	channel := "",
	show := true,
) -> ^Net_Session {
	monitor_stop(ui) // the connection opens the microphone itself
	ns := session_new(ui, server, password, channel)
	old_index := -1
	for other, i in ui.sessions {
		if other.server == server && !other.joining {
			old_index = i
		}
	}
	if old_index >= 0 {
		old := ui.sessions[old_index]
		ui.sessions[old_index] = ns
		if old == ui.session {
			ui.session, ui.view = ns, &ns.view
		} else {
			ns.stash, old.stash = old.stash, {}
			if show {
				show_session(ui, ns)
			}
		}
		session_free(ui, old)
	} else {
		append(&ui.sessions, ns)
		if show {
			show_session(ui, ns)
		}
	}
	// The per-user volumes are applied once the server's key tells which
	// ones belong to this server (see apply_gains).
	if ns == ui.session {
		ui.gains_for = {}
	} else {
		ns.stash.gains_for = {}
	}
	if !relay_blocked(ui, ns) {
		net_start(ns)
	}
	return ns
}

// command hands a command to the session's connection thread, if there is a
// session.
command :: proc(ui: ^UI, cmd: conn.Command) {
	if ui.session != nil {
		conn.push_command(&ui.session.client.commands, cmd)
	}
}

// session_new creates a session for `server`, ready to start, which joins
// `channel` if there is one.
session_new :: proc(ui: ^UI, server, password: string, channel := "") -> ^Net_Session {
	ns := new(Net_Session)
	ns.key_path = strings.clone(ui.opts.key_path)
	ns.server = strings.clone(server)
	ns.password = strings.clone(password)
	ns.known_servers = strings.clone(ui.opts.known_servers)
	ns.channel = strings.clone(channel)
	// If no channel was asked for, the channel that was on screen the last
	// time is shown again (but not joined).
	ns.look_at = strings.clone(settings.joined_channel(&ui.settings, server))
	ns.slot = session_slot(ui)
	// Its login form, if it needs one, starts with the account that was last
	// logged in to on any server.
	field_set(&ns.stash.account.username, ui.settings.username)
	conn.view_init(&ns.view)
	ns.view.wake = ui_wake
	ns.view.status = .Connecting
	ns.view.server = strings.clone(server)
	ns.client = new(conn.Server_Conn)
	ns.client.view = &ns.view
	ns.client.slot = ns.slot
	ns.client.blobs.disk = &ui.image_cache
	if audio.voice_init(&ns.client.voice) {
		// Devices may have come or gone since the list was made. The
		// microphone waits until it is needed (see session_capture_update).
		audio.audio_refresh(&ui.audio)
		audio.open_playback(&ui.audio, &ns.streams, &ns.client.voice, ui.settings.output_device)
	}
	ns.client.voice.muted = ui.muted
	ns.client.voice.deafened = ui.deafened
	// Told to the others as soon as we're in a channel (see drive_sound).
	ns.client.channels.sound = conn.sound_flags(ui.muted, ui.deafened)
	ns.client.voice.denoise = ui.settings.noise_suppression
	ns.client.voice.listen = ui.listen_back
	ns.client.voice.notifications.volume = settings.notification_gain(&ui.settings)
	sounds_session_init(ui, ns)
	conn.push_command(
		&ns.client.commands,
		conn.Quality_Command{settings.settings_quality(&ui.settings)},
	)
	conn.push_command(&ns.client.commands, conn.gate_command(&ui.settings))
	conn.push_command(&ns.client.commands, conn.transfer_limits_command(&ui.settings))
	return ns
}

// session_slot returns the first three consecutive WebSocket slots that no
// session uses, for a web build (see conn/transport_web.odin): 0 to 2 for the
// first session, 3 to 5 for the next. A desktop build has no use for it.
@(private = "file")
session_slot :: proc(ui: ^UI) -> i32 {
	for slot := i32(0);; slot += 3 {
		taken := false
		for other in ui.sessions {
			taken ||= other.slot == slot
		}
		if !taken {
			return slot
		}
	}
}

// reconnect tries a server that isn't connected again right now. A connection
// that is still trying (see conn.connection_lost) is told to retry, and one
// that has stopped (for example after being refused) is started again in its
// place. Called between frames.
reconnect :: proc(ui: ^UI, ns: ^Net_Session) {
	if ns == nil || ns.joining {
		return
	}
	retrying: bool
	{
		sync.guard(&ns.view.mutex)
		retrying = ns.view.retrying
	}
	if retrying {
		conn.push_command(&ns.client.commands, conn.Reconnect_Command{})
		return
	}
	log.infof("ui: connecting to %s again", ns.server)
	connect_to(ui, ns.server, ns.password)
}

// disconnect leaves a server: its session ends and it is no longer joined.
// If it was the one shown, the next one in the rail is shown instead. A server
// that is being joined from the + page is given up instead. Called between
// frames.
disconnect :: proc(ui: ^UI, ns: ^Net_Session) {
	if ns == nil {
		return
	}
	if ns.joining {
		join_close(ui)
		return
	}
	settings.leave_server(&ui.settings, ns.server)
	save_settings(ui)
	relay_release(ui, ns.server)
	in_voice: bool
	{
		sync.guard(&ns.view.mutex)
		in_voice = ns.view.my_room != 0 || ns.view.voice_pending
	}
	if in_voice {
		// What was shared there has nobody to go to any more.
		video.share_stop()
		video.camera_stop()
		app_audio_stop(ui)
	}
	session_remove(ui, ns)
	session_free(ui, ns)
}

// session_remove takes a session off the rail together with what the UI kept
// for it. If it was the one shown, the one after it is shown, or else the
// one before it, or none.
session_remove :: proc(ui: ^UI, ns: ^Net_Session) {
	index := -1
	for other, i in ui.sessions {
		if other == ns {
			index = i
		}
	}
	if index < 0 {
		return
	}
	ordered_remove(&ui.sessions, index)
	if ui.voice_at == ns {
		ui.voice_at = nil
	}
	if ns != ui.session {
		stash_destroy(ui, ns)
		return
	}
	server_ui_destroy(ui)
	ui.session, ui.view = nil, &ui.no_view
	// Not one that is being joined, which isn't on the rail.
	next: ^Net_Session
	for i := min(index, len(ui.sessions) - 1); i >= 0; i -= 1 {
		if !ui.sessions[i].joining {
			next = ui.sessions[i]
			break
		}
	}
	show_session(ui, next)
}

// session_free stops a session that is off the rail and frees it.
session_free :: proc(ui: ^UI, ns: ^Net_Session) {
	app_audio_session_gone(ui, ns)
	// Close the devices first, so nothing touches the rings after the voice goes away.
	audio.close_streams(&ns.streams, &ns.client.voice)
	sync.atomic_store(&ns.stop, true)
	net_stop(ns)
	audio.voice_destroy(&ns.client.voice)
	free(ns.client)
	conn.view_destroy(&ns.view)
	delete(ns.key_path)
	delete(ns.server)
	delete(ns.password)
	delete(ns.known_servers)
	delete(ns.channel)
	delete(ns.look_at)
	free(ns)
}

// disconnect_all ends every session at once.
disconnect_all :: proc(ui: ^UI) {
	for len(ui.sessions) > 0 {
		ns := ui.sessions[len(ui.sessions) - 1]
		session_remove(ui, ns)
		session_free(ui, ns)
	}
}

// set_muted plays the muted or unmuted sound, unless it is part of
// deafening (`feedback` false), which plays its own sound.
set_muted :: proc(ui: ^UI, muted: bool, feedback := true) {
	if muted == ui.muted {
		return
	}
	if !muted && ui.deafened {
		// Being heard by everyone while hearing nobody isn't somewhere anyone
		// means to be, so unmuting also undeafens, and stays unmuted.
		ui.muted_before_deafen = false
		set_deafened(ui, false)
		return
	}
	ui.muted = muted
	// Every server's: the feedback sound only from the one in voice, or
	// with none, the one shown.
	for ns in ui.sessions {
		heard := feedback && ns == sound_session(ui)
		conn.push_command(&ns.client.commands, conn.Mute_Command{muted = muted, feedback = heard})
	}
}

// Deafen silences everyone else. Like mute, it lives on the UI so it
// survives reconnecting, and it is pushed to the network thread.
//
// Deafening also mutes, because not being able to hear anyone while still
// sending to them is an odd state to be in. It remembers what mute
// was set to beforehand, so undeafening restores that instead of always
// unmuting.
set_deafened :: proc(ui: ^UI, deafened: bool) {
	if deafened == ui.deafened {
		return
	}
	ui.deafened = deafened
	if deafened {
		ui.muted_before_deafen = ui.muted
		set_muted(ui, true, feedback = false)
	} else {
		set_muted(ui, ui.muted_before_deafen, feedback = false)
	}
	for ns in ui.sessions {
		conn.push_command(
			&ns.client.commands,
			conn.Deafen_Command{deafened = deafened, feedback = ns == sound_session(ui)},
		)
	}
}

// reopen_audio switches the running connections to the devices that are now
// selected in the settings.
reopen_audio :: proc(ui: ^UI, input: bool) {
	if m := &ui.monitor; m.active {
		if input {
			audio.open_capture(&ui.audio, &m.streams, &m.voice, ui.settings.input_device)
		} else if m.streams.playback != nil {
			audio.open_playback(&ui.audio, &m.streams, &m.voice, ui.settings.output_device)
		}
	}
	for ns in ui.sessions {
		if !ns.client.voice.ready {
			continue
		}
		if input {
			// A microphone that isn't wanted is left closed (see session_capture_update).
			if ns.capture_on {
				audio.open_capture(
					&ui.audio,
					&ns.streams,
					&ns.client.voice,
					ui.settings.input_device,
				)
			}
		} else {
			audio.open_playback(
				&ui.audio,
				&ns.streams,
				&ns.client.voice,
				ui.settings.output_device,
			)
		}
	}
}

// session_capture_update runs every frame, before the layout and with no
// View locked. It records which session is in voice (see UI.voice_at; there is
// at most one), and keeps a connection's microphone open only while it is
// wanted: while it is in a voice room (a channel's voice or a call) or on its
// way into one, and, for the shown session or the one in voice, while the
// settings page tests it (see mic_test_wanted; its meter and listen back
// come from the connection). Joining a server alone doesn't open the microphone.
session_capture_update :: proc(ui: ^UI) {
	ui.voice_at = nil
	for ns in ui.sessions {
		if in_voice(ns) {
			ui.voice_at = ns
			break
		}
	}
	// When not in voice, what was shared has nobody to go to, so the capture
	// ends with it (otherwise the OS keeps showing it with the yellow border and
	// the menu bar icon).
	if ui.voice_at == nil {
		video.share_stop()
		app_audio_stop(ui)
	} else {
		// Nor where we may not show it, or not be heard.
		speak, video_ok := room_rights(ui.voice_at)
		if !video_ok && video.share_state() != .Off {
			video.share_stop()
		}
		if !speak {
			app_audio_stop(ui)
		}
	}
	// The camera, likewise, and when we move elsewhere (ui_camera.odin).
	camera_follow(ui)
	// The screen, if it is being shared, goes to the voice too.
	for ns in ui.sessions {
		sync.atomic_store(&ns.client.video.share_here, ns == ui.voice_at)
	}
	test := mic_test_wanted(ui)
	tester := ui.voice_at if ui.voice_at != nil else ui.session
	for ns in ui.sessions {
		if !ns.client.voice.ready {
			continue
		}
		want := ns == ui.voice_at || (test && ns == tester)
		if want == ns.capture_on {
			continue
		}
		ns.capture_on = want
		if want {
			// Devices may have come or gone since the list was made.
			audio.audio_refresh(&ui.audio)
			audio.open_capture(&ui.audio, &ns.streams, &ns.client.voice, ui.settings.input_device)
		} else {
			audio.close_capture(&ns.streams, &ns.client.voice)
		}
	}
}

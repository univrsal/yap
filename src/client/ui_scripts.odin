package client

import "core:strings"
import "core:time"

import "client:platform"
import "client:script"

// Scripts (client/script): started with the UI, told about the connections
// as they are made (ui_sessions.odin), and given a little time every frame.

// How long the loop may sleep at most while scripts are running, so that their
// timers are on time.
SCRIPT_TICK :: 0.1

// How much of a frame the scripts may use all together.
SCRIPT_BUDGET :: 2 * time.Millisecond

scripts_start :: proc(ui: ^UI) {
	dir := platform.default_config_path("scripts")
	defer delete(dir)
	if dir == "" {
		return
	}
	rt := script.runtime_create(dir)
	script.runtime_load(rt)
	if script.runtime_scripts(rt) == 0 {
		// Nothing to run, so nothing to wake up for.
		script.runtime_destroy(rt)
		return
	}
	ui.scripts = rt
}

scripts_frame :: proc(ui: ^UI) {
	if ui.scripts != nil {
		script.runtime_step(ui.scripts, SCRIPT_BUDGET)
	}
}

// scripts_command runs `text` if it is a /command that a script has registered
// for the shown server. Call with the View locked.
scripts_command :: proc(ui: ^UI, text: string) -> bool {
	if ui.scripts == nil || ui.session == nil || !strings.has_prefix(text, "/") {
		return false
	}
	return script.runtime_run_command(ui.scripts, ui.session.client, text, scripts_channel(ui))
}

// scripts_channel is the name of the channel being looked at, "" if it is a
// conversation. Call with the View locked.
scripts_channel :: proc(ui: ^UI) -> string {
	for ch in ui.view.channels {
		if ch.id == ui.view.viewing {
			return ch.name
		}
	}
	return ""
}

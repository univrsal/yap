package client

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

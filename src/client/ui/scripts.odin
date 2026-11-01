package ui

import "core"
import "core:fmt"
import "core:strings"
import "core:time"

import "client:platform"
import "client:script"

// Scripts (client/script): started with the UI, told about the connections
// as they are made (ui/sessions.odin), and given a little time every frame.

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
	script.runtime_notifications_to_ui(rt)
	ui.scripts = rt
	ui.script_ui.dir = strings.clone(dir) if !platform.WEB else ""
}

scripts_frame :: proc(ui: ^UI) {
	if ui.scripts == nil {
		return
	}
	script.runtime_step(ui.scripts, SCRIPT_BUDGET)
	// What scripts want to notify of, shown as the client's own are. The server is
	// named when there are several, as for a mention.
	for n in script.runtime_take_notifications(ui.scripts) {
		title := n.title
		if n.server != "" && len(ui.sessions) > 1 {
			title = fmt.tprintf("%s on %s", n.title, n.server)
		}
		script_notice(ui, title, n.text)
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
scripts_channel :: proc(env: ^core.Env) -> string {
	for ch in env.view.channels {
		if ch.id == env.view.viewing {
			return ch.name
		}
	}
	return ""
}

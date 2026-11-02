package client

import "core:fmt"
import "core:strings"
import "core:time"

import "client:conn"
import "client:platform"
import "client:script"
import "common:proto"

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
scripts_channel :: proc(ui: ^UI) -> string {
	for ch in ui.view.channels {
		if ch.id == ui.view.viewing {
			return ch.name
		}
	}
	return ""
}

// Slash_Result says what became of a line that may be a bot's command.
Slash_Result :: enum {
	None, // it isn't one: it is for whoever is next (a message)
	Run, // it was queued to run: the line is used up
	Keep, // it is one, but can't run as it is: what was typed stays
}

// composer_dm returns whom a composer writes to if it is the DM of the
// Buddies page, or 0. Call with the View locked.
composer_dm :: proc(ui: ^UI, c: Composer) -> proto.Account_Id {
	if c.thread == 0 && ui.page == .Buddies {
		return ui.buddies.selected
	}
	return 0
}

// composer_conv returns the conversation a composer writes in, or 0 if it
// is a DM that isn't open yet. Call with the View locked.
composer_conv :: proc(ui: ^UI, c: Composer, dm_to: proto.Account_Id) -> proto.Conv_Id {
	if c.thread != 0 && c.thread <= len(ui.threads) {
		return ui.threads[c.thread - 1].key.conv
	}
	if dm_to != 0 {
		for dm in ui.view.dms {
			if dm.with == dm_to {
				return dm.id
			}
		}
		return 0
	}
	return ui.view.viewing
}

// composer_bot_commands lists the bots' commands that could be run in the
// conversation a composer writes in. Call with the View locked.
composer_bot_commands :: proc(
	ui: ^UI,
	c: Composer,
	dm_to: proto.Account_Id,
) -> []conn.Bot_Command_Entry {
	conv := composer_conv(ui, c, dm_to)
	if conv == 0 && dm_to != 0 {
		return conn.bot_commands_scope(ui.view.bot_commands[:], {dm_to}, true)
	}
	return conn.view_bot_commands(ui.view, conv)
}

// bot_slash runs `text` if it is a command of a bot that could be in the
// conversation the composer writes in. It is not guessed which bot is meant
// when several have the command: that is said, and the text stays so that it
// can be changed to name one (/bot:command). Call with the View locked.
bot_slash :: proc(ui: ^UI, c: Composer, dm_to: proto.Account_Id, text: string) -> Slash_Result {
	if ui.session == nil {
		return .None
	}
	word, _, ok := conn.command_line_split(text)
	if !ok {
		return .None
	}
	found := conn.bot_commands_lookup(composer_bot_commands(ui, c, dm_to), word)
	switch len(found) {
	case 0:
		return .None
	case 1:
	case:
		conn.notice_set(
			ui.view,
			false,
			fmt.tprintf("Several bots have /%s: use /%s.", word, conn.bot_command_typed(found[0])),
		)
		return .Keep
	}
	run := conn.Bot_Run_Command {
		line  = strings.clone(text),
		conv  = composer_conv(ui, c, dm_to),
		dm_to = dm_to if c.thread == 0 else 0,
	}
	if c.thread != 0 && c.thread <= len(ui.threads) {
		run.thread_root = ui.threads[c.thread - 1].key.root
	}
	conn.push_command(&ui.session.client.commands, run)
	return .Run
}

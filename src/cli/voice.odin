package main

import "core:fmt"
import "core:strings"

import "common:proto"

import "client:conn"
import "tui"

// Voice and calls. The app keeps what the user chose (muted, deafened) and
// tells the connections; the loop (run.odin) opens the audio devices while a
// connection is in a voice room or a call, since the devices belong to the
// program and not to a screen.

// in_voice says whether a server's connection is in a voice room, on its way into
// one, or in a call. Call with its View locked.
in_voice :: proc(v: ^conn.View) -> bool {
	return v.my_room != 0 || v.voice_pending || v.call.status != .None
}

// has_voice says whether a channel has a voice room we may use.
has_voice :: proc(ch: conn.View_Channel) -> bool {
	return .Text_Only not_in ch.flags && .Voice in ch.rights
}

// voice_users are the people in a channel's voice room, as the list shows them.
voice_users :: proc(v: ^conn.View, ch: conn.View_Channel) -> []Voice_User {
	out := make([dynamic]Voice_User, context.temp_allocator)
	for num in ch.members {
		u, ok := v.users[num]
		if !ok {
			continue
		}
		name := "someone"
		if acc, known := v.accounts[u.account]; known {
			name = acc.display
		}
		append(&out, Voice_User{name = name, speaking = conn.is_speaking(v, num), muted = u.muted, deafened = u.deafened})
	}
	return out[:]
}

Voice_User :: struct {
	name:     string,
	speaking: bool,
	muted:    bool,
	deafened: bool,
}

// set_muted mutes or unmutes on every server, like the window client: it is
// ours, not a server's. The sound of it is played by the shown server only.
set_muted :: proc(a: ^App, muted: bool, feedback := true) {
	if muted == a.muted {
		return
	}
	if !muted && a.deafened {
		// Being heard by everyone while hearing nobody is not somewhere anyone
		// means to be, so unmuting also undeafens, and stays unmuted.
		a.muted_before_deafen = false
		set_deafened(a, false)
		return
	}
	a.muted = muted
	for s, i in a.servers {
		conn.push_command(&s.client.commands, conn.Mute_Command{muted = muted, feedback = feedback && i == a.cur})
	}
	say(a, "Muted." if muted else "Unmuted.")
}

// set_deafened silences everyone else, and mutes with it; undeafening gives back
// what mute was.
set_deafened :: proc(a: ^App, deafened: bool) {
	if deafened == a.deafened {
		return
	}
	a.deafened = deafened
	if deafened {
		a.muted_before_deafen = a.muted
		a.muted = true
		for s in a.servers {
			conn.push_command(&s.client.commands, conn.Mute_Command{muted = true, feedback = false})
		}
	} else {
		a.muted = a.muted_before_deafen
		for s in a.servers {
			conn.push_command(&s.client.commands, conn.Mute_Command{muted = a.muted, feedback = false})
		}
	}
	for s, i in a.servers {
		conn.push_command(&s.client.commands, conn.Deafen_Command{deafened = deafened, feedback = i == a.cur})
	}
	say(a, "Deafened." if deafened else "Hearing again.")
}

// join_voice enters a channel's voice room, leaving any other (also on other
// servers: there is one voice at a time). Call with the View locked.
join_voice :: proc(a: ^App, ch: conn.View_Channel) {
	leave_voice_elsewhere(a)
	push(a, conn.Voice_Command{conv = ch.id})
}

leave_voice :: proc(a: ^App) {
	push(a, conn.Voice_Command{})
}

leave_voice_elsewhere :: proc(a: ^App) {
	for s, i in a.servers {
		if i == a.cur {
			continue
		}
		if s.view.my_room != 0 || s.view.voice_pending {
			conn.push_command(&s.client.commands, conn.Voice_Command{})
		}
	}
}

// toggle_voice joins the voice room of the channel being looked at, or leaves it.
toggle_voice :: proc(a: ^App) {
	ch := conn.viewed_channel(a.view)
	switch {
	case a.view.my_room != 0 && (ch == nil || ch.id == a.view.my_room):
		leave_voice(a)
	case ch != nil && has_voice(ch^):
		join_voice(a, ch^)
	case:
		say(a, "This conversation has no voice room.", true)
	}
}

// hang_up ends, declines or cancels the call.
hang_up :: proc(a: ^App) {
	if a.view.call.status != .None {
		push(a, conn.Call_Hangup_Command{})
	}
}

// voice_status is what the status bar says about voice: the room or call, whether
// we are heard, and the microphone's level. Call with the View locked.
voice_status :: proc(a: ^App) -> (text: string, style: tui.Style) {
	v := a.view
	if !in_voice(v) && !a.muted && !a.deafened {
		return "", {}
	}
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	switch {
	case v.call.status == .Ringing_Out:
		fmt.sbprintf(&b, "calling %s", call_peer_name(v))
	case v.call.status == .Ringing_In:
		fmt.sbprintf(&b, "%s is calling", call_peer_name(v))
	case v.call.status == .Active:
		fmt.sbprintf(&b, "in a call with %s", call_peer_name(v))
	case v.my_room != 0:
		fmt.sbprintf(&b, "♪ %s", conversation_name(v, v.my_room))
	case v.voice_pending:
		fmt.sbprintf(&b, "♪ joining…")
	}
	if a.deafened {
		strings.write_string(&b, "  deafened")
	} else if a.muted {
		strings.write_string(&b, "  muted")
	} else if v.my_room != 0 || v.call.status == .Active {
		if v.mic_open {
			fmt.sbprintf(&b, "  %s", level_bar(v.mic_level))
		}
	}
	return strings.to_string(b), {fg = theme.online.fg, bg = theme.bar.bg}
}

// level_bar draws a microphone level in dBFS as eight steps.
level_bar :: proc(db: f32) -> string {
	steps := [?]string{"▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"}
	n := clamp(int((db + 60) / 60 * f32(len(steps))), 0, len(steps) - 1)
	return fmt.tprintf("%s%s%s", steps[max(n - 2, 0)], steps[max(n - 1, 0)], steps[n])
}

call_peer_name :: proc(v: ^conn.View) -> string {
	if acc, ok := v.accounts[v.call.peer]; ok {
		return acc.display
	}
	return "someone"
}


// can_call says whether a person can be called now: someone else, with an
// account that is there, and no call going on already. Call with the View locked.
can_call :: proc(a: ^App, account: proto.Account_Id) -> bool {
	v := a.view
	if account == 0 || account == v.me || v.call.status != .None {
		return false
	}
	acc, ok := v.accounts[account]
	return ok && .Deleted not_in acc.flags
}

// start_call calls somebody. Call with the View locked.
start_call :: proc(a: ^App, account: proto.Account_Id) {
	if !can_call(a, account) {
		say(a, "That person can't be called now." if a.view.call.status == .None else "You are in a call already.", true)
		return
	}
	push(a, conn.Call_Command{account = account})
	say(a, fmt.tprintf("Calling %s…", a.view.accounts[account].display))
}

// dm_peer is the other person of the DM being looked at (not a group); 0 if it is
// not one. Call with the View locked.
dm_peer :: proc(v: ^conn.View) -> proto.Account_Id {
	if dm := viewed_dm(v); dm != nil && dm.count == 0 && dm.with != v.me {
		return dm.with
	}
	return 0
}

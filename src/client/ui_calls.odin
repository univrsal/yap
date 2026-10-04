package client

import "core:fmt"
import mu "vendor:microui"

import "client:conn"
import glfw "client:wglfw"
import "common:proto"

/*
Calls on screen (conn/calls.odin). The call itself is in the voice
panel (ui_voice_panel.odin): ringing in with Accept and Decline, ringing
out with Cancel, and once on, whom it's with, how long, and the buttons.
A call coming in also says so on the desktop, and asks for the window's
attention. A call is started from a DM's header or somebody's menu.
*/

UI_Calls :: struct {
	// The call last told of on the desktop, so it's told once.
	announced: proto.Call_Id,
}

// call_peer_name is who a call is with. Call with the View locked.
call_peer_name :: proc(v: ^conn.View) -> string {
	if acc, ok := v.accounts[v.call.peer]; ok {
		return acc.display
	}
	return "someone"
}

// call_announce tells the desktop of a call coming in, once. Call with
// the View locked, every frame.
call_announce :: proc(ui: ^UI) {
	v := &ui.view
	if v.call.status != .Ringing_In {
		if v.call.status == .None {
			ui.calls.announced = 0
		}
		return
	}
	if ui.calls.announced == v.call.id {
		return
	}
	ui.calls.announced = v.call.id
	tray_notify(ui, fmt.tprintf("%s is calling you", call_peer_name(v)), "Answer it in yap.")
	if ui.window != nil {
		glfw.RequestWindowAttention(ui.window)
	}
}

// may_call is whether we could call an account now: it's somebody else,
// here, and we aren't in a call. Call with the View locked.
may_call :: proc(v: ^conn.View, account: proto.Account_Id) -> bool {
	if account == v.me || account == 0 || v.call.status != .None {
		return false
	}
	for num, u in v.users {
		if u.account == account && num != v.my_num {
			return true
		}
	}
	return false
}

// call_account calls somebody.
call_account :: proc(ui: ^UI, account: proto.Account_Id) {
	if ui.session != nil {
		conn.push_command(&ui.session.client.commands, conn.Call_Command{account = account})
	}
}

// Text buttons beside a name (a DM's header).
CALL_BUTTON :: 60

_ :: mu

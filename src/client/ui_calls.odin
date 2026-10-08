package client

import mu "vendor:microui"

import "client:conn"
import "common:proto"

/*
Calls on screen (conn/calls.odin). The call itself is in the voice
panel (ui_voice_panel.odin): ringing in with Accept and Decline, ringing
out with Cancel, and once on, whom it's with, how long, and the buttons.
A call coming in also says so on the desktop, and asks for the window's
attention. A call is started from a DM's header or somebody's menu.
*/

// call_peer_name is who a call is with. Call with the View locked.
call_peer_name :: proc(v: ^conn.View) -> string {
	if acc, ok := v.accounts[v.call.peer]; ok {
		return acc.display
	}
	return "someone"
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
		leave_voice_elsewhere(ui)
		conn.push_command(&ui.session.client.commands, conn.Call_Command{account = account})
	}
}

_ :: mu

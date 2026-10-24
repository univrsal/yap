package client

import mu "vendor:microui"

import "client:conn"
import "common:proto"

// Calls on screen (see conn/calls.odin). The call itself is in the voice
// panel (see ui_voice_panel.odin): an incoming call rings with Accept and
// Decline buttons, an outgoing call rings with a Cancel button, and once the
// call is on, the panel shows who it is with, how long it has lasted, and the
// call's buttons. An incoming call is also announced on the desktop, and asks
// for the window's attention. A call is started from a DM's header or from
// somebody's menu, with or without video (ui_camera.odin).

// call_peer_name returns who a call is with. Call with the View locked.
call_peer_name :: proc(v: ^conn.View) -> string {
	if acc, ok := v.accounts[v.call.peer]; ok {
		return acc.display
	}
	return "someone"
}

// call_peer returns the user of the person a call is with (their device in the
// call's room, the one whose state counts), or 0 if they aren't there. Call
// with the View locked.
call_peer :: proc(v: ^conn.View) -> (num: proto.User_Num, peer: conn.View_User) {
	room := proto.call_room(v.call.id)
	for n, u in v.users {
		if u.account == v.call.peer && u.room == room {
			return n, u
		}
	}
	return
}

// may_call returns whether we could call an account now: it has to be somebody
// else, who is online and not a bot (which has no voice), and we must not be in
// a call. Call with the View locked.
may_call :: proc(v: ^conn.View, account: proto.Account_Id) -> bool {
	if account == v.me || account == 0 || v.call.status != .None || is_bot(v, account) {
		return false
	}
	for num, u in v.users {
		if u.account == account && num != v.my_num {
			return true
		}
	}
	return false
}

// call_account calls somebody, with our camera on once they answer if `video`
// says so (see ui_camera.odin).
call_account :: proc(ui: ^UI, account: proto.Account_Id, video := false) {
	if ui.session != nil {
		leave_voice_elsewhere(ui)
		command(ui, conn.Call_Command{account = account})
		if video {
			camera_on_call(ui)
		}
	}
}

_ :: mu

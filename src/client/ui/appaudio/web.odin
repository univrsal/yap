#+build wasi
package appaudio

import "client:ui/core"
import "client:conn"
import "client:video"

// A page can't capture another application's audio, so a web build has no
// button for it (see ui/appaudio/native.odin). What it can share is the audio
// the browser offers along with a screen share (a tab's, or on some systems
// the whole system's), which the network loop sends the same way
// (capture_audio in video/web.odin). It goes with the share, so
// all there is to do here is to keep the settings it is sent with.

State :: struct {
	hooks:   Hooks,
	sharing: bool, // the screen share was live last frame
}

init :: proc(a: ^State, hooks: Hooks) {
	a.hooks = hooks
}
destroy :: proc(a: ^State) {}
available :: proc(a: ^State) -> bool {return false}
on :: proc(a: ^State) -> bool {return false}

// setting is whether the settings show how shared audio is sent.
setting :: proc(a: ^State) -> bool {
	return video.can_share()
}

// frame passes the settings on as a share starts, since the session
// it goes out through may not have had them yet.
frame :: proc(env: ^core.Env, a: ^State) {
	sharing := video.share_state() == .Live
	if sharing && !a.sharing {
		a.hooks.send_all(a.hooks.user, conn.app_audio_command(&env.settings))
	}
	a.sharing = sharing
}

stop :: proc(a: ^State) {}
session_gone :: proc(a: ^State, owner: rawptr) {}
button :: proc(env: ^core.Env, a: ^State) {}
menu :: proc(env: ^core.Env, a: ^State) {}
share_audio_refresh :: proc(a: ^State) {}
share_audio_choice :: proc(env: ^core.Env, a: ^State, width: i32) {}
share_audio_start :: proc(env: ^core.Env, a: ^State) {}

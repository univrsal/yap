#+build wasi
package client

import "client:conn"
import "client:video"

// A page can't capture another application's audio, so a web build has no
// button for it (see ui_app_audio_native.odin). What it can share is the audio
// the browser offers along with a screen share (a tab's, or on some systems
// the whole system's), which the network loop sends the same way
// (capture_audio in video/web.odin). It goes with the share, so
// all there is to do here is to keep the settings it is sent with.

UI_App_Audio :: struct {
	sharing: bool, // the screen share was live last frame
}

app_audio_init :: proc(ui: ^UI) {}
app_audio_destroy :: proc(ui: ^UI) {}
app_audio_available :: proc(ui: ^UI) -> bool {return false}
app_audio_on :: proc(ui: ^UI) -> bool {return false}

// app_audio_setting is whether the settings show how shared audio is sent.
app_audio_setting :: proc(ui: ^UI) -> bool {
	return video.can_share()
}

// app_audio_frame passes the settings on as a share starts, since the session
// it goes out through may not have had them yet.
app_audio_frame :: proc(ui: ^UI) {
	sharing := video.share_state() == .Live
	if sharing && !ui.app_audio.sharing {
		command_all(ui, conn.app_audio_command(&ui.settings))
	}
	ui.app_audio.sharing = sharing
}

app_audio_stop :: proc(ui: ^UI) {}
app_audio_session_gone :: proc(ui: ^UI, ns: ^Net_Session) {}
app_audio_button :: proc(ui: ^UI) {}
app_audio_menu :: proc(ui: ^UI) {}
share_audio_refresh :: proc(ui: ^UI) {}
share_audio_choice :: proc(ui: ^UI, width: i32) {}
share_audio_start :: proc(ui: ^UI) {}

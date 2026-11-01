package ui

import "appaudio"
import "client:audio"
import "client:conn"

// app_audio_init gives the app audio what it needs of the UI (ui/appaudio):
// the session the audio goes into, a way to send a command to every
// connection, and the playback devices.
app_audio_init :: proc(ui: ^UI) {
	appaudio.init(
		&ui.app_audio,
		{
			user = ui,
			target = proc(user: rawptr) -> appaudio.Target {
				ns := sound_session((^UI)(user))
				if ns == nil {
					return {}
				}
				return {owner = ns, conn = ns.client}
			},
			send_all = proc(user: rawptr, cmd: conn.Command) {
				command_all((^UI)(user), cmd)
			},
			outputs = proc(user: rawptr) -> []audio.Audio_Device {
				return (^UI)(user).audio.outputs[:]
			},
		},
	)
}

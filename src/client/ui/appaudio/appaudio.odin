// Sharing an application's audio with the channel, next to the microphone
// (ui/appaudio/native.odin), or, in a web build, the audio that comes with a
// screen share (web.odin).
//
// What this needs from the rest of the UI is given in Hooks, so that the
// package doesn't know about the UI's sessions: the UI says where the audio
// should go (target), how to send a command to every connection (send_all) and
// which playback devices there are (outputs).
package appaudio

import "client:audio"
import "client:conn"

// The connection that the shared audio goes into, and who it belongs to, for
// session_gone. conn is nil when there is none.
Target :: struct {
	owner: rawptr,
	conn:  ^conn.Server_Conn,
}

Hooks :: struct {
	user:     rawptr, // passed to each of them
	// The session that sounds go with: the one in voice or, if none is, the one shown.
	target:   proc(user: rawptr) -> Target,
	send_all: proc(user: rawptr, cmd: conn.Command),
	outputs:  proc(user: rawptr) -> []audio.Audio_Device,
}

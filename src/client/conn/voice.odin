package conn

import "client:audio"

/*
The connection's end of the voice pipeline (audio/voice.odin): what the
pipeline captures and encodes is sent here, and what arrives is handed
to it in client_step.
*/

// voice_step sends captured audio, and keeps the output fed.
voice_step :: proc(c: ^Voice_Client) {
	send_captured(c)
	audio.voice_step(&c.voice)
}

// send_captured sends a frame for every 20 ms that's been captured, once
// there's a session and a settled channel to send it to.
@(private = "file")
send_captured :: proc(c: ^Voice_Client) {
	v := &c.voice
	mic, capturing := audio.capture_begin(v)
	if !capturing {
		return
	}
	buf: [audio.VOICE_MESSAGE_MAX]u8
	for {
		sending := c.has_current && in_room(c)
		level, msg := audio.capture_frame(v, mic, sending, buf[:]) or_break
		publish_mic(c, level, v.gate.open)
		if len(msg) > 0 && send_data(c, msg) {
			audio.voice_sent(v, msg)
			if me := my_num(c); me != 0 {
				publish_voice(c, me)
			}
		}
	}
}

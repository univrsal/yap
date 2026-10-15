package conn

import log "common:wlog"
import "core:time"

import "client:audio"

// Which sound each event plays is the UI's to say (Sound_Command, from the
// settings). What plays when is decided here and in the places the events
// happen: the loop under everything (loop_sounds), and the sounds for the
// connection going bad while our voice is in a room or a call (trouble_step).

// Gives an event another sound: a built-in one ("aim/msg"), one of the user's
// own ("custom:<file>", which the UI has loaded) or none ("").
Sound_Command :: struct {
	kind:     audio.Sound_Event,
	name_buf: [96]u8,
	name_len: int,
}

// Whether our voice is busy on another server (in a room or a call there), so
// that a call here knocks instead of ringing.
Voice_Elsewhere_Command :: struct {
	busy: bool,
}

// sound_command returns the command that gives `kind` the sound `name`. A name
// too long for it is no sound (the UI keeps the names of the user's own files
// short enough).
sound_command :: proc(kind: audio.Sound_Event, name: string) -> (cmd: Sound_Command) {
	cmd.kind = kind
	if len(name) <= len(cmd.name_buf) {
		cmd.name_len = copy(cmd.name_buf[:], name)
	}
	return
}

sound_command_apply :: proc(c: ^Voice_Client, cmd: ^Sound_Command) {
	audio.notifications_set(&c.voice.notifications, cmd.kind, string(cmd.name_buf[:cmd.name_len]))
}

// The connection going bad while our voice is in a room or a call: no answer
// to our pings for a few seconds (LOST_IN_A_ROW). Connection_Trouble plays
// once, and if it is still bad by the time that is over, Connection_Bad loops
// until it is better, or until the connection is given up as lost.
Trouble :: struct {
	bad:     bool,
	since:   time.Tick,
	looping: bool,
}

// trouble_step checks the connection, along with the pings (ping_step).
trouble_step :: proc(c: ^Voice_Client, stats: Connection_Stats) {
	t := &c.trouble
	bad := my_room(c) != 0 && stats.lost_run >= LOST_IN_A_ROW
	switch {
	case bad && !t.bad:
		t^ = {
			bad   = true,
			since = time.tick_now(),
		}
		log.warn("the connection to the server is bad")
		audio.voice_notification_play(&c.voice, .Connection_Trouble)
	case bad && !t.looping && time.tick_since(t.since) >= trouble_length(c):
		t.looping = true
		loop_sounds(c)
	case !bad && t.bad:
		log.info("the connection to the server is better")
		trouble_end(c)
	}
}

// trouble_end forgets about the connection being bad: it is better, or it is
// gone (connection_lost).
trouble_end :: proc(c: ^Voice_Client) {
	if c.trouble.bad {
		c.trouble = {}
		loop_sounds(c)
	}
}

// trouble_length is how long Connection_Trouble plays.
@(private = "file")
trouble_length :: proc(c: ^Voice_Client) -> time.Duration {
	clip := c.voice.notifications.clips[.Connection_Trouble]
	if clip == nil {
		return 0
	}
	frames := min(len(clip.samples), audio.ONE_SHOT_SECONDS * audio.SAMPLE_RATE * audio.CHANNELS)
	frames /= audio.CHANNELS
	return time.Duration(frames) * time.Second / audio.SAMPLE_RATE
}

// loop_sounds plays the loop that fits: the ring while a call rings in (a
// knock instead if our voice is busy, here or on another server), the
// ringback while our call rings out, otherwise Connection_Bad while the
// connection stays bad, and nothing otherwise.
loop_sounds :: proc(c: ^Voice_Client) {
	loop: audio.Sound_Event
	#partial switch c.call.status {
	case .Ringing_In:
		loop = .Knock if my_room(c) != 0 || c.voice_elsewhere else .Ring
	case .Ringing_Out:
		if c.call.here {
			loop = .Ringback
		}
	}
	if loop == .None && c.trouble.looping {
		loop = .Connection_Bad
	}
	audio.notification_loop(&c.voice.notifications, loop)
}

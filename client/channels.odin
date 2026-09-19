package client

import "core:bufio"
import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "../proto"

// Channel_Client is the client's copy of the channel state, plus any
// Join request still waiting to be acknowledged.
Channel_Client :: struct {
	assembler:       proto.State_Assembler,

	// The applied snapshot; `state` points into the buffers below.
	state:           proto.Channel_State,
	have_state:      bool,
	applied_version: u32,
	body:            [proto.MAX_STATE_SIZE]byte,
	channels_buf:    [proto.MAX_CHANNELS]proto.Channel_Info,
	members_buf:     [proto.MAX_STATE_SIZE / 4]u32,

	// Channel to join as soon as the first snapshot arrives.
	wanted:          string,
	last_request:    u32, // newest Join request id used
	join_pending:    bool,
	join_channel:    u16,
	last_join_sent:  time.Tick,
}

handle_state_message :: proc(c: ^Voice_Client, pt: []byte) {
	ch := &c.channels
	version := proto.state_message_version(pt)
	if ch.have_state && !proto.serial_newer(version, ch.applied_version) {
		// The server resends what we already have when our ack got lost,
		// or after a rekey. Ack again so it stops.
		if version == ch.applied_version {
			send_state_ack(c, version)
		}
		return
	}

	v, body, complete := proto.assembler_add(
		&ch.assembler,
		pt,
		ch.applied_version if ch.have_state else 0,
	)
	if complete {
		apply_state(c, v, body)
	}
}

apply_state :: proc(c: ^Voice_Client, version: u32, body: []byte) {
	ch := &c.channels

	// Validate into scratch space first, so a bad snapshot can't clobber
	// the one we have.
	{
		scratch_channels := make([]proto.Channel_Info, proto.MAX_CHANNELS, context.temp_allocator)
		scratch_members := make([]u32, len(ch.members_buf), context.temp_allocator)
		if _, ok := proto.decode_state(body, scratch_channels, scratch_members); !ok {
			log.warnf("ignoring invalid channel state v%d from the server", version)
			return
		}
	}

	had_state := ch.have_state
	old_channel := ch.state.your_channel
	old_members: []u32
	if had_state {
		old_members = slice.clone(ch.state.channels[old_channel].members, context.temp_allocator)
	}

	copy(ch.body[:], body)
	ch.state, _ = proto.decode_state(ch.body[:len(body)], ch.channels_buf[:], ch.members_buf[:])
	ch.have_state = true
	ch.applied_version = version
	send_state_ack(c, version)
	log.debugf("applied channel state v%d", version)

	state := &ch.state
	if !had_state {
		// Continue from the server's numbering: a restarted client's
		// counter would otherwise look like old retransmits.
		ch.last_request = state.join_ack
	}
	if ch.join_pending && !proto.serial_newer(ch.last_request, state.join_ack) {
		ch.join_pending = false
		if state.your_channel != ch.join_channel && int(ch.join_channel) < len(state.channels) {
			log.warnf("the server didn't move us to %q", state.channels[ch.join_channel].name)
		}
	}

	current := state.channels[state.your_channel]
	switch {
	case !had_state || state.your_channel != old_channel:
		log.infof("in channel %q with %s", current.name, members_string(c, current.members))
	case !slice.equal(old_members, current.members):
		log.infof("%q now has %s", current.name, members_string(c, current.members))
	}

	if ch.wanted != "" {
		wanted := ch.wanted
		ch.wanted = ""
		request_join(c, wanted)
		delete(wanted)
	}
	publish_channels(c)
}

// in_settled_channel is false until we know which channel we're in, and
// while a move is pending. Voice is neither sent nor played then, so
// nothing leaks into a channel we're only passing through (e.g. the
// default channel, before a -channel request takes effect).
in_settled_channel :: proc(c: ^Voice_Client) -> bool {
	return c.channels.have_state && !c.channels.join_pending && c.channels.wanted == ""
}

// request_join asks the server to move us to the channel called `name`.
request_join :: proc(c: ^Voice_Client, name: string) {
	ch := &c.channels
	if !ch.have_state {
		delete(ch.wanted)
		ch.wanted = strings.clone(name)
		log.infof("will join %q once connected", name)
		return
	}

	idx := -1
	for info, i in ch.state.channels {
		if info.name == name {
			idx = i
			break
		}
	}
	switch {
	case idx < 0:
		log.warnf("there's no channel called %q (/channels lists them)", name)
		return
	case idx == int(ch.state.your_channel) && !ch.join_pending:
		log.infof("already in %q", name)
		return
	}

	ch.last_request += 1
	ch.join_pending = true
	ch.join_channel = u16(idx)
	send_join(c)
	publish_channels(c)
}

// drive_join resends an unacknowledged Join request.
drive_join :: proc(c: ^Voice_Client) {
	ch := &c.channels
	if ch.join_pending &&
	   c.has_current &&
	   time.tick_since(ch.last_join_sent) >= proto.CONTROL_RESEND {
		log.debug("resending join request")
		send_join(c)
	}
}

send_join :: proc(c: ^Voice_Client) {
	buf: [proto.JOIN_SIZE]byte
	send_data(c, proto.encode_join(&buf, c.channels.last_request, c.channels.join_channel))
	c.channels.last_join_sent = time.tick_now()
}

send_state_ack :: proc(c: ^Voice_Client, version: u32) {
	buf: [proto.STATE_ACK_SIZE]byte
	send_data(c, proto.encode_state_ack(&buf, version))
}

list_channels :: proc(c: ^Voice_Client) {
	ch := &c.channels
	if !ch.have_state {
		log.info("not connected yet")
		return
	}
	for info, i in ch.state.channels {
		marker := i == int(ch.state.your_channel) ? "*" : " "
		log.infof("%s %s: %s", marker, info.name, members_string(c, info.members))
	}
}

members_string :: proc(c: ^Voice_Client, members: []u32) -> string {
	if len(members) == 0 {
		return "nobody"
	}
	b := strings.builder_make(context.temp_allocator)
	for m, i in members {
		if i > 0 {
			strings.write_string(&b, ", ")
		}
		fmt.sbprintf(&b, "%08x", m)
		if m == c.my_id {
			strings.write_string(&b, " (you)")
		}
	}
	return strings.to_string(b)
}

/*
Commands for the network loop, from the UI or (headless) from stdin.
The queue is the only part of a Voice_Client other threads may touch.
*/
Join_Command :: struct {
	channel: string, // owned by the command
}
List_Command :: struct {}
Mute_Command :: struct {
	muted: bool,
}
Noise_Command :: struct {
	enabled: bool,
}
// How loud to play a user: 1 is unchanged, 0 is muted.
Gain_Command :: struct {
	user: u32,
	gain: f32,
}

Command :: union {
	Join_Command,
	List_Command,
	Mute_Command,
	Noise_Command,
	Gain_Command,
}

Command_Queue :: struct {
	mutex:    sync.Mutex,
	commands: [dynamic]Command,
}

push_command :: proc(q: ^Command_Queue, cmd: Command) {
	sync.guard(&q.mutex)
	append(&q.commands, cmd)
}

commands_destroy :: proc(q: ^Command_Queue) {
	sync.guard(&q.mutex)
	for cmd in q.commands {
		command_destroy(cmd)
	}
	delete(q.commands)
	q.commands = nil
}

@(private = "file")
command_destroy :: proc(cmd: Command) {
	if join, ok := cmd.(Join_Command); ok {
		delete(join.channel)
	}
}

process_commands :: proc(c: ^Voice_Client) {
	commands: [dynamic]Command
	{
		sync.guard(&c.commands.mutex)
		commands, c.commands.commands = c.commands.commands, {}
	}
	defer {
		for cmd in commands {
			command_destroy(cmd)
		}
		delete(commands)
	}

	for cmd in commands {
		switch v in cmd {
		case Join_Command:
			request_join(c, v.channel)
		case List_Command:
			list_channels(c)
		case Mute_Command:
			c.voice.muted = v.muted
			log.infof("voice %s", "muted" if v.muted else "unmuted")
		case Noise_Command:
			c.voice.denoise = v.enabled
			log.infof("noise suppression %s", "on" if v.enabled else "off")
		case Gain_Command:
			if v.gain == 1 {
				delete_key(&c.voice.gains, v.user)
			} else {
				c.voice.gains[v.user] = v.gain
			}
		}
	}
}

/*
Headless mode reads commands from stdin on a separate thread, so the
network loop never blocks on input.

	/channels        list channels and who is in them
	/join <channel>  move to another channel
	/mute, /unmute   stop or resume sending voice
*/
start_command_reader :: proc(q: ^Command_Queue) {
	thread.create_and_start_with_poly_data(
		q,
		read_commands,
		init_context = context,
		self_cleanup = true,
	)
}

@(private = "file")
read_commands :: proc(q: ^Command_Queue) {
	sc: bufio.Scanner
	bufio.scanner_init(&sc, os.to_reader(os.stdin))
	defer bufio.scanner_destroy(&sc)
	for bufio.scanner_scan(&sc) {
		line := strings.trim_space(bufio.scanner_text(&sc))
		switch {
		case line == "":
		case line == "/channels":
			push_command(q, List_Command{})
		case line == "/mute" || line == "/unmute":
			push_command(q, Mute_Command{line == "/mute"})
		case strings.has_prefix(line, "/join "):
			push_command(q, Join_Command{strings.clone(strings.trim_space(line[len("/join "):]))})
		case:
			log.warn("commands: /channels, /join <channel>, /mute, /unmute")
		}
	}
}

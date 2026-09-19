package client

import "core:log"
import "core:strings"
import "core:sync"
import "core:time"

import "../proto"

/*
State shared between the network thread (which writes it) and the UI
(which reads it every frame). Everything is behind one mutex; the UI
holds it while laying out a frame, which is well under a millisecond.

The network thread never touches UI state directly, and the UI never
touches the Voice_Client except through its command queue.
*/

Status :: enum {
	Disconnected,
	Connecting,
	Connected,
	Failed,
}

View_Channel :: struct {
	name:    string,
	members: []u32, // user numbers
}

View_User :: struct {
	key:  [proto.KEY_SIZE]u8,
	name: string, // for display (see display_name); owned
}

View :: struct {
	mutex:      sync.Mutex,
	status:     Status,
	error:      string, // why we Failed
	server:     string,
	my_key:     [proto.KEY_SIZE]u8,
	my_num:     u32, // 0 until the first snapshot
	my_name:    string, // as the server has it
	users:      map[u32]View_User,
	channels:   [dynamic]View_Channel,
	my_channel: int, // -1 until known
	joining:    int, // channel a move is pending to, or -1
	// The microphone's level and the voice gate, per captured frame.
	mic_level:  f32, // dBFS
	mic_open:   bool,
	mic_time:   time.Tick,
	// Last time each user's voice was heard, for a speaking indicator.
	speaking:   map[u32]time.Tick,
}

SPEAKING_HOLD :: 250 * time.Millisecond

view_init :: proc(v: ^View) {
	v.my_channel = -1
	v.joining = -1
}

// view_reset clears everything from a previous connection.
view_reset :: proc(v: ^View) {
	sync.guard(&v.mutex)
	view_clear_channels(v)
	v.my_num = 0
	delete(v.error)
	delete(v.server)
	v.error, v.server = "", ""
	v.status = .Disconnected
	v.my_channel, v.joining = -1, -1
	clear(&v.speaking)
}

view_destroy :: proc(v: ^View) {
	view_reset(v)
	delete(v.channels)
	delete(v.users)
	delete(v.speaking)
}

@(private = "file")
view_clear_channels :: proc(v: ^View) {
	for ch in v.channels {
		delete(ch.name)
		delete(ch.members)
	}
	clear(&v.channels)
	for _, u in v.users {
		delete(u.name)
	}
	clear(&v.users)
	delete(v.my_name)
	v.my_name = ""
}

is_speaking :: proc(v: ^View, id: u32) -> bool {
	t, ok := v.speaking[id]
	return ok && time.tick_since(t) < SPEAKING_HOLD
}

// The publish_* procs are called from the network thread. They do
// nothing when there's no UI (headless mode).

publish_status :: proc(c: ^Voice_Client, status: Status, error := "") {
	c.status = status
	v := c.view
	if v == nil {
		return
	}
	sync.guard(&v.mutex)
	v.status = status
	v.my_key = c.my_key
	if v.server == "" {
		v.server = strings.clone(c.server_addr)
	}
	delete(v.error)
	v.error = strings.clone(error)
}

publish_channels :: proc(c: ^Voice_Client) {
	v := c.view
	if v == nil {
		return
	}
	ch := &c.channels
	sync.guard(&v.mutex)
	view_clear_channels(v)
	for info in ch.state.channels {
		members := make([]u32, len(info.members))
		copy(members, info.members)
		append(&v.channels, View_Channel{name = strings.clone(info.name), members = members})
	}
	for &u in ch.state.users {
		v.users[u.num] = {
			key  = u.key,
			name = strings.clone(display_name(ch.state.users, u.num)),
		}
	}
	v.my_num = ch.state.your_user
	if me := proto.find_user(&ch.state, v.my_num); me != nil {
		v.my_name = strings.clone(me.name)
	}
	v.my_channel = int(ch.state.your_channel)
	v.joining = ch.join_pending ? int(ch.join_channel) : -1
}

publish_mic :: proc(c: ^Voice_Client, level_db: f32, gate_open: bool) {
	v := c.view
	if v == nil {
		return
	}
	sync.guard(&v.mutex)
	v.mic_level, v.mic_open, v.mic_time = level_db, gate_open, time.tick_now()
}

publish_voice :: proc(c: ^Voice_Client, speaker: u32) {
	v := c.view
	if v == nil {
		return
	}
	sync.guard(&v.mutex)
	v.speaking[speaker] = time.tick_now()
}

/*
Recent log lines for the UI's log panel, fed by a common.Log_Sink.
*/
MAX_LOG_LINES :: 500

Log_Line :: struct {
	level: log.Level,
	text:  string,
}

Log_Lines :: struct {
	mutex: sync.Mutex,
	lines: [dynamic]Log_Line,
	total: int, // lines ever added, so the UI can tell when new ones arrive
}

log_lines_sink :: proc(data: rawptr, level: log.Level, line: string) {
	l := (^Log_Lines)(data)
	sync.guard(&l.mutex)
	if len(l.lines) >= MAX_LOG_LINES {
		// Drop the oldest tenth in one go rather than shifting per line.
		drop := MAX_LOG_LINES / 10
		for old in l.lines[:drop] {
			delete(old.text)
		}
		remove_range(&l.lines, 0, drop)
	}
	append(&l.lines, Log_Line{level, strings.clone(line)})
	l.total += 1
}

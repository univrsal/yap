package client

import log "../common/wlog"
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
	members: []proto.User_Num,
}

View_User :: struct {
	key:      [proto.KEY_SIZE]u8,
	name:     string, // for display (see display_name); owned
	// What they've switched off for themselves; nothing to do with the
	// per-user volume we keep for our own ears (see user_settings).
	muted:    bool,
	deafened: bool,
}

View :: struct {
	mutex:      sync.Mutex,
	status:     Status,
	error:      string, // why we Failed
	server:     string,
	my_key:     [proto.KEY_SIZE]u8,
	my_num:     proto.User_Num, // 0 until the first snapshot
	my_name:    string, // as the server has it
	users:      map[proto.User_Num]View_User,
	channels:   [dynamic]View_Channel,
	my_channel: int, // -1 until known
	joining:    int, // channel a move is pending to, or -1
	// The microphone's level and the voice gate, per captured frame.
	mic_level:  f32, // dBFS
	mic_open:   bool,
	mic_time:   time.Tick,
	// Last time each user's voice was heard, for a speaking indicator.
	speaking:   map[proto.User_Num]time.Tick,
	// Text chat in our channel, oldest first.
	chat:       [dynamic]View_Chat_Line,
	chat_total:  int, // lines ever added, so the UI knows when to scroll
	chat_unread: int, // new messages from others; the UI zeroes it when seen
	outbox:     [dynamic]string, // our messages the server hasn't confirmed yet
	images:     map[u32]View_Image, // by image id
	typing:     map[proto.User_Num]time.Tick, // when each user last said they're typing
	// Pokes that came in, for the UI to show (and take) next frame.
	pokes:      [dynamic]View_Poke,
}

View_Poke :: struct {
	name:    string, // who poked us; owned
	message: string, // may be empty; owned
}

View_Chat_Line :: struct {
	sender: proto.User_Num,
	time:   proto.Unix_Time,
	name:   string, // owned
	kind:   proto.Chat_Kind,
	text:   string, // .Text, owned
	image:  proto.Image_Info, // .Image; the bytes live in View.images
}

// View_Image is an image a chat line points at: what it looks like, how
// far along it is, and the JPEG itself once it's here.
View_Image :: struct {
	info:  proto.Image_Info,
	state: Image_State,
	jpeg:  []u8, // owned; only when Ready
}

SPEAKING_HOLD :: 250 * time.Millisecond
MAX_CHAT_LINES :: 500

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
	view_clear_chat(v)
	view_clear_outbox(v)
	view_clear_pokes(v)
}

view_destroy :: proc(v: ^View) {
	view_reset(v)
	delete(v.channels)
	delete(v.users)
	delete(v.speaking)
	delete(v.chat)
	delete(v.outbox)
	delete(v.typing)
	delete(v.images)
	delete(v.pokes)
}

@(private = "file")
view_clear_pokes :: proc(v: ^View) {
	for p in v.pokes {
		delete(p.name)
		delete(p.message)
	}
	clear(&v.pokes)
}

// view_take_pokes hands the UI the pokes that have come in, as copies in
// the temp allocator, and forgets them.
view_take_pokes :: proc(v: ^View) -> []View_Poke {
	sync.guard(&v.mutex)
	if len(v.pokes) == 0 {
		return nil
	}
	out := make([]View_Poke, len(v.pokes), context.temp_allocator)
	for p, i in v.pokes {
		out[i] = {
			name    = strings.clone(p.name, context.temp_allocator),
			message = strings.clone(p.message, context.temp_allocator),
		}
	}
	view_clear_pokes(v)
	return out
}

@(private = "file")
view_clear_chat :: proc(v: ^View) {
	for l in v.chat {
		delete(l.name)
		delete(l.text)
	}
	clear(&v.chat)
	clear(&v.typing)
	v.chat_unread = 0
	for _, img in v.images {
		delete(img.jpeg)
	}
	clear(&v.images)
}

@(private = "file")
view_clear_outbox :: proc(v: ^View) {
	for m in v.outbox {
		delete(m)
	}
	clear(&v.outbox)
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

is_speaking :: proc(v: ^View, id: proto.User_Num) -> bool {
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
		members := make([]proto.User_Num, len(info.members))
		copy(members, info.members)
		append(&v.channels, View_Channel{name = strings.clone(info.name), members = members})
	}
	for &u in ch.state.users {
		v.users[u.num] = {
			key      = u.key,
			name     = strings.clone(display_name(ch.state.users, u.num)),
			muted    = .Muted in u.flags,
			deafened = .Deafened in u.flags,
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

publish_voice :: proc(c: ^Voice_Client, speaker: proto.User_Num) {
	v := c.view
	if v == nil {
		return
	}
	sync.guard(&v.mutex)
	v.speaking[speaker] = time.tick_now()
}

publish_poke :: proc(c: ^Voice_Client, name, message: string) {
	v := c.view
	if v == nil {
		return
	}
	sync.guard(&v.mutex)
	append(&v.pokes, View_Poke{strings.clone(name), strings.clone(message)})
}

publish_chat_reset :: proc(c: ^Voice_Client) {
	v := c.view
	if v == nil {
		return
	}
	sync.guard(&v.mutex)
	view_clear_chat(v)
}

publish_chat :: proc(c: ^Voice_Client, e: proto.Chat_Entry, unread: bool) {
	v := c.view
	if v == nil {
		return
	}
	name := chat_sender_name(c, e)
	sync.guard(&v.mutex)
	if len(v.chat) >= MAX_CHAT_LINES {
		drop := MAX_CHAT_LINES / 10
		for old in v.chat[:drop] {
			delete(old.name)
			delete(old.text)
		}
		remove_range(&v.chat, 0, drop)
	}
	append(
		&v.chat,
		View_Chat_Line {
			sender = e.sender,
			time = e.time,
			name = strings.clone(name),
			kind = e.kind,
			text = strings.clone(e.text),
			image = e.image,
		},
	)
	v.chat_total += 1
	if unread {
		v.chat_unread += 1
	}
	// They're done typing, at least this message.
	delete_key(&v.typing, e.sender)
}

publish_outbox :: proc(c: ^Voice_Client) {
	v := c.view
	if v == nil {
		return
	}
	sync.guard(&v.mutex)
	view_clear_outbox(v)
	for m in c.chat.outbox {
		append(&v.outbox, strings.clone(m.text))
	}
}

// publish_image mirrors an image's state (and its bytes once they're
// here) for the UI to draw.
publish_image :: proc(c: ^Voice_Client, id: u32) {
	v := c.view
	img := c.images.cache[id] or_else nil
	if v == nil || img == nil {
		return
	}
	sync.guard(&v.mutex)
	old := v.images[id]
	delete(old.jpeg)
	jpeg: []u8
	if img.state == .Ready {
		jpeg = make([]u8, len(img.data))
		copy(jpeg, img.data)
	}
	v.images[id] = {info = img.info, state = img.state, jpeg = jpeg}
}

// unpublish_image drops an image the client no longer keeps.
unpublish_image :: proc(c: ^Voice_Client, id: u32) {
	v := c.view
	if v == nil {
		return
	}
	sync.guard(&v.mutex)
	if img, ok := v.images[id]; ok {
		delete(img.jpeg)
		delete_key(&v.images, id)
	}
}

publish_typing :: proc(c: ^Voice_Client, user: proto.User_Num) {
	v := c.view
	if v == nil {
		return
	}
	sync.guard(&v.mutex)
	v.typing[user] = time.tick_now()
}

// is_typing says whether a user has told us recently they're typing.
is_typing :: proc(v: ^View, user: proto.User_Num) -> bool {
	t, ok := v.typing[user]
	return ok && time.tick_since(t) < TYPING_SHOW
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

package conn

import log "common:wlog"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"

import "common:proto"

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

// A channel we're subscribed to, and who is in its voice room.
View_Channel :: struct {
	id:       proto.Conv_Id,
	name:     string, // owned
	topic:    string, // owned
	home:     bool, // the one everyone is in, which can't be left
	private:  bool, // only for those added to it
	position: int,
	members:  []proto.User_Num, // owned
	// What's unread there (see Conv_Info).
	read:     proto.Msg_Id,
	unread:   int,
	mentions: int,
	notify:   proto.Notify_Level,
}

View_User :: struct {
	account:  proto.Account_Id,
	name:     string, // for display (see display_name); owned
	// What they've switched off for themselves; nothing to do with the
	// per-user volume we keep for our own ears (see user_settings).
	muted:    bool,
	deafened: bool,
	sharing:  bool, // their screen can be watched (video.odin)
	room:     proto.Room, // where their voice is; 0 for nowhere
}

View :: struct {
	mutex:          sync.Mutex,
	// Called, from whichever thread, when something the UI shows has
	// changed, for it to draw a frame (see view_write); set once by the
	// UI before any connection starts.
	wake:           proc "c" (),
	status:         Status,
	error:          string, // why we Failed
	// Set when we Failed because the server's key isn't the one saved
	// for it (see verify_server_key), for the UI to offer trusting it.
	key_change:     Key_Change,
	server:         string,
	// What the server calls itself, if it has said and has a name; what
	// it says it's for; and its picture, once fetched (the JPEG, owned,
	// and the id it goes by). See server_info.odin.
	server_name:    string,
	server_about:   string,
	server_icon:    proto.Blob_Id,
	icon_jpeg:      []u8,
	// How big a file attached to a message may be; 0 if it takes none.
	max_attachment: u64,
	// Whether one may register an account there, and with what; and the
	// server's own address, where verifying mail goes (verify.odin).
	registration:   proto.Registration_Flags,
	server_email:   string,
	my_key:         [proto.KEY_SIZE]u8,
	// The server's, once the handshake has shown it (zero until then):
	// per-user settings are kept by it and the account (settings.odin).
	server_key:     [proto.KEY_SIZE]u8,
	my_num:         proto.User_Num, // 0 until the first snapshot
	my_name:        string, // what our account is called
	// Our account and the others (auth.odin).
	login:          View_Login,
	me:             proto.Account_Id,
	permissions:    proto.Permissions,
	my_activity:    proto.Activity, // what we chose to be (activity.odin)
	accounts:       map[proto.Account_Id]View_Account,
	// Our account's devices as of the last time they were asked for, and
	// how many times they've arrived.
	devices:        [dynamic]Dir_Device,
	devices_count:  int,
	invites:        View_Invites, // invites.odin
	notice:         View_Notice,
	users:          map[proto.User_Num]View_User,
	// Our channels, in the order to list them (convs.odin); the
	// conversation whose messages are shown, and the channel last shown
	// (to go back to from a DM); the one whose voice room we're in (0
	// for none); and whether a change of room is on its way.
	channels:       [dynamic]View_Channel,
	viewing:        proto.Conv_Id,
	channel:        proto.Conv_Id,
	my_room:        proto.Conv_Id,
	voice_pending:  bool,
	// The channels there were to subscribe to the last time they were
	// asked for, and how many times they've arrived.
	browse:         [dynamic]Browse_Entry,
	browse_count:   int,
	browse_more:    bool, // there are more of them to ask for
	// The microphone's level and the voice gate, per captured frame.
	mic_level:      f32, // dBFS
	mic_open:       bool,
	mic_time:       time.Tick,
	// Last time each user's voice was heard, for a speaking indicator.
	speaking:       map[proto.User_Num]time.Tick,
	// Messages (messages.odin): the windows of the conversations we
	// keep, ours on their way, the pictures messages show (blobs.odin),
	// who said last they're typing where, and how many messages from
	// others have come in the one on screen (the UI zeroes it when seen).
	timelines:      map[Timeline_Key]View_Timeline,
	// Roots of threads, fetched for the replies that point at them and
	// for the threads open.
	roots:          map[proto.Msg_Id]View_Root,
	// Messages asked for by id (roots, links) that aren't to be had.
	roots_missing:  map[proto.Msg_Id]bool,
	outbox:         [dynamic]View_Pending,
	// Files of messages being saved, or saved, by their blobs
	// (attachments.odin).
	saves:          map[proto.Blob_Id]View_Save,
	blobs:          map[proto.Blob_Id]View_Image,
	typing:         map[proto.Account_Id]View_Typing,
	unread:         int,
	// Pokes that came in, and mentions of us, for the UI to show (and
	// take) next frame.
	pokes:          [dynamic]View_Poke,
	mentioned:      [dynamic]View_Mention,
	// Whose screen we're watching, or 0.
	watching:       proto.User_Num,
	// How the pings to the server are doing (ping.odin).
	connection:     Connection_Stats,
	// Our DMs (buddies.odin): who each is with, and what's unread there.
	// Our buddies. And when people were last here, as far as the server
	// has said (proto/buddies.odin).
	dms:            [dynamic]View_DM,
	buddies:        [dynamic]proto.Account_Id,
	last_seen:      map[proto.Account_Id]proto.Unix_Ms,
	// File transfers in DMs, by the message that offers the file
	// (files.odin).
	files:          map[proto.Msg_Id]View_File,
	// The pinned messages of a conversation, last asked for (messages.odin).
	pins:           View_Pins,
	// Who reacted with an emoji, as last asked (messages.odin).
	reactors:       View_Reactors,
	// What the latest search found (search.odin).
	search:         View_Search,
	// The server's own emoji (emoji.odin).
	emoji:          View_Emoji,
	// Our account's settings as the server keeps them, whether the sync
	// has brought them all, and a count bumped whenever they change; and
	// the members last asked for (profiles.odin).
	shared:         map[string]string,
	shared_synced:  bool,
	shared_count:   int,
	shared_syncs:   int, // how many syncs have brought them
	members:        View_Members,
	// The server's roles, by id (roles.odin).
	roles:          [dynamic]View_Role,
	// The call our account is in, if any (calls.odin).
	call:           View_Call,
}

// A DM: who it's with, and what's unread there (see View_Channel).
View_DM :: struct {
	id:        proto.Conv_Id,
	with:      proto.Account_Id,
	last:      proto.Msg_Id,
	read:      proto.Msg_Id,
	unread:    int,
	notify:    proto.Notify_Level,
	// When its newest message was posted, 0 for none.
	last_time: proto.Unix_Ms,
}

View_File :: struct {
	name:     string, // owned
	size:     u64,
	outgoing: bool,
	state:    File_State,
	done:     u64, // bytes through
	rate:     f32, // bytes per second, lately
	path:     string, // where a received one is saved; owned
}

Key_Change :: struct {
	changed:  bool,
	server:   string, // the known_servers entry; owned
	saved:    [proto.KEY_SIZE]u8,
	received: [proto.KEY_SIZE]u8,
}

View_Poke :: struct {
	name:    string, // who poked us; owned
	message: string, // may be empty; owned
}

View_Mention :: struct {
	name:  string, // who mentioned us; owned
	place: string, // where; owned
	text:  string, // what they said, as shown; owned
	// The message, for a notification to go to when it's clicked.
	conv:  proto.Conv_Id,
	msg:   proto.Msg_Id,
	// Not a mention but a DM (`place` is who it's with), which isn't
	// told while it's being read.
	dm:    bool,
}

SPEAKING_HOLD :: 250 * time.Millisecond

view_init :: proc(v: ^View) {
}

// view_reset clears everything from a previous connection.
view_reset :: proc(v: ^View) {
	sync.guard(&v.mutex)
	view_clear_channels(v)
	v.my_num = 0
	delete(v.error)
	delete(v.server)
	delete(v.server_name)
	v.error, v.server, v.server_name = "", "", ""
	delete(v.server_about)
	delete(v.icon_jpeg)
	v.server_about, v.server_icon, v.icon_jpeg = "", 0, nil
	view_clear_key_change(v)
	v.status = .Disconnected
	v.server_key = {}
	v.viewing, v.my_room, v.voice_pending = 0, 0, false
	view_clear_browse(v)
	v.watching = 0
	v.connection = {}
	clear(&v.speaking)
	view_clear_timelines(v)
	view_clear_saves(v)
	view_clear_blobs(v)
	view_clear_pokes(v)
	view_clear_files(v)
	view_clear_pins(v)
	view_clear_reactors(v)
	clear(&v.roots_missing)
	view_clear_search(v)
	view_clear_emoji(v)
	view_clear_shared(v)
	view_clear_roles(v)
	v.call = {}
	v.shared_synced = false
	clear(&v.members.accounts)
	v.members.conv = 0
	view_clear_accounts(v)
	view_clear_devices(v)
	view_clear_invites(v)
	v.registration = {}
	delete(v.server_email)
	v.server_email = ""
	delete(v.login.error)
	delete(v.login.username)
	delete(v.login.email)
	delete(v.login.verify_code)
	delete(v.notice.text)
	v.login, v.notice = {}, {}
	v.me, v.permissions = 0, {}
}

// publish_logged_out takes what the server showed us off the screen:
// we're connected to it still, but not logged in any more.
publish_logged_out :: proc(c: ^Voice_Client) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	view_clear_channels(v)
	view_clear_timelines(v)
	view_clear_saves(v)
	view_clear_blobs(v)
	view_clear_accounts(v)
	view_clear_devices(v)
	view_clear_invites(v)
	clear(&v.buddies)
	clear(&v.last_seen)
	v.my_num, v.me, v.permissions = 0, 0, {}
	v.viewing, v.my_room, v.voice_pending = 0, 0, false
	view_clear_browse(v)
	v.watching = 0
	clear(&v.speaking)
}

view_destroy :: proc(v: ^View) {
	view_reset(v)
	delete(v.channels)
	delete(v.users)
	delete(v.speaking)
	delete(v.timelines)
	delete(v.roots)
	delete(v.roots_missing)
	view_clear_shared(v)
	delete(v.shared)
	delete(v.members.accounts)
	view_clear_roles(v)
	delete(v.roles)
	delete(v.reactors.accounts)
	view_clear_search(v)
	delete(v.search.found)
	delete(v.outbox)
	delete(v.saves)
	delete(v.typing)
	delete(v.blobs)
	delete(v.pokes)
	delete(v.mentioned)
	delete(v.dms)
	delete(v.buddies)
	delete(v.last_seen)
	delete(v.files)
	delete(v.pins.messages)
	delete(v.emoji.names)
	delete(v.accounts)
	delete(v.devices)
	view_destroy_invites(v)
	delete(v.browse)
}

@(private = "file")
view_clear_files :: proc(v: ^View) {
	for _, f in v.files {
		delete(f.name)
		delete(f.path)
	}
	clear(&v.files)
}

// publish_file shows how a transfer is going, at most every
// FILE_PUBLISH_INTERVAL unless `force` (a change of state).
publish_file :: proc(c: ^Voice_Client, t: ^File_Transfer, force := false) {
	v := c.view
	now := time.tick_now()
	if v == nil || (!force && time.tick_diff(t.last_publish, now) < FILE_PUBLISH_INTERVAL) {
		return
	}
	t.last_publish = now
	view_write(v)
	_, f, just_added, _ := map_entry(&v.files, t.id)
	if just_added || f.name != t.name {
		delete(f.name)
		f.name = strings.clone(t.name)
	}
	if f.path != t.path {
		delete(f.path)
		f.path = strings.clone(t.path)
	}
	f.size, f.outgoing, f.state, f.done, f.rate = t.size, t.outgoing, t.state, t.done, t.rate
}

@(private = "file")
view_clear_pokes :: proc(v: ^View) {
	for p in v.pokes {
		delete(p.name)
		delete(p.message)
	}
	clear(&v.pokes)
	for m in v.mentioned {
		delete(m.name)
		delete(m.place)
		delete(m.text)
	}
	clear(&v.mentioned)
}

publish_mentioned :: proc(
	c: ^Voice_Client,
	name, place, text: string,
	conv: proto.Conv_Id,
	msg: proto.Msg_Id,
	dm := false,
) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	append(
		&v.mentioned,
		View_Mention {
			name = strings.clone(name),
			place = strings.clone(place),
			text = strings.clone(text),
			conv = conv,
			msg = msg,
			dm = dm,
		},
	)
}

// view_take_mentions hands the UI the mentions of us that have come in,
// as copies in the temp allocator, and forgets them.
view_take_mentions :: proc(v: ^View) -> []View_Mention {
	sync.guard(&v.mutex)
	if len(v.mentioned) == 0 {
		return nil
	}
	out := make([]View_Mention, len(v.mentioned), context.temp_allocator)
	for m, i in v.mentioned {
		out[i] = {
			name  = strings.clone(m.name, context.temp_allocator),
			place = strings.clone(m.place, context.temp_allocator),
			text  = strings.clone(m.text, context.temp_allocator),
			conv  = m.conv,
			msg   = m.msg,
			dm    = m.dm,
		}
		delete(m.name)
		delete(m.place)
		delete(m.text)
	}
	clear(&v.mentioned)
	return out
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
view_clear_channels :: proc(v: ^View) {
	for ch in v.channels {
		delete(ch.name)
		delete(ch.topic)
		delete(ch.members)
	}
	clear(&v.channels)
	clear(&v.dms)
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

/*
view_write is sync.guard for a change to the View: once the lock is let
go, it wakes the UI to draw what changed. The UI only draws a frame when
there's something new to show (see ui_frame), so a change made under a
plain sync.guard waits for the next thing that does wake it.
*/
@(deferred_in = view_write_end)
view_write :: proc(v: ^View) -> bool {
	sync.mutex_lock(&v.mutex)
	return true
}

@(private = "file")
view_write_end :: proc(v: ^View) {
	sync.mutex_unlock(&v.mutex)
	view_changed(v)
}

// view_changed wakes the UI to draw a frame.
view_changed :: proc "contextless" (v: ^View) {
	if v.wake != nil {
		v.wake()
	}
}

publish_status :: proc(c: ^Voice_Client, status: Status, error := "") {
	c.status = status
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	v.status = status
	v.my_key = c.my_key
	if v.server == "" {
		v.server = strings.clone(c.server_addr)
	}
	delete(v.error)
	v.error = strings.clone(error)
}

// publish_server hands the UI what the server said about itself.
publish_server :: proc(c: ^Voice_Client) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	delete(v.server_name)
	v.server_name = strings.clone(c.rpc.server.name)
	v.max_attachment = c.rpc.server.max_attachment
	v.registration = c.rpc.server.registration
	delete(v.server_email)
	v.server_email = strings.clone(c.rpc.server.email)
	delete(v.server_about)
	v.server_about = strings.clone(c.rpc.server.description)
	if v.server_icon != c.rpc.server.icon || len(v.icon_jpeg) != len(c.rpc.server.icon_jpeg) {
		delete(v.icon_jpeg)
		v.icon_jpeg = nil
		if len(c.rpc.server.icon_jpeg) > 0 {
			v.icon_jpeg = make([]u8, len(c.rpc.server.icon_jpeg))
			copy(v.icon_jpeg, c.rpc.server.icon_jpeg)
		}
	}
	v.server_icon = c.rpc.server.icon
}

// publish_server_key tells the UI the server's key, which the per-user
// settings go by.
publish_server_key :: proc(c: ^Voice_Client) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	v.server_key = c.server_key
}

// publish_key_change tells the UI the server showed a key other than
// the one saved for it. The connection fails right after.
publish_key_change :: proc(c: ^Voice_Client, saved, received: [proto.KEY_SIZE]u8) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	view_clear_key_change(v)
	v.key_change = {
		changed  = true,
		server   = strings.clone(c.server_addr),
		saved    = saved,
		received = received,
	}
}

// Call with the mutex held.
view_clear_key_change :: proc(v: ^View) {
	delete(v.key_change.server)
	v.key_change = {}
}

publish_channels :: proc(c: ^Voice_Client) {
	v := c.view
	if v == nil {
		return
	}
	ch := &c.channels
	order := convs_ordered(c)
	dms := make([dynamic]View_DM, context.temp_allocator)
	for id, info in c.convs.convs {
		if info.kind == .DM {
			append(
				&dms,
				View_DM {
					id = id,
					with = dm_other(c, info),
					last = info.last,
					read = info.read,
					unread = info.unread,
					notify = info.notify,
					last_time = info.last_time,
				},
			)
		}
	}
	view_write(v)
	view_clear_channels(v)
	append(&v.dms, ..dms[:])
	for id in order {
		info := c.convs.convs[id]
		append(
			&v.channels,
			View_Channel {
				id = id,
				name = strings.clone(info.name),
				topic = strings.clone(info.topic),
				home = .Home in info.flags,
				private = .Private in info.flags,
				position = info.position,
				members = slice.clone(room_members(c, proto.Room(id))),
				read = info.read,
				unread = info.unread,
				mentions = info.mentions,
				notify = info.notify,
			},
		)
	}
	for &u in ch.state.users {
		v.users[u.num] = {
			account  = u.account,
			name     = strings.clone(display_name(c, u.num)),
			muted    = .Muted in u.flags,
			deafened = .Deafened in u.flags,
			sharing  = .Sharing in u.flags,
			room     = u.room,
		}
	}
	v.my_num = ch.state.your_user
	v.my_name = strings.clone(account_display(c, c.auth.me))
	v.viewing = c.convs.viewing
	v.channel = c.convs.channel
	v.my_room = proto.Conv_Id(my_room(c))
	v.voice_pending = c.convs.voice_pending
}

publish_mic :: proc(c: ^Voice_Client, level_db: f32, gate_open: bool) {
	v := c.view
	if v == nil {
		return
	}
	// Every captured frame: no waking for this. The meter, the only
	// thing that shows it, keeps drawing frames while it's on screen.
	sync.guard(&v.mutex)
	v.mic_level, v.mic_open, v.mic_time = level_db, gate_open, time.tick_now()
}

publish_voice :: proc(c: ^Voice_Client, speaker: proto.User_Num) {
	v := c.view
	if v == nil {
		return
	}
	// Every voice frame: the UI is only woken as someone starts to
	// speak, and wakes itself for when they'd stop (speaking_until).
	sync.guard(&v.mutex)
	was := is_speaking(v, speaker)
	v.speaking[speaker] = time.tick_now()
	if !was {
		view_changed(v)
	}
}

// speaking_until is when the first of those speaking stops, as far as
// is_speaking goes, unless more of their voice comes before then; zero
// if nobody is speaking. Call with the View locked.
speaking_until :: proc(v: ^View) -> (until: time.Tick) {
	for _, t in v.speaking {
		if time.tick_since(t) < SPEAKING_HOLD {
			end := time.tick_add(t, SPEAKING_HOLD)
			if until == {} || time.tick_diff(end, until) > 0 {
				until = end
			}
		}
	}
	return
}

publish_watching :: proc(c: ^Voice_Client) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	v.watching = c.video.watching
}

publish_connection :: proc(c: ^Voice_Client) {
	v := c.view
	if v == nil {
		return
	}
	stats := connection_stats(&c.ping, time.tick_now())
	// Twice a second: the UI is only woken when the indicator's bars
	// would change. Its tooltip, with the figures, keeps up by itself.
	sync.guard(&v.mutex)
	if stats.quality != v.connection.quality {
		view_changed(v)
	}
	v.connection = stats
}

publish_poke :: proc(c: ^Voice_Client, name, message: string) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	append(&v.pokes, View_Poke{strings.clone(name), strings.clone(message)})
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

package conn

import "core:strings"
import "core:sync"

import "client:richtext"
import "common:proto"

// What scripts (client/script) are told about a connection. A script runtime
// that wants to hear sets `Server_Conn.events` to a sink of its own; the code
// that handles the protocol calls event_* where something happens, and does
// nothing when there is no sink (just as with the View, headless_log.odin).
// The events are copies the runtime owns, so that the network thread never
// waits for a script. It drains the sink from another thread, or the same one.

Event_Connected :: struct {}

// The connection is gone (it comes back by itself; see connection_lost).
Event_Disconnected :: struct {
	why: string, // owned
}

// A message arrived, one of ours included (`mine`), in a channel, DM or group.
Event_Message :: struct {
	id:          proto.Msg_Id,
	conv:        proto.Conv_Id,
	channel:     string, // owned; the channel's name, or who the DM or group is with
	kind:       proto.Conv_Kind,
	msg_kind:    proto.Msg_Kind,
	author:      proto.Account_Id,
	author_name: string, // owned; as shown
	username:    string, // owned
	text:        string, // owned; as shown, with @name for mentions
	thread_root: proto.Msg_Id, // 0 if it isn't a reply
	time:        proto.Unix_Ms,
	mine:        bool,
	mentions_me: bool,
}

// Somebody else's activity (online, away, busy, offline) changed.
Event_Presence :: struct {
	account:  proto.Account_Id,
	name:     string, // owned; as shown
	username: string, // owned
	activity: proto.Activity,
	was:      proto.Activity,
}

Event :: union {
	Event_Connected,
	Event_Disconnected,
	Event_Message,
	Event_Presence,
}

// The events that have happened since they were last taken.
Event_Sink :: struct {
	mutex:  sync.Mutex,
	events: [dynamic]Event,
}

// The most events kept for a runtime that doesn't take them (a script that
// stalls the loop). Past this the oldest are dropped.
MAX_QUEUED_EVENTS :: 1000

event_destroy :: proc(e: ^Event) {
	switch &v in e {
	case Event_Connected:
	case Event_Disconnected:
		delete(v.why)
	case Event_Message:
		delete(v.channel)
		delete(v.author_name)
		delete(v.username)
		delete(v.text)
	case Event_Presence:
		delete(v.name)
		delete(v.username)
	}
	e^ = nil
}

sink_destroy :: proc(s: ^Event_Sink) {
	sync.guard(&s.mutex)
	for &e in s.events {
		event_destroy(&e)
	}
	delete(s.events)
	s.events = nil
}

// sink_take hands over the events, oldest first. They are in `allocator`'s
// slice and the caller destroys each with event_destroy.
sink_take :: proc(s: ^Event_Sink, allocator := context.allocator) -> []Event {
	sync.guard(&s.mutex)
	if len(s.events) == 0 {
		return nil
	}
	taken := make([]Event, len(s.events), allocator)
	copy(taken, s.events[:])
	clear(&s.events)
	return taken
}

event_put :: proc(c: ^Server_Conn, e: Event) {
	s := c.events
	sync.guard(&s.mutex)
	if len(s.events) >= MAX_QUEUED_EVENTS {
		old := s.events[0]
		event_destroy(&old)
		ordered_remove(&s.events, 0)
	}
	append(&s.events, e)
}

event_connected :: proc(c: ^Server_Conn) {
	if c.events != nil {
		event_put(c, Event_Connected{})
	}
}

event_disconnected :: proc(c: ^Server_Conn, why: string) {
	if c.events != nil {
		event_put(c, Event_Disconnected{why = strings.clone(why)})
	}
}

// `mention` is whether the message mentions us (see conv_new_message).
event_message :: proc(c: ^Server_Conn, m: proto.Message, mention: bool) {
	if c.events == nil {
		return
	}
	info := message_info(c, m)
	info.mentions_me ||= mention
	// message_info's strings are in the temp allocator.
	info.channel = strings.clone(info.channel)
	info.author_name = strings.clone(info.author_name)
	info.username = strings.clone(info.username)
	info.text = strings.clone(info.text)
	event_put(c, info)
}

// message_info describes a message the way scripts are told about it. The
// strings are in the temp allocator.
message_info :: proc(c: ^Server_Conn, m: proto.Message) -> Event_Message {
	info := c.convs.convs[m.conv] or_else Conv_Info{}
	shown, spans := richtext.mentions_display(m.text, c.auth.accounts, dir_roles(c), c.auth.me)
	acc := c.auth.accounts[m.sender] or_else Dir_Account{}
	mentions_me := false
	for sp in spans {
		mentions_me ||= sp.me
	}
	return Event_Message {
		id = m.id,
		conv = m.conv,
		channel = room_name(c, proto.Room(m.conv)),
		kind = info.kind,
		msg_kind = m.kind,
		author = m.sender,
		author_name = acc.display,
		username = acc.username,
		text = shown,
		thread_root = m.thread_root,
		time = m.time,
		mine = m.sender == c.auth.me,
		mentions_me = mentions_me,
	}
}

event_presence :: proc(c: ^Server_Conn, id: proto.Account_Id, was: proto.Activity) {
	if c.events == nil {
		return
	}
	acc := c.auth.accounts[id] or_else Dir_Account{}
	event_put(
		c,
		Event_Presence {
			account = id,
			name = strings.clone(acc.display),
			username = strings.clone(acc.username),
			activity = acc.activity,
			was = was,
		},
	)
}

// sink_put_for_test puts an event in the connection's sink, as the protocol
// code would.
sink_put_for_test :: proc(c: ^Server_Conn, e: Event) {
	event_put(c, e)
}

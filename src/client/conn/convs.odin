package conn

import log "common:wlog"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"

import "client:audio"
import "common:proto"

/*
The channels we're subscribed to and our DMs (src/common/proto/convs.odin),
and the two things we do with channels, which have nothing to do with
each other:

  - looking at one: its messages are the ones we're shown, and fetched
    (messages.odin);
  - talking in one: our connection is in its voice room (Voice_Join).
    Which room we're in, like who else is in which, comes back in the
    snapshot (channels.odin).

A DM (buddies.odin) is looked at the same way, from the buddy screen;
looking at it leaves the channel we were looking at to go back to.

And what we've read of each, which is the account's, not this device's:
the server says at login and whenever another device reads, we count
the messages that arrive in between, and what's being read here is
marked read (Mark_Read) as it's read, at most once a second for each.

The server tells us of our channels when we log in and as they change.
A channel to look at or talk in can be asked for by name before we know
of any (the -channel option, or what we were doing when the connection
started over): it's kept, and acted on once the server has told us what
there is.
*/

// A channel we're subscribed to, or a DM.
Conv_Info :: struct {
	kind:     proto.Conv_Kind,
	flags:    proto.Conv_Flags,
	name:     string, // owned
	topic:    string, // owned
	// Its newest message, what we've read, and so what's unread.
	last:     proto.Msg_Id,
	read:     proto.Msg_Id,
	unread:   int, // at most proto.UNREAD_CAP
	mentions: int,
	notify:   proto.Notify_Level,
	// A DM's two accounts (dm_other); 0 for a channel.
	a, b:     proto.Account_Id,
	position: int, // a channel's place in the list
}

// A Mark_Read to send, once a second has passed since the last.
Mark :: struct {
	due:  proto.Msg_Id, // 0 for none
	sent: time.Tick,
}

// How often what's read of one conversation is told to the server.
MARK_INTERVAL :: time.Second

// A channel there is to subscribe to.
Browse_Entry :: struct {
	id:    proto.Conv_Id,
	name:  string, // owned
	topic: string, // owned
}

Conv_Client :: struct {
	convs:         map[proto.Conv_Id]Conv_Info,
	// The server has told us of all our channels (Sync_End).
	synced:        bool,
	// The conversation whose messages we're shown, 0 for none; and the
	// channel last looked at, to go back to from a DM.
	viewing:       proto.Conv_Id,
	channel:       proto.Conv_Id,
	// Channels to look at and to talk in once we know of them, by name
	// (owned); and what was looked at before the connection started
	// over, by id.
	want_view:     string,
	want_voice:    string,
	want_view_id:  proto.Conv_Id,
	want_channel:  proto.Conv_Id,
	// The mail sound has played for DMs found waiting at login; once.
	mail_played:   bool,
	// A Voice_Join is on its way.
	voice_pending: bool,
	// The channels there were to subscribe to, the last time we asked,
	// for what (owned), as many pages of it as were asked for; whether
	// there are more; and which asking is the latest, whose answer is
	// the one taken.
	browse:        [dynamic]Browse_Entry,
	browse_query:  string,
	browse_more:   bool,
	browse_asked:  u64,
	// A channel to subscribe to by name (owned) that we didn't know of,
	// being looked for (conv_subscribe_command).
	finding:       string,
	finding_on:    bool,
	// The conversation being read: on screen, in a window that has the
	// focus, at its newest message. What arrives there is read as it
	// comes. 0 for none.
	reading:       proto.Conv_Id,
	marks:         map[proto.Conv_Id]Mark,
}

// Look at a conversation: by id, or a channel by name if the id is 0;
// with neither, nothing. With `back`, the channel last looked at (from
// a DM).
View_Command :: struct {
	conv: proto.Conv_Id,
	name: string, // owned by the command
	back: bool,
}
// Join a channel's voice room: by id, or by name if the id is 0. With
// neither, leave the room we're in.
Voice_Command :: struct {
	conv: proto.Conv_Id,
	name: string, // owned by the command
}
// Ask which channels there are to subscribe to: those whose name or
// topic has `query` in it (all for ""); with `more`, the next page of
// what was asked for last.
Browse_Command :: struct {
	query: string, // owned by the command
	more:  bool,
}
Subscribe_Command :: struct {
	conv: proto.Conv_Id,
	name: string, // owned by the command; for one in the last Browse
	on:   bool,
}
// Make a channel (for who may).
Create_Channel_Command :: struct {
	name:    string, // owned by the command
	topic:   string, // owned by the command
	private: bool, // only for those added to it
}
// The conversation being read, or 0 for none (see Conv_Client.reading).
Reading_Command :: struct {
	conv: proto.Conv_Id,
}
// How much a conversation may interrupt: by id, or by name if the id is
// 0.
Notify_Command :: struct {
	conv:   proto.Conv_Id,
	name:   string, // owned by the command
	notify: proto.Notify_Level,
}

convs_destroy :: proc(c: ^Voice_Client) {
	cv := &c.convs
	convs_clear(cv)
	delete(cv.convs)
	browse_clear(cv)
	delete(cv.browse)
	delete(cv.browse_query)
	delete(cv.finding)
	delete(cv.want_view)
	delete(cv.want_voice)
	delete(cv.marks)
	cv^ = {}
}

@(private = "file")
convs_clear :: proc(cv: ^Conv_Client) {
	for _, info in cv.convs {
		delete(info.name)
		delete(info.topic)
	}
	clear(&cv.convs)
	cv.synced = false
}

@(private = "file")
browse_clear :: proc(cv: ^Conv_Client) {
	for e in cv.browse {
		delete(e.name)
		delete(e.topic)
	}
	clear(&cv.browse)
}

@(private = "file")
want :: proc(slot: ^string, name: string) {
	delete(slot^)
	slot^ = strings.clone(name)
}

// conv_start_in is where to begin once connected: the channel called
// `name` is looked at, and its voice joined.
conv_start_in :: proc(c: ^Voice_Client, name: string) {
	want(&c.convs.want_view, name)
	want(&c.convs.want_voice, name)
}

// conv_start_viewing is conv_start_in without the voice: the channel
// called `name` is the one looked at once connected.
conv_start_viewing :: proc(c: ^Voice_Client, name: string) {
	want(&c.convs.want_view, name)
}

/*
convs_restart forgets our channels, for a connection the server has made
anew: it tells us of them again. What we were looking at and talking in
is asked for again once it has, since a new connection starts out doing
neither. With `forget`, we were logged out, and that's not to be.
*/
convs_restart :: proc(c: ^Voice_Client, forget := false) {
	cv := &c.convs
	if forget {
		want(&cv.want_view, "")
		want(&cv.want_voice, "")
		cv.want_view_id, cv.want_channel = 0, 0
		clear(&cv.marks)
	} else {
		if cv.viewing != 0 && cv.want_view == "" {
			cv.want_view_id = cv.viewing
		}
		cv.want_channel = cv.channel
		if info, ok := cv.convs[proto.Conv_Id(my_room(c))]; ok && cv.want_voice == "" {
			want(&cv.want_voice, info.name)
		}
	}
	convs_clear(cv)
	browse_clear(cv)
	cv.viewing, cv.channel = 0, 0
	cv.voice_pending = false
}

// conv_by_name is the channel of ours called `name`, whatever the case;
// 0 if there's none.
conv_by_name :: proc(c: ^Voice_Client, name: string) -> proto.Conv_Id {
	for id, info in c.convs.convs {
		if info.kind == .Channel && strings.equal_fold(info.name, name) {
			return id
		}
	}
	return 0
}

// home_conv is the channel everyone is in, or 0 before we know of it.
home_conv :: proc(c: ^Voice_Client) -> proto.Conv_Id {
	for id, info in c.convs.convs {
		if .Home in info.flags {
			return id
		}
	}
	return 0
}

// room_name is what to call a voice room: its channel's name, if it's
// one of ours. And for a conversation that's a DM, who it's with.
room_name :: proc(c: ^Voice_Client, room: proto.Room) -> string {
	if info, ok := c.convs.convs[proto.Conv_Id(room)]; ok {
		if info.kind == .DM {
			return fmt.tprintf("DMs with %s", account_display(c, dm_other(c, info)))
		}
		return info.name
	}
	return fmt.tprintf("channel #%d", room)
}

// convs_begin and convs_synced are the server starting to tell us how
// things are, and having told us (Sync_Begin, Sync_End).
convs_begin :: proc(c: ^Voice_Client) {
	convs_clear(&c.convs)
}

convs_synced :: proc(c: ^Voice_Client) {
	cv := &c.convs
	cv.synced = true

	// What to look at: what was asked for, or else the home channel.
	// (One that's gone, or was left on another device, is no loss.) And
	// the channel to go back to, from a DM.
	// The one looked at last on any of our devices comes first, when
	// the client starts (profiles.odin).
	view: proto.Conv_Id
	if shared := shared_view(c); shared in cv.convs {
		view = shared
	}
	if view == 0 && cv.want_view != "" {
		view = conv_by_name(c, cv.want_view)
	}
	if view == 0 && cv.want_view_id in cv.convs {
		view = cv.want_view_id
	}
	if view == 0 {
		view = home_conv(c)
	}
	if info, ok := cv.convs[cv.want_channel]; ok && info.kind == .Channel {
		cv.channel = cv.want_channel
	}
	want(&cv.want_view, "")
	cv.want_view_id, cv.want_channel = 0, 0
	conv_view(c, view)

	// DMs that came while we were away are mail, announced once.
	if !cv.mail_played && !quiet(c) {
		for _, info in cv.convs {
			if info.kind == .DM && info.unread > 0 && info.notify != .None {
				cv.mail_played = true
				audio.voice_notification_play(&c.voice, .Mail)
				break
			}
		}
	}

	if cv.want_voice != "" {
		if room := conv_by_name(c, cv.want_voice); room != 0 {
			voice_join(c, proto.Room(room))
		} else {
			log.warnf("there's no channel called %q among yours to talk in", cv.want_voice)
		}
		want(&cv.want_voice, "")
	}
	publish_channels(c)
}

// conv_event takes an event about conversations or rooms; false if
// `op` isn't one.
conv_event :: proc(c: ^Voice_Client, op: proto.Event_Op, body: []u8) -> bool {
	cv := &c.convs
	#partial switch op {
	case .Conv_Changed:
		record, ok := proto.decode_conv(body)
		if !ok || !record.member {
			break
		}
		_, info, added, _ := map_entry(&cv.convs, record.id)
		delete(info.name)
		delete(info.topic)
		// What we've read here that the server may not have heard yet
		// stays read.
		read, unread, mentions := record.read, record.unread, record.mentions
		if !added && info.read > record.read {
			read, unread, mentions = info.read, info.unread, info.mentions
		}
		info^ = {
			kind     = record.kind,
			flags    = record.flags,
			name     = strings.clone(record.name),
			topic    = strings.clone(record.topic),
			last     = max(record.last, info.last),
			read     = read,
			unread   = unread,
			mentions = mentions,
			notify   = record.notify,
			a        = record.a,
			b        = record.b,
			position = record.position,
		}
		if cv.synced {
			if added && record.kind == .Channel {
				log.infof("subscribed to %q", record.name)
			}
			publish_channels(c)
		}
	case .Conv_Removed:
		id, ok := proto.decode_conv_id(body)
		info, had := cv.convs[id]
		if !ok || !had {
			break
		}
		log.infof("no longer subscribed to %q", info.name)
		delete(info.name)
		delete(info.topic)
		delete_key(&cv.convs, id)
		if cv.channel == id {
			cv.channel = 0
		}
		// Its chat isn't ours to read any more; the home channel's is.
		if cv.viewing == id {
			cv.viewing = 0
			conv_view(c, home_conv(c))
		}
		publish_channels(c)
	case .Read_Changed:
		state, ok := proto.decode_read_changed(body)
		info, have := &cv.convs[state.conv]
		if !ok || !have {
			break
		}
		// Not if we've read further here, and are about to say so.
		if state.read < info.read || state.read < cv.marks[state.conv].due {
			break
		}
		info.read, info.unread, info.mentions = state.read, state.unread, state.mentions
		info.last = max(info.last, state.read)
		publish_channels(c)
	case .Voice_Moved:
		room, _ := proto.decode_room(body)
		log.infof(
			"another of your devices joined the voice of %q, which took this one out",
			room_name(c, room),
		)
	case:
		return false
	}
	return true
}

// conv_view makes `conv` the conversation whose messages we're shown;
// 0 for none.
conv_view :: proc(c: ^Voice_Client, conv: proto.Conv_Id) {
	cv := &c.convs
	if conv == cv.viewing {
		return
	}
	info, known := cv.convs[conv]
	if conv != 0 && !known {
		log.warn("that's not one of your conversations")
		return
	}
	cv.viewing = conv
	if conv != 0 {
		log.infof(
			"looking at %s",
			room_name(c, proto.Room(conv)) if info.kind == .DM else fmt.tprintf("%q", info.name),
		)
	}
	if known && info.kind == .Channel {
		cv.channel = conv
	}
	shared_viewed(c, conv)
	messages_view(c, conv)
	if c.view == nil {
		// Headless: what's looked at is read, since it's all in the log.
		conv_reading(c, conv)
	}
	publish_channels(c)
}

conv_view_command :: proc(c: ^Voice_Client, cmd: View_Command) {
	cv := &c.convs
	if !cv.synced {
		if cmd.name != "" {
			want(&cv.want_view, cmd.name)
		}
		return
	}
	switch {
	case cmd.back:
		conv_view(c, cv.channel if cv.channel in cv.convs else home_conv(c))
		return
	case cmd.conv == 0 && cmd.name == "":
		conv_view(c, 0)
		return
	}
	conv := cmd.conv if cmd.conv != 0 else conv_by_name(c, cmd.name)
	if conv == 0 {
		log.warnf("there's no channel called %q among yours (/channels lists them)", cmd.name)
		return
	}
	conv_view(c, conv)
}

// voice_join puts us in a voice room, or with 0 takes us out of the one
// we're in. The snapshot shows when it has happened.
voice_join :: proc(c: ^Voice_Client, room: proto.Room) {
	cv := &c.convs
	if room == my_room(c) && !cv.voice_pending {
		return
	}
	cv.voice_pending = true
	buf: [4]u8
	request(
		c,
		.Voice_Join,
		proto.encode_room(&buf, room),
		proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
			c.convs.voice_pending = false
			if status != .Ok && status != .Reset {
				log.warnf(
					"couldn't join the voice of %q (%v)",
					room_name(c, proto.Room(tag)),
					status,
				)
			}
			publish_channels(c)
		},
		u64(room),
	)
	publish_channels(c)
}

voice_command :: proc(c: ^Voice_Client, cmd: Voice_Command) {
	cv := &c.convs
	if cmd.conv == 0 && cmd.name == "" {
		voice_join(c, 0)
		return
	}
	if !cv.synced {
		want(&cv.want_voice, cmd.name)
		return
	}
	conv := cmd.conv if cmd.conv != 0 else conv_by_name(c, cmd.name)
	if conv == 0 {
		log.warnf("there's no channel called %q among yours (/channels lists them)", cmd.name)
		return
	}
	voice_join(c, proto.Room(conv))
}

/*
conv_browse asks which channels there are to subscribe to that match
`query`: the first page, or with `more`, the next page of the last
query. The answer goes to the UI, and headless to the log; only the
answer to the latest asking is taken.
*/
conv_browse :: proc(c: ^Voice_Client, query: string, more := false) {
	cv := &c.convs
	offset := 0
	if more {
		offset = len(cv.browse)
	} else if query != cv.browse_query {
		delete(cv.browse_query)
		cv.browse_query = strings.clone(query)
	}
	cv.browse_asked += 1
	buf: [proto.CONV_BROWSE_MAX_SIZE]u8
	body := proto.encode_conv_browse(
		&buf,
		{query = cv.browse_query, offset = offset, limit = proto.BROWSE_PAGE},
	)
	tag := cv.browse_asked << 16 | u64(offset)
	request(
		c,
		.Conv_Browse,
		body,
		proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
			cv := &c.convs
			if status != .Ok || tag >> 16 != cv.browse_asked {
				return
			}
			buf: [proto.MAX_BROWSE_LIMIT]proto.Conv
			more, found, ok := proto.decode_browse_page(body, buf[:])
			if !ok {
				return
			}
			if tag & 0xffff == 0 {
				browse_clear(cv)
			}
			cv.browse_more = more
			for record in found {
				append(
					&cv.browse,
					Browse_Entry {
						id = record.id,
						name = strings.clone(record.name),
						topic = strings.clone(record.topic),
					},
				)
			}
			if c.view == nil {
				if len(cv.browse) == 0 {
					log.info(
						"there are no other channels to subscribe to" if cv.browse_query == "" else "no other channel has that in its name or topic",
					)
				}
				for record in found {
					log.infof(
						"can subscribe to %q%s%s",
						record.name,
						": " if record.topic != "" else "",
						record.topic,
					)
				}
				if more {
					log.info("and more (/browse more)")
				}
			}
			publish_browse(c)
		},
		tag,
	)
}

conv_subscribe_command :: proc(c: ^Voice_Client, cmd: Subscribe_Command) {
	conv := cmd.conv
	if conv == 0 {
		// One of ours to leave, or one we were told of to join.
		conv = conv_by_name(c, cmd.name)
		for e in c.convs.browse {
			if conv == 0 && strings.equal_fold(e.name, cmd.name) {
				conv = e.id
			}
		}
	}
	if conv == 0 && cmd.on {
		// One we haven't been shown: asked for by its name.
		cv := &c.convs
		delete(cv.finding)
		cv.finding, cv.finding_on = strings.clone(cmd.name), cmd.on
		buf: [proto.CONV_BROWSE_MAX_SIZE]u8
		body := proto.encode_conv_browse(&buf, {query = cmd.name, limit = proto.MAX_BROWSE_LIMIT})
		request(
			c,
			.Conv_Browse,
			body,
			proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
				cv := &c.convs
				name := cv.finding
				cv.finding = ""
				defer delete(name)
				buf: [proto.MAX_BROWSE_LIMIT]proto.Conv
				_, found, ok := proto.decode_browse_page(body, buf[:])
				if status != .Ok || !ok {
					return
				}
				for record in found {
					if strings.equal_fold(record.name, name) {
						conv_subscribe(c, record.id, cv.finding_on)
						return
					}
				}
				log.warnf("there's no channel called %q to subscribe to", name)
			},
		)
		return
	}
	if conv == 0 {
		log.warnf("there's no channel called %q among yours", cmd.name)
		return
	}
	conv_subscribe(c, conv, cmd.on)
}

@(private = "file")
conv_subscribe :: proc(c: ^Voice_Client, conv: proto.Conv_Id, on: bool) {
	buf: [proto.CONV_SUBSCRIBE_SIZE]u8
	request(
		c,
		.Conv_Subscribe,
		proto.encode_conv_subscribe(&buf, conv, on),
		proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
			#partial switch status {
			case .Ok:
				// What there is to subscribe to has changed with it.
				conv_browse(c, c.convs.browse_query)
			case .Denied:
				log.warn("that channel can't be left: everyone is in it")
			case .Reset:
			case:
				log.warnf("the server wouldn't do that (%v)", status)
			}
		},
	)
}

conv_create :: proc(c: ^Voice_Client, name, topic: string, private := false) {
	buf: [proto.CONV_CREATE_MAX_SIZE]u8
	body := proto.encode_conv_create(buf[:], name, topic, private)
	if body == nil {
		log.warn("that name or topic is too long")
		return
	}
	request(
		c,
		.Conv_Create,
		body,
		proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
			text: string
			#partial switch status {
			case .Ok:
				text = "Channel made."
			case .Denied:
				text = "You aren't allowed to make channels."
			case .Conflict:
				text = "There's a channel with that name already."
			case .Invalid:
				text = "A channel needs a name."
			case .Too_Large:
				text = "There are as many channels as there can be."
			case .Reset:
				return
			case:
				text = fmt.tprintf("The server couldn't do that (%v).", status)
			}
			notify(c, status == .Ok, text)
		},
	)
}

/*
conv_new_message counts a message that was just posted (and wasn't here
before) as unread, or not: our own read everything up to them, and one
in the conversation being read is read. It says whether the message may
interrupt, by its conversation's level, and whether it's a mention of
us that's told on the desktop: not in a muted conversation (where it's
still counted), but in the one being read too (which may be on a server
that isn't shown, or in a window that's in the background).
*/
conv_new_message :: proc(c: ^Voice_Client, m: proto.Message) -> (interrupts: bool, mention: bool) {
	cv := &c.convs
	info, ok := &cv.convs[m.conv]
	if !ok {
		return false, false
	}
	info.last = max(info.last, m.id)
	switch {
	case m.sender == c.auth.me:
		if m.id > info.read {
			info.read, info.unread, info.mentions = m.id, 0, 0
		}
	case m.id <= info.read:
		return false, false
	case cv.reading == m.conv:
		mark_read(c, m.conv, m.id)
		return false, info.notify != .None && mentions_me(c, m)
	case:
		info.unread = min(info.unread + 1, proto.UNREAD_CAP)
		mention = mentions_me(c, m)
		if mention {
			info.mentions = min(info.mentions + 1, proto.UNREAD_CAP)
		}
		interrupts = info.notify == .All || (info.notify == .Mentions && mention)
		mention &&= info.notify != .None
	}
	publish_channels(c)
	return
}

// mentions_me is whether a message mentions us. <@everyone> is only
// ever stored from someone allowed it.
@(private = "file")
mentions_me :: proc(c: ^Voice_Client, m: proto.Message) -> bool {
	return m.kind == .Text && .Deleted not_in m.flags && proto.mentions_account(m.text, c.auth.me)
}

// conv_reading is the UI saying which conversation is being read, if
// any: what's in it is read.
conv_reading :: proc(c: ^Voice_Client, conv: proto.Conv_Id) {
	cv := &c.convs
	cv.reading = conv
	if info, ok := cv.convs[conv]; ok && info.last > info.read {
		mark_read(c, conv, info.last)
	}
}

// mark_read reads a conversation up to `id`, here and now, and tells the
// server when it may be told (convs_step).
@(private = "file")
mark_read :: proc(c: ^Voice_Client, conv: proto.Conv_Id, id: proto.Msg_Id) {
	cv := &c.convs
	info, ok := &cv.convs[conv]
	if !ok || id <= info.read {
		return
	}
	info.read, info.unread, info.mentions = id, 0, 0
	_, m, _, _ := map_entry(&cv.marks, conv)
	m.due = max(m.due, id)
	publish_channels(c)
}

// convs_step sends what's been read, at most once every MARK_INTERVAL for
// each conversation.
convs_step :: proc(c: ^Voice_Client) {
	cv := &c.convs
	if !cv.synced || !c.has_current || len(cv.marks) == 0 {
		return
	}
	for conv, &m in cv.marks {
		if m.due == 0 || (m.sent != {} && time.tick_since(m.sent) < MARK_INTERVAL) {
			continue
		}
		buf: [proto.MARK_READ_SIZE]u8
		request(c, .Mark_Read, proto.encode_mark_read(&buf, conv, m.due))
		m.due, m.sent = 0, time.tick_now()
	}
}

conv_notify :: proc(c: ^Voice_Client, cmd: Notify_Command) {
	conv := cmd.conv if cmd.conv != 0 else conv_by_name(c, cmd.name)
	if conv not_in c.convs.convs {
		log.warnf("there's no channel called %q among yours (/channels lists them)", cmd.name)
		return
	}
	buf: [proto.CONV_NOTIFY_SIZE]u8
	request(
		c,
		.Conv_Notify,
		proto.encode_conv_notify(&buf, conv, cmd.notify),
		proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
			if status != .Ok && status != .Reset {
				log.warnf("the server wouldn't change that (%v)", status)
			}
		},
	)
}

// list_channels logs our channels, with who is talking in each.
list_channels :: proc(c: ^Voice_Client) {
	cv := &c.convs
	if !cv.synced {
		log.info("not logged in yet")
		return
	}
	room := my_room(c)
	for id in convs_ordered(c) {
		info := cv.convs[id]
		unread := ""
		if info.unread > 0 {
			mentions :=
				fmt.tprintf(", %s mentioning you", unread_count(info.mentions)) if info.mentions > 0 else ""
			unread = fmt.tprintf(
				" (%s unread%s%s)",
				unread_count(info.unread),
				mentions,
				", muted" if info.notify == .None else "",
			)
		}
		log.infof(
			"%s%s %s%s: %s",
			"*" if id == cv.viewing else " ",
			"♪" if proto.Room(id) == room else " ",
			info.name,
			unread,
			members_string(c, room_members(c, proto.Room(id))),
		)
	}
}

// convs_ordered is our channels in the order a list shows them: the
// home channel, then as they were made. In the temp allocator.
convs_ordered :: proc(c: ^Voice_Client) -> []proto.Conv_Id {
	ids := make([dynamic]proto.Conv_Id, 0, len(c.convs.convs), context.temp_allocator)
	for id, info in c.convs.convs {
		if info.kind == .Channel {
			append(&ids, id)
		}
	}
	// The home channel first, then by place, then by id, as the server
	// has them.
	context.user_ptr = c
	slice.sort_by(ids[:], proc(x, y: proto.Conv_Id) -> bool {
		c := (^Voice_Client)(context.user_ptr)
		a, b := c.convs.convs[x], c.convs.convs[y]
		if (.Home in a.flags) != (.Home in b.flags) {
			return .Home in a.flags
		}
		if a.position != b.position {
			return a.position < b.position
		}
		return x < y
	})
	return ids[:]
}

// unread_count is how an unread count is shown: past the cap, "99+".
unread_count :: proc(n: int) -> string {
	return "99+" if n >= proto.UNREAD_CAP else fmt.tprintf("%d", n)
}

publish_browse :: proc(c: ^Voice_Client) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	view_clear_browse(v)
	for e in c.convs.browse {
		append(
			&v.browse,
			Browse_Entry{id = e.id, name = strings.clone(e.name), topic = strings.clone(e.topic)},
		)
	}
	v.browse_more = c.convs.browse_more
	v.browse_count += 1
}

// Call with the mutex held.
view_clear_browse :: proc(v: ^View) {
	for e in v.browse {
		delete(e.name)
		delete(e.topic)
	}
	clear(&v.browse)
}

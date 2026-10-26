package conn

import log "common:wlog"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"

import "client:audio"
import "common:proto"

// This file handles the channels we are subscribed to and our DMs
// (src/common/proto/convs.odin), and the two unrelated things we do with
// channels:
//
//   - Looking at one: its messages are the ones we are shown and fetch
//     (see messages.odin).
//   - Talking in one: our connection is in its voice room (Voice_Join). Which
//     room we are in, like who else is in which room, comes back in the
//     snapshot (see presence.odin).
//
// A DM (see buddies.odin) is looked at the same way, from the buddy screen.
// Looking at a DM leaves the channel we were looking at, so we can go back to
// it later.
//
// What we have read of each conversation belongs to the account, not to this
// device. The server tells us at login and whenever another device reads. We
// count the messages that arrive in between, and what is being read here is
// marked as read (Mark_Read) as it is read, at most once a second for each
// conversation.
//
// The server tells us about our channels when we log in and whenever they
// change. A channel to look at or talk in can be requested by name before we
// know of any channels (with the -channel option, or from what we were doing
// before the connection restarted). The request is kept and acted on once the
// server has told us which channels there are.

// A channel we are subscribed to, or a DM.
Conv_Info :: struct {
	kind:      proto.Conv_Kind,
	flags:     proto.Conv_Flags,
	name:      string, // owned
	topic:     string, // owned
	// Its newest message, what we have read, and from those what is unread.
	last:      proto.Msg_Id,
	read:      proto.Msg_Id,
	unread:    int, // at most proto.UNREAD_CAP
	// When the newest message was posted, 0 if there is none. DMs from every
	// server are sorted by this.
	last_time: proto.Unix_Ms,
	mentions:  int,
	notify:    proto.Notify_Level,
	// A DM's two accounts (see dm_other); 0 for a channel.
	a, b:      proto.Account_Id,
	position:  int, // the position of a channel in the list
	rights:    proto.Conv_Rights, // what we may do there
}

// A Mark_Read to send, once a second has passed since the last one.
Mark :: struct {
	due:  proto.Msg_Id, // 0 if there is none
	sent: time.Tick,
}

// How often the server is told what has been read of one conversation.
MARK_INTERVAL :: time.Second

// A channel that can be subscribed to, or for those who manage channels, any
// channel (see All_Channels_Command).
Browse_Entry :: struct {
	id:       proto.Conv_Id,
	name:     string, // owned
	topic:    string, // owned
	flags:    proto.Conv_Flags,
	member:   bool, // we are in it
	position: int,
}

Conv_Client :: struct {
	convs:         map[proto.Conv_Id]Conv_Info,
	// The server has told us about all our channels (Sync_End).
	synced:        bool,
	// The conversation whose messages we are shown, 0 if there is none, and the
	// channel that was looked at last, to go back to from a DM.
	viewing:       proto.Conv_Id,
	channel:       proto.Conv_Id,
	// Channels to look at and to talk in once we know about them, by name
	// (owned), and what was looked at before the connection restarted, by id.
	want_view:     string,
	want_voice:    string,
	want_view_id:  proto.Conv_Id,
	want_channel:  proto.Conv_Id,
	// Whether the mail sound has already played (only once) for DMs that were
	// waiting at login.
	mail_played:   bool,
	// A Voice_Join request is on its way.
	voice_pending: bool,
	// The room a moderator moved us into and its channel's name (owned),
	// until we leave it (moderation.odin), else 0 and "".
	guest_room:    proto.Room,
	guest_name:    string,
	// The channels that could be subscribed to when we last asked, as many
	// pages of them as were requested from `browse_offset` on, how many were
	// asked for at a time, the query they were requested with (owned), whether
	// there are more, and which request is the latest. Only the answer to the
	// latest request is used.
	browse:        [dynamic]Browse_Entry,
	browse_offset: int,
	browse_limit:  int,
	browse_query:  string,
	browse_more:   bool,
	browse_asked:  u64,
	// Every channel, for managing them (fetch_all_channels): the ones that have
	// arrived so far, which fetch is the latest, and whether they were ever
	// asked for (so that they are kept up to date).
	all:           [dynamic]Browse_Entry,
	all_asked:     u64,
	all_wanted:    bool,
	// How many changes to channels are on their way (roles.odin). The lists are
	// fetched again once the last of them is done, not after each.
	changing:      int,
	// The name (owned) of a channel to subscribe to that we didn't know about
	// and are looking for (see conv_subscribe_command).
	finding:       string,
	finding_on:    bool,
	// The conversation being read, meaning it is on screen, in a window that has
	// the focus, and scrolled to its newest message. What arrives there is read
	// as it comes in. 0 if there is none.
	reading:       proto.Conv_Id,
	marks:         map[proto.Conv_Id]Mark,
}

// Looks at a conversation, identified by id, or by channel name if the id is 0.
// With neither, nothing is shown. With `back`, it goes back to the channel that
// was looked at last (from a DM).
View_Command :: struct {
	conv: proto.Conv_Id,
	name: string, // owned by the command
	back: bool,
}
// Joins a channel's voice room, identified by id, or by name if the id is 0.
// With neither, it leaves the room we are in.
Voice_Command :: struct {
	conv: proto.Conv_Id,
	name: string, // owned by the command
}
// Asks which channels can be subscribed to, namely those whose name or topic
// contains `query` (all channels for ""): `limit` of them (0: proto.BROWSE_PAGE)
// from the `offset`th on. With `more`, it requests the next page of what was
// requested last, in addition to what it has.
Browse_Command :: struct {
	query:  string, // owned by the command
	offset: int,
	limit:  int,
	more:   bool,
}
// Fetches every channel, for those who manage channels (View.all_channels).
All_Channels_Command :: struct {}
Subscribe_Command :: struct {
	conv: proto.Conv_Id,
	name: string, // owned by the command; for a channel from the last Browse
	on:   bool,
}
// Creates a channel (only for users with permission to do so).
Create_Channel_Command :: struct {
	name:    string, // owned by the command
	topic:   string, // owned by the command
	private: bool, // only visible to those who were added to it
	flags:   proto.Conv_Flags, // Default, Text_Only
}
// The conversation being read, or 0 for none (see Conv_Client.reading).
Reading_Command :: struct {
	conv: proto.Conv_Id,
}
// Sets how much a conversation may notify the user, identified by id, or by name
// if the id is 0.
Notify_Command :: struct {
	conv:   proto.Conv_Id,
	name:   string, // owned by the command
	notify: proto.Notify_Level,
}

convs_destroy :: proc(c: ^Server_Conn) {
	cv := &c.convs
	convs_clear(cv)
	delete(cv.convs)
	browse_clear(cv)
	delete(cv.browse)
	delete(cv.browse_query)
	entries_clear(&cv.all)
	delete(cv.all)
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
	guest_forget(cv)
}

@(private = "file")
browse_clear :: proc(cv: ^Conv_Client) {
	entries_clear(&cv.browse)
}

entries_clear :: proc(entries: ^[dynamic]Browse_Entry) {
	for e in entries {
		delete(e.name)
		delete(e.topic)
	}
	clear(entries)
}

// entry_of makes a list's entry (owning its strings) from what the server sent.
@(private = "file")
entry_of :: proc(record: proto.Conv) -> Browse_Entry {
	return {
		id = record.id,
		name = strings.clone(record.name),
		topic = strings.clone(record.topic),
		flags = record.flags,
		member = record.member,
		position = record.position,
	}
}

@(private = "file")
want :: proc(slot: ^string, name: string) {
	delete(slot^)
	slot^ = strings.clone(name)
}

// conv_start_in sets where to begin once connected: the channel called `name` is
// looked at, and its voice room is joined.
conv_start_in :: proc(c: ^Server_Conn, name: string) {
	want(&c.convs.want_view, name)
	want(&c.convs.want_voice, name)
}

// conv_start_viewing is like conv_start_in, but without joining the voice room:
// the channel called `name` is the one looked at once connected.
conv_start_viewing :: proc(c: ^Server_Conn, name: string) {
	want(&c.convs.want_view, name)
}

// convs_restart forgets our channels when the server has made a new connection
// for us, because it tells us about them again. What we were looking at and
// talking in is requested again once it has, since a new connection starts out
// doing neither. With `forget`, we were logged out, and that is not wanted.
convs_restart :: proc(c: ^Server_Conn, forget := false) {
	cv := &c.convs
	if forget {
		want(&cv.want_view, "")
		want(&cv.want_voice, "")
		cv.want_view_id, cv.want_channel = 0, 0
		clear(&cv.marks)
		cv.all_wanted = false
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
	entries_clear(&cv.all)
	cv.all_asked += 1 // whatever was on its way is from before
	cv.viewing, cv.channel = 0, 0
	cv.voice_pending = false
}

// conv_by_name returns the channel of ours called `name`, ignoring case, or 0 if
// there is none.
conv_by_name :: proc(c: ^Server_Conn, name: string) -> proto.Conv_Id {
	for id, info in c.convs.convs {
		if info.kind == .Channel && strings.equal_fold(info.name, name) {
			return id
		}
	}
	return 0
}

// home_conv returns the channel everyone is in, or 0 before we know about it.
home_conv :: proc(c: ^Server_Conn) -> proto.Conv_Id {
	for id, info in c.convs.convs {
		if .Home in info.flags {
			return id
		}
	}
	return 0
}

// room_name returns what to call a voice room, which is the name of its channel
// if it is one of ours. For a DM it is who the DM is with.
room_name :: proc(c: ^Server_Conn, room: proto.Room) -> string {
	if info, ok := c.convs.convs[proto.Conv_Id(room)]; ok {
		if info.kind == .DM {
			return fmt.tprintf("DMs with %s", account_display(c, dm_other(c, info)))
		}
		return info.name
	}
	if room == c.convs.guest_room && c.convs.guest_name != "" {
		return c.convs.guest_name
	}
	return fmt.tprintf("channel #%d", room)
}

// convs_begin and convs_synced handle the server starting to tell us how things
// are and having told us (Sync_Begin and Sync_End).
convs_begin :: proc(c: ^Server_Conn) {
	convs_clear(&c.convs)
}

convs_synced :: proc(c: ^Server_Conn) {
	cv := &c.convs
	cv.synced = true

	// Decide what to look at: what was requested, or else the home channel.
	// (A channel that is gone, or was left on another device, is no loss.) Also
	// decide the channel to go back to from a DM. When the client starts, the
	// conversation that was looked at last on any of our devices comes first
	// (see profiles.odin).
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

	// DMs that arrived while we were away count as mail, which is announced once.
	if !cv.mail_played && !quiet(c) {
		for _, info in cv.convs {
			if info.kind == .DM && info.unread > 0 && info.notify != .None {
				cv.mail_played = true
				audio.voice_notification_play(&c.voice, .Direct_Message)
				break
			}
		}
	}

	if cv.want_voice != "" {
		if room := conv_by_name(c, cv.want_voice); room != 0 {
			if .Voice in cv.convs[room].rights {
				voice_join(c, proto.Room(room))
			} else {
				log.warnf("%q has no voice room for us any more", cv.want_voice)
			}
		} else {
			log.warnf("there is no channel called %q among yours to talk in", cv.want_voice)
		}
		want(&cv.want_voice, "")
	}
	publish_channels(c)
}

// conv_event handles an event about conversations or rooms. It returns false if
// `op` is not one.
conv_event :: proc(c: ^Server_Conn, op: proto.Event_Op, body: []u8) -> bool {
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
		// What we have read here that the server may not know yet stays read.
		read, unread, mentions := record.read, record.unread, record.mentions
		if !added && info.read > record.read {
			read, unread, mentions = info.read, info.unread, info.mentions
		}
		info^ = {
			kind      = record.kind,
			flags     = record.flags,
			name      = strings.clone(record.name),
			topic     = strings.clone(record.topic),
			last      = max(record.last, info.last),
			last_time = max(record.last_time, info.last_time),
			read      = read,
			unread    = unread,
			mentions  = mentions,
			notify    = record.notify,
			a         = record.a,
			b         = record.b,
			position  = record.position,
			rights    = record.rights,
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
		// Its chat is no longer ours to read, but the home channel's is.
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
		// Ignore this if we have read further here and are about to tell the server.
		if state.read < info.read || state.read < cv.marks[state.conv].due {
			break
		}
		info.read, info.unread, info.mentions = state.read, state.unread, state.mentions
		info.last = max(info.last, state.read)
		publish_channels(c)
	case .Voice_Moved:
		voice_moved(c, body) // moderation.odin
	case:
		return false
	}
	return true
}

// conv_view makes `conv` the conversation whose messages we are shown. 0 means
// none.
conv_view :: proc(c: ^Server_Conn, conv: proto.Conv_Id) {
	cv := &c.convs
	if conv == cv.viewing {
		return
	}
	info, known := cv.convs[conv]
	if conv != 0 && !known {
		log.warn("that is not one of your conversations")
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
		// Headless: what is looked at counts as read, since it is all in the log.
		conv_reading(c, conv)
	}
	publish_channels(c)
}

conv_view_command :: proc(c: ^Server_Conn, cmd: View_Command) {
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

// voice_join puts us in a voice room, or with 0 takes us out of the room we are
// in. The snapshot shows when it has happened.
voice_join :: proc(c: ^Server_Conn, room: proto.Room) {
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
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			c.convs.voice_pending = false
			if status != .Ok && status != .Reset {
				log.warnf(
					"failed to join the voice of %q (%v)",
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

voice_command :: proc(c: ^Server_Conn, cmd: Voice_Command) {
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
	// A channel we aren't in is left to the server to judge.
	if info, ok := cv.convs[conv]; ok && .Voice not_in info.rights {
		text :=
			"That channel has no voice room." if .Text_Only in info.flags else "You can't talk in that channel."
		notify(c, false, text)
		return
	}
	voice_join(c, proto.Room(conv))
}

// conv_browse asks which channels can be subscribed to that match the
// command's query: the page it asks for, or with `more`, the next page of the
// last query. The answer goes to the UI, or to the log when running headless.
// Only the answer to the latest request is used.
conv_browse :: proc(c: ^Server_Conn, cmd: Browse_Command) {
	cv := &c.convs
	offset := cmd.offset
	adding := cmd.more
	if adding {
		offset = cv.browse_offset + len(cv.browse)
	} else {
		if cmd.query != cv.browse_query {
			delete(cv.browse_query)
			cv.browse_query = strings.clone(cmd.query)
		}
		cv.browse_limit = cmd.limit if cmd.limit > 0 else proto.BROWSE_PAGE
	}
	// The offset is a u16 on the wire; clamp it here so that what the tag
	// remembers is what was asked for.
	offset = clamp(offset, 0, int(max(u16)))
	cv.browse_asked += 1
	buf: [proto.CONV_BROWSE_MAX_SIZE]u8
	body := proto.encode_conv_browse(
		&buf,
		{query = cv.browse_query, offset = offset, limit = cv.browse_limit},
	)
	// Which request it is, whether it adds to what we have, and where it starts.
	tag := cv.browse_asked << 32 | u64(adding) << 31 | u64(offset)
	request(
		c,
		.Conv_Browse,
		body,
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			cv := &c.convs
			if status != .Ok || tag >> 32 != cv.browse_asked {
				return
			}
			buf: [proto.MAX_BROWSE_LIMIT]proto.Conv
			more, found, ok := proto.decode_browse_page(body, buf[:])
			if !ok {
				return
			}
			if tag & (1 << 31) == 0 {
				browse_clear(cv)
				cv.browse_offset = int(tag & 0xffff)
			}
			cv.browse_more = more
			for record in found {
				append(&cv.browse, entry_of(record))
			}
			report_browse(c, cv.browse_query, len(cv.browse), found, more)
			publish_browse(c)
		},
		tag,
	)
}

// browse_again asks again for the page of channels to subscribe to that was
// asked for last, after something that changes it.
@(private = "file")
browse_again :: proc(c: ^Server_Conn) {
	cv := &c.convs
	conv_browse(c, {query = cv.browse_query, offset = cv.browse_offset, limit = cv.browse_limit})
}

// fetch_all_channels asks for every channel there is to manage (proto.BROWSE_ALL)
// as many pages as it takes, and shows them once they have all arrived. Managing
// them works on the whole list (their order, for one), which is only ever as long
// as the server has channels.
fetch_all_channels :: proc(c: ^Server_Conn) {
	cv := &c.convs
	cv.all_asked += 1
	cv.all_wanted = true
	entries_clear(&cv.all)
	all_page(c, 0)
}

@(private = "file")
all_page :: proc(c: ^Server_Conn, offset: int) {
	cv := &c.convs
	buf: [proto.CONV_BROWSE_MAX_SIZE]u8
	body := proto.encode_conv_browse(
		&buf,
		{offset = offset, limit = proto.MAX_BROWSE_LIMIT, flags = proto.BROWSE_ALL},
	)
	request(
		c,
		.Conv_Browse,
		body,
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			cv := &c.convs
			if tag != cv.all_asked || status == .Reset {
				return
			}
			buf: [proto.MAX_BROWSE_LIMIT]proto.Conv
			more, found, ok := proto.decode_browse_page(body, buf[:])
			if status != .Ok || !ok {
				// Nothing more is coming, so show what there is.
				if status == .Denied {
					cv.all_wanted = false // not ours to manage (any more)
				} else {
					log.warnf("the server failed to list the channels (%v)", status)
				}
				publish_all_channels(c)
				return
			}
			for record in found {
				append(&cv.all, entry_of(record))
			}
			if more && len(found) > 0 && len(cv.all) < proto.MAX_CHANNELS {
				all_page(c, len(cv.all))
				return
			}
			publish_all_channels(c)
		},
		cv.all_asked,
	)
}

// channels_changed is called when a change we asked for to a channel or to
// what we are subscribed to has been made. What the lists of channels show
// may be different now, so they are asked for again (if they were ever asked
// for).
channels_changed :: proc(c: ^Server_Conn) {
	cv := &c.convs
	if cv.browse_asked != 0 {
		browse_again(c)
	}
	if cv.all_wanted {
		fetch_all_channels(c)
	}
}

conv_subscribe_command :: proc(c: ^Server_Conn, cmd: Subscribe_Command) {
	conv := cmd.conv
	if conv == 0 {
		// Either one of ours to leave, or one we were told about to join.
		conv = conv_by_name(c, cmd.name)
		for e in c.convs.browse {
			if conv == 0 && strings.equal_fold(e.name, cmd.name) {
				conv = e.id
			}
		}
	}
	if conv == 0 && cmd.on {
		// A channel we haven't been shown, so request it by its name.
		cv := &c.convs
		delete(cv.finding)
		cv.finding, cv.finding_on = strings.clone(cmd.name), cmd.on
		buf: [proto.CONV_BROWSE_MAX_SIZE]u8
		body := proto.encode_conv_browse(&buf, {query = cmd.name, limit = proto.MAX_BROWSE_LIMIT})
		request(
			c,
			.Conv_Browse,
			body,
			proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
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
conv_subscribe :: proc(c: ^Server_Conn, conv: proto.Conv_Id, on: bool) {
	buf: [proto.CONV_SUBSCRIBE_SIZE]u8
	request(
		c,
		.Conv_Subscribe,
		proto.encode_conv_subscribe(&buf, conv, on),
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			#partial switch status {
			case .Ok:
				// This changes which channels can be subscribed to.
				channels_changed(c)
			case .Denied:
				log.warn("that channel cannot be left because everyone is in it")
			case .Reset:
			case:
				log.warnf("the server failed to change the subscription (%v)", status)
			}
		},
	)
}

conv_create :: proc(
	c: ^Server_Conn,
	name, topic: string,
	private := false,
	flags := proto.Conv_Flags{},
) {
	buf: [proto.CONV_CREATE_MAX_SIZE]u8
	body := proto.encode_conv_create(buf[:], name, topic, private, flags)
	if body == nil {
		log.warn("that name or topic is too long")
		return
	}
	request(
		c,
		.Conv_Create,
		body,
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			text: string
			#partial switch status {
			case .Ok:
				text = "Channel created."
			case .Denied:
				text = "You don't have permission to create channels."
			case .Conflict:
				text = "A channel with that name already exists."
			case .Invalid:
				text = "A channel must have a name, and a private one can't be default."
			case .Too_Large:
				text = "You've reached the maximum number of channels."
			case .Reset:
				return
			case:
				text = fmt.tprintf("The server failed to create the channel (%v).", status)
			}
			notify(c, status == .Ok, text)
			if status == .Ok {
				channels_changed(c)
			}
		},
	)
}

// conv_new_message counts a message that was just posted (and wasn't here
// before) as unread or not. Our own messages mark everything up to them as
// read, and a message in the conversation being read counts as read. It returns
// whether the message may interrupt the user, according to its conversation's
// notification level, and whether it is a mention of us that should be
// announced on the desktop. That is not the case in a muted conversation (where
// it is still counted), but it is the case in the conversation being read too
// (which may be on a server that isn't shown, or in a window that is in the
// background).
conv_new_message :: proc(c: ^Server_Conn, m: proto.Message) -> (interrupts: bool, mention: bool) {
	cv := &c.convs
	info, ok := &cv.convs[m.conv]
	if !ok {
		return false, false
	}
	info.last = max(info.last, m.id)
	// This doesn't change anything about what is unread, but it does change
	// the order of the DMs.
	newer := m.time > info.last_time
	info.last_time = max(info.last_time, m.time)
	switch {
	case m.sender == c.auth.me:
		if m.id > info.read {
			info.read, info.unread, info.mentions = m.id, 0, 0
		}
	case m.id <= info.read:
		if newer {
			publish_channels(c)
		}
		return false, false
	case cv.reading == m.conv:
		mark_read(c, m.conv, m.id)
		if newer {
			publish_channels(c)
		}
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

// mentions_me reports whether a message mentions us or one of our roles.
// <@everyone> is only ever stored if the sender was allowed to use it, and a
// role mention is only stored if the role can be mentioned.
@(private = "file")
mentions_me :: proc(c: ^Server_Conn, m: proto.Message) -> bool {
	if m.kind != .Text || .Deleted in m.flags {
		return false
	}
	return proto.mentions_account(m.text, c.auth.me, c.auth.accounts[c.auth.me].roles)
}

// conv_reading handles the UI saying which conversation is being read, if any.
// What is in it counts as read.
conv_reading :: proc(c: ^Server_Conn, conv: proto.Conv_Id) {
	cv := &c.convs
	cv.reading = conv
	if info, ok := cv.convs[conv]; ok && info.last > info.read {
		mark_read(c, conv, info.last)
	}
}

// mark_read marks a conversation as read up to `id` here and now, and tells the
// server as soon as it is allowed to (see convs_step).
@(private = "file")
mark_read :: proc(c: ^Server_Conn, conv: proto.Conv_Id, id: proto.Msg_Id) {
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

// convs_step tells the server what has been read, at most once every
// MARK_INTERVAL for each conversation.
convs_step :: proc(c: ^Server_Conn) {
	cv := &c.convs
	if !cv.synced || !c.has_current || len(cv.marks) == 0 {
		return
	}
	// Access the mark through a pointer from the map instead of `for conv, &m
	// in`. With a u32 key, Odin (dev-2026-10) iterates over a copy, so the mark
	// was never cleared and was sent again on every step.
	for conv in cv.marks {
		m := &cv.marks[conv]
		if m.due == 0 || (m.sent != {} && time.tick_since(m.sent) < MARK_INTERVAL) {
			continue
		}
		buf: [proto.MARK_READ_SIZE]u8
		request(c, .Mark_Read, proto.encode_mark_read(&buf, conv, m.due))
		m.due, m.sent = 0, time.tick_now()
	}
}

conv_notify :: proc(c: ^Server_Conn, cmd: Notify_Command) {
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
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			if status != .Ok && status != .Reset {
				log.warnf("the server failed to change the notification level (%v)", status)
			}
		},
	)
}

// list_channels logs our channels, with who is talking in each.
list_channels :: proc(c: ^Server_Conn) {
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

// convs_ordered returns our channels in the order a list shows them, which is
// the home channel first and then in the order they were made. It is allocated
// in the temp allocator.
convs_ordered :: proc(c: ^Server_Conn) -> []proto.Conv_Id {
	ids := make([dynamic]proto.Conv_Id, 0, len(c.convs.convs), context.temp_allocator)
	for id, info in c.convs.convs {
		if info.kind == .Channel {
			append(&ids, id)
		}
	}
	// The home channel comes first, then the channels sorted by position and
	// then by id, the same way the server orders them.
	context.user_ptr = c
	slice.sort_by(ids[:], proc(x, y: proto.Conv_Id) -> bool {
		c := (^Server_Conn)(context.user_ptr)
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

// unread_count returns how an unread count is shown, which is "99+" past the
// cap.
unread_count :: proc(n: int) -> string {
	return "99+" if n >= proto.UNREAD_CAP else fmt.tprintf("%d", n)
}

publish_browse :: proc(c: ^Server_Conn) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	view_clear_browse(v)
	entries_copy(&v.browse, c.convs.browse[:])
	v.browse_offset = c.convs.browse_offset
	v.browse_more = c.convs.browse_more
	v.browse_count += 1
}

publish_all_channels :: proc(c: ^Server_Conn) {
	v := c.view
	if v == nil {
		for e in c.convs.all {
			log.infof(
				"%s%s%s",
				e.name,
				" (private)" if .Private in e.flags else "",
				"" if e.member else " (not in it)",
			)
		}
		return
	}
	view_write(v)
	entries_clear(&v.all_channels)
	entries_copy(&v.all_channels, c.convs.all[:])
	v.all_channels_count += 1
}

@(private = "file")
entries_copy :: proc(to: ^[dynamic]Browse_Entry, from: []Browse_Entry) {
	for e in from {
		owned := e
		owned.name, owned.topic = strings.clone(e.name), strings.clone(e.topic)
		append(to, owned)
	}
}

// Call with the mutex held.
view_clear_browse :: proc(v: ^View) {
	entries_clear(&v.browse)
	entries_clear(&v.all_channels)
}

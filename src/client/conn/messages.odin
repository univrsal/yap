package conn

import log "common:wlog"
import "core:fmt"
import "core:strings"
import "core:time"

import "client:audio"
import "client:richtext"
import "common:proto"


// Messages on our end (src/common/proto/messages.odin).
//
// For each conversation we keep a window of consecutive messages, with the
// newest at the end (Conv_Cache). The server keeps everything, while we only
// keep what is being looked at and ask for more one page at a time. We ask for
// older messages when the list is scrolled to its top, for newer messages when
// a window that stopped short of the end is scrolled to its bottom, and for a
// page around one message to jump to it. A message that is posted in any
// conversation we are a member of arrives as Msg_New, and is added to its
// window if that window reaches the end.
//
// Windows are bounded. Past MAX_CACHE_MESSAGES the far end is dropped (and
// requested again if the user scrolls back to it), and only the CACHE_KEEP
// conversations that were looked at last keep their windows. When the
// connection restarts, every window is dropped and the one on screen is fetched
// again, because nothing is replayed (D9).
//
// What we post is in outbox.odin, typing notices in typing.odin, and what the UI
// is shown in messages_view.odin.
//
// Threads (phase 11): a reply is a message of its conversation like any other,
// so it is in the conversation's window, and also in its thread's window while
// that thread is open (in a window of the UI's). A thread's window is kept the
// same way, keyed by the conversation and the root (Timeline_Key), and is
// dropped when the thread is closed. The roots that replies point at are
// fetched one at a time (a page of one around the root) when the UI wants to
// show what a reply replies to and the root isn't in a window. They are kept
// as long as their conversation's window is.

// How many messages a conversation's window holds, and how many conversations
// keep a window.
MAX_CACHE_MESSAGES :: 1000
CACHE_KEEP :: 8
// The number of messages requested per page.
HISTORY_PAGE :: proto.MAX_HISTORY_LIMIT
// How many threads may be open at once. Opening another one closes the one that
// was opened longest ago.
MAX_THREADS :: 4

// Timeline_Key identifies a window of messages, which is either a conversation's
// (root 0) or one of its threads'.
Timeline_Key :: struct {
	conv: proto.Conv_Id,
	root: proto.Msg_Id,
}

// Msg is a message as we keep it.
Msg :: struct {
	id:          proto.Msg_Id,
	sender:      proto.Account_Id,
	time:        proto.Unix_Ms,
	kind:        proto.Msg_Kind,
	flags:       proto.Msg_Flags,
	thread_root: proto.Msg_Id,
	edited:      proto.Unix_Ms,
	text:        string, // owned; a file's name
	file_size:   u64,
	reactions:   [dynamic]Reaction, // owned, as are their emoji
	// The thread of a root (.Has_Thread): the number of replies, and the last one.
	reply_count: int,
	last_reply:  proto.Msg_Id,
	// For a system message: what happened, and a number that goes with it.
	system:      u8,
	system_arg:  u32,
	// For a forwarded message: the original message (see forward.odin).
	forward:     proto.Forward_Info,
	// The files the message carries (.Has_Attachments, see attachments.odin).
	files:       []Msg_File, // owned, as are their names
}

// Msg_File is a file a message carries. It has a blob (0 once the file has been
// removed because of the retention policy), its size, and its name. A picture
// also has the width and height its header states, or 0 if it couldn't be read.
Msg_File :: struct {
	blob:          proto.Blob_Id,
	size:          u64,
	name:          string,
	width, height: int,
}

msg_files_clone :: proc(files: []Msg_File) -> []Msg_File {
	if len(files) == 0 {
		return nil
	}
	out := make([]Msg_File, len(files))
	for f, i in files {
		out[i] = f
		out[i].name = strings.clone(f.name)
	}
	return out
}

msg_files_destroy :: proc(files: []Msg_File) {
	for f in files {
		delete(f.name)
	}
	delete(files)
}

// Reaction is an emoji that people reacted to a message with. It has the number
// of people who did, and whether we are among them.
Reaction :: struct {
	emoji: string,
	count: int,
	me:    bool,
}

reactions_clone :: proc(rs: []Reaction) -> [dynamic]Reaction {
	out := make([dynamic]Reaction, 0, len(rs))
	for r in rs {
		append(&out, Reaction{strings.clone(r.emoji), r.count, r.me})
	}
	return out
}

reactions_destroy :: proc(rs: ^[dynamic]Reaction) {
	for r in rs {
		delete(r.emoji)
	}
	delete(rs^)
	rs^ = nil
}

Conv_Cache :: struct {
	messages:    [dynamic]Msg, // consecutive messages, ordered by id
	have_newest: bool, // the window reaches the end of the conversation
	have_oldest: bool, // ... and its beginning
	loading:     bool, // a history request is pending
	// Incremented when the window is replaced, so that an answer to a request
	// made for the previous window can be recognized as outdated.
	generation:  u32,
	used:        time.Tick, // when the window was last looked at
}

Message_Client :: struct {
	caches:         map[Timeline_Key]^Conv_Cache,
	// The open threads, oldest first.
	threads:        [dynamic]Timeline_Key,
	// Roots that were fetched for the replies pointing at them, or that are
	// being fetched (`have` is false).
	roots:          map[proto.Msg_Id]Root,
	// The conversation whose pins the UI was last shown (see pins_fetch).
	pins_conv:      proto.Conv_Id,
	// Who reacted with which emoji, as requested last (see reactors_fetch).
	// Only its answer is shown.
	reactors_id:    proto.Msg_Id,
	reactors_emoji: string, // owned
	generation:     u32,
	outbox:         [dynamic]Pending,
	// Typing notices: when the last one was sent, and where it was sent to.
	last_typing:    time.Tick,
	typing_to:      Timeline_Key,
}

// Root is a thread's root message as fetched for its conversation.
Root :: struct {
	conv: proto.Conv_Id,
	have: bool,
	msg:  Msg,
}

// Requests more of a conversation (or a thread): older messages, or with `newer`,
// messages that are newer than what its window has.
History_Command :: struct {
	conv:  proto.Conv_Id, // 0 means the conversation we are looking at
	root:  proto.Msg_Id,
	newer: bool,
}

// Opens a thread (fetches its replies and its root, and keeps them up to date),
// or closes it.
Thread_Command :: struct {
	thread: Timeline_Key,
	open:   bool,
}

// Fetches the root of the thread that a reply on screen points at, so it can be
// shown in the reply's line in the conversation.
Root_Command :: struct {
	conv: proto.Conv_Id,
	root: proto.Msg_Id,
}

messages_destroy :: proc(c: ^Server_Conn) {
	mc := &c.msgs
	for key in mc.caches {
		cache_drop(c, key, publish = false)
	}
	delete(mc.caches)
	delete(mc.threads)
	for _, &r in mc.roots {
		msg_destroy(&r.msg)
	}
	delete(mc.roots)
	for &p in mc.outbox {
		pending_destroy(&p)
	}
	delete(mc.outbox)
	delete(mc.reactors_emoji)
	mc^ = {}
}

msg_destroy :: proc(m: ^Msg) {
	delete(m.text)
	reactions_destroy(&m.reactions)
	msg_files_destroy(m.files)
	m^ = {}
}

// msg_of returns a message as we keep it, with its text copied.
msg_of :: proc(m: proto.Message) -> Msg {
	out := Msg {
		id          = m.id,
		sender      = m.sender,
		time        = m.time,
		kind        = m.kind,
		flags       = m.flags,
		thread_root = m.thread_root,
		edited      = m.edited,
		text        = strings.clone(m.file_name if m.kind == .File else m.text),
		file_size   = m.file_size,
		reply_count = int(m.reply_count),
		last_reply  = m.last_reply,
		system      = m.system,
		system_arg  = m.system_arg,
		forward     = m.forward,
	}
	buf: [proto.MAX_REACTIONS]proto.Reaction
	for r in proto.reactions_of(m, buf[:]) {
		append(&out.reactions, Reaction{strings.clone(r.emoji), r.count, r.me})
	}
	if .Has_Attachments in m.flags && m.attachment_count > 0 {
		out.files = make([]Msg_File, m.attachment_count)
		for i in 0 ..< m.attachment_count {
			a := m.attachments[i]
			name_buf: [proto.MAX_FILE_NAME]u8
			name := proto.sanitize_file_name(a.name, &name_buf)
			out.files[i] = {
				blob   = a.blob,
				size   = a.size,
				name   = strings.clone(name if name != "" else "file"),
				width  = a.width,
				height = a.height,
			}
		}
	}
	return out
}

// The window of one conversation. These procedures only change the window, and
// the callers publish it.

cache_destroy :: proc(cache: ^Conv_Cache) {
	for &m in cache.messages {
		msg_destroy(&m)
	}
	delete(cache.messages)
}

// cache_replace makes a page the whole window, either the first page or one
// that was jumped to. It takes ownership of the messages.
cache_replace :: proc(cache: ^Conv_Cache, page: []Msg, more: u8) {
	for &m in cache.messages {
		msg_destroy(&m)
	}
	clear(&cache.messages)
	append(&cache.messages, ..page)
	cache.have_oldest = more & proto.MORE_BEFORE == 0
	cache.have_newest = more & proto.MORE_AFTER == 0
}

// cache_prepend adds a page of older messages. It takes ownership of the
// messages, and drops those that the window already has.
cache_prepend :: proc(cache: ^Conv_Cache, page: []Msg, more: u8) {
	n := len(page)
	if len(cache.messages) > 0 {
		first := cache.messages[0].id
		for n > 0 && page[n - 1].id >= first {
			n -= 1
			msg_destroy(&page[n])
		}
	}
	inject_at_elems(&cache.messages, 0, ..page[:n])
	cache.have_oldest = more & proto.MORE_BEFORE == 0
	// The window is too long now, so drop the newest messages. They are fetched
	// again if they are wanted.
	for len(cache.messages) > MAX_CACHE_MESSAGES {
		msg_destroy(&cache.messages[len(cache.messages) - 1])
		pop(&cache.messages)
		cache.have_newest = false
	}
}

// cache_append adds newer messages, either a page of them or one that was just
// posted. It takes ownership of the messages, and drops those that the window
// already has.
cache_append :: proc(cache: ^Conv_Cache, page: []Msg, more: u8) {
	for &m in page {
		if len(cache.messages) > 0 && m.id <= cache.messages[len(cache.messages) - 1].id {
			msg_destroy(&m)
			continue
		}
		append(&cache.messages, m)
	}
	cache.have_newest = more & proto.MORE_AFTER == 0
	cache_trim_front(cache)
}

// cache_trim_front drops the oldest messages beyond MAX_CACHE_MESSAGES.
@(private = "file")
cache_trim_front :: proc(cache: ^Conv_Cache) {
	extra := len(cache.messages) - MAX_CACHE_MESSAGES
	if extra <= 0 {
		return
	}
	for &m in cache.messages[:extra] {
		msg_destroy(&m)
	}
	remove_range(&cache.messages, 0, extra)
	cache.have_oldest = false
}

// cache_new takes ownership of a message that was just posted. It returns false
// if the window doesn't reach the end, in which case the message doesn't belong
// to the window and is freed.
cache_new :: proc(cache: ^Conv_Cache, m: Msg) -> bool {
	m := m
	if !cache.have_newest {
		msg_destroy(&m)
		return false
	}
	cache_append(cache, {m}, 0)
	return true
}

// The network side.

// cache_of returns the window for a key, making one if there is none.
@(private = "file")
cache_of :: proc(c: ^Server_Conn, key: Timeline_Key) -> ^Conv_Cache {
	mc := &c.msgs
	cache := mc.caches[key] or_else nil
	if cache == nil {
		cache = new(Conv_Cache)
		mc.generation += 1
		cache.generation = mc.generation
		mc.caches[key] = cache
	}
	cache.used = time.tick_now()
	return cache
}

// cache_drop drops a window. Dropping a conversation's window also drops the
// roots that were fetched for it, except those of threads that are still open.
@(private = "file")
cache_drop :: proc(c: ^Server_Conn, key: Timeline_Key, publish := true) {
	cache := c.msgs.caches[key] or_else nil
	if cache == nil {
		return
	}
	cache_destroy(cache)
	free(cache)
	delete_key(&c.msgs.caches, key)
	if key.root == 0 {
		gone := make([dynamic]proto.Msg_Id, context.temp_allocator)
		for id, r in c.msgs.roots {
			if r.conv == key.conv && !thread_is_open(c, {key.conv, id}) {
				append(&gone, id)
			}
		}
		for id in gone {
			root_forget(c, id, publish)
		}
	}
	if publish {
		publish_timeline(c, key)
	}
}

@(private = "file")
thread_is_open :: proc(c: ^Server_Conn, key: Timeline_Key) -> bool {
	for t in c.msgs.threads {
		if t == key {
			return true
		}
	}
	return false
}

// messages_view is called when the UI shows a conversation: its window is
// fetched if it has none, and the windows that were looked at longest ago are
// dropped.
messages_view :: proc(c: ^Server_Conn, conv: proto.Conv_Id) {
	if conv == 0 {
		return
	}
	key := Timeline_Key{conv, 0}
	cache := cache_of(c, key)
	if len(cache.messages) == 0 && !cache.have_oldest && !cache.loading {
		history_ask(c, key, 0, .Before)
	}
	// Only conversation windows are counted; the windows of threads stay as
	// long as the threads are open.
	for {
		count := 0
		oldest: Timeline_Key
		for k, other in c.msgs.caches {
			if k.root != 0 {
				continue
			}
			count += 1
			if k != key &&
			   (oldest == {} || time.tick_diff(other.used, c.msgs.caches[oldest].used) < 0) {
				oldest = k
			}
		}
		if count <= CACHE_KEEP {
			break
		}
		cache_drop(c, oldest)
	}
	publish_timeline(c, key)
	// Fetch the open threads again, in case this is a new connection.
	for t in c.msgs.threads {
		thread_fetch(c, t)
	}
}

// messages_more asks for the page before a window (or, with `newer`, the page
// after it).
messages_more :: proc(c: ^Server_Conn, key: Timeline_Key, newer: bool) {
	cache := c.msgs.caches[key] or_else nil
	if cache == nil || cache.loading || len(cache.messages) == 0 {
		return
	}
	if newer && !cache.have_newest {
		history_ask(c, key, cache.messages[len(cache.messages) - 1].id, .After)
	} else if !newer && !cache.have_oldest {
		history_ask(c, key, cache.messages[0].id, .Before)
	}
}

// messages_jump replaces a conversation's window with the page around a
// message.
messages_jump :: proc(c: ^Server_Conn, conv: proto.Conv_Id, id: proto.Msg_Id) {
	cache := cache_of(c, {conv, 0})
	if cache.loading {
		return
	}
	history_ask(c, {conv, 0}, id, .Around)
}

@(private = "file")
history_ask :: proc(
	c: ^Server_Conn,
	key: Timeline_Key,
	anchor: proto.Msg_Id,
	dir: proto.History_Dir,
) {
	if !c.convs.synced {
		return
	}
	cache := cache_of(c, key)
	cache.loading = true
	buf: [proto.MSG_HISTORY_SIZE]u8
	body := proto.encode_msg_history(
		&buf,
		{
			conv = key.conv,
			thread_root = key.root,
			anchor = anchor,
			dir = dir,
			limit = HISTORY_PAGE,
		},
	)
	// The tag says which window the page is for (each window has its own
	// generation) and what to do with it: append it (bit 33), have it replace
	// the window (bit 32: a jump, or the newest page), or else prepend it.
	tag := u64(cache.generation)
	if dir == .After {
		tag |= 1 << 33
	} else if dir == .Around || anchor == 0 {
		tag |= 1 << 32
	}
	request(c, .Msg_History, body, history_done, tag)
	publish_timeline(c, key)
}

@(private = "file")
history_done :: proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
	generation := u32(tag)
	key: Timeline_Key
	cache: ^Conv_Cache
	for k, found in c.msgs.caches {
		if found.generation == generation {
			key, cache = k, found
		}
	}
	if cache == nil {
		return // the window has been dropped since
	}
	conv := key.conv
	cache.loading = false
	if status != .Ok {
		if status != .Reset {
			log.warnf(
				"the server failed to send the messages of %q (%v)",
				room_name(c, proto.Room(conv)),
				status,
			)
		}
		publish_timeline(c, key)
		return
	}
	buf: [proto.MAX_HISTORY_LIMIT]proto.Message
	more, got, ok := proto.decode_history_page(body, buf[:])
	if !ok {
		log.warn("the server sent a page of messages we can't read")
		publish_timeline(c, key)
		return
	}
	page := make([]Msg, len(got), context.temp_allocator)
	for m, i in got {
		page[i] = msg_of(m)
	}
	switch {
	case tag & (1 << 32) != 0:
		cache_replace(cache, page, more)
	case tag & (1 << 33) != 0:
		cache_append(cache, page, more)
	case:
		cache_prepend(cache, page, more)
	}
	report_history(c, key, got, cache.have_oldest, len(cache.messages))
	publish_timeline(c, key)
}

// Threads.

// thread_open opens a thread: its window and its root are fetched, and they are
// kept up to date until the thread is closed. Past MAX_THREADS, the thread that
// was opened longest ago is closed.
thread_open :: proc(c: ^Server_Conn, key: Timeline_Key) {
	if key.conv == 0 || key.root == 0 || thread_is_open(c, key) {
		return
	}
	append(&c.msgs.threads, key)
	for len(c.msgs.threads) > MAX_THREADS {
		thread_close(c, c.msgs.threads[0])
	}
	thread_fetch(c, key)
}

thread_close :: proc(c: ^Server_Conn, key: Timeline_Key) {
	for t, i in c.msgs.threads {
		if t == key {
			ordered_remove(&c.msgs.threads, i)
			break
		}
	}
	cache_drop(c, key)
	// Its root is dropped too, unless the conversation's window still keeps
	// it.
	if (Timeline_Key{key.conv, 0}) not_in c.msgs.caches {
		root_forget(c, key.root)
	}
}

// thread_fetch fetches an open thread's window and its root, if we don't have
// them yet.
@(private = "file")
thread_fetch :: proc(c: ^Server_Conn, key: Timeline_Key) {
	cache := cache_of(c, key)
	if len(cache.messages) == 0 && !cache.have_oldest && !cache.loading {
		history_ask(c, key, 0, .Before)
	}
	root_want(c, key.conv, key.root)
}

// root_want fetches a thread's root, unless we already have it or it is on its
// way.
root_want :: proc(c: ^Server_Conn, conv: proto.Conv_Id, root: proto.Msg_Id) {
	if root == 0 || root in c.msgs.roots || !c.convs.synced || conv not_in c.convs.convs {
		return
	}
	c.msgs.roots[root] = {
		conv = conv,
	}
	buf: [proto.MSG_HISTORY_SIZE]u8
	body := proto.encode_msg_history(&buf, {conv = conv, anchor = root, dir = .Around, limit = 1})
	request(
		c,
		.Msg_History,
		body,
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			root := proto.Msg_Id(tag)
			r, ok := &c.msgs.roots[root]
			if !ok || r.have {
				return // dropped since
			}
			if status != .Ok {
				if status == .Reset {
					delete_key(&c.msgs.roots, root) // so that it is asked for again
				} else {
					publish_root_missing(c, root)
				}
				return
			}
			buf: [1]proto.Message
			_, got, read := proto.decode_history_page(body, buf[:])
			if !read || len(got) != 1 || got[0].id != root {
				publish_root_missing(c, root)
				return
			}
			r.have, r.msg = true, msg_of(got[0])
			publish_root(c, r^)
		},
		u64(root),
	)
}

@(private = "file")
root_forget :: proc(c: ^Server_Conn, id: proto.Msg_Id, publish := true) {
	if r, ok := &c.msgs.roots[id]; ok {
		msg_destroy(&r.msg)
		delete_key(&c.msgs.roots, id)
	}
	if publish {
		publish_root_gone(c, id)
	}
}

// messages_event handles an event about messages. It returns false if `op`
// isn't such an event.
messages_event :: proc(c: ^Server_Conn, op: proto.Event_Op, body: []u8) -> bool {
	if op == .Reaction_Changed {
		if change, ok := proto.decode_reaction_changed(body); ok {
			reaction_changed(c, change)
		}
		return true
	}
	if op == .Msgs_Purged {
		if p, ok := proto.decode_msgs_purged(body); ok {
			msgs_purged(c, p)
		}
		return true
	}
	if op != .Msg_New && op != .Msg_Changed {
		return false
	}
	m, ok := proto.decode_message(body)
	if !ok {
		return true
	}
	if op == .Msg_New {
		message_arrived(c, m)
	} else {
		message_changed(c, m)
	}
	return true
}

// message_arrived handles a message that was just posted: either one we were
// told about (Msg_New), or one of ours that the server has accepted. For our own
// messages both happen, and whichever comes second is a message we already
// have.
message_arrived :: proc(c: ^Server_Conn, m: proto.Message) {
	if m.kind == .File && m.sender != c.auth.me {
		file_offer_received(c, m)
	}
	if m.thread_root != 0 {
		// Add it to its thread's window if that thread is open. The
		// conversation's window is handled below.
		key := Timeline_Key{m.conv, m.thread_root}
		if cache := c.msgs.caches[key] or_else nil; cache != nil && !cache_has_newer(cache, m.id) {
			cache_new(cache, msg_of(m))
			publish_timeline(c, key)
		}
	}
	if cache := c.msgs.caches[{m.conv, 0}] or_else nil; cache != nil {
		if cache_has_newer(cache, m.id) {
			return // already have it: ours, announced after the answer to our post or before it
		}
		cache_new(cache, msg_of(m))
		publish_timeline(c, {m.conv, 0})
	} else if info, ok := c.convs.convs[m.conv]; ok && m.id <= info.last {
		// The same check for a conversation we keep no window of: a message
		// that isn't newer than the last one we know of was seen already.
		return
	}
	interrupts, mention := conv_new_message(c, m)
	if m.kind == .System &&
	   proto.Call_System(m.system) == .Missed &&
	   m.sender != c.auth.me &&
	   c.call.status != .None &&
	   c.call.peer != m.sender {
		// Somebody called while we were in a call (the server turned them
		// away): a knock, once.
		audio.voice_notification_play(&c.voice, .Knock)
	}
	// A DM from someone else gets a desktop notification whatever it says
	// (unless the DM is muted); the UI skips it while the DM is being read.
	info := c.convs.convs[m.conv] or_else Conv_Info{}
	dm :=
		info.kind == .DM &&
		info.notify != .None &&
		m.sender != c.auth.me &&
		m.kind != .System &&
		.Deleted not_in m.flags
	if dm {
		publish_mentioned(
			c,
			account_display(c, m.sender),
			room_name(c, proto.Room(m.conv)),
			dm_notice_text(c, m),
			m.conv,
			m.id,
			dm = true,
		)
	}
	switch {
	case mention:
		// A mention has its own sound and a desktop notification. In a DM,
		// it is the DM's sound.
		audio.voice_notification_play(&c.voice, .Direct_Message if dm else .Mention)
		if dm {
			break // already notified above
		}
		shown, _ := richtext.mentions_display(m.text, c.auth.accounts, dir_roles(c), c.auth.me)
		publish_mentioned(
			c,
			account_display(c, m.sender),
			room_name(c, proto.Room(m.conv)),
			shown,
			m.conv,
			m.id,
		)
		report_mention(c, m, shown)
	case interrupts && !quiet(c):
		audio.voice_notification_play(&c.voice, .Direct_Message if dm else .Message)
	}
	if m.sender != c.auth.me {
		publish_typing_done(c, {m.conv, m.thread_root}, m.sender)
		if m.conv == c.convs.viewing {
			publish_unread(c)
		}
	}
	report_message(c, m)
}

// cache_has_newer reports whether a window ends at or past `id`, which means
// that a message with that id that just arrived is already in the window.
@(private = "file")
cache_has_newer :: proc(cache: ^Conv_Cache, id: proto.Msg_Id) -> bool {
	return len(cache.messages) > 0 && id <= cache.messages[len(cache.messages) - 1].id
}

// dm_notice_text returns the text of a DM's desktop notification.
@(private = "file")
dm_notice_text :: proc(c: ^Server_Conn, m: proto.Message) -> string {
	if m.kind == .File {
		return fmt.tprintf("Sent you the file %q", m.file_name)
	}
	text, _ := richtext.mentions_display(m.text, c.auth.accounts, dir_roles(c), c.auth.me)
	if text == "" && .Has_Attachments in m.flags {
		return "Sent you a file"
	}
	return text
}

// message_changed handles the new state of a message (Msg_Changed) after it was
// edited, deleted, pinned or unpinned. Any window that has the message gets the
// new version; a deleted file offer can no longer be accepted; and the pins
// shown are fetched again (the message may have been or become one of them).
@(private = "file")
message_changed :: proc(c: ^Server_Conn, m: proto.Message) {
	// An event doesn't say which reactions are ours, so keep ours as they were.
	replace :: proc(old: ^Msg, m: proto.Message) {
		fresh := msg_of(m)
		for &r in fresh.reactions {
			for o in old.reactions {
				if o.emoji == r.emoji {
					r.me = o.me
				}
			}
		}
		msg_destroy(old)
		old^ = fresh
	}
	// Update the conversation's window, and the window of the thread it's a
	// reply in or the root of.
	for key in ([]Timeline_Key{{m.conv, 0}, {m.conv, m.thread_root if m.thread_root != 0 else m.id}}) {
		cache := c.msgs.caches[key] or_else nil
		if cache == nil {
			continue
		}
		for &old in cache.messages {
			if old.id == m.id {
				replace(&old, m)
				publish_message_changed(c, key, old)
				break
			}
		}
	}
	if r, ok := &c.msgs.roots[m.id]; ok && r.have {
		replace(&r.msg, m)
		publish_root(c, r^)
	}
	if .Deleted in m.flags {
		file_offer_deleted(c, m.id)
	}
	if c.msgs.pins_conv == m.conv {
		pins_fetch(c, m.conv)
	}
	report_changed(c, m)
}

// msgs_purged handles the server telling us that it has purged a conversation's
// messages below an id, except pinned ones and the roots of threads that live
// on, or one author's messages from an id on (purged_by). They are removed
// from our windows, and a window with nothing left is fetched again if it is
// on screen.
@(private = "file")
msgs_purged :: proc(c: ^Server_Conn, p: proto.Msgs_Purged) {
	if p.what == .Files {
		purge_files(c, p)
		return
	}
	keys := make([dynamic]Timeline_Key, context.temp_allocator)
	for key in c.msgs.caches {
		if key.conv == p.conv {
			append(&keys, key)
		}
	}
	for key in keys {
		cache := c.msgs.caches[key]
		n := 0
		if p.author == 0 {
			for n < len(cache.messages) && cache.messages[n].id < p.before {
				msg_destroy(&cache.messages[n])
				n += 1
			}
			remove_range(&cache.messages, 0, n)
			cache.have_oldest = n == 0 && cache.have_oldest
		} else {
			// Theirs can be anywhere in the window.
			kept := 0
			for &m in cache.messages {
				if purged_by(p, m) {
					msg_destroy(&m)
					n += 1
				} else {
					cache.messages[kept] = m
					kept += 1
				}
			}
			resize(&cache.messages, kept)
		}
		if n == 0 {
			continue
		}
		if len(cache.messages) > 0 {
			publish_timeline(c, key)
			continue
		}
		cache_drop(c, key)
		switch {
		case key.root == 0 && c.convs.viewing == key.conv:
			messages_view(c, key.conv)
		case key.root != 0 && thread_is_open(c, key):
			thread_fetch(c, key)
		}
	}
	gone := make([dynamic]proto.Msg_Id, context.temp_allocator)
	for id, &r in c.msgs.roots {
		if r.conv != p.conv || !r.have {
			continue
		}
		kept := id >= p.before if p.author == 0 else !purged_by(p, r.msg)
		if kept {
			continue
		}
		append(&gone, id)
	}
	// Pinned messages of theirs went too.
	if p.author != 0 && c.msgs.pins_conv == p.conv {
		pins_fetch(c, p.conv)
	}
	for id in gone {
		root_forget(c, id)
		// Fetch it again if an open thread still needs it.
		for t in c.msgs.threads {
			if t.root == id {
				root_want(c, t.conv, id)
			}
		}
	}
	report_purged(c, p)
}

// purged_by returns whether a purge of one author's messages removed `m`.
// Their thread roots that others replied to are kept as deleted messages
// (the server says so first, with Msg_Changed).
@(private = "file")
purged_by :: proc(p: proto.Msgs_Purged, m: Msg) -> bool {
	if p.author == 0 || m.sender != p.author || m.id < p.from {
		return false
	}
	return p.what == .Files || !(.Deleted in m.flags && .Has_Thread in m.flags)
}

// purge_files removes the files from a conversation's messages below the
// purge's boundary, except from pinned messages, or from one author's
// messages from an id on, pinned too. The files stay listed, but without
// their blobs.
@(private = "file")
purge_files :: proc(c: ^Server_Conn, p: proto.Msgs_Purged) {
	strip :: proc(m: ^Msg, p: proto.Msgs_Purged) -> bool {
		kept := (m.id >= p.before || .Pinned in m.flags) if p.author == 0 else !purged_by(p, m^)
		if kept {
			return false
		}
		changed := false
		for &f in m.files {
			changed ||= f.blob != 0
			f.blob = 0
		}
		return changed
	}
	for key, cache in c.msgs.caches {
		if key.conv != p.conv {
			continue
		}
		for &m in cache.messages {
			if strip(&m, p) {
				publish_message_changed(c, key, m)
			}
		}
	}
	for _, &r in c.msgs.roots {
		if r.conv == p.conv && r.have && strip(&r.msg, p) {
			publish_root(c, r)
		}
	}
}

// reaction_changed handles someone adding or removing a reaction.
@(private = "file")
reaction_changed :: proc(c: ^Server_Conn, change: proto.Reaction_Change) {
	react :: proc(c: ^Server_Conn, m: ^Msg, change: proto.Reaction_Change) {
		found := false
		for &r, i in m.reactions {
			if r.emoji != change.emoji {
				continue
			}
			found = true
			r.count = change.count
			if change.account == c.auth.me {
				r.me = change.on
			}
			if r.count == 0 {
				delete(r.emoji)
				ordered_remove(&m.reactions, i)
			}
			break
		}
		if !found && change.count > 0 {
			append(
				&m.reactions,
				Reaction {
					strings.clone(change.emoji),
					change.count,
					change.account == c.auth.me && change.on,
				},
			)
		}
	}
	// Update every window of the conversation that has the message: the
	// conversation's own and those of threads.
	for key, cache in c.msgs.caches {
		if key.conv != change.conv {
			continue
		}
		for &m in cache.messages {
			if m.id == change.id {
				react(c, &m, change)
				publish_message_changed(c, key, m)
				break
			}
		}
	}
	if r, ok := &c.msgs.roots[change.id]; ok && r.have {
		react(c, &r.msg, change)
		publish_root(c, r^)
	}
	// If the list of who reacted with this emoji is shown, it is outdated
	// now, so clear it.
	if v := c.view; v != nil {
		view_write(v)
		if v.reactors.id == change.id && v.reactors.emoji == change.emoji {
			view_clear_reactors(v)
		}
	}
}

// messages_jump_to moves the window of the conversation we are looking at to
// message `id` by fetching a page around it, unless it is in the window
// already.
messages_jump_to :: proc(c: ^Server_Conn, id: proto.Msg_Id) {
	conv := c.convs.viewing
	if conv == 0 {
		return
	}
	if cache := c.msgs.caches[{conv, 0}] or_else nil; cache != nil && len(cache.messages) > 0 {
		if cache.messages[0].id <= id && id <= cache.messages[len(cache.messages) - 1].id {
			return
		}
	}
	messages_jump(c, conv, id)
}

// messages_restart is called when the connection to the server has been made
// anew: all windows are dropped (the one on screen is fetched again when it is
// looked at), and the outbox is posted again, resuming where possible. With
// `forget`, we were logged out, and the messages we had written are dropped
// too.
messages_restart :: proc(c: ^Server_Conn, forget := false) {
	mc := &c.msgs
	keys := make([dynamic]Timeline_Key, context.temp_allocator)
	for key in mc.caches {
		append(&keys, key)
	}
	for key in keys {
		cache_drop(c, key)
	}
	// The fetched roots are dropped too. The threads stay open, and are
	// fetched again along with the conversation on screen (messages_view).
	roots := make([dynamic]proto.Msg_Id, context.temp_allocator)
	for id in mc.roots {
		append(&roots, id)
	}
	for id in roots {
		root_forget(c, id)
	}
	if forget {
		clear(&mc.threads)
		for &p in mc.outbox {
			pending_destroy(&p)
		}
		clear(&mc.outbox)
	}
	for &p in mc.outbox {
		p.asking = false
	}
	mc.last_typing, mc.typing_to = {}, {}
	// The pins are requested again the next time they are shown.
	mc.pins_conv = 0
	blobs_restart(c, forget)
	attachments_restart(c, forget)
	publish_outbox(c)
}

// msg_find looks up a message of a conversation in our windows and in the
// fetched roots.
msg_find :: proc(c: ^Server_Conn, conv: proto.Conv_Id, id: proto.Msg_Id) -> (Msg, bool) {
	for key, cache in c.msgs.caches {
		if key.conv != conv {
			continue
		}
		for m in cache.messages {
			if m.id == id {
				return m, true
			}
		}
	}
	if r, ok := c.msgs.roots[id]; ok && r.have && r.conv == conv {
		return r.msg, true
	}
	return {}, false
}

// to_the_end makes a conversation's window reach its end, where what we post
// is shown: if the window was scrolled far back, the newest page replaces it.
to_the_end :: proc(c: ^Server_Conn, key: Timeline_Key) {
	if cache := c.msgs.caches[key] or_else nil;
	   cache != nil && !cache.have_newest && !cache.loading {
		history_ask(c, key, 0, .Before)
	}
}

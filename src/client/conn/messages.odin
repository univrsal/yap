package conn

import log "common:wlog"
import "core:crypto"
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
// What we post goes into the outbox, one message at a time in the order they
// were written. A message's files are uploaded first (see attachments.odin)
// and then the message is posted. Each message has a nonce, and a post that was lost with
// the connection is repeated with the same nonce, which the server recognizes.
// What is written to somebody we have no DM with yet waits in the outbox while
// the server opens one (DM_Open, see buddies.odin). An offer of a file is posted
// the same way, and its transfer starts once the offer has its id (see
// files.odin).
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
// Typing notices are sent at most this often while typing, and are shown for
// TYPING_SHOW after the last one arrives.
TYPING_SEND_INTERVAL :: 3 * time.Second
TYPING_SHOW :: 5 * time.Second

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
// removed because of the retention policy), its size, and its name.
Msg_File :: struct {
	blob: proto.Blob_Id,
	size: u64,
	name: string,
}

msg_files_clone :: proc(files: []Msg_File) -> []Msg_File {
	if len(files) == 0 {
		return nil
	}
	out := make([]Msg_File, len(files))
	for f, i in files {
		out[i] = {f.blob, f.size, strings.clone(f.name)}
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

@(private = "file")
reactions_clone :: proc(rs: []Reaction) -> [dynamic]Reaction {
	out := make([dynamic]Reaction, 0, len(rs))
	for r in rs {
		append(&out, Reaction{strings.clone(r.emoji), r.count, r.me})
	}
	return out
}

@(private = "file")
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

Post_State :: enum {
	Open, // the DM it is for has to be opened (DM_Open)
	Post, // the message has to be posted
}

// Pending is a message of ours that is on its way.
Pending :: struct {
	nonce:  u64,
	conv:   proto.Conv_Id, // 0 while its DM is being opened
	root:   proto.Msg_Id, // the thread it replies in, if it is a reply
	dm_to:  proto.Account_Id, // who it is for, if it is a DM
	kind:   proto.Msg_Kind,
	text:   string, // .Text; for .File its name; owned
	size:   u64, // for .File
	state:  Post_State,
	asking: bool, // a request for it is pending
	// A message with files (see attachments.odin), which names the uploads.
	attach: ^Attach_Post,
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

// Posts a message to the conversation we are looking at. With `dm_to` it is
// posted to the DM with that account, and with `thread` it is posted as a reply
// in that thread.
Chat_Command :: struct {
	text:   string, // owned by the command
	dm_to:  proto.Account_Id,
	thread: Timeline_Key,
	// The text is as typed, with `@username` for a mention, instead of as
	// stored (headless; the UI turns it into tokens itself).
	typed:  bool,
}
// Reports that we are typing in the conversation we are looking at, or in a
// thread.
Typing_Command :: struct {
	thread: Timeline_Key,
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

pending_destroy :: proc(p: ^Pending) {
	delete(p.text)
	p^ = {}
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
			out.files[i] = {a.blob, a.size, strings.clone(name if name != "" else "file")}
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
	if c.view == nil {
		// Headless: log what arrived.
		place := room_name(c, proto.Room(conv))
		if key.root != 0 {
			place = fmt.tprintf("%s, thread #%d", place, key.root)
		}
		if len(got) > 0 {
			log.infof(
				"[history] %s: %d messages (%d to %d)%s, %d in all",
				place,
				len(got),
				got[0].id,
				got[len(got) - 1].id,
				", back to the first" if cache.have_oldest else "",
				len(cache.messages),
			)
		} else {
			log.infof("[history] %s: no messages", place)
		}
	}
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
@(private = "file")
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
		if c.view == nil {
			log.infof(
				"[mention] %s mentioned you in %s: %s",
				account_display(c, m.sender),
				room_name(c, proto.Room(m.conv)),
				shown,
			)
		}
	case interrupts && !quiet(c):
		audio.voice_notification_play(&c.voice, .Direct_Message if dm else .Message)
	}
	if m.sender != c.auth.me {
		publish_typing_done(c, {m.conv, m.thread_root}, m.sender)
		if m.conv == c.convs.viewing {
			publish_unread(c)
		}
	}
	if c.view == nil {
		// Headless: the log is the only place to show it.
		place := room_name(c, proto.Room(m.conv))
		who := account_display(c, m.sender)
		if m.thread_root != 0 {
			log.infof(
				"[chat] %s %s (#%d, in the thread of #%d): %s",
				place,
				who,
				m.id,
				m.thread_root,
				describe(c, m),
			)
		} else {
			log.infof("[chat] %s %s (#%d): %s", place, who, m.id, describe(c, m))
		}
	}
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

// describe returns a message as the log shows it (headless).
@(private = "file")
describe :: proc(c: ^Server_Conn, m: proto.Message) -> string {
	if .Deleted in m.flags {
		return "(deleted)"
	}
	text: string
	#partial switch m.kind {
	case .System:
		text = system_text(
			m.system,
			m.system_arg,
			account_display(c, m.sender),
			m.sender == c.auth.me,
		)
	case .Text:
		text, _ = richtext.mentions_display(m.text, c.auth.accounts, dir_roles(c), c.auth.me)
		if .Has_Attachments in m.flags {
			b := strings.builder_make(context.temp_allocator)
			strings.write_string(&b, text)
			for i in 0 ..< m.attachment_count {
				a := m.attachments[i]
				if a.blob == 0 {
					fmt.sbprintf(&b, " [file %d: %q, no longer kept]", i + 1, a.name)
				} else {
					fmt.sbprintf(&b, " [file %d: %q, %s]", i + 1, a.name, format_bytes(a.size))
				}
			}
			text = strings.to_string(b)
		}
	case .File:
		text = fmt.tprintf("offers the file %q (%s)", m.file_name, format_bytes(m.file_size))
	}
	if m.edited != 0 {
		text = fmt.tprintf("%s (edited)", text)
	}
	if .Pinned in m.flags {
		text = fmt.tprintf("%s (pinned)", text)
	}
	if .Has_Thread in m.flags {
		text = fmt.tprintf("%s (%d replies)", text, m.reply_count)
	}
	if .Forwarded in m.flags {
		text = fmt.tprintf(
			"%s (forwarded from %s, #%d)",
			text,
			account_display(c, m.forward.sender),
			m.forward.conv,
		)
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
	for key in ([]Timeline_Key {
			{m.conv, 0},
			{m.conv, m.thread_root if m.thread_root != 0 else m.id},
		}) {
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
	if c.view == nil {
		log.infof(
			"[chat] %s, message #%d is now: %s",
			room_name(c, proto.Room(m.conv)),
			m.id,
			describe(c, m),
		)
	}
}

// msgs_purged handles the server telling us that it has purged a conversation's
// messages below an id, except pinned ones and the roots of threads that live
// on. They are removed from our windows, and a window with nothing left is
// fetched again if it is on screen.
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
		for n < len(cache.messages) && cache.messages[n].id < p.before {
			msg_destroy(&cache.messages[n])
			n += 1
		}
		if n == 0 {
			continue
		}
		remove_range(&cache.messages, 0, n)
		cache.have_oldest = false
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
		if r.conv != p.conv || !r.have || id >= p.before {
			continue
		}
		append(&gone, id)
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
	if c.view == nil {
		log.infof(
			"[chat] %s: the messages below #%d were purged",
			room_name(c, proto.Room(p.conv)),
			p.before,
		)
	}
}

// purge_files removes the files from a conversation's messages below the
// purge's boundary, except from pinned messages. The files stay listed, but
// without their blobs.
@(private = "file")
purge_files :: proc(c: ^Server_Conn, p: proto.Msgs_Purged) {
	strip :: proc(m: ^Msg, before: proto.Msg_Id) -> bool {
		if m.id >= before || .Pinned in m.flags {
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
			if strip(&m, p.before) {
				publish_message_changed(c, key, m)
			}
		}
	}
	for _, &r in c.msgs.roots {
		if r.conv == p.conv && r.have && strip(&r.msg, p.before) {
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

// Ask who reacted to a message with an emoji, for the UI to show
// (View.reactors).
Reactors_Command :: struct {
	id:    proto.Msg_Id,
	emoji: string, // owned by the command
}

// reactors_fetch asks who reacted with `emoji`. The previous request is
// forgotten, and its answer is ignored if it still arrives.
reactors_fetch :: proc(c: ^Server_Conn, id: proto.Msg_Id, emoji: string) {
	mc := &c.msgs
	delete(mc.reactors_emoji)
	mc.reactors_id, mc.reactors_emoji = id, strings.clone(emoji)
	buf: [proto.REACTORS_GET_MAX_SIZE]u8
	body := proto.encode_reactors_get(&buf, id, emoji)
	if body == nil {
		return
	}
	request(
		c,
		.Reactors_Get,
		body,
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			mc := &c.msgs
			if status != .Ok || proto.Msg_Id(tag) != mc.reactors_id {
				return
			}
			buf: [proto.MAX_REACTORS]proto.Account_Id
			total, accounts, ok := proto.decode_reactors(body, &buf)
			if !ok {
				return
			}
			publish_reactors(c, mc.reactors_id, mc.reactors_emoji, total, accounts)
		},
		u64(id),
	)
}

// React with an emoji to a message, or (`on` false) take it back.
React_Command :: struct {
	id:    proto.Msg_Id,
	emoji: string, // owned by the command
	on:    bool,
	typed: bool, // the emoji is a :shortcode: as typed, as in Chat_Command
}

msg_react :: proc(c: ^Server_Conn, cmd: React_Command) {
	emoji := richtext.emoji_encode(cmd.emoji, c.emoji.names[:]) if cmd.typed else cmd.emoji
	buf: [proto.MSG_REACT_MAX_SIZE]u8
	body := proto.encode_msg_react(&buf, cmd.id, emoji, cmd.on)
	if body == nil {
		return
	}
	request(
		c,
		.Msg_React,
		body,
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			#partial switch status {
			case .Ok, .Reset:
			case .Too_Large:
				notify(
					c,
					false,
					fmt.tprintf(
						"A message can't have more than %d different reactions.",
						proto.MAX_REACTIONS,
					),
				)
			case .Invalid:
				notify(c, false, "That emoji can't be used as a reaction here.")
			case:
				notify(
					c,
					false,
					fmt.tprintf("The server failed to add the reaction (%v).", status),
				)
			}
		},
	)
}

// Forward a message (Msg_Forward) to a conversation. Headless, the
// destination is a channel given by name.
Forward_Command :: struct {
	msg:  proto.Msg_Id,
	conv: proto.Conv_Id,
	name: string, // owned by the command
}

msg_forward :: proc(c: ^Server_Conn, cmd: Forward_Command) {
	conv := cmd.conv if cmd.conv != 0 else conv_by_name(c, cmd.name)
	if conv == 0 {
		log.warnf("you aren't a member of a channel called %q", cmd.name)
		return
	}
	buf: [proto.MSG_FORWARD_SIZE]u8
	body := proto.encode_msg_forward(&buf, {conv = conv, nonce = new_nonce(), msg = cmd.msg})
	request(
		c,
		.Msg_Forward,
		body,
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			#partial switch status {
			case .Ok:
				notify(c, true, "Forwarded.")
			case .Reset:
			case .Not_Found:
				notify(
					c,
					false,
					"The message to forward or the destination conversation no longer exists.",
				)
			case .Invalid:
				notify(c, false, "That message can't be forwarded.")
			case .Denied:
				notify(c, false, "You don't have permission to post in that conversation.")
			case:
				notify(
					c,
					false,
					fmt.tprintf("The server failed to forward the message (%v).", status),
				)
			}
		},
	)
}

// Change a message of ours (Msg_Edit), delete one (Msg_Delete), or pin or
// unpin one (Msg_Pin).
Edit_Command :: struct {
	id:    proto.Msg_Id,
	text:  string, // owned by the command
	typed: bool, // as in Chat_Command
}
Delete_Command :: struct {
	id: proto.Msg_Id,
}
Pin_Command :: struct {
	id: proto.Msg_Id,
	on: bool,
}
// Fetch the pinned messages of a conversation (0 means the one we are looking
// at) for the UI's pins window. They are kept up to date until the pins of
// another conversation are requested.
Pins_Command :: struct {
	conv: proto.Conv_Id,
}
// Move the window of the conversation we are looking at to message `id`.
Jump_Command :: struct {
	id: proto.Msg_Id,
}

msg_edit :: proc(c: ^Server_Conn, id: proto.Msg_Id, raw: string) {
	buf: [proto.MAX_CHAT_SIZE]u8
	text := proto.sanitize_message(raw, buf[:])
	if text == "" {
		return
	}
	body_buf: [proto.MSG_EDIT_MAX_SIZE]u8
	request(c, .Msg_Edit, proto.encode_msg_edit(&body_buf, id, text), change_done, u64(id))
}

msg_delete :: proc(c: ^Server_Conn, id: proto.Msg_Id) {
	buf: [proto.MSG_ID_SIZE]u8
	request(c, .Msg_Delete, proto.encode_msg_id(&buf, id), change_done, u64(id))
}

msg_pin :: proc(c: ^Server_Conn, id: proto.Msg_Id, on: bool) {
	buf: [proto.MSG_PIN_SIZE]u8
	request(c, .Msg_Pin, proto.encode_msg_pin(&buf, id, on), change_done, u64(id))
}

// change_done handles the answer to a change of a message. A change that
// succeeded arrives separately, as Msg_Changed.
@(private = "file")
change_done :: proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
	#partial switch status {
	case .Ok, .Reset:
	case .Denied:
		notify(c, false, "You aren't allowed to modify this message.")
	case .Too_Large:
		notify(
			c,
			false,
			fmt.tprintf("A conversation can't have more than %d pinned messages.", proto.MAX_PINS),
		)
	case .Not_Found:
		notify(c, false, "That message no longer exists.")
	case:
		notify(c, false, fmt.tprintf("The server failed to change the message (%v).", status))
	}
}

// pins_fetch asks for a conversation's pinned messages, which are passed to the
// UI (or, headless, written to the log).
pins_fetch :: proc(c: ^Server_Conn, conv: proto.Conv_Id) {
	if conv == 0 {
		return
	}
	c.msgs.pins_conv = conv
	publish_pins_loading(c, conv)
	buf: [4]u8
	request(
		c,
		.Pins_Get,
		proto.encode_conv_id(&buf, conv),
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			conv := proto.Conv_Id(tag)
			if c.msgs.pins_conv != conv || status != .Ok {
				return
			}
			buf: [proto.MAX_PINS]proto.Message
			pins, ok := proto.decode_message_list(body, buf[:])
			if !ok {
				return
			}
			publish_pins(c, conv, pins)
			if c.view == nil {
				if len(pins) == 0 {
					log.infof("[pins] %s: nothing pinned", room_name(c, proto.Room(conv)))
				}
				for m in pins {
					log.infof(
						"[pins] %s %s (#%d): %s",
						room_name(c, proto.Room(conv)),
						account_display(c, m.sender),
						m.id,
						describe(c, m),
					)
				}
			}
		},
		u64(conv),
	)
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

// chat_send puts a message in the outbox. It is for the conversation we are
// looking at, or with `dm_to`, for the DM with that account, or with `thread`,
// a reply in that thread.
chat_send :: proc(
	c: ^Server_Conn,
	raw: string,
	dm_to: proto.Account_Id = 0,
	thread := Timeline_Key{},
) {
	buf: [proto.MAX_CHAT_SIZE]u8
	text := proto.sanitize_message(raw, buf[:])
	conv, state, ok := post_target(c, dm_to)
	thread := thread
	if thread.root != 0 {
		conv, state, ok = thread.conv, .Post, thread.conv in c.convs.convs
		// The server treats a reply to a reply as a reply to the root, so
		// our pending copy has to point at the root too.
		if m, found := msg_find(c, thread.conv, thread.root); found && m.thread_root != 0 {
			thread.root = m.thread_root
		}
	}
	if text == "" || !ok {
		return
	}
	append(
		&c.msgs.outbox,
		Pending {
			nonce = new_nonce(),
			conv = conv,
			root = thread.root,
			dm_to = dm_to,
			kind = .Text,
			text = strings.clone(text),
			state = state,
		},
	)
	// Any typing after this starts a new typing notice.
	c.msgs.last_typing = {}
	to_the_end(c, {conv, thread.root})
	publish_outbox(c)
}

// post_target returns where a post goes: the conversation we are looking at,
// or with `dm_to`, the DM with that account, which may have to be opened first.
// `first` is the state the post starts in if nothing has to be opened. It
// returns false if there is nowhere to post.
post_target :: proc(
	c: ^Server_Conn,
	dm_to: proto.Account_Id,
	first := Post_State.Post,
) -> (
	conv: proto.Conv_Id,
	state: Post_State,
	ok: bool,
) {
	if dm_to == 0 {
		conv = c.convs.viewing
		return conv, first, conv != 0
	}
	if dm_to == c.auth.me {
		return
	}
	conv = dm_with(c, dm_to)
	return conv, first if conv != 0 else .Open, true
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

// file_post puts the offer of a file in the outbox, for the DM with `to`. It
// returns the offer's nonce, by which files.odin identifies the transfer until
// the offer has an id.
file_post :: proc(c: ^Server_Conn, to: proto.Account_Id, name: string, size: u64) -> u64 {
	conv, state, _ := post_target(c, to)
	p := Pending {
		nonce = new_nonce(),
		conv  = conv,
		dm_to = to,
		kind  = .File,
		text  = strings.clone(name),
		size  = size,
		state = state,
	}
	append(&c.msgs.outbox, p)
	to_the_end(c, {conv, 0})
	publish_outbox(c)
	return p.nonce
}

new_nonce :: proc() -> (nonce: u64) {
	for nonce == 0 {
		crypto.rand_bytes(([^]u8)(&nonce)[:size_of(nonce)])
	}
	return
}

// chat_typing tells the conversation we are looking at (or with `thread`, that
// thread) that we are typing, unless we did so recently.
chat_typing :: proc(c: ^Server_Conn, thread := Timeline_Key{}) {
	mc := &c.msgs
	to := thread if thread.root != 0 else Timeline_Key{c.convs.viewing, 0}
	if !c.has_current || to.conv == 0 {
		return
	}
	if mc.typing_to == to &&
	   mc.last_typing != {} &&
	   time.tick_since(mc.last_typing) < TYPING_SEND_INTERVAL {
		return
	}
	mc.last_typing, mc.typing_to = time.tick_now(), to
	buf: [proto.TYPING_UP_SIZE]u8
	send_data(c, proto.encode_typing_up(&buf, to.conv, to.root))
}

handle_typing :: proc(c: ^Server_Conn, pt: []u8) {
	if len(pt) != proto.TYPING_DOWN_SIZE {
		return
	}
	conv, root, account := proto.decode_typing_down(pt)
	if account == c.auth.me || conv not_in c.convs.convs {
		return
	}
	publish_typing(c, {conv, root}, account)
	if c.view == nil {
		if root != 0 {
			log.infof(
				"[chat] %s is typing in %s, in the thread of #%d",
				account_display(c, account),
				room_name(c, proto.Room(conv)),
				root,
			)
		} else {
			log.infof(
				"[chat] %s is typing in %s",
				account_display(c, account),
				room_name(c, proto.Room(conv)),
			)
		}
	}
}

// drive_outbox advances the oldest entry in our outbox: a message is posted
// once its DM is open and its files are uploaded. Entries are sent one at a
// time, so that they arrive in the order they were written.
drive_outbox :: proc(c: ^Server_Conn) {
	mc := &c.msgs
	if len(mc.outbox) == 0 || !c.has_current || !c.convs.synced {
		return
	}
	p := &mc.outbox[0]
	if p.state != .Open && p.conv not_in c.convs.convs {
		log.warn("a message wasn't posted because we are no longer a member of its channel")
		outbox_fail(c)
		return
	}
	switch p.state {
	case .Open:
		if conv := dm_with(c, p.dm_to); conv != 0 {
			// The DM has been opened since, by this post's DM_Open or
			// otherwise.
			p.conv = conv
			p.state = .Post
			p.asking = false
			to_the_end(c, {conv, 0})
			publish_outbox(c)
		} else if !p.asking {
			p.asking = true
			buf: [4]u8
			request(c, .DM_Open, proto.encode_account_id(&buf, p.dm_to), open_done, p.nonce)
		}
	case .Post:
		if !p.asking {
			p.asking = true
			buf: [proto.MSG_POST_MAX_SIZE]u8
			post := proto.Msg_Post {
				conv        = p.conv,
				nonce       = p.nonce,
				thread_root = p.root,
				kind        = p.kind,
				text        = p.text,
				file_size   = p.size,
			}
			if p.attach != nil {
				post.attachment_count = len(p.attach.files)
				for f, i in p.attach.files {
					post.uploads[i] = f.id
				}
			}
			request(c, .Msg_Post, proto.encode_msg_post(buf[:], post), post_done, p.nonce)
		}
	}
}

// outbox_head returns the message at the head of the outbox if it is the one
// with `nonce`, and nil otherwise.
outbox_head :: proc(c: ^Server_Conn, nonce: u64) -> ^Pending {
	if len(c.msgs.outbox) == 0 || c.msgs.outbox[0].nonce != nonce {
		return nil
	}
	return &c.msgs.outbox[0]
}

// outbox_pop drops the message at the head of the outbox, which is done with.
outbox_pop :: proc(c: ^Server_Conn) {
	pending_destroy(&c.msgs.outbox[0])
	ordered_remove(&c.msgs.outbox, 0)
	publish_outbox(c)
}

// outbox_fail drops the message at the head of the outbox, which could not be
// posted, and tells what was waiting for it.
outbox_fail :: proc(c: ^Server_Conn) {
	p := &c.msgs.outbox[0]
	if p.kind == .File {
		file_post_failed(c, p.nonce)
	}
	if p.attach != nil {
		attach_post_failed(c, p.attach)
	}
	outbox_pop(c)
}

// outbox_give_up is outbox_fail, with a notice of why.
outbox_give_up :: proc(c: ^Server_Conn, why: string) {
	notify(c, false, why)
	outbox_fail(c)
}

// open_done handles the answer to opening the DM that a post is for. The server
// tells us about the DM (Conv_Changed) before answering, so we already know it
// by now.
@(private = "file")
open_done :: proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
	p := outbox_head(c, tag)
	if p == nil || p.state != .Open {
		return
	}
	p.asking = false
	#partial switch status {
	case .Ok:
	case .Reset:
		return // asked again on the new connection
	case:
		outbox_give_up(c, "A message wasn't sent because the server failed to open the DM.")
		return
	}
	conv, ok := proto.decode_conv_id(body)
	if !ok || conv not_in c.convs.convs {
		return // asked for again by drive_outbox
	}
	p.conv = conv
	p.state = .Post
	to_the_end(c, {conv, 0})
	if c.view == nil && c.convs.viewing != conv {
		// Headless: /say posts to this DM from now on.
		conv_view(c, conv)
	}
	publish_outbox(c)
}

@(private = "file")
post_done :: proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
	p := outbox_head(c, tag)
	if p == nil {
		return
	}
	p.asking = false
	#partial switch status {
	case .Ok:
	case .Reset:
		return // posted again, with the same nonce, on the new connection
	case .Not_Found:
		if p.attach != nil && p.state == .Post {
			// It's its uploaded files that are gone: they are uploaded
			// again, and the message is queued again after that.
			attach_upload_again(c, p.attach)
			outbox_pop(c)
			return
		}
		outbox_give_up(c, "A message wasn't posted because its channel no longer exists.")
		return
	case .Invalid:
		if p.kind == .File {
			outbox_give_up(
				c,
				"That file can't be offered: only archives, pictures and videos are allowed.",
			)
			return
		}
		if p.root != 0 {
			outbox_give_up(
				c,
				"A reply wasn't posted because the message it replies to no longer exists.",
			)
			return
		}
		outbox_give_up(c, "A message wasn't posted because the server rejected it as invalid.")
		return
	case .Denied:
		outbox_give_up(c, "A message wasn't posted because you can't write or attach files there.")
		return
	case:
		outbox_give_up(c, "A message wasn't posted because the server rejected it.")
		return
	}
	id, at, ok := proto.decode_msg_posted(body)
	if !ok {
		return
	}
	if p.attach != nil {
		// The message arrives next as Msg_New, along with its files' blobs.
		attach_posted(c, p.attach)
		outbox_pop(c)
		return
	}
	m := proto.Message {
		id          = id,
		conv        = p.conv,
		sender      = c.auth.me,
		time        = at,
		kind        = p.kind,
		thread_root = p.root,
		text        = p.text,
	}
	if p.kind == .File {
		m.text, m.file_name, m.file_size = "", p.text, p.size
		file_posted(c, p.nonce, id)
	}
	message_arrived(c, m)
	outbox_pop(c)
}

// What the UI is shown.

View_Message :: struct {
	id:          proto.Msg_Id,
	sender:      proto.Account_Id,
	time:        proto.Unix_Ms,
	edited:      proto.Unix_Ms, // 0 if it hasn't been edited
	kind:        proto.Msg_Kind,
	flags:       proto.Msg_Flags,
	thread_root: proto.Msg_Id, // for a reply
	text:        string, // owned; a file's name
	file_size:   u64,
	reactions:   [dynamic]Reaction, // owned, as are their emoji
	// For a root (.Has_Thread): the number of replies, and the last one.
	reply_count: int,
	last_reply:  proto.Msg_Id,
	// For a system message (see system_text).
	system:      u8,
	system_arg:  u32,
	// For a forwarded message: the original.
	forward:     proto.Forward_Info,
	files:       []Msg_File, // owned, as are their names
}

// view_message_destroy frees what a View_Message owns.
view_message_destroy :: proc(m: View_Message) {
	m := m
	delete(m.text)
	reactions_destroy(&m.reactions)
	msg_files_destroy(m.files)
}

// A conversation's window, as the UI sees it.
View_Timeline :: struct {
	messages:    [dynamic]View_Message,
	have_oldest: bool,
	have_newest: bool,
	loading:     bool,
	revision:    int, // bumped on any change
	appended:    int, // bumped for every message added at the end
}

// A message of ours that is on its way.
View_Pending :: struct {
	nonce:     u64,
	// For a message with files: the files and their upload progress, and
	// whether they are still being uploaded (then the message isn't in the
	// outbox yet).
	files:     []View_Pending_File, // owned
	uploading: bool,
	conv:      proto.Conv_Id, // 0 while its DM is being opened
	root:      proto.Msg_Id, // the thread, for a reply
	dm_to:     proto.Account_Id,
	kind:      proto.Msg_Kind,
	text:      string, // owned
}

View_Typing :: struct {
	to: Timeline_Key, // where: the conversation, or one of its threads
	at: time.Tick,
}

// A thread's root as fetched (Root_Command, Thread_Command), together with its
// conversation.
View_Root :: struct {
	conv: proto.Conv_Id,
	msg:  View_Message,
}

view_message_of :: proc(m: Msg) -> View_Message {
	return {
		id = m.id,
		sender = m.sender,
		time = m.time,
		edited = m.edited,
		kind = m.kind,
		flags = m.flags,
		thread_root = m.thread_root,
		text = strings.clone(m.text),
		file_size = m.file_size,
		reactions = reactions_clone(m.reactions[:]),
		reply_count = m.reply_count,
		last_reply = m.last_reply,
		system = m.system,
		system_arg = m.system_arg,
		forward = m.forward,
		files = msg_files_clone(m.files),
	}
}

@(private = "file")
timeline_clear_messages :: proc(tl: ^View_Timeline) {
	for m in tl.messages {
		view_message_destroy(m)
	}
	clear(&tl.messages)
}

// A conversation's pinned messages, as the UI's pins window shows them.
View_Pins :: struct {
	conv:     proto.Conv_Id,
	messages: [dynamic]View_Message,
	loading:  bool,
	count:    int, // bumped whenever they arrive
}

// publish_message_changed replaces a message that has changed in the UI's copy
// of its window, if the copy has it.
@(private = "file")
publish_message_changed :: proc(c: ^Server_Conn, key: Timeline_Key, m: Msg) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	tl, ok := &v.timelines[key]
	if !ok {
		return
	}
	for &old in tl.messages {
		if old.id == m.id {
			view_message_destroy(old)
			old = view_message_of(m)
			tl.revision += 1
			return
		}
	}
}

@(private = "file")
publish_pins_loading :: proc(c: ^Server_Conn, conv: proto.Conv_Id) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	if v.pins.conv != conv {
		view_clear_pins(v)
		v.pins.conv = conv
	}
	v.pins.loading = true
}

@(private = "file")
publish_pins :: proc(c: ^Server_Conn, conv: proto.Conv_Id, pins: []proto.Message) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	view_clear_pins(v)
	v.pins.conv = conv
	for m in pins {
		kept := msg_of(m)
		append(&v.pins.messages, view_message_of(kept))
		msg_destroy(&kept)
	}
	v.pins.loading = false
	v.pins.count += 1
}

@(private = "file")
publish_root :: proc(c: ^Server_Conn, r: Root) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	if old, ok := v.roots[r.msg.id]; ok {
		view_message_destroy(old.msg)
	}
	v.roots[r.msg.id] = {r.conv, view_message_of(r.msg)}
}

// publish_root_missing tells the UI that a message that was asked for by its id
// (i.e. the root of a thread or a message link) does not exist, because it's
// either gone or we can't read it.
@(private = "file")
publish_root_missing :: proc(c: ^Server_Conn, id: proto.Msg_Id) {
	v := c.view
	if v == nil {
		log.infof("[chat] message #%d doesn't exist or can't be read", id)
		return
	}
	view_write(v)
	v.roots_missing[id] = true
}

@(private = "file")
publish_root_gone :: proc(c: ^Server_Conn, id: proto.Msg_Id) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	if old, ok := v.roots[id]; ok {
		view_message_destroy(old.msg)
		delete_key(&v.roots, id)
	}
}

// View_Reactors lists who reacted to a message with an emoji, as last requested
// (Reactors_Command): the first proto.MAX_REACTORS of `total`.
View_Reactors :: struct {
	id:       proto.Msg_Id,
	emoji:    string, // owned
	total:    int,
	accounts: [dynamic]proto.Account_Id,
}

@(private = "file")
publish_reactors :: proc(
	c: ^Server_Conn,
	id: proto.Msg_Id,
	emoji: string,
	total: int,
	accounts: []proto.Account_Id,
) {
	v := c.view
	if v == nil {
		log.infof("[chat] #%d %s: %d reacted (%v)", id, emoji, total, accounts)
		return
	}
	view_write(v)
	view_clear_reactors(v)
	v.reactors.id, v.reactors.emoji, v.reactors.total = id, strings.clone(emoji), total
	append(&v.reactors.accounts, ..accounts)
}

// Call with the mutex held.
view_clear_reactors :: proc(v: ^View) {
	delete(v.reactors.emoji)
	clear(&v.reactors.accounts)
	v.reactors.id, v.reactors.emoji, v.reactors.total = 0, "", 0
}

// Call with the mutex held.
view_clear_pins :: proc(v: ^View) {
	for m in v.pins.messages {
		view_message_destroy(m)
	}
	clear(&v.pins.messages)
	v.pins.conv, v.pins.loading = 0, false
}

// Call with the mutex held.
view_clear_timelines :: proc(v: ^View) {
	for _, &tl in v.timelines {
		timeline_clear_messages(&tl)
		delete(tl.messages)
	}
	clear(&v.timelines)
	for _, r in v.roots {
		view_message_destroy(r.msg)
	}
	clear(&v.roots)
	for p in v.outbox {
		view_pending_destroy(p)
	}
	clear(&v.outbox)
	clear(&v.typing)
	v.unread = 0
}

// publish_timeline brings the UI's copy of a conversation's window in line with
// ours, copying only what the copy doesn't have: a page of older messages is
// inserted at the front, and new ones are added at the end.
publish_timeline :: proc(c: ^Server_Conn, key: Timeline_Key) {
	v := c.view
	if v == nil {
		return
	}
	cache := c.msgs.caches[key] or_else nil
	view_write(v)
	if cache == nil {
		if tl, ok := &v.timelines[key]; ok {
			timeline_clear_messages(tl)
			delete(tl.messages)
			delete_key(&v.timelines, key)
		}
		return
	}
	_, tl, _, _ := map_entry(&v.timelines, key)
	src := cache.messages[:]
	have := tl.messages[:]
	// A window that doesn't overlap the one shown replaces it.
	if len(src) == 0 ||
	   (len(have) > 0 &&
			   (have[len(have) - 1].id < src[0].id || have[0].id > src[len(src) - 1].id)) {
		timeline_clear_messages(tl)
	}
	if len(src) > 0 {
		first, last := src[0].id, src[len(src) - 1].id
		n := 0
		for n < len(tl.messages) && tl.messages[n].id < first {
			view_message_destroy(tl.messages[n])
			n += 1
		}
		remove_range(&tl.messages, 0, n)
		for len(tl.messages) > 0 && tl.messages[len(tl.messages) - 1].id > last {
			view_message_destroy(pop(&tl.messages))
		}
		if len(tl.messages) == 0 {
			for m in src {
				append(&tl.messages, view_message_of(m))
			}
		} else {
			k := 0
			for k < len(src) && src[k].id < tl.messages[0].id {
				k += 1
			}
			if k > 0 {
				older := make([]View_Message, k, context.temp_allocator)
				for m, i in src[:k] {
					older[i] = view_message_of(m)
				}
				inject_at_elems(&tl.messages, 0, ..older)
			}
			j := len(src)
			for j > 0 && src[j - 1].id > tl.messages[len(tl.messages) - 1].id {
				j -= 1
			}
			for m in src[j:] {
				append(&tl.messages, view_message_of(m))
				tl.appended += 1
			}
		}
	}
	tl.have_oldest, tl.have_newest, tl.loading =
		cache.have_oldest, cache.have_newest, cache.loading
	tl.revision += 1
}

publish_outbox :: proc(c: ^Server_Conn) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	for p in v.outbox {
		view_pending_destroy(p)
	}
	clear(&v.outbox)
	for p in c.msgs.outbox {
		append(
			&v.outbox,
			View_Pending {
				nonce = p.nonce,
				files = pending_files(p.attach) if p.attach != nil else nil,
				conv = p.conv,
				root = p.root,
				dm_to = p.dm_to,
				kind = p.kind,
				text = strings.clone(p.text),
			},
		)
	}
	// Then the messages whose files are still being uploaded. They are posted
	// once the uploads are done.
	for p in c.attach.posts {
		if p.queued {
			continue
		}
		append(
			&v.outbox,
			View_Pending {
				nonce = p.nonce,
				files = pending_files(p),
				uploading = true,
				conv = p.conv,
				root = p.root,
				dm_to = p.dm_to,
				kind = .Text,
				text = strings.clone(p.text),
			},
		)
	}
}

// publish_unread counts a message from someone else in the conversation on
// screen. The UI resets the count once the message has been seen.
@(private = "file")
publish_unread :: proc(c: ^Server_Conn) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	v.unread += 1
}

@(private = "file")
publish_typing :: proc(c: ^Server_Conn, to: Timeline_Key, account: proto.Account_Id) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	v.typing[account] = {to, time.tick_now()}
}

// publish_typing_done clears an account's typing notice once it has posted,
// since it is done typing that message.
@(private = "file")
publish_typing_done :: proc(c: ^Server_Conn, to: Timeline_Key, account: proto.Account_Id) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	if t, ok := v.typing[account]; ok && t.to == to {
		delete_key(&v.typing, account)
	}
}

// is_typing reports whether an account recently told us that it is typing in a
// conversation (or with `root`, in that thread of it). Call with the mutex
// held.
is_typing :: proc(
	v: ^View,
	account: proto.Account_Id,
	conv: proto.Conv_Id,
	root: proto.Msg_Id = 0,
) -> bool {
	t, ok := v.typing[account]
	return ok && t.to == {conv, root} && time.tick_since(t.at) < TYPING_SHOW
}

// typing_until returns when the first typing notice that is still shown will
// disappear, unless another one arrives; zero if none is shown. Call with the
// mutex held.
typing_until :: proc(v: ^View) -> (until: time.Tick) {
	for _, t in v.typing {
		if time.tick_since(t.at) < TYPING_SHOW {
			end := time.tick_add(t.at, TYPING_SHOW)
			if until == {} || time.tick_diff(end, until) > 0 {
				until = end
			}
		}
	}
	return
}

// is_typing_in_thread reports whether an account recently told us that it is
// typing in one of a conversation's threads. Call with the mutex held.
is_typing_in_thread :: proc(v: ^View, account: proto.Account_Id, conv: proto.Conv_Id) -> bool {
	t, ok := v.typing[account]
	return ok && t.to.conv == conv && t.to.root != 0 && time.tick_since(t.at) < TYPING_SHOW
}

package conn

import log "common:wlog"
import "core:crypto"
import "core:fmt"
import "core:crypto/hash"
import "core:strings"
import "core:time"

import "common:proto"
import "client:audio"

/*
Messages on our end (src/common/proto/msgs.odin).

Per conversation we keep a window of consecutive messages, newest at
the end (Conv_Cache). The server keeps everything; we keep what's being
looked at, and ask for more a page at a time: older ones when the list
is scrolled to its top, newer ones when a window that stopped short of
the end is scrolled to its bottom, a page around one message to jump to
it. A message that's posted anywhere we're a member arrives as Msg_New,
and is added to its window if that window reaches the end.

Windows are bounded: past MAX_CACHE_MESSAGES the far end is dropped (and
asked for again if it's scrolled back to), and only the CACHE_KEEP
conversations looked at last keep theirs. When the connection starts
over, every window goes and the one on screen is fetched again: nothing
is replayed (D9).

What we post goes into the outbox, one message at a time in the order
they were written: a picture is uploaded first (blobs.odin), then the
message posted. Each has a nonce, and a post the connection lost is
repeated with it, which the server recognises. What's written to
somebody we have no DM with yet waits there while the server opens one
(DM_Open, buddies.odin). An offer of a file is posted the same way, and
its transfer starts once it has its id (files.odin).

Threads (phase 11): a reply is a message of its conversation like any
other, in the conversation's window, and also in its thread's while that
thread is open (in a window of the UI's). A thread's window is kept the
same way, keyed by the conversation and the root (Timeline_Key), and goes
when the thread is closed. The roots that replies point at are fetched
one at a time (a page of one around the root) when the UI wants to say
what a reply replies to and the root isn't in a window; they're kept
while their conversation's window is.
*/

// How many messages a conversation's window holds, and how many
// conversations keep one.
MAX_CACHE_MESSAGES :: 1000
CACHE_KEEP :: 8
// The page asked for at a time.
HISTORY_PAGE :: proto.MAX_HISTORY_LIMIT
// How many threads may be open at once; opening another closes the one
// opened longest ago.
MAX_THREADS :: 4

// Timeline_Key is a window of messages: a conversation's (root 0), or
// one of its threads'.
Timeline_Key :: struct {
	conv: proto.Conv_Id,
	root: proto.Msg_Id,
}
// Typing notices go out at most this often while typing, and are shown
// for TYPING_SHOW after the last one arrives.
TYPING_SEND_INTERVAL :: 3 * time.Second
TYPING_SHOW :: 5 * time.Second
// How many times a picture is uploaded before its post is given up on.
UPLOAD_TRIES :: 3

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
	image:       proto.Msg_Image,
	file_size:   u64,
	reactions:   [dynamic]Reaction, // owned, as are their emoji
	// A root's thread (.Has_Thread): how many replies, and the last.
	reply_count: int,
	last_reply:  proto.Msg_Id,
	// A system message's: what happened, and a number about it.
	system:      u8,
	system_arg:  u32,
	// A forwarded message's original (forward.odin).
	forward:     proto.Forward_Info,
	// The files it carries (.Has_Attachments; attachments.odin).
	files:       []Msg_File, // owned, as are their names
}

// Msg_File is a file a message carries: its blob, 0 once it's been
// removed (retention), how big it is and what it's called.
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

// Reaction is an emoji a message has been reacted to with: how many did,
// and whether we're among them.
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
	messages:    [dynamic]Msg, // consecutive, by id
	have_newest: bool, // the window reaches the conversation's end
	have_oldest: bool, // ... and its beginning
	loading:     bool, // a history request is out
	// Bumped when the window is replaced, so the answer to a request
	// made for the one before is known for what it is.
	generation:  u32,
	used:        time.Tick, // when it was last looked at
}

Post_State :: enum {
	Open, // the DM it's for to open (DM_Open)
	Put, // a picture to announce (Blob_Put)
	Upload, // ... and send
	Post, // the message to post
}

// Pending is a message of ours on its way.
Pending :: struct {
	nonce:  u64,
	conv:   proto.Conv_Id, // 0 while its DM is being opened
	root:   proto.Msg_Id, // the thread it replies in, if it does
	dm_to:  proto.Account_Id, // whom it's for, if it's a DM
	// Not a message at all: our new picture, set once it's uploaded
	// (profiles.odin).
	avatar: bool,
	kind:   proto.Msg_Kind,
	text:   string, // .Text, .File's name; owned
	size:   u64, // .File's
	state:  Post_State,
	asking: bool, // a request for it is out
	// A picture: the JPEG (owned), how it's announced, and once the
	// server has it, its id.
	jpeg:   []u8,
	put:    proto.Blob_Put,
	blob:   proto.Blob_Id,
	upload: Upload,
	tries:  int,
	// A message with files (attachments.odin), whose uploads it names.
	attach: ^Attach_Post,
}

// Upload is a picture's bytes on their way to the server.
Upload :: struct {
	handle:     u64,
	send:       proto.Blob_Sender,
	tokens:     f32,
	last_chunk: time.Tick,
	last_heard: time.Tick, // when the server last said anything about it
}

Message_Client :: struct {
	caches:      map[Timeline_Key]^Conv_Cache,
	// The threads open, oldest first.
	threads:     [dynamic]Timeline_Key,
	// Roots fetched for the replies that point at them, or being
	// fetched (`have` false).
	roots:       map[proto.Msg_Id]Root,
	// The conversation whose pins the UI was last shown (pins_fetch).
	pins_conv:   proto.Conv_Id,
	// Who reacted with what was asked for last (reactors_fetch): only
	// its answer is shown.
	reactors_id:    proto.Msg_Id,
	reactors_emoji: string, // owned
	generation:  u32,
	outbox:      [dynamic]Pending,
	// Typing notices: when the last one went, and for where.
	last_typing: time.Tick,
	typing_to:   Timeline_Key,
}

// Root is a thread's root as fetched, for its conversation.
Root :: struct {
	conv: proto.Conv_Id,
	have: bool,
	msg:  Msg,
}

// Post a message to the conversation we're looking at, or with
// `dm_to`, to the DM with that account, or with `thread`, as a reply in
// that thread.
Chat_Command :: struct {
	text:   string, // owned by the command
	dm_to:  proto.Account_Id,
	thread: Timeline_Key,
	// As typed, with `@username` for a mention, rather than stored
	// (headless; the UI turns it into tokens itself).
	typed: bool,
}
// We're typing in the conversation we're looking at, or in a thread.
Typing_Command :: struct {
	thread: Timeline_Key,
}
// More of a conversation (or a thread): older messages, or (`newer`)
// newer ones than its window has.
History_Command :: struct {
	conv:  proto.Conv_Id, // 0 for the one we're looking at
	root:  proto.Msg_Id,
	newer: bool,
}
// Open a thread (fetch its replies and its root, and keep them up to
// date), or close it.
Thread_Command :: struct {
	thread: Timeline_Key,
	open:   bool,
}
// Fetch the root of a thread a reply on screen points at, for its line
// in the conversation.
Root_Command :: struct {
	conv: proto.Conv_Id,
	root: proto.Msg_Id,
}

messages_destroy :: proc(c: ^Voice_Client) {
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
	delete(p.jpeg)
	proto.blob_sender_destroy(&p.upload.send)
	p^ = {}
}

msg_destroy :: proc(m: ^Msg) {
	delete(m.text)
	reactions_destroy(&m.reactions)
	msg_files_destroy(m.files)
	m^ = {}
}

// msg_of is a message as we keep it, with its text copied.
msg_of :: proc(m: proto.Message) -> Msg {
	out := Msg {
		id = m.id,
		sender = m.sender,
		time = m.time,
		kind = m.kind,
		flags = m.flags,
		thread_root = m.thread_root,
		edited = m.edited,
		text = strings.clone(m.file_name if m.kind == .File else m.text),
		image = m.image,
		file_size = m.file_size,
		reply_count = int(m.reply_count),
		last_reply = m.last_reply,
		system = m.system,
		system_arg = m.system_arg,
		forward = m.forward,
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

/*
The window of one conversation. These only change the window; the
callers publish it.
*/

cache_destroy :: proc(cache: ^Conv_Cache) {
	for &m in cache.messages {
		msg_destroy(&m)
	}
	delete(cache.messages)
}

// cache_replace makes a page the whole window: the first one, or one
// that was jumped to. Takes the messages over.
cache_replace :: proc(cache: ^Conv_Cache, page: []Msg, more: u8) {
	for &m in cache.messages {
		msg_destroy(&m)
	}
	clear(&cache.messages)
	append(&cache.messages, ..page)
	cache.have_oldest = more & proto.MORE_BEFORE == 0
	cache.have_newest = more & proto.MORE_AFTER == 0
}

// cache_prepend adds a page of older messages. Takes the messages over;
// those the window already has are dropped.
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
	// Too long now: the newest go, and are fetched again if wanted.
	for len(cache.messages) > MAX_CACHE_MESSAGES {
		msg_destroy(&cache.messages[len(cache.messages) - 1])
		pop(&cache.messages)
		cache.have_newest = false
	}
}

// cache_append adds newer messages: a page of them, or one that was just
// posted. Takes the messages over; those the window already has are
// dropped.
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

// cache_trim_front drops the oldest messages past MAX_CACHE_MESSAGES.
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

// cache_new takes a message that was just posted, and takes it over;
// false if the window doesn't reach the end, so it isn't one of the
// window's (and is freed).
cache_new :: proc(cache: ^Conv_Cache, m: Msg) -> bool {
	m := m
	if !cache.have_newest {
		msg_destroy(&m)
		return false
	}
	cache_append(cache, {m}, 0)
	return true
}

/*
The network side.
*/

// cache_of is a window, made if there's none.
@(private = "file")
cache_of :: proc(c: ^Voice_Client, key: Timeline_Key) -> ^Conv_Cache {
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

// cache_drop lets a window go; a conversation's takes the roots fetched
// for it along, but for those of threads still open.
@(private = "file")
cache_drop :: proc(c: ^Voice_Client, key: Timeline_Key, publish := true) {
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
thread_is_open :: proc(c: ^Voice_Client, key: Timeline_Key) -> bool {
	for t in c.msgs.threads {
		if t == key {
			return true
		}
	}
	return false
}

// messages_view is the UI showing a conversation: its window is fetched
// if it has none, and the windows looked at longest ago are let go.
messages_view :: proc(c: ^Voice_Client, conv: proto.Conv_Id) {
	if conv == 0 {
		return
	}
	key := Timeline_Key{conv, 0}
	cache := cache_of(c, key)
	if len(cache.messages) == 0 && !cache.have_oldest && !cache.loading {
		history_ask(c, key, 0, .Before)
	}
	// Threads' windows stay while they're open.
	for {
		count := 0
		oldest: Timeline_Key
		for k, other in c.msgs.caches {
			if k.root != 0 {
				continue
			}
			count += 1
			if k != key && (oldest == {} || time.tick_diff(other.used, c.msgs.caches[oldest].used) < 0) {
				oldest = k
			}
		}
		if count <= CACHE_KEEP {
			break
		}
		cache_drop(c, oldest)
	}
	publish_timeline(c, key)
	// The threads open, after a new connection.
	for t in c.msgs.threads {
		thread_fetch(c, t)
	}
}

// messages_more asks for the page before (or `newer`: after) a window.
messages_more :: proc(c: ^Voice_Client, key: Timeline_Key, newer: bool) {
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
messages_jump :: proc(c: ^Voice_Client, conv: proto.Conv_Id, id: proto.Msg_Id) {
	cache := cache_of(c, {conv, 0})
	if cache.loading {
		return
	}
	history_ask(c, {conv, 0}, id, .Around)
}

@(private = "file")
history_ask :: proc(c: ^Voice_Client, key: Timeline_Key, anchor: proto.Msg_Id, dir: proto.History_Dir) {
	if !c.convs.synced {
		return
	}
	cache := cache_of(c, key)
	cache.loading = true
	buf: [proto.MSG_HISTORY_SIZE]u8
	body := proto.encode_msg_history(
		&buf,
		{conv = key.conv, thread_root = key.root, anchor = anchor, dir = dir, limit = HISTORY_PAGE},
	)
	// Which window (each has a generation of its own), and what to do
	// with the page: add it after, or have it replace the window (a
	// jump, or the newest), or else add it before.
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
history_done :: proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
	generation := u32(tag)
	key: Timeline_Key
	cache: ^Conv_Cache
	for k, found in c.msgs.caches {
		if found.generation == generation {
			key, cache = k, found
		}
	}
	if cache == nil {
		return // a window that has gone since
	}
	conv := key.conv
	cache.loading = false
	if status != .Ok {
		if status != .Reset {
			log.warnf("the server won't give us the messages of %q (%v)", room_name(c, proto.Room(conv)), status)
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
		want_picture(c, m)
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
		// Headless: what came, for the log.
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

/*
Threads.
*/

// thread_open opens a thread: its window is fetched, and its root, and
// they're kept up to date until it's closed. Past MAX_THREADS the one
// opened longest ago is closed.
thread_open :: proc(c: ^Voice_Client, key: Timeline_Key) {
	if key.conv == 0 || key.root == 0 || thread_is_open(c, key) {
		return
	}
	append(&c.msgs.threads, key)
	for len(c.msgs.threads) > MAX_THREADS {
		thread_close(c, c.msgs.threads[0])
	}
	thread_fetch(c, key)
}

thread_close :: proc(c: ^Voice_Client, key: Timeline_Key) {
	for t, i in c.msgs.threads {
		if t == key {
			ordered_remove(&c.msgs.threads, i)
			break
		}
	}
	cache_drop(c, key)
	// Its root goes with it, unless it's kept with its conversation's
	// window.
	if (Timeline_Key{key.conv, 0}) not_in c.msgs.caches {
		root_forget(c, key.root)
	}
}

// thread_fetch has an open thread's window and its root fetched, if
// they aren't here.
@(private = "file")
thread_fetch :: proc(c: ^Voice_Client, key: Timeline_Key) {
	cache := cache_of(c, key)
	if len(cache.messages) == 0 && !cache.have_oldest && !cache.loading {
		history_ask(c, key, 0, .Before)
	}
	root_want(c, key.conv, key.root)
}

// root_want has a thread's root fetched, unless it's here or on its way.
root_want :: proc(c: ^Voice_Client, conv: proto.Conv_Id, root: proto.Msg_Id) {
	if root == 0 || root in c.msgs.roots || !c.convs.synced || conv not_in c.convs.convs {
		return
	}
	c.msgs.roots[root] = {conv = conv}
	buf: [proto.MSG_HISTORY_SIZE]u8
	body := proto.encode_msg_history(&buf, {conv = conv, anchor = root, dir = .Around, limit = 1})
	request(c, .Msg_History, body, proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
		root := proto.Msg_Id(tag)
		r, ok := &c.msgs.roots[root]
		if !ok || r.have {
			return // let go of since
		}
		if status != .Ok {
			if status == .Reset {
				delete_key(&c.msgs.roots, root) // asked again
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
		want_picture(c, got[0])
		publish_root(c, r^)
	}, u64(root))
}

@(private = "file")
root_forget :: proc(c: ^Voice_Client, id: proto.Msg_Id, publish := true) {
	if r, ok := &c.msgs.roots[id]; ok {
		msg_destroy(&r.msg)
		delete_key(&c.msgs.roots, id)
	}
	if publish {
		publish_root_gone(c, id)
	}
}

// want_picture has the picture of a message fetched (blobs.odin).
@(private = "file")
want_picture :: proc(c: ^Voice_Client, m: proto.Message) {
	if m.kind == .Image && m.image.blob != 0 {
		blob_want(c, m.image)
	}
}

// messages_event takes an event about messages; false if `op` isn't one.
messages_event :: proc(c: ^Voice_Client, op: proto.Event_Op, body: []u8) -> bool {
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

// message_arrived takes a message that was just posted: one we were told
// of, or one of ours the server has taken. Whichever of those comes
// second is a message we have already.
@(private = "file")
message_arrived :: proc(c: ^Voice_Client, m: proto.Message) {
	if m.kind == .File && m.sender != c.auth.me {
		file_offer_received(c, m)
	}
	if m.thread_root != 0 {
		// Its thread's, if that's open; and the conversation's, below.
		key := Timeline_Key{m.conv, m.thread_root}
		if cache := c.msgs.caches[key] or_else nil; cache != nil && !cache_has_newer(cache, m.id) {
			if cache_new(cache, msg_of(m)) {
				want_picture(c, m)
			}
			publish_timeline(c, key)
		}
	}
	if cache := c.msgs.caches[{m.conv, 0}] or_else nil; cache != nil {
		if cache_has_newer(cache, m.id) {
			return // had it: ours, told of after its answer, or the other way round
		}
		if cache_new(cache, msg_of(m)) {
			want_picture(c, m)
		}
		publish_timeline(c, {m.conv, 0})
	} else if info, ok := c.convs.convs[m.conv]; ok && m.id <= info.last {
		// The same, for a conversation we keep no window of: nothing
		// newer than the last we know of arrives before it.
		return
	}
	interrupts, mention := conv_new_message(c, m)
	switch {
	case mention:
		// Its own sound, and said on the desktop like a poke.
		audio.voice_notification_play(&c.voice, .Mail)
		shown, _ := mentions_display(m.text, c.auth.accounts, c.auth.me)
		publish_mentioned(c, account_display(c, m.sender), room_name(c, proto.Room(m.conv)), shown)
		if c.view == nil {
			log.infof("[mention] %s mentioned you in %s: %s", account_display(c, m.sender), room_name(c, proto.Room(m.conv)), shown)
		}
	case interrupts && !quiet(c):
		audio.voice_notification_play(&c.voice, .Message)
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
			log.infof("[chat] %s %s (#%d, in the thread of #%d): %s", place, who, m.id, m.thread_root, describe(c, m))
		} else {
			log.infof("[chat] %s %s (#%d): %s", place, who, m.id, describe(c, m))
		}
	}
}

// cache_has_newer is whether a window ends at or past `id`, so that a
// message with that id that's just arrived is one it has already.
@(private = "file")
cache_has_newer :: proc(cache: ^Conv_Cache, id: proto.Msg_Id) -> bool {
	return len(cache.messages) > 0 && id <= cache.messages[len(cache.messages) - 1].id
}

// describe is a message as the log shows it (headless).
@(private = "file")
describe :: proc(c: ^Voice_Client, m: proto.Message) -> string {
	if .Deleted in m.flags {
		return "(deleted)"
	}
	text: string
	#partial switch m.kind {
	case .System:
		text = system_text(m.system, m.system_arg, account_display(c, m.sender), m.sender == c.auth.me)
	case .Text:
		text, _ = mentions_display(m.text, c.auth.accounts, c.auth.me)
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
	case .Image:
		if m.image.blob == 0 {
			text = "[picture no longer kept]"
			break
		}
		text = fmt.tprintf(
			"[picture %d, %dx%d, %d bytes]",
			m.image.blob,
			m.image.width,
			m.image.height,
			m.image.size,
		)
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
		text = fmt.tprintf("%s (forwarded from %s, #%d)", text, account_display(c, m.forward.sender), m.forward.conv)
	}
	return text
}

/*
message_changed takes a message as it now is (Msg_Changed): edited,
deleted, pinned or unpinned. Where a window has it, it's replaced; a
file offer that's been deleted can't be taken up; and the pins shown are
fetched again if this was one of them, or becomes one.
*/
@(private = "file")
message_changed :: proc(c: ^Voice_Client, m: proto.Message) {
	// An event marks nobody's reactions: ours are as they were.
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
	// The conversation's window, and its thread's (a reply) or the
	// thread it's the root of.
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
	if c.view == nil {
		log.infof("[chat] %s, message #%d is now: %s", room_name(c, proto.Room(m.conv)), m.id, describe(c, m))
	}
}

/*
msgs_purged takes the server saying it has purged a conversation below
an id (phase 15): the messages there, but for some it kept (pinned ones,
roots of threads that go on), which the windows let go of and fetch
again when they're scrolled to; or the pictures in them, but for pinned
ones'. A window with nothing left is fetched again if it's on screen.
*/
@(private = "file")
msgs_purged :: proc(c: ^Voice_Client, p: proto.Msgs_Purged) {
	if p.what == .Files {
		purge_files(c, p)
		return
	}
	strip :: proc(m: ^Msg, before: proto.Msg_Id) -> bool {
		if m.id >= before || m.kind != .Image || .Pinned in m.flags || m.image.blob == 0 {
			return false
		}
		m.image = {}
		return true
	}
	keys := make([dynamic]Timeline_Key, context.temp_allocator)
	for key in c.msgs.caches {
		if key.conv == p.conv {
			append(&keys, key)
		}
	}
	for key in keys {
		cache := c.msgs.caches[key]
		if p.what == .Images {
			for &m in cache.messages {
				if strip(&m, p.before) {
					publish_message_changed(c, key, m)
				}
			}
			continue
		}
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
		if p.what == .Messages {
			append(&gone, id)
		} else if strip(&r.msg, p.before) {
			publish_root(c, r)
		}
	}
	for id in gone {
		root_forget(c, id)
		// Fetched again if it was kept and a thread still wants it.
		for t in c.msgs.threads {
			if t.root == id {
				root_want(c, t.conv, id)
			}
		}
	}
	if c.view == nil {
		log.infof(
			"[chat] %s: the %s below #%d were purged",
			room_name(c, proto.Room(p.conv)),
			"pictures of messages" if p.what == .Images else "messages",
			p.before,
		)
	}
}

// purge_files takes the files out of a conversation's messages below
// the purge's boundary, but for pinned ones: they stay listed, without
// their blobs.
@(private = "file")
purge_files :: proc(c: ^Voice_Client, p: proto.Msgs_Purged) {
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

// reaction_changed is someone's reaction added or taken back: the
// message, where a window has it, says so.
@(private = "file")
reaction_changed :: proc(c: ^Voice_Client, change: proto.Reaction_Change) {
	react :: proc(c: ^Voice_Client, m: ^Msg, change: proto.Reaction_Change) {
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
			append(&m.reactions, Reaction{strings.clone(change.emoji), change.count, change.account == c.auth.me && change.on})
		}
	}
	// Whichever windows of the conversation have it: its own, a
	// thread's.
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
	// Who reacted with it, if that's what's shown, isn't any more.
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

// reactors_fetch asks who reacted with `emoji`; what was asked before is
// forgotten, and its answer, if it comes, ignored.
reactors_fetch :: proc(c: ^Voice_Client, id: proto.Msg_Id, emoji: string) {
	mc := &c.msgs
	delete(mc.reactors_emoji)
	mc.reactors_id, mc.reactors_emoji = id, strings.clone(emoji)
	buf: [proto.REACTORS_GET_MAX_SIZE]u8
	body := proto.encode_reactors_get(&buf, id, emoji)
	if body == nil {
		return
	}
	request(c, .Reactors_Get, body, proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
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
	}, u64(id))
}

// React with an emoji to a message, or (`on` false) take it back.
React_Command :: struct {
	id:    proto.Msg_Id,
	emoji: string, // owned by the command
	on:    bool,
	typed: bool, // a :shortcode: for a character, as in Chat_Command
}

msg_react :: proc(c: ^Voice_Client, cmd: React_Command) {
	emoji := emoji_encode(cmd.emoji, c.emoji.names[:]) if cmd.typed else cmd.emoji
	buf: [proto.MSG_REACT_MAX_SIZE]u8
	body := proto.encode_msg_react(&buf, cmd.id, emoji, cmd.on)
	if body == nil {
		return
	}
	request(c, .Msg_React, body, proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
		#partial switch status {
		case .Ok, .Reset:
		case .Too_Large:
			notify(c, false, fmt.tprintf("A message can't have more than %d different reactions.", proto.MAX_REACTIONS))
		case .Invalid:
			notify(c, false, "That isn't an emoji that can be reacted with here.")
		case:
			notify(c, false, fmt.tprintf("The server wouldn't take that reaction (%v).", status))
		}
	})
}

// Forward a message (Msg_Forward) to a conversation; headless, to a
// channel by name.
Forward_Command :: struct {
	msg:  proto.Msg_Id,
	conv: proto.Conv_Id,
	name: string, // owned by the command
}

msg_forward :: proc(c: ^Voice_Client, cmd: Forward_Command) {
	conv := cmd.conv if cmd.conv != 0 else conv_by_name(c, cmd.name)
	if conv == 0 {
		log.warnf("there's no channel called %q among yours", cmd.name)
		return
	}
	buf: [proto.MSG_FORWARD_SIZE]u8
	body := proto.encode_msg_forward(&buf, {conv = conv, nonce = new_nonce(), msg = cmd.msg})
	request(c, .Msg_Forward, body, proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
		#partial switch status {
		case .Ok:
			notify(c, true, "Forwarded.")
		case .Reset:
		case .Not_Found:
			notify(c, false, "That message, or where it was to go, isn't there for you.")
		case .Invalid:
			notify(c, false, "That message can't be forwarded.")
		case .Denied:
			notify(c, false, "You can't post there.")
		case:
			notify(c, false, fmt.tprintf("The server wouldn't forward it (%v).", status))
		}
	})
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
// Fetch the pinned messages of a conversation (0: the one we're looking
// at), for the UI's pins window; they're kept up to date until another
// is asked for.
Pins_Command :: struct {
	conv: proto.Conv_Id,
}
// Have the window of the conversation we're looking at reach message `id`.
Jump_Command :: struct {
	id: proto.Msg_Id,
}

msg_edit :: proc(c: ^Voice_Client, id: proto.Msg_Id, raw: string) {
	buf: [proto.MAX_CHAT_SIZE]u8
	text := proto.sanitize_message(raw, buf[:])
	if text == "" {
		return
	}
	body_buf: [proto.MSG_EDIT_MAX_SIZE]u8
	request(c, .Msg_Edit, proto.encode_msg_edit(&body_buf, id, text), change_done, u64(id))
}

msg_delete :: proc(c: ^Voice_Client, id: proto.Msg_Id) {
	buf: [proto.MSG_ID_SIZE]u8
	request(c, .Msg_Delete, proto.encode_msg_id(&buf, id), change_done, u64(id))
}

msg_pin :: proc(c: ^Voice_Client, id: proto.Msg_Id, on: bool) {
	buf: [proto.MSG_PIN_SIZE]u8
	request(c, .Msg_Pin, proto.encode_msg_pin(&buf, id, on), change_done, u64(id))
}

// change_done hears how a change to a message went; it shows itself, as
// Msg_Changed, when it went.
@(private = "file")
change_done :: proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
	#partial switch status {
	case .Ok, .Reset:
	case .Denied:
		notify(c, false, "You aren't allowed to do that to this message.")
	case .Too_Large:
		notify(c, false, fmt.tprintf("A conversation can't have more than %d pinned messages.", proto.MAX_PINS))
	case .Not_Found:
		notify(c, false, "That message isn't there any more.")
	case:
		notify(c, false, fmt.tprintf("The server wouldn't change that message (%v).", status))
	}
}

// pins_fetch asks for a conversation's pinned messages, which go to the
// UI (and headless, the log).
pins_fetch :: proc(c: ^Voice_Client, conv: proto.Conv_Id) {
	if conv == 0 {
		return
	}
	c.msgs.pins_conv = conv
	publish_pins_loading(c, conv)
	buf: [4]u8
	request(c, .Pins_Get, proto.encode_conv_id(&buf, conv), proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
		conv := proto.Conv_Id(tag)
		if c.msgs.pins_conv != conv || status != .Ok {
			return
		}
		buf: [proto.MAX_PINS]proto.Message
		pins, ok := proto.decode_message_list(body, buf[:])
		if !ok {
			return
		}
		for m in pins {
			want_picture(c, m)
		}
		publish_pins(c, conv, pins)
		if c.view == nil {
			if len(pins) == 0 {
				log.infof("[pins] %s: nothing pinned", room_name(c, proto.Room(conv)))
			}
			for m in pins {
				log.infof("[pins] %s %s (#%d): %s", room_name(c, proto.Room(conv)), account_display(c, m.sender), m.id, describe(c, m))
			}
		}
	}, u64(conv))
}

// messages_jump_to has the window of the conversation we're looking at
// reach message `id`: a page around it, unless it's in the window
// already.
messages_jump_to :: proc(c: ^Voice_Client, id: proto.Msg_Id) {
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

/*
messages_restart is a connection the server has made anew: the windows
go (the one on screen is fetched again when it's looked at), and what's
in the outbox is posted again from where it can be. With `forget`, we
were logged out, and what we'd written goes too.
*/
messages_restart :: proc(c: ^Voice_Client, forget := false) {
	mc := &c.msgs
	keys := make([dynamic]Timeline_Key, context.temp_allocator)
	for key in mc.caches {
		append(&keys, key)
	}
	for key in keys {
		cache_drop(c, key)
	}
	// What was fetched of roots goes too; the threads stay open, and are
	// fetched again with the conversation on screen (messages_view).
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
		if p.kind == .Image && p.blob == 0 {
			// The server has forgotten the upload with the connection.
			p.state = .Put
			proto.blob_sender_destroy(&p.upload.send)
			p.upload = {}
		}
	}
	mc.last_typing, mc.typing_to = {}, {}
	// The pins shown are asked for again when they're looked at again.
	mc.pins_conv = 0
	blobs_restart(c)
	attachments_restart(c, forget)
	publish_outbox(c)
}

// chat_send puts a message in the outbox: for the conversation we're
// looking at, or with `dm_to`, the DM with that account, or with
// `thread`, a reply in that thread.
chat_send :: proc(c: ^Voice_Client, raw: string, dm_to: proto.Account_Id = 0, thread := Timeline_Key{}) {
	buf: [proto.MAX_CHAT_SIZE]u8
	text := proto.sanitize_message(raw, buf[:])
	conv, state, ok := post_target(c, dm_to)
	thread := thread
	if thread.root != 0 {
		conv, state, ok = thread.conv, .Post, thread.conv in c.convs.convs
		// A reply to a reply is to its root, as the server will have it;
		// what we keep of ours has to say so too.
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
	// Whatever comes next is a new bout of typing.
	c.msgs.last_typing = {}
	to_the_end(c, {conv, thread.root})
	publish_outbox(c)
}

// post_target is where a post goes: the conversation we're looking at,
// or with `dm_to`, the DM with that account, which may have to be opened
// first (`first` says which state the post starts in). False if there's
// nowhere.
post_target :: proc(
	c: ^Voice_Client,
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

// msg_find is a message of a conversation, if one of our windows (or
// the roots fetched) has it.
msg_find :: proc(c: ^Voice_Client, conv: proto.Conv_Id, id: proto.Msg_Id) -> (Msg, bool) {
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

// to_the_end has a conversation's window reach its end, where what we
// post is shown: the newest page replaces one scrolled far back.
to_the_end :: proc(c: ^Voice_Client, key: Timeline_Key) {
	if cache := c.msgs.caches[key] or_else nil; cache != nil && !cache.have_newest && !cache.loading {
		history_ask(c, key, 0, .Before)
	}
}

// chat_send_image puts a picture in the outbox, for where chat_send
// would; it takes over `jpeg`.
chat_send_image :: proc(c: ^Voice_Client, jpeg: []u8, width, height: int, dm_to: proto.Account_Id = 0) {
	conv, state, ok := post_target(c, dm_to, .Put)
	if len(jpeg) == 0 || len(jpeg) > proto.MAX_IMAGE_SIZE || !ok {
		log.warnf("not sending a picture of %d bytes", len(jpeg))
		delete(jpeg)
		return
	}
	p := Pending {
		nonce = new_nonce(),
		conv = conv,
		dm_to = dm_to,
		kind = .Image,
		jpeg = jpeg,
		state = state,
		put = {kind = .Image, size = len(jpeg), width = width, height = height},
	}
	hash.hash_bytes_to_buffer(.SHA256, jpeg, p.put.hash[:])
	append(&c.msgs.outbox, p)
	c.msgs.last_typing = {}
	to_the_end(c, {conv, 0})
	publish_outbox(c)
}

// file_post puts the offer of a file in the outbox, for the DM with
// `to`; its nonce, which files.odin knows the transfer by until the
// offer has its id.
file_post :: proc(c: ^Voice_Client, to: proto.Account_Id, name: string, size: u64) -> u64 {
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

// chat_typing tells the conversation we're looking at (or with
// `thread`, that thread) that we're typing, if we haven't lately.
chat_typing :: proc(c: ^Voice_Client, thread := Timeline_Key{}) {
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

handle_typing :: proc(c: ^Voice_Client, pt: []u8) {
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
			log.infof("[chat] %s is typing in %s, in the thread of #%d", account_display(c, account), room_name(c, proto.Room(conv)), root)
		} else {
			log.infof("[chat] %s is typing in %s", account_display(c, account), room_name(c, proto.Room(conv)))
		}
	}
}

/*
drive_outbox keeps the oldest message of ours going: its picture
announced and uploaded, then the message posted. One at a time, so they
arrive in the order they were written.
*/
drive_outbox :: proc(c: ^Voice_Client) {
	mc := &c.msgs
	if len(mc.outbox) == 0 || !c.has_current || !c.convs.synced {
		return
	}
	p := &mc.outbox[0]
	if !p.avatar && p.state != .Open && p.conv not_in c.convs.convs {
		log.warn("a message wasn't posted: that channel isn't one of ours any more")
		if p.kind == .File {
			file_post_failed(c, p.nonce)
		}
		if p.attach != nil {
			attach_post_failed(c, p.attach)
		}
		pending_destroy(p)
		ordered_remove(&mc.outbox, 0)
		publish_outbox(c)
		return
	}
	switch p.state {
	case .Open:
		if conv := dm_with(c, p.dm_to); conv != 0 {
			// Opened since, by this post's DM_Open or another way.
			p.conv = conv
			p.state = .Put if p.kind == .Image else .Post
			p.asking = false
			to_the_end(c, {conv, 0})
			publish_outbox(c)
		} else if !p.asking {
			p.asking = true
			buf: [4]u8
			request(c, .DM_Open, proto.encode_account_id(&buf, p.dm_to), open_done, p.nonce)
		}
	case .Put:
		if !p.asking {
			p.asking = true
			buf: [proto.BLOB_PUT_SIZE]u8
			request(c, .Blob_Put, proto.encode_blob_put(&buf, p.put), put_done, p.nonce)
		}
	case .Upload:
		upload_step(c, p)
	case .Post:
		if !p.asking && p.avatar {
			p.asking = true
			avatar_post(c, p)
		} else if !p.asking {
			p.asking = true
			buf: [proto.MSG_POST_MAX_SIZE]u8
			post := proto.Msg_Post {
				conv        = p.conv,
				nonce       = p.nonce,
				thread_root = p.root,
				kind        = p.kind,
				text        = p.text,
				blob        = p.blob,
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

// outbox_head is the message at the head of the outbox, if it's the one
// with `nonce`.
outbox_head :: proc(c: ^Voice_Client, nonce: u64) -> ^Pending {
	if len(c.msgs.outbox) == 0 || c.msgs.outbox[0].nonce != nonce {
		return nil
	}
	return &c.msgs.outbox[0]
}

// outbox_give_up drops the message at the head of the outbox.
outbox_give_up :: proc(c: ^Voice_Client, why: string) {
	notify(c, false, why)
	if c.msgs.outbox[0].kind == .File {
		file_post_failed(c, c.msgs.outbox[0].nonce)
	}
	if attach := c.msgs.outbox[0].attach; attach != nil {
		attach_post_failed(c, attach)
	}
	pending_destroy(&c.msgs.outbox[0])
	ordered_remove(&c.msgs.outbox, 0)
	publish_outbox(c)
}

// open_done is the DM a post is for, opened: the server has told us of
// it (Conv_Changed) before answering, so it's one of ours by now.
@(private = "file")
open_done :: proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
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
		outbox_give_up(c, "A message wasn't sent: the server wouldn't open that conversation.")
		return
	}
	conv, ok := proto.decode_conv_id(body)
	if !ok || conv not_in c.convs.convs {
		return // asked again
	}
	p.conv = conv
	p.state = .Put if p.kind == .Image else .Post
	to_the_end(c, {conv, 0})
	if c.view == nil && c.convs.viewing != conv {
		// Headless: where /say goes from here.
		conv_view(c, conv)
	}
	publish_outbox(c)
}

@(private = "file")
put_done :: proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
	p := outbox_head(c, tag)
	if p == nil || p.state == .Post {
		return
	}
	p.asking = false
	#partial switch status {
	case .Ok:
	case .Reset:
		return // asked again on the new connection
	case:
		outbox_give_up(c, "The server won't take that picture.")
		return
	}
	blob, have, handle, ok := proto.decode_blob_put_answer(body)
	switch {
	case !ok:
		return
	case have:
		p.blob = blob
		p.state = .Post
		proto.blob_sender_destroy(&p.upload.send)
		p.upload = {}
	case p.state == .Upload && p.upload.handle == handle:
	// Still on its way.
	case:
		// Start (or start over) sending it.
		proto.blob_sender_destroy(&p.upload.send)
		now := time.tick_now()
		p.upload = {
			handle     = handle,
			send       = {data = p.jpeg},
			last_chunk = now,
			last_heard = now,
		}
		p.state = .Upload
		log.debugf("uploading a %dx%d picture, %d bytes", p.put.width, p.put.height, p.put.size)
	}
	publish_outbox(c)
}

// How fast a picture is uploaded, and how much may go at once.
UPLOAD_RATE :: 256 * 1024 // bytes per second
UPLOAD_BURST :: 32 * 1024
// A picture whose upload the server has said nothing about for this long
// is announced again, which says where it's got to.
UPLOAD_QUIET :: 3 * time.Second

@(private = "file")
upload_step :: proc(c: ^Voice_Client, p: ^Pending) {
	up := &p.upload
	now := time.tick_now()
	elapsed := f32(time.duration_seconds(time.tick_diff(up.last_chunk, now)))
	up.last_chunk = now
	up.tokens = min(up.tokens + elapsed * UPLOAD_RATE, UPLOAD_BURST)
	buf: [proto.MAX_PAYLOAD_SIZE]u8
	for up.tokens > 0 {
		index, data, ok := proto.blob_next_chunk(&up.send)
		if !ok {
			break
		}
		send_data(c, proto.encode_blob_chunk(buf[:], up.handle, index, data))
		up.tokens -= f32(len(data))
	}
	if proto.blob_sender_idle(&up.send) && !p.asking && time.tick_since(up.last_heard) > UPLOAD_QUIET {
		up.last_heard = now
		p.asking = true
		put_buf: [proto.BLOB_PUT_SIZE]u8
		request(c, .Blob_Put, proto.encode_blob_put(&put_buf, p.put), put_done, p.nonce)
	}
}

// upload_need is the server saying how our upload is going; false if it
// isn't about ours.
upload_need :: proc(c: ^Voice_Client, pt: []u8) -> bool {
	handle, complete, count, indices, ok := proto.decode_blob_need(pt)
	if !ok || len(c.msgs.outbox) == 0 {
		return false
	}
	p := &c.msgs.outbox[0]
	if p.state != .Upload || p.upload.handle != handle {
		return false
	}
	p.upload.last_heard = time.tick_now()
	switch {
	case proto.blob_need_failed(pt):
		p.tries += 1
		if p.tries >= UPLOAD_TRIES {
			outbox_give_up(c, "A picture couldn't be sent: the server wouldn't take it.")
			return true
		}
		log.warn("the server didn't take a picture as it arrived; sending it again")
		fallthrough
	case complete:
		// All there: announcing it again gets its id.
		proto.blob_sender_destroy(&p.upload.send)
		p.upload = {}
		p.state = .Put
		p.asking = false
	case p.upload.send.next >= proto.blob_chunk_count(len(p.jpeg)):
		// Past the first pass: what's missing goes again.
		for i in 0 ..< count {
			proto.blob_sender_needs(&p.upload.send, proto.blob_need_index(indices, i))
		}
	}
	return true
}

@(private = "file")
post_done :: proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
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
		if p.kind == .Image {
			// The picture has gone from the server; send it again.
			p.blob, p.state = 0, .Put
			return
		}
		if p.attach != nil && p.state == .Post {
			// Its files have: they go again, and it's queued after.
			attach_upload_again(c, p.attach)
			pending_destroy(p)
			ordered_remove(&c.msgs.outbox, 0)
			publish_outbox(c)
			return
		}
		outbox_give_up(c, "A message wasn't posted: the channel isn't there any more.")
		return
	case .Invalid:
		if p.kind == .File {
			outbox_give_up(c, "That file can't be offered: only archives, pictures and videos, in a DM.")
			return
		}
		if p.root != 0 {
			outbox_give_up(c, "A reply wasn't posted: what it replies to isn't there any more.")
			return
		}
		outbox_give_up(c, "A message wasn't posted: the server wouldn't take it.")
		return
	case:
		outbox_give_up(c, "A message wasn't posted: the server wouldn't take it.")
		return
	}
	id, at, ok := proto.decode_msg_posted(body)
	if !ok {
		return
	}
	if p.attach != nil {
		// Its Msg_New, which comes next, has it with its files' blobs.
		attach_posted(c, p.attach)
		pending_destroy(p)
		ordered_remove(&c.msgs.outbox, 0)
		publish_outbox(c)
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
	if p.kind == .Image {
		m.image = {
			blob   = p.blob,
			width  = u16(p.put.width),
			height = u16(p.put.height),
			size   = u32(p.put.size),
		}
		// We have the picture: no need to fetch it.
		blob_have(c, p.blob, p.jpeg, p.put.width, p.put.height)
		p.jpeg = nil
	}
	message_arrived(c, m)
	pending_destroy(p)
	ordered_remove(&c.msgs.outbox, 0)
	publish_outbox(c)
}

/*
What the UI is shown.
*/

View_Message :: struct {
	id:          proto.Msg_Id,
	sender:      proto.Account_Id,
	time:        proto.Unix_Ms,
	edited:      proto.Unix_Ms, // 0 if it hasn't been
	kind:        proto.Msg_Kind,
	flags:       proto.Msg_Flags,
	thread_root: proto.Msg_Id, // a reply's
	text:        string, // owned; a file's name
	image:       proto.Msg_Image,
	file_size:   u64,
	reactions:   [dynamic]Reaction, // owned, as are their emoji
	// A root's (.Has_Thread): how many replies, and the last.
	reply_count: int,
	last_reply:  proto.Msg_Id,
	// A system message's (system_text).
	system:      u8,
	system_arg:  u32,
	// A forwarded one's original.
	forward:     proto.Forward_Info,
	files:       []Msg_File, // owned, as are their names
}

// view_message_destroy lets go of what a View_Message owns.
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

// A message of ours on its way.
View_Pending :: struct {
	nonce: u64,
	// A message with files: what they are and how far they've got, and
	// whether they're still being uploaded (it's not in the outbox yet).
	files: []View_Pending_File, // owned
	uploading: bool,
	conv:  proto.Conv_Id, // 0 while its DM is being opened
	root:  proto.Msg_Id, // a reply's thread
	avatar: bool, // not a message: our new picture
	dm_to: proto.Account_Id,
	kind:  proto.Msg_Kind,
	text:  string, // owned
	width: int, // a picture's
	height: int,
}

View_Typing :: struct {
	to: Timeline_Key, // where: the conversation, or a thread of it
	at: time.Tick,
}

// A thread's root, as fetched (Root_Command, Thread_Command): for its
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
		image = m.image,
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

// publish_message_changed puts a message that has changed in place in
// the UI's copy of its window, if it has it.
@(private = "file")
publish_message_changed :: proc(c: ^Voice_Client, key: Timeline_Key, m: Msg) {
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
publish_pins_loading :: proc(c: ^Voice_Client, conv: proto.Conv_Id) {
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
publish_pins :: proc(c: ^Voice_Client, conv: proto.Conv_Id, pins: []proto.Message) {
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
publish_root :: proc(c: ^Voice_Client, r: Root) {
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

// publish_root_missing tells the UI a message asked for by its id (a
// thread's root, a link's) isn't to be had: gone, or not ours to read.
@(private = "file")
publish_root_missing :: proc(c: ^Voice_Client, id: proto.Msg_Id) {
	v := c.view
	if v == nil {
		log.infof("[chat] message #%d isn't there for us", id)
		return
	}
	view_write(v)
	v.roots_missing[id] = true
}

@(private = "file")
publish_root_gone :: proc(c: ^Voice_Client, id: proto.Msg_Id) {
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

// View_Reactors is who reacted to a message with an emoji, as last
// asked (Reactors_Command): the first proto.MAX_REACTORS of `total`.
View_Reactors :: struct {
	id:       proto.Msg_Id,
	emoji:    string, // owned
	total:    int,
	accounts: [dynamic]proto.Account_Id,
}

@(private = "file")
publish_reactors :: proc(c: ^Voice_Client, id: proto.Msg_Id, emoji: string, total: int, accounts: []proto.Account_Id) {
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

/*
publish_timeline brings the UI's copy of a conversation's window in line
with ours, copying only what it doesn't have: a page of older messages
goes in at the front, new ones at the end.
*/
publish_timeline :: proc(c: ^Voice_Client, key: Timeline_Key) {
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
	   (len(have) > 0 && (have[len(have) - 1].id < src[0].id || have[0].id > src[len(src) - 1].id)) {
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
	tl.have_oldest, tl.have_newest, tl.loading = cache.have_oldest, cache.have_newest, cache.loading
	tl.revision += 1
}

publish_outbox :: proc(c: ^Voice_Client) {
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
				avatar = p.avatar,
				dm_to = p.dm_to,
				kind = p.kind,
				text = strings.clone(p.text),
				width = p.put.width,
				height = p.put.height,
			},
		)
	}
	// Messages whose files are on their way, after: they're posted when
	// they're there.
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

// publish_unread counts a message from someone else in the
// conversation on screen; the UI zeroes the count once it's seen.
@(private = "file")
publish_unread :: proc(c: ^Voice_Client) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	v.unread += 1
}

@(private = "file")
publish_typing :: proc(c: ^Voice_Client, to: Timeline_Key, account: proto.Account_Id) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	v.typing[account] = {to, time.tick_now()}
}

// publish_typing_done: they've posted, so they're done typing that.
@(private = "file")
publish_typing_done :: proc(c: ^Voice_Client, to: Timeline_Key, account: proto.Account_Id) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	if t, ok := v.typing[account]; ok && t.to == to {
		delete_key(&v.typing, account)
	}
}

// is_typing says whether an account has told us lately it's typing in a
// conversation (or with `root`, in that thread of it). Call with the
// mutex held.
is_typing :: proc(v: ^View, account: proto.Account_Id, conv: proto.Conv_Id, root: proto.Msg_Id = 0) -> bool {
	t, ok := v.typing[account]
	return ok && t.to == {conv, root} && time.tick_since(t.at) < TYPING_SHOW
}

// typing_until is when the first typing notice still shown stops being
// shown, unless another comes; zero if none is. Call with the mutex held.
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

// is_typing_in_thread says whether an account has told us lately it's
// typing in one of a conversation's threads. Call with the mutex held.
is_typing_in_thread :: proc(v: ^View, account: proto.Account_Id, conv: proto.Conv_Id) -> bool {
	t, ok := v.typing[account]
	return ok && t.to.conv == conv && t.to.root != 0 && time.tick_since(t.at) < TYPING_SHOW
}

package conn

import log "common:wlog"
import "core:strings"

import "common:proto"

// What the UI is shown of the messages (see view.odin).

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
	persona:     proto.Persona, // .Persona: the name is owned
	files:       []Msg_File, // owned, as are their names
}

// view_message_destroy frees what a View_Message owns.
view_message_destroy :: proc(m: View_Message) {
	m := m
	delete(m.text)
	delete(m.persona.name)
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
		persona = {strings.clone(m.persona.name), m.persona.avatar},
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

// publish_pins shows a page of a conversation's pins: the first one, or one
// that is `added` after those shown. They are `loading` while more pages are
// coming.
publish_pins :: proc(
	c: ^Server_Conn,
	conv: proto.Conv_Id,
	pins: []proto.Message,
	added: bool,
	loading: bool,
) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	if !added || v.pins.conv != conv {
		view_clear_pins(v)
	}
	v.pins.conv = conv
	for m in pins {
		kept := msg_of(m)
		append(&v.pins.messages, view_message_of(kept))
		msg_destroy(&kept)
	}
	v.pins.loading = loading
	v.pins.count += 1
}

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
publish_root_missing :: proc(c: ^Server_Conn, id: proto.Msg_Id) {
	v := c.view
	if v == nil {
		log.infof("[chat] message #%d doesn't exist or can't be read", id)
		return
	}
	view_write(v)
	v.roots_missing[id] = true
}

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
publish_unread :: proc(c: ^Server_Conn) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	v.unread += 1
}

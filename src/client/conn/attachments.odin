package conn

import log "common:wlog"
import "core:slice"
import "core:strings"
import "core:time"

import "client:audio"
import "common:proto"

// Attachments on our end (src/common/proto/attachments.odin) are files sent with
// a message. They are uploaded to the server and kept there, and are saved from
// there by whoever reads the message.
//
// Sending: a message with files waits here while its files are uploaded, one
// file at a time (Attach_Put, followed by the chunks, see transfer.odin). Once
// all files are on the server, the message goes into the outbox and names the
// uploads. This way it doesn't hold up messages written in the meantime, which
// may even get there first (decision 4). The files stay open until the message
// is posted. If the post finds that the uploads are gone (because the server
// restarted or an hour went by), the files are uploaded again. A connection
// that restarts loses the uploads that were in progress, and they start again,
// but finished uploads stay because the server keeps them for the account.
//
// The files of our own message come back in its Msg_New, together with the
// blobs they were stored as. The answer to the post only has its id.
//
// Previews: a picture that a message carries and that is not too big
// (PREVIEW_MAX) is fetched the same way when the UI shows it
// (Attach_Preview_Command), into memory instead of a file. It is then handed to
// the pictures that messages show (blob_have), which the UI decodes and draws
// like those.
//
// Saving: a file is fetched (Attach_Get) and written to its destination as it
// arrives. It goes into the downloads folder under the name it was sent with
// (or `name (1)` and so on if that is taken), like a DM's file (see
// files_io_*.odin). A save that was cut off by the connection restarting
// continues from where it got to.

// The maximum number of attempts to upload a file before the message is given
// up.
ATTACH_TRIES :: 3
// The biggest picture a message can carry that is still fetched to be shown.
PREVIEW_MAX :: 8 * 1024 * 1024
// The tag of a get_answer for a preview, which is the blob's id with this bit
// set.
@(private = "file")
PREVIEW_TAG :: u64(1) << 63

// Attach_File is a file to attach. On a desktop it is the file at `path`, in a
// browser it is the page's picked file `web_file` (see files_io_web.odin), and
// for a pasted picture the bytes are in `data` and the name is `web_name`.
Attach_File :: struct {
	path:     string, // owned
	web_file: i32,
	web_name: string, // owned
	web_size: u64,
	data:     []u8, // owned
}

// Attach_Send_Command sends a message with files, in the places where chat_send
// would send a message. The text may be empty.
Attach_Send_Command :: struct {
	text:   string, // owned
	dm_to:  proto.Account_Id,
	thread: Timeline_Key,
	files:  []Attach_File, // owned
	typed:  bool, // headless: `@username` as typed (see Chat_Command)
}

// Attach_Cancel_Command drops a message whose files are still being sent.
Attach_Cancel_Command :: struct {
	nonce: u64,
}

// Attach_Save_Command saves file `index` of message `msg` in `conv` (0 means the
// conversation we are looking at), or stops saving it if `cancel` is set.
Attach_Save_Command :: struct {
	conv:   proto.Conv_Id,
	msg:    proto.Msg_Id,
	index:  int,
	cancel: bool,
}

// Attach_Preview_Command fetches file `index` of message `msg` in `conv` so it
// can be shown, which is only done for pictures (see preview_wanted).
Attach_Preview_Command :: struct {
	conv:  proto.Conv_Id,
	msg:   proto.Msg_Id,
	index: int,
}

attach_command_destroy :: proc(cmd: ^Attach_Send_Command) {
	delete(cmd.text)
	for f in cmd.files {
		delete(f.path)
		delete(f.web_name)
		delete(f.data)
	}
	delete(cmd.files)
	cmd^ = {}
}

Upload_State :: enum u8 {
	Waiting, // not yet announced to the server
	Putting, // an Attach_Put request is pending
	Sending,
	Done, // uploaded to the server
}

Attach_Upload :: struct {
	name:       string, // owned
	size:       u64,
	src:        File_Source,
	memory:     []u8, // owned: the bytes of a pasted picture, which are read from here instead of src
	state:      Upload_State,
	id:         u64, // the server's id, once it has announced it
	send:       proto.Transfer_Sender,
	last_heard: time.Tick,
	tries:      int,
}

// Attach_Post is a message with files, until it is posted.
Attach_Post :: struct {
	nonce:  u64,
	conv:   proto.Conv_Id,
	root:   proto.Msg_Id,
	dm_to:  proto.Account_Id,
	first:  Post_State, // the state its post starts in (Open for a DM that has to be opened)
	text:   string, // owned
	files:  []Attach_Upload, // owned
	queued: bool, // in the outbox, which happens once every file is on the server
}

Save_State :: enum u8 {
	Asking, // an Attach_Get request is pending
	Receiving,
	Done,
	Failed,
	Cancelled,
}

// Attach_Save is a file that is being saved, identified by its blob.
Attach_Save :: struct {
	blob:         proto.Blob_Id,
	name:         string, // owned
	size:         u64,
	state:        Save_State,
	asking:       bool,
	id:           u64, // the server's id of the download, once it has announced it
	recv:         proto.Transfer_Receiver,
	sink:         File_Sink,
	path:         string, // owned: where the file is saved
	last_heard:   time.Tick,
	last_publish: time.Tick,
	// A preview is received into `data` (owned) instead of a file.
	memory:       bool,
	data:         []u8,
}

Attach_Client :: struct {
	posts:        [dynamic]^Attach_Post,
	saves:        map[proto.Blob_Id]^Attach_Save,
	// Pictures that are being fetched to be shown, by their blobs.
	previews:     map[proto.Blob_Id]^Attach_Save,
	last_publish: time.Tick,
}

attachments_destroy :: proc(c: ^Voice_Client) {
	for p in c.attach.posts {
		attach_post_free(p)
	}
	delete(c.attach.posts)
	for _, sv in c.attach.saves {
		save_free(sv)
	}
	delete(c.attach.saves)
	for _, sv in c.attach.previews {
		save_free(sv)
	}
	delete(c.attach.previews)
	c.attach = {}
}

@(private = "file")
attach_post_free :: proc(p: ^Attach_Post) {
	for &f in p.files {
		file_source_close(&f.src)
		delete(f.memory)
		proto.transfer_sender_destroy(&f.send)
		delete(f.name)
	}
	delete(p.files)
	delete(p.text)
	free(p)
}

@(private = "file")
save_free :: proc(sv: ^Attach_Save) {
	if !sv.memory && (sv.state == .Asking || sv.state == .Receiving) {
		file_sink_abort(&sv.sink)
	}
	delete(sv.data)
	proto.transfer_receiver_destroy(&sv.recv)
	delete(sv.name)
	delete(sv.path)
	free(sv)
}

// Sending.

// attach_send takes in a message with files. The files are opened now and stay
// open until the message is posted.
attach_send :: proc(c: ^Voice_Client, cmd: Attach_Send_Command) {
	max_size := c.rpc.server.max_attachment
	if len(cmd.files) == 0 || len(cmd.files) > proto.MAX_ATTACHMENTS {
		notify(c, false, "A message can have at most 10 files attached.")
		return
	}
	if max_size == 0 {
		notify(c, false, "This server does not accept file attachments.")
		return
	}
	conv, first, ok := post_target(c, cmd.dm_to)
	thread := cmd.thread
	if thread.root != 0 {
		conv, first, ok = thread.conv, .Post, thread.conv in c.convs.convs
		if m, found := msg_find(c, thread.conv, thread.root); found && m.thread_root != 0 {
			thread.root = m.thread_root
		}
	}
	if !ok {
		return
	}
	buf: [proto.MAX_CHAT_SIZE]u8
	raw := typed_text(c, cmd.text) if cmd.typed else cmd.text
	p := new(Attach_Post)
	p^ = {
		nonce = new_nonce(),
		conv  = conv,
		root  = thread.root,
		dm_to = cmd.dm_to,
		first = first,
		text  = strings.clone(proto.sanitize_message(raw, buf[:])),
		files = make([]Attach_Upload, len(cmd.files)),
	}
	for spec, i in cmd.files {
		src: File_Source
		raw_name: string
		size: u64
		opened: bool
		if spec.data != nil {
			raw_name, size, opened = spec.web_name, u64(len(spec.data)), true
		} else {
			src, raw_name, size, opened = file_source_open(
				{
					path = spec.path,
					web_file = spec.web_file,
					web_name = spec.web_name,
					web_size = spec.web_size,
				},
			)
		}
		name_buf: [proto.MAX_FILE_NAME]u8
		name := proto.sanitize_file_name(raw_name, &name_buf) if opened else ""
		why := ""
		switch {
		case !opened:
			why = "A file could not be read, so the message was not sent."
		case size == 0:
			why = "Empty files cannot be sent."
		case size > max_size:
			why = "A file is larger than the maximum size this server allows."
		case name == "":
			why = "A file has a name that cannot be used."
		}
		if why != "" {
			if opened {
				file_source_close(&src)
			}
			p.files = p.files[:i]
			attach_post_free(p)
			notify(c, false, why)
			return
		}
		p.files[i] = {
			name   = strings.clone(name),
			size   = size,
			src    = src,
			memory = slice.clone(spec.data) if spec.data != nil else nil,
		}
	}
	append(&c.attach.posts, p)
	c.msgs.last_typing = {}
	to_the_end(c, {conv, thread.root})
	log.infof("[file] sending %d file(s)", len(p.files))
	publish_outbox(c)
}

// attachments_step advances the uploads and saves. It is called from the client's
// loop.
attachments_step :: proc(c: ^Voice_Client) {
	if !c.has_current || !c.convs.synced {
		return
	}
	now := time.tick_now()
	upload_turn(c, now)
	for _, sv in c.attach.saves {
		save_turn(c, sv, now)
	}
	for _, sv in c.attach.previews {
		save_turn(c, sv, now)
	}
	if time.tick_diff(c.attach.last_publish, now) >= FILE_PUBLISH_INTERVAL {
		c.attach.last_publish = now
		publish_outbox(c)
		publish_saves(c)
	}
}

// upload_turn drives the one file that is being uploaded or starts the next one,
// and queues a message once all its files are uploaded.
@(private = "file")
upload_turn :: proc(c: ^Voice_Client, now: time.Tick) {
	for i := 0; i < len(c.attach.posts); {
		p := c.attach.posts[i]
		if p.queued {
			i += 1
			continue
		}
		active: ^Attach_Upload
		all_done := true
		for &f in p.files {
			if f.state != .Done {
				all_done = false
				if active == nil {
					active = &f
				}
			}
		}
		if all_done {
			queue_post(c, p)
			i += 1
			continue
		}
		switch active.state {
		case .Waiting:
			active.state = .Putting
			buf: [proto.ATTACH_PUT_MAX_SIZE]u8
			request(
				c,
				.Attach_Put,
				proto.encode_attach_put(buf[:], {size = active.size, name = active.name}),
				put_answer,
				p.nonce,
			)
		case .Putting:
		case .Sending:
			if time.tick_diff(active.last_heard, now) > FILE_TIMEOUT {
				log.warnf("[file] the server went quiet about %q", active.name)
				if !upload_again(c, p, active) {
					continue // the message was given up, so `i` already refers to the next one
				}
			} else if !send_upload(c, active, now) {
				drop_post(c, p, "A file could not be read, so the message was not sent.")
				continue
			}
		case .Done:
		}
		// Only one file is uploaded at a time, across all messages.
		return
	}
}

// send_upload sends as much of a file as the pace allows. It returns false if
// the file cannot be read.
@(private = "file")
send_upload :: proc(c: ^Voice_Client, f: ^Attach_Upload, now: time.Tick) -> bool {
	rate := transfer_rate(c.files.upload_limit, f.send.peer_rate)
	proto.transfer_refill(&f.send, now, rate, FILE_BURST * rate / FILE_MAX_RATE)
	data: [proto.FILE_CHUNK_DATA]u8
	out: [proto.MAX_PAYLOAD_SIZE]u8
	for {
		index, first, ok := proto.transfer_pick(&f.send, now)
		if !ok {
			return true
		}
		start, end := proto.file_chunk_range(f.size, index)
		ready, read_ok := true, true
		if f.memory != nil {
			copy(data[:end - start], f.memory[start:end])
		} else {
			ready, read_ok = file_source_read(&f.src, start, data[:end - start])
		}
		if !read_ok {
			log.errorf("[file] could not read %q", f.name)
			return false
		}
		if !ready {
			return true // a browser is still reading it, so try again next time
		}
		send_data(
			c,
			proto.encode_transfer_chunk(out[:], .Upload_Chunk, f.id, index, data[:end - start]),
		)
		proto.transfer_sent(&f.send, index, first, int(end - start), now)
	}
}

// upload_again starts a file over, unless it has been tried too often. It returns
// false if the message was given up.
@(private = "file")
upload_again :: proc(c: ^Voice_Client, p: ^Attach_Post, f: ^Attach_Upload) -> bool {
	f.tries += 1
	if f.tries >= ATTACH_TRIES {
		drop_post(c, p, "A file could not be sent because the server rejected it.")
		return false
	}
	proto.transfer_sender_destroy(&f.send)
	f.send = {}
	f.state, f.id = .Waiting, 0
	return true
}

@(private = "file")
attach_post_of :: proc(c: ^Voice_Client, nonce: u64) -> (^Attach_Post, int) {
	for p, i in c.attach.posts {
		if p.nonce == nonce {
			return p, i
		}
	}
	return nil, -1
}

// drop_post gives up a message with files and tells the user why.
@(private = "file")
drop_post :: proc(c: ^Voice_Client, p: ^Attach_Post, why: string) {
	if why != "" {
		notify(c, false, why)
	}
	_, i := attach_post_of(c, p.nonce)
	if i >= 0 {
		ordered_remove(&c.attach.posts, i)
	}
	for f in p.files {
		if f.state == .Sending {
			cancel_transfer(c, f.id)
		}
	}
	attach_post_free(p)
	publish_outbox(c)
}

// attach_cancel drops a message whose files are still being sent or are waiting
// in the outbox to be posted.
attach_cancel :: proc(c: ^Voice_Client, nonce: u64) {
	p, _ := attach_post_of(c, nonce)
	if p == nil {
		return
	}
	if p.queued {
		for &pending, i in c.msgs.outbox {
			// The head of the outbox cannot be dropped while it is being posted, because
			// that is too late.
			if pending.attach == p && (i > 0 || !pending.asking) {
				pending_destroy(&pending)
				ordered_remove(&c.msgs.outbox, i)
				break
			}
		}
		if still_queued(c, p) {
			return
		}
	}
	log.infof("[file] stopped sending %d file(s)", len(p.files))
	drop_post(c, p, "")
}

@(private = "file")
still_queued :: proc(c: ^Voice_Client, p: ^Attach_Post) -> bool {
	for pending in c.msgs.outbox {
		if pending.attach == p {
			return true
		}
	}
	return false
}

@(private = "file")
cancel_transfer :: proc(c: ^Voice_Client, id: u64) {
	buf: [proto.TRANSFER_CANCEL_SIZE]u8
	send_data(c, proto.encode_transfer_cancel(&buf, id, .Cancelled))
}

@(private = "file")
put_answer :: proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
	p, _ := attach_post_of(c, tag)
	if p == nil {
		return
	}
	f: ^Attach_Upload
	for &file in p.files {
		if file.state == .Putting {
			f = &file
			break
		}
	}
	if f == nil {
		return
	}
	#partial switch status {
	case .Ok:
	case .Reset:
		f.state = .Waiting // it is announced again on the new connection
		return
	case .Rate_Limited:
		f.state = .Waiting
		return
	case .Too_Large:
		drop_post(c, p, "A file is larger than the maximum size this server allows.")
		return
	case .Denied:
		drop_post(c, p, "You don't have permission to send files here.")
		return
	case .Closed:
		drop_post(c, p, "The server has no room for more files.")
		return
	case:
		drop_post(c, p, "The server rejected the file.")
		return
	}
	id, ok := proto.decode_attach_id(body)
	if !ok {
		f.state = .Waiting
		return
	}
	now := time.tick_now()
	f.id, f.state, f.last_heard = id, .Sending, now
	proto.transfer_sender_init(&f.send, f.size, now)
	log.debugf("[file] uploading %q (%s)", f.name, format_bytes(f.size))
}

// upload_of returns the file that is being uploaded as `id`, and its message.
@(private = "file")
upload_of :: proc(c: ^Voice_Client, id: u64) -> (^Attach_Post, ^Attach_Upload) {
	for p in c.attach.posts {
		for &f in p.files {
			if f.id == id && (f.state == .Sending || f.state == .Done) {
				return p, &f
			}
		}
	}
	return nil, nil
}

handle_upload_ack :: proc(c: ^Voice_Client, pt: []u8) {
	ack, count, missing, ok := proto.decode_transfer_ack(pt)
	if !ok {
		return
	}
	p, f := upload_of(c, ack.id)
	if f == nil || f.state != .Sending {
		return
	}
	now := time.tick_now()
	f.last_heard = now
	if proto.transfer_acked(&f.send, ack, count, missing, now) {
		f.state = .Done
		log.infof("[file] uploaded %q", f.name)
		publish_outbox(c)
	}
	_ = p
}

// handle_transfer_cancel handles the server stopping an upload or a download.
handle_transfer_cancel :: proc(c: ^Voice_Client, pt: []u8) {
	id, reason := proto.decode_transfer_cancel(pt)
	if p, f := upload_of(c, id); f != nil && f.state == .Sending {
		if reason == .Failed {
			drop_post(c, p, "The server failed to store a file, so the message was not sent.")
		} else {
			upload_again(c, p, f)
		}
		return
	}
	for _, sv in all_saves(c) {
		if sv.id == id && sv.state == .Receiving {
			if reason == .Failed {
				save_end(c, sv, .Failed)
			} else {
				// The file is requested again, and what has arrived so far is kept.
				sv.asking, sv.id = false, 0
				sv.state = .Asking
			}
			return
		}
	}
}

// queue_post puts a message whose files are all on the server into the outbox.
@(private = "file")
queue_post :: proc(c: ^Voice_Client, p: ^Attach_Post) {
	p.queued = true
	pending := Pending {
		nonce  = p.nonce,
		conv   = p.conv,
		root   = p.root,
		dm_to  = p.dm_to,
		kind   = .Text,
		text   = strings.clone(p.text),
		state  = p.first,
		attach = p,
	}
	append(&c.msgs.outbox, pending)
	publish_outbox(c)
}

// attach_posted handles a message with files having been posted, so whatever is
// left of it here is removed. The message itself arrives in its Msg_New, together
// with the files' blobs.
attach_posted :: proc(c: ^Voice_Client, p: ^Attach_Post) {
	_, i := attach_post_of(c, p.nonce)
	if i >= 0 {
		ordered_remove(&c.attach.posts, i)
	}
	attach_post_free(p)
}

// attach_post_failed handles the outbox giving up on a message with files.
attach_post_failed :: proc(c: ^Voice_Client, p: ^Attach_Post) {
	drop_post(c, p, "")
}

// attach_upload_again handles a post that found its uploads gone. The files are
// uploaded again, and the message is queued again afterwards.
attach_upload_again :: proc(c: ^Voice_Client, p: ^Attach_Post) {
	p.queued = false
	for &f in p.files {
		proto.transfer_sender_destroy(&f.send)
		f.send = {}
		f.state, f.id = .Waiting, 0
	}
	log.info("[file] the server no longer has the files, so they are being sent again")
}

// Saving.

// attach_save starts saving a file that a message carries, or stops it.
attach_save :: proc(c: ^Voice_Client, cmd: Attach_Save_Command) {
	conv := cmd.conv if cmd.conv != 0 else c.convs.viewing
	m, found := msg_find(c, conv, cmd.msg)
	if !found || cmd.index < 0 || cmd.index >= len(m.files) {
		log.warnf("[file] message %d has no file %d", cmd.msg, cmd.index + 1)
		return
	}
	f := m.files[cmd.index]
	sv := c.attach.saves[f.blob] or_else nil
	if cmd.cancel {
		if sv != nil && (sv.state == .Asking || sv.state == .Receiving) {
			if sv.id != 0 {
				cancel_transfer(c, sv.id)
			}
			save_end(c, sv, .Cancelled)
		}
		return
	}
	if f.blob == 0 {
		notify(c, false, "That file is no longer available on the server.")
		return
	}
	if f.size > proto.MAX_FILE_SIZE {
		notify(c, false, "That file is too large to be saved.")
		return
	}
	if sv != nil {
		if sv.state == .Asking || sv.state == .Receiving {
			return // it is already on its way
		}
		// Saving it again, so start anew.
		delete_key(&c.attach.saves, f.blob)
		save_free(sv)
	}
	sink, path, ok := file_sink_create(c.files.download_dir, f.name, f.size)
	if !ok {
		notify(
			c,
			false,
			"The file could not be saved because the downloads folder is not writable.",
		)
		return
	}
	sv = new(Attach_Save)
	sv^ = {
		blob       = f.blob,
		name       = strings.clone(f.name),
		size       = f.size,
		sink       = sink,
		path       = path,
		last_heard = time.tick_now(),
	}
	proto.transfer_receiver_init(&sv.recv, f.size)
	c.attach.saves[f.blob] = sv
	log.infof("[file] saving %q to %s", f.name, path)
	publish_saves(c)
}

@(private = "file")
save_turn :: proc(c: ^Voice_Client, sv: ^Attach_Save, now: time.Tick) {
	switch sv.state {
	case .Asking:
		if !sv.asking {
			sv.asking = true
			sv.last_heard = now
			buf: [8]u8
			tag := u64(sv.blob) | (PREVIEW_TAG if sv.memory else 0)
			request(c, .Attach_Get, proto.encode_attach_id(&buf, u64(sv.blob)), get_answer, tag)
		}
	case .Receiving:
		if time.tick_diff(sv.last_heard, now) > FILE_TIMEOUT {
			log.warnf("[file] the server went quiet about %q", sv.name)
			sv.state, sv.asking, sv.id = .Asking, false, 0
		} else if time.tick_diff(sv.recv.last_ack, now) >= proto.TRANSFER_ACK_INTERVAL {
			send_save_ack(c, sv, now)
		}
	case .Done:
		// This is repeated a few times, in case the first ack did not arrive.
		if sv.recv.complete_acks < proto.TRANSFER_COMPLETE_ACKS &&
		   time.tick_diff(sv.recv.last_ack, now) >= proto.TRANSFER_ACK_INTERVAL * 3 {
			send_save_ack(c, sv, now)
		}
	case .Failed, .Cancelled:
	}
}

@(private = "file")
send_save_ack :: proc(c: ^Voice_Client, sv: ^Attach_Save, now: time.Tick) {
	out: [proto.MAX_PAYLOAD_SIZE]u8
	send_data(
		c,
		proto.transfer_encode_ack(
			&sv.recv,
			out[:],
			.Download_Ack,
			sv.id,
			c.files.download_limit,
			now,
		),
	)
}

@(private = "file")
get_answer :: proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
	blob := proto.Blob_Id(tag &~ PREVIEW_TAG)
	sv := (c.attach.previews if tag & PREVIEW_TAG != 0 else c.attach.saves)[blob] or_else nil
	if sv == nil || sv.state != .Asking {
		return
	}
	sv.asking = false
	#partial switch status {
	case .Ok:
	case .Reset, .Rate_Limited:
		return // it is requested again
	case .Not_Found:
		if !sv.memory {
			notify(c, false, "That file is no longer available on the server.")
		}
		save_end(c, sv, .Failed)
		return
	case:
		save_end(c, sv, .Failed)
		return
	}
	size, id, ok := proto.decode_attach_get_answer(body)
	if !ok || size != sv.size {
		log.warnf("[file] %q does not have the size its message says", sv.name)
		save_end(c, sv, .Failed)
		return
	}
	sv.id, sv.state, sv.last_heard = id, .Receiving, time.tick_now()
	if sv.recv.done > 0 {
		log.infof(
			"[file] picking %q up again, %s of %s in",
			sv.name,
			format_bytes(sv.recv.done),
			format_bytes(sv.size),
		)
	}
	// Immediately acknowledge what is already here (from before the connection
	// restarted), so that it is not sent again.
	send_save_ack(c, sv, sv.last_heard)
	publish_saves(c)
}

handle_download_chunk :: proc(c: ^Voice_Client, pt: []u8) {
	id, index, data := proto.decode_transfer_chunk(pt)
	sv: ^Attach_Save
	for _, s in all_saves(c) {
		if s.id == id && s.state == .Receiving {
			sv = s
			break
		}
	}
	if sv == nil {
		return
	}
	now := time.tick_now()
	sv.last_heard = now
	if !proto.transfer_wants(&sv.recv, index, len(data)) {
		return
	}
	start, _ := proto.file_chunk_range(sv.size, index)
	if sv.memory {
		copy(sv.data[start:], data)
	} else if !file_sink_write(&sv.sink, start, data) {
		log.errorf("[file] could not write %s", sv.path)
		cancel_transfer(c, sv.id)
		save_end(c, sv, .Failed)
		return
	}
	proto.transfer_got(&sv.recv, index, len(data))
	if proto.transfer_complete(&sv.recv) && sv.memory {
		// This is a picture to show. It now goes to the pictures that messages show.
		sv.state = .Done
		send_save_ack(c, sv, now)
		blob_have(c, sv.blob, sv.data, 0, 0)
		sv.data = nil
		return
	}
	if proto.transfer_complete(&sv.recv) {
		if !file_sink_finish(&sv.sink, sv.path) {
			log.errorf("[file] could not finish %s", sv.path)
			save_end(c, sv, .Failed)
			return
		}
		log.infof("[file] saved %q to %s", sv.name, sv.path)
		sv.state = .Done
		send_save_ack(c, sv, now)
		audio.voice_notification_play(&c.voice, .Done)
		publish_saves(c)
	}
}

@(private = "file")
save_end :: proc(c: ^Voice_Client, sv: ^Attach_Save, state: Save_State) {
	if !sv.memory && (sv.state == .Asking || sv.state == .Receiving) {
		file_sink_abort(&sv.sink)
	}
	sv.state = state
	publish_saves(c)
}

// attachments_restart handles the server having made a new connection. What was
// in progress starts again (an upload from the start, a save from where it got
// to). With `forget`, we were logged out and everything is discarded.
attachments_restart :: proc(c: ^Voice_Client, forget: bool) {
	if forget {
		for p in c.attach.posts {
			attach_post_free(p)
		}
		clear(&c.attach.posts)
		for _, sv in c.attach.saves {
			save_free(sv)
		}
		clear(&c.attach.saves)
		for _, sv in c.attach.previews {
			save_free(sv)
		}
		clear(&c.attach.previews)
		publish_saves(c)
		return
	}
	for p in c.attach.posts {
		for &f in p.files {
			if f.state == .Putting || f.state == .Sending {
				proto.transfer_sender_destroy(&f.send)
				f.send = {}
				f.state, f.id = .Waiting, 0
			}
		}
	}
	for _, sv in all_saves(c) {
		if sv.state == .Receiving || sv.state == .Asking {
			sv.state, sv.asking, sv.id = .Asking, false, 0
		}
	}
}

// all_saves returns every file that is being fetched, either to be saved or to
// be shown. It is allocated in the temp allocator.
@(private = "file")
all_saves :: proc(c: ^Voice_Client) -> map[proto.Blob_Id]^Attach_Save {
	all := make(
		map[proto.Blob_Id]^Attach_Save,
		len(c.attach.saves) + len(c.attach.previews),
		context.temp_allocator,
	)
	for blob, sv in c.attach.saves {
		all[blob] = sv
	}
	// A preview's blob may be being saved too. They are told apart by their
	// ids, so the key here only has to be unique.
	for blob, sv in c.attach.previews {
		all[proto.Blob_Id(u64(blob) | PREVIEW_TAG)] = sv
	}
	return all
}

// preview_wanted reports whether a file with that name and size is shown as a
// preview, which is the case for a picture that can be decoded and is not too
// big to fetch.
preview_wanted :: proc(name: string, size: u64) -> bool {
	if size == 0 || size > PREVIEW_MAX {
		return false
	}
	dot := strings.last_index_byte(name, '.')
	if dot < 0 {
		return false
	}
	ext := name[dot + 1:]
	for known in ([]string{"png", "jpg", "jpeg", "gif", "bmp", "webp"}) {
		if strings.equal_fold(ext, known) {
			return true
		}
	}
	return false
}

// attach_preview fetches a picture that a message carries so it can be shown,
// unless it is already here or on its way.
attach_preview :: proc(c: ^Voice_Client, cmd: Attach_Preview_Command) {
	conv := cmd.conv if cmd.conv != 0 else c.convs.viewing
	m, found := msg_find(c, conv, cmd.msg)
	if !found || cmd.index < 0 || cmd.index >= len(m.files) {
		return
	}
	f := m.files[cmd.index]
	if f.blob == 0 || !preview_wanted(f.name, f.size) {
		return
	}
	if fetch := c.blobs.cache[f.blob] or_else nil; fetch != nil && fetch.state == .Ready {
		publish_blob(c, f.blob) // it is already here
		return
	}
	if sv := c.attach.previews[f.blob] or_else nil; sv != nil {
		if sv.state == .Asking || sv.state == .Receiving || sv.state == .Failed {
			return // it is already on its way, or it is not available
		}
		// It was fetched before and dropped from memory since, so fetch it again.
		delete_key(&c.attach.previews, f.blob)
		save_free(sv)
	}
	sv := new(Attach_Save)
	sv^ = {
		blob       = f.blob,
		name       = strings.clone(f.name),
		size       = f.size,
		memory     = true,
		data       = make([]u8, f.size),
		last_heard = time.tick_now(),
	}
	proto.transfer_receiver_init(&sv.recv, f.size)
	c.attach.previews[f.blob] = sv
}

// What the UI is shown: the files of a message that is being sent
// (View_Pending, see publish_outbox), and the files that are being saved.

View_Pending_File :: struct {
	name: string, // owned
	size: u64,
	done: u64, // bytes uploaded to the server
}

View_Save :: struct {
	state: Save_State,
	size:  u64,
	done:  u64,
	path:  string, // owned
}

// pending_files returns what the UI is shown of a message's files.
pending_files :: proc(p: ^Attach_Post) -> []View_Pending_File {
	out := make([]View_Pending_File, len(p.files))
	for &f, i in p.files {
		done: u64
		switch f.state {
		case .Waiting, .Putting:
		case .Sending:
			done = proto.transfer_sender_done(&f.send)
		case .Done:
			done = f.size
		}
		out[i] = {strings.clone(f.name), f.size, done}
	}
	return out
}

view_pending_destroy :: proc(p: View_Pending) {
	delete(p.text)
	for f in p.files {
		delete(f.name)
	}
	delete(p.files)
}

publish_saves :: proc(c: ^Voice_Client) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	view_clear_saves(v)
	for blob, sv in c.attach.saves {
		v.saves[blob] = {sv.state, sv.size, sv.recv.done, strings.clone(sv.path)}
	}
}

// Call with the mutex held.
view_clear_saves :: proc(v: ^View) {
	for _, s in v.saves {
		delete(s.path)
	}
	clear(&v.saves)
}

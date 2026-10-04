package server

import "core:crypto"
import "core:crypto/hash"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:time"

import "common:proto"
import "sqlite"

/*
Attachments (src/common/proto/attachments.odin): files uploaded with a
message and kept with it, in channels and DMs.

An upload is written as it comes to blobs/incoming/<id> (blobs.odin),
each chunk where it goes. The file is hashed as it grows: whenever the
part that's there from the start gets longer, that much more is hashed,
from the chunk that just came or, for chunks that came early, from the
file. So nothing big is done at once, which would hold up voice. Once
it's whole it's kept as a blob of kind File (a rename, or nothing if
the store has that content already), and the ack says complete. The
upload stays known to its account for ATTACH_KEEP, for a post to name
it (Msg_Post, messages.odin).

A download reads from the blob's file, a chunk at a time, as the window
and the pace allow. The server takes and sends at most the config's
`rate_kb` per connection, its downloads sharing that. Each read is a
system call and each chunk is sealed and sent, so a turn of the loop
sends at most ATTACH_TURN_BYTES of them, and while downloads are going
the loop comes round every ATTACH_WAIT (server.odin) rather than when
the next packet comes: little and often, with voice in between.

A transfer that hears nothing for ATTACH_IDLE is dropped, and an
unfinished one goes with its connection. A kept file nothing points at
goes at retention's next collect.
*/

// A transfer that hears nothing from its client for this long is
// dropped.
ATTACH_IDLE :: time.Minute
// How long a finished upload may be named in a post.
ATTACH_KEEP :: time.Hour
// What one download may send in a turn of the loop, and what all of them
// may together: about half a millisecond of reading, sealing and sending.
ATTACH_BURST :: 32 * 1024
ATTACH_TURN_BYTES :: 64 * 1024
// How long the loop waits for a packet while downloads are going.
ATTACH_WAIT :: 2 * time.Millisecond

Attachments :: struct {
	max_size:  u64, // bytes; 0 takes none
	rate:      f32, // bytes per second, per connection
	uploads:   map[u64]^Attach_Upload,
	downloads: map[u64]^Attach_Download,
}

Attach_Upload :: struct {
	id:        u64,
	conn:      ^Conn, // nil once it's kept, or its connection went
	account:   proto.Account_Id,
	name:      string, // owned; sanitized
	size:      u64,
	recv:      proto.Transfer_Receiver,
	file:      ^os.File, // the part file, while it's coming
	part:      string, // owned
	hasher:    hash.Context,
	hashed:    u32, // chunks hashed, all from the start
	last_data: time.Tick,
	blob:      Blob_Id, // once it's kept
	kept_at:   time.Tick,
}

Attach_Download :: struct {
	id:         u64,
	conn:       ^Conn,
	blob:       Blob_Id,
	file:       ^os.File,
	send:       proto.Transfer_Sender,
	last_heard: time.Tick,
}

attachments_open :: proc(s: ^Server, config: Attach_Config) {
	s.attach.max_size = u64(config.max_megabytes) * 1024 * 1024
	s.attach.rate = f32(config.rate_kb) * 1024
}

attachments_close :: proc(s: ^Server) {
	for _, up in s.attach.uploads {
		upload_free(up)
	}
	for _, down in s.attach.downloads {
		download_free(down)
	}
	delete(s.attach.uploads)
	delete(s.attach.downloads)
	s.attach = {}
}

@(private = "file")
upload_free :: proc(up: ^Attach_Upload) {
	if up.file != nil {
		os.close(up.file)
		os.remove(up.part)
	}
	proto.transfer_receiver_destroy(&up.recv)
	delete(up.name)
	delete(up.part)
	free(up)
}

@(private = "file")
download_free :: proc(down: ^Attach_Download) {
	if down.file != nil {
		os.close(down.file)
	}
	proto.transfer_sender_destroy(&down.send)
	free(down)
}

// attach_test_sent, when set (by tests, which have no sessions), takes
// what would be sent to a connection.
@(thread_local)
attach_test_sent: proc(u: ^Conn, msg: []u8)

// can_send is whether there's a way to send `u` datagrams now.
@(private = "file")
can_send :: proc(s: ^Server, u: ^Conn) -> bool {
	return u != nil && (attach_test_sent != nil || sending_session(s, u) != nil)
}

@(private = "file")
attach_send :: proc(s: ^Server, u: ^Conn, msg: []u8) {
	if attach_test_sent != nil {
		attach_test_sent(u, msg)
	} else if c := sending_session(s, u); c != nil {
		send_message(s, c, msg)
	}
}

// new_transfer_id is a transfer's id: random, so one can't be guessed or
// taken for another's, and never 0.
@(private = "file")
new_transfer_id :: proc(s: ^Server) -> (id: u64) {
	for id == 0 || (id in s.attach.uploads) || (id in s.attach.downloads) {
		crypto.rand_bytes(([^]u8)(&id)[:size_of(id)])
	}
	return
}

attach_put_request :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	p, ok := proto.decode_attach_put(body)
	name_buf: [proto.MAX_FILE_NAME]u8
	name := proto.sanitize_file_name(p.name, &name_buf) if ok else ""
	switch {
	case !ok || p.size == 0 || name == "":
		respond(u, id, .Invalid)
		return
	case s.attach.max_size == 0 || !can(u.account, .Attach_Files):
		respond(u, id, .Denied)
		return
	case p.size > s.attach.max_size:
		respond(u, id, .Too_Large)
		return
	}
	busy := 0
	for _, up in s.attach.uploads {
		if up.conn == u {
			busy += 1
		}
	}
	if busy >= proto.MAX_ATTACH_TRANSFERS {
		respond(u, id, .Rate_Limited)
		return
	}

	up := new(Attach_Upload)
	up.id = new_transfer_id(s)
	up.part, _ = os.join_path({blob_incoming_dir(&s.blobs), fmt.tprintf("%x", up.id)}, context.allocator)
	file, err := os.open(up.part, {.Read, .Write, .Create, .Trunc}, {.Read_User, .Write_User})
	if err != nil {
		log.errorf("could not create %s: %v", up.part, err)
		delete(up.part)
		free(up)
		respond(u, id, .Internal)
		return
	}
	up.file = file
	up.conn = u
	up.account = u.account.id
	up.name = strings.clone(name)
	up.size = p.size
	up.last_data = time.tick_now()
	proto.transfer_receiver_init(&up.recv, p.size)
	hash.init(&up.hasher, .SHA256)
	s.attach.uploads[up.id] = up
	log.debugf("%s is uploading %q (%d bytes) as %x", conn_label(u), up.name, up.size, up.id)

	answer: [proto.ATTACH_PUT_ANSWER_SIZE]u8
	respond(u, id, .Ok, proto.encode_attach_id(&answer, up.id))
}

handle_upload_chunk :: proc(s: ^Server, u: ^Conn, pt: []u8) {
	id, index, data := proto.decode_transfer_chunk(pt)
	up := s.attach.uploads[id] or_else nil
	if up == nil || up.account != u.account.id {
		send_cancel(s, u, id, .Gone)
		return
	}
	if up.blob != 0 {
		// Kept already: it may not have heard.
		if time.tick_since(up.recv.last_ack) >= proto.TRANSFER_ACK_INTERVAL {
			send_upload_ack(s, u, up, time.tick_now())
		}
		return
	}
	if up.conn != u || !proto.transfer_wants(&up.recv, index, len(data)) {
		return // a repeat, or one from a connection that's gone
	}
	start, _ := proto.file_chunk_range(up.size, index)
	if n, err := os.write_at(up.file, data, i64(start)); err != nil || n != len(data) {
		log.errorf("could not write %s: %v", up.part, err)
		send_cancel(s, u, id, .Failed)
		upload_drop(s, up)
		return
	}
	proto.transfer_got(&up.recv, index, len(data))
	up.last_data = time.tick_now()

	// Hash what's there from the start and wasn't yet.
	for up.hashed < up.recv.base {
		if up.hashed == index {
			hash.update(&up.hasher, data)
		} else {
			buf: [proto.FILE_CHUNK_DATA]u8
			from, to := proto.file_chunk_range(up.size, up.hashed)
			chunk := buf[:to - from]
			if n, err := os.read_at(up.file, chunk, i64(from)); err != nil || n != len(chunk) {
				log.errorf("could not read back %s: %v", up.part, err)
				send_cancel(s, u, id, .Failed)
				upload_drop(s, up)
				return
			}
			hash.update(&up.hasher, chunk)
		}
		up.hashed += 1
	}
	if proto.transfer_complete(&up.recv) {
		upload_keep(s, u, up)
	}
}

// upload_keep keeps an upload that's all there as a blob, and says so.
@(private = "file")
upload_keep :: proc(s: ^Server, u: ^Conn, up: ^Attach_Upload) {
	sum: [BLOB_HASH_SIZE]u8
	hash.final(&up.hasher, sum[:])
	os.close(up.file)
	up.file = nil
	blob, ok := blob_adopt(&s.blobs, .File, up.part, sum, int(up.size), i64(up.account))
	if !ok {
		os.remove(up.part)
		send_cancel(s, u, up.id, .Failed)
		upload_drop(s, up)
		return
	}
	up.blob = blob
	up.kept_at = time.tick_now()
	up.conn = nil
	log.debugf("%s uploaded %q as blob %d", conn_label(u), up.name, blob)
	send_upload_ack(s, u, up, up.kept_at)
}

@(private = "file")
upload_drop :: proc(s: ^Server, up: ^Attach_Upload) {
	delete_key(&s.attach.uploads, up.id)
	upload_free(up)
}

@(private = "file")
send_upload_ack :: proc(s: ^Server, u: ^Conn, up: ^Attach_Upload, now: time.Tick) {
	out: [proto.MAX_PAYLOAD_SIZE]u8
	msg := proto.transfer_encode_ack(&up.recv, out[:], .Upload_Ack, up.id, u32(s.attach.rate), now)
	attach_send(s, u, msg)
}

@(private = "file")
send_cancel :: proc(s: ^Server, u: ^Conn, id: u64, reason: proto.File_Cancel_Reason) {
	buf: [proto.TRANSFER_CANCEL_SIZE]u8
	attach_send(s, u, proto.encode_transfer_cancel(&buf, id, reason))
}

// attach_upload_for is the upload `id` of `account`'s, once it's kept,
// for a post to name.
attach_upload_for :: proc(s: ^Server, account: proto.Account_Id, id: u64) -> (^Attach_Upload, bool) {
	up := s.attach.uploads[id] or_else nil
	if up == nil || up.account != account || up.blob == 0 {
		return nil, false
	}
	return up, true
}

attach_get_request :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	blob, ok := proto.decode_attach_id(body)
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	b, found := blob_get(&s.blobs, Blob_Id(blob))
	if !found || !attachment_visible(s, u.account.id, b.id) {
		respond(u, id, .Not_Found)
		return
	}
	answer: [proto.ATTACH_GET_ANSWER_SIZE]u8
	busy := 0
	for _, down in s.attach.downloads {
		if down.conn != u {
			continue
		}
		if down.blob == b.id {
			// Asked again: it's on its way.
			respond(u, id, .Ok, proto.encode_attach_get_answer(&answer, u64(b.size), down.id))
			return
		}
		busy += 1
	}
	if busy >= proto.MAX_ATTACH_TRANSFERS {
		respond(u, id, .Rate_Limited)
		return
	}
	path := blob_path(&s.blobs, b.hash)
	file, err := os.open(path)
	if err != nil {
		log.errorf("blob %d: could not open %s: %v", b.id, path, err)
		respond(u, id, .Internal)
		return
	}
	down := new(Attach_Download)
	down^ = {
		id         = new_transfer_id(s),
		conn       = u,
		blob       = b.id,
		file       = file,
		last_heard = time.tick_now(),
	}
	proto.transfer_sender_init(&down.send, u64(b.size), down.last_heard)
	s.attach.downloads[down.id] = down
	log.debugf("sending attachment blob %d to %s as %x", b.id, conn_label(u), down.id)
	respond(u, id, .Ok, proto.encode_attach_get_answer(&answer, u64(b.size), down.id))
}

// attachment_visible is whether an account may fetch a file: a message
// it may read has it.
attachment_visible :: proc(s: ^Server, account: proto.Account_Id, blob: Blob_Id) -> bool {
	q := db_stmt(&s.db, .Attach_Blob_Convs)
	db_bind_int(q, 1, i64(blob))
	for {
		row, ok := db_step(&s.db, q)
		if !ok || !row {
			return false
		}
		conv := conv_by_id(&s.convs, proto.Conv_Id(db_col_int(q, 0)))
		if conv != nil && conv_is_member(conv, account) {
			sqlite.reset(q)
			return true
		}
	}
}

handle_download_ack :: proc(s: ^Server, u: ^Conn, pt: []u8) {
	ack, count, missing, ok := proto.decode_transfer_ack(pt)
	if !ok {
		return
	}
	down := s.attach.downloads[ack.id] or_else nil
	if down == nil || down.conn != u {
		send_cancel(s, u, ack.id, .Gone)
		return
	}
	now := time.tick_now()
	down.last_heard = now
	if proto.transfer_acked(&down.send, ack, count, missing, now) {
		log.debugf("%s has attachment blob %d", conn_label(u), down.blob)
		download_drop(s, down)
	}
}

@(private = "file")
download_drop :: proc(s: ^Server, down: ^Attach_Download) {
	delete_key(&s.attach.downloads, down.id)
	download_free(down)
}

// handle_transfer_cancel: the client stops an upload or a download of
// its own.
handle_transfer_cancel :: proc(s: ^Server, u: ^Conn, pt: []u8) {
	id, _ := proto.decode_transfer_cancel(pt)
	if up := s.attach.uploads[id] or_else nil; up != nil && up.conn == u {
		upload_drop(s, up)
	} else if down := s.attach.downloads[id] or_else nil; down != nil && down.conn == u {
		download_drop(s, down)
	}
}

// attachments_sync keeps transfers moving: acks to uploaders, chunks to
// downloaders, and drops what has gone quiet or is too old to post.
attachments_sync :: proc(s: ^Server) {
	now := time.tick_now()
	drop := make([dynamic]u64, context.temp_allocator)
	for id, up in s.attach.uploads {
		if up.blob != 0 {
			// Kept: say so a few times, then wait for a post.
			if time.tick_diff(up.kept_at, now) > ATTACH_KEEP {
				append(&drop, id)
			} else if up.recv.complete_acks < proto.TRANSFER_COMPLETE_ACKS &&
			   time.tick_diff(up.recv.last_ack, now) >= proto.TRANSFER_ACK_INTERVAL * 3 {
				if u := upload_conn(s, up); can_send(s, u) {
					send_upload_ack(s, u, up, now)
				}
			}
			continue
		}
		if up.conn == nil || time.tick_diff(up.last_data, now) > ATTACH_IDLE {
			log.debugf("upload %x stopped", id)
			append(&drop, id)
			continue
		}
		if time.tick_diff(up.recv.last_ack, now) >= proto.TRANSFER_ACK_INTERVAL && can_send(s, up.conn) {
			send_upload_ack(s, up.conn, up, now)
		}
	}
	for id in drop {
		upload_drop(s, s.attach.uploads[id])
	}

	clear(&drop)
	budget := ATTACH_TURN_BYTES
	for id, down in s.attach.downloads {
		if time.tick_diff(down.last_heard, now) > ATTACH_IDLE {
			log.debugf("download %x stopped", id)
			append(&drop, id)
			continue
		}
		if !can_send(s, down.conn) || !send_download(s, down, now, &budget) {
			continue
		}
		append(&drop, id)
	}
	for id in drop {
		download_drop(s, s.attach.downloads[id])
	}
}

// upload_conn is where a kept upload's acks go. The connection that sent
// it isn't remembered once it's kept, so any of its account's: only
// the one that uploaded it knows the id.
@(private = "file")
upload_conn :: proc(s: ^Server, up: ^Attach_Upload) -> ^Conn {
	acc := s.accounts.by_id[up.account] or_else nil
	if acc == nil {
		return nil
	}
	for u in acc.conns {
		if can_send(s, u) {
			return u
		}
	}
	return nil
}

// attachments_busy is whether downloads are going, which the loop comes
// round for often (ATTACH_WAIT).
attachments_busy :: proc(s: ^Server) -> bool {
	return len(s.attach.downloads) > 0
}

// send_download sends what the pace allows of a download, and what's
// left of this turn's `budget`; true if it can't go on (its file can't
// be read).
@(private = "file")
send_download :: proc(s: ^Server, down: ^Attach_Download, now: time.Tick, budget: ^int) -> bool {
	// The connection's downloads share its rate.
	sharing := 0
	for _, other in s.attach.downloads {
		if other.conn == down.conn {
			sharing += 1
		}
	}
	rate := s.attach.rate / f32(max(sharing, 1))
	if down.send.peer_rate > 0 {
		rate = min(rate, f32(down.send.peer_rate))
	}
	proto.transfer_refill(&down.send, now, rate, ATTACH_BURST)
	buf: [proto.FILE_CHUNK_DATA]u8
	out: [proto.MAX_PAYLOAD_SIZE]u8
	for budget^ > 0 {
		index, first, ok := proto.transfer_pick(&down.send, now)
		if !ok {
			return false
		}
		from, to := proto.file_chunk_range(down.send.size, index)
		chunk := buf[:to - from]
		if n, err := os.read_at(down.file, chunk, i64(from)); err != nil || n != len(chunk) {
			log.errorf("blob %d: could not read it: %v", down.blob, err)
			send_cancel(s, down.conn, down.id, .Failed)
			return true
		}
		attach_send(s, down.conn, proto.encode_transfer_chunk(out[:], .Download_Chunk, down.id, index, chunk))
		proto.transfer_sent(&down.send, index, first, len(chunk), now)
		budget^ -= len(chunk)
	}
	return false
}

// attachments_conn_gone ends a leaving connection's transfers; what it
// had finished uploading stays, for its account's posts.
attachments_conn_gone :: proc(s: ^Server, u: ^Conn) {
	drop := make([dynamic]u64, context.temp_allocator)
	for id, up in s.attach.uploads {
		if up.conn == u {
			append(&drop, id)
		}
	}
	for id in drop {
		upload_drop(s, s.attach.uploads[id])
	}
	clear(&drop)
	for id, down in s.attach.downloads {
		if down.conn == u {
			append(&drop, id)
		}
	}
	for id in drop {
		download_drop(s, s.attach.downloads[id])
	}
}

// attach_files puts a message's files in its record.
attach_files :: proc(s: ^Server, m: ^proto.Message) {
	if .Has_Attachments not_in m.flags {
		return
	}
	q := db_stmt(&s.db, .Attach_Of_Msg)
	db_bind_int(q, 1, i64(m.id))
	m.attachment_count = 0
	for m.attachment_count < proto.MAX_ATTACHMENTS {
		row, ok := db_step(&s.db, q)
		if !ok || !row {
			break
		}
		m.attachments[m.attachment_count] = {
			blob = proto.Blob_Id(db_col_int(q, 0)),
			name = db_col_text(q, 1),
			size = u64(db_col_int(q, 2)),
		}
		m.attachment_count += 1
	}
	sqlite.reset(q)
	if m.attachment_count == 0 {
		// Nothing there after all: a record can't say it has files and
		// list none.
		m.flags -= {.Has_Attachments}
	}
}

// attachments_store writes a new message's files, in their order, and
// their names where search finds them.
attachments_store :: proc(s: ^Server, m: proto.Message) -> bool {
	if m.attachment_count == 0 {
		return true
	}
	names := strings.builder_make(context.temp_allocator)
	for i in 0 ..< m.attachment_count {
		if i > 0 {
			strings.write_byte(&names, ' ')
		}
		strings.write_string(&names, m.attachments[i].name)
	}
	index := db_stmt(&s.db, .Files_Index_Add)
	db_bind_int(index, 1, i64(m.id))
	db_bind_text(index, 2, strings.to_string(names))
	db_run(&s.db, index) or_return
	for i in 0 ..< m.attachment_count {
		a := m.attachments[i]
		q := db_stmt(&s.db, .Attach_Add)
		db_bind_int(q, 1, i64(m.id))
		db_bind_int(q, 2, i64(i))
		db_bind_int(q, 3, i64(a.blob))
		db_bind_text(q, 4, a.name)
		db_bind_int(q, 5, i64(a.size))
		db_run(&s.db, q) or_return
	}
	return true
}

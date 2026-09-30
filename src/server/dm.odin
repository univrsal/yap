package server

import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:time"

import "common:."
import "common:proto"

/*
Direct messages (src/common/proto/dm.odin). The server can't read them: it
holds each one for its recipient until they acknowledge it, handing it
over whenever they're online, and keeps what's held in a file next to
the config, so a restart doesn't lose them.

The file is rewritten whenever what's held changes. It's small - at
most proto.MAX_HELD_DMS per user, each well under a kilobyte - and
changes only as fast as people type.
*/

// Held_DM is a DM waiting for its recipient to take it.
Held_DM :: struct {
	from:      [proto.KEY_SIZE]u8,
	id:        u64,
	received:  proto.Unix_Time, // when the server took it in
	nonce:     [proto.DM_NONCE_SIZE]u8,
	sealed:    []u8, // owned
	last_sent: time.Tick, // to the recipient; not saved
	// When it came in, to tell whether it waited for the recipient to
	// connect (proto.DM_Flag.Waited). Not saved: one loaded from the file
	// has waited, whenever they connect.
	arrived:   time.Tick,
}

// How many of a recipient's held DMs go out at once; the rest follow as
// these are acknowledged.
DM_WINDOW :: 8
// How many ids per sender are remembered, so a resent DM_Send that was
// already taken (and maybe delivered) isn't held again.
DM_RECENT_IDS :: 64
// Typing notices are passed on at most this often per sender.
DM_TYPING_INTERVAL :: 250 * time.Millisecond

DM_Store :: struct {
	path:   string,
	// By recipient key, oldest first.
	held:   map[[proto.KEY_SIZE]u8][dynamic]Held_DM,
	// By sender key: the last ids they sent, oldest overwritten first.
	recent: map[[proto.KEY_SIZE]u8]Recent_DM_Ids,
	dirty:  bool, // `held` changed since it was saved
	// Image DMs' pictures, by the DM's id; in memory only.
	images: map[u64]^Held_Image,
}

Recent_DM_Ids :: struct {
	ids:  [DM_RECENT_IDS]u64,
	next: int,
}

@(private = "file")
recent_has :: proc(r: ^Recent_DM_Ids, id: u64) -> bool {
	for x in r.ids {
		if x == id && id != 0 {
			return true
		}
	}
	return false
}

@(private = "file")
recent_add :: proc(r: ^Recent_DM_Ids, id: u64) {
	r.ids[r.next] = id
	r.next = (r.next + 1) % DM_RECENT_IDS
}

handle_dm_send :: proc(s: ^Server, c: ^Client, pt: []u8) {
	id, to, nonce, sealed := proto.decode_dm_send(pt)
	result, fresh := dm_check(s, c.user, to, id)
	if fresh {
		dm_hold(s, c.user, to, id, nonce, sealed)
	}
	send_dm_sent(s, c, id, result)
}

// dm_check is whether a DM from `from` to `to` may be held: fresh is
// false if it may not, or if it's a resend of one already taken, and
// the result says which.
@(private = "file")
dm_check :: proc(
	s: ^Server,
	from: ^User,
	to: [proto.KEY_SIZE]u8,
	id: u64,
) -> (
	result: proto.DM_Result,
	fresh: bool,
) {
	to := to
	if to == from.key {
		return .Full, false
	}
	// Taken as entries: a plain &map[key] is nil for a key not there yet.
	_, recent, _, _ := map_entry(&s.dms.recent, from.key)
	if recent_has(recent, id) {
		return .Held, false // a resend of one we have, or had
	}
	from_them, waiting := 0, 0
	if queue, ok := s.dms.held[to]; ok {
		waiting = len(queue)
		for h in queue {
			if h.from == from.key {
				from_them += 1
			}
		}
	}
	if waiting >= proto.MAX_HELD_DMS || from_them >= proto.MAX_HELD_DMS_FROM {
		log.debugf(
			"%s: DM refused, %08x has too many waiting",
			user_label(from),
			common.key_id(to),
		)
		return .Full, false
	}
	return .Held, true
}

// dm_hold keeps a DM for its recipient.
@(private = "file")
dm_hold :: proc(
	s: ^Server,
	from: ^User,
	to: [proto.KEY_SIZE]u8,
	id: u64,
	nonce: [proto.DM_NONCE_SIZE]u8,
	sealed: []u8,
) {
	to := to
	_, queue, _, _ := map_entry(&s.dms.held, to)
	append(
		queue,
		Held_DM {
			from = from.key,
			id = id,
			received = proto.Unix_Time(time.time_to_unix(time.now())),
			arrived = time.tick_now(),
			nonce = nonce,
			sealed = clone_bytes(sealed),
		},
	)
	_, recent, _, _ := map_entry(&s.dms.recent, from.key)
	recent_add(recent, id)
	s.dms.dirty = true
	last_seen_sent(s, from.key, to)
	log.debugf(
		"%s: DM for %08x held (%d waiting)",
		user_label(from),
		common.key_id(to),
		len(queue),
	)
}

@(private = "file")
send_dm_sent :: proc(s: ^Server, c: ^Client, id: u64, result: proto.DM_Result) {
	buf: [proto.DM_SENT_SIZE]u8
	send_message(s, c, proto.encode_dm_sent(&buf, id, result))
}

/*
Image DMs (see src/common/proto/dm.odin): the sealed picture comes in while the
recipient is online, and is kept in memory, never on disk, until they've
fetched it or proto.DM_IMAGE_KEEP has passed. The DM that describes it is
held like any other.
*/

// All the images waiting to be fetched may take up this much.
DM_IMAGE_BYTES :: 32 * 1024 * 1024

// Held_Image is an image DM's picture, waiting for its recipient.
Held_Image :: struct {
	from, to: [proto.KEY_SIZE]u8,
	data:     []u8, // sealed; owned
	expires:  time.Tick,
}

// DM_Upload is an image DM on its way in: the upload itself (its nonce
// being the DM's id), and the DM to hold once it's all here.
DM_Upload :: struct {
	using up:   Upload,
	to:         [proto.KEY_SIZE]u8,
	body_nonce: [proto.DM_NONCE_SIZE]u8,
	body:       [proto.MAX_DM_SEALED]u8,
	body_len:   int,
}

handle_dm_image_send :: proc(s: ^Server, c: ^Client, pt: []u8) {
	u := c.user
	id, to, nonce, size, sealed := proto.decode_dm_image_send(pt)
	up := &u.dm_upload
	if up.active && up.nonce == id {
		send_blob_need(s, c, &up.up, force = true)
		return
	}
	result, fresh := dm_check(s, u, to, id)
	if !fresh {
		send_dm_sent(s, c, id, result)
		return
	}
	recipient := s.users[to] or_else nil
	if recipient == nil || sending_session(s, recipient) == nil {
		send_dm_sent(s, c, id, .Offline)
		return
	}
	if size <= proto.TAG_SIZE || size > proto.MAX_DM_IMAGE_SEALED {
		return
	}
	if dm_image_bytes(s) + size > DM_IMAGE_BYTES {
		log.warnf("%s: image DM refused, the server is holding too many images", user_label(u))
		send_dm_sent(s, c, id, .Full)
		return
	}

	if up.active {
		log.debugf("%s started another image DM", user_label(u))
		proto.blob_receiver_destroy(&up.recv)
	}
	up^ = {}
	if !proto.blob_receiver_init(&up.recv, size) {
		return
	}
	up.active = true
	up.nonce = id
	up.last_data = time.tick_now()
	up.to = to
	up.body_nonce = nonce
	up.body_len = copy(up.body[:], sealed)
	log.debugf("%s is sending %08x an image DM, %d bytes", user_label(u), common.key_id(to), size)
	send_blob_need(s, c, &up.up, force = true)
}

// dm_image_chunk takes a chunk of an image DM's upload (handle_blob_chunk
// passes on those that aren't a chat image's).
dm_image_chunk :: proc(s: ^Server, c: ^Client, handle: u64, index: int, data: []u8) {
	u := c.user
	up := &u.dm_upload
	if !up.active || up.nonce != handle {
		return
	}
	proto.blob_receive(&up.recv, index, data)
	up.last_data = time.tick_now()
	if !proto.blob_receiver_complete(&up.recv) {
		return
	}

	// Checked again: the recipient may be full or gone by now.
	result, fresh := dm_check(s, u, up.to, up.nonce)
	if fresh {
		img := new(Held_Image)
		img^ = {
			from    = u.key,
			to      = up.to,
			data    = up.recv.data,
			expires = time.tick_add(time.tick_now(), proto.DM_IMAGE_KEEP),
		}
		up.recv.data = nil // the image has it now
		s.dms.images[up.nonce] = img
		dm_hold(s, u, up.to, up.nonce, up.body_nonce, up.body[:up.body_len])
		log.debugf("%s: image DM %x uploaded (%d bytes)", user_label(u), up.nonce, len(img.data))
	}
	send_dm_sent(s, c, up.nonce, result)
	proto.blob_receiver_destroy(&up.recv)
	up^ = {}
}

// handle_dm_image_get starts sending an image DM's picture to its
// recipient, if it's still here.
handle_dm_image_get :: proc(s: ^Server, c: ^Client, pt: []u8) {
	u := c.user
	id, from := proto.decode_dm_key_message(pt)
	img := s.dms.images[id] or_else nil
	if img == nil || img.to != u.key || img.from != from {
		buf: [proto.DM_IMAGE_REF_SIZE]u8
		send_message(s, c, proto.encode_dm_key_message(&buf, .DM_Image_Gone, id, from))
		return
	}
	down := &u.dm_download
	if down.active && down.handle == id {
		return // already on its way
	}
	proto.blob_sender_destroy(&down.send)
	down^ = {
		active = true,
		handle = id,
		send = {data = img.data},
		last = time.tick_now(),
	}
	log.debugf("sending image DM %x to %s", id, user_label(u))
}

// dm_image_need is a recipient's Blob_Need for an image DM's picture
// (handle_blob_need passes on those that aren't for a chat image). Once
// they have all of it, the server lets it go.
dm_image_need :: proc(
	s: ^Server,
	u: ^User,
	handle: u64,
	complete: bool,
	count: int,
	indices: []u8,
) {
	down := &u.dm_download
	if !down.active || down.handle != handle {
		return
	}
	if complete {
		proto.blob_sender_destroy(&down.send)
		down^ = {}
		forget_dm_image(s, handle)
		return
	}
	for i in 0 ..< count {
		proto.blob_sender_needs(&down.send, proto.blob_need_index(indices, i))
	}
}

@(private = "file")
forget_dm_image :: proc(s: ^Server, id: u64) {
	img := s.dms.images[id] or_else nil
	if img == nil {
		return
	}
	delete_key(&s.dms.images, id)
	// Anyone still sending it has nothing left to send.
	for _, u in s.users {
		if u.dm_download.active && u.dm_download.handle == id {
			proto.blob_sender_destroy(&u.dm_download.send)
			u.dm_download = {}
		}
	}
	delete(img.data)
	free(img)
}

@(private = "file")
dm_image_bytes :: proc(s: ^Server) -> (n: int) {
	for _, img in s.dms.images {
		n += len(img.data)
	}
	// Uploads under way will need their room too.
	for _, u in s.users {
		if u.dm_upload.active {
			n += u.dm_upload.recv.size
		}
	}
	return
}

// dm_images_sync keeps image DMs moving, and lets go of those kept too long.
@(private = "file")
dm_images_sync :: proc(s: ^Server, now: time.Tick) {
	for _, u in s.users {
		c := sending_session(s, u)
		if c == nil {
			continue
		}
		if up := &u.dm_upload; up.active {
			if time.tick_since(up.last_data) > UPLOAD_TIMEOUT {
				log.debugf("%s stopped sending an image DM", user_label(u))
				proto.blob_receiver_destroy(&up.recv)
				up^ = {}
			} else {
				send_blob_need(s, c, &up.up)
			}
		}
		send_chunks(s, c, &u.dm_download, now)
	}
	expired := make([dynamic]u64, context.temp_allocator)
	for id, img in s.dms.images {
		if time.tick_diff(img.expires, now) > 0 {
			append(&expired, id)
		}
	}
	for id in expired {
		log.debugf("image DM %x wasn't fetched in time", id)
		forget_dm_image(s, id)
	}
}

// dm_drop_transfers ends a leaving user's image DM transfers. The
// pictures themselves stay until they're fetched or expire.
dm_drop_transfers :: proc(u: ^User) {
	if u.dm_upload.active {
		proto.blob_receiver_destroy(&u.dm_upload.recv)
	}
	u.dm_upload = {}
	proto.blob_sender_destroy(&u.dm_download.send)
	u.dm_download = {}
}

// handle_dm_ack forgets a DM its recipient has, and tells the sender.
handle_dm_ack :: proc(s: ^Server, u: ^User, pt: []u8) {
	id, from := proto.decode_dm_key_message(pt)
	queue, ok := &s.dms.held[u.key]
	if !ok {
		return
	}
	for h, i in queue {
		if h.id != id || h.from != from {
			continue
		}
		delete(h.sealed)
		ordered_remove(queue, i)
		s.dms.dirty = true
		if sender := s.users[from] or_else nil; sender != nil {
			if sc := sending_session(s, sender); sc != nil {
				buf: [proto.DM_DELIVERED_SIZE]u8
				send_message(s, sc, proto.encode_dm_key_message(&buf, .DM_Delivered, id, u.key))
			}
		}
		return
	}
}

// handle_dm_typing passes a typing notice on, if the recipient's here.
handle_dm_typing :: proc(s: ^Server, u: ^User, pt: []u8) {
	now := time.tick_now()
	if u.last_dm_typing != {} && time.tick_diff(u.last_dm_typing, now) < DM_TYPING_INTERVAL {
		return
	}
	to := proto.decode_dm_typing(pt)
	target := s.users[to] or_else nil
	if target == nil || target == u {
		return
	}
	if c := sending_session(s, target); c != nil {
		u.last_dm_typing = now
		buf: [proto.DM_TYPING_SIZE]u8
		send_message(s, c, proto.encode_dm_typing(&buf, u.key))
	}
}

// dm_sync hands held DMs to recipients who are online, resending until
// they're acknowledged, and saves what's held when it has changed.
dm_sync :: proc(s: ^Server) {
	now := time.tick_now()
	dm_images_sync(s, now)
	for key, &queue in s.dms.held {
		if len(queue) == 0 {
			continue
		}
		u := s.users[key] or_else nil
		if u == nil {
			continue
		}
		c := sending_session(s, u)
		if c == nil {
			continue
		}
		for &h in queue[:min(len(queue), DM_WINDOW)] {
			if h.last_sent != {} && time.tick_diff(h.last_sent, now) < proto.CONTROL_RESEND {
				continue
			}
			h.last_sent = now
			flags: proto.DM_Flags
			if h.arrived == {} || time.tick_diff(h.arrived, u.joined) > 0 {
				flags += {.Waited}
			}
			buf: [proto.MAX_DM_SIZE_ON_WIRE]u8
			send_message(
				s,
				c,
				proto.encode_dm(buf[:], h.id, h.from, h.received, flags, h.nonce, h.sealed),
			)
		}
	}
	if s.dms.dirty {
		s.dms.dirty = false
		dm_save(&s.dms)
	}
}

// What the file holds: one entry per DM, keys and bytes in hex, the id
// as a string too, as JSON numbers don't reliably carry 64 bits.
@(private = "file")
Saved_DM :: struct {
	to:     string,
	from:   string,
	id:     string,
	time:   u64,
	nonce:  string,
	sealed: string,
}

@(private = "file")
dm_save :: proc(d: ^DM_Store) {
	if d.path == "" {
		return
	}
	entries := make([dynamic]Saved_DM, context.temp_allocator)
	for to, queue in d.held {
		to := to
		for &h in queue {
			append(
				&entries,
				Saved_DM {
					to = string(hex.encode(to[:], context.temp_allocator)),
					from = string(hex.encode(h.from[:], context.temp_allocator)),
					id = hex_u64(h.id),
					time = u64(h.received),
					nonce = string(hex.encode(h.nonce[:], context.temp_allocator)),
					sealed = string(hex.encode(h.sealed, context.temp_allocator)),
				},
			)
		}
	}
	data, err := json.marshal(entries[:], {pretty = true}, context.temp_allocator)
	if err != nil {
		log.errorf("could not encode the held DMs: %v", err)
		return
	}
	// Written aside and moved over, so a crash mid-write can't leave
	// half a file.
	tmp := concat(d.path, ".tmp")
	if werr := os.write_entire_file(tmp, data, {.Read_User, .Write_User}); werr != nil {
		log.errorf("could not save the held DMs to %s: %v", tmp, werr)
		return
	}
	if rerr := os.rename(tmp, d.path); rerr != nil {
		log.errorf("could not save the held DMs to %s: %v", d.path, rerr)
	}
}

// dm_load reads the held DMs saved at `path`, if there are any.
dm_load :: proc(d: ^DM_Store, path: string) {
	d.path = path
	if path == "" || !os.exists(path) {
		return
	}
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		log.errorf("could not read the held DMs from %s: %v", path, err)
		return
	}
	entries: []Saved_DM
	if jerr := json.unmarshal(data, &entries, allocator = context.temp_allocator); jerr != nil {
		log.errorf("could not read the held DMs from %s: %v", path, jerr)
		return
	}
	count := 0
	for e in entries {
		to, to_ok := decode_key(e.to)
		h: Held_DM
		from_ok: bool
		h.from, from_ok = decode_key(e.from)
		id, id_ok := strconv.parse_u64_of_base(e.id, 16)
		nonce, nonce_ok := hex.decode(transmute([]u8)e.nonce, context.temp_allocator)
		sealed, sealed_ok := hex.decode(transmute([]u8)e.sealed, context.temp_allocator)
		if !to_ok ||
		   !from_ok ||
		   !id_ok ||
		   !nonce_ok ||
		   !sealed_ok ||
		   len(nonce) != proto.DM_NONCE_SIZE ||
		   len(sealed) < proto.TAG_SIZE ||
		   len(sealed) > proto.MAX_DM_SEALED {
			log.warnf("%s: skipping a malformed entry", path)
			continue
		}
		h.id, h.received = id, proto.Unix_Time(e.time)
		copy(h.nonce[:], nonce)
		h.sealed = clone_bytes(sealed)
		_, queue, _, _ := map_entry(&d.held, to)
		append(queue, h)
		_, recent, _, _ := map_entry(&d.recent, h.from)
		recent_add(recent, h.id)
		count += 1
	}
	if count > 0 {
		log.infof("%d direct messages are waiting for their recipients", count)
	}
}

dm_destroy :: proc(d: ^DM_Store) {
	for _, queue in d.held {
		for h in queue {
			delete(h.sealed)
		}
		delete(queue)
	}
	delete(d.held)
	delete(d.recent)
	for _, img in d.images {
		delete(img.data)
		free(img)
	}
	delete(d.images)
	delete(d.path)
}

decode_key :: proc(s: string) -> (key: [proto.KEY_SIZE]u8, ok: bool) {
	raw := hex.decode(transmute([]u8)s, context.temp_allocator) or_return
	if len(raw) != proto.KEY_SIZE {
		return
	}
	copy(key[:], raw)
	return key, true
}

@(private = "file")
hex_u64 :: proc(v: u64) -> string {
	return fmt.tprintf("%x", v)
}

@(private = "file")
clone_bytes :: proc(b: []u8) -> []u8 {
	out := make([]u8, len(b))
	copy(out, b)
	return out
}

concat :: proc(a, b: string) -> string {
	out := make([]u8, len(a) + len(b), context.temp_allocator)
	copy(out, a)
	copy(out[len(a):], b)
	return string(out)
}

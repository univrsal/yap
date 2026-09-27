package server

import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:time"

import "../proto"

/*
Direct messages (src/proto/dm.odin). The server can't read them: it
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
	from := c.user.key
	id, to, nonce, sealed := proto.decode_dm_send(pt)
	if to == from {
		return
	}
	result := proto.DM_Result.Held
	defer {
		buf: [proto.DM_SENT_SIZE]u8
		send_message(s, c, proto.encode_dm_sent(&buf, id, result))
	}

	// Taken as entries: a plain &map[key] is nil for a key not there yet.
	_, recent, _, _ := map_entry(&s.dms.recent, from)
	if recent_has(recent, id) {
		return // a resend of one we have, or had
	}
	_, queue, _, _ := map_entry(&s.dms.held, to)
	from_them := 0
	for &h in queue {
		if h.from == from {
			from_them += 1
		}
	}
	if len(queue) >= proto.MAX_HELD_DMS || from_them >= proto.MAX_HELD_DMS_FROM {
		result = .Full
		log.debugf("%s: DM refused, %x... has too many waiting", user_label(c.user), to[:4])
		return
	}
	append(
		queue,
		Held_DM {
			from = from,
			id = id,
			received = proto.Unix_Time(time.time_to_unix(time.now())),
			nonce = nonce,
			sealed = clone_bytes(sealed),
		},
	)
	recent_add(recent, id)
	s.dms.dirty = true
	log.debugf("%s: DM for %x... held (%d waiting)", user_label(c.user), to[:4], len(queue))
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
			buf: [proto.MAX_DM_SIZE_ON_WIRE]u8
			send_message(s, c, proto.encode_dm(buf[:], h.id, h.from, h.received, h.nonce, h.sealed))
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
	delete(d.path)
}

@(private = "file")
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

@(private = "file")
concat :: proc(a, b: string) -> string {
	out := make([]u8, len(a) + len(b), context.temp_allocator)
	copy(out, a)
	copy(out[len(a):], b)
	return string(out)
}

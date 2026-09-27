package server

import "core:encoding/hex"
import "core:encoding/json"
import "core:log"
import "core:os"
import "core:time"

import "../proto"

/*
When each user was last here (src/proto/last_seen.odin): noted as they
leave, and kept in a file next to the config, rewritten whenever someone
leaves, so the buddy screen can say how long ago it was even after a
restart.

It's only told to people who have sent each other DMs, so the server
also keeps who has sent whom one (last_seen_sent), in the same file.
*/

Last_Seen_Store :: struct {
	path:  string,
	times: map[[proto.KEY_SIZE]u8]proto.Unix_Time,
	// Who has sent whom a DM: the sender's key, then the recipient's.
	sent:  map[Key_Pair]struct{},
}

Key_Pair :: [2 * proto.KEY_SIZE]u8

@(private = "file")
key_pair :: proc(from, to: [proto.KEY_SIZE]u8) -> (pair: Key_Pair) {
	from, to := from, to
	copy(pair[:], from[:])
	copy(pair[proto.KEY_SIZE:], to[:])
	return
}

// last_seen_sent notes that `from` has sent `to` a DM (dm_hold), saving
// the first time.
last_seen_sent :: proc(s: ^Server, from, to: [proto.KEY_SIZE]u8) {
	pair := key_pair(from, to)
	if pair in s.last_seen.sent {
		return
	}
	s.last_seen.sent[pair] = {}
	last_seen_save(&s.last_seen)
}

// last_seen_shared is whether `a` and `b` have each sent the other a DM.
@(private = "file")
last_seen_shared :: proc(l: ^Last_Seen_Store, a, b: [proto.KEY_SIZE]u8) -> bool {
	return key_pair(a, b) in l.sent && key_pair(b, a) in l.sent
}

unix_now :: proc() -> proto.Unix_Time {
	return proto.Unix_Time(time.time_to_unix(time.now()))
}

// last_seen_left notes that `u` has just left, and saves.
last_seen_left :: proc(s: ^Server, u: ^User) {
	s.last_seen.times[u.key] = unix_now()
	last_seen_save(&s.last_seen)
}

handle_last_seen_get :: proc(s: ^Server, c: ^Client, pt: []u8) {
	n := proto.last_seen_count(pt)
	keys: [proto.MAX_LAST_SEEN][proto.KEY_SIZE]u8
	times: [proto.MAX_LAST_SEEN]proto.Unix_Time
	now := unix_now()
	for i in 0 ..< n {
		keys[i] = proto.last_seen_get_key(pt, i)
		switch {
		case keys[i] in s.users:
			times[i] = now // here, which anyone can see anyway
		case !last_seen_shared(&s.last_seen, c.user.key, keys[i]):
			times[i] = proto.LAST_SEEN_HIDDEN
		case:
			times[i] = s.last_seen.times[keys[i]] or_else 0
		}
	}
	out: [proto.MAX_PAYLOAD_SIZE]u8
	send_message(s, c, proto.encode_last_seen(out[:], keys[:n], times[:n]))
}

// The file: each key, in hex, with when it was last here, and who has
// sent whom a DM, as the two keys in hex with a colon between.
@(private = "file")
Saved_Last_Seen :: struct {
	seen: map[string]u64,
	sent: []string,
}

@(private = "file")
last_seen_save :: proc(l: ^Last_Seen_Store) {
	if l.path == "" {
		return
	}
	saved: Saved_Last_Seen
	saved.seen = make(map[string]u64, len(l.times), context.temp_allocator)
	for key, at in l.times {
		key := key
		saved.seen[string(hex.encode(key[:], context.temp_allocator))] = u64(at)
	}
	sent := make([dynamic]string, 0, len(l.sent), context.temp_allocator)
	for pair in l.sent {
		pair := pair
		from := string(hex.encode(pair[:proto.KEY_SIZE], context.temp_allocator))
		to := string(hex.encode(pair[proto.KEY_SIZE:], context.temp_allocator))
		append(&sent, concat(concat(from, ":"), to))
	}
	saved.sent = sent[:]
	data, err := json.marshal(saved, {pretty = true}, context.temp_allocator)
	if err != nil {
		log.errorf("could not encode when users were last seen: %v", err)
		return
	}
	// Written aside and moved over, like the held DMs (dm.odin).
	tmp := concat(l.path, ".tmp")
	if werr := os.write_entire_file(tmp, data, {.Read_User, .Write_User}); werr != nil {
		log.errorf("could not save %s: %v", tmp, werr)
		return
	}
	if rerr := os.rename(tmp, l.path); rerr != nil {
		log.errorf("could not save %s: %v", l.path, rerr)
	}
}

last_seen_load :: proc(l: ^Last_Seen_Store, path: string) {
	l.path = path
	if path == "" || !os.exists(path) {
		return
	}
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		log.errorf("could not read %s: %v", path, err)
		return
	}
	saved: Saved_Last_Seen
	if jerr := json.unmarshal(data, &saved, allocator = context.temp_allocator); jerr != nil {
		log.errorf("could not read %s: %v", path, jerr)
		return
	}
	for k, at in saved.seen {
		if key, ok := decode_key(k); ok {
			l.times[key] = proto.Unix_Time(at)
		}
	}
	for entry in saved.sent {
		if len(entry) != 4 * proto.KEY_SIZE + 1 || entry[2 * proto.KEY_SIZE] != ':' {
			continue
		}
		from, from_ok := decode_key(entry[:2 * proto.KEY_SIZE])
		to, to_ok := decode_key(entry[2 * proto.KEY_SIZE + 1:])
		if from_ok && to_ok {
			l.sent[key_pair(from, to)] = {}
		}
	}
}

last_seen_destroy :: proc(l: ^Last_Seen_Store) {
	delete(l.times)
	delete(l.sent)
	delete(l.path)
}

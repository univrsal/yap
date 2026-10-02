package server

import "core:log"
import "core:time"

import "common:proto"

// Pokes from one user are passed on at most this often.
POKE_INTERVAL :: time.Second

// handle_poke passes a poke on to the user it's for, as from the user
// whose session it came on - whatever the packet claims (see poke.odin).
// At most one per POKE_INTERVAL from each user, so they can't be used to
// flood someone's desktop with notifications.
handle_poke :: proc(s: ^Server, from: ^Conn, pt: []byte) {
	_, target, raw := proto.decode_poke(pt)
	now := time.tick_now()
	if from.last_poke != {} && time.tick_diff(from.last_poke, now) < POKE_INTERVAL {
		log.debugf("%s is poking too often", conn_label(from))
		return
	}
	for _, u in s.conns {
		if u.num != target || u == from {
			continue
		}
		c := sending_session(s, u)
		if c == nil {
			return // not online
		}
		from.last_poke = now
		text_buf: [proto.MAX_POKE_SIZE]u8
		text := proto.sanitize_text(raw, text_buf[:])
		buf: [proto.POKE_MAX_SIZE]u8
		send_message(s, c, proto.encode_poke(&buf, from.num, target, text))
		log.infof("%s poked %s", conn_label(from), conn_label(u))
		return
	}
}

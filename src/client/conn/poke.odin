package conn

import log "common:wlog"

import "common:proto"
import "client:audio"

// poke_send pokes another user, with a message or without (see
// src/common/proto/poke.odin). `to` 0 means the user called `name`.
poke_send :: proc(c: ^Voice_Client, to: proto.User_Num, name: string, raw: string) {
	ch := &c.channels
	if !ch.have_state || !c.has_current {
		log.warn("poke: not connected")
		return
	}
	target := to
	if target == 0 {
		for &u in ch.state.users {
			if named(c, &u, name) {
				target = u.num
			}
		}
	}
	if target == 0 || proto.find_user(&ch.state, target) == nil {
		log.warnf("poke: there's nobody called %q", name)
		return
	}
	if target == ch.state.your_user {
		return
	}
	text_buf: [proto.MAX_POKE_SIZE]u8
	text := proto.sanitize_text(raw, text_buf[:])
	log.infof("[poke] poking %s", display_name(c, target))
	buf: [proto.POKE_MAX_SIZE]u8
	send_data(c, proto.encode_poke(&buf, ch.state.your_user, target, text))
}

// handle_poke takes a poke from the server and hands it to the UI, which
// shows it as a notification.
handle_poke :: proc(c: ^Voice_Client, pt: []byte) {
	sender, _, raw := proto.decode_poke(pt)
	if !c.channels.have_state {
		return
	}
	name := display_name(c, sender)
	text_buf: [proto.MAX_POKE_SIZE]u8
	text := proto.sanitize_text(raw, text_buf[:])
	if text == "" {
		log.infof("[poke] %s poked you", name)
	} else {
		log.infof("[poke] %s poked you: %s", name, text)
	}
	if !quiet(c) {
		audio.voice_notification_play(&c.voice, .Message)
	}
	publish_poke(c, name, text)
}

package server

import "core:log"
import "core:net"
import "core:time"

import "../proto"

/*
Screen sharing (see src/proto/video.odin): the server passes a sharer's
video fragments on to whoever in their channel holds a Watch lease on
them, and passes the viewers' keyframe requests back. It never looks
inside the video.
*/

// The most video one sharer may push through, in bytes a second, and
// how far a burst (a keyframe) may run ahead of that. Anything over is
// dropped, which the viewers see as a lost frame.
VIDEO_MAX_RATE :: 4_000_000 / 8
VIDEO_MAX_BURST :: proto.MAX_VIDEO_FRAME_SIZE + 64 * 1024

// What the server keeps about a user's screen sharing.
Video_State :: struct {
	// Who they're watching, until when.
	watching:      proto.User_Num,
	watch_until:   time.Tick,
	// As a sharer: the budget left for passing their video on, and when
	// it was last topped up.
	budget:        int,
	budget_at:     time.Tick,
	last_key_sent: time.Tick, // Keyframe requests passed to them
}

handle_watch :: proc(s: ^Server, u: ^User, pt: []byte) {
	sharer, need_key := proto.decode_watch(pt)
	v := &u.video
	if sharer != v.watching {
		log.debugf("%s watches %d", user_label(u), sharer)
	}
	v.watching = sharer
	if sharer == 0 {
		return
	}
	v.watch_until = time.tick_add(time.tick_now(), proto.WATCH_LEASE)
	if need_key {
		request_keyframe(s, u, sharer)
	}
}

// request_keyframe asks a sharer for a keyframe on a viewer's behalf,
// at most once every KEYFRAME_REQUEST_MIN whoever is asking.
@(private = "file")
request_keyframe :: proc(s: ^Server, viewer: ^User, sharer: proto.User_Num) {
	for _, u in s.users {
		if u.num != sharer {
			continue
		}
		if u.channel != viewer.channel || .Sharing not_in u.flags {
			return
		}
		now := time.tick_now()
		v := &u.video
		if v.last_key_sent != {} && time.tick_diff(v.last_key_sent, now) < proto.KEYFRAME_REQUEST_MIN {
			return
		}
		c := sending_session(s, u)
		if c == nil {
			return
		}
		v.last_key_sent = now
		buf: [proto.KEYFRAME_SIZE]u8
		send_message(s, c, proto.encode_keyframe(&buf))
		return
	}
}

/*
relay_video passes a fragment on to everyone in the sharer's channel
who's watching them, re-encrypted for each. Video from somebody who
hasn't said they're sharing, or over their budget, goes nowhere.
*/
relay_video :: proc(s: ^Server, from: ^Client, pt: []byte) {
	u := from.user
	if _, ok := proto.decode_video_up(pt); !ok || .Sharing not_in u.flags {
		return
	}
	if !spend_budget(&u.video, len(pt)) {
		log.debugf("%s is sharing faster than the server passes on", user_label(u))
		return
	}

	out_buf: [proto.MAX_PAYLOAD_SIZE]u8
	msg := proto.video_up_to_down(&out_buf, u.num, pt)
	now := time.tick_now()
	pkt_buf: [proto.MAX_PACKET_SIZE]u8
	for _, c in s.sessions {
		if !c.keyed || c.superseded || c.user == u || c.user.channel != u.channel {
			continue
		}
		v := &c.user.video
		if v.watching != u.num || time.tick_diff(now, v.watch_until) <= 0 {
			continue
		}
		if pkt, ok := proto.seal(&c.session, msg, pkt_buf[:]); ok {
			net.send_udp(s.sock, pkt, c.endpoint)
		}
	}
}

// spend_budget takes `n` bytes from a sharer's budget, topping it up
// for the time gone by first. It returns false, taking nothing, if
// there isn't enough.
@(private = "file")
spend_budget :: proc(v: ^Video_State, n: int) -> bool {
	now := time.tick_now()
	if v.budget_at == {} {
		v.budget = VIDEO_MAX_BURST
	} else {
		elapsed := time.tick_diff(v.budget_at, now)
		v.budget = min(VIDEO_MAX_BURST, v.budget + int(time.duration_seconds(elapsed) * VIDEO_MAX_RATE))
	}
	v.budget_at = now
	if v.budget < n {
		return false
	}
	v.budget -= n
	return true
}

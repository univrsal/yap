package client

import log "../common/wlog"
import "core:time"

import "../proto"

/*
Screen sharing (see src/proto/video.odin), the part that's the same
wherever the client runs. The capturing, encoding and decoding are the
browser's (video_web.odin); a desktop build has none of it, so it never
shares or watches, but still shows who is sharing.

Sharing: encoded frames are numbered and queued, and go out a fragment
at a time, paced to VIDEO_SEND_RATE and only while the socket isn't
already backed up. Voice doesn't wait in this queue, so a keyframe
going out doesn't hold it up. When the queue has fallen too far behind,
the frames not yet started are thrown away and the encoder is asked for
a keyframe, since what follows a lost frame can't be decoded anyway;
until it comes, nothing else is queued.

Watching: a Watch lease on one sharer, repeated every WATCH_RESEND,
and sooner - asking for a keyframe - whenever the frames coming in
can't be decoded.
*/

// How fast video goes out, in bytes a second, and how much may go at
// once. A little over what the encoder is asked for, so the queue
// drains after a keyframe.
VIDEO_SEND_RATE :: 3_000_000 / 8
VIDEO_SEND_BURST :: 16 * 1024
// More than this still waiting to go out means we can't keep up.
VIDEO_QUEUE_MAX :: VIDEO_SEND_RATE
// Video only goes out while less than this is waiting on the socket, so
// that voice, which goes straight out, never queues behind much of it.
VIDEO_BACKLOG_MAX :: 16 * 1024

Video_Client :: struct {
	// Sharing.
	sharing:        bool, // the capture is running
	next_frame:     u32,
	queue:          [dynamic]Outgoing_Frame,
	queued_bytes:   int,
	sent:           int, // fragments of queue[0] already sent
	awaiting_key:   bool, // frames were dropped; only a keyframe may follow
	want_key:       bool, // the encoder should make the next frame a keyframe
	budget:         int, // bytes that may go out now (VIDEO_SEND_RATE)
	budget_at:      time.Tick,

	// Watching.
	watching:       proto.User_Num, // 0 for nobody
	last_watch:     time.Tick,
	last_key_asked: time.Tick,
	assembler:      ^proto.Video_Assembler, // while watching
}

Outgoing_Frame :: struct {
	num:  u32,
	ts:   u32,
	key:  bool,
	data: []u8, // owned
}

// Watch somebody's screen, or nobody's (0).
Watch_Command :: struct {
	user: proto.User_Num,
}

video_destroy :: proc(c: ^Voice_Client) {
	v := &c.video
	video_clear_queue(v)
	delete(v.queue)
	free(v.assembler)
	v^ = {}
}

// video_step gives screen sharing its turn in the network loop.
video_step :: proc(c: ^Voice_Client) {
	v := &c.video

	if live := video_capture_live(); live != v.sharing {
		v.sharing = live
		set_sound(c, .Sharing, live)
		video_clear_queue(v)
		v.awaiting_key = false
		log.infof("screen sharing %s", "started" if live else "stopped")
	}
	if v.sharing {
		for {
			data, ts, key, ok := video_capture_pull()
			if !ok {
				break
			}
			video_queue_frame(v, data, ts, key)
		}
	}
	if v.want_key {
		video_capture_request_key()
		v.want_key = false
	}

	if c.has_current {
		video_send(c)
		drive_watch(c)
	}
}

/*
video_queue_frame takes over an encoded frame and queues it, or drops
it. Frames get their numbers here, so any dropped after this point show
up at the far end as a gap and a request for a keyframe.
*/
video_queue_frame :: proc(v: ^Video_Client, data: []u8, ts: u32, key: bool) {
	if len(data) == 0 || len(data) > proto.MAX_VIDEO_FRAME_SIZE {
		log.warnf("dropping a %d-byte video frame", len(data))
		delete(data)
		v.awaiting_key, v.want_key = true, true
		return
	}
	if v.queued_bytes > VIDEO_QUEUE_MAX {
		// Behind: keep only what has started going out.
		start := 1 if v.sent > 0 else 0
		for f in v.queue[start:] {
			v.queued_bytes -= len(f.data)
			delete(f.data)
		}
		resize(&v.queue, start)
		v.awaiting_key, v.want_key = true, true
		log.debug("video can't keep up; dropped the queue")
	}
	if v.awaiting_key && !key {
		delete(data)
		return
	}
	v.awaiting_key = false
	append(&v.queue, Outgoing_Frame{num = v.next_frame, ts = ts, key = key, data = data})
	v.next_frame += 1
	v.queued_bytes += len(data)
}

// video_next_fragment returns the next fragment to go out, as a Video
// message written to `out`, and moves past it.
video_next_fragment :: proc(v: ^Video_Client, out: []u8) -> (msg: []u8, ok: bool) {
	if len(v.queue) == 0 {
		return
	}
	f := &v.queue[0]
	count := proto.video_fragment_count(len(f.data))
	start, end := proto.video_fragment_range(len(f.data), v.sent)
	msg = proto.encode_video_up(
		out,
		{
			frame = f.num,
			ts = f.ts,
			index = v.sent,
			count = count,
			key = f.key,
			codec = .H264,
			data = f.data[start:end],
		},
	)
	v.sent += 1
	if v.sent == count {
		v.queued_bytes -= len(f.data)
		delete(f.data)
		ordered_remove(&v.queue, 0)
		v.sent = 0
	}
	return msg, true
}

video_clear_queue :: proc(v: ^Video_Client) {
	for f in v.queue {
		delete(f.data)
	}
	clear(&v.queue)
	v.queued_bytes, v.sent = 0, 0
}

// video_send sends what the pace and the socket allow.
@(private = "file")
video_send :: proc(c: ^Voice_Client) {
	v := &c.video
	if len(v.queue) == 0 {
		return
	}
	now := time.tick_now()
	if v.budget_at == {} {
		v.budget = VIDEO_SEND_BURST
	} else {
		elapsed := time.duration_seconds(time.tick_diff(v.budget_at, now))
		v.budget = min(VIDEO_SEND_BURST, v.budget + int(elapsed * VIDEO_SEND_RATE))
	}
	v.budget_at = now

	buf: [proto.MAX_PAYLOAD_SIZE]u8
	for v.budget > 0 && transport_backlog(&c.transport) < VIDEO_BACKLOG_MAX {
		msg, ok := video_next_fragment(v, buf[:])
		if !ok {
			break
		}
		send_data(c, msg)
		v.budget -= len(msg)
	}
}

// video_keyframe_requested: a viewer asked the server for a keyframe.
video_keyframe_requested :: proc(c: ^Voice_Client) {
	if c.video.sharing {
		c.video.want_key = true
	}
}

// video_watch starts watching `user`, or stops watching with 0.
video_watch :: proc(c: ^Voice_Client, user: proto.User_Num) {
	v := &c.video
	if user == v.watching {
		return
	}
	if user == 0 {
		// The lease would run out anyway; this just ends it sooner.
		if c.has_current {
			buf: [proto.WATCH_SIZE]u8
			send_data(c, proto.encode_watch(&buf, 0, false))
		}
	} else {
		if v.assembler == nil {
			v.assembler = new(proto.Video_Assembler)
		}
		proto.video_assembler_reset(v.assembler)
	}
	log.infof("watching %s", display_name(c.channels.state.users, user) if user != 0 else "nobody")
	video_show_end()
	v.watching = user
	v.last_watch, v.last_key_asked = {}, {}
	publish_watching(c)
}

/*
drive_watch renews the lease on whoever we're watching, and asks for a
keyframe while what arrives can't be decoded. Somebody who stops
sharing or leaves the channel stops being watched.
*/
@(private = "file")
drive_watch :: proc(c: ^Voice_Client) {
	v := &c.video
	if v.watching == 0 || !c.channels.have_state {
		return
	}
	if !can_watch(c, v.watching) {
		video_watch(c, 0)
		return
	}
	if video_show_failed() {
		// Whatever the decoder had is gone, so start again from a keyframe.
		proto.video_assembler_reset(v.assembler)
	}
	need_key := v.assembler.broken
	due := time.tick_since(v.last_watch) >= proto.WATCH_RESEND
	if need_key && time.tick_since(v.last_key_asked) >= proto.KEYFRAME_REQUEST_MIN {
		due = true
		v.last_key_asked = time.tick_now()
	}
	if !due {
		return
	}
	buf: [proto.WATCH_SIZE]u8
	send_data(c, proto.encode_watch(&buf, v.watching, need_key))
	v.last_watch = time.tick_now()
}

// can_watch says whether `user` is sharing, in our channel, and not us.
can_watch :: proc(c: ^Voice_Client, user: proto.User_Num) -> bool {
	ch := &c.channels
	if !ch.have_state || user == ch.state.your_user {
		return false
	}
	u := proto.find_user(&ch.state, user)
	if u == nil || .Sharing not_in u.flags {
		return false
	}
	for m in ch.state.channels[ch.state.your_channel].members {
		if m == user {
			return true
		}
	}
	return false
}

handle_video :: proc(c: ^Voice_Client, pt: []u8) {
	v := &c.video
	sharer, f, ok := proto.decode_video_down(pt)
	if !ok || sharer != v.watching || v.watching == 0 {
		return
	}
	if frame, complete := proto.video_assembler_add(v.assembler, f); complete {
		video_show_frame(sharer, frame)
	}
}

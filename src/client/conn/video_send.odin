package conn

import log "common:wlog"
import "core:fmt"
import "core:strings"
import "core:time"

import "client:video"
import "common:proto"

// Sending: the queue of frames, cut in fragments and paced onto the media link.

// How fast video goes out, in bytes per second, and how many bytes may go out
// at once, while the encoder's bitrate isn't known. A share reports its
// encoding bitrate (video.share_kbit) and goes out at half as much again,
// so that a keyframe is spread over several frames instead of one burst whose
// end router queues would drop.
VIDEO_SEND_RATE :: 12_000_000 / 8
VIDEO_SEND_BURST :: 16 * 1024
// More than this much sending still waiting (behind the frame going out) means
// we cannot keep up (video_queue_max).
VIDEO_QUEUE_TIME :: 500 * time.Millisecond
// Video only goes out while less than this is waiting on the socket, so that
// the socket's buffer never holds much more than one burst. (Voice does not
// wait in it: video has the media link to itself.)
VIDEO_BACKLOG_MAX :: 16 * 1024
// How long a camera may go without the server taking our Camera flag before
// the View says that it was refused (a few Sound resends).
CAMERA_REFUSED_AFTER :: 3 * time.Second

// out_step follows one of our streams: whether it is live, whether the server
// takes it, and what its encoder has ready.
out_step :: proc(c: ^Server_Conn, o: ^Video_Out, here: bool) {
	now := time.tick_now()
	if live := video.capture_live(o.stream) && here; live != o.live {
		video_clear_queue(o)
		// The frames keep counting on, so that the server's cache never mixes
		// them up with the last share's.
		stream, queue, next_frame := o.stream, o.queue, o.next_frame
		o^ = {
			stream     = stream,
			live       = live,
			live_at    = now,
			taken      = stream == .Screen,
			queue      = queue,
			next_frame = next_frame,
		}
		set_sound(c, proto.stream_flag(o.stream), live)
		log.infof("%s %s", stream_name(o.stream), "started" if live else "stopped")
	}
	if o.stream == .Camera {
		note_camera_taken(c, o, now)
	}
	if !o.live {
		return
	}
	if o.stream == .Camera {
		follow_camera_tier(c, o, now)
		follow_demand(o, now)
	}
	note_encoding(o, video.share_kbit(o.stream), now)
	for {
		data, ts, key, codec, ok := video.capture_pull(o.stream)
		if !ok {
			break
		}
		o.log_encoded += len(data)
		if !o.taken {
			delete(data) // the server would drop it
			continue
		}
		video_queue_frame(o, data, ts, key, codec)
	}
	if o.want_key {
		video.capture_request_key(o.stream)
		o.want_key = false
	}
	video.share_codecs(o.stream, viewer_codecs(c))
}

// video_log_counts is how many fragments of what we watch were asked for again,
// how many frames that saved and how many were lost anyway, since it was last
// asked (for the log).
video_log_counts :: proc(c: ^Server_Conn) -> (d: [3]int) {
	for &in_ in c.video.ins {
		if w := in_.window; w != nil {
			counts := [3]int{w.nacked, w.recovered, w.given_up}
			d += counts - in_.logged
			in_.logged = counts
		}
	}
	return
}

// video_queue_frame takes over an encoded frame and queues it, or drops it.
// Frames get their numbers here, so any frame dropped after this point shows up
// at the far end as a gap and a request for a keyframe.
video_queue_frame :: proc(
	o: ^Video_Out,
	data: []u8,
	ts: u32,
	key: bool,
	codec := proto.Video_Codec.H264,
) {
	if len(data) == 0 || len(data) > proto.MAX_VIDEO_FRAME_SIZE {
		log.warnf("dropping a %d-byte video frame", len(data))
		delete(data)
		o.awaiting_key, o.want_key = true, true
		return
	}
	// The frame going out doesn't count: a keyframe bigger than the limit would
	// otherwise throw out what follows it, and ask for another.
	waiting := o.queued_bytes
	if o.sent > 0 {
		waiting -= len(o.queue[0].data)
	}
	if waiting > video_queue_max(o) {
		// Behind: keep only what has started going out.
		start := 1 if o.sent > 0 else 0
		for f in o.queue[start:] {
			o.queued_bytes -= len(f.data)
			delete(f.data)
		}
		dropped := len(o.queue) - start
		resize(&o.queue, start)
		o.awaiting_key, o.want_key = true, true
		o.log_drops += 1
		log.debugf(
			"video: %s can't keep up; dropped %d queued frames (%d kB waiting)",
			stream_name(o.stream),
			dropped,
			waiting / 1000,
		)
	}
	if o.awaiting_key && !key {
		delete(data)
		return
	}
	o.awaiting_key = false
	append(
		&o.queue,
		Outgoing_Frame{num = o.next_frame, ts = ts, key = key, codec = codec, data = data},
	)
	o.next_frame += 1
	o.queued_bytes += len(data)
	o.log_queue_max = max(o.log_queue_max, o.queued_bytes)
}

// video_next_fragment returns the next fragment to go out, as a Video message
// written to `out`, and moves past it.
video_next_fragment :: proc(o: ^Video_Out, out: []u8) -> (msg: []u8, ok: bool) {
	if len(o.queue) == 0 {
		return
	}
	f := &o.queue[0]
	count := proto.video_fragment_count(len(f.data))
	start, end := proto.video_fragment_range(len(f.data), o.sent)
	msg = proto.encode_video_up(
		out,
		{
			frame = f.num,
			ts = f.ts,
			index = o.sent,
			count = count,
			key = f.key,
			stream = o.stream,
			codec = f.codec,
			data = f.data[start:end],
		},
	)
	o.sent += 1
	if o.sent == count {
		o.queued_bytes -= len(f.data)
		delete(f.data)
		ordered_remove(&o.queue, 0)
		o.sent = 0
	}
	return msg, true
}

// video_send_rate is how fast a stream goes out, in bytes per second: half as
// much again as its encoder makes, where that is known (VIDEO_SEND_RATE).
video_send_rate :: proc(o: ^Video_Out) -> int {
	if o.encoding_kbit > 0 {
		return o.encoding_kbit * 1000 / 8 * 3 / 2
	}
	return VIDEO_SEND_RATE
}

// video_pace_rate is how fast a stream goes out, in bytes per second. On a
// reliable media link (a browser's WebSocket) this is as fast as the server
// takes from one stream: the pacing is there so that routers don't drop the
// end of a burst, which TCP already sees to, and a browser's encoder may go
// well over its bitrate while the picture moves (web/video.js, pickCodec), and
// put out large keyframes of its own, which would otherwise wait in the queue
// and hold up the picture. (Pacing in proportion to what waits leaves a long
// tail: the last of a keyframe goes out slowest.)
video_pace_rate :: proc(c: ^Server_Conn, o: ^Video_Out) -> int {
	rate := video_send_rate(o)
	if !video.MEDIA_RELIABLE {
		return rate
	}
	limit_kbit := int(c.rpc.server.camera_kbit if o.stream == .Camera else c.rpc.server.video_kbit)
	limit := limit_kbit * 1000 / 8 if limit_kbit > 0 else VIDEO_SEND_RATE
	return max(rate, limit)
}

// video_queue_max is how many bytes may wait behind the frame going out:
// VIDEO_QUEUE_TIME's worth at the rate they go out.
video_queue_max :: proc(o: ^Video_Out) -> int {
	return video_send_rate(o) * int(VIDEO_QUEUE_TIME / time.Millisecond) / 1000
}

video_clear_queue :: proc(o: ^Video_Out) {
	for f in o.queue {
		delete(f.data)
	}
	clear(&o.queue)
	o.queued_bytes, o.sent = 0, 0
}

// video_next_out is the stream whose fragment goes out next: the camera's
// while it has any waiting, then the screen's. Nil when nothing waits.
video_next_out :: proc(v: ^Video_Client) -> ^Video_Out {
	for stream in ([?]proto.Video_Stream{.Camera, .Screen}) {
		if len(v.outs[stream].queue) > 0 {
			return &v.outs[stream]
		}
	}
	return nil
}

// video_send sends what the pacing and the socket allow. The pace is the sum of
// the live streams' rates.
video_send :: proc(c: ^Server_Conn) {
	v := &c.video
	if video_next_out(v) == nil {
		return
	}
	now := time.tick_now()
	rate := 0
	for &o in v.outs {
		if o.live {
			pace := video_pace_rate(c, &o)
			o.log_pace_max = max(o.log_pace_max, pace)
			rate += pace
		}
	}
	proto.bucket_refill(&v.budget, now, f64(rate), VIDEO_SEND_BURST)
	if !c.media.has_current {
		return // the queue is falling behind, which asks for a keyframe
	}

	buf: [proto.MAX_PAYLOAD_SIZE]u8
	link := &c.media.link
	for v.budget.tokens > 0 && transport_backlog(&link.transport) < VIDEO_BACKLOG_MAX {
		o := video_next_out(v)
		if o == nil {
			break
		}
		msg, _ := video_next_fragment(o, buf[:])
		link_send(link, msg)
		v.budget.tokens -= f64(len(msg))
		v.bytes_out += len(msg)
		o.stats_out += len(msg)
		o.log_sent += len(msg)
	}
	if video_next_out(v) != nil {
		if v.budget.tokens <= 0 {
			v.held_budget += 1
		} else {
			v.held_backlog += 1
		}
	}
}

// log_video_out logs, once a second while we send anything, how it goes: for
// each stream what its encoder made against what it was asked for, what went
// out, and the most that waited in the queue;
// and how often sending was held back by the socket or by the pacing, and the
// longest video_step went without running (the page's frames, on the web).
log_video_out :: proc(c: ^Server_Conn, now: time.Tick) {
	v := &c.video
	if v.log_at != {} && time.tick_diff(v.log_at, now) < time.Second {
		return
	}
	secs := time.duration_seconds(time.tick_diff(v.log_at, now))
	first := v.log_at == {}
	v.log_at = now
	b := strings.builder_make(context.temp_allocator)
	for &o in v.outs {
		if o.live && !first {
			fmt.sbprintf(
				&b,
				"%s%s: encoded %d kbit/s (at %d), sent %d kbit/s (paced up to %d), queue up to %d kB",
				" | " if strings.builder_len(b) > 0 else "",
				stream_name(o.stream),
				int(f64(o.log_encoded) * 8 / 1000 / secs),
				o.encoding_kbit,
				int(f64(o.log_sent) * 8 / 1000 / secs),
				o.log_pace_max * 8 / 1000,
				o.log_queue_max / 1000,
			)
			if o.log_drops > 0 {
				fmt.sbprintf(&b, ", dropped %dx", o.log_drops)
			}
		}
		o.log_encoded, o.log_sent, o.log_queue_max, o.log_drops, o.log_pace_max = 0, 0, 0, 0, 0
	}
	if strings.builder_len(b) > 0 {
		log.debugf(
			"video out: %s | held %dx by the socket, %dx by pacing; steps up to %.0f ms apart",
			strings.to_string(b),
			v.held_backlog,
			v.held_budget,
			time.duration_milliseconds(v.step_gap_max),
		)
	}
	v.held_backlog, v.held_budget, v.step_gap_max = 0, 0, 0
}

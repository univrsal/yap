package conn

import log "common:wlog"
import "core:sync"
import "core:time"

import "client:settings"
import "common:proto"

/*
Screen sharing (see src/common/proto/video.odin), the part that's the same
wherever the client runs. The capturing, encoding and decoding are the
browser's (video_web.odin), or on the desktop the optional yap_video
library's (video_native.odin), which only watches so far. Without it a
desktop build never shares or watches, but still shows who is sharing.

Sharing: encoded frames are numbered and queued, and go out a fragment
at a time over the media link (media.odin) where there is one, else the
bulk link (bulk.odin), paced to VIDEO_SEND_RATE and only while its
socket isn't already backed up. Voice doesn't wait in
this queue or on that socket, so a keyframe going out doesn't hold it
up. When the queue has fallen too far behind,
the frames not yet started are thrown away and the encoder is asked for
a keyframe, since what follows a lost frame can't be decoded anyway;
until it comes, nothing else is queued.

Watching: a Watch lease on one sharer, repeated every WATCH_RESEND,
and sooner - asking for a keyframe - whenever the frames coming in
can't be decoded. What comes in is put together in a proto.Video_Window,
which says what's missing; on the media link we ask the server for it
again (Nack), and only what that doesn't bring is given up on. It goes over the main link, and the media link too
when there is one: the server serves sharers on media links on its
media thread and the others in its main loop, and each only knows of
leases that come to it.

Adapting: on the media link, a viewer reports once a second how the
share reaches it (proto.Report: fragments missing, how much later than
at their quickest frames arrive, what came in), and the server passes
the worst of a sharer's viewers on to it. The sharer holds its bitrate
down while that says the network can't keep up, and lets it back up
while it can, never over what it was set to (adapt_bitrate). The
library takes a new bitrate up only now and then, as each costs a
keyframe (yv_share_set_bitrate).
*/

// How fast video goes out, in bytes a second, and how much may go at
// once. Over what the encoder is asked for (the browser's 2 Mbit/s), so
// the queue drains after a keyframe. The desktop's share says what it
// encodes at (video_share_kbit), and goes out at half as much again:
// a keyframe goes out over several frames' time rather than in one
// burst that router queues would drop the end of.
VIDEO_SEND_RATE :: 12_000_000 / 8
VIDEO_SEND_BURST :: 16 * 1024
// More than this still waiting to go out means we can't keep up.
VIDEO_QUEUE_MAX :: VIDEO_SEND_RATE
// Video only goes out while less than this is waiting on the socket, so
// that the socket's buffer never holds much more than a burst. (Voice
// doesn't wait in it: video goes over the bulk link, bulk.odin.)
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
	window:         ^proto.Video_Window, // while watching

	// This connection is the one whose voice the page's screen goes to
	// (set by the UI, which has several; atomic). Only it shares.
	share_here:     bool,
	// Bytes sent and received since log_stats last looked, and the
	// window's counts when it did.
	bytes_out:      int,
	bytes_in:       int,
	logged:         [3]int,
	// The same for the View's figures (publish_video_stats), a second
	// at a time.
	stats_at:       time.Tick,
	stats_out:      int,
	stats_in:       int,
	stats_seen:     [3]int,
	last_codec:     proto.Video_Codec, // of the last frame shown
	stats_frags:    int, // fragments that came, for the Report's loss

	// For the Report's delay: how much later than the sharer's clock
	// each frame's first fragment comes, its least over the last 10
	// seconds (two halves), and how far over that this second.
	delay_min:      [2]i64,
	delay_min_at:   time.Tick,
	delay_sum:      i64,
	delay_n:        int,

	// Adapting our share to its viewers (adapt_bitrate).
	target_kbit:    int, // 0: as set
	cut_at:         time.Tick,
	good_since:     time.Tick,
	reports_at:     time.Tick,
	reports:        proto.Video_Reports, // the last
}

// Adapting the bitrate (adapt_bitrate): what says the network can't keep
// up (in thousandths of fragments missing, and ms of queueing), what
// says it can, how often to cut and how long it has to be good before
// going up, and how far down it may go (a part of what it was set to).
ADAPT_LOSS_BAD :: 20
ADAPT_DELAY_BAD :: 150
ADAPT_LOSS_GOOD :: 5
ADAPT_DELAY_GOOD :: 40
ADAPT_CUT_EVERY :: 2 * time.Second
ADAPT_GOOD_FOR :: 4 * time.Second
ADAPT_FLOOR :: 8
// With no reports for this long, nobody watches: back to as set.
ADAPT_QUIET :: 10 * time.Second
// How long the least delay is over (twice this).
DELAY_WINDOW :: 5 * time.Second

/*
Share_Preset is one of the sizes the desktop shares at, with the bitrate
that suits it at 60 frames a second; Advanced settings can change the
rate and bitrate (share_config). The server may take less (its
video.max_kbit), which the share is held to.
*/
Share_Preset :: struct {
	name:  string, // what settings.share_preset stores
	label: string,
	max:   [2]i32, // the largest it's scaled to, keeping its shape; 0 for as it is
	kbit:  int,
}

SHARE_PRESETS := [?]Share_Preset {
	{"720p", "720p", {1280, 720}, 4000},
	{"1080p", "1080p", {1920, 1080}, 8000},
	{"1440p", "1440p", {2560, 1440}, 15000},
	{"source", "As it is", {0, 0}, 20000},
}

// The preset that settings with none (or one we don't know) get.
DEFAULT_SHARE_PRESET :: 1

// The frame rates Advanced offers, and the bitrates (kbit/s).
SHARE_FPS_CHOICES :: [?]int{30, 60}
SHARE_KBIT_MIN :: 500
SHARE_KBIT_MAX :: 50_000

// share_preset is the preset `s` picks.
share_preset :: proc(s: ^settings.Settings) -> int {
	for p, i in SHARE_PRESETS {
		if p.name == s.share_preset {
			return i
		}
	}
	return DEFAULT_SHARE_PRESET
}

// How a share is set up (video_share_source).
Share_Config :: struct {
	max:     [2]i32,
	fps:     int,
	kbit:    int,
	encoder: string, // "" for the best that works
	cursor:  bool,
}

/*
share_config is what `s` says to share at, held to `limit_kbit` (the
server's limit for a sharer; 0 if it didn't say).
*/
share_config :: proc(s: ^settings.Settings, limit_kbit: int) -> Share_Config {
	p := SHARE_PRESETS[share_preset(s)]
	cfg := Share_Config {
		max     = p.max,
		fps     = s.share_fps if s.share_fps > 0 else 60,
		kbit    = s.share_kbit if s.share_kbit > 0 else p.kbit,
		encoder = s.share_encoder,
		cursor  = s.share_cursor,
	}
	if s.share_kbit == 0 && cfg.fps < 60 {
		// The preset's bitrate is for 60 frames a second.
		cfg.kbit = cfg.kbit * cfg.fps / 60
	}
	if limit_kbit > 0 {
		cfg.kbit = min(cfg.kbit, limit_kbit)
	}
	return cfg
}

// What the View shows of screen sharing, worked out once a second.
Video_Stats :: struct {
	kbit_in, kbit_out:     int,
	// Over that second: fragments asked for again, frames that saved,
	// and frames lost all the same.
	asked, saved, lost:    int,
	codec:                 proto.Video_Codec, // of what we watch
	// Sharing: what we're held to for our viewers (0 when not), what
	// the share was set to, and how many report (and were left out).
	kbit_target, kbit_max: int,
	viewers, left_out:     int,
}

Outgoing_Frame :: struct {
	num:   u32,
	ts:    u32,
	key:   bool,
	codec: proto.Video_Codec,
	data:  []u8, // owned
}

// Watch somebody's screen, or nobody's (0).
Watch_Command :: struct {
	user: proto.User_Num,
}

video_destroy :: proc(c: ^Voice_Client) {
	v := &c.video
	video_clear_queue(v)
	delete(v.queue)
	if v.window != nil {
		proto.video_window_destroy(v.window)
		free(v.window)
	}
	v^ = {}
}

// video_step gives screen sharing its turn in the network loop.
video_step :: proc(c: ^Voice_Client) {
	v := &c.video

	if live := video_capture_live() && sync.atomic_load(&v.share_here); live != v.sharing {
		v.sharing = live
		v.target_kbit, v.cut_at, v.good_since, v.reports_at = 0, {}, {}, {}
		v.reports = {}
		set_sound(c, .Sharing, live)
		video_clear_queue(v)
		v.awaiting_key = false
		log.infof("screen sharing %s", "started" if live else "stopped")
	}
	if v.sharing {
		for {
			data, ts, key, codec, ok := video_capture_pull()
			if !ok {
				break
			}
			video_queue_frame(v, data, ts, key, codec)
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
	publish_video_stats(c)
}

// publish_video_stats puts the figures in the View once a second while
// sharing or watching, and clears them once after.
@(private = "file")
publish_video_stats :: proc(c: ^Voice_Client) {
	v := &c.video
	active := v.sharing || v.watching != 0
	now := time.tick_now()
	if !active && v.stats_at == {} {
		return
	}
	if active && v.stats_at != {} && time.tick_diff(v.stats_at, now) < time.Second {
		return
	}
	s: Video_Stats
	if active && v.stats_at != {} {
		secs := time.duration_seconds(time.tick_diff(v.stats_at, now))
		s.kbit_in = int(f64(v.stats_in) * 8 / 1000 / secs)
		s.kbit_out = int(f64(v.stats_out) * 8 / 1000 / secs)
	}
	if w := v.window; w != nil {
		counts := [3]int{w.nacked, w.recovered, w.given_up}
		if active {
			s.asked = counts[0] - v.stats_seen[0]
			s.saved = counts[1] - v.stats_seen[1]
			s.lost = counts[2] - v.stats_seen[2]
		}
		v.stats_seen = counts
	}
	s.codec = v.last_codec
	if v.sharing {
		if v.target_kbit > 0 && time.tick_diff(v.reports_at, now) > ADAPT_QUIET {
			// Nobody's reported for a while: back to as set.
			v.target_kbit = 0
			video_share_adapt(video_share_max_kbit())
		}
		s.kbit_target = v.target_kbit
		s.kbit_max = video_share_max_kbit()
		s.viewers, s.left_out = v.reports.viewers, v.reports.left_out
	}
	if v.watching != 0 && active && c.media.has_current {
		send_report(c, s)
	}
	v.stats_in, v.stats_out = 0, 0
	v.stats_frags, v.delay_sum, v.delay_n = 0, 0, 0
	v.stats_at = now if active else {}
	if view := c.view; view != nil {
		view_write(view)
		view.video_stats = s
	}
}

/*
video_queue_frame takes over an encoded frame and queues it, or drops
it. Frames get their numbers here, so any dropped after this point show
up at the far end as a gap and a request for a keyframe.
*/
video_queue_frame :: proc(
	v: ^Video_Client,
	data: []u8,
	ts: u32,
	key: bool,
	codec := proto.Video_Codec.H264,
) {
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
	append(
		&v.queue,
		Outgoing_Frame{num = v.next_frame, ts = ts, key = key, codec = codec, data = data},
	)
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
			codec = f.codec,
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
	rate := VIDEO_SEND_RATE
	if kbit := video_share_kbit(); kbit > 0 {
		rate = kbit * 1000 / 8 * 3 / 2
	}
	if v.budget_at == {} {
		v.budget = VIDEO_SEND_BURST
	} else {
		elapsed := time.duration_seconds(time.tick_diff(v.budget_at, now))
		v.budget = min(VIDEO_SEND_BURST, v.budget + int(elapsed * f64(rate)))
	}
	v.budget_at = now

	buf: [proto.MAX_PAYLOAD_SIZE]u8
	// What video goes out on: the media link, else what send_data picks.
	media := c.media.has_current
	link := &c.media.link if media else &c.bulk.link if c.bulk.has_current else &c.link
	for v.budget > 0 && transport_backlog(&link.transport) < VIDEO_BACKLOG_MAX {
		msg, ok := video_next_fragment(v, buf[:])
		if !ok {
			break
		}
		if media {
			link_send(link, msg)
		} else {
			send_data(c, msg)
		}
		v.budget -= len(msg)
		v.bytes_out += len(msg)
		v.stats_out += len(msg)
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
			send_watch(c, proto.encode_watch(&buf, 0, false))
		}
	} else {
		if v.window == nil {
			v.window = new(proto.Video_Window)
		}
		proto.video_window_reset(v.window)
	}
	log.infof("watching %s", display_name(c, user) if user != 0 else "nobody")
	video_show_end()
	v.watching = user
	v.last_watch, v.last_key_asked = {}, {}
	publish_watching(c)
}

/*
drive_watch renews the lease on whoever we're watching, asks again for
what's gone missing (on the media link; without one, the window gives
up on it when it would have), and asks for a keyframe while what
arrives can't be decoded. Somebody who stops sharing or leaves the
channel stops being watched.
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
		proto.video_window_reset(v.window)
	}
	asking := c.media.has_current
	for n in proto.video_window_nacks(v.window, time.tick_now(), asking) {
		buf: [proto.NACK_SIZE]u8
		link_send(&c.media.link, proto.encode_nack(&buf, v.watching, n))
	}
	// Giving up may have let what's behind it through.
	show_frames(c)
	need_key := v.window.broken
	due := time.tick_since(v.last_watch) >= proto.WATCH_RESEND
	if need_key && time.tick_since(v.last_key_asked) >= proto.KEYFRAME_REQUEST_MIN {
		due = true
		v.last_key_asked = time.tick_now()
	}
	if !due {
		return
	}
	buf: [proto.WATCH_SIZE]u8
	send_watch(c, proto.encode_watch(&buf, v.watching, need_key))
	v.last_watch = time.tick_now()
}

// send_watch sends a Watch on the main link, and the media link if
// there is one.
@(private = "file")
send_watch :: proc(c: ^Voice_Client, msg: []u8) {
	send_data(c, msg)
	if c.media.has_current {
		link_send(&c.media.link, msg)
	}
}

// can_watch says whether `user` is sharing, in our voice room, and not us.
can_watch :: proc(c: ^Voice_Client, user: proto.User_Num) -> bool {
	ch := &c.channels
	if !ch.have_state || user == ch.state.your_user {
		return false
	}
	u := proto.find_user(&ch.state, user)
	if u == nil || .Sharing not_in u.flags {
		return false
	}
	room := my_room(c)
	return room != 0 && u.room == room
}

handle_video :: proc(c: ^Voice_Client, pt: []u8) {
	v := &c.video
	sharer, f, ok := proto.decode_video_down(pt)
	if !ok || sharer != v.watching || v.watching == 0 {
		return
	}
	v.bytes_in += len(pt)
	v.stats_in += len(pt)
	v.stats_frags += 1
	now := time.tick_now()
	if f.index == 0 {
		note_delay(v, f.ts, now)
	}
	proto.video_window_add(v.window, f, now)
	show_frames(c)
}

// send_report tells the server how the share we watch reaches us, this
// past second.
@(private = "file")
send_report :: proc(c: ^Voice_Client, s: Video_Stats) {
	v := &c.video
	r := proto.Video_Report {
		loss = s.asked * 1000 / max(v.stats_frags, 1),
		kbit = s.kbit_in,
	}
	if v.delay_n > 0 {
		r.delay_ms = int(v.delay_sum / i64(v.delay_n))
	}
	buf: [proto.REPORT_SIZE]u8
	link_send(&c.media.link, proto.encode_report_up(&buf, v.watching, r))
}

/*
note_delay notes when a frame's first fragment came, against the
sharer's clock (its `ts`). The clocks differ by some unknown amount, so
it's only how this compares with the least of the last 10 seconds that
says anything: a queue building up on the way.
*/
@(private = "file")
note_delay :: proc(v: ^Video_Client, ts: u32, now: time.Tick) {
	ms := u32(now._nsec / i64(time.Millisecond))
	rel := i64(i32(ms - ts))
	if v.delay_min_at == {} || time.tick_diff(v.delay_min_at, now) >= DELAY_WINDOW {
		v.delay_min[1] = v.delay_min[0] if v.delay_min_at != {} else rel
		v.delay_min[0] = rel
		v.delay_min_at = now
	}
	v.delay_min[0] = min(v.delay_min[0], rel)
	least := min(v.delay_min[0], v.delay_min[1])
	v.delay_sum += rel - least
	v.delay_n += 1
}

// video_reports: the server says how our share reaches its viewers.
video_reports :: proc(c: ^Voice_Client, s: proto.Video_Reports) {
	v := &c.video
	if !v.sharing {
		return
	}
	v.reports = s
	v.reports_at = time.tick_now()
	adapt_bitrate(v, s.worst, video_share_max_kbit(), v.reports_at)
}

/*
adapt_bitrate moves the share's bitrate with its worst viewer's report:
down by a quarter (to no less than what reaches them, if that's not
much less) when it says the network can't keep up, at most every
ADAPT_CUT_EVERY; up by a fifth of what it was set to after
ADAPT_GOOD_FOR of good reports; never under an ADAPT_FLOOR-th of that,
nor over it.
*/
adapt_bitrate :: proc(v: ^Video_Client, worst: proto.Video_Report, max_kbit: int, now: time.Tick) {
	if max_kbit <= 0 {
		return
	}
	floor := max(SHARE_KBIT_MIN, max_kbit / ADAPT_FLOOR)
	target := v.target_kbit if v.target_kbit > 0 else max_kbit
	was := target
	switch {
	case worst.loss >= ADAPT_LOSS_BAD || worst.delay_ms >= ADAPT_DELAY_BAD:
		v.good_since = {}
		if v.cut_at == {} || time.tick_diff(v.cut_at, now) >= ADAPT_CUT_EVERY {
			// What reaches them, unless that's only a still screen's
			// trickle.
			base := min(target, max(worst.kbit, target / 2))
			target = max(floor, base * 3 / 4)
			v.cut_at = now
		}
	case worst.loss < ADAPT_LOSS_GOOD && worst.delay_ms < ADAPT_DELAY_GOOD:
		if v.good_since == {} {
			v.good_since = now
		} else if target < max_kbit && time.tick_diff(v.good_since, now) >= ADAPT_GOOD_FOR {
			target = min(max_kbit, target + max_kbit / 5)
			v.good_since = now
		}
	case:
		v.good_since = {} // in between: as it is
	}
	if target != was {
		log.infof(
			"video: bitrate %d -> %d kbit/s for our viewers (worst: %d/1000 lost, %d ms late)",
			was,
			target,
			worst.loss,
			worst.delay_ms,
		)
		v.target_kbit = target if target < max_kbit else 0
		video_share_adapt(target)
	}
}

// show_frames hands what the window has ready to the decoder.
@(private = "file")
show_frames :: proc(c: ^Voice_Client) {
	v := &c.video
	for {
		frame := proto.video_window_pop(v.window) or_break
		v.last_codec = frame.codec
		video_show_frame(v.watching, frame)
	}
}

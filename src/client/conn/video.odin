package conn

import log "common:wlog"
import "core:sync"
import "core:time"

import "client:settings"
import "common:proto"

// Screen sharing (see src/common/proto/video.odin): the part that is the same
// wherever the client runs. Capturing, encoding and decoding are done by the
// browser (video_web.odin), or on the desktop by the optional yap_video library
// (video_native.odin), which can only watch so far. Without it, a desktop build
// never shares or watches, but still shows who is sharing.
//
// Everything goes over the media link (media.odin). Without it there is no
// sharing or watching, and the View says so (video_link).
//
// Sharing: encoded frames are numbered and queued, and go out one fragment at a
// time over the media link, paced to VIDEO_SEND_RATE and only while the socket
// is not already backed up. Voice does not wait in this queue or on that
// socket, so a keyframe going out does not hold it up. When the queue has
// fallen too far behind, the frames that have not started yet are thrown away
// and the encoder is asked for a keyframe, because whatever follows a lost
// frame cannot be decoded anyway. Until that keyframe arrives, nothing else is
// queued.
//
// Watching: a Watch lease on one sharer is renewed every WATCH_RESEND, and
// sooner (asking for a keyframe) whenever the incoming frames cannot be
// decoded. Incoming frames are assembled in a proto.Video_Window, which knows
// what is missing. We ask the server for the missing fragments again (Nack),
// and only what that does not bring is given up on.
//
// Adapting: once a second a viewer reports how well the share reaches it
// (proto.Report: missing fragments, how much later than at their quickest the
// frames arrive, and what came in). The server passes the worst report of a
// sharer's viewers on to the sharer. The sharer lowers its bitrate while the
// report says the network cannot keep up, and raises it again while it can,
// never above the configured value (adapt_bitrate). The library only accepts a
// new bitrate now and then, because each change costs a keyframe
// (yv_share_set_bitrate). Until it has, and for a moment after, the reports
// are about the old bitrate and that keyframe, so they are not acted on.

// How fast video goes out, in bytes per second, and how many bytes may go out
// at once. The rate is above what the encoder is asked for (the browser's 2
// Mbit/s), so the queue drains after a keyframe. The desktop's share reports
// its encoding bitrate (video_share_kbit) and goes out at half as much again,
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

Video_Client :: struct {
	// Sharing.
	sharing:        bool, // the capture is running
	next_frame:     u32,
	queue:          [dynamic]Outgoing_Frame,
	queued_bytes:   int,
	sent:           int, // fragments of queue[0] already sent
	awaiting_key:   bool, // frames were dropped, so only a keyframe may follow
	want_key:       bool, // the encoder should make the next frame a keyframe
	budget:         int, // bytes that may be sent now (VIDEO_SEND_RATE)
	budget_at:      time.Tick,

	// Watching.
	watching:       proto.User_Num, // 0: not watching anybody
	last_watch:     time.Tick,
	last_key_asked: time.Tick,
	window:         ^proto.Video_Window, // only set while watching

	// This connection is the one that the page's screen voice goes to (set by
	// the UI, which has several; atomic). Only it shares.
	share_here:     bool,
	// Bytes sent and received since log_stats last looked, and the window's
	// counts at that time.
	bytes_out:      int,
	bytes_in:       int,
	logged:         [3]int,
	// The same for the View's figures (publish_video_stats), one second at a
	// time.
	stats_at:       time.Tick,
	stats_out:      int,
	stats_in:       int,
	stats_seen:     [3]int,
	last_codec:     proto.Video_Codec, // codec of the last frame shown
	stats_frags:    int, // fragments that arrived, for the Report's loss

	// For the Report's delay: how much later than the sharer's clock each
	// frame's first fragment arrives, its minimum over the last 10 seconds (in
	// two halves), and how far above that minimum it was this second.
	delay_min:      [2]i64,
	delay_min_at:   time.Tick,
	delay_sum:      i64,
	delay_n:        int,

	// Adapting our share to its viewers (adapt_bitrate).
	target_kbit:    int, // 0: use the configured bitrate
	encoding_kbit:  int, // what the encoder runs at (video_share_kbit); 0 if not known
	encoding_at:    time.Tick, // when that last changed
	cut_at:         time.Tick,
	good_since:     time.Tick,
	reports_at:     time.Tick,
	reports:        proto.Video_Reports, // the latest reports
}

// Adapting the bitrate (adapt_bitrate): the thresholds that say the network
// cannot keep up (in thousandths of fragments missing, and ms of queueing), the
// thresholds that say it can, how often to cut, how long it has to be good
// before going up, and how far down it may go (a fraction of the configured
// bitrate).
ADAPT_LOSS_BAD :: 20
ADAPT_DELAY_BAD :: 150
ADAPT_LOSS_GOOD :: 5
ADAPT_DELAY_GOOD :: 40
ADAPT_CUT_EVERY :: 2 * time.Second
ADAPT_GOOD_FOR :: 4 * time.Second
ADAPT_FLOOR :: 8
// With no reports for this long, nobody is watching: go back to the configured bitrate.
ADAPT_QUIET :: 10 * time.Second
// How long after the encoder has changed its bitrate reports are not acted on:
// it starts again with a keyframe, which goes out as a burst, and the reports
// that come in meanwhile still cover the time before.
ADAPT_SETTLE :: 2 * time.Second
// The library takes up a new bitrate only if it differs by at least this part
// of the current one (yv_share_set_bitrate); a smaller change counts as done.
ADAPT_MIN_CHANGE :: 5
// How long the minimum delay is measured over (twice this).
DELAY_WINDOW :: 5 * time.Second

// Share_Preset is one of the sizes the desktop shares at, with the bitrate that
// suits it at 60 frames per second. Advanced settings can change the frame rate
// and bitrate (share_config). The server may allow less (its video.max_kbit),
// and the share is held to that.
Share_Preset :: struct {
	name:  string, // what settings.share_preset stores
	label: string,
	max:   [2]i32, // the largest it's scaled to, keeping its aspect ratio; 0 keeps the original size
	kbit:  int,
}

SHARE_PRESETS := [?]Share_Preset {
	{"720p", "720p", {1280, 720}, 4000},
	{"1080p", "1080p", {1920, 1080}, 8000},
	{"1440p", "1440p", {2560, 1440}, 15000},
	{"source", "Original size", {0, 0}, 20000},
}

// The preset used when the settings have none (or one we don't know).
DEFAULT_SHARE_PRESET :: 1

// The frame rates Advanced offers, and the bitrates (in kbit/s).
SHARE_FPS_CHOICES :: [?]int{30, 60}
SHARE_KBIT_MIN :: 500
SHARE_KBIT_MAX :: 50_000

// share_preset is the preset that `s` selects.
share_preset :: proc(s: ^settings.Settings) -> int {
	for p, i in SHARE_PRESETS {
		if p.name == s.share_preset {
			return i
		}
	}
	return DEFAULT_SHARE_PRESET
}

// How a share is set up (see video_share_source).
Share_Config :: struct {
	max:     [2]i32,
	fps:     int,
	kbit:    int,
	encoder: string, // "" picks the best encoder that works
	cursor:  bool,
}

// share_config is what `s` says to share at, held to `limit_kbit` (the server's
// limit for a sharer; 0 if it did not say).
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
		// The preset's bitrate is for 60 frames per second.
		cfg.kbit = cfg.kbit * cfg.fps / 60
	}
	if limit_kbit > 0 {
		cfg.kbit = min(cfg.kbit, limit_kbit)
	}
	return cfg
}

// What the View shows of screen sharing, calculated once a second.
Video_Stats :: struct {
	kbit_in, kbit_out:     int,
	// Over that second: fragments asked for again, frames that this saved,
	// and frames that were lost anyway.
	asked, saved, lost:    int,
	codec:                 proto.Video_Codec, // codec of what we are watching
	// Sharing: what we are held to for our viewers (0 when not sharing), what
	// the share was set to, and how many viewers report (and were left out).
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
		v.encoding_kbit, v.encoding_at = 0, {}
		v.reports = {}
		set_sound(c, .Sharing, live)
		video_clear_queue(v)
		v.awaiting_key = false
		log.infof("screen sharing %s", "started" if live else "stopped")
	}
	if v.sharing {
		note_encoding(v, video_share_kbit(), time.tick_now())
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
	say_decodable(c)
	publish_video_link(c)
	if v.sharing {
		video_share_codecs(viewer_codecs(c))
	}

	if c.has_current {
		video_send(c)
		drive_watch(c)
	}
	publish_video_stats(c)
}

// publish_video_link tells the View whether there is a media link, which
// sharing and watching need. (Only we write it, so it may be read without the
// lock.)
@(private = "file")
publish_video_link :: proc(c: ^Voice_Client) {
	up := c.media.has_current
	if c.view == nil || c.view.video_link == up {
		return
	}
	view_write(c.view)
	c.view.video_link = up
}

// say_decodable tells the others what we can watch (User_Flag). The page only
// knows this once it has asked the browser.
@(private = "file")
say_decodable :: proc(c: ^Voice_Client) {
	codecs := video_decodable() if video_can_watch() else {}
	have := proto.decodable_codecs(c.channels.sound)
	if (.HEVC in codecs) != (.HEVC in have) {
		set_sound(c, .Decodes_HEVC, .HEVC in codecs)
	}
	if (.AV1 in codecs) != (.AV1 in have) {
		set_sound(c, .Decodes_AV1, .AV1 in codecs)
	}
}

// viewer_codecs is what everyone else in our voice room can decode, any of whom
// may watch. A share is encoded in one of those codecs (the best that works,
// video_share_codecs). Anything goes while nobody else is there.
@(private)
viewer_codecs :: proc(c: ^Voice_Client) -> proto.Video_Codecs {
	ch := &c.channels
	codecs := proto.Video_Codecs{.H264, .HEVC, .AV1}
	room := my_room(c)
	if room == 0 {
		return codecs
	}
	for &u in ch.state.users {
		if u.room == room && u.num != ch.state.your_user {
			codecs &= proto.decodable_codecs(u.flags)
		}
	}
	return codecs
}

// publish_video_stats puts the figures in the View once a second while sharing
// or watching, and clears them once afterwards.
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
			// Nobody has reported for a while: go back to the configured bitrate.
			v.target_kbit = 0
			video_share_adapt(video_share_max_kbit())
		}
		s.kbit_target = v.target_kbit
		s.kbit_max = video_share_max_kbit()
		s.viewers, s.left_out = v.reports.viewers, v.reports.left_out
	}
	if v.watching != 0 && active {
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

// video_queue_frame takes over an encoded frame and queues it, or drops it.
// Frames get their numbers here, so any frame dropped after this point shows up
// at the far end as a gap and a request for a keyframe.
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
	// The frame going out doesn't count: a keyframe bigger than the limit would
	// otherwise throw out what follows it, and ask for another.
	waiting := v.queued_bytes
	if v.sent > 0 {
		waiting -= len(v.queue[0].data)
	}
	if waiting > video_queue_max(v) {
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

// video_next_fragment returns the next fragment to go out, as a Video message
// written to `out`, and moves past it.
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

// video_send_rate is how fast video goes out, in bytes per second: half as
// much again as the encoder makes, where that is known (VIDEO_SEND_RATE).
video_send_rate :: proc(v: ^Video_Client) -> int {
	if v.encoding_kbit > 0 {
		return v.encoding_kbit * 1000 / 8 * 3 / 2
	}
	return VIDEO_SEND_RATE
}

// video_queue_max is how many bytes may wait behind the frame going out:
// VIDEO_QUEUE_TIME's worth at the rate they go out.
video_queue_max :: proc(v: ^Video_Client) -> int {
	return video_send_rate(v) * int(VIDEO_QUEUE_TIME / time.Millisecond) / 1000
}

video_clear_queue :: proc(v: ^Video_Client) {
	for f in v.queue {
		delete(f.data)
	}
	clear(&v.queue)
	v.queued_bytes, v.sent = 0, 0
}

// video_send sends what the pacing and the socket allow.
@(private = "file")
video_send :: proc(c: ^Voice_Client) {
	v := &c.video
	if len(v.queue) == 0 {
		return
	}
	now := time.tick_now()
	rate := video_send_rate(v)
	if v.budget_at == {} {
		v.budget = VIDEO_SEND_BURST
	} else {
		elapsed := time.duration_seconds(time.tick_diff(v.budget_at, now))
		v.budget = min(VIDEO_SEND_BURST, v.budget + int(elapsed * f64(rate)))
	}
	v.budget_at = now
	if !c.media.has_current {
		return // the queue is falling behind, which asks for a keyframe
	}

	buf: [proto.MAX_PAYLOAD_SIZE]u8
	link := &c.media.link
	for v.budget > 0 && transport_backlog(&link.transport) < VIDEO_BACKLOG_MAX {
		msg, ok := video_next_fragment(v, buf[:])
		if !ok {
			break
		}
		link_send(link, msg)
		v.budget -= len(msg)
		v.bytes_out += len(msg)
		v.stats_out += len(msg)
	}
}

// video_keyframe_requested is called when a viewer asked the server for a keyframe.
video_keyframe_requested :: proc(c: ^Voice_Client) {
	if c.video.sharing {
		c.video.want_key = true
	}
}

// video_watch starts watching `user`, or stops watching when `user` is 0.
video_watch :: proc(c: ^Voice_Client, user: proto.User_Num) {
	v := &c.video
	if user == v.watching {
		return
	}
	if user == 0 {
		// The lease would run out anyway, but this ends it sooner.
		buf: [proto.WATCH_SIZE]u8
		send_watch(c, proto.encode_watch(&buf, 0, false))
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

// drive_watch renews the lease on whoever we are watching, asks again for
// whatever has gone missing, and asks for a keyframe while the incoming frames
// cannot be decoded. Somebody who stops sharing or leaves the channel is no
// longer watched.
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
	for n in proto.video_window_nacks(v.window, time.tick_now(), c.media.has_current) {
		buf: [proto.NACK_SIZE]u8
		link_send(&c.media.link, proto.encode_nack(&buf, v.watching, n))
	}
	// Giving up may have let the frames behind it through.
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

// send_watch sends a Watch, if there is a media link to send it on.
@(private = "file")
send_watch :: proc(c: ^Voice_Client, msg: []u8) {
	if c.media.has_current {
		link_send(&c.media.link, msg)
	}
}

// can_watch says whether `user` is sharing, is in our voice room, and is not us.
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

// send_report tells the server how well the share we watch has reached us
// during the past second.
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

// note_delay records when a frame's first fragment arrived, relative to the
// sharer's clock (its `ts`). The clocks differ by an unknown amount, so only
// the comparison with the minimum of the last 10 seconds is meaningful: it
// shows a queue building up on the way.
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

// video_reports is called when the server says how our share reaches its viewers.
video_reports :: proc(c: ^Voice_Client, s: proto.Video_Reports) {
	v := &c.video
	if !v.sharing {
		return
	}
	v.reports = s
	v.reports_at = time.tick_now()
	adapt_bitrate(v, s.worst, video_share_max_kbit(), v.reports_at)
}

// note_encoding keeps track of the bitrate the encoder runs at, and of when it
// last changed (adapt_bitrate).
@(private = "file")
note_encoding :: proc(v: ^Video_Client, kbit: int, now: time.Tick) {
	if kbit != v.encoding_kbit {
		v.encoding_kbit = kbit
		v.encoding_at = now
	}
}

// adapt_bitrate moves the share's bitrate according to its worst viewer's
// report. It goes down by a quarter when the report says the network cannot
// keep up (to no less than what reaches the viewer, unless that is much less),
// at most every ADAPT_CUT_EVERY. It goes up by a fifth of the configured
// bitrate after ADAPT_GOOD_FOR of good reports. It never goes below
// 1/ADAPT_FLOOR of the configured bitrate, nor above it.
//
// When the encoder's bitrate is known, changes start from it rather than from
// what was asked for last, which the library may have left alone as too small
// a change. While the encoder has not taken up the last change, and for
// ADAPT_SETTLE after it has, the reports are ignored.
adapt_bitrate :: proc(v: ^Video_Client, worst: proto.Video_Report, max_kbit: int, now: time.Tick) {
	if max_kbit <= 0 {
		return
	}
	floor := max(SHARE_KBIT_MIN, max_kbit / ADAPT_FLOOR)
	asked := v.target_kbit if v.target_kbit > 0 else max_kbit
	current := asked
	if enc := v.encoding_kbit; enc > 0 {
		// The library takes up a change of a fifth or more, and any change back
		// to the configured bitrate.
		pending :=
			asked != enc && (abs(asked - enc) * ADAPT_MIN_CHANGE >= enc || asked == max_kbit)
		if pending || time.tick_diff(v.encoding_at, now) < ADAPT_SETTLE {
			v.good_since = {}
			return
		}
		current = enc
	}
	target := current
	switch {
	case worst.loss >= ADAPT_LOSS_BAD || worst.delay_ms >= ADAPT_DELAY_BAD:
		v.good_since = {}
		if v.cut_at == {} || time.tick_diff(v.cut_at, now) >= ADAPT_CUT_EVERY {
			// What reaches them, unless that is only the trickle of a still
			// screen.
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
		v.good_since = {} // in between: keep the current bitrate
	}
	// Asking again for what the library left alone would change nothing.
	if target != current && target != asked {
		log.infof(
			"video: bitrate %d -> %d kbit/s for our viewers (worst: %d/1000 lost, %d ms late)",
			current,
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

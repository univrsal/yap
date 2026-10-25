package conn

import log "common:wlog"
import "core:fmt"
import "core:sync"
import "core:time"

import "client:video"
import "common:proto"


// Screen sharing and cameras (see src/common/proto/video.odin): the part that
// is the same wherever the client runs. Capturing, encoding and decoding are
// done by the browser (video/web.odin), or on the desktop by the optional
// yap_video library (video/native.odin). Without it, a desktop build never
// shares or watches, but still shows who is sharing.
//
// Everything goes over the media link (media.odin). Without it there is no
// sharing or watching, and the View says so (video_link).
//
// We send up to two streams, our screen and our camera (Video_Out), and watch
// one screen and up to MAX_CAMERAS cameras (Video_In). Each stream has all of
// what is described below to itself; only the pacing is shared.
//
// Sharing: encoded frames are numbered and queued, and go out one fragment at a
// time over the media link, paced (video_pace_rate: to the encoder's bitrate,
// or in a browser as fast as the server takes it) and only while the socket
// is not already backed up. Voice does not wait in this queue or on that
// socket, so a keyframe going out does not hold it up. When the queue has
// fallen too far behind, the frames that have not started yet are thrown away
// and the encoder is asked for a keyframe, because whatever follows a lost
// frame cannot be decoded anyway. Until that keyframe arrives, nothing else is
// queued. The camera goes first: it sends little, and its frames being late
// shows more than a screen's.
//
// A camera only goes out while the server shows our Camera flag, which it
// doesn't while the room already has as many cameras as it allows (or none at
// all). The capture keeps going meanwhile, and the View says that the camera
// was refused once it hasn't been taken for CAMERA_REFUSED_AFTER.
//
// Watching: a Watch lease on each stream we watch is renewed every
// WATCH_RESEND, and sooner (asking for a keyframe) whenever its incoming frames
// cannot be decoded. Incoming frames are assembled in a proto.Video_Window for
// each stream, which knows what is missing. We ask the server for the missing
// fragments again (Nack), and only what that does not bring is given up on. A
// screen that stops being shared is no longer watched; a camera that goes off
// is kept in the list the UI gave (Watch_Cameras_Command), and watched again
// when it comes back.
//
// Demand: a camera goes to all its viewers as one stream, so it need not be
// bigger than the largest tile any of them shows it in. Each lease on a camera
// says how big its tile is (in pixels), and the server tells the sharer the
// largest and how many viewers there are (proto.Demand). The camera is then
// sent at the smallest of CAMERA_SIZES that covers that tile, if that is
// smaller than the room's tier (follow_demand): larger at once, smaller once
// it has been asked for DEMAND_DOWN_AFTER, since each change costs a keyframe.
// With no viewers it stops encoding (video.camera_pause), and goes on as soon
// as the server says there is one or a viewer asks for a keyframe. A server
// that says nothing of it (Server_Info.demand) gets no tile sizes, and a
// camera that hears nothing for DEMAND_STALE goes back to the tier.
//
// Adapting: once a second a viewer reports how well each stream reaches it
// (proto.Report: missing fragments, how much later than at their quickest the
// frames arrive, and what came in). The server passes the worst report of a
// stream's viewers on to the sharer. The sharer lowers its bitrate while the
// report says the network cannot keep up, and raises it again while it can,
// never above the configured value (adapt_bitrate). The library only accepts a
// new bitrate now and then, because each change costs a keyframe
// (yv_share_set_bitrate). Until it has, and for a moment after, the reports
// are about the old bitrate and that keyframe, so they are not acted on.

Video_Client :: struct {
	outs:         [proto.Video_Stream]Video_Out,
	ins:          [video.STREAMS]Video_In,
	// How much of our video may go out now (VIDEO_SEND_RATE), for all of it.
	budget:       proto.Bucket,
	// This connection is the one that the page's screen voice goes to (set by
	// the UI, which has several; atomic). Only it shares.
	share_here:   bool,
	// Bytes sent and received since log_stats last looked (video_log_counts).
	bytes_out:    int,
	bytes_in:     int,
	// When the View's figures were last worked out (publish_video_stats).
	stats_at:     time.Tick,
	// Whether the View says that our camera was refused.
	refused:      bool,
	// For the log of what we send (log_video_out): when it last looked, when
	// video_step last ran and the longest it went without, and how often
	// video_send had to leave something waiting because the socket was backed
	// up or the pacing budget was spent.
	log_at:       time.Tick,
	step_at:      time.Tick,
	step_gap_max: time.Duration,
	held_backlog: int,
	held_budget:  int,
}

// Video_Out is one of our own streams going out.
Video_Out :: struct {
	stream:        proto.Video_Stream,
	live:          bool, // the capture is running
	live_at:       time.Tick, // since when
	// The server passes it on (the camera's Camera flag is shown; always for
	// the screen).
	taken:         bool,
	next_frame:    u32,
	queue:         [dynamic]Outgoing_Frame,
	queued_bytes:  int,
	sent:          int, // fragments of queue[0] already sent
	awaiting_key:  bool, // frames were dropped, so only a keyframe may follow
	want_key:      bool, // the encoder should make the next frame a keyframe
	stats_out:     int, // bytes sent this second, for the View's figures
	// For the log (log_video_out): bytes the encoder made and bytes sent since
	// it last looked, the most that waited in the queue, and how often the
	// queue was dropped.
	log_encoded:   int,
	log_sent:      int,
	log_queue_max: int,
	log_drops:     int,
	log_pace_max:  int, // the fastest it was paced, in bytes per second

	// Adapting it to its viewers (adapt_bitrate).
	target_kbit:   int, // 0: use the configured bitrate
	encoding_kbit: int, // what the encoder runs at (video.share_kbit); 0 if not known
	encoding_at:   time.Tick, // when that last changed
	cut_at:        time.Tick,
	good_since:    time.Tick,
	reports_at:    time.Tick,
	reports:       proto.Video_Reports, // the latest reports

	// The camera's tier (follow_camera_tier): what the room allows ({} not
	// yet), and a higher one it may go up to, and since when the room has kept
	// to it.
	tier:          video.Share_Config,
	tier_pending:  video.Share_Config,
	tier_since:    time.Tick,
	// What its viewers want (follow_demand): the server's last Demand and when
	// it came, what the camera is set to (the tier, or smaller for its
	// viewers), since when something smaller has been wanted, and whether it is
	// paused for having no viewers.
	demand:        proto.Demand,
	demand_at:     time.Tick,
	applied:       video.Share_Config,
	smaller_since: time.Tick,
	paused:        bool,
}

// Video_In is a stream that we watch.
Video_In :: struct {
	key:            video.Key, // a user of 0 when not in use
	// How big a camera's tile is in pixels (0 if not known), and what the
	// last Watch said.
	tile:           [2]int,
	tile_sent:      [2]int,
	// Its stream is on, so we hold a lease on it (drive_in).
	watching:       bool,
	last_watch:     time.Tick,
	last_key_asked: time.Tick,
	window:         ^proto.Video_Window, // set while in use
	// Frames were dropped because nothing could show them yet (show_frames).
	dropped:        bool,
	last_codec:     proto.Video_Codec, // codec of the last frame shown
	// Bytes and fragments that arrived this second, and the window's counts
	// when the figures (stats_seen) and the log (logged) last looked.
	stats_in:       int,
	stats_frags:    int,
	stats_seen:     [3]int,
	logged:         [3]int,

	// For the Report's delay: how much later than the sharer's clock each
	// frame's first fragment arrives, its minimum over the last 10 seconds (in
	// two halves), and how far above that minimum it was this second.
	delay_min:      [2]i64,
	delay_min_at:   time.Tick,
	delay_sum:      i64,
	delay_n:        int,
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

video_destroy :: proc(c: ^Server_Conn) {
	v := &c.video
	for &o in v.outs {
		video_clear_queue(&o)
		delete(o.queue)
	}
	for &in_ in v.ins {
		in_free(&in_)
	}
	v^ = {}
}

// video_step gives video its turn in the network loop.
video_step :: proc(c: ^Server_Conn) {
	v := &c.video
	now := time.tick_now()
	if v.step_at != {} {
		v.step_gap_max = max(v.step_gap_max, time.tick_diff(v.step_at, now))
	}
	v.step_at = now
	here := sync.atomic_load(&v.share_here)
	for &o, stream in v.outs {
		o.stream = stream
		out_step(c, &o, here)
	}
	video.capture_audio(&c.voice, v.outs[.Screen].live)
	say_decodable(c)
	publish_video_link(c)
	if c.has_current {
		video_send(c)
		drive_watch(c)
	}
	publish_video_stats(c)
	log_video_out(c, now)
}

stream_name :: proc(stream: proto.Video_Stream) -> string {
	return "camera" if stream == .Camera else "screen sharing"
}

// note_camera_taken follows whether the server shows our Camera flag, which is
// what lets our camera through, and tells the View when it doesn't.
note_camera_taken :: proc(c: ^Server_Conn, o: ^Video_Out, now: time.Tick) {
	v := &c.video
	ch := &c.channels
	me := proto.find_user(&ch.state, ch.state.your_user) if ch.have_state else nil
	taken := o.live && me != nil && .Camera in me.flags
	if taken != o.taken {
		o.taken = taken
		video_clear_queue(o)
		// What it sent before was dropped (or there was nothing), so the
		// viewers need a keyframe to start from.
		o.awaiting_key, o.want_key = taken, taken
		log.infof("camera %s by the server", "taken" if taken else "not taken")
	}
	refused := o.live && !taken && time.tick_diff(o.live_at, now) >= CAMERA_REFUSED_AFTER
	if refused != v.refused {
		v.refused = refused
		if view := c.view; view != nil {
			view_write(view)
			view.camera_refused = refused
		}
		if refused {
			max_cameras := c.rpc.server.max_cameras
			switch {
			case max_cameras == 0:
				notify(c, false, "This server doesn't allow cameras.")
			case my_room(c) == 0:
				notify(c, false, "Your camera can only be on in a voice chat or a call.")
			case:
				notify(
					c,
					false,
					fmt.tprintf(
						"This channel already has %d camera%s on.",
						max_cameras,
						"" if max_cameras == 1 else "s",
					),
				)
			}
		}
	}
}

// publish_video_link tells the View whether there is a media link, which
// sharing and watching need. (Only we write it, so it may be read without the
// lock.)
@(private = "file")
publish_video_link :: proc(c: ^Server_Conn) {
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
say_decodable :: proc(c: ^Server_Conn) {
	codecs := video.decodable() if video.can_watch() else {}
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
// video.share_codecs). Anything goes while nobody else is there.
@(private)
viewer_codecs :: proc(c: ^Server_Conn) -> proto.Video_Codecs {
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

// publish_video_stats reports how each stream we watch has reached us, and puts
// the figures of the screens (the one we share and the one we watch) in the
// View, once a second while anything is going on, and clears them once
// afterwards.
@(private = "file")
publish_video_stats :: proc(c: ^Server_Conn) {
	v := &c.video
	active := false
	for o in v.outs {
		active = active || o.live
	}
	for in_ in v.ins {
		active = active || in_.watching
	}
	now := time.tick_now()
	if !active && v.stats_at == {} {
		return
	}
	if active && v.stats_at != {} && time.tick_diff(v.stats_at, now) < time.Second {
		return
	}
	secs: f64
	if active && v.stats_at != {} {
		secs = time.duration_seconds(time.tick_diff(v.stats_at, now))
	}
	kbit :: proc(bytes: int, secs: f64) -> int {
		return int(f64(bytes) * 8 / 1000 / secs) if secs > 0 else 0
	}
	s: Video_Stats
	for &in_, i in v.ins {
		if in_.key.user == 0 {
			continue
		}
		counts := [3]int{in_.window.nacked, in_.window.recovered, in_.window.given_up}
		d := counts - in_.stats_seen if active else {}
		in_.stats_seen = counts
		kbit_in := kbit(in_.stats_in, secs)
		if in_.watching && active {
			send_report(c, &in_, d[0], kbit_in)
		}
		if i == 0 {
			s.kbit_in = kbit_in
			s.asked, s.saved, s.lost = d[0], d[1], d[2]
			s.codec = in_.last_codec
		}
		in_.stats_in, in_.stats_frags, in_.delay_sum, in_.delay_n = 0, 0, 0, 0
	}
	for &o in v.outs {
		if o.live && o.target_kbit > 0 && time.tick_diff(o.reports_at, now) > ADAPT_QUIET {
			// Nobody has reported for a while: go back to the configured bitrate.
			o.target_kbit = 0
			video.share_adapt(o.stream, video.share_max_kbit(o.stream))
		}
	}
	screen := &v.outs[.Screen]
	s.kbit_out = kbit(screen.stats_out, secs)
	if screen.live {
		s.kbit_target = screen.target_kbit
		s.kbit_max = video.share_max_kbit(.Screen)
		s.viewers, s.left_out = screen.reports.viewers, screen.reports.left_out
	}
	for &o in v.outs {
		o.stats_out = 0
	}
	v.stats_at = now if active else {}
	if view := c.view; view != nil {
		view_write(view)
		view.video_stats = s
	}
}

// video_keyframe_requested is called when a viewer asked the server for a
// keyframe of one of our streams. A camera paused for want of viewers has one
// now, so it goes on at once.
video_keyframe_requested :: proc(c: ^Server_Conn, stream: proto.Video_Stream) {
	o := &c.video.outs[stream]
	if !o.live {
		return
	}
	log.debugf("video: a viewer asked for a %s keyframe", stream_name(stream))
	o.want_key = true
	if o.paused {
		o.demand.viewers = max(o.demand.viewers, 1)
		follow_demand(o, time.tick_now())
	}
}

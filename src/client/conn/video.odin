package conn

import log "common:wlog"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"

import "client:settings"
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

// share_config is what `s` says to share at, held to `limit_kbit` (the server's
// limit for a sharer; 0 if it did not say).
share_config :: proc(s: ^settings.Settings, limit_kbit: int) -> video.Share_Config {
	p := SHARE_PRESETS[share_preset(s)]
	cfg := video.Share_Config {
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

// How a camera is sent (misc/video-chat, Quality). One stream goes to all of
// its viewers, so it has to suit the grid they all see: the more cameras in
// the room, the smaller each. Everyone works this out the same way from the
// Camera flags, so nothing needs to be said about it. A call has two, and
// gets the most.
CAMERA_CALL :: video.Share_Config {
	max  = {1280, 720},
	fps  = 30,
	kbit = 1800,
}

// The tiers of a channel's room, by the most cameras each is for.
Camera_Tier :: struct {
	cameras: int,
	config:  video.Share_Config,
}

CAMERA_TIERS := [?]Camera_Tier {
	{2, {max = {1280, 720}, fps = 30, kbit = 1500}},
	{4, {max = {960, 540}, fps = 30, kbit = 800}},
	{9, {max = {640, 360}, fps = 30, kbit = 450}},
	{proto.MAX_CAMERAS, {max = {480, 270}, fps = 24, kbit = 300}},
}

// The camera's quality in the settings (settings.camera_quality): Auto is the
// tiers as they are; High sends a call at 1080p; Low keeps to the 640x360 tier
// everywhere, for a slow connection or computer.
Camera_Quality :: enum i32 {
	Auto,
	High,
	Low,
}

CAMERA_QUALITY_NAMES := [Camera_Quality]string {
	.Auto = "auto",
	.High = "high",
	.Low  = "low",
}

CAMERA_CALL_HIGH :: video.Share_Config {
	max  = {1920, 1080},
	fps  = 30,
	kbit = 3500,
}

CAMERA_LOW :: video.Share_Config {
	max  = {640, 360},
	fps  = 30,
	kbit = 450,
}

// camera_quality is the quality settings.camera_quality names; Auto for
// anything else.
camera_quality :: proc(name: string) -> Camera_Quality {
	for n, q in CAMERA_QUALITY_NAMES {
		if n == name {
			return q
		}
	}
	return .Auto
}

// The quality the network thread keeps our camera to (follow_camera_tier),
// which the UI sets (video_set_camera_quality; atomic).
@(private = "file")
quality_now: Camera_Quality

// video_set_camera_quality has the camera follow `q` from now on; a camera
// that is on changes at once (or, going up, as a tier does).
video_set_camera_quality :: proc(q: Camera_Quality) {
	sync.atomic_store(&quality_now, q)
}

// The sizes a camera is sent at for its viewers' tiles (follow_demand), with
// the bitrate each needs at 30 fps, largest first.
CAMERA_SIZES := [?]video.Share_Config {
	{max = {1920, 1080}, kbit = 3500},
	{max = {1280, 720}, kbit = 1500},
	{max = {960, 540}, kbit = 800},
	{max = {640, 360}, kbit = 450},
	{max = {480, 270}, kbit = 300},
	{max = {320, 180}, kbit = 180},
}

// How long the viewers have to want a smaller camera before it is sent
// smaller, so that a window being resized or a tile clicked back and forth
// doesn't cost a keyframe each time.
DEMAND_DOWN_AFTER :: 3 * time.Second
// How often a Watch may go out sooner because a tile changed size.
WATCH_TILE_EVERY :: 250 * time.Millisecond
// A Demand older than this is not followed: the server went quiet, so the
// tier applies, and the camera isn't paused.
DEMAND_STALE :: 3 * time.Second

// demand_config is the camera at `tier`, made smaller to the smallest of
// CAMERA_SIZES that covers `tile` where that is smaller (a tile of 0: the
// tier).
demand_config :: proc(tier: video.Share_Config, tile: [2]int) -> video.Share_Config {
	if tile.x <= 0 || tile.y <= 0 {
		return tier
	}
	fit := CAMERA_SIZES[0]
	for s in CAMERA_SIZES {
		if int(s.max.x) >= tile.x && int(s.max.y) >= tile.y {
			fit = s
		}
	}
	if fit.max.x >= tier.max.x {
		return tier
	}
	cfg := tier
	cfg.max = fit.max
	cfg.kbit = min(tier.kbit, fit.kbit)
	return cfg
}

// How long the room has to keep fewer cameras before ours goes up a tier
// again. Going down happens at once. Each change costs a keyframe, so a camera
// that goes on and off doesn't make everybody's encoders start again each
// time.
CAMERA_TIER_UP_AFTER :: 5 * time.Second

// camera_config is how to send our camera with `cameras` on in our room (ours
// included), or in a call, at `quality`, held to `limit_kbit` (the server's
// limit for a camera; 0 if it did not say).
camera_config :: proc(
	cameras: int,
	call: bool,
	limit_kbit: int,
	quality := Camera_Quality.Auto,
) -> video.Share_Config {
	cfg := CAMERA_CALL_HIGH if quality == .High else CAMERA_CALL
	if !call {
		cfg = CAMERA_TIERS[len(CAMERA_TIERS) - 1].config
		for t in CAMERA_TIERS {
			if cameras <= t.cameras {
				cfg = t.config
				break
			}
		}
	}
	if quality == .Low && cfg.max.x > CAMERA_LOW.max.x {
		cfg = CAMERA_LOW
	}
	if limit_kbit > 0 {
		cfg.kbit = min(cfg.kbit, limit_kbit)
	}
	return cfg
}

// room_camera_config is camera_config for our room as it is now.
@(private = "file")
room_camera_config :: proc(c: ^Server_Conn) -> video.Share_Config {
	ch := &c.channels
	room := my_room(c)
	cameras := 1 // ours
	for u in ch.state.users {
		if u.room == room && u.num != ch.state.your_user && .Camera in u.flags {
			cameras += 1
		}
	}
	return camera_config(
		cameras,
		proto.room_call(room) != 0,
		int(c.rpc.server.camera_kbit),
		sync.atomic_load(&quality_now),
	)
}

// follow_camera_tier keeps our camera to the tier of the room: down at once, up
// once the room has kept to fewer cameras for CAMERA_TIER_UP_AFTER.
@(private = "file")
follow_camera_tier :: proc(c: ^Server_Conn, o: ^Video_Out, now: time.Tick) {
	if !c.channels.have_state || my_room(c) == 0 {
		return
	}
	want := room_camera_config(c)
	switch {
	case want == o.tier:
		o.tier_since = {}
		return
	case o.tier != {} && want.max.x >= o.tier.max.x && want.kbit >= o.tier.kbit:
		// Up: once it has kept to it for long enough.
		if o.tier_since == {} || want != o.tier_pending {
			o.tier_pending, o.tier_since = want, now
			return
		}
		if time.tick_diff(o.tier_since, now) < CAMERA_TIER_UP_AFTER {
			return
		}
	}
	log.infof(
		"camera: %dx%d at %d fps, %d kbit/s for this room",
		want.max.x,
		want.max.y,
		want.fps,
		want.kbit,
	)
	o.tier, o.tier_since = want, {}
}

// follow_demand keeps our camera to what its viewers show (see Demand above):
// at the room's tier, or smaller, and paused while nobody watches.
@(private)
follow_demand :: proc(o: ^Video_Out, now: time.Tick) {
	if o.tier == {} {
		return
	}
	fresh := o.demand_at != {} && time.tick_diff(o.demand_at, now) < DEMAND_STALE
	tile := o.demand.tile if fresh else {}
	if pause := fresh && o.demand.viewers == 0; pause != o.paused {
		o.paused = pause
		video.camera_pause(pause)
		log.infof(
			"camera: %s",
			"nobody watches it, so it pauses" if pause else "watched, so it goes on",
		)
	}
	want := demand_config(o.tier, tile)
	if want == o.applied {
		o.smaller_since = {}
		return
	}
	if o.applied != {} && want.max.x < o.applied.max.x && want != o.tier {
		// Smaller only for its viewers: once they have kept to it.
		if o.smaller_since == {} {
			o.smaller_since = now
		}
		if time.tick_diff(o.smaller_since, now) < DEMAND_DOWN_AFTER {
			return
		}
	}
	if want != o.tier {
		log.infof(
			"camera: %dx%d, %d kbit/s for its viewers' %dx%d",
			want.max.x,
			want.max.y,
			want.kbit,
			tile.x,
			tile.y,
		)
	}
	video.camera_configure(want)
	o.applied, o.smaller_since = want, {}
	// What it was held to was a part of the old bitrate.
	o.target_kbit = 0
}

// video_demand is called when the server says what the viewers of one of our
// streams want of it.
video_demand :: proc(c: ^Server_Conn, d: proto.Demand) {
	o := &c.video.outs[d.stream]
	if !o.live || d.stream != .Camera {
		return
	}
	o.demand, o.demand_at = d, time.tick_now()
	follow_demand(o, o.demand_at)
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

// Watch the cameras of these users, and no others, each in a tile of that
// size in pixels (0 if not known). A user whose camera is off stays in the
// list and is watched once it comes on.
Watch_Cameras_Command :: struct {
	users: [proto.MAX_CAMERAS]proto.User_Num,
	tiles: [proto.MAX_CAMERAS][2]int,
	count: int,
}

// Watch the cameras of the users of these accounts (names separated by spaces,
// owned), and no others: the headless client's /cameras.
Watch_Camera_Names_Command :: struct {
	names: string,
}

// video_watch_camera_names watches the cameras of the named accounts' users.
video_watch_camera_names :: proc(c: ^Server_Conn, names: string) {
	users := make([dynamic]proto.User_Num, context.temp_allocator)
	for name in strings.fields(names, context.temp_allocator) {
		account := account_named(c, name)
		if account == 0 {
			log.warnf("there's no account %q", name)
			continue
		}
		for u in c.channels.state.users {
			if u.account == account {
				append(&users, u.num)
			}
		}
	}
	video_watch_cameras(c, users[:], nil)
	log.infof("watching %d cameras", len(users))
}

// watch_cameras makes the command that watches the cameras of `users` (the
// first MAX_CAMERAS of them).
watch_cameras :: proc(users: ..proto.User_Num) -> (cmd: Watch_Cameras_Command) {
	cmd.count = copy(cmd.users[:], users)
	return
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

// out_step follows one of our streams: whether it is live, whether the server
// takes it, and what its encoder has ready.
@(private = "file")
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

@(private = "file")
stream_name :: proc(stream: proto.Video_Stream) -> string {
	return "camera" if stream == .Camera else "screen sharing"
}

// note_camera_taken follows whether the server shows our Camera flag, which is
// what lets our camera through, and tells the View when it doesn't.
@(private = "file")
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
@(private = "file")
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
@(private = "file")
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

// video_watch starts watching `user`'s screen, or stops watching any when
// `user` is 0.
video_watch :: proc(c: ^Server_Conn, user: proto.User_Num) {
	in_ := &c.video.ins[0]
	if user == in_.key.user {
		return
	}
	if in_.key.user != 0 {
		in_stop(c, in_)
	}
	if user != 0 {
		in_start(in_, {user, .Screen})
	}
	log.infof("watching %s", display_name(c, user) if user != 0 else "nobody")
	publish_watching(c)
}

// video_watch_cameras watches the cameras of `users`, each in a tile of the
// size `tiles` says (none if nil), and stops watching all others.
video_watch_cameras :: proc(c: ^Server_Conn, users: []proto.User_Num, tiles: [][2]int) {
	v := &c.video
	for &in_ in v.ins[1:] {
		if in_.key.user != 0 && !slice.contains(users, in_.key.user) {
			in_stop(c, &in_)
		}
	}
	next: for user, i in users {
		if user == 0 {
			continue
		}
		tile := tiles[i] if i < len(tiles) else {}
		free_in: ^Video_In
		for &in_ in v.ins[1:] {
			if in_.key.user == user {
				in_.tile = tile
				continue next
			}
			if in_.key.user == 0 && free_in == nil {
				free_in = &in_
			}
		}
		if free_in == nil {
			break // more than MAX_CAMERAS
		}
		in_start(free_in, {user, .Camera})
		free_in.tile = tile
	}
}

@(private = "file")
in_start :: proc(in_: ^Video_In, key: video.Key) {
	window := in_.window if in_.window != nil else new(proto.Video_Window)
	in_^ = {
		key    = key,
		window = window,
	}
	proto.video_window_reset(window)
	window.reliable = video.MEDIA_RELIABLE
}

// in_stop stops watching a stream, ending its lease at once rather than when
// it runs out, and lets go of what it took.
@(private = "file")
in_stop :: proc(c: ^Server_Conn, in_: ^Video_In) {
	if in_.watching {
		buf: [proto.WATCH_TILE_SIZE]u8
		send_watch(c, proto.encode_watch(&buf, in_.key.user, false, in_.key.stream, stop = true))
	}
	video.show_end(in_.key)
	in_free(in_)
}

@(private = "file")
in_free :: proc(in_: ^Video_In) {
	if in_.window != nil {
		proto.video_window_destroy(in_.window)
		free(in_.window)
	}
	in_^ = {}
}

// drive_watch drives each stream we watch (drive_in).
@(private = "file")
drive_watch :: proc(c: ^Server_Conn) {
	if !c.channels.have_state {
		return
	}
	for &in_ in c.video.ins {
		if in_.key.user != 0 {
			drive_in(c, &in_)
		}
	}
}

// drive_in renews the lease on a stream, asks again for whatever has gone
// missing, and asks for a keyframe while the incoming frames cannot be decoded.
// A screen that is no longer shared or whose sharer leaves the channel is no
// longer watched, and a camera that goes off waits until it comes on again.
@(private = "file")
drive_in :: proc(c: ^Server_Conn, in_: ^Video_In) {
	if !can_watch(c, in_.key) {
		if in_.key.stream == .Screen {
			video_watch(c, 0)
		} else if in_.watching {
			// Its lease runs out by itself.
			video.show_end(in_.key)
			proto.video_window_reset(in_.window)
			in_.watching, in_.last_watch, in_.last_key_asked = false, {}, {}
		}
		return
	}
	in_.watching = true
	if video.show_failed(in_.key) {
		// Whatever the decoder had is gone, so start again from a keyframe.
		log.infof("video: %s's decoder failed", in_name(c, in_.key))
		proto.video_window_reset(in_.window)
	}
	for n in proto.video_window_nacks(in_.window, time.tick_now(), c.media.has_current) {
		buf: [proto.NACK_CAMERA_SIZE]u8
		link_send(&c.media.link, proto.encode_nack(&buf, in_.key.user, n, in_.key.stream))
	}
	// Giving up may have let the frames behind it through.
	show_frames(in_)
	log_break(c, in_)
	need_key := in_.window.broken
	due := time.tick_since(in_.last_watch) >= proto.WATCH_RESEND
	if need_key && time.tick_since(in_.last_key_asked) >= proto.KEYFRAME_REQUEST_MIN {
		due = true
		in_.last_key_asked = time.tick_now()
	}
	// A server that takes tile sizes hears of a new one soon (but not at every
	// step of a window being resized).
	tile := in_.tile if c.rpc.server.demand && in_.key.stream == .Camera else {}
	if tile != in_.tile_sent && time.tick_since(in_.last_watch) >= WATCH_TILE_EVERY {
		due = true
	}
	if !due {
		return
	}
	buf: [proto.WATCH_TILE_SIZE]u8
	send_watch(c, proto.encode_watch(&buf, in_.key.user, need_key, in_.key.stream, tile = tile))
	in_.last_watch = time.tick_now()
	in_.tile_sent = tile
}

// log_break logs why the frames of a stream we watch can no longer be decoded,
// which asks for a keyframe and leaves the picture still until it comes.
@(private = "file")
log_break :: proc(c: ^Server_Conn, in_: ^Video_In) {
	w := in_.window
	if w.breaks == 0 {
		return
	}
	b := w.last_break
	more := fmt.tprintf(" (and %d more)", w.breaks - 1) if w.breaks > 1 else ""
	w.breaks = 0
	if b.pushed_out > 0 {
		log.debugf(
			"video: %s broke at frame %d: %d frames pushed out of the window%s",
			in_name(c, in_.key),
			b.frame,
			b.pushed_out,
			more,
		)
		return
	}
	log.debugf(
		"video: %s broke at frame %d: gave up on it with %d of %d fragments%s after %d Nack rounds, %.0f ms after its gap was seen, %.0f ms after its last fragment%s",
		in_name(c, in_.key),
		b.frame,
		b.received,
		b.count,
		" (a keyframe)" if b.key else "",
		b.rounds,
		time.duration_milliseconds(b.waited),
		time.duration_milliseconds(b.idle),
		more,
	)
}

// in_name names a stream we watch for the log.
@(private = "file")
in_name :: proc(c: ^Server_Conn, key: video.Key) -> string {
	return fmt.tprintf(
		"%s's %s",
		display_name(c, key.user),
		"camera" if key.stream == .Camera else "screen",
	)
}

// send_watch sends a Watch, if there is a media link to send it on.
@(private = "file")
send_watch :: proc(c: ^Server_Conn, msg: []u8) {
	if c.media.has_current {
		link_send(&c.media.link, msg)
	}
}

// can_watch says whether `key`'s stream is on, its user is in our voice room,
// and is not us.
can_watch :: proc(c: ^Server_Conn, key: video.Key) -> bool {
	ch := &c.channels
	if !ch.have_state || key.user == ch.state.your_user {
		return false
	}
	u := proto.find_user(&ch.state, key.user)
	if u == nil || proto.stream_flag(key.stream) not_in u.flags {
		return false
	}
	room := my_room(c)
	return room != 0 && u.room == room
}

handle_video :: proc(c: ^Server_Conn, pt: []u8) {
	v := &c.video
	sharer, f, ok := proto.decode_video_down(pt)
	if !ok || sharer == 0 {
		return
	}
	key := video.Key{sharer, f.stream}
	in_: ^Video_In
	for &candidate in v.ins {
		if candidate.key == key && candidate.watching {
			in_ = &candidate
			break
		}
	}
	if in_ == nil {
		return
	}
	v.bytes_in += len(pt)
	in_.stats_in += len(pt)
	in_.stats_frags += 1
	now := time.tick_now()
	if f.index == 0 {
		note_delay(in_, f.ts, now)
	}
	proto.video_window_add(in_.window, f, now)
	show_frames(in_)
}

// send_report tells the server how well a stream we watch has reached us
// during the past second: `asked` fragments were asked for again, and
// `kbit_in` came in.
@(private = "file")
send_report :: proc(c: ^Server_Conn, in_: ^Video_In, asked, kbit_in: int) {
	r := proto.Video_Report {
		loss = asked * 1000 / max(in_.stats_frags, 1),
		kbit = kbit_in,
	}
	if in_.delay_n > 0 {
		r.delay_ms = int(in_.delay_sum / i64(in_.delay_n))
	}
	buf: [proto.REPORT_CAMERA_SIZE]u8
	link_send(&c.media.link, proto.encode_report_up(&buf, in_.key.user, r, in_.key.stream))
}

// note_delay records when a frame's first fragment arrived, relative to the
// sharer's clock (its `ts`). The clocks differ by an unknown amount, so only
// the comparison with the minimum of the last 10 seconds is meaningful: it
// shows a queue building up on the way.
@(private = "file")
note_delay :: proc(in_: ^Video_In, ts: u32, now: time.Tick) {
	ms := u32(now._nsec / i64(time.Millisecond))
	rel := i64(i32(ms - ts))
	if in_.delay_min_at == {} || time.tick_diff(in_.delay_min_at, now) >= DELAY_WINDOW {
		in_.delay_min[1] = in_.delay_min[0] if in_.delay_min_at != {} else rel
		in_.delay_min[0] = rel
		in_.delay_min_at = now
	}
	in_.delay_min[0] = min(in_.delay_min[0], rel)
	least := min(in_.delay_min[0], in_.delay_min[1])
	in_.delay_sum += rel - least
	in_.delay_n += 1
}

// video_reports is called when the server says how one of our streams reaches
// its viewers.
video_reports :: proc(c: ^Server_Conn, stream: proto.Video_Stream, s: proto.Video_Reports) {
	o := &c.video.outs[stream]
	if !o.live {
		return
	}
	o.reports = s
	o.reports_at = time.tick_now()
	adapt_bitrate(o, s.worst, video.share_max_kbit(stream), o.reports_at)
}

// note_encoding keeps track of the bitrate the encoder runs at, and of when it
// last changed (adapt_bitrate).
@(private = "file")
note_encoding :: proc(o: ^Video_Out, kbit: int, now: time.Tick) {
	if kbit != o.encoding_kbit {
		o.encoding_kbit = kbit
		o.encoding_at = now
	}
}

// adapt_bitrate moves a stream's bitrate according to its worst viewer's
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
adapt_bitrate :: proc(o: ^Video_Out, worst: proto.Video_Report, max_kbit: int, now: time.Tick) {
	if max_kbit <= 0 {
		return
	}
	floor := max(SHARE_KBIT_MIN, max_kbit / ADAPT_FLOOR)
	asked := o.target_kbit if o.target_kbit > 0 else max_kbit
	current := asked
	if enc := o.encoding_kbit; enc > 0 {
		// The library takes up a change of a fifth or more, and any change back
		// to the configured bitrate.
		pending :=
			asked != enc && (abs(asked - enc) * ADAPT_MIN_CHANGE >= enc || asked == max_kbit)
		if pending || time.tick_diff(o.encoding_at, now) < ADAPT_SETTLE {
			o.good_since = {}
			return
		}
		current = enc
	}
	target := current
	switch {
	case worst.loss >= ADAPT_LOSS_BAD || worst.delay_ms >= ADAPT_DELAY_BAD:
		o.good_since = {}
		if o.cut_at == {} || time.tick_diff(o.cut_at, now) >= ADAPT_CUT_EVERY {
			// What reaches them, unless that is only the trickle of a still
			// screen.
			base := min(target, max(worst.kbit, target / 2))
			target = max(floor, base * 3 / 4)
			o.cut_at = now
		}
	case worst.loss < ADAPT_LOSS_GOOD && worst.delay_ms < ADAPT_DELAY_GOOD:
		if o.good_since == {} {
			o.good_since = now
		} else if target < max_kbit && time.tick_diff(o.good_since, now) >= ADAPT_GOOD_FOR {
			target = min(max_kbit, target + max_kbit / 5)
			o.good_since = now
		}
	case:
		o.good_since = {} // in between: keep the current bitrate
	}
	// Asking again for what the library left alone would change nothing.
	if target != current && target != asked {
		log.infof(
			"video: %s bitrate %d -> %d kbit/s for our viewers (worst: %d/1000 lost, %d ms late)",
			stream_name(o.stream),
			current,
			target,
			worst.loss,
			worst.delay_ms,
		)
		o.target_kbit = target if target < max_kbit else 0
		video.share_adapt(o.stream, target)
	}
}

// show_frames hands what a stream's window has ready to its decoder. While it
// has none yet (video.show_ready: the desktop makes it when the UI first draws
// the stream), the frames are dropped. Once it has, it starts from a keyframe:
// anything else resets the window, which asks for one.
@(private = "file")
show_frames :: proc(in_: ^Video_In) {
	ready := video.show_ready(in_.key)
	for {
		frame := proto.video_window_pop(in_.window) or_break
		if !ready {
			in_.dropped = true
			continue
		}
		if in_.dropped && !frame.key {
			proto.video_window_reset(in_.window)
			break
		}
		in_.dropped = false
		in_.last_codec = frame.codec
		video.show_frame(in_.key, frame)
	}
}

package conn

import log "common:wlog"
import "core:sync"
import "core:time"

import "client:settings"
import "client:video"
import "common:proto"

// What to send: share presets, camera sizes and tiers, and what the viewers' tiles
// ask for.

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

// How a camera is sent (docs/design/video-chat.md, Quality). One stream goes to all of
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

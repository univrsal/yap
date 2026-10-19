#+build !wasi
package conn

import "base:runtime"
import "core:dynlib"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "client:audio"
import "client:render"
import "common:proto"
import log "common:wlog"

// Screen sharing on the desktop comes from an optional library, yap_video
// (src/video, misc/hq-share/README.md), which is loaded from next to the
// executable the first time anything here is asked. Without it, or with a
// different version of it, the client neither shares nor watches.
//
// The library decodes on threads of its own and keeps the newest picture on the
// GPU, created for our renderer's device (video_picture). Frames are pushed
// from the network thread (video_show_frame). Each stream we watch (a screen,
// cameras) has a view of its own (View_Slot).
//
// Sharing: the UI picks a monitor or window (video_sources, video_share_source),
// and the library captures and encodes it on a thread of its own. The network
// thread pulls the encoded frames (video_capture_pull). Which encoders work is
// found out on a separate thread while the library loads, because trying them
// takes a moment. Until then, and if none works, video_can_share says no. There
// is one share of the screen for the whole client, like the browser's, and one
// of our camera (misc/video-chat): the library shares a camera the same way.
// Only Windows has cameras so far (DirectShow, through dshowcapture.dll); the
// library lists them, which is done off the UI thread (list_cameras).
//
// On macOS the user has to allow Screen Recording first. Until they have,
// sharing is still offered, and the menu asks for the permission
// (video_capture_allowed, video_allow_capture) instead of listing sources.

// The desktop's media link is UDP, which loses packets and asks for them again
// (proto.Video_Window).
MEDIA_RELIABLE :: false

// The version of the library API this was built against (see src/video/include/yap_video.h).
@(private = "file")
YV_API_VERSION :: 9

@(private = "file")
Yv_Log_Proc :: #type proc "c" (user: rawptr, level: i32, msg: cstring)

@(private = "file")
Yv_Init :: struct {
	api_version: u32,
	log:         Yv_Log_Proc,
	log_user:    rawptr,
	log_level:   i32,
}

@(private = "file")
Yv_Gpu :: struct {
	kind:         i32, // 0 none, 1 D3D11, 2 GL, 3 Metal
	d3d11_device: rawptr,
	gl_get_proc:  rawptr,
	metal_device: rawptr,
	metal_queue:  rawptr,
}

@(private = "file")
Yv_Picture :: struct {
	texture:  uintptr,
	width:    i32,
	height:   i32,
	frames:   u64,
	hardware: bool,
	pts_us:   u64,
}

@(private = "file")
Yv_Source :: struct {
	kind:          i32, // 0 monitor, 1 window
	id:            u64,
	name:          [256]u8,
	app:           [256]u8,
	x, y:          i32,
	width, height: i32,
	primary:       bool,
}

@(private = "file")
Yv_Encoder :: struct {
	name:     [64]u8,
	label:    [128]u8,
	codec:    i32,
	hardware: bool,
	works:    bool,
}

@(private = "file")
Yv_Share_Config :: struct {
	kind:                  i32,
	source:                u64,
	encoder:               [64]u8,
	fps:                   i32,
	max_width, max_height: i32,
	kbit:                  u32,
	cursor:                bool,
	codecs:                u32, // bits (1 << codec) that the viewers decode; 0 for any
}

@(private = "file")
Yv_Camera :: struct {
	id:                             [512]u8,
	name:                           [256]u8,
	max_width, max_height, max_fps: i32,
	front:                          bool,
}

@(private = "file")
Yv_Camera_Config :: struct {
	camera:                [512]u8, // Yv_Camera.id, or "" for the first
	encoder:               [64]u8,
	fps:                   i32,
	max_width, max_height: i32,
	kbit:                  u32,
	codecs:                u32,
}

@(private = "file")
Yv_Packet :: struct {
	data:   [^]u8,
	size:   uint,
	pts_us: u64,
	codec:  i32,
	key:    bool,
}

// The values of yv_share_state.
@(private = "file")
YV_SHARE_STARTING :: 1
@(private = "file")
YV_SHARE_LIVE :: 2
@(private = "file")
YV_SHARE_FAILED :: 3
@(private = "file")
YV_SHARE_CANCELLED :: 4

// The library's procedures, named without their yv_ prefix.
@(private = "file")
Yv :: struct {
	api_version:           proc "c" () -> u32,
	version_string:        proc "c" () -> cstring,
	create:                proc "c" (init: ^Yv_Init) -> rawptr,
	set_gpu:               proc "c" (ctx: rawptr, gpu: ^Yv_Gpu),
	view_create:           proc "c" (ctx: rawptr) -> rawptr,
	view_push:             proc "c" (
		view: rawptr,
		data: [^]u8,
		size: uint,
		codec: i32,
		pts_us: u64,
		key: bool,
	),
	view_clear:            proc "c" (view: rawptr),
	view_take_failed:      proc "c" (view: rawptr) -> bool,
	view_present:          proc "c" (view: rawptr, out: ^Yv_Picture) -> bool,
	list_sources:          proc "c" (ctx: rawptr, out: [^]Yv_Source, max: i32) -> i32,
	list_encoders:         proc "c" (ctx: rawptr, out: [^]Yv_Encoder, max: i32) -> i32,
	share_start:           proc "c" (ctx: rawptr, config: ^Yv_Share_Config) -> rawptr,
	share_pull:            proc "c" (share: rawptr, out: ^Yv_Packet) -> bool,
	share_request_key:     proc "c" (share: rawptr),
	share_set_bitrate:     proc "c" (share: rawptr, kbit: u32),
	share_get_bitrate:     proc "c" (share: rawptr) -> u32,
	share_set_codecs:      proc "c" (share: rawptr, codecs: u32),
	share_get_state:       proc "c" (share: rawptr) -> i32,
	share_error:           proc "c" (share: rawptr) -> cstring,
	share_stop:            proc "c" (share: rawptr),
	capture_allowed:       proc "c" (ctx: rawptr, ask: bool) -> bool,
	open_capture_settings: proc "c" (ctx: rawptr) -> bool,
	system_picker:         proc "c" (ctx: rawptr) -> bool,
	view_on_frame:         proc "c" (view: rawptr, fn: proc "c" (user: rawptr), user: rawptr),
	list_cameras:          proc "c" (ctx: rawptr, out: [^]Yv_Camera, max: i32) -> i32,
	camera_allowed:        proc "c" (ctx: rawptr, ask: bool) -> bool,
	camera_start:          proc "c" (ctx: rawptr, config: ^Yv_Camera_Config) -> rawptr,
	share_configure:       proc "c" (share: rawptr, fps, max_width, max_height: i32, kbit: u32),
	share_preview:         proc "c" (share: rawptr, out: ^Yv_Picture) -> bool,
	__handle:              dynlib.Library,
}

@(private = "file")
YV_PROCS :: 29

when ODIN_OS == .Windows {
	@(private = "file")
	YV_LIBRARY :: "yap_video.dll"
} else when ODIN_OS == .Darwin {
	@(private = "file")
	YV_LIBRARY :: "libyap_video.dylib"
} else {
	@(private = "file")
	YV_LIBRARY :: "libyap_video.so"
}

// A view decodes one stream (Video_Key). There is one for each stream that can
// be watched at once (VIDEO_INS), made the first time it's needed and kept as
// long as the process lives: a view that isn't decoding anything holds next to
// nothing (yv_view_clear).
@(private = "file")
View_Slot :: struct {
	// What it decodes, {} while it's free, and how often it was given a
	// stream (under views_mu).
	key:      Video_Key,
	used:     u64,
	view:     rawptr,
	// When the UI last drew it (take_view).
	drawn_at: time.Tick,
	// The UI thread's handle on the picture it last gave us, and that
	// picture's statistics (video_picture_info).
	picture:  render.Gpu_Texture,
	wrapped:  uintptr,
	frames:   u64,
	hardware: bool,
}

// A share of one of our streams: the screen, or our camera.
@(private = "file")
Share_Slot :: struct {
	share:  rawptr,
	kbit:   int, // the bitrate it was set to encode at (atomic)
	codecs: u8, // the codecs its viewers decode (Video_Codecs; atomic)
}

// How often the cameras are counted again while there's none (video_can_camera).
@(private = "file")
CAMERAS_AGAIN :: 10 * time.Second

@(private = "file")
Native_Video :: struct {
	once:          sync.Once,
	loaded:        bool, // everything below is set up
	yv:            Yv,
	ctx:           rawptr,
	logger:        runtime.Logger,
	// The views, which the network threads give streams to and the UI thread
	// presents.
	views_mu:      sync.Mutex,
	views:         [VIDEO_INS]View_Slot,
	// The UI thread's state: whether the library has the renderer's device.
	gpu_set:       bool,
	full:          bool, // video_set_fullscreen
	// Sharing. The shares are started and stopped by the UI and pulled from by
	// a network thread, so they are only touched under `share_mu`.
	encoder_ok:    bool, // atomic: at least one encoder works (probe_encoders)
	encoders_done: bool, // atomic: probe_encoders has tried all encoders
	share_mu:      sync.Mutex,
	shares:        [proto.Video_Stream]Share_Slot,
	asked:         bool, // UI thread only: video_allow_capture has shown the prompt
	// The UI thread's: the camera's shares that were turned off, until the
	// frame that may still draw their preview has been drawn
	// (video_frame_done), and the preview's texture.
	retired:       [dynamic]rawptr,
	preview:       render.Gpu_Texture,
	preview_of:    uintptr, // the library's texture `preview` wraps
	// How many cameras there are (atomic), when they were last counted (UI
	// thread), and whether they are being counted (atomic; list_cameras).
	cameras:       int,
	cameras_at:    time.Tick,
	listing:       bool,
	// Wakes the UI for each new picture (video_set_wake; atomic).
	wake:          proc "c" (),
}

@(private = "file")
nv: Native_Video

// loaded loads the library the first time it is asked for, from any thread.
@(private = "file")
loaded :: proc() -> bool {
	sync.once_do(&nv.once, load)
	return nv.loaded
}

@(private = "file")
load :: proc() {
	nv.logger = context.logger
	dir, err := os.get_executable_directory(context.temp_allocator)
	if err != nil {
		return
	}
	path, _ := filepath.join({dir, YV_LIBRARY}, context.temp_allocator)
	if !os.exists(path) {
		log.debugf("video: no %s, so no screen sharing", path)
		return
	}
	count, ok := dynlib.initialize_symbols(&nv.yv, path, "yv_")
	if !ok {
		log.warnf("video: can't load %s: %s", path, dynlib.last_error())
		return
	}
	if count != YV_PROCS || nv.yv.api_version() != YV_API_VERSION {
		log.warnf(
			"video: %s is of another version (API %d, wanted %d)",
			path,
			nv.yv.api_version() if nv.yv.api_version != nil else 0,
			YV_API_VERSION,
		)
		dynlib.unload_library(nv.yv.__handle)
		nv.yv = {}
		return
	}
	init := Yv_Init {
		api_version = YV_API_VERSION,
		log         = yv_log,
		log_level   = 0 if context.logger.lowest_level <= .Debug else 1,
	}
	nv.ctx = nv.yv.create(&init)
	if nv.ctx == nil {
		return
	}
	nv.loaded = true
	log.infof("video: yap_video %s", nv.yv.version_string())
	thread.run(probe_encoders, context)
}

// probe_encoders finds out, off the UI thread, whether anything can be captured
// and any encoder works here. The library remembers which. The cameras are
// counted first.
@(private = "file")
probe_encoders :: proc() {
	sync.atomic_store(&nv.listing, true)
	list_cameras()
	if !nv.yv.capture_allowed(nv.ctx, false) {
		log.info("video: capturing isn't allowed yet; the share menu asks")
	} else if nv.yv.list_sources(nv.ctx, nil, 0) == 0 && sync.atomic_load(&nv.cameras) == 0 {
		log.info("video: nothing to capture here (yet), so no sharing")
		return
	}
	n := nv.yv.list_encoders(nv.ctx, nil, 0)
	sync.atomic_store(&nv.encoders_done, true)
	list := make([]Yv_Encoder, n, context.temp_allocator)
	n = nv.yv.list_encoders(nv.ctx, raw_data(list), n)
	for &e in list[:n] {
		if e.works {
			log.infof("video: sharing with %s", cstring(&e.label[0]))
			sync.atomic_store(&nv.encoder_ok, true)
			return
		}
	}
	log.info("video: no encoder works here, so no sharing")
}

// list_cameras counts the cameras, which can take a moment, so it's done on a
// thread of its own, with `listing` set until it's done. The UI is woken if
// the count changed, for the camera button to come or go.
@(private = "file")
list_cameras :: proc() {
	n := int(nv.yv.list_cameras(nv.ctx, nil, 0))
	if sync.atomic_exchange(&nv.cameras, n) != n {
		log.infof("video: %d camera(s)", n)
		if wake := sync.atomic_load(&nv.wake); wake != nil {
			wake()
		}
	}
	sync.atomic_store(&nv.listing, false)
}

// on_frame is called by the library, from its decoder's thread, when there is a new picture.
@(private = "file")
on_frame :: proc "c" (user: rawptr) {
	if wake := sync.atomic_load(&nv.wake); wake != nil {
		wake()
	}
}

// video_set_wake has the UI woken whenever there is a new picture to draw,
// rather than the UI looking for one every frame.
video_set_wake :: proc(wake: proc "c" ()) {
	sync.atomic_store(&nv.wake, wake)
}

// The library's log, which may be called from any of its threads.
@(private = "file")
yv_log :: proc "c" (user: rawptr, level: i32, msg: cstring) {
	context = runtime.default_context()
	context.logger = nv.logger
	switch level {
	case 0:
		log.debugf("yap_video: %s", msg)
	case 1:
		log.infof("yap_video: %s", msg)
	case 2:
		log.warnf("yap_video: %s", msg)
	case:
		log.errorf("yap_video: %s", msg)
	}
}

// A native share has no audio of its own: an application's is shared on its
// own (ui_app_audio_native.odin), and owns the voice's app ring.
video_capture_audio :: proc(v: ^audio.Voice, sharing: bool) {}

video_capture_live :: proc(stream: proto.Video_Stream) -> bool {
	return share_state(stream) == .Live
}

// video_capture_pull returns the next encoded frame of a stream, which the
// caller then owns. Called from the network thread.
video_capture_pull :: proc(
	stream: proto.Video_Stream,
) -> (
	data: []u8,
	ts: u32,
	key: bool,
	codec: proto.Video_Codec,
	ok: bool,
) {
	if !nv.loaded {
		return
	}
	sync.guard(&nv.share_mu)
	p: Yv_Packet
	share := nv.shares[stream].share
	if share == nil || !nv.yv.share_pull(share, &p) || p.size == 0 {
		return
	}
	data = make([]u8, p.size)
	copy(data, p.data[:p.size])
	// Milliseconds, wrapping around: only differences matter.
	return data, u32(p.pts_us / 1000), p.key, proto.Video_Codec(p.codec), true
}

video_capture_request_key :: proc(stream: proto.Video_Stream) {
	if !nv.loaded {
		return
	}
	sync.guard(&nv.share_mu)
	if share := nv.shares[stream].share; share != nil {
		nv.yv.share_request_key(share)
	}
}

// find_view returns the view that decodes `key`, or nil if it has none (yet).
// The view stays valid, but may be given another stream after video_show_end.
@(private = "file")
find_view :: proc(key: Video_Key) -> rawptr {
	sync.guard(&nv.views_mu)
	for slot in nv.views {
		if slot.key == key {
			return slot.view
		}
	}
	return nil
}

// take_view gives `key` a view of its own, making one if no free one has been
// made yet. A view takes the renderer's device when it is made, so this is
// done on the UI thread, by video_picture. With none free, the one drawn
// longest ago is taken, if that was over VIEW_UNUSED ago: the UI may have drawn
// a stream once more after it ended. Nil if there is none.
@(private = "file")
take_view :: proc(key: Video_Key) -> ^View_Slot {
	sync.guard(&nv.views_mu)
	free_slot, oldest: ^View_Slot
	for &slot in nv.views {
		if slot.key == key {
			return &slot
		}
		// One that has a view already, rather than making another.
		if slot.key == {} && (free_slot == nil || free_slot.view == nil) {
			free_slot = &slot
		}
		if slot.key != {} &&
		   time.tick_since(slot.drawn_at) > VIEW_UNUSED &&
		   (oldest == nil || time.tick_diff(oldest.drawn_at, slot.drawn_at) < 0) {
			oldest = &slot
		}
	}
	if free_slot == nil && oldest != nil {
		nv.yv.view_clear(oldest.view)
		free_slot = oldest
	}
	if free_slot == nil {
		return nil
	}
	if free_slot.view == nil {
		free_slot.view = nv.yv.view_create(nv.ctx)
		if free_slot.view == nil {
			return nil
		}
		nv.yv.view_on_frame(free_slot.view, on_frame, nil)
	}
	free_slot.key = key
	free_slot.used += 1
	free_slot.drawn_at = time.tick_now()
	return free_slot
}

// How long a view goes undrawn before take_view may give it to another stream.
@(private = "file")
VIEW_UNUSED :: 5 * time.Second

// video_show_ready says whether a stream has a decoder to take its frames:
// the UI has started drawing it (video_picture). Until then its frames are
// dropped, and once it has, the next keyframe is what to start from.
video_show_ready :: proc(key: Video_Key) -> bool {
	return loaded() && find_view(key) != nil
}

// video_show_frame hands a whole frame of a stream to its decoder. Called from
// a network thread.
video_show_frame :: proc(key: Video_Key, frame: proto.Video_Frame) {
	if !loaded() || len(frame.data) == 0 || u8(frame.codec) > 2 {
		return
	}
	view := find_view(key)
	if view == nil {
		return
	}
	nv.yv.view_push(
		view,
		raw_data(frame.data),
		uint(len(frame.data)),
		i32(frame.codec),
		u64(frame.ts) * 1000,
		frame.key,
	)
}

// video_show_end drops what a stream's decoder has, and its view.
video_show_end :: proc(key: Video_Key) {
	if !loaded() {
		return
	}
	sync.guard(&nv.views_mu)
	for &slot in nv.views {
		if slot.key == key {
			nv.yv.view_clear(slot.view)
			slot.key = {}
		}
	}
}

// video_show_failed says, once, that a stream's decoder gave up on what it was
// given. It needs a keyframe to start again.
video_show_failed :: proc(key: Video_Key) -> bool {
	if !loaded() {
		return false
	}
	view := find_view(key)
	return view != nil && nv.yv.view_take_failed(view)
}

Share_State :: enum i32 {
	Off,
	Starting,
	Live,
	Failed,
}

video_can_share :: proc() -> bool {
	return loaded() && sync.atomic_load(&nv.encoder_ok)
}

video_can_watch :: proc() -> bool {
	return loaded()
}

// The library's decoders handle every codec (view.cpp).
video_decodable :: proc() -> proto.Video_Codecs {
	return {.H264, .HEVC, .AV1} if loaded() else {}
}

// video_share_codecs says what the share's viewers can decode (video.odin).
// It is called from the network thread as viewers come and go, and a share that
// is started later starts with it too.
video_share_codecs :: proc(stream: proto.Video_Stream, codecs: proto.Video_Codecs) {
	bits := transmute(u8)codecs
	if sync.atomic_exchange(&nv.shares[stream].codecs, bits) == bits || !loaded() {
		return
	}
	sync.guard(&nv.share_mu)
	if share := nv.shares[stream].share; share != nil {
		nv.yv.share_set_codecs(share, u32(bits))
	}
}

// The desktop asks what to share (video_sources) before starting, while the
// browser asks in its own picker.
VIDEO_PICKER :: true

// video_capture_allowed says whether the system lets us capture the screen.
// Only macOS asks the user. Called from the UI thread.
video_capture_allowed :: proc() -> bool {
	return loaded() && nv.yv.capture_allowed(nv.ctx, false)
}

// video_allow_capture asks for that permission. macOS shows its prompt only the
// first time, so after that it opens the settings page instead. Once allowed,
// yap has to be restarted before the permission takes effect. Called from the
// UI thread.
video_allow_capture :: proc() {
	if !loaded() {
		return
	}
	if !nv.asked {
		nv.asked = true
		// The prompt, which has its own button for the settings.
		nv.yv.capture_allowed(nv.ctx, true)
		return
	}
	nv.yv.open_capture_settings(nv.ctx)
}

Video_Source_Kind :: enum {
	Monitor,
	Window,
}

Video_Source :: struct {
	kind:          Video_Source_Kind,
	id:            u64,
	name:          string,
	app:           string, // a window's program or a monitor's device
	width, height: int,
	primary:       bool,
}

// video_sources lists the monitors (first) and the windows that can be shared,
// allocated with `allocator`.
video_sources :: proc(allocator := context.temp_allocator) -> []Video_Source {
	if !loaded() {
		return nil
	}
	n := nv.yv.list_sources(nv.ctx, nil, 0)
	raw := make([]Yv_Source, n, context.temp_allocator)
	n = nv.yv.list_sources(nv.ctx, raw_data(raw), n)
	out := make([]Video_Source, n, allocator)
	for &r, i in raw[:n] {
		out[i] = {
			kind    = .Window if r.kind == 1 else .Monitor,
			id      = r.id,
			name    = strings.clone_from_cstring(cstring(&r.name[0]), allocator),
			app     = strings.clone_from_cstring(cstring(&r.app[0]), allocator),
			width   = int(r.width),
			height  = int(r.height),
			primary = r.primary,
		}
	}
	return out
}

// video_share_source starts sharing `src` as `config` says, replacing whatever
// was shared before. Where the system picks the source (video_system_picker),
// `src` is {} and the system asks.
video_share_source :: proc(src: Video_Source, config: Share_Config) {
	if !video_can_share() {
		return
	}
	video_share_stop()
	cfg := Yv_Share_Config {
		kind       = 1 if src.kind == .Window else 0,
		source     = src.id,
		fps        = i32(config.fps),
		max_width  = config.max.x,
		max_height = config.max.y,
		kbit       = u32(config.kbit),
		cursor     = config.cursor,
		codecs     = u32(sync.atomic_load(&nv.shares[.Screen].codecs)),
	}
	copy(cfg.encoder[:len(cfg.encoder) - 1], config.encoder)
	share_took(.Screen, nv.yv.share_start(nv.ctx, &cfg), config.kbit)
	log.infof(
		"video: sharing %s at %d fps, %d kbit/s%s%s",
		src.name if src.id != 0 else "what the system's picker gives",
		config.fps,
		config.kbit,
		", with " if config.encoder != "" else "",
		config.encoder,
	)
}

// video_share_kbit is the bitrate the share encodes at, used for pacing it
// (video.odin). It is 0 while there is no share. This is what the encoder
// runs at, not what video_share_adapt last asked for: the library takes that
// up only some seconds later, if at all, and pacing below what the encoder
// makes in the meantime builds up a queue.
video_share_kbit :: proc(stream: proto.Video_Stream) -> int {
	if share_state(stream) == .Off {
		return 0
	}
	sync.guard(&nv.share_mu)
	share := nv.shares[stream].share
	return int(nv.yv.share_get_bitrate(share)) if share != nil else 0
}

// video_share_max_kbit is the bitrate the share was set to encode at, which
// adapting never goes above. It is 0 while there is no share.
video_share_max_kbit :: proc(stream: proto.Video_Stream) -> int {
	if share_state(stream) == .Off {
		return 0
	}
	return sync.atomic_load(&nv.shares[stream].kbit)
}

// video_share_adapt holds a stream to `kbit` for its viewers (video.odin).
// Called from the network thread.
video_share_adapt :: proc(stream: proto.Video_Stream, kbit: int) {
	if !nv.loaded {
		return
	}
	sync.guard(&nv.share_mu)
	if share := nv.shares[stream].share; share != nil {
		nv.yv.share_set_bitrate(share, u32(kbit))
	}
}

// share_took makes `share` (nil if it didn't start) the share of `stream`,
// set to encode at `kbit`.
@(private = "file")
share_took :: proc(stream: proto.Video_Stream, share: rawptr, kbit: int) {
	sync.guard(&nv.share_mu)
	nv.shares[stream].share = share
	if share != nil {
		// In case the viewers have changed since it was started (video_share_codecs).
		nv.yv.share_set_codecs(share, u32(sync.atomic_load(&nv.shares[stream].codecs)))
	}
	sync.atomic_store(&nv.shares[stream].kbit, kbit)
}

// share_take takes the share of `stream` away from the network thread, which
// then has nothing more to pull: nil if there was none.
@(private = "file")
share_take :: proc(stream: proto.Video_Stream) -> (share: rawptr) {
	sync.guard(&nv.share_mu)
	share, nv.shares[stream].share = nv.shares[stream].share, nil
	return
}

// video_library_dir is the directory the library is looked for in: next to the executable.
video_library_dir :: proc(allocator := context.temp_allocator) -> string {
	dir, err := os.get_executable_directory(allocator)
	return dir if err == nil else "the folder yap is in"
}

// video_system_picker says that the system asks what to share (Wayland's
// portal, macOS 15's picker) rather than our menu.
video_system_picker :: proc() -> bool {
	return loaded() && nv.yv.system_picker(nv.ctx)
}

Video_Encoder :: struct {
	name:  string, // what settings.share_encoder stores
	label: string,
	works: bool,
}

// video_encoders lists the library's encoders, best first, allocated with
// `allocator`. It is empty until the encoders have been tried (probe_encoders).
video_encoders :: proc(allocator := context.temp_allocator) -> []Video_Encoder {
	if !loaded() || !sync.atomic_load(&nv.encoders_done) {
		return nil
	}
	n := nv.yv.list_encoders(nv.ctx, nil, 0)
	raw := make([]Yv_Encoder, n, context.temp_allocator)
	n = nv.yv.list_encoders(nv.ctx, raw_data(raw), n)
	out := make([]Video_Encoder, n, allocator)
	for &e, i in raw[:n] {
		out[i] = {
			name  = strings.clone_from_cstring(cstring(&e.name[0]), allocator),
			label = strings.clone_from_cstring(cstring(&e.label[0]), allocator),
			works = e.works,
		}
	}
	return out
}

// The browser's way of sharing, which on the desktop needs a source: see
// video_share_source.
video_share_start :: proc(config: Share_Config) {}

// video_can_camera says whether our camera can be turned on: there is a camera
// and an encoder that works. While there is none, the cameras are counted
// again now and then, for one that is plugged in later. Called from the UI
// thread.
video_can_camera :: proc() -> bool {
	if !loaded() {
		return false
	}
	if sync.atomic_load(&nv.cameras) == 0 &&
	   time.tick_since(nv.cameras_at) > CAMERAS_AGAIN &&
	   !sync.atomic_exchange(&nv.listing, true) {
		nv.cameras_at = time.tick_now()
		thread.run(list_cameras, context)
	}
	return sync.atomic_load(&nv.cameras) > 0 && sync.atomic_load(&nv.encoder_ok)
}

// video_camera_start turns on the camera `device` (a Yv_Camera id; "" for the
// first) as `config` says, replacing a camera that was on. Called from the UI
// thread.
video_camera_start :: proc(config: Share_Config, device := "") {
	if !video_can_camera() {
		return
	}
	video_camera_stop()
	cfg := Yv_Camera_Config {
		fps        = i32(config.fps),
		max_width  = config.max.x,
		max_height = config.max.y,
		kbit       = u32(config.kbit),
		codecs     = u32(sync.atomic_load(&nv.shares[.Camera].codecs)),
	}
	copy(cfg.camera[:len(cfg.camera) - 1], device)
	copy(cfg.encoder[:len(cfg.encoder) - 1], config.encoder)
	share_took(.Camera, nv.yv.camera_start(nv.ctx, &cfg), config.kbit)
	log.infof(
		"video: camera at %d fps, %d kbit/s, at most %dx%d",
		config.fps,
		config.kbit,
		config.max.x,
		config.max.y,
	)
}

// video_camera_stop turns the camera off. The network thread has nothing more
// to send at once, but the share itself is stopped once the frame being drawn
// is done (video_frame_done), since that may still draw its preview. Called
// from the UI thread.
video_camera_stop :: proc() {
	if !nv.loaded {
		return
	}
	share := share_take(.Camera)
	if share == nil {
		return
	}
	append(&nv.retired, share)
	log.info("video: camera off")
}

// video_camera_configure has the camera go on as `config` says (its size,
// frame rate and bitrate), from a keyframe: the room's tier changed
// (video.odin). Called from the network thread.
video_camera_configure :: proc(config: Share_Config) {
	if !nv.loaded {
		return
	}
	sync.guard(&nv.share_mu)
	if share := nv.shares[.Camera].share; share != nil {
		nv.yv.share_configure(share, i32(config.fps), config.max.x, config.max.y, u32(config.kbit))
		sync.atomic_store(&nv.shares[.Camera].kbit, config.kbit)
	}
}

video_camera_state :: proc() -> Share_State {
	return share_state(.Camera)
}

// video_camera_error says why the camera failed. The result is in the temp
// allocator.
video_camera_error :: proc() -> string {
	return share_error(.Camera)
}

// video_camera_preview is the newest frame of our own camera as it is sent
// (not mirrored), for the self view, valid until the next call or
// video_forget_gpu. Called from the UI thread, with the renderer's device up.
video_camera_preview :: proc(
	g: ^render.Gpu,
) -> (
	texture: render.Gpu_Texture,
	width, height: int,
	ok: bool,
) {
	// While a camera is being let go of, its preview may still be drawn this
	// frame, so it's kept as it is until video_frame_done.
	if !nv.loaded || len(nv.retired) > 0 {
		return
	}
	ensure_gpu(g)
	// Only the UI thread starts and stops it, so it stays while this runs.
	share: rawptr
	{
		sync.guard(&nv.share_mu)
		share = nv.shares[.Camera].share
	}
	pic: Yv_Picture
	if share == nil || !nv.yv.share_preview(share, &pic) || pic.texture == 0 {
		return
	}
	if pic.texture != nv.preview_of {
		render.gpu_texture_unwrap(g, &nv.preview)
		nv.preview = render.gpu_texture_wrap(g, pic.texture)
		nv.preview_of = pic.texture
	}
	return nv.preview, int(pic.width), int(pic.height), true
}

// video_frame_done is called once a frame has been drawn: a camera turned off
// while it was laid out is stopped now that nothing draws its preview. This
// may take a moment, since it waits for the camera's thread. Called from the
// UI thread.
video_frame_done :: proc() {
	if len(nv.retired) == 0 {
		return
	}
	// The wrapper only (no renderer needed); the share frees the texture.
	render.gpu_texture_unwrap(nil, &nv.preview)
	nv.preview_of = 0
	for share in nv.retired {
		nv.yv.share_stop(share)
	}
	clear(&nv.retired)
}

video_share_stop :: proc() {
	if !nv.loaded {
		return
	}
	if share := share_take(.Screen); share != nil {
		// This may take a moment because it waits for its thread. Nobody else
		// can reach it any more.
		nv.yv.share_stop(share)
		log.info("video: stopped sharing")
	}
}

video_share_state :: proc() -> Share_State {
	return share_state(.Screen)
}

@(private = "file")
share_state :: proc(stream: proto.Video_Stream) -> Share_State {
	if !nv.loaded {
		return .Off
	}
	sync.guard(&nv.share_mu)
	share := nv.shares[stream].share
	if share == nil {
		return .Off
	}
	switch nv.yv.share_get_state(share) {
	case YV_SHARE_STARTING:
		return .Starting
	case YV_SHARE_LIVE:
		return .Live
	case YV_SHARE_CANCELLED:
		return .Off // the user cancelled in the system's picker
	}
	return .Failed
}

// video_share_error says why sharing failed. The result is in the temp allocator.
video_share_error :: proc() -> string {
	return share_error(.Screen)
}

@(private = "file")
share_error :: proc(stream: proto.Video_Stream) -> string {
	if !nv.loaded {
		return ""
	}
	sync.guard(&nv.share_mu)
	share := nv.shares[stream].share
	if share == nil {
		return ""
	}
	return strings.clone_from_cstring(nv.yv.share_error(share), context.temp_allocator)
}

// video_picture is the newest frame of a stream we are watching, as a texture
// of the renderer's, valid until the next call for that stream or
// video_forget_gpu. Called from the UI thread, with the renderer's device up.
video_picture :: proc(
	g: ^render.Gpu,
	key: Video_Key,
) -> (
	texture: render.Gpu_Texture,
	width, height: int,
	ok: bool,
) {
	if !loaded() || key.user == 0 {
		return
	}
	ensure_gpu(g)
	// Presenting can take a moment, so it is done without the lock. If the
	// view was given to another stream meanwhile, its picture is not ours.
	slot, used := find_slot(key)
	if slot == nil {
		// The first time this stream is drawn: from now on its frames are
		// decoded (video_show_ready).
		if take_view(key) == nil {
			log.warnf("video: no view free for %v", key)
		}
		return
	}
	slot.drawn_at = time.tick_now()
	pic: Yv_Picture
	if !nv.yv.view_present(slot.view, &pic) || pic.texture == 0 {
		return
	}
	if again, again_used := find_slot(key); again != slot || again_used != used {
		return
	}
	slot.frames, slot.hardware = pic.frames, pic.hardware
	if pic.texture != slot.wrapped {
		render.gpu_texture_unwrap(g, &slot.picture)
		slot.picture = render.gpu_texture_wrap(g, pic.texture)
		slot.wrapped = pic.texture
	}
	return slot.picture, int(pic.width), int(pic.height), true
}

// ensure_gpu hands the library the renderer's device, the first time a picture
// is asked for. Called from the UI thread.
@(private = "file")
ensure_gpu :: proc(g: ^render.Gpu) {
	if nv.gpu_set {
		return
	}
	native := render.gpu_native(g)
	gpu := Yv_Gpu {
		d3d11_device = native.d3d11_device,
		gl_get_proc  = native.gl_get_proc,
		metal_device = native.metal_device,
		metal_queue  = native.metal_queue,
	}
	switch {
	case native.d3d11_device != nil:
		gpu.kind = 1
	case native.gl_get_proc != nil:
		gpu.kind = 2
	case native.metal_device != nil:
		gpu.kind = 3
	}
	nv.yv.set_gpu(nv.ctx, &gpu)
	nv.gpu_set = true
}

// find_slot returns the slot of the view that decodes `key`, and how often it
// had been given a stream then, or nil.
@(private = "file")
find_slot :: proc(key: Video_Key) -> (slot: ^View_Slot, used: u64) {
	sync.guard(&nv.views_mu)
	for &s in nv.views {
		if s.key == key {
			return &s, s.used
		}
	}
	return
}

// video_picture_info describes the last picture video_picture gave of a
// stream: how many have been decoded so far, and whether by the GPU. Called
// from the UI thread.
video_picture_info :: proc(key: Video_Key) -> (frames: u64, hardware: bool) {
	if slot, _ := find_slot(key); slot != nil {
		return slot.frames, slot.hardware
	}
	return
}

// video_forget_gpu lets go of everything on the renderer's device, which is
// about to go away (or already has). Called from the UI thread.
video_forget_gpu :: proc(g: ^render.Gpu) {
	if !nv.loaded || !nv.gpu_set {
		return
	}
	for &s in nv.views {
		render.gpu_texture_unwrap(g, &s.picture)
		s.wrapped = 0
	}
	video_frame_done()
	render.gpu_texture_unwrap(g, &nv.preview)
	nv.preview_of = 0
	nv.yv.set_gpu(nv.ctx, nil)
	nv.gpu_set = false
}

// Fullscreen on the desktop means the picture fills the window (ui_video.odin),
// not that the window fills the screen.
video_set_fullscreen :: proc(on: bool) {
	nv.full = on
}

video_is_fullscreen :: proc() -> bool {
	return nv.full
}

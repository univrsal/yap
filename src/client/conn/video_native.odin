#+build !wasi
package conn

import "base:runtime"
import "core:dynlib"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"

import "client:render"
import "common:proto"
import log "common:wlog"

/*
Screen sharing on the desktop comes from an optional library, yap_video
(src/video, misc/hq-share/README.md), loaded from next to the executable
the first time anything here is asked. Without it, or with one of
another version, the client neither shares nor watches, as before; it
still shows who is sharing.

The library decodes on threads of its own and keeps the newest picture
on the GPU, made for our renderer's device (video_picture); frames are
pushed from the network thread (video_show_frame).

Sharing: the UI picks a monitor or window (video_sources,
video_share_source), and the library captures and encodes it on a
thread of its own; the network thread pulls the encoded frames
(video_capture_pull). Which encoders work is found out on a thread of
our own as the library loads, since trying them takes a moment; until
then, and if none does, video_can_share says no. There's one share for
the whole client, like the browser's.

On macOS the user has to allow Screen Recording first. Until they have,
sharing is still offered, and the menu asks for it
(video_capture_allowed, video_allow_capture) instead of listing
anything.
*/

// What this was built against: src/video/include/yap_video.h.
@(private = "file")
YV_API_VERSION :: 5

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
	kind:         i32, // 0 none, 1 D3D11, 2 GL
	d3d11_device: rawptr,
	gl_get_proc:  rawptr,
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
}

@(private = "file")
Yv_Packet :: struct {
	data:   [^]u8,
	size:   uint,
	pts_us: u64,
	codec:  i32,
	key:    bool,
}

// yv_share_state's values.
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
	share_get_state:       proc "c" (share: rawptr) -> i32,
	share_error:           proc "c" (share: rawptr) -> cstring,
	share_stop:            proc "c" (share: rawptr),
	capture_allowed:       proc "c" (ctx: rawptr, ask: bool) -> bool,
	open_capture_settings: proc "c" (ctx: rawptr) -> bool,
	system_picker:         proc "c" (ctx: rawptr) -> bool,
	view_on_frame:         proc "c" (view: rawptr, fn: proc "c" (user: rawptr), user: rawptr),
	__handle:              dynlib.Library,
}

@(private = "file")
YV_PROCS :: 22

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

@(private = "file")
Native_Video :: struct {
	once:          sync.Once,
	loaded:        bool, // all of the below is there
	yv:            Yv,
	ctx:           rawptr,
	view:          rawptr, // the one we watch with; it lives as long as the process
	logger:        runtime.Logger,
	// Whose frames the view is decoding (atomic: network threads).
	sharer:        proto.User_Num,
	// The UI thread's: whether the library has the renderer's device,
	// and our handle on the picture it last gave us.
	gpu_set:       bool,
	picture:       render.Gpu_Texture,
	wrapped:       uintptr,
	full:          bool, // video_set_fullscreen
	// Sharing. `share` is started and stopped by the UI and pulled from
	// by a network thread, so it's only touched under `share_mu`.
	encoder_ok:    bool, // atomic: an encoder works (probe_encoders)
	encoders_done: bool, // atomic: probe_encoders has tried them
	share_mu:      sync.Mutex,
	share:         rawptr,
	share_kbit:    int, // what it was set to encode at (atomic)
	share_target:  int, // what it's held to for its viewers, 0 for that (atomic)
	asked:         bool, // the UI's: video_allow_capture showed the prompt
	// The UI's waking (video_set_wake; atomic), for each new picture.
	wake:          proc "c" (),
	// The last picture's, for the figures (video_picture_info).
	frames:        u64,
	hardware:      bool,
}

@(private = "file")
nv: Native_Video

// loaded loads the library, the first time it's asked from any thread.
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
	nv.view = nv.yv.view_create(nv.ctx)
	if nv.view == nil {
		return
	}
	nv.yv.view_on_frame(nv.view, on_frame, nil)
	nv.loaded = true
	log.infof("video: yap_video %s", nv.yv.version_string())
	thread.run(probe_encoders, context)
}

// probe_encoders finds out, off the UI's thread, whether anything can
// be captured and any encoder works here; the library remembers which.
@(private = "file")
probe_encoders :: proc() {
	if !nv.yv.capture_allowed(nv.ctx, false) {
		log.info("video: capturing isn't allowed yet; the share menu asks")
	} else if nv.yv.list_sources(nv.ctx, nil, 0) == 0 {
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

// on_frame: the library has a new picture, from its decoder's thread.
@(private = "file")
on_frame :: proc "c" (user: rawptr) {
	if wake := sync.atomic_load(&nv.wake); wake != nil {
		wake()
	}
}

// video_set_wake has the UI woken whenever there's a new picture to
// draw, rather than it looking for one every frame.
video_set_wake :: proc(wake: proc "c" ()) {
	sync.atomic_store(&nv.wake, wake)
}

// The library's log, from any of its threads.
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

video_capture_live :: proc() -> bool {
	return video_share_state() == .Live
}

// video_capture_pull returns the next encoded frame, which the caller
// then owns. From the network thread.
video_capture_pull :: proc(
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
	if nv.share == nil || !nv.yv.share_pull(nv.share, &p) || p.size == 0 {
		return
	}
	data = make([]u8, p.size)
	copy(data, p.data[:p.size])
	// Milliseconds, wrapping: only differences matter.
	return data, u32(p.pts_us / 1000), p.key, proto.Video_Codec(p.codec), true
}

video_capture_request_key :: proc() {
	if !nv.loaded {
		return
	}
	sync.guard(&nv.share_mu)
	if nv.share != nil {
		nv.yv.share_request_key(nv.share)
	}
}

// video_show_frame hands a whole frame to the decoder. From a network
// thread.
video_show_frame :: proc(sharer: proto.User_Num, frame: proto.Video_Frame) {
	if !loaded() || len(frame.data) == 0 || u8(frame.codec) > 2 {
		return
	}
	if sync.atomic_exchange(&nv.sharer, sharer) != sharer {
		nv.yv.view_clear(nv.view)
	}
	nv.yv.view_push(
		nv.view,
		raw_data(frame.data),
		uint(len(frame.data)),
		i32(frame.codec),
		u64(frame.ts) * 1000,
		frame.key,
	)
}

video_show_end :: proc() {
	if !loaded() {
		return
	}
	sync.atomic_store(&nv.sharer, 0)
	nv.yv.view_clear(nv.view)
}

// video_show_failed says, once, that the decoder gave up on what it was
// given; it needs a keyframe to start again.
video_show_failed :: proc() -> bool {
	return loaded() && nv.yv.view_take_failed(nv.view)
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

// The desktop asks what to share (video_sources) before starting; the
// browser asks in its own picker.
VIDEO_PICKER :: true

// video_capture_allowed says whether the system lets us capture the
// screen; only macOS asks the user. From the UI thread.
video_capture_allowed :: proc() -> bool {
	return loaded() && nv.yv.capture_allowed(nv.ctx, false)
}

/*
video_allow_capture asks for it: macOS shows its prompt only the first
time, so after that it opens the settings page instead. Once allowed,
yap has to be started again before it counts. From the UI thread.
*/
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
	app:           string, // a window's program, a monitor's device
	width, height: int,
	primary:       bool,
}

// video_sources lists the monitors (first) and windows that can be
// shared, in `allocator`.
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

/*
video_share_source starts sharing `src`, as `config` says, instead of
whatever was shared before. Where the system picks (video_system_picker),
`src` is {} and the system asks.
*/
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
	}
	copy(cfg.encoder[:len(cfg.encoder) - 1], config.encoder)
	share := nv.yv.share_start(nv.ctx, &cfg)
	sync.guard(&nv.share_mu)
	nv.share = share
	sync.atomic_store(&nv.share_kbit, config.kbit)
	sync.atomic_store(&nv.share_target, 0)
	log.infof(
		"video: sharing %s at %d fps, %d kbit/s%s%s",
		src.name if src.id != 0 else "what the system's picker gives",
		config.fps,
		config.kbit,
		", with " if config.encoder != "" else "",
		config.encoder,
	)
}

// video_share_kbit is what the share encodes at, for pacing it
// (video.odin); 0 while there's none.
video_share_kbit :: proc() -> int {
	if video_share_state() == .Off {
		return 0
	}
	if target := sync.atomic_load(&nv.share_target); target > 0 {
		return target
	}
	return sync.atomic_load(&nv.share_kbit)
}

// video_share_max_kbit is what the share was set to encode at, which
// adapting never goes over; 0 while there's none.
video_share_max_kbit :: proc() -> int {
	return sync.atomic_load(&nv.share_kbit) if video_share_state() != .Off else 0
}

// video_share_adapt holds the share to `kbit` for its viewers (video.odin).
// From the network thread.
video_share_adapt :: proc(kbit: int) {
	if !nv.loaded {
		return
	}
	sync.guard(&nv.share_mu)
	if nv.share != nil {
		nv.yv.share_set_bitrate(nv.share, u32(kbit))
		sync.atomic_store(&nv.share_target, kbit)
	}
}

// video_library_dir is where the library is looked for: next to us.
video_library_dir :: proc(allocator := context.temp_allocator) -> string {
	dir, err := os.get_executable_directory(allocator)
	return dir if err == nil else "the folder yap is in"
}

// video_system_picker says the system asks what to share (Wayland's
// portal, macOS 15's picker) rather than our menu.
video_system_picker :: proc() -> bool {
	return loaded() && nv.yv.system_picker(nv.ctx)
}

Video_Encoder :: struct {
	name:  string, // what settings.share_encoder stores
	label: string,
	works: bool,
}

// video_encoders lists the library's encoders, best first, in
// `allocator`; empty until it has tried them (probe_encoders).
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

// The browser's way, which on the desktop needs a source: see
// video_share_source.
video_share_start :: proc() {}

video_share_stop :: proc() {
	if !nv.loaded {
		return
	}
	share: rawptr
	{
		sync.guard(&nv.share_mu)
		share, nv.share = nv.share, nil
	}
	if share != nil {
		// It may take a moment, waiting for its thread; nobody else
		// can reach it any more.
		nv.yv.share_stop(share)
		log.info("video: stopped sharing")
	}
}

video_share_state :: proc() -> Share_State {
	if !nv.loaded {
		return .Off
	}
	sync.guard(&nv.share_mu)
	if nv.share == nil {
		return .Off
	}
	switch nv.yv.share_get_state(nv.share) {
	case YV_SHARE_STARTING:
		return .Starting
	case YV_SHARE_LIVE:
		return .Live
	case YV_SHARE_CANCELLED:
		return .Off // the user said no in the system's picker
	}
	return .Failed
}

// video_share_error says why sharing failed, in the temp allocator.
video_share_error :: proc() -> string {
	if !nv.loaded {
		return ""
	}
	sync.guard(&nv.share_mu)
	if nv.share == nil {
		return ""
	}
	return strings.clone_from_cstring(nv.yv.share_error(nv.share), context.temp_allocator)
}

/*
video_picture is the newest frame of what we're watching, as a texture
of the renderer's, until the next call or video_forget_gpu. From the UI
thread, with the renderer's device up.
*/
video_picture :: proc(
	g: ^render.Gpu,
) -> (
	texture: render.Gpu_Texture,
	width, height: int,
	ok: bool,
) {
	if !loaded() {
		return
	}
	if !nv.gpu_set {
		native := render.gpu_native(g)
		gpu := Yv_Gpu {
			d3d11_device = native.d3d11_device,
			gl_get_proc  = native.gl_get_proc,
		}
		gpu.kind = 1 if native.d3d11_device != nil else 2 if native.gl_get_proc != nil else 0
		nv.yv.set_gpu(nv.ctx, &gpu)
		nv.gpu_set = true
	}
	pic: Yv_Picture
	if !nv.yv.view_present(nv.view, &pic) || pic.texture == 0 {
		return
	}
	nv.frames, nv.hardware = pic.frames, pic.hardware
	if pic.texture != nv.wrapped {
		render.gpu_texture_unwrap(g, &nv.picture)
		nv.picture = render.gpu_texture_wrap(g, pic.texture)
		nv.wrapped = pic.texture
	}
	return nv.picture, int(pic.width), int(pic.height), true
}

// video_forget_gpu lets go of everything on the renderer's device, which
// is about to go (or has). From the UI thread.
// video_picture_info is about the last picture video_picture gave: how
// many have been decoded so far, and whether by the GPU. From the UI
// thread.
video_picture_info :: proc() -> (frames: u64, hardware: bool) {
	return nv.frames, nv.hardware
}

video_forget_gpu :: proc(g: ^render.Gpu) {
	if !nv.loaded || !nv.gpu_set {
		return
	}
	render.gpu_texture_unwrap(g, &nv.picture)
	nv.wrapped = 0
	nv.yv.set_gpu(nv.ctx, nil)
	nv.gpu_set = false
}

// Fullscreen on the desktop is the picture filling the window
// (ui_video.odin), not the window filling the screen.
video_set_fullscreen :: proc(on: bool) {
	nv.full = on
}

video_is_fullscreen :: proc() -> bool {
	return nv.full
}

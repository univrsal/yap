# Video chat: plan

Cameras in DM calls and in voice channels, built on what screen sharing
already has (`docs/design/hq-share.md`): the media link, the server's relay and
Nack cache, the viewers' reports, `yap_video` on the desktop and
WebCodecs in the browser. Nothing here is built yet. As in `docs/design/next.md`,
each phase is its own commit or series of commits; what turns out
differently is written under it when it's done ("*As built:*"), and the
open questions are in the Decisions table at the end.

Sizes: S up to about 300 changed lines, M up to
1000, L up to 2500, XL more.

## What we start from

- **Video is per user, not per stream.** A fragment is
  `[sharer u32][frame u32][ts u32][index u16][count u16][flags u8][codec u8]`
  (`proto/video.odin`); `flags` uses one bit (`VIDEO_KEY`). Watch, Nack
  and Report name a `sharer u32`; Keyframe has no body at all. A user
  can have one stream, and a second (a camera beside a screen) couldn't
  be told apart.
- **A viewer watches one sharer.** On the server, `Media_Session` has
  one `watching`/`watch_until`, one `report`/`report_of`
  (`server/media.odin`). In the client, `Video_Client` has one
  `watching`, one `Video_Window`, one set of delay and loss figures
  (`conn/video.odin`), the native side one `yv_view`
  (`conn/video_native.odin`), the page one `VideoDecoder`
  (`web/video.js`). A grid of nine needs nine of each.
- **The server's state is per sharer.** `Media_Sharer` (token bucket,
  keyframe throttle, cache) is keyed by `User_Num`. The cache is
  `MEDIA_CACHE_SLOTS` (2048) full-size packets, about 2.4 MB per sharer
  once used: fine for one screen, 22 MB for nine cameras that need a
  tenth of it each.
- **Rooms already cover calls.** A call has a voice room of its own
  (`proto/calls.odin`, `call_room`), and the relay only checks "same
  room". Screen sharing in a call works today; cameras in a call need
  nothing special from the server.
- **Who shares is a user flag.** `Sharing` is set by the client with
  Sound (`set_sound`), and the server takes it as it comes
  (`sound_set`). `User_Flags` is a `bit_set[;u8]` with seven of eight
  bits used: one is left.
- **The pipeline after capture is the same for a camera.** Encoders,
  hardware or OpenH264, pacing, Nack, reports, `adapt_bitrate`,
  `yv_share_set_codecs`, the decoders and `yv_view_present` don't care
  where the picture came from. What's new is the capture itself, a
  picture of our own camera (self view), and many decoders at once.
- **The media link already goes through the web relay**
  (`/yap-media/`), so browsers can watch and send cameras the same way
  they do screens.

## Requirements

### Must

- **A camera button** beside Share, in a channel's voice room and in a
  call. Off by default, always; it goes off when leaving the room or
  the call.
- **DM calls in good quality.** 720p30 by default, 1080p30 if the camera
  and the settings allow it, adapting down when the network can't take
  it (as screens do). A **Video tab** beside Chat (and Screen) shows the
  other person large and our own camera small in a corner.
- **Voice channels: a grid.** A **Video tab** in the channel shows every
  camera in the room, our own included. At most `video.max_cameras`
  (default 9) cameras on at once per room; the tenth is told the room is
  full.
- **Quality follows the number of cameras** in the room, so that the
  grid fits an ordinary connection (see Quality).
- **Every platform**: Windows, Linux, macOS and the browser (desktop
  and phone).
- **Nothing for those not watching.** Video only flows to someone who
  has the Video tab open (or popped out), as with screens.
- **Old clients aren't harmed.** They don't see cameras, but nothing
  they receive changes.

### Should

- A camera and a screen at the same time.
- Pick the camera; a preview in the settings; mirror the self view.
- Talking shown on the tile (the voice panel's talking state).
- A tile can be focused (large, the others in a row) and the Video tab
  popped out and made fullscreen, like the Screen tab.
- Cameras paused when nobody watches them (see Demand, phase 10).

### Not now

- Peer-to-peer calls. Everything goes through the server, which costs
  one hop but needs no NAT traversal, keeps the Nack cache, and keeps
  one code path (D8).
- Background blur or replacement, effects, virtual cameras of our own.
- Simulcast (two sizes per camera, the server picking per viewer); see
  Later.
- Lip sync beyond measuring it (see Risks).
- Recording.

## Design

### Streams

A user has up to two streams: their screen and their camera. The
camera is told apart by a **bit in the fragment's flags byte**
(`VIDEO_CAMERA :: 1 << 1`), so the fragment header doesn't change and
the server's `video_up_to_down` still just puts the sharer in front
(D1).

| Message | Today | With cameras |
| --- | --- | --- |
| Video (both ways) | `flags` = key | `flags` = key \| camera |
| Watch | `[sharer u32][flags u8]` | flag `WATCH_CAMERA`; a lease per (sharer, stream) |
| Nack | `[sharer u32][frame u32][first u16][missing u64]` | `[stream u8]` appended |
| Report up | `[sharer u32][loss u16][delay u16][kbit u32]` | `[stream u8]` appended |
| Report down | `[viewers][left out][loss][delay][kbit]` | `[stream u8]` appended |
| Keyframe | `[kind]` | `[kind][stream u8]`; no byte means the screen |
| Demand (new, phase 10) | - | server → sharer: `[stream u8][width u16][height u16][viewers u16]`; Watch on a camera gains `[width u16][height u16]` where `Server_Info.demand` says so |

Messages are told apart by length, so the old ones still mean the
screen, and an old client never takes a camera lease, so it never gets
a camera fragment. `HELLO_VERSION` stays as it is: a different one
refuses the connection, which would lock old clients out (`Link.Media`
was added the same way, without a new version). A new client knows the
server understands cameras from `max_cameras` in `Server_Info`; an
older server doesn't send it, and there's no camera button.

A user's camera is announced by the last free User_Flag, **`Camera`**,
set with Sound like `Sharing` (D6). The server checks it in
`sound_set`: in a channel's room that already has `max_cameras`
cameras, the flag is cleared again, the change goes out in the next
snapshot as usual, and the client, seeing its flag not taken, says
"This channel already has 9 cameras on". A call's room allows two.

### Server

All in `server/media.odin`, no new thread:

- **Sharers keyed by (user, stream)**: `map[Stream_Key]Media_Sharer`.
  Budget, keyframe throttle, cache and reports per stream.
  `Media_Peer` gets `camera` beside `sharing`.
- **Leases per session**: a small array instead of one `watching`, up
  to `max_cameras + 1` (the cameras and one screen), each with its own
  `watch_until` and report. `media_relay` checks "does this session
  hold a live lease on (sharer, stream)". The scan over every session
  per fragment stays; at nine cameras of ~60 packets a second each and
  a few dozen sessions that's still a few hundred thousand cheap checks
  a second. A viewer list per stream is the fix if it ever shows up in
  `loop_stats`.
- **A cache sized by rate**: a camera's cache holds `cache_ms` of
  `camera_max_kbit` (256 slots, ~300 KB) instead of 2048.
- **Config**: `video { max_cameras: 9, camera_max_kbit: 4000 }`;
  `max_cameras: 0` turns cameras off. Both go in `Server_Info` so the
  client knows the limit and the rate before it shows the button.
- **What it costs the server.** Each camera goes to every other
  watcher in the room: cameras × (watchers − 1) × rate. Nine cameras
  at 450 kbit/s to nine watchers is about 32 Mbit/s out; add six more
  people watching without a camera and it's 56. An operator on a small
  uplink lowers `max_cameras`.

### Client, network side

`conn/video.odin` becomes "streams" rather than "the share and the
watched":

- **Outgoing**: a `Video_Out` per stream (screen, camera), each with
  its queue, frame numbers, keyframe state and `adapt_bitrate` figures.
  `video_send` takes fragments from both against one pace and one
  socket backlog, camera first (it's small, and late camera frames
  show more than late screen frames).
- **Incoming**: a `Video_In` per watched (user, stream): its lease,
  `Video_Window`, delay and loss figures, report. Leases for every
  stream the UI shows (`Watch_Command` takes a list); Nacks and Reports
  name the stream.
- **The library and the page get a view per stream.**
  `video_show_frame(sharer, stream, frame)`, `video_picture(sharer,
  stream)`; the native side keeps a small pool of `yv_view`s (made when
  a tile appears, kept for a few seconds after it goes, so that
  re-opening the tab is quick).

### Capture

A camera is a new kind of share in `yap_video`: the same `yv_share`
(pull, request_key, set_bitrate, set_codecs, state, stop), started from
a camera instead of a monitor. API version 9:

```c
typedef struct yv_camera {
	char id[256];   // what to pass back: a device path, symbolic link or unique ID
	char name[256]; // "Logitech C920"
	int32_t max_width, max_height, max_fps; // the best mode it offers
	bool front;     // a phone's or laptop's own camera, where that's known
} yv_camera;

YV_API int yv_list_cameras(yv_context *, yv_camera *out, int max);
YV_API bool yv_camera_allowed(yv_context *, bool ask); // macOS asks, Windows' privacy switch
YV_API yv_share *yv_camera_start(yv_context *, const yv_camera_config *);
// Fit within a new size and frame rate, e.g. when the room's tier
// changes; costs a keyframe.
YV_API void yv_share_set_size(yv_share *, int32_t max_w, int32_t max_h, int32_t fps);
// Our own camera as it was captured, before encoding, for the self
// view; from the thread of yv_set_gpu, like yv_view_present.
YV_API bool yv_share_preview(yv_share *, yv_picture *out);
```

| Platform | API | Formats | Notes |
| --- | --- | --- | --- |
| Windows | DirectShow, through OBS's libdshowcapture (LGPL, as dshowcapture.dll); Media Foundation was the plan, see phase 6 | NV12, I420, YUY2, MJPEG (FFmpeg's decoder), RGB | Windows' camera privacy switches are read from the registry: say where to turn them on. The Frame Server shares a camera with other apps. |
| Linux | V4L2 directly (`/dev/video*`, `VIDIOC_ENUM_FMT`, mmap buffers) | MJPEG (FFmpeg's `mjpeg`, or VA-API's JPEG decoder), YUYV, NV12 | Covers USB cameras everywhere. Intel IPU6 laptop cameras need libcamera, reachable through PipeWire: later (D5). |
| macOS | AVFoundation `AVCaptureSession`, `AVCaptureDevice.DiscoverySession` (Continuity Camera too) | NV12 `CVPixelBuffer` on an IOSurface, straight into VideoToolbox | The app's `Info.plist` needs `NSCameraUsageDescription`, or macOS kills the app on first use (`scripts/package/package-macos.sh`). |
| Browser | `getUserMedia({video: {deviceId, width, height, frameRate}})`, `enumerateDevices` | `VideoFrame`s, into the share's `VideoEncoder` | Labels only after permission is granted once. Phones: front camera by default, `facingMode` to switch. |

Most USB cameras give 720p and 1080p at 30fps only as MJPEG (YUYV is
limited by USB 2 bandwidth), so the decode step on Linux matters. A
software MJPEG decode of 1080p30 is a few percent of a core. FFmpeg's
trimmed build (hq-share phase 1) has to keep `mjpeg`.

The camera is mirrored only in the self view, never in what is sent.
Encoding is cheap at these sizes: OpenH264 handles 720p30 in software
easily, so cameras work where the GPU has no encoder. A screen and a
camera at once means two encoder sessions; NVIDIA's consumer limit is
eight these days, others have none worth worrying about.

### Quality

One stream goes to all of a camera's viewers, so the size has to suit
the grid everyone sees. Every client counts the cameras in its room
(the `Camera` flag) and picks the same tier, with no new protocol (D2):

| Cameras in the room | Size | fps | H.264 kbit/s | A viewer receives at most |
| --- | --- | --- | --- | --- |
| Call (2) | 1280×720 (1920×1080 on High) | 30 | 1800 (3500) | 1.8 (3.5) Mbit/s |
| 1–2 | 1280×720 | 30 | 1500 | 1.5 Mbit/s |
| 3–4 | 960×540 | 30 | 800 | 2.4 Mbit/s |
| 5–9 | 640×360 | 30 | 450 | 3.6 Mbit/s |
| 10–16 (if the operator allows) | 480×270 | 24 | 300 | 4.5 Mbit/s |

- Tile sizes back this up: a 3×3 grid in the chat's side of a 1080p
  window gets tiles of about 460×260, which 640×360 more than fills; a
  2×2 grid about 700×400, for 960×540.
- HEVC and AV1 get 70% of these rates, as screens do with
  `decodable_codecs`.
- A tier change costs a keyframe (`yv_share_set_size`), so going down
  happens at once and going up only after the count has stayed lower
  for 5 seconds; someone flicking their camera doesn't make everyone's
  encoder restart.
- `adapt_bitrate` keeps working underneath: the tier sets the ceiling,
  the reports bring it down when a viewer can't keep up, with the
  outlier rule as for screens.
- Up to 9 is about what an ordinary connection takes (3.6 Mbit/s down)
  and what decodes comfortably anywhere (nine 360p decoders is less
  work than one 1080p screen). The server's egress is the real limit
  (see Server); 16 is possible at 480×270, beyond that tiles are too
  small to be worth it.

**Demand (phase 10)** refines this with what viewers actually show.
The Watch lease gets the tile's size in pixels; the server tells each
camera the largest any of its viewers shows it at, and how many there
are (Demand, sent once a second like the report summary). The sharer
encodes at the smaller of its tier and that size, and **stops
encoding while nobody watches** (zero viewers): no uplink, no GPU, the
camera light stays on. A focused tile then gets its 720p while the
others stay at 360p, without anyone's downlink paying for nine 720p
streams. This is the same idea as an SFU's layer selection, with one
layer.

### UI

- **Camera button** beside Share in the voice panel, with the same
  states (off, starting, on, failed, not allowed). The channel list
  shows a camera icon by everyone whose camera is on, like the screen
  icon.
- **Calls.** The call bar gets "Video call" beside "Call", and the
  ringing callee "Answer with video" beside "Answer" (audio only
  unless chosen: answering never turns a camera on by itself). The
  Video tab opens by itself when the other person turns their camera
  on, as the Screen tab does when watching starts: them large, us in a
  corner (click to swap, drag to move between corners).
- **Channels.** The Video tab is shown while any camera in the room is
  on, labelled with the count ("Video (4)"), but not opened by itself
  (D7). It's a grid of 16:9 tiles: the column count that gives the
  largest tiles for the panel's shape, our own tile last, names under
  each, an outline while talking. Clicking a tile focuses it (large,
  the others in a row under it, scrolling), clicking it again goes back
  to the grid. Pop-out and fullscreen as for the screen.
- Only the tiles drawn hold leases; a tile scrolled out of the focused
  row lets its lease run out.
- **Settings, Camera**: which camera, quality (Auto, High for calls,
  Low), mirror my view, and a live preview while the category is open.
  On the web the picker appears after the first permission prompt.
- Watching cameras is open to everyone in the room, with or without a
  camera of their own (D4).

## Phases

| # | Phase | Size | Where | Depends on | Status |
| --- | --- | --- | --- | --- | --- |
| 1 | Streams in the protocol, the server: camera bit, stream bytes, leases, `Camera` flag and limit, config | M | protocol, server | - | done (2026-10-18): proto and server tests |
| 2 | The client's streams: `Video_Out`/`Video_In`, several leases, a view per stream | L | client (conn) | 1 | done (2026-10-18): conn tests; a browser's share watched by a desktop client |
| 3 | Cameras in the browser: getUserMedia, a second encoder, several decoders | M | web | 2 | done (2026-10-19): headless Chromium's fake camera to a headless client |
| 4 | Calls: camera button, Video tab with self view, video call / answer with video | M | client (UI) | 2, 3 | done (2026-10-19): browser to browser and browser to desktop, headless |
| 5 | Channels: the grid, tiers, focus, the full-room message, pop-out | M | client (UI) | 4 | done (2026-10-19): three headless browsers in a channel |
| 6 | `yap_video` cameras on Windows: DirectShow (libdshowcapture), `yv_share_preview`, `yv_share_configure` | L | library, client | 2 | done (2026-10-19): under wine, then by the owner on Windows (OBS's virtual camera to a Linux client) |
| 7 | Linux: V4L2, MJPEG | M | library | 6 | built (2026-10-19): OBS's v4l2loopback camera, in yv-loopback and the client |
| 8 | macOS: AVFoundation, `Info.plist` | M | library, scripts | 6 | built (2026-10-19): on the Mac mini with the fake camera, the client by the owner; no real camera there yet |
| 9 | Settings: camera, quality, mirror, preview | S | client | 4, 6 | done (2026-10-19): headless Edge's fake camera; the owner on macOS (fake camera) and Windows (OBS) |
| 10 | Demand: viewers' tile sizes, pausing unwatched cameras | M | protocol, server, client | 5 | built (2026-10-19): two headless Edges; the library's pause in yv-loopback on the Mac |

Why this order:

- **1 → 2 first**: everything else stands on several streams per user
  and several per viewer, and both are testable without a camera
  (proto, conn and server tests, as hq-share did; a fake stream from
  `stream_file`).
- **3 before 6**: the browser has the camera, the encoder and the
  decoder already, so it gets cameras working end to end with the
  least new code, and headless Chromium's fake camera
  (`--use-fake-device-for-media-stream`) lets it be tested here without
  hardware. The UI phases then have something real to show.
- **4 before 5**: a call is two streams and no tiers; the grid adds
  layout and quality rules on top.
- **6 → 7, 8**: as with screens, Windows settles the library's shape
  first; Linux and macOS can then go in parallel.
- **10 last**: it's about cost, not about it working, and it's easier
  to judge once real grids can be measured.

### 1. Streams in the protocol, the server

*As built:*

- **Protocol** (`proto/video.odin`, `video_window.odin`,
  `video_report.odin`, `messages.odin`, `rpc.odin`):
  - `Video_Stream` (`Screen = 0`, `Camera = 1`) is the stream byte;
    `Video_Fragment.stream` comes from `VIDEO_CAMERA` (flags bit 1).
  - Keyframe, Nack and Report end with the stream byte for a camera
    only (`KEYFRAME_CAMERA_SIZE`, `NACK_CAMERA_SIZE`,
    `REPORT_CAMERA_SIZE`); without it they're about the screen, so
    they're byte for byte what they were. `message_kind` takes both
    sizes; an older client drops the longer ones.
  - Watch keeps its size: `WATCH_CAMERA` (bit 1) and, not in the plan,
    `WATCH_STOP` (bit 2) to end one lease at once (a grid's tile going
    away shouldn't keep a camera coming for 3 seconds). Sharer 0 still
    ends "every lease", now of that kind of stream; an old client's
    Watch 0 ends the screen as before. `decode_watch` returns a
    `Watch` struct.
  - `User_Flag.Camera` is bit 7, the last.
  - `Server_Info` ends with `max_cameras u8` and `camera_kbit u32`,
    after the push key; an older server's info ends before, which
    reads as 0 cameras. `MAX_CAMERAS :: 16`.
  - `HELLO_VERSION` is unchanged (see Streams).
- **Server, media thread** (`server/media.odin`):
  - `sharers` is keyed by `Media_Stream{num, stream}`: budget
    (`camera_rate` for a camera), keyframe throttle and cache per
    stream.
  - A session has `leases: [1 + MAX_CAMERAS]Media_Lease`, each with its
    own report. `lease_take`: a screen lease replaces the other screen
    lease, a camera takes a free or run-out slot, at most 16.
  - A camera's cache is 256 slots (~300 KB), a screen's 2048 as
    before; `Media_Cache.slots` is a slice now.
  - `media_reports` sends one summary per stream that is on, with the
    stream byte.
  - Viewer lists per stream aren't built; the relay still scans every
    session (fine at these numbers, see Server).
- **Server, main loop**:
  - `camera_allowed` (`server.odin`) is checked when the Camera flag is
    turned on (`sound_set`) and on moving rooms (`conn_set_room`).
  - **Not in the plan:** a camera is only allowed *in* a room; outside
    one (room 0) the flag is taken off too. A call's room is never
    counted (it only has the two).
  - Without the media link, or with `max_cameras: 0`, it never is.
- **Config**: `video.max_cameras` (default 9, 0..16, 0 = no cameras),
  `video.camera_max_kbit` (default 4000), with what a full channel costs
  in the comment.
- **Client**: only what the new signatures need. It still watches and
  sends screens only, and drops camera fragments, keyframe requests and
  reports (`conn/media.odin`, `handle_video`).
- **Tried**:
  - proto (90 tests): camera fragments both ways, Watch with the
    camera and stop flags, Keyframe/Nack/Report with and without the
    stream byte, `Server_Info` with and without the camera fields.
  - server (139): `test_media_camera` (camera and screen leases side by
    side, keyframe, relay, Nack and reports per stream, ending one
    lease, the camera's cache size, housekeeping) and
    `test_camera_limit` (room 0, the limit, room again after one goes
    off, moving into a full room, cameras off).
  - conn (37) passes; the client type-checks for Linux, Windows and the
    web.

### 2. The client's streams

*As built:*

- **`conn/video.odin`**:
  - `Video_Client` is now `outs: [Video_Stream]Video_Out` and
    `ins: [1 + MAX_CAMERAS]Video_In` (`ins[0]` the screen, the rest
    cameras). What was per share (queue, frame numbers, keyframe state,
    `adapt_bitrate`'s figures) is in `Video_Out`; what was per watched
    sharer (lease timing, `Video_Window`, delay and loss figures,
    report) is in `Video_In`, keyed by `Video_Key{user, stream}`.
  - One pace for everything we send (the live streams' rates added
    up), camera fragments first (`video_next_out`).
  - A stream's frame numbers keep counting across restarts, so the
    server's cache never confuses them with the last share's.
  - `Watch_Command` still watches one screen.
    `Watch_Cameras_Command` (made with `watch_cameras(users..)`) sets
    the list of cameras to watch. A camera that goes off stays in the
    list, without a lease, and is watched again (from a keyframe) when
    it comes back. A screen that stops being shared is dropped, as
    before. A stream that stops being watched ends its lease at once
    (`WATCH_STOP`), and its window is freed.
  - Reports go out once a second for every stream watched.
  - The View's `video_stats` stay about the screens (the one shared
    and the one watched); there are no per-camera figures yet.
  - **The camera and the server's limit**: a camera's frames are
    only queued while the server shows our Camera flag
    (`note_camera_taken`). When it does, the camera starts from a
    keyframe. After `CAMERA_REFUSED_AFTER` (3 s) without it,
    `View.camera_refused` is set for the UI. The View also gets
    `max_cameras` and `camera_limit_kbit` from `Server_Info`.
- **Platform procs** take a stream: `video_capture_live/pull/
  request_key`, `video_share_kbit/max_kbit/adapt/codecs` take a
  `Video_Stream`; `video_show_frame/end/failed`, `video_picture`,
  `video_picture_info` a `Video_Key`. New: `video_show_ready`. Both
  platforms only capture screens so far (cameras come in 3 and 6), and
  the page has one decoder, for the screen (more in 3).
- **Desktop views** (`video_native.odin`):
  - A pool of `VIDEO_INS` slots, each with a `yv_view` kept for the
    life of the process once made.
  - **Not as planned:** a view has to be made on the UI thread.
    `yv_view_create` hands it the renderer's device at once, which on
    GL loads the GL functions and needs the GL context current. A view
    made on the network thread showed nothing. So `video_picture`
    makes a stream's view the first time the UI draws it
    (`take_view`).
  - Until then `video_show_ready` is false and its frames are
    dropped; after that, a non-key frame resets the window, so one
    keyframe is asked for, not one every half second.
  - With none free, a view not drawn for 5 s is taken, so a stream the
    UI drew once more after it ended can't hold one forever.
  - A generation count (`used`) keeps a picture presented while its
    view changed hands from being shown.
- **UI**: only `video_picture`'s key. The Screen tab and the popped-out
  window pass the screen they show.
- **Tried**:
  - conn tests (39): two new ones. `test_video_camera_first` checks
    the camera goes first and fragments carry their stream.
    `test_video_watch_streams` covers the camera list (duplicates, other
    rooms), routing fragments by (user, stream), a camera going off and
    on, a screen ending, and letting cameras go.
  - Off screen (headless weston, headless Chromium): a browser shared
    (the web build from this branch), and the desktop client watched
    it. The picture showed, and also after stopping and watching again.
    The phase 1 client showed it too.
  - **Not tried**: a desktop client *sharing*. Native X11 capture on
    the headless weston display never produced a frame, with the
    phase 1 client as well, so that's the test setup, not this change.
  - Type-checks for Linux, Windows, macOS and the web.

### 3. Cameras in the browser

*As built:*

- **`web/video.js`**:
  - What was the share is now a capture made by `newCapture`, one for
    the screen and one for the camera (`captures[stream]`). Capturing,
    sizing, encoding, the queue and `setBitrate` take the capture they
    work on.
  - The camera starts with `getUserMedia` (`startCamera(fps, kbit,
    w, h, device)`). It asks for the size and frame rate the client
    wants, with `facingMode: "user"` (a phone's front camera) when no
    device is named, and `contentHint = "motion"`.
  - A camera that isn't allowed is `FAILED`. A picker the user cancels
    stays `OFF`, as before. Shared audio stays the screen's alone.
  - **Self view**: the camera's newest frame as it is encoded (scaled
    to the sending size, not mirrored) is kept for `takePreview`.
  - **Watching**: a decoder per `sharer:stream` (`views`), each with
    its own codec, failure flag and newest frame; `end(sharer,
    stream)` drops one. The old "a new sharer ends the previous one"
    is gone, since streams no longer share a decoder.
- **`web/shell.c`**: the calls take the stream (and the sharer where
  they're about watching). New: `yap_video_camera_start`,
  `yap_video_can_camera`, and `yap_video_stop`/`yap_video_state` for
  either stream. `yap_video_upload` with sharer 0 uploads the self view.
- **`conn/video_web.odin`**:
  - A texture for each stream drawn, plus one for the self view (the
    one drawn longest ago is given to a new stream), instead of one.
  - New procs for the UI: `video_can_camera`, `video_camera_start
    (config, device)`, `video_camera_stop`, `video_camera_state`,
    `video_camera_preview`. The desktop has stubs that say no (phase
    6).
- **`conn/video.odin`**: `camera_config(limit_kbit)` with a first
  `CAMERA_CONFIG` (720p30, 1800 kbit/s) until the tiers (phase 5).
- **Not in the plan**: `/cameras [names]` in the headless client
  (`Watch_Camera_Names_Command`) watches the named accounts' cameras.
  It's for testing without the UI: what arrives shows in the debug
  log's figures.
- **Tried** (headless Chromium with its fake camera, against a headless
  client):
  - The camera turned on outside any room: the server didn't take the
    Camera flag. After joining Lobby's voice it did.
  - With `/cameras bot1`, the headless client received the camera at
    about 65 kB/s.
  - Turning it off cleared the flag and the video stopped.
  - In the page: H.264 fed to two streams of one sharer decoded on
    their own (10 and 9 frames). Ending one left the other, and the self
    view gave 1280x720 frames.
  - The screen still shares from the page (live at 8000 kbit/s, pulled
    as it comes).
  - conn tests (39) pass, and the client type-checks everywhere.
  - **Not tried**: a real browser's camera and permission prompt, and a
    phone.

### 4. Calls

*As built:*

- **`ui_camera.odin`** (new):
  - **The Camera button** beside Share, in a voice chat or a call, where
    the platform can send a camera (`video_can_camera`) and the server
    allows cameras (`max_cameras` > 0). Its states:
    - Off: "Turn your camera on".
    - Starting: dim, the browser asking.
    - Live: green, "Turn your camera off".
    - Failed: red, crossed out, "isn't allowed, or another program has
      it".
  - **New icons**: `Camera` and `Camera_Off` (`render/icons.odin`).
  - **The camera follows where it was turned on** (`camera_follow`,
    each frame). It goes off when our voice is no longer on that
    server, when we move to another room (**not in the plan**: it never
    follows us into another channel), or when the server doesn't take
    it. Leaving the server also turns it off.
  - **A full channel**: conn puts up a notice, "This channel already has
    N cameras on." (or "This server doesn't allow cameras."), when the
    server hasn't taken the Camera flag for 3 seconds. The UI then turns
    the camera off.
  - **Video call / Answer with video**:
    - "Video call" (camera icon) sits beside "Call" in a DM's header and
      in somebody's menu.
    - A ringing call gets three buttons where we can send a camera:
      Accept, Answer with video, Decline. Elsewhere it keeps two.
    - Either way the camera comes on once the call is on and our voice
      is in it (`follow_video_call`). Answering never turns it on
      otherwise.
- **The Video tab**:
  - Offered in a call on the shown server while their camera or ours
    is on. It sits beside Chat (and Screen), beside a channel's chat and
    in the DM screen alike: the tab row is shared (`side_tab_widths`,
    `side_tab_buttons` in `ui_chat.odin`).
  - It opens by itself when their camera comes on (from the Chat tab),
    and goes back to the chat when there's nothing to show.
  - Their camera is watched only while the tab shows it
    (`Watch_Cameras_Command`).
  - Layout: they're large; our own camera, mirrored, sits in the bottom
    right-hand corner, a quarter of the width, 16:9. A click on the
    corner swaps the two. With only one camera on, that one fills the
    tab.
  - **Not in this phase**: dragging the corner between corners,
    fullscreen and pop-out for the Video tab (phase 5 brings them for
    the grid), and a self view on the desktop (no capture yet, so it
    reads "Your camera").
- `call_peer` (`ui_calls.odin`) finds the other person's user in the
  call's room, for the voice panel's row and the tab.
  `View_User.camera` comes from the snapshot.
- **Tried** (headless Chromium with the fake camera, the desktop client
  on headless weston, one server):
  - Browser to desktop:
    - bot1 used "Video call" from bot2's menu. bot2's desktop client
      rang with two buttons, as it has no camera, and answered.
    - bot1's camera came on with the call, and bot2's Video tab opened
      by itself showing it.
    - bot1's Video tab showed its own camera mirrored.
    - The camera off: bot2 went back to the chat. On again from the
      button: the tab reopened.
    - Hanging up turned the camera off.
  - Browser to browser:
    - bot2 got Accept, Answer with video and Decline, and answered with
      video. Both cameras came on, and both tabs opened with the other
      large and their own in the corner.
    - Clicking the corner swapped them.
  - A full channel (`max_cameras: 1`): bot2's camera was refused with the
    notice and turned off; bot1's stayed.
  - conn (39) and render (17) tests pass; the client type-checks for
    Linux, Windows, macOS and the web.
- **Tried by the owner** (2026-10-19): a video call between two
  browsers with the OBS virtual camera worked.

### 5. Channels

*As built:*

- **Tiers** (`conn/video.odin`):
  - `camera_config(cameras, call, limit_kbit)` follows the table under
    Quality (`CAMERA_TIERS`, `CAMERA_CALL`).
  - The UI starts the camera at the room's tier, and conn keeps it
    there (`follow_camera_tier`): down at once, up once the room has
    kept to fewer cameras for `CAMERA_TIER_UP_AFTER` (5 s). A change
    clears what adapting held it to.
  - **The page**: `configureCamera` (`yap_video_camera_configure`)
    sets the size, frame rate and bitrate; the next frame sets the
    encoder up again, from a keyframe.
  - The camera is now always asked for at 720p, so that a tier can go
    back up (what is sent is scaled down from it).
  - The desktop has a stub.
- **The grid** (`ui_camera.odin`):
  - The Video tab is offered in a channel's voice chat while anyone's
    camera there is on (ours too). It's labelled "Video (N)" and never
    opens by itself.
  - Tiles are 16:9 in the number of columns that makes them largest.
    The whole block and a short last row are centred. Others come in the
    order of their user numbers, ours last ("You", mirrored).
  - Names sit on a dark band; a green outline marks whoever is talking.
  - A click makes a tile large, with the others in a row under it (a
    fifth of the height). A click on the large one goes back.
  - With nobody's camera on but ours not yet live, it reads "Nobody's
    camera is on".
- **Fullscreen and pop-out**, for the grid and for a call's video alike:
  - Buttons in the tab's header row.
  - Fullscreen fills the window (on the web, the page goes fullscreen)
    until Escape or its button (`camera_full_screen`).
  - The pop-out window "Cameras" (`camera_window`) shows the room our
    voice is in, so it stays while another server is shown. It offers
    fullscreen and putting it back while its server is shown.
- **Not as planned (watching)**:
  - Phase 4 had the tab send its camera when the tab changed.
  - Now every tile drawn notes its camera (`note_drawn`), and after each
    frame the list goes to the voice's server if it changed
    (`camera_after_frame`).
  - So whatever is drawn (the tab, fullscreen, the window, the call's
    corner) is what is watched, and switching servers needs nothing
    special: `show_session` no longer sends an empty list.
- **The channel list** marks a camera that is on with the camera icon
  (ours too). A click on it opens the Video tab.
- **Not done**:
  - A row of tiles that scrolls (the row under a large tile shrinks
    them instead).
  - Talking order or pinning.
  - Watching a channel's cameras without being in its voice chat (the
    server only passes cameras to the same room).
- **Tried** (three headless Chromiums with the fake camera, in Lobby):
  - **Tiers**: one camera and two sent 1500 kbit/s; the third took all
    three to 800 at once. When it went off, they stayed at 800 for the
    5 s, then went back to 1500.
  - The grid of three (two above, one centred under them), names,
    outlines, "Video (3)", and the camera marks in the list.
  - Focusing bot3's tile.
  - The pop-out window, and fullscreen from it and back.
  - **Found and fixed while trying**: the window never showed the first
    time. microui makes a new container already open, so it was never
    placed; it now keeps its own "shown last frame" as the Screen window
    does.
  - conn tests (40, with `test_camera_config`) pass; the client
    type-checks for Linux, Windows, macOS and the web.
- **Tried by the owner** (2026-10-19): three browsers in a channel,
  behind a Cloudflare tunnel (https) over a VPN. Two OBS virtual cameras
  and a screen share all worked, with the grid and making tiles larger.
  But the incoming cameras and the screen had a low frame rate.

### 5a. Video in browsers over slow or jittery paths

What the owner saw led to this; it isn't one of the plan's phases.

- **Why.**
  - A browser's media link is a WebSocket (TCP), through the relay and
    whatever is in front of it (a tunnel, a VPN). Nothing on it is lost
    or reordered, only late, and in bursts. On top of that, the page
    sends a camera frame's fragments 16 ms apart (its loop runs once per
    animation frame).
  - The viewer's `Video_Window` was tuned for UDP. It took a gap of
    10 ms (or 20 ms at a frame's end) for loss and asked again (Nack),
    and gave up on a frame about 170 ms after.
  - So on such a path, viewers kept asking for fragments that were on
    their way. Their reports counted that as loss, and the sender cut
    its bitrate to the floor. Where a stall outlasted the 170 ms, the
    window gave up on a frame that was still coming. Decoding then
    stopped until the next keyframe: the low frame rate.
- **Fix**: `Video_Window.reliable`, set for every window in the browser
  build (`MEDIA_RELIABLE`). Such a window asks for nothing again. It
  gives up on a frame only once a later frame is complete (what is
  missing then was lost before the server, or the server dropped it),
  or after `RELIABLE_WAIT` (1 s) with nothing newer.
  - The page's reports then have no false loss, so the sender adapts to
    real queueing delay only.
  - The desktop (UDP) is unchanged.
- **Measured** (two headless Chromiums, one camera at the fake device's
  20 fps; a proxy in front of the relay that delays each chunk, in
  order, losing nothing):

  | Path (each way) | Before: bitrate, Nacks | After: bitrate, Nacks |
  | --- | --- | --- |
  | Direct | 1500 kbit/s, none | 1500, none |
  | 40 ms | cut to 500 in 4 s; 118/1000 "lost" | 1500, none |
  | 40 ms + up to 80 ms jitter | 500; 202/1000 | 1500, none |
  | 100 ms + up to 60 ms jitter | 500; 206/1000 | 1500, none |

  - All frames reached the viewer in all of these, before and after:
    the proxy's stalls stay under the old 170 ms. A real tunnel's can be
    longer, which is where the old window lost frames.
  - In one earlier run before the fix (40 ms) the viewer decoded 11 of 20
    a second.
- **Tests**: `test_window_reliable` (proto): a fragment 300 ms late is
  waited for and asked for by nobody; a frame is given up on once a
  later one is complete; with nothing newer, after `RELIABLE_WAIT`.
  proto (91), conn (40) and server (139) pass.
- **Not changed**: the page's 16 ms send bursts (harmless now). Also
  the headless fake camera's 20 fps; a real camera runs at its own rate.

### 6. Cameras on Windows

*As built:*

- **DirectShow, not Media Foundation.** The owner suggested OBS's
  libdshowcapture (LGPL), and it fits better:
  - DirectShow sees every camera Media Foundation does (both go through
    the Frame Server), and also the virtual ones that are DirectShow
    filters only, such as OBS's virtual camera.
  - Its frames arrive in memory, which is where camera.cpp wants them.
    The plan's NV12 on the GPU isn't worth it at a camera's sizes.
  - Vendored in `src/video/thirdparty/dshowcapture`, without its VS
    project and its submodule (Elgato's capture-device-support).
  - Two changes from upstream, marked `yap:`:
    - Elgato's HDR tonemapper (and two GC4K60SPlus calls) is behind
      `DSHOWCAPTURE_ELGATO`, which we leave off.
    - Frames without time stamps are passed on too (wine's camera sends
      them that way; Windows' carry times).
- **dshowcapture.dll.** libdshowcapture is built as a DLL of its own, so
  that the LGPL part stays a separate library, like FFmpeg's.
  - Its interface is C++ (`std::vector`, `std::function`), which can't
    cross between two DLLs with their own static C runtime. So the DLL
    also holds `yv_dshow.cpp`, a plain C face (`yv_dshow.h`: fixed-size
    device and mode structs, a frame callback, open/close).
  - `yap_video` loads it from its own folder at run time (`camera_win.cpp`).
    Without it there are no cameras and nothing else changes.
  - build-video.bat copies its licence (`dshowcapture-LICENSE.txt`).
    package-video.sh packs both files, and the installer removes them
    with the add-on.
- **Library API 9** (`yap_video.h`):
  - `yv_list_cameras` / `yv_camera` (id up to 512 bytes: a device path,
    or a virtual camera's name).
  - `yv_camera_allowed`.
  - `yv_camera_start` / `yv_camera_config`.
  - `yv_share_configure(fps, max_w, max_h, kbit)`, instead of the plan's
    `yv_share_set_size`. The tier changes the bitrate too, and changing
    it all at once costs one keyframe rather than two. The same config
    again is ignored.
  - `yv_share_preview`.
  - A camera is a `yv_share` like a screen: `share.cpp` takes
    `camera.cpp`'s pipeline. Only encoders that take frames from memory
    are picked for a camera (no VA-API; later VA-API too, phase 7's
    notes).
- **camera.cpp** (every platform, for phases 7 and 8 too):
  - It picks the mode: the fastest that reaches the frame rate, then the
    smallest at least 1280x720 (so the tier can go up again without
    reopening the camera), then raw before MJPEG.
  - It keeps the newest frame only, and decodes MJPEG with FFmpeg as
    frames come in.
  - swscale scales it and converts BT.601 (JPEG full range, raw YUV
    limited) to BT.709 limited NV12 when a frame is encoded.
  - A camera that sends nothing for 5 s (10 s at first) fails the share:
    unplugged, or taken. "Another program is using the camera" comes
    from DirectShow's `InUse`.
  - RGB that arrives at three bytes a pixel is taken as RGB24, whatever
    it was called: libdshowcapture calls RGB24 XRGB, and on Windows a
    converter usually makes it XRGB on the way, but not always.
- **Privacy switches.**
  - The three camera switches in Settings (the computer's, the user's
    for all apps, desktop apps) are read from where Settings keeps them
    (`CapabilityAccessManager\ConsentStore\webcam`).
  - Cameras are still listed while a switch is off, so the camera button
    stays and turning it on fails with "turn it on in Settings, Privacy
    & security, Camera". The button's tooltip now says the library's
    reason (`video_camera_error`).
- **The preview** is what is encoded (at the tier's size), handed to an
  `Output` of the share's own on the client's GPU, as a view's picture.
  `yv_set_gpu` reaches it through `ctx->outputs`.
- **Client** (`video_native.odin`):
  - The shares are per stream (`Share_Slot`), so the network side's
    procs work for the camera as they did for the screen.
  - Cameras are counted on the probe thread, and again every 10 s while
    there are none (plugged in later). `video_can_camera` needs a camera
    and a working encoder.
  - `video_camera_preview` hands the library the GPU itself, for a self
    view shown before any other video.
  - Turning the camera off stops the network side at once, but the share
    and its preview's texture wrapper only after the frame is drawn
    (`video_frame_done`, after `gpu_present`). The frame may have the
    preview queued, and on D3D11 and Metal that wrapper is freed memory
    otherwise.
- **yv-loopback**:
  - `--list` shows the cameras.
  - `--camera [ID]` shares one.
  - `--then-max WxH` reconfigures 3 s in, as a tier change does.
- **A fake camera for testing** (Linux and macOS, until phases 7 and 8):
  `YAP_VIDEO_FAKE_CAMERA=1` (or `nv12`, `bgrx`, `mjpeg`) lists one camera
  of colour bars with a moving box, at 1280x720 and 30 fps. It's like
  Chromium's `--use-fake-device-for-media-stream`.
- **Tested here:**
  - **Under wine**, built with zig's mingw-w64 (screen capture left out:
    it needs C++/WinRT). DirectShow (wine's qcap, over V4L2) saw the OBS
    virtual camera on this machine.
    - `yv-loopback --camera` captured it at 1280x720 and 30 fps through
      libopenh264. `--then-max 640x360` gave a new keyframe at 640x360.
      The picture came out upright: bottom-up RGB handled.
    - With the desktop-apps switch set to Deny in the prefix, the camera
      was listed as not allowed, and starting it said where to allow it.
    - Wine found three bugs that MSVC would have hit too: missing
      `<objbase.h>`, and two Elgato calls outside the guard. It also
      found two wine-only problems: no time stamps, and RGB24 called
      XRGB.
  - **The fake camera in every format** through yv-loopback: the bars
    decode in the right colours and order, and bottom-up BGRX comes out
    upright.
  - **The client on Linux** (weston, fake camera) with a headless
    Chromium in the channel:
    - The camera button shows. The Video tab shows our camera mirrored
      (the preview), and the browser shows it unmirrored.
    - It went off and on again three times with the tab open, without
      trouble.
    - With two browser cameras on, it started at 960x540/800 kbit/s.
      When one went off, it went up to 1280x720/1500 after 5 s.
    - The browsers' cameras show in its grid.
- **On Windows** (the owner, after CI built it for every platform): the
  OBS virtual camera, shared from the Windows client, watched from a
  Linux one.
- **Not tested**: MJPEG from a real camera, a camera that another
  program holds, and unplugging one. Media Foundation-only cameras (if
  any exist without DirectShow) are not tested either.
- **Left for later**: picking the camera (phase 9; "" is the first one
  listed), and `front`, which stays false on Windows.

### 7. Cameras on Linux

*As built:*

- **`camera_v4l2.cpp`**, a `Camera_Source` for camera.cpp, talking to
  V4L2 directly (only the kernel's headers; no libv4l, nothing loaded
  at run time).
- **Listing**:
  - It goes through every `/dev/videoN`, in order, and takes those that
    capture video and stream. That skips the metadata nodes UVC cameras
    have next to their video ones.
  - It reads each format (`VIDIOC_ENUM_FMT`, leaving out ones libv4l
    makes up), its sizes and its frame rates. Discrete sizes become one
    mode each; a stepwise or continuous range becomes one mode with
    steps.
  - Cameras that only send grey (laptops' infrared ones, for face
    login) aren't listed.
  - The id is the camera's `/dev/v4l/by-id` name where it has one, which
    stays the same when it's plugged in elsewhere, and `/dev/videoN`
    otherwise (v4l2loopback has none).
  - Formats: YUYV, UYVY, YVYU, NV12, YUV420, YVU420, MJPEG and JPEG,
    BGR24, XBGR32 and BGR32, ABGR32, GREY. `Camera_Mode.native` keeps
    V4L2's own code, which opening needs (MJPEG has two).
- **Capturing**:
  - `VIDIOC_S_FMT` at the mode camera.cpp picked, keeping what the
    driver took. Then the frame rate where it can be set, and four
    memory-mapped buffers.
  - A thread polls, dequeues, hands each frame on and queues the buffer
    again. A frame flagged as broken is dropped. `ENODEV` (unplugged)
    ends the thread, and camera.cpp then finds the camera stalled.
  - `EBUSY` from setting the format, the buffers or starting says
    "another program is using the camera". `EACCES` on opening says yap
    may not open it.
- **Padded rows**: `Camera_Frame.stride` (V4L2's `bytesperline`).
  camera.cpp now takes NV12, I420 and YV12 with rows longer than the
  picture. The fake camera's NV12 pads its rows, to try that.
- **The fake camera** moved to `camera_fake.cpp`. On Linux it's listed
  before the real ones, with the id `fake`. `make_camera_source` now
  takes the camera, so a platform can give either.
- **The client** needed nothing: Linux now counts cameras like Windows,
  and the camera button comes with them.
- **Encoders**: a camera still takes encoders that take frames from
  memory. On AMD and Intel that's OpenH264 on the CPU (VA-API's need
  GPU frames), about 7 ms a frame at 720p here. Uploading to VA-API
  surfaces would cut that; for later if it matters.
  - Later, with FFmpeg opened at run time (the system's 8 or 9 when
    there's none next to yap), it mattered: the system's FFmpeg often
    has no OpenH264 (Arch's hasn't), so a camera there had no encoder at
    all. Now `camera.cpp` opens VA-API when the encoder is one of its,
    and `convert` uploads its NV12 to a surface (`vaapi_frames`, shared
    with X11 capture); the preview shows the NV12 that was uploaded
    (`Pipeline::uploaded`). `pick_encoder` lets a camera take VA-API's
    encoders, which come before OpenH264, so AMD and Intel encode
    cameras in hardware. OpenH264 is left for a machine without
    VA-API, with the FFmpeg we ship.
- **Tested here**:
  - OBS's virtual camera (v4l2loopback, YUYV 1280x720 at 30 fps) with
    `yv-loopback --camera`: 30 fps, and `--then-max` gives a 640x360
    keyframe. The picture is right.
  - Every fake format again, picked by id: colours right, padded NV12
    included.
  - The client on weston with the OBS camera:
    - The self view shows the OBS scene mirrored, and a browser in the
      channel shows it unmirrored.
    - Off and on again works, and the server's `Camera` flag follows.
- **Not tested**: a real USB camera (MJPEG at 720p and up, the by-id
  name, unplugging) and `EBUSY`; v4l2loopback lets every reader in.
- **For phase 8**: the macOS FFmpeg (`scripts/build/build-ffmpeg-macos.sh`)
  has no MJPEG decoder (or encoder, for the fake camera's `mjpeg`). It
  needs `--enable-decoder=mjpeg` if AVFoundation ever gives MJPEG; it
  normally gives NV12.

### 8. Cameras on macOS

*As built:*

- **`camera_mac.mm`**, a `Camera_Source` through AVFoundation
  (`AVCaptureSession`, `AVCaptureVideoDataOutput`). `camera_none.cpp` is
  gone: every platform has cameras now.
- **Listing** (`AVCaptureDeviceDiscoverySession`):
  - Built-in and external (USB) cameras. An iPhone (Continuity Camera)
    only where the app's Info.plist has
    `NSCameraUseContinuityCameraDeviceType`; without it macOS 14 lists
    one as an external camera anyway.
  - The id is AVFoundation's `uniqueID`, the name its `localizedName`.
    `front` is set for the built-in camera.
  - Each `AVCaptureDeviceFormat` is a mode, by its index in the device's
    list (`Camera_Mode.native`), with the widest frame rates of its
    ranges. Formats that differ only in what the camera sends are one
    mode.
- **Capturing**:
  - Whatever the camera sends, the output asks for NV12 (`420v`,
    limited range), so AVFoundation converts (and decodes MJPEG) on the
    way. Every mode is NV12 to camera.cpp. The macOS FFmpeg can stay
    without an MJPEG decoder.
  - The format and frame rate are set on the device after it's in the
    session and while it's locked, and the session is started before
    unlocking, so it keeps them instead of a preset's.
  - Frames come on a serial dispatch queue of the source's own and are
    read from the `CVPixelBuffer` in memory. Planes that aren't one after
    the other are packed first. Stopping takes the delegate away and
    drains the queue, so no frame comes after the source is gone.
  - What's sent is never mirrored (the connection's automatic mirroring
    is off).
- **Colours**: `Camera_Frame.bt709`. macOS tags its buffers' matrix, and
  HD cameras are BT.709, so camera.cpp now takes BT.709 YUV where the
  platform says so (BT.601 otherwise, as before).
- **Permission**:
  - `camera_allowed` gains a `stop`. On macOS it's true until the user
    said no. Starting a camera asks (`requestAccessForMediaType`) if
    they haven't answered, and waits for the answer or for the share to
    be stopped. Denied, starting says where to allow it (System
    Settings, Privacy & Security, Camera).
  - The fake camera needs no asking: camera.cpp now finds the camera
    first and asks only for a real one.
  - A process asking without `NSCameraUsageDescription` is killed.
    `package-macos.sh` adds it (and the Continuity Camera key) to the
    app's Info.plist. yv-loopback has an Info.plist linked into it
    (`tools/Info.plist`, `-sectcreate __TEXT __info_plist`). A client
    run from Terminal goes by Terminal's.
- **The client** needed nothing but a comment.
- **Tested on the Mac mini** (macOS 27, M2 Pro):
  - It builds with no warnings of its own. `yv-loopback --list` shows
    no cameras (the Mac mini has none) and the fake one with
    `YAP_VIDEO_FAKE_CAMERA`.
  - The fake camera in YUY2, NV12 and BGRX through `h264/hevc_videotoolbox`
    at 30 fps, and `--then-max 640x360` reconfigures.
  - The client counts the fake camera ("1 camera(s)") and finds a
    working encoder.
  - From ssh, asking for the camera gets no prompt and a no at once (the
    responsible process is sshd), which starting reports as not allowed.
  - The owner ran the client there with the fake camera: the camera
    button, and the self view through Metal.
- **Not tested**: a real camera (none on the Mac mini), the permission
  prompt and Continuity Camera.

### 9. Settings

*As built:*

- **A Camera category** in the client's settings, after Screen sharing
  (`ui_camera_settings.odin`). Saved as `camera_device`,
  `camera_quality` and `camera_mirror`.
- **Which camera**: a dropdown of the cameras there are, with "The first
  one there is" (in a browser, "The browser's choice", a phone's front
  camera) on top.
  - A camera picked before that isn't plugged in now stays picked, as
    "The one picked before (not there now)".
  - The list is counted again every 3 s while the category is shown (off
    the UI thread on the desktop; the browser's `enumerateDevices` and
    `devicechange` on the web). A browser gives ids and names only once
    the page has been allowed a camera, which the preview asks for, and
    the page says so until then.
  - Picking another camera while ours is on switches to it at once
    (`camera_switch`).
- **Quality** (`conn.Camera_Quality`, `camera_config`'s new argument):
  - Auto is the tiers as before.
  - High sends a call at 1920x1080, 3500 kbit/s; a channel as Auto.
  - Low keeps everything to the 640x360, 450 kbit/s tier (480x270 in a
    room of more than nine).
  - A camera that's on follows a change as it follows the room's tier
    (`video_set_camera_quality`, read by `follow_camera_tier`): down at
    once, up after 5 s.
- **Mirror my own view**: the self view, in the call's corner and the
  grid, is mirrored unless it's off. What others see never is.
- **The preview**:
  - It shows our camera while it's on.
  - Otherwise the camera picked is opened for it but not sent
    (`video_camera_look`): on the desktop a camera share of the library's
    that the network side never sees, in the browser a `getUserMedia`
    stream of video.js's own whose frames go where the camera's
    self-view frames go. It's let go of after a frame without the
    category (`camera_after_frame`).
  - Turning the camera on while it's open takes it over as it is: the
    share becomes the camera's (reconfigured to the tier), or the page
    hands a clone of its track to the camera. Through the UI that only
    happens when a call answered with video comes on meanwhile, since
    the settings cover the voice panel.
  - A preview that failed says why, and isn't tried again until another
    camera is picked (the browser would ask again each frame).
- **Found and fixed**: the dropdown's list left microui's padding out of
  its row height, so a short list (two cameras) got a scrollbar and
  half its second row. The Sounds page's lists are long enough that it
  never showed.
- **Tried** (headless Edge with its fake camera, a server here):
  - The category, its preview (mirrored, then not), the dropdown with
    `fake_device_0`, and the settings saved.
  - Leaving the settings let go of the preview's camera.
  - In Lobby's voice chat with Low picked, the camera came on at
    450 kbit/s. Auto from the settings took it to 1500 after 5 s, Low
    back to 450 at once. The preview showed the live camera without
    opening another.
  - Switching to "The browser's choice" while on kept it live; turning
    it off brought the preview back.
  - conn (40) and settings (6) tests pass; the client type-checks for
    Windows and the web, builds on the Mac, and the web build builds.
- **Tried by the owner** (2026-10-19): the settings on macOS with the
  fake camera, and on Windows with the OBS virtual camera.

### 10. Demand

*As built:*

- **Protocol** (`proto/video.odin`):
  - A Watch on a camera may end with the tile's size in pixels
    (`WATCH_TILE_SIZE`: `[width u16][height u16]`).
  - Demand, the new message kind 50, server to sharer:
    `[stream u8][width u16][height u16][viewers u16]`. A size of 0 means
    a viewer didn't say, so there's no limit.
  - `Server_Info.demand` says the server takes tile sizes; a client only
    sends them then. Older servers drop the longer Watch, so this keeps
    new clients working with them.
- **Server** (`media.odin`):
  - A lease keeps its tile (`Media_Lease.tile`).
  - `media_demand` works out the largest tile and the viewers in the
    sharer's room.
  - It's sent once a second with the reports, to every camera that's
    on, nobody watching included. It's also sent at once when a lease
    starts or its tile changes size, so a new viewer wakes a paused
    camera without waiting.
- **Viewers** (`ui_camera.odin`, `conn/video.odin`):
  - Each drawn tile notes its size in the framebuffer's pixels, rounded
    up to 16, the largest if a camera is drawn twice (the call's corner
    and the pop-out).
  - The list goes with `Watch_Cameras_Command` when users or sizes
    change. A changed size goes out with the next Watch, at most every
    250 ms (`WATCH_TILE_EVERY`), so resizing the window doesn't flood
    the link.
- **The sharer** (`follow_demand`):
  - It sends at the smallest of `CAMERA_SIZES` that covers the largest
    tile, never above the room's tier. The sizes and rates are 1080p
    3500, 720p 1500, 540p 800, 360p 450, 270p 300 and 180p 180.
  - Larger at once, smaller after 3 s (`DEMAND_DOWN_AFTER`), since each
    change costs a keyframe.
  - `follow_camera_tier` now only works out the room's tier;
    `follow_demand` is what configures the camera.
  - **Paused with no viewers**: `yv_share_pause` (library API 10) and
    the page's `pauseCamera`. The capture goes on, and so does the self
    view (the library still converts the frame for the preview, the page
    still makes its preview frame). Nothing is encoded, and the camera
    goes on from a keyframe.
  - It goes on when a Demand has viewers, or at once when a viewer asks
    for a keyframe.
  - A Demand older than 3 s (`DEMAND_STALE`) isn't followed: back to the
    tier, not paused. An older server never sends one, so nothing
    changes there.
  - yv-loopback gains `--then-pause`.
- **Tried** (two headless Edges with their fake cameras, the server
  built from this tree):
  - admin's camera on with nobody watching: paused within a second of
    the camera being taken.
  - bot1 opened the Video tab: it went on at once, then dropped to
    960x540 at 800 kbit/s for bot1's 912x512 tile after 3 s.
  - Back to Chat: paused again; the tab again: on again, with a picture.
  - bot1's camera on too: the grid's two tiles took admin's camera to
    640x360 at 450 for a 496x288 tile. bot1's own camera, unwatched,
    paused, while its self view kept moving.
  - On the Mac, `yv-loopback --camera fake --then-pause`: no frames while
    paused, then on again with a second keyframe.
  - proto (92), server and conn (42, with `test_demand_config` and
    `test_follow_demand`) tests pass. One server test,
    `test_attachments_quota`, fails now and then on its own timing,
    also without these changes. The client type-checks for Windows and
    the web, and builds on the Mac.
- **Not tried**: a desktop client watching or being watched (its tile
  sizes come from the window's scale, so a Retina display asks for
  twice the points), and the pop-out window's tiles.

## Risks

- **Lip sync.** Voice takes the main link with its own jitter buffer;
  video the media link, through the window and a decoder thread. Video
  probably arrives 30–80 ms after the voice. Under 45 ms nobody
  notices, past 100 ms most do. Phase 4 measures it (the frame's `ts`
  against the voice's); if it's bad, delaying a user's voice by the
  difference while their camera is shown is the fix, which costs
  conversation latency, so it's a decision then.
- **Memory** (the client is meant to stay small). Nine FFmpeg software
  decoders hold their reference frames (360p NV12 is 350 KB a frame, a
  few dozen MB for nine) plus nine RGBA textures. To measure in phase 5
  with Settings > Memory; decoder threads and frame pools can be cut
  down for small streams.
- **Cameras that are busy** (in another app without a Frame Server,
  Linux V4L2): a clear "the camera is in use" message, not a hang.
- **Laptop cameras on Linux** behind libcamera (IPU6) aren't V4L2
  capture devices: they show up, or don't, until the PipeWire path.
- **Server traffic** grows with cameras × watchers; operators need to
  know (`max_cameras` in the config's comment and the README).

## Later

- **Simulcast**: each camera encoded at two sizes (say 720p and 180p),
  the server forwarding whichever each viewer's tile wants. Costs the
  sharer a second encode and the protocol a layer bit; worth it if
  Demand's "the largest viewer decides" turns out too expensive for
  everyone else.
- PipeWire camera (and the camera portal) on Linux, for libcamera
  cameras and Flatpak.
- Background blur, peer-to-peer calls, lip sync by delaying voice,
  more than one camera per user, group calls outside channels.

## Decisions

All settled as recommended (2026-10-18).

| # | Question | Recommendation |
| --- | --- | --- |
| D1 | How a camera is told apart | A bit in the fragment's flags plus a stream byte on Watch/Nack/Report/Keyframe; the header doesn't grow. A general stream id only if more than two streams per user ever come up. |
| D2 | How quality scales with cameras | Tiers by the number of cameras in the room, worked out by every client the same way; then Demand (phase 10). Simulcast only if needed. |
| D3 | The room limit | 9 by default, `video.max_cameras` on the server (0 turns cameras off), enforced by the server on the `Camera` flag. |
| D4 | Who can watch a channel's grid | Everyone in the voice room, camera or not. |
| D5 | Linux capture | V4L2 first; PipeWire (libcamera, portal) later. |
| D6 | The `Camera` flag | The last free bit of `User_Flags`. The next flag after it means growing it to u16 (a snapshot change); doing that now instead costs a protocol step for nothing yet. |
| D7 | Opening the Video tab | By itself in a call when the other's camera comes on; in a channel only shown, with the count. |
| D8 | Calls through the server or peer-to-peer | Through the server. |
| D9 | The self view | From the capture (`yv_share_preview`, the page's own `VideoFrame`), not by decoding our own stream. |
| D10 | Call quality by default | 720p30 at 1.8 Mbit/s; High (1080p30, 3.5) in the settings. |
| D11 | Tab name | "Video" in both calls and channels. |

## Working through a phase

As in `docs/design/hq-share.md`: read the yap code the phase touches, build it,
write what turned out differently under "*As built:*", tick it in the
table. Phases 3–5 can be tested here with headless Chromium's fake
camera; 6 needs Windows, 8 a Mac.

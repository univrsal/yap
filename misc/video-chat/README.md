# Video chat: plan

Cameras in DM calls and in voice channels, built on what screen sharing
already has (`misc/hq-share`): the media link, the server's relay and
Nack cache, the viewers' reports, `yap_video` on the desktop and
WebCodecs in the browser. Nothing here is built yet. As in `misc/next`,
each phase is its own commit or series of commits; what turns out
differently is written under it when it's done ("*As built:*"), and the
open questions are in the Decisions table at the end.

Sizes as in `docs/extended`: S up to about 300 changed lines, M up to
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
| Demand (new, phase 10) | - | server → sharer: `[stream u8][width u16][height u16][viewers u16]` |

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
| Windows | Media Foundation `IMFSourceReader` (`MFEnumDeviceSources`) with a D3D manager, so NV12 arrives on the GPU | NV12, YUY2, MJPEG (decoded by MF) | Windows' camera privacy switch shows as `E_ACCESSDENIED`: say where to turn it on. The Frame Server shares a camera with other apps. |
| Linux | V4L2 directly (`/dev/video*`, `VIDIOC_ENUM_FMT`, mmap buffers) | MJPEG (FFmpeg's `mjpeg`, or VA-API's JPEG decoder), YUYV, NV12 | Covers USB cameras everywhere. Intel IPU6 laptop cameras need libcamera, reachable through PipeWire: later (D5). |
| macOS | AVFoundation `AVCaptureSession`, `AVCaptureDevice.DiscoverySession` (Continuity Camera too) | NV12 `CVPixelBuffer` on an IOSurface, straight into VideoToolbox | The app's `Info.plist` needs `NSCameraUsageDescription`, or macOS kills the app on first use (`scripts/package-macos.sh`). |
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
| 1 | Streams in the protocol, the server: camera bit, stream bytes, leases, `Camera` flag and limit, config | M | protocol, server | - | - |
| 2 | The client's streams: `Video_Out`/`Video_In`, several leases, a view per stream | L | client (conn) | 1 | - |
| 3 | Cameras in the browser: getUserMedia, a second encoder, several decoders | M | web | 2 | - |
| 4 | Calls: camera button, Video tab with self view, video call / answer with video | M | client (UI) | 2, 3 | - |
| 5 | Channels: the grid, tiers, focus, the full-room message, pop-out | M | client (UI) | 4 | - |
| 6 | `yap_video` cameras on Windows: Media Foundation, `yv_share_preview`, `yv_share_set_size` | L | library, client | 2 | - |
| 7 | Linux: V4L2, MJPEG | M | library | 6 | - |
| 8 | macOS: AVFoundation, `Info.plist` | M | library, scripts | 6 | - |
| 9 | Settings: camera, quality, mirror, preview | S | client | 4, 6 | - |
| 10 | Demand: viewers' tile sizes, pausing unwatched cameras | M | protocol, server, client | 5 | - |

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

Open until the owner answers. Recommended answers first.

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

As in `misc/hq-share`: read the yap code the phase touches, build it,
write what turned out differently under "*As built:*", tick it in the
table. Phases 3–5 can be tested here with headless Chromium's fake
camera; 6 needs Windows, 8 a Mac.

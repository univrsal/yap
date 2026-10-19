# HQ share: plan

Screen sharing for the native clients at up to 60fps and a sharp picture,
built as an optional library that the client loads only if it's there.
Nothing here is built yet. As in `misc/next`, each phase is its own commit
or series of commits; what turns out differently is written under it when
it's done ("*As built:*"), and the open questions are in the Decisions
table at the end.

Sizes as in `docs/extended`: S up to about 300 changed lines, M up to
1000, L up to 2500, XL more. Sizes for the library count its own C++, not
FFmpeg.

The OBS source in `misc/hq-share/obs-studio-master` is a reference for
*how* capture and hardware encoding are done on each platform (which
APIs, in what order, what goes wrong). OBS is GPL-2.0 and yap is zlib, so
nothing is copied from it; the library is written fresh against the
platform APIs and FFmpeg. "OBS:" lines below point at the parts worth
reading before each phase.

## What we start from

- **The protocol and the relay already exist, and don't care about the
  codec.** `proto/video.odin` defines Video (fragments of
  `[frame u32][ts u32][index u16][count u16][flags u8][codec u8]`), Watch
  (a lease, resent every second) and Keyframe. `server/video.odin` passes
  fragments to whoever in the room holds a lease, with a per-sharer
  token bucket, and never looks inside. Whether someone shares is the
  `Sharing` user flag.
- **The client side is shared, only the media part is web-only.**
  `conn/video.odin` queues, paces and sends frames, keeps the Watch
  lease and reassembles frames. It calls a set of platform procs
  (`video_capture_live/pull/request_key`, `video_show_frame`,
  `video_upload(texture)`, `video_share_start/stop/state`,
  `video_can_share/watch`, ...). `video_web.odin` implements them with
  getDisplayMedia and WebCodecs (`web/video.js`, H.264, 15fps, 2 Mbit/s,
  at most 1080p). `video_native.odin` is a set of stubs that say "can't".
  This is exactly where the library plugs in.
- **The UI is there.** `ui_video.odin` has the share button, the Screen
  tab, fullscreen, and draws whatever `video_upload` put into a texture.
- **Heavy traffic already has its own link** (next, item 5): video goes
  on the bulk link, its own UDP socket and Noise session, so voice isn't
  harmed. But everything is sized for 2–4 Mbit/s:

  | Limit | Today | Where |
  | --- | --- | --- |
  | Server rate per sharer | 4 Mbit/s | `server/video.odin` `VIDEO_MAX_RATE` |
  | Client send pace | 3 Mbit/s | `conn/video.odin` `VIDEO_SEND_RATE` |
  | Largest frame | 256 KiB | `proto/video.odin` `MAX_VIDEO_FRAME_SIZE` |
  | Replay window | 64 packets | `proto/session.odin` |
  | Client bulk receive | 16 packets a loop turn | `conn/bulk.odin` `BULK_RECV_MAX` |
  | Server loop | one packet, then every sync phase | `server/server.odin` |
  | Relay | scans every session per fragment | `server/video.odin` `relay_video` |
  | Reassembly | one frame at a time, broken until a keyframe | `proto.Video_Assembler` |

  60fps at a good quality is 8–20 Mbit/s, which is 900–2200 packets a
  second per viewer. Each of these limits breaks before that.
- **Losses are repaired only with keyframes.** A lost fragment spoils
  everything up to the next keyframe, and the viewer asks for one. At
  15fps and 2 Mbit/s that's tolerable; at 60fps a 1440p keyframe is
  200–400 fragments, any of which can be lost, and every keyframe makes
  the next loss likelier.
- **The renderer can't draw someone else's texture.** `render` is a quad
  batcher with D3D11 on Windows and OpenGL 3.3 elsewhere.
  `gpu_texture_make/update` make and fill RGBA textures from memory;
  there's no way to draw a texture that something else made.
- **Optional pieces today are compiled in.** App audio (`audio/aac`) is a
  static lib that only `dlopen`s its OS backend. `core:dynlib` is used
  for libcurl, X11 and Wayland, so loading a library at runtime is an
  established pattern.
- **The licence is zlib.** FFmpeg is fine as LGPL if it's linked
  dynamically, in a library that isn't part of the default download
  anyway.

## Requirements

### Must

- **60fps, sharp text.** 1080p60 at about 8 Mbit/s and 1440p60 at about
  15 Mbit/s should look clean on text and code; 4K is allowed but not a
  target.
- **Low latency.** Under 100ms from the sharer's screen to the viewer's
  on a LAN, under 150ms across the internet at 50ms ping. Rules out
  B-frames, lookahead and deep jitter buffers.
- **Hardware encoding** where there is any: NVIDIA (NVENC), AMD (AMF on
  Windows, VA-API on Linux), Intel (QSV on Windows, VA-API on Linux),
  Apple (VideoToolbox: H.264 and HEVC on every Apple Silicon Mac and
  Intel Macs with Quick Sync or a T2; AV1 is decode only, M3 and later).
- **Capture** of a whole monitor or a single window on Windows 10 1903+,
  macOS 12.3+, and Linux on Wayland (portal) and X11. The cursor in the
  picture, optionally.
- **Optional.** No library next to the client: the client is what it is
  today, same size, sharing hidden as now. The default build doesn't
  need FFmpeg or a C++ compiler.
- **Small changes to the client and server.** The client gets a loader
  for the library, a way to draw its textures, and some UI. The server
  stays a single small binary: a relay with no codec knowledge.
- **Modern codecs only.** H.264, HEVC and AV1. Every viewer decodes all
  three (FFmpeg has software decoders for each), so the server never
  re-encodes and no one needs to negotiate.

### Should

- Zero-copy on the sharer's side: the captured frame stays on the GPU
  until it's encoded. This is what keeps 60fps cheap.
- Hardware decoding on the viewer's side where available, with software
  as the fallback.
- Settings for those who want them: codec, encoder, bitrate, frame rate,
  largest size. Sensible presets for everyone else.
- Native clients watch web shares (H.264 Annex B, which the library
  decodes anyway).

### Not now

- Webcams and video calls. The library is shaped so a camera is just
  another source (see Later).
- Audio: app audio goes with voice already (`audio/app_audio_native`).
- Web clients watching native shares (D9).
- HDR, more than one share at a time per user, watching more than one
  share at a time, region capture, thumbnails in the picker.

## Architecture

```
 sharer's client                    server                     viewer's client
 ┌────────────────────────┐        ┌──────────────┐        ┌────────────────────────┐
 │ yap_video              │        │ media thread │        │ yap_video              │
 │  capture → convert →   │ frames │  per-sharer  │        │  decode → convert →    │
 │  encode (GPU)          ├──►conn─┤  cache, NACK,├─►conn──┤  texture (GPU)         │
 │                        │  media │  relay       │  media │          │             │
 └────────────────────────┘  link  └──────────────┘  link  └──────────┼─────────────┘
                                                                     render draws it
```

Three parts, each with one job:

1. **`yap_video`**, a shared library (`yap_video.dll`,
   `libyap_video.so`, `libyap_video.dylib`) with a C API. Capture,
   colour conversion, encoding, decoding, and handing out a texture the
   client's renderer can draw. It knows nothing of networks, Noise or
   yap's protocol: encoded frames go out, encoded frames come in.
2. **The client** (Odin) loads the library with `core:dynlib`, moves
   encoded frames between it and the network, and draws its texture.
   `video_native.odin` stops being stubs; `conn/video.odin` gets the
   transport changes; `render` gets `gpu_texture_wrap`.
3. **The server** relays, on a link of its own (see Transport). It
   learns nothing about codecs; it gets a cache of recent fragments so
   it can resend lost ones itself.

### The library

C++20 behind a plain C header (`yap_video.h`), because WGC is WinRT,
ScreenCaptureKit is Objective-C, and FFmpeg, PipeWire and D3D11 are C or
COM. Odin binds the header with `core:dynlib` (a proc table filled with
`dynlib.initialize_symbols`), not `foreign import`, so the client never
links it.

Built with CMake from its own folder (`src/video/`, D7) by
`scripts/build-video.sh` / `.bat`, which also fetches FFmpeg
the way `opus` and `webp` are fetched (`scripts/ffmpeg.version`). The
output is the library and FFmpeg's shared libraries, copied into `bin/`
next to the client.

FFmpeg is configured small: LGPL, shared, only `avcodec`, `avutil` (and
`swscale` for the CPU fallback), only the H.264/HEVC/AV1 encoders and
decoders named below, with `nv-codec-headers` (NVENC/NVDEC), AMF
headers, `libvpl` (QSV), `libdav1d` (AV1 decode), VA-API, D3D11VA and
VideoToolbox. All of those are MIT/BSD. No x264, x265 or anything else
GPL. Expect 15–25 MB for the lot. (For now it's a prebuilt FFmpeg
with every codec, about 90 MB; see phase 1's *As built*.)

#### API sketch

```c
#define YV_API_VERSION 1

typedef struct yv_context yv_context;
typedef struct yv_share yv_share;
typedef struct yv_view yv_view;

typedef enum { YV_GPU_D3D11, YV_GPU_GL } yv_gpu_kind;
typedef enum { YV_CODEC_H264 = 0, YV_CODEC_HEVC = 1, YV_CODEC_AV1 = 2 } yv_codec;

typedef struct {
    uint32_t api_version;               // YV_API_VERSION, refused if it differs
    yv_gpu_kind gpu;
    void *d3d11_device;                 // the client's ID3D11Device (D3D11)
    void *(*gl_get_proc)(const char *); // glfwGetProcAddress (GL)
    void (*log)(int level, const char *msg);
} yv_init;

yv_context *yv_create(const yv_init *init);
void yv_destroy(yv_context *);

// What can be shared, and with what.
int yv_list_sources(yv_context *, yv_source *out, int max);   // monitors, windows: id, kind, name, app, size
int yv_list_encoders(yv_context *, yv_encoder *out, int max); // "nvenc_av1", codec, hardware or not
bool yv_system_picker(yv_context *);                          // true on Wayland and macOS 14+: the OS picks

// Sharing. Any thread; the library has its own capture and encode thread.
yv_share *yv_share_start(yv_context *, const yv_share_config *); // source, codec, encoder, fps, bitrate, max size, cursor
int  yv_share_pull(yv_share *, yv_packet *out); // next encoded frame, or 0: data, size, pts_us, key, codec
void yv_share_request_key(yv_share *);
void yv_share_set_bitrate(yv_share *, uint32_t kbit);
int  yv_share_state(yv_share *);               // starting, live, failed (+ yv_share_error)
void yv_share_stop(yv_share *);

// Watching. push from the network thread, present from the UI thread.
yv_view *yv_view_create(yv_context *);
void yv_view_push(yv_view *, const uint8_t *data, size_t size, yv_codec, uint64_t pts_us, bool key);
bool yv_view_need_key(yv_view *);              // decoder gave up, ask for a keyframe
bool yv_view_present(yv_view *, yv_texture *out); // newest frame: native texture, width, height
void yv_view_destroy(yv_view *);
```

That maps almost one to one onto the procs `video_native.odin` stubs
today, which is the point: `conn/video.odin` doesn't care whether the
browser or the library is underneath.

#### Capture

| Platform | Monitor | Window | Cursor | OBS |
| --- | --- | --- | --- | --- |
| Windows | Windows.Graphics.Capture; DXGI Desktop Duplication as the fallback | WGC | WGC's `IsCursorCaptureEnabled`; drawn ourselves with DXGI | `libobs-winrt/winrt-capture.cpp`, `libobs-d3d11/d3d11-duplicator.cpp`, `plugins/win-capture/cursor-capture.c`, `libobs/util/windows/window-helpers.c` |
| macOS | ScreenCaptureKit display stream | SCK window stream | `showsCursor` | `plugins/mac-capture/mac-sck-common.m`, `mac-sck-video-capture.m` |
| Linux, Wayland | xdg-desktop-portal ScreenCast + PipeWire | same, the portal picks | portal cursor mode: embedded (metadata later) | `plugins/linux-pipewire/screencast-portal.c`, `portal.c`, `pipewire.c` |
| Linux, X11 | portal if there is one, else XShm | XComposite | XFixes | `plugins/linux-capture/xshm-input.c`, `xcomposite-input.c`, `xcursor-xcb.c` |

Points that matter, from reading OBS:

- **WGC** wraps the D3D11 device as a WinRT `IDirect3DDevice`, makes a
  frame pool of 2 BGRA buffers and recreates it when the size changes.
  The yellow border can only be removed on Windows 11
  (`IsBorderRequired`). Size comes from the texture, not `ContentSize`.
- **Desktop duplication** is polled with `AcquireNextFrame(0)` and needs
  rebuilding on mode changes and device loss.
- **Window lists** skip cloaked and tool windows and handle UWP frames;
  ours should do the same and also skip yap's own windows.
- **SCK** can deliver NV12 (`kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`)
  as an IOSurface-backed `CVPixelBuffer`, which goes into VideoToolbox
  as is. OBS asks for BGRA because it composites; we don't need to.
  macOS asks the user for Screen Recording permission the first time.
- **The portal** shows its own picker, so on Wayland our source list is
  "whatever the portal offers". `persist_mode=2` with a `restore_token`
  remembers the choice. PipeWire gives DMA-BUFs if we offer modifiers
  (from EGL), else shared memory; the shm path comes first, DMA-BUF in
  the zero-copy phase.

#### Conversion and encoding

The capture is BGRA; encoders want NV12. The conversion is two small
shaders (Y at full size, UV at half) drawn into the planes of an NV12
texture, BT.709, limited range. OBS: `libobs/data/format_conversion.effect`
(`NV12_Y`, `NV12_UV`), `libobs/obs-video.c` (`render_convert_texture`).

Encoding is FFmpeg's `avcodec` with hardware frames, so the frame
doesn't leave the GPU:

| Platform | Path | Encoders, best first |
| --- | --- | --- |
| Windows | capture texture → NV12 shader → `AV_PIX_FMT_D3D11` frame from a hwframes pool on the capture device | `av1_nvenc`, `hevc_nvenc`, `h264_nvenc`; `av1_amf`, `hevc_amf`, `h264_amf`; `av1_qsv`, `hevc_qsv`, `h264_qsv` (D3D11 mapped to QSV) |
| macOS | SCK NV12 `CVPixelBuffer` → `AV_PIX_FMT_VIDEOTOOLBOX` frame | `hevc_videotoolbox`, `h264_videotoolbox` |
| Linux | first: shm → `swscale` → upload. Later: DMA-BUF → VA-API surface (`hwmap`) → `scale_vaapi` to NV12 | `av1_vaapi`, `hevc_vaapi`, `h264_vaapi`; `*_nvenc` (CUDA) on NVIDIA |

Low-latency settings, the same idea for each (OBS sets most of these
differently because it records and streams):

- No B-frames, no lookahead, no frame reordering, one frame in flight
  (`delay 0`, `async_depth 1`).
- NVENC: `tune ull`, `zerolatency 1`, CBR with a VBV of about one or two
  frames. AMF: `usage ultralowlatency`. QSV: `low_power 1`.
  VideoToolbox: `realtime 1`, `prio_speed 1`, low-latency rate control
  (OBS doesn't set these).
- Keyframes on request, with a safety keyframe every 10 seconds. Later,
  intra refresh (NVENC, AMF, QSV support it) instead of big keyframes.
- Screen content: AV1's screen-content tools where the encoder offers
  them; otherwise nothing special.

Which encoder: the best codec the hardware encodes (AV1, then HEVC, then
H.264), each tried in turn at start-up with a tiny test encode, because
"the driver says it exists" and "it opens" differ. Overridable in
settings. No software encoder in the first version (D5); OpenH264 came
later, as the last choice.

#### Decoding and presenting

FFmpeg decoders with hardware decoding where it works (`d3d11va` on
Windows, `videotoolbox` on macOS, `vaapi` or `nvdec` on Linux), software
otherwise (`h264`, `hevc`, `libdav1d`). The decoder runs on a thread of
its own; `yv_view_present` on the UI thread hands over the newest frame
and throws away older ones, so a slow UI never backs up the decoder.

- **D3D11.** The library decodes on a device of its own on the same
  adapter as the client's, converts NV12 to RGBA there into a ring of
  three shared textures with keyed mutexes, and opens them once on the
  client's device. `present` returns the client-side
  `ID3D11ShaderResourceView` of the newest. No copies through memory,
  and the client's immediate context is never touched from another
  thread. (OBS: `GS_SHARED_KM_TEX`, `libobs-d3d11/d3d11-texture2d.cpp`.)
- **OpenGL, first version.** Frames come back to memory as NV12
  (`av_hwframe_transfer_data` if decoded in hardware), `present` uploads
  the two planes and converts them into an RGBA texture with the
  library's own shader, in the client's context, with GL functions from
  `gl_get_proc`. 1440p60 NV12 is about 330 MB/s, which is fine.
- **OpenGL, zero-copy, later.** macOS: VideoToolbox's IOSurface into
  `CGLTexImageIOSurface2D`. Linux: VA-API surface exported as a DMA-BUF
  and imported with `EGL_LINUX_DMA_BUF_EXT`, which needs the client's
  GL context to be EGL rather than GLX on X11 (a GLFW hint; D8).

### Transport

Moving 8–20 Mbit/s to each viewer with a 60fps frame every 16ms. Three
options:

1. **The bulk link as it is**, with its limits raised. Least new code,
   but the server's single loop handles one packet per turn and then
   runs every sync phase, so a busy share makes chat and snapshots wait,
   which is what next item 5 set out to stop.
2. **TCP.** Simple and reliable, but one lost packet stalls everything
   behind it for a round trip; at 60fps that's a visible hitch every
   time. Real-time video over TCP is what we'd like to avoid.
3. **A media link: a third UDP link, on its own port and its own server
   thread.** Recommended (D3).

The media link works like the bulk link (next 5): a hello with the
connection's `conn_id` and `link = Media` binds a third Noise session to
the same connection, so it's authenticated by the main link's login and
needs no new crypto. What's different:

- **Its own port** (`video.port` in config.json, default `port + 1`, 0 to
  turn video off), its own UDP socket and **its own thread** on the
  server. The main loop never sees a video packet.
- **The thread does the handshake, the relay, Watch, Keyframe and NACK
  itself.** What it needs to know from the main thread (who's which
  user, in which room, sharing or not, allowed or not) is a small table
  the main thread updates under a mutex whenever those change. A viewer
  list per sharer replaces scanning every session per fragment.
- **A replay window of 1024 packets** instead of 64, for this link only.
- **Socket buffers of 4–8 MB** each way, and the client takes everything
  waiting on the socket every turn, not 16 packets.
- **Fragments stay under 1200 bytes**, as now: no IP fragmentation, no
  MTU discovery.

Its protocol is today's video messages with these changes:

- `Video_Codec` gets `HEVC = 1` and `AV1 = 2`. The rest of the fragment
  header stays.
- `MAX_VIDEO_FRAME_SIZE` goes to 2 MiB, the per-sharer rate to a server
  setting (`video.max_kbit`, default 20000), the client's pace to the
  encoder's bitrate plus a margin.
- **Nack** (new, viewer → server): `[sharer u32][frame u32][first u16][bitmap u64]`,
  fragments missing from a frame.
- **Report** (new, viewer → server → sharer, later): loss and delay, for
  adapting the bitrate.
- `Server_Info` gets the media port and the rate limit, so the client
  knows where to connect and what it may send. `HELLO_VERSION` goes up.

The web build has a media link too: the relay takes WebSockets under
`/yap-media/` to the media port, as it takes `/yap/` to the main one.
(As built, 2026-10-14: the plan here was for the web build to keep its
video on the bulk link, which left natives' shares unwatchable in a
browser. Video on the bulk link is gone; without a media link there's
no screen sharing.)

### Loss and pacing

- **The server keeps the last 500ms of each sharer's fragments**, about
  1 MB at 15 Mbit/s. A viewer who sees a gap in fragment indices or
  frame numbers sends a Nack; the server resends from its cache. One
  viewer–server round trip, nothing from the sharer, and the sharer's
  upload isn't spent on retransmissions. Fragments are asked for once
  more if the resend is lost too, then the frame is given up on.
- **The viewer reassembles several frames at once** (a window of, say,
  8), decodes in order as soon as each is complete, and gives up on a
  frame after about two frame intervals plus a round trip. Giving up
  means skipping to the next keyframe and asking for one, as now.
- **The sharer paces each frame's fragments** over most of the frame
  interval instead of in one burst, so a keyframe doesn't overflow
  router buffers. Token bucket at about 1.5× the bitrate.
- **FEC** (a parity fragment every N) is left for later; NACK from a
  server that's usually close to the viewer is cheaper and enough.

### Bitrate

One stream goes to every viewer unchanged, so it has to suit the worst
of them. First version: a preset chosen by the sharer (720p60 4 Mbit/s,
1080p60 8, 1440p60 15, source at 60 and 20, plus "custom"), capped by
the server's limit. Later: viewers report loss and delay, the server
passes the worst to the sharer, the sharer's library adjusts
(`yv_share_set_bitrate`; NVENC, AMF and QSV reconfigure without a new
keyframe). A viewer far worse off than the rest is told so in the UI
rather than dragging everyone down.

### What changes in the client

- `conn/video_native.odin`: loads `yap_video` from next to the
  executable at start-up, checks `YV_API_VERSION`, and implements the
  same procs as `video_web.odin` with it. No library, or a library of
  another version: the stubs' answers, as today.
- `conn/media.odin` (new): the third link, like `conn/bulk.odin`.
  `conn/video.odin`: send and receive on it, the multi-frame assembler,
  Nack, the new limits.
- `render`: `gpu_texture_wrap(native) -> Gpu_Texture` and its unwrap, on
  both backends: an SRV the D3D11 backend doesn't own, a GL texture name
  the GL backend doesn't delete. `video_upload` becomes "wrap whatever
  `yv_view_present` returned".
- `ui_video.odin`: a source picker (monitors and windows by name; the OS
  picker on Wayland and newer macOS), the preset, and under "advanced"
  codec, encoder, bitrate and fps. A small stats line (resolution, fps,
  bitrate, loss, decoder) for those who turn it on.
- The UI loop already wakes on `ui_redraw_at`; at 60fps it should wake
  when the library has a new frame (a callback that posts an empty GLFW
  event) rather than drawing at 240Hz.

### What changes in the server

- `server/media.odin` (new): the thread, its socket, its sessions, the
  relay, the cache, Nack.
- `server/video.odin`: the shared table, fed by `conn_set_room` and the
  `Sharing` flag; Watch and Keyframe handling move to the media thread.
- `config.odin`: `video { port, max_kbit, cache_ms }`.

No new dependencies, still one binary.

## Phases

| # | Phase | Size | Where | Depends on | Status |
| --- | --- | --- | --- | --- | --- |
| 1 | The library's skeleton, the FFmpeg build, a loopback tool | L | library, scripts | - | built (2026-10-12) on Windows and Linux (WSL); macOS not yet built |
| 2 | Decoding and presenting; natives watch web shares | M | library, client | 1 | done (2026-10-12): a Linux client watched a web share |
| 3 | Windows capture and encoding; natives share over the bulk link | L | library, client | 2 | done (2026-10-12): two Windows clients share and watch |
| 4 | The media link | L | protocol, server, client | 3 | done (2026-10-13): two Windows clients over it |
| 5 | Nack, the server's cache, pacing | M | protocol, server, client | 4 | built (2026-10-13); tested in proto, conn and the server, not yet with a real share |
| 6 | Linux capture and encoding | L | library | 3 | done (2026-10-13): the portal and VA-API on Arch (AMD, Wayland); X11 listing under XWayland; a full X11 session not yet |
| 7 | macOS capture and encoding | M | library | 3 | done (2026-10-13): CI builds it; sharing and watching on a Mac |
| 8 | The UI: picker, presets, advanced settings, stats | M | client | 3 | done (2026-10-13): Wayland's and macOS's pickers, the settings |
| 9 | Zero-copy on Linux and macOS | M | library, client | 6, 7 | built (2026-10-13); builds on Linux, macOS waits for CI; not yet tried |
| 10 | Adapting the bitrate | M | protocol, server, client, library | 5 | built (2026-10-13); tested in proto, conn, the server and yv-loopback, not yet with real viewers |

Why this order:

- **1 stands alone.** The loopback tool (`yv-loopback`: capture → encode
  → decode → show in a window, with latency and bitrate printed) proves
  the library on each platform with nothing of yap involved, and stays
  useful for testing encoders on new hardware.
- **2 before 3**: decoding web shares in the native client needs no
  protocol change at all (they're H.264 on the bulk link already), and
  it settles the hardest client-side part, getting the library's texture
  drawn by `render`, early.
- **3 on the bulk link first**, with its limits raised a little, so
  native sharing works end to end before the transport is redone; 4 then
  has something real to measure.
- **4 → 5**: the media link makes the bitrates possible, Nack makes them
  watchable over real networks.
- **6, 7 in parallel** with 4 and 5 once 3 has settled the library's
  shape on Windows.
- **9 and 10 last**: they're about cost and robustness, not about it
  working.

### 1. Skeleton, FFmpeg, loopback

`src/video/` with CMake, `yap_video.h`, the context and logging, source
listing on Windows (monitors via `EnumDisplayMonitors`/DXGI outputs,
windows via `EnumWindows` filtered as OBS does), encoder probing.
`scripts/build-video.sh` / `.bat` and `scripts/fetch-ffmpeg.sh` build
dav1d, libvpl and FFmpeg with the configure line kept in one place.
`yv-loopback` for Windows.

Checked: the library builds on all three platforms from a clean
checkout; `yv-loopback --list` shows monitors, windows and working
encoders on an NVIDIA, an AMD and an Intel machine.

*As built:*

- **FFmpeg is fetched prebuilt, not built.** Building it on Windows
  needs MSYS2's make and a POSIX shell, and dav1d needs meson; none of
  that is otherwise needed for yap. BtbN's LGPL shared builds
  (github.com/BtbN/FFmpeg-Builds) have everything the plan lists
  (NVENC, AMF, QSV through libvpl, VA-API, D3D11VA, dav1d), nothing
  GPL, and MSVC import libraries. `scripts/ffmpeg.version` pins one
  autobuild with its SHA-256 sums; `build-video.bat` fetches the
  Windows zip, `fetch-ffmpeg.sh` the x86_64 Linux tarball. macOS uses
  the system's FFmpeg through pkg-config until phase 7 decides. The
  catch: BtbN deletes old autobuilds after a while, so the pin has to be
  moved when the download stops working (the version file says how).
- **FFmpeg 8.1, not 9.0.** BtbN builds 9.0 against the NVENC 13.1
  headers, which want NVIDIA driver 610 or later; on driver 576 every
  NVENC encoder failed to open. 8.0 and 8.1 use the 13.0 headers
  (driver 570, early 2025). Whoever moves the pin has to check this.
- **Later (2026-10-19): the system's FFmpeg on Linux and macOS.**
  yap_video no longer links FFmpeg there: `src/ffmpeg.cpp` opens it at
  run time, from the library's own folder first (what we ship), else the
  system's, FFmpeg 8 (`libavcodec.so.62`) or 9 (`.so.63`). Built
  against 8.1's headers, all 69 fields and 42 constants the library
  uses are the same in 9.0, and its 49 functions are all there; FFmpeg
  7.1 lays AVFrame and AVCodecContext out differently, so it isn't
  taken. Without H.264 decoding an FFmpeg is no use (`yv_create`
  fails); HEVC and AV1 are offered only when it decodes them
  (`yv_decodable_codecs`, API 9). Windows still links its DLLs.
- **Later (2026-10-19): linked into the client on Linux.** build.sh
  builds `src/client/conn/libyap_video.a` (CMake, `YV_STATIC`) and
  copies the compiler's `libstdc++.a` beside it, which the client links
  too, so yap needs no particular `libstdc++.so` (only `libgcc_s`).
  The Linux yap-video download is just FFmpeg's libraries now, for
  systems without FFmpeg 8 or 9. macOS and Windows keep the add-on.
- **Much bigger than the plan guessed:** `avcodec-62.dll` alone is
  87 MB, about 91 MB with `avutil` and `swresample`, because BtbN's
  builds carry every codec. Fine per the goals, but if it matters, our
  own FFmpeg build with only the codecs we use is the way to shrink it.
- **Library:** `src/video/` (CMake, C++20, static CRT on Windows).
  `include/yap_video.h` is the C API: `yv_create`/`yv_destroy` with an
  API version check (`yv_api_version`, so the client can check before
  calling anything else), `yv_version_string`, `yv_list_sources`,
  `yv_system_picker`, `yv_list_encoders`. `yv_init` already has the GPU
  fields (`YV_GPU_NONE` for tools). One log callback for the whole
  library, because FFmpeg's log is global; FFmpeg's lines are gathered
  per thread and passed on with a `ffmpeg:` prefix, and `Quiet_FFmpeg`
  turns its errors into debug messages while probing.
- **Sources on Windows** (`sources_win.cpp`): monitors from
  `EnumDisplayMonitors`, with real pixel sizes from
  `EnumDisplaySettings` (whatever the DPI awareness) and model names
  from `QueryDisplayConfig`/`DisplayConfigGetDeviceInfo`; windows from
  `EnumWindows` with the Alt+Tab rules (visible, not a child or tool
  window, not cloaked, titled, not the desktop or taskbars, not our own
  process) and the frame bounds from DWM. UWP windows are named after
  the app behind `ApplicationFrameHost.exe`. Other platforms list
  nothing yet (`sources_other.cpp`).
- **Encoders** (`encoders.cpp`): per platform, the hardware encoders in
  order of preference; each opened and fed one 640x480 NV12 frame, and
  it "works" if a packet comes out. Working ones first. VA-API encoders
  get a device and a frame pool, since they don't take frames from
  memory. Probing runs once, on the first `yv_list_encoders`.
- **`yv-loopback --list [--debug]`** prints the version, monitors,
  windows and encoders.
- `scripts/build-video.bat` / `build-video.sh` configure, build and
  install into `bin/`, and copy only `avcodec`, `avutil` and
  `swresample` from FFmpeg.
- **Tried:** Windows 10 with an RTX 4060 Ti (driver 576.88): the build
  works from a clean `.cache`, the AV1, HEVC and H.264 NVENC encoders
  work, AMF and QSV are listed as not working (no such GPU). Not tried
  yet: AMD, Intel, and building on Linux or macOS. This machine was used
  over Remote Desktop, so it showed one virtual monitor without a model
  name; desktop duplication won't work in such a session, so phase 3
  needs testing at the machine itself.

### 2. Decoding, presenting, watching web shares

`yv_view_*` with the D3D11 shared-texture path and the GL upload path.
`gpu_texture_wrap` in both backends. `video_native.odin` loads the
library and implements `video_can_watch`, `video_show_frame`,
`video_upload`. The web share protocol is unchanged.

Checked: a native client on Windows and Linux watches a web client's
share; without the library the client behaves as today; the D3D11 debug
layer is quiet.

*As built:*

- **The API** (`yap_video.h`): the GPU moved out of `yv_init` into
  `yv_set_gpu(ctx, gpu)`, because the client's device comes and goes
  with its window (`window_close`, `reset_gpu`) while the library stays.
  The client calls it again with NULL before the device goes. Watching
  is `yv_view_create/destroy`, `yv_view_push` (any thread; the frame is
  copied), `yv_view_clear` (another sharer, or none),
  `yv_view_take_failed` (once, after the decoder gave up: ask for a
  keyframe) and `yv_view_present` (the drawing thread; the newest
  picture as an `ID3D11ShaderResourceView*` or GL texture name, its
  size, frames decoded, hardware or not).
- **The decoder** (`view.cpp`) runs on a thread per view. Frames wait in
  a queue of at most 8; more means it can't keep up, which fails like a
  broken stream: everything is dropped and it waits for a keyframe.
  `AV_CODEC_FLAG_LOW_DELAY` and slice threads only, since frame threads
  hold frames back. The decoder is made on the first keyframe, again
  when the codec changes, and again after a failure.
  - H.264 and HEVC: FFmpeg's decoders with a D3D11VA (or VA-API,
    VideoToolbox) device. They fall back to software by themselves when
    the hardware won't do a stream.
  - AV1: FFmpeg's own decoder only drives hardware and has no fallback,
    so it's only used when the GPU lists DXVA's AV1 profile; otherwise
    dav1d (`max_frame_delay 1`).
  - `YAP_VIDEO_SOFTWARE=1` turns hardware decoding off, to try the
    software path on a machine that decodes everything.
- **D3D11** (`output_d3d11.cpp`), as planned:
  - The library decodes on a device of its own, on the client's adapter
    (found by LUID; the default adapter until the client says).
  - Each frame is copied out of the decoder's texture array into an
    NV12/P010 texture shaders can read. Software frames are uploaded
    into an R8 and an R8G8 texture instead. A shader converts either to
    RGBA into one of three shared keyed-mutex textures.
  - `present` copies the newest of those into a texture on the client's
    device, which is what the client draws.
  - The CPU tracks which slot is being read and which is newest, so the
    keyed mutexes (always key 0) only order the two devices' GPU work.
  - If the decoder's textures can't be made readable, frames go through
    memory instead. If the client moves to another adapter, the decoder
    is made again there (and asks for a keyframe).
- **OpenGL** (`output_gl.cpp`): frames come back to memory as NV12, and
  `present` uploads the planes and converts them into an RGBA texture
  with the same shader in GLSL. GL 3.3 functions are loaded through
  `gl_get_proc`, and the client's GL state is put back afterwards. AV1
  always uses dav1d here for now. **Written but not built or run
  anywhere yet.**
- **Colour** (`yuv.cpp`): the frame's matrix (BT.601, 709 or 2020) and
  range, from its colorspace and range tags; untagged is BT.709
  limited. Software frames other than I420/NV12 go through swscale, so
  `swscale` is linked and shipped too.
- **`yv-loopback --play <file> [--fps N] [--seconds S] [--once]
  [--dump picture.bmp]`** (Windows): it splits an Annex B (.h264/.hevc)
  or OBU (.obu) file into frames, pushes them from another thread at the
  given rate, and draws what the view presents in a window with a
  SINGLETHREADED device of its own, like the client's. It prints frames
  pushed and decoded each second, and can save the last picture.
- **Client:**
  - `render`: `gpu_native` (the D3D11 device, or `glfwGetProcAddress`)
    and `gpu_texture_wrap`/`unwrap`. A wrapped D3D11 texture is a
    `D3D_Texture` marked borrowed, which delete doesn't release; in GL
    it's just the name.
  - `conn` owns the picture's texture now. `video_upload(texture)`
    became `video_picture(gpu) -> (texture, w, h, ok)` plus
    `video_forget_gpu(gpu)`, for both web and desktop, so `UI_Video` no
    longer keeps a texture or a size.
  - `video_native.odin` loads `yap_video` from the executable's folder
    on first use (`sync.once_do` + `dynlib.initialize_symbols` with the
    `yv_` prefix). It checks the procedure count and API version, and
    routes the library's log into ours. It implements watching; sharing
    still says no.
  - `window_close` now lets go of the video texture before the
    renderer, since a GL context can only be cleaned up while current.
  - Fullscreen on the desktop is the picture filling the window
    (Escape or Exit leaves it), not the window filling the screen.
- **Tried, on Windows 10 with an RTX 4060 Ti over Remote Desktop:**
  - `yv-loopback --play` with 1080p60 H.264, HEVC and AV1 from NVENC
    decodes 60 frames a second in hardware, about two frames behind
    what was pushed.
  - With `YAP_VIDEO_SOFTWARE=1`, H.264 and AV1 (dav1d) also keep up at
    60.
  - The saved pictures are right way up. A BT.709-tagged stream's
    colour bars come out exact (red 253,0,1; blue 1,0,255).
  - The client builds with `-vet -strict-style`. `odin check` for
    Linux, macOS and WASI finds nothing but the C libraries that aren't
    built here. The video queue tests pass.
- **Linux build fixes** (found building in WSL, Ubuntu 24.04):
  - FFmpeg is linked by full path, with `-rpath-link` for
    `yv-loopback`. Before, linking the tool failed on FFmpeg's symbols.
  - The library and the tool are linked with `--disable-new-dtags`, so
    their `$ORIGIN` is a DT_RPATH. A DT_RUNPATH only covers an object's
    own dependencies, and BtbN's FFmpeg libraries have no run path of
    their own, so `libavcodec` couldn't find `libswresample`. That
    would also have stopped the client from loading the library.
  - BtbN's FFmpeg reaches libva through stubs that abort the process
    when libva isn't installed. `vaapi_installed()` (a `dlopen` of
    `libva.so.2` and `libva-drm.so.2`) now guards every use of VA-API
    in the encoder probe and the GL output's decoder.
  - `build-video.sh` builds in `.cache/video-build-<system>`, so a WSL
    build in a Windows checkout doesn't clash with `build-video.bat`'s.
  - In WSL the NVENC encoders work through the GPU pass-through; VA-API
    is listed as not working (no libva).
- **Not tried:**
  - A native client watching a web share (needs a server, a browser
    sharing, and someone at the client).
  - The D3D11 debug layer.
  - The GL path, AMD and Intel GPUs, Linux and macOS.

### 3. Windows capture and encoding; sharing over the bulk link

WGC monitor and window capture, DXGI duplication as the fallback, the
NV12 shaders, NVENC/AMF/QSV through FFmpeg with D3D11 frames, the
low-latency settings. `video_native.odin` implements the sharing procs.
The bulk link's limits raised enough for 1080p60 at 6 Mbit/s to one or
two viewers on a LAN (rate, frame size, replay window, bulk receive).

Checked: 1080p60 between two native Windows clients on a LAN, latency
measured with `yv-loopback` and by filming both screens; GPU and CPU use
noted per vendor.

*As built:*

- **The API** (`YV_API_VERSION` 2):
  - `yv_share_start(ctx, config)` with a source (kind and id from
    `yv_list_sources`), an encoder name (or "" for the best that works),
    fps, the largest size, kbit/s and the cursor.
  - `yv_share_pull` returns the next packet with its data, `pts_us`,
    codec and key flag. The data is the library's until the next pull.
  - `yv_share_request_key`, `yv_share_get_state` (starting, live,
    failed), `yv_share_error` and `yv_share_stop`.
  - `yv_clock_us`, the clock `pts_us` counts on.
  - `yv_picture` gained the `pts_us` the frame was pushed with, so
    latency can be measured end to end.
- **Sharing** (`share.cpp`, the same on every platform):
  - A thread per share waits for captures and encodes at most `fps` of
    them a second. A still screen captures nothing new, so nothing is
    encoded. A keyframe asked for in the meantime is made from the last
    capture again.
  - A change of size makes a new encoder, which starts with a keyframe.
  - At most 8 packets wait to be pulled. More than that drops them all,
    and the next frame is a keyframe.
  - Encoder settings: no B-frames, a keyframe every 10 s and whenever
    asked (`pict_type` I; `forced-idr` for NVENC and QSV), VBR with a
    peak of 1.5× the rate and half a second of buffer, BT.709 limited.
    Per family: NVENC `p4`/`ll`/`zerolatency`/`delay 0`; AMF
    `ultralowlatency`; QSV `veryfast`/`async_depth 1`/no lookahead;
    VA-API `async_depth 1`; VideoToolbox `realtime`/`prio_speed`.
  - `Parameter_Sets` keeps the latest SPS/PPS(/VPS), or AV1 sequence
    header, from the encoder's output, and puts them in front of any
    keyframe that came without, so a viewer can always start from one.
- **Capture on Windows** (`capture_win.cpp`): Windows.Graphics.Capture
  through C++/WinRT from the Windows SDK (linking `windowsapp`), for
  monitors and windows alike.
  - A free-threaded frame pool on our own D3D11 device signals an
    event. The newest frame is copied into a texture of ours with a
    full mip chain, which is kept for encoding again.
  - The pool is recreated when a window changes size.
  - The cursor goes in through `IsCursorCaptureEnabled`. The border is
    turned off where Windows allows it (11), and stays on 10.
  - The device is on the GPU of the encoder's vendor where there's a
    choice, since NVENC needs an NVIDIA device to take D3D11 frames.
- **Conversion:** two shader passes, Y into an R8 view and UV at half
  size into an R8G8 view of an NV12 texture, sampling the mips
  trilinearly to scale down without aliasing.
  - The target is a frame from the encoder's own D3D11 pool
    (`initial_pool_size 0`, one texture per frame, `BindFlags`
    render target), for encoders that take `AV_PIX_FMT_D3D11` (NVENC,
    AMF). So the picture never leaves the GPU.
  - Other encoders (QSV) get frames through a staging texture.
  - `YAP_VIDEO_SOFTWARE=1` forces that way too, for trying it.
- **Desktop duplication isn't done.** WGC covers monitors from 1903 on
  (D10), and duplication's only gain here is no border on Windows 10.
  It's left for later.
- **`yv-loopback --share [--monitor ID | --window ID] [--encoder NAME]
  [--kbit N] [--fps N] [--max WxH]`** shares into its own window
  through a view. Every second it prints frames, Mbit/s, the time from
  capture to encoded packet, the time from capture to the picture
  being ready to draw, and keyframes.
- **Protocol:**
  - `Video_Codec` has `HEVC = 1` and `AV1 = 2`.
  - `MAX_VIDEO_FRAME_SIZE` is 1 MiB, up from 256 KiB.
  - The replay window is 1024 packets in 16 words, up from 64 (with a
    test for moving across words). The main link has the bigger window
    too; it costs 120 bytes a session.
  - No version bump: older clients ignore the new codecs, and the
    limits are each side's own.
- **Server:** 16 Mbit/s per sharer (was 4), and 4 MB receive and send
  buffers on its socket for keyframe bursts. Its loop still takes one
  packet per turn; that's phase 4's.
- **Client:**
  - Pacing is up to 12 Mbit/s (was 3). The bulk link takes 64 packets
    a turn (was 16) and has 2 MB of receive buffer.
  - Frames carry their codec (`Outgoing_Frame.codec`), and
    `video_capture_pull` returns it.
  - `video_native.odin` implements sharing. Whether sharing is offered
    is decided off the UI thread when the library loads: something
    must be listed to capture (so not on Linux and macOS yet) and an
    encoder must work.
  - One share for the client, behind a mutex, since the UI starts and
    stops it while a network thread pulls from it.
  - The preset is fixed for now: 1080p at most, 60 fps, 6 Mbit/s, and
    the best encoder that works.
- **UI:** on the desktop, Share opens a menu of monitors and windows
  (`share_menu`, beside the app audio menu), and picking one starts
  sharing it. The share button's hint says why a share failed (from the
  library), as the web's says to look in the console.
- **Note:** the web client only decodes H.264, and the best encoder is
  usually AV1 or HEVC, so web viewers of a native share see nothing (as
  D9 says). Choosing H.264 when web viewers are around would be a
  setting (phase 8) or a capability (later).
- **Tried, on Windows 10 with an RTX 4060 Ti over Remote Desktop:**
  - `yv-loopback --share` of the 2516x1351 desktop at 1080p, AV1 on
    NVENC from D3D11 frames, decoded in hardware: about 4 ms from
    capture to encoded packet, and about 30 ms to the picture being
    ready to draw.
  - Only about 32 fps, because Remote Desktop only updates the screen
    that often.
  - A window (Notepad) with H.264, and HEVC through memory
    (`YAP_VIDEO_SOFTWARE=1`, about 6 ms to the packet).
  - The saved picture is right.
  - Client, server and library build (the library on Linux too). The
    proto (83), conn (28) and server (115) tests pass. The Odin copies
    of the library's structs match the C ones in size and offsets.
- **Not tried:** two clients sharing and watching through a server,
  AMD and Intel, and 60 fps on a real screen.

### 4. The media link

As under Transport. The bulk link's limits go back to what they were.

Checked: three viewers at 15 Mbit/s each while chat, voice and a file
upload run, with voice unaffected (the next item 5 tests, extended);
the server's main loop never handles a video packet; a server with
`video.port = 0` refuses sharing cleanly.

*As built:*

- **Protocol:**
  - `Link.Media = 2`. No new `HELLO_VERSION`: only a server that names
    a media port is ever sent it, on that port.
  - `Server_Info` ends with `[media_port u16][video_kbit u32]`. Port 0
    means no media link; older servers don't send the fields.
  - The messages are the existing ones: Video, Watch, Keyframe, and
    Ping/Pong for the keepalive.
- **Server** (`media.odin`):
  - `Media` has its own socket (8 MB buffers each way) and its own
    thread. Its sessions, Watch leases, per-sharer budgets and keyframe
    throttling live on that thread.
  - The thread does its own handshakes with a copy of the server's
    key. It welcomes a hello with `link = Media` if the device has a
    logged-in (and verified) connection of that `conn_id`, with that
    connection's `instance`, and refuses it with `No_Connection`
    otherwise.
  - What the thread knows of the connections (key, number, `conn_id`,
    instance, room, sharing) is a table the main loop republishes
    under a mutex. It does this in a new sync phase (`media_sync`,
    `Loop_Phase.Media`) whenever the state version moves, and every
    second anyway.
  - Each second the thread drops sessions that are silent or too old,
    and those whose connection has gone or started over.
- **Shares on bulk links stay with the main loop**, for browsers and
  for desktop clients without a media link. So native clients still
  watch web shares on their bulk links.
  - Clients send Watch on both links.
  - Each side asks only its own sharers for keyframes. The main loop
    now asks a sharer only if their video came through it in the last
    `WATCH_LEASE` (`Video_State.last_video`), so a sharer is asked
    once.
- **Config:** `video {enabled, port, max_kbit}`.
  - On by default.
  - Port 0 means the one after the server's port.
  - 20000 kbit/s a sharer by default (D11).
  - Off, sharing goes through the main loop as before.
- **Client** (`conn/media.odin`): a third link like the bulk one. It's
  opened once the connection is logged in (`auth.state == .Done`),
  `Server_Info` has named a port, and the library is loaded
  (`video_can_watch`).
  - First built with `.Working`, which is a login underway, not
    done: a new device tried once mid-login and was refused, and a
    known device (through `.Working` at once) never tried at all.
    Found when two clients showed no `media link up`; a headless client
    against a local server reproduced it, and showed it up after the
    fix.
  - The address is the server's host with the media port.
  - It pings each second and rekeys on the same timers as the bulk
    link.
  - After 5 refusals in a row it gives up for that connection, and
    video goes over the bulk link.
  - It takes up to 256 packets a turn.
  - Our video goes out on the media link when it's up (`video_send`).
    Watch goes on both links (`send_watch`).
  - The web build has no media link.
- **Not as planned:** the bulk link's limits stay raised (16 Mbit/s on
  the server, 12 on the client). A desktop client whose media link
  can't be had (a firewall on the second port, the media link off)
  still shares at the same rate that way.
- **Tried:**
  - `test_media_link` (server): over loopback sockets, with the
    thread's packet handling called directly.
    - A wrong `conn_id` is refused, and the right one is welcomed with
      the connection's instance.
    - A viewer's Watch with need-key brings the sharer a Keyframe.
    - A fragment reaches the viewer, and not the sharer.
    - Nothing goes out once the sharer stops sharing, or when the
      viewer is in another room.
  - The server binary, with a config of only `port`, logs "media link
    on udp :17778".
  - The proto (83, two of them updated for the new layouts), conn (28)
    and server (116) tests pass. The client builds for Windows and
    type-checks for Linux and the web.
- **Not tried:** two clients sharing through the media link of a real
  server, and the load checks above (three viewers at 15 Mbit/s with
  chat, voice and a file upload).

### 5. Nack, cache, pacing

As under Loss and pacing. Also uses `YAP_LOSS_PERCENT` for testing.

Checked: at 2% random loss, 1080p60 shows no keyframe requests in a
minute and no visible freezes; at 10% it degrades to occasional
keyframes rather than a frozen picture.

*As built:*

- **Protocol:** `Nack = 48`, viewer to server on the media link:
  `[sharer u32][frame u32][first u16][missing u64]`, with bit i meaning
  fragment first + i (`proto/video_window.odin`). The main loop ignores
  it.
- **`proto.Video_Window`** replaces `Video_Assembler`, on the web too.
  - It collects up to 8 frames at once and hands them out complete and
    in order (`video_window_pop`).
  - Every frame number up to the newest gets a slot, so a frame that
    didn't come at all is missed as well.
  - What counts as missing is whatever lies before the newest fragment
    of the frame. Once a newer frame has come, or nothing has for
    20 ms (`TAIL_WAIT`), it's the whole rest of the frame. Of a frame
    of which nothing came, it's the start of it.
  - `video_window_nacks(now, asking)` asks after a 10 ms reorder wait
    (`REORDER_WAIT`), and again after 80 ms (`NACK_RETRY`). It gives the
    frame up after another 80 ms.
  - A frame given up on, or pushed out of the window, makes the window
    broken, and only a keyframe gets through, as before. While broken,
    `pop` goes straight to the first complete keyframe in the window.
  - Without a media link (`asking` false) there's nobody to ask, so a
    loss is given up on at the reorder wait. The keyframe request goes
    out about as soon as it used to.
  - It counts fragments asked for, frames saved and frames lost, which
    the client's debug stats line shows.
- **Server** (`media.odin`):
  - Each sharer has a ring of 2048 fragments, about 2.4 MB, made with
    their first fragment and freed when they stop sharing. It holds
    the Video messages exactly as they went out, found by frame and
    index.
  - Fragments older than `video.cache_ms` (500 by default, -1 for
    none, at most 5000) aren't sent again.
  - A Nack is answered from the ring, but only for the sharer the
    viewer holds a lease on. It's paid for from the viewer's own
    budget at the sharer's rate, so a viewer can't make the server
    send more than the sharer could.
- **Client:**
  - `drive_watch` sends the window's Nacks over the media link each
    turn. Frames the window gave up on are then let past (`show_frames`
    after `handle_video` and after the Nacks).
  - **Pacing** was already there (a token bucket, 16 KB bursts). It now
    goes at 1.5× the share's own bitrate (`video_share_kbit`, the
    desktop's 6 Mbit/s preset gives 9), so a keyframe goes out over
    several frames' time. The browser's share stays at
    `VIDEO_SEND_RATE`.
- **Not as planned:** no measurement of the round trip. The retry is a
  fixed 80 ms, which suits a LAN and most of a continent; a viewer
  much further away gives up a little early and asks for a keyframe
  instead.
- **Tried:**
  - proto tests of the window (7, replacing the assembler's 4):
    keyframe waiting, out of order, the largest frame, Nack and
    recovery, giving up, skipped frames, the Nack encoding.
  - `test_media_link` now also has a lost fragment sent again from the
    cache, and none for a sharer the viewer doesn't watch.
  - `test_video_loss_repaired` (conn): 120 frames through the real
    queue and the server's rewrite, every 10th fragment (16 in all)
    lost, a map standing in for the cache. All 120 come out in order,
    none given up, no keyframe needed.
  - The proto (86), conn (29) and server (116) suites pass. The client
    builds for Windows and type-checks for the web and Linux.
- **Not tried:** a real share with loss (`-define:YAP_LOSS_PERCENT=2`)
  between two clients.

### 6. Linux

The portal and PipeWire with shared memory, X11 with XShm and
XComposite, `swscale` to NV12, VA-API and NVENC. `yv-loopback` on
Linux. The portal's picker replaces ours on Wayland.

Checked: GNOME and KDE on Wayland, one X11 desktop; AMD, Intel and
NVIDIA.

*As built:*

- **Which way** (`capture_linux.cpp`): the portal on Wayland
  (`WAYLAND_DISPLAY` or `XDG_SESSION_TYPE=wayland`) if it offers
  ScreenCast, X11 otherwise, the portal if there's no X11 either.
  `YAP_VIDEO_CAPTURE=x11` or `portal` forces one. Not as planned: an
  X11 desktop uses our own list even when it has a portal, which keeps
  our picker there.
- **Loaded at run time.** XCB, GLib's GIO and PipeWire are opened with
  `dlopen` (`dl_linux.h`), into tables typed from their own headers.
  Only the headers are needed to build (`libxcb*-dev`,
  `libglib2.0-dev`, `libpipewire-0.3-dev`), and without them that way
  of capturing is left out with a warning. Without the libraries, the
  library still loads and decodes, and sharing says it isn't possible.
  `nm -D --undefined-only` shows no XCB, GLib or PipeWire symbols.
- **X11** (`x11_linux.cpp`), with XCB rather than Xlib: errors come
  per request, not through a process-wide handler, which GLFW's Xlib
  connection in the client relies on.
  - Monitors come from RandR 1.5 (or the whole screen). The id is the
    monitor's rectangle packed into 64 bits, as X11 has no handle for
    one.
  - Windows come from `_NET_CLIENT_LIST`, less unmapped ones, docks,
    desktops and our own (`_NET_WM_PID`). Without a window manager's
    list (WSLg), they're the root's children with `WM_STATE`, or their
    children with it.
  - A window is captured from its Composite pixmap, so what's in front
    of it doesn't matter. A minimised one keeps its last picture.
  - MIT-SHM where the server shares memory with us, GetImage otherwise.
  - X11 doesn't say when something changed. So the picture is taken at
    the share's rate, compared with the last, and only a changed one
    counts as new (a still screen still encodes nothing).
  - The cursor is XFixes' image, drawn in by us.
- **The portal** (`portal_linux.cpp`): CreateSession, SelectSources
  (monitor or window; cursor embedded or hidden), Start (the picker),
  OpenPipeWireRemote, over GDBus, each waiting for its Response signal.
  - `Pipeline::open` got the share's stop flag, so stopping while the
    picker is up closes it (Request.Close) instead of blocking
    `yv_share_stop` until the user answers.
  - A PipeWire stream on its own thread loop asks for BGRx, BGRA, RGBx
    or RGBA in memory (MemPtr, MemFd), at most `fps`, with the header
    and video crop metadata (a window inside a bigger buffer).
  - The newest buffer is copied out and handed over through three
    images (PipeWire's, the waiting one, the share's), so nothing is
    locked while converting.
  - The session's Closed signal, or the stream going away, ends the
    share ("what was shared went away").
  - The client needed no change: on Wayland `yv_list_sources` lists one
    source, "Screen or window (chosen in the system's picker)", whose
    share opens the portal. No restore token yet: each share asks again.
- **Conversion** (`Memory_Pipeline`): swscale from the captured RGB to
  NV12, BT.709 limited range, area averaging when scaling down.
  - NVENC takes that from memory.
  - The VA-API encoders get it uploaded to a VAAPI surface from a pool
    of the share's size: `hw_frames` now means "frames the pipeline can
    fill", and share.cpp gives them to any encoder that takes their
    format (before, D3D11 was assumed).
  - `YAP_VIDEO_SOFTWARE` no longer stops VA-API getting its surfaces,
    as it takes nothing else.
- **`yv-loopback --share` without a window** (`play_other.cpp`): on
  Linux it only encodes. Once a second it prints the rate, bitrate and
  time to encode. `--out` (on Windows too) saves the stream for
  `--play` or ffprobe.
- `fetch-ffmpeg.sh` strips CRs from `ffmpeg.version`, which a Windows
  checkout gives it, so WSL builds from the same tree.
- **Tried** in WSL (Ubuntu 24.04, WSLg, RTX 4060 Ti):
  - NVENC AV1, HEVC and H.264 all work.
  - An `ico` window at 800x600: 45–50 frames a second (what it draws),
    7–10 ms from capture to packet, every frame decodes in ffprobe.
  - A red window decodes as 254,0,0, tagged BT.709 limited.
  - Closing the window ends the share.
  - The Windows build and share still work.
- **Not tried:**
  - The portal and PipeWire (WSL has neither).
  - VA-API: Windows 10's WSL has no `/dev/dri`. The library fails
    cleanly without it.
  - MIT-SHM: WSLg's X server can't share memory with us.
  - Monitor capture: WSLg's XWayland is rootless, and GetImage on the
    root is a BadMatch there.
  - A Linux client sharing to others.
  - GNOME, KDE, a real X server, AMD and Intel all remain, as the
    plan says.

### 7. macOS

ScreenCaptureKit with NV12 straight into VideoToolbox; the permission
prompt handled (state "needs permission" shown in the UI with a button
to the settings page). On macOS 14+ the system picker
(`SCContentSharingPicker`) as on Wayland.

Checked: an Apple Silicon and an Intel Mac; 1080p60 HEVC.

*As built (unbuilt):* written on Windows without a Mac or its SDK, so
none of it has been compiled. The client's side type-checks for macOS.

- **Sources** (`sources_mac.mm`): SCShareableContent's displays (id is
  the CGDirectDisplayID; "Built-in display" or "Display N", as
  CoreGraphics has no names and NSScreen wants the main thread) and its
  windows on layer 0 with a title, less our own. Sizes are in pixels
  (points times the display's scale).
- **Permission:** `yv_capture_allowed(ctx, ask)` and
  `yv_open_capture_settings(ctx)` are new (API version 3). Elsewhere
  they're always true and do nothing.
  - Nothing asks ScreenCaptureKit for anything until Screen Recording is
    allowed. Asking is what makes macOS prompt, and the client lists
    sources as it starts, where a prompt would come out of nowhere.
    `yv_list_sources` lists nothing until then.
  - Client: until it's allowed, sharing is still offered (the probe
    doesn't need sources then). The share menu says what to allow, with
    "Allow screen recording", which shows macOS's prompt the first time
    and opens the settings page after that, and "Check again". macOS
    only counts the permission once yap has been started again, which
    the menu says.
- **Capture** (`capture_mac.mm`): an SCStream asked for `420v` (NV12,
  BT.709 limited) at the size the share encodes, at most `fps`, with
  the cursor if wanted; our own windows are left out of a display.
  ScreenCaptureKit converts and scales on the GPU.
  - Only complete frames count (idle ones are skipped). The newest
    CVPixelBuffer is handed to the share's thread; `didStopWithError`
    ends the share.
  - VideoToolbox gets that IOSurface backed buffer itself, wrapped as an
    `AV_PIX_FMT_VIDEOTOOLBOX` frame: nothing goes through memory, so
    the zero-copy half of phase 9 for macOS encoding is already here.
  - Anything else reads it back through swscale, also when the size
    differs from the encoder's.
- **Not as planned:** `SCContentSharingPicker` (macOS 14) isn't used.
  Our own list works on every version, and the system's picker belongs
  with phase 8, which makes the share button open it straight away, as
  for the portal.
- A resized window keeps the stream's first size (ScreenCaptureKit fits
  it in); following it would need `updateConfiguration`.
- `sources_other.cpp` and `capture_other.cpp` are gone: every platform
  has its own now. CMake builds the `.mm` files with ARC and links
  ScreenCaptureKit, CoreMedia, CoreVideo, CoreGraphics, Foundation and
  AppKit, for macOS 12.3 and later.
- `yv-loopback --list` says when capturing isn't allowed; `--share`
  asks (on macOS the permission is the terminal's).
- **Tried:** the Windows and Linux (WSL) builds, and the client
  type-checking for Windows, Linux, macOS and the web. Everything else
  waits for a Mac:
  - building, then `yv-loopback --list` and `--share --out`
  - the prompt and the settings page
  - VideoToolbox taking the buffers
  - the client sharing
- **FFmpeg and shipping**, added after the first try on a Mac:
  - macOS had no FFmpeg to fetch (it relied on Homebrew's, which is GPL
    and only works where Homebrew is). `scripts/build-ffmpeg-macos.sh`
    now builds a small LGPL one from pinned sources (FFmpeg 8.1.3, and
    dav1d 1.5.4 inside libavcodec for AV1 before the M3). It has the
    H.264, HEVC and AV1 decoders, the VideoToolbox encoders and decoding,
    and `@rpath` install names: 12 MB in all, against BtbN's 90 MB.
    `build-video.sh` uses it on macOS. Tried on Linux in WSL (without
    VideoToolbox): it builds in about 4 minutes, and yap_video links
    against it.
  - D12 is built. CI builds the add-on on all three platforms and
    uploads `yap-video-<platform>` next to `yap-<platform>`
    (`scripts/package-video.sh`): the library, FFmpeg's libraries,
    `ffmpeg-LICENSE.txt` (which build, where its source is), yv-loopback
    and a README. The release workflow zips it with the rest.
  - The add-on's CI steps are `continue-on-error`, so a broken add-on
    doesn't cost the client's artifacts. FFmpeg is cached (the archives;
    on macOS the whole build).
  - Not yet: the client's "needs the add-on" hint, and the macOS `.app`
    (the client looks next to its executable, inside the bundle, so the
    disk image doesn't take the add-on).

### 8. UI

Picker, presets, advanced settings, the stats line, waking the UI per
frame. Where the system picks (`yv_system_picker`: Wayland, later
macOS), the share button opens the system's picker straight away
rather than our menu with its one "Screen or window 0x0 (main)" entry.

*As built:*

- **Settings, "Screen sharing"** (`ui_share_settings.odin`, the
  desktop only: a browser shares what its picker says).
  - **Size:** 720p, 1080p (the default), 1440p, or "As it is", each with
    a bitrate for 60 fps: 4, 8, 15 and 20 Mbit/s (`conn.SHARE_PRESETS`).
  - **Advanced:** 30 or 60 fps (30 halves the preset's bitrate); a
    bitrate slider from 0.5 Mbit/s up to the server's limit (or 50),
    with "The size's" to go back; the encoder ("The best that works", or
    one of those that do); the pointer.
  - **Watching:** "Show figures under a screen you watch".
  - A line says what it comes to, and when the server holds the bitrate
    down (`Server_Info.video_kbit`, now in the View).
  - Without the add-on, the category says where to put it (the D12
    hint).
  - Changes apply from the next share. A share isn't restarted for
    them, which with the system's picker would ask again.
  - Saved as `share_preset`, `share_fps`, `share_kbit`,
    `share_encoder`, `share_cursor` and `share_stats` in settings.json.
  - The constants that were in `video_native.odin` are gone;
    `video_share_source` takes a `Share_Config`. Pacing goes by the
    share's own bitrate.
- **The system's picker:** where `yv_system_picker` says so, the share
  button opens it straight away (sharing source 0), without our menu.
  - On Wayland that's the portal.
  - On macOS 15 and later it's now `SCContentSharingPicker`
    (`capture_mac.mm`), shown from the main thread's queue, which the
    client's event loop runs. 14 has it too, but it's only from 15
    that it's meant to spare the Screen Recording permission, so it
    starts there.
  - `YAP_VIDEO_OUR_PICKER=1` keeps our list on macOS. `yv-loopback`
    always uses our list: a tool without an event loop on its main
    thread couldn't show the picker.
  - Saying no in a system picker is a new state, `YV_SHARE_CANCELLED`
    (`Pipeline::cancelled`). The button just goes back to Share, rather
    than showing an error.
- **Waking per frame:** `yv_view_on_frame` (API version 4) calls the
  client for each new picture, which wakes the UI (`ui_wake`). Before,
  the Screen tab asked for a frame every frame, but the loop slept up
  to 1/30 s between them, so a 60 fps share was shown at about 30. A
  page still asks every frame, as the browser paces it.
- **Figures** (`figures_line`), under the picture when asked for:
  - size, frame rate (from the decoded count), codec and bitrate;
  - GPU or CPU decoding;
  - fragments asked for again, frames saved, and frames lost (shown in
    the warning colour).
  - The network thread works them out once a second
    (`publish_video_stats`). `log_stats` now diffs the window's counts
    rather than zeroing them, so both can read them.
  - The share button's hint says how much is going out while sharing.
- **Not done:** thumbnails in the picker, and changing a running share's
  settings without starting it again (phase 10's
  `yv_share_set_bitrate` would cover the bitrate).
- **Tried:**
  - the library on Windows and Linux (WSL);
  - the client builds for Windows and type-checks for Linux, macOS and
    the web;
  - the proto (86) and conn (29) tests.
- **Not tried:** the UI itself, the macOS picker, and 60 fps on screen.

### 9. Zero-copy on Linux and macOS

PipeWire DMA-BUF into VA-API for encoding; VA-API → DMA-BUF → EGL image
and IOSurface → GL texture for presenting.

Checked: CPU use at 1440p60 compared before and after.

*As built:* the library only; the client didn't change.

- **Presenting** (`output_gl.cpp`, `gl_interop.h`): a frame decoded on
  the GPU is kept as it is, and its two NV12 planes are bound as
  textures where they lie, for the shader that was already there.
  - **Linux** (`gl_interop_linux.cpp`): the VA-API surface is mapped as
    DRM PRIME (DMA-BUFs with offsets, pitches and modifiers), and each
    plane is an EGL image, R8 and GR88, bound with
    `glEGLImageTargetTexture2DOES`. libEGL is loaded at run time.
  - **macOS** (`gl_interop_mac.cpp`): the CVPixelBuffer's IOSurface,
    each plane bound with `CGLTexImageIOSurface2D` as a rectangle
    texture; a second fragment shader samples those in pixels.
    *Since replaced:* the client draws with Metal on macOS now, and so
    does the library (`output_metal.mm`): each plane of the IOSurface is
    an `MTLTexture` (`newTextureWithDescriptor:iosurface:plane:`),
    converted on the client's own command queue, and the frame is held
    until that command buffer completes.
  - The frame is held until the next is bound, so the GPU is long done
    with it. The decoder gets three more surfaces for that
    (`extra_hw_frames`).
  - The first frame that won't go this way (GLX, a driver that won't
    export or import) is copied back where it is. From then on the
    decoder copies frames back itself, as before, until the GPU
    changes. `YAP_VIDEO_NO_INTEROP=1` forces the copy, to compare.
  - **Not as planned:** EGL on X11 (D8) isn't done. GLFW gives X11 a GLX
    context, which has no way in for DMA-BUFs, so X11 keeps the copy.
    Asking GLFW for EGL there would change every X11 client's context,
    sharing or not; it's left until someone needs it.
- **Capturing on Linux** (`portal_linux.cpp`, `vpp_linux.cpp`): with a
  VA-API encoder, the portal's stream is offered DMA-BUFs first, then
  memory.
  - Only linear DMA-BUFs are offered, which VA-API always imports. That
    avoids asking EGL for the GPU's tiled layouts (OBS's way), at the
    cost of the compositor writing linear buffers. If the compositor
    leaves the modifier to us, we fix it to linear.
  - The newest buffer is held, not copied. The share's thread imports it
    as a VA-API surface (`av_hwframe_map` from DRM PRIME). VA-API's own
    video processor scales it and converts it to BT.709 limited NV12,
    straight into the encoder's frame, and waits for that before giving
    the buffer back. Windows' crop is the processor's source region.
  - FFmpeg does this in libavfilter's `scale_vaapi`, which yap_video
    doesn't use, so it's libva's calls, loaded at run time. Building it
    needs `libva-dev` (now in CI); without it, memory only.
  - If VA-API won't import the buffers, the stream is renegotiated to
    shared memory, and capture goes on. Buffers PipeWire takes away (a
    new size) are never given back after. `YAP_VIDEO_NO_DMABUF=1`
    keeps to memory, to compare.
  - NVENC on Linux still takes frames from memory: CUDA's import of
    DMA-BUFs is another path, left for later.
  - X11 capture is unchanged: XShm is a copy whatever happens.
- **macOS encoding** had no copy already: ScreenCaptureKit's IOSurfaces
  go into VideoToolbox as they are (phase 7).
- **Tried:**
  - Linux (WSL) builds without warnings, with and without libva's
    headers, and calls nothing of libva, EGL, XCB, GLib or PipeWire
    directly.
  - Windows still shares and decodes on the GPU.
- **Not tried:** all of it on real hardware. WSL has no DMA-BUFs, VA-API
  or portal, and there's no Mac here; the macOS part waits for CI. To
  compare CPU use at 1440p60 (the check above), run with and without
  `YAP_VIDEO_NO_INTEROP=1` (watching) and `YAP_VIDEO_NO_DMABUF=1`
  (sharing on Wayland). The log says which way each went ("go to OpenGL
  as DMA-BUFs", "the portal sends ... in DMA-BUFs").

### 10. Adapting the bitrate

Reports, aggregation on the server, `yv_share_set_bitrate`.

*As built:*

- **Report** (`Message_Kind.Report = 49`, `proto/video_report.odin`),
  13 bytes each way, on the media link only.
  - **Viewer → server**, once a second (`send_report`):
    `[sharer u32][loss u16][delay u16][kbit u32]`.
    - Loss is fragments asked for again per thousand that came, so
      it's the network's loss before repair.
    - Delay is how much later than at their quickest (the least of the
      last 10 seconds) frames' first fragments arrive, against the
      sharer's clock (`note_delay`). The clocks' offset drops out, and
      what's left is a queue building up on the way.
    - kbit is what came in.
  - **Server → sharer**, once a second (`media_reports`):
    `[viewers u16][left out u16][loss u16][delay u16][kbit u32]`. It's
    the worst of that sharer's viewers in its room whose reports are
    under 3 seconds old (`summarize_reports`).
  - With three or more viewers, the single worst is left out when it's
    far behind the next (5 points more loss, or 200 ms more delay).
    Its own figures line then says it's losing frames ("more than your
    connection takes"), and the sharer's button says one viewer was too
    far behind to go by.
  - The main loop ignores Reports: a browser's share on the bulk link
    doesn't adapt.
- **The sharer's client** (`adapt_bitrate`):
  - **Down** by a quarter when the worst report shows 2% loss or 150 ms
    of delay, at most every 2 seconds. It goes from what reaches that
    viewer, unless that's under half (a still screen's trickle).
  - **Up** by a fifth of what it was set to after 4 seconds of good
    reports (under 0.5% and 40 ms).
  - Never under an eighth of what it was set to, nor over it. Back to as
    set after 10 seconds without reports (nobody watching).
  - Pacing follows the held bitrate.
  - The share button's hint says what it's held to, of what.
- **`yv_share_set_bitrate`** (API version 5):
  - NVENC and Quick Sync take the new rate as they go (`bit_rate` on the
    open context); AMF, VA-API and VideoToolbox are started again.
  - **Not as planned:** the plan had NVENC, AMF and QSV reconfigure
    "without a new keyframe". FFmpeg's NVENC forces one when it
    reconfigures (yv-loopback: 8 → 7 Mbit/s gave a keyframe). So every
    change costs one, and the library only takes a change of a fifth or
    more, at most every 3 seconds; the client's steps are a quarter and
    a fifth to match.
  - `yv-loopback --share --then-kbit N` switches 3 seconds in, to try
    it.
- **Tried:**
  - proto: Report both ways, and the summary with and without an
    outlier.
  - server: `test_media_link` sends a report through, and drops one
    about somebody the viewer doesn't watch.
  - conn: `test_adapt_bitrate` covers cuts, how often, the floor,
    going up, and back to as set.
  - yv-loopback with NVENC: 8 → 1 Mbit/s applied (0.7 measured after),
    8 → 7 ignored.
  - The proto (88), conn (30) and server (116) suites pass. The client
    builds for Windows and type-checks for Linux, macOS and the web.
- **Not tried:** real viewers on a congested link. With
  `-define:YAP_LOSS_PERCENT=3` on a viewer, the sharer's log should show
  "bitrate ... for our viewers".

## Later

- **Webcams.** A camera is another source (Media Foundation, AVFoundation,
  V4L2/PipeWire camera portal), the rest is the same. Several streams per
  user would need a stream id in the fragment header.
- **Web viewers of native shares.** The server could pass a native
  share to web viewers on their bulk link; WebCodecs decodes H.264
  everywhere and AV1/HEVC in most browsers. Bandwidth through the
  WebSocket relay is the question (D9).
- Intra refresh and reference invalidation instead of keyframes after
  loss.
- Thumbnails in the picker, HDR, sharing a region, the sharer's own
  preview, audio and video in sync.

## Decisions

Open until the owner answers. Recommended answers first.

| # | Question | Recommendation |
| --- | --- | --- |
| D1 | The library's language | C++20 behind a C header. WinRT and Objective-C++ need it; Odin would have to bind all of D3D11, WinRT, SCK and FFmpeg. |
| D2 | FFmpeg, or the vendors' SDKs directly | FFmpeg for both directions. |
| D3 | Transport | A third UDP link on its own port and server thread (Transport, option 3). |
| D4 | Codecs | Every viewer decodes H.264, HEVC and AV1; the sharer encodes the best its hardware can. No negotiation. |
| D5 | Software encoding | None at first: every GPU of the last ten years encodes H.264. OpenH264 later if someone needs it; it was needed (a GTX 1050 Ti on driver 560, too old for our FFmpeg's NVENC), so `libopenh264` is the last encoder tried. |
| D6 | HEVC's patents | Ship FFmpeg's HEVC decoder and use hardware HEVC encoders, as browsers and OBS do; make HEVC easy to switch off at build time. |
| D7 | Where the library lives | `src/video/` in this repository, built by its own script, never by `build.sh`/`build.bat`. Keeps the protocol and the library in step. |
| D8 | EGL instead of GLX on X11 | Only when phase 9 needs it, behind a check that EGL works. |
| D9 | Web clients watching native shares | Not now; keep the protocol able to (the codec byte is all a viewer needs). |
| D10 | Minimum OS versions | Windows 10 1903 (WGC), macOS 12.3 (SCK), Linux with PipeWire 0.3 and xdg-desktop-portal, or X11. |
| D11 | The server's default limit | 20 Mbit/s per sharer, 500ms of cache; the operator raises or lowers them, 0 turns video off. |
| D12 | Shipping | A separate archive per platform (`yap-video-<os>.zip`) to unpack next to the client; the client says "screen sharing needs the video add-on" with a link when it's missing. |

## Working through a phase

As in `misc/next`: read the "OBS:" references and the yap code the
phase touches, build it, write what turned out differently under
"*As built:*", tick it in the table.

A note on testing: We'll start the work on Windows, so code for other platforms has to be tested later.
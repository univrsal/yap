# Animated pictures: plan

Animated WebP and GIF, in the chat's picture previews, in the image
viewer and as the server's own emoji, for the `extended` client and
server. Nothing here is built yet. Each phase is its own commit or
series of commits; what turns out differently is written under its
section when it's done ("*As built:*"), as in `docs/next`.

Sizes as in `docs/extended`: S up to about 300 changed lines, M up to
1000, L up to 2500. "Client" means no protocol change; "protocol" means
new or changed requests or events.

| # | Change | Size | Where | Depends on | Status |
| --- | --- | --- | --- | --- | --- |
| 1 | Animated WebP in previews and the viewer (native) | L | client | - | done (2026-10-10) |
| 2 | Animated GIF in previews and the viewer (native) | S | client | 1 | done (2026-10-10) |
| 3 | The "Animate pictures" setting: hover (default), always, never | S | client | 1 | done (2026-10-10) |
| 4 | Animations on web (WebCodecs `ImageDecoder`) | M | client (web) | 1 | done (2026-10-10) |
| 5 | Animated pastes kept as they are | S | client | 1 | done (2026-10-10) |
| 6 | The server's emoji animated: frame grids made by the server | M | server, protocol | - | done (2026-10-10) |
| 7 | Drawing animated emoji | M | client | 6 | done (2026-10-10) |

Why this order:

- **1 first**: it's the core everything in the chat reuses (the worker
  holding a decoder, frames uploaded into a live texture, redraws on a
  clock), and it shows on its own: anything attached as a `.webp`
  animates.
- **2, 3 right after**: GIF is a second source of frames for the same
  machinery; the setting decides when that machinery runs, and has to
  be there before animations reach anyone, since the default (hover)
  is the less surprising behaviour.
- **4** is the same protocol to the browser: frames come from
  `ImageDecoder` rather than libwebp.
- **5** only needs 1 to show what it keeps.
- **6 → 7** are independent of 1–5 (emoji frames are decoded on the
  server, and the client gets a still grid): they could go first, but
  they change the protocol, so they go last, once the client side of
  animation has settled.

## What's there now

- A message's attached picture is fetched whole for its preview (up to
  `PREVIEW_MAX`, 8 MB, `conn/attachments.odin`), so an animated file
  already reaches the client as it was sent. It's decoded once on the
  worker thread (`ui_images_worker_native.odin`, `clipboard.decode`)
  into one texture with mipmaps (`ui_images_frame`), drawn by
  `image_fitted` and `image_viewer`, and textures are kept for the 96
  most recently drawn pictures (`trim_textures`).
- Native: `WebPDecodeRGBAInto` refuses an animation outright (it shows
  as "broken image"); stb_image reads a GIF's first frame.
- Web: `web/decode.js` (`createImageBitmap`) gives the first frame of
  either.
- The server's emoji (`src/server/emoji.odin`): `emoji/*.png`, each
  scaled into a 64 px cell, 16 to a row with a pixel of gap, written as
  one QOI (at most `MAX_BLOB_SIZE`, 1 MB), kept as a blob of kind
  `Emoji_Sheet` and named to clients in `Emoji_Sheet`. The client draws
  an emoji as a UV rect of the sheet's texture (`custom_emoji_icon`).
  Purging keeps the sheet by its meta key (`EMOJI_SHEET_META`,
  `retention.odin`).
- The client only draws when something changes (idle redraw):
  anything that changes on a clock must ask with `ui_redraw_at`.
- libwebp's cmake build already makes `libwebpdemux.a` (15 KB); build.sh
  doesn't copy it. The server links C already (SQLite), and the
  Dockerfile's build stage has cmake.

## 1. Animated WebP in previews and the viewer (native)

**libwebp:** build.sh and build.bat copy `libwebpdemux.a` /
`libwebpdemux.lib` beside the others, and `webp.odin` links it. The shim
(`yap_webp.c`) wraps `WebPAnimDecoder`, keeping its structs on the C
side as with the encoder:

	yap_webp_anim_open(data, size, &width, &height, &frames, &loops) -> handle (NULL if not an animation)
	yap_webp_anim_next(handle, &pixels, &timestamp_ms) -> 0 at the end
	yap_webp_anim_reset(handle)
	yap_webp_anim_close(handle)

`WebPAnimDecoder` does the blending and disposal and hands back the
whole canvas, RGBA, straight alpha (`MODE_RGBA`). `WebPGetFeatures`'
`has_animation` tells the two kinds apart before decoding.

**Frames are streamed, not decoded up front.** A 1080p animation of
200 frames is 1.6 GB of RGBA; a 480×270 one of 100 frames is 50 MB.
So each animated picture keeps one decoder on the worker and one
decoded frame ahead:

- A decode job for an animation comes back as the first frame (shown
  as now) plus an `Anim` the worker keeps: the decoder, the source
  bytes (the decoder points into them), the next frame and when it's
  due. Results carry a `next_due` so the UI knows when to ask.
- The UI asks for the next frame when the shown one's time is up
  (`Anim_Job{id}`); the worker hands over the frame it has ready and
  starts on the one after. Past the last frame it resets and loops
  (WebP's loop count is honoured; 0 is forever).
- The frame is uploaded into the picture's texture: a new
  `gpu_texture_update` (whole RGBA texture: `TexSubImage2D` in GL,
  `UpdateSubresource` in D3D11), beside `gpu_texture_update_rows`,
  which only does `.Alpha`. Animated textures are made without
  mipmaps (regenerating them every frame isn't worth it; they're drawn
  near their size).
- Durations of 10 ms or less count as 100 ms, as browsers do, and
  anything under 20 ms as 20 ms.

**Only what's drawn moves.** A picture asks for its next frame only
from `image_fitted`/`image_viewer`, i.e. while it's drawn: scrolled out
of sight, it stops where it is. When `trim_textures` drops a texture,
or `ui_images_switch` drops a server's pictures, the worker is told to
close its `Anim` (a `Drop_Job`); `ui_images_destroy` closes all.

**Redraws:** a frame that draws an animation calls
`ui_redraw_at(earliest next_due)`, so idle redraw still sleeps when
nothing moves. Animation redraws are capped at 30 a second (frames due
sooner are skipped in time, not slowed), and stop while the window is
minimised or unfocused (the frame shown stays).

Memory: per animated picture, the encoded file plus about two
canvases (current and next). `ui_memory.odin` counts them with the
other decoded pictures.

Tests: the shim on a small animated WebP made in the test (libwebp's
encoder can't make animations without libwebpmux, so a tiny
`testdata/anim.webp` checked in, made with `img2webp`): frame count,
timestamps, looping; a still WebP still decodes as before; dropping an
`Anim` frees everything (memtrack shows no leak).

*As built:* as planned, with these differences:

- The UI holds the frame ahead rather than the worker: a texture keeps
  `next` (the frame the worker handed over) and asks for the one after
  only once `next` has gone into the texture. The worker keeps just the
  decoder (`Decode_Worker.anims`, `ui_images_anim_native.odin`); jobs
  are `Decode`, `Next_Frame` and `Drop`, all carrying the generation,
  so a server switch can't drop or feed the wrong animation.
- The 30 a second cap is on the worker's side: frames shorter than
  33 ms are merged with the next (the last one's pixels, the sum of
  their times), so speed is kept and nothing is skipped on the UI side.
- `WebPAnimDecoder` opens a still WebP too, as one frame; an
  "animation" of one frame is treated as a still picture.
- Animations are moved on in `ui_images_frame` (`anims_advance`) for
  textures drawn the frame before; the viewer now marks its texture
  drawn too, so a picture plays in the viewer when its message is
  scrolled away. A focus callback (native only) redraws when the window
  gets the focus back. Pausing tests `glfw.WindowFocused` (and
  `ui.hidden`): minimised windows don't have the focus.
- Not counted on the memory page beyond the GPU texture: the frame
  ahead is on the heap (memtrack counts it), libwebp's canvases are
  malloc'd (not counted).
- Tests: `webp_test.odin` (shim: frames, timestamps, reset, stills) and
  `ui_images_anim_test.odin` (worker: order, times, the 10 ms → 100 ms
  rule, merging 20 ms frames, a loop count of 1 ending, Drop and stale
  generations). Fixtures in `src/client/webp/testdata`, made with PIL.
- Checked off-screen: a 320×200 4-frame WebP attached in a message
  showed its first frame (it used to say "broken image"), stayed still
  while the window had no focus, played red → green → blue → yellow at
  700 ms a frame with `YAP_ALWAYS_FOCUSED`, and played in the viewer.
  CPU over 10 s: 130 ms playing, 110 ms paused. The D3D11
  `gpu_texture_update` and build.bat's libwebpdemux are untested (no
  Windows here).

## 2. Animated GIF (native)

stb_image can't stream a GIF, but reads all of its frames at once
(`stbi_load_gif_from_memory`, with each frame's delay). So a GIF
animates when `width * height * 4 * frames` fits a budget (32 MB), and
shows its first frame otherwise. The frames live in the worker's
`Anim` like WebP's streamed ones, and the UI side doesn't know the
difference: `Anim` is a union of the two sources, with one
`anim_next`.

To know the size before decoding them all, the frame count comes from
walking the GIF's blocks (a few lines: image descriptors after the
header and colour tables), not from decoding.

GIF's delays are in hundredths of a second; the same 10 ms → 100 ms
rule applies (most GIFs that say 0 or 1 mean "as fast as you like" and
are shown at 10 fps by browsers).

*As built:* as planned. `Anim_Source` holds either a WebP decoder or a
GIF's frames (stb_image's buffers, freed with `stbi.image_free`), behind
`source_next`/`source_reset`; the rest (merging short frames, looping,
Drop) is shared. `gif_info` walks the blocks for the size, frame count
and the NETSCAPE2.0 loop count (none: once; 0: for ever; n: n + 1
times, as browsers do), and accepts a GIF that ends after a whole block
without its trailer, as stb_image does. A GIF of one frame, or over the
32 MB budget, goes the still way (`clipboard.decode`, the first frame).
`wstbi` gains `load_gif_from_memory` on native only. Tests: block
walking, frame order and times, merging, loop counts, the budget, cut
off data; fixtures in `src/client/testdata`. Checked off-screen: a
4-frame 320×200 GIF attached in a message plays beside the WebP of 1.

## 3. The "Animate pictures" setting

For pictures in the chat only (previews of attached files, and the
paste chips' hover preview):

- **On hover** (the default): a preview shows its first frame, with a
  small "GIF"/"WEBP" badge in a corner so it's clear it moves, and
  animates while the pointer is on it. Leaving it stops it where it is.
- **Always**: everything in view animates.
- **Never**: first frames only, also on hover.

The viewer always animates: opening a picture is asking to see it.
The server's emoji aren't affected (7 has its own rule).

Settings > Interface: a three-way
choice, saved as `animate_pictures` = `"hover"` / `"always"` /
`"never"` in `settings.odin`, with a test that an old settings file
reads as `hover`.

*As built:* as planned, under "User interface" (the Interface tab),
beside Theme. The setting is a string like `theme`
(`settings.animate_pictures`, `Animate_Pictures`): unset or unknown is
hover. `image_fitted` decides each frame whether a picture plays and
notes it (`Texture.played`); only those move on (`anims_advance`), so
leaving one with the pointer stops it where it is. Its `hovered`
argument is the chips' preview's: it plays unless the setting is never.
The badge says GIF or WEBP (the worker says which) in the bottom left,
on any animated preview that isn't playing, and not on one too small
for it. Differences:

- Never shows first frames only from the start; switched to never
  while one was played (or after the viewer played it), a picture stays
  on the frame it had.
- A native cursor-leave callback takes the pointer out of microui's
  sight (unless a button is held), so a preview left by leaving the
  window stops too; untested (the kiosk shell's window fills the
  display).
- Tests: the setting's default, round trip and unknown values
  (`settings_test.odin`). Checked off-screen: hover plays and leaving
  stops, with badges on both still previews; "Always" plays both with
  no badges and saves `"animate_pictures": "always"`; "Never" doesn't
  play under the pointer, and the viewer still plays. The chip's
  preview wasn't tried.

## 4. Animations on web

`web/decode.js` gains the same thing through WebCodecs: when
`ImageDecoder` exists and says the type is supported
(`ImageDecoder.isTypeSupported`), an animated picture keeps a decoder
in JS, `decode({frameIndex})` gives a `VideoFrame` with its duration,
drawn to the canvas and read out as now. The protocol to the client
grows by `next(handle)` (start decoding the next frame), and `poll` and
`take` say how long the frame is shown. `close(handle)` is the
`Drop_Job`.

Without `ImageDecoder` (older Safari) pictures stay still, as today,
with no badge. `ImageDecoder` reads both WebP and GIF, so 2 needs
nothing more on web, and its memory budget doesn't apply (the browser
streams GIFs too).

Checked off-screen in Chromium (see the off-screen testing notes); the
fallback by deleting `ImageDecoder` before the client starts.

*As built:* as planned. `web/decode.js` tries `ImageDecoder` for a GIF,
or a WebP whose VP8X header says it's animated, when the browser has it
and supports the type; a track that's animated with more than one frame
keeps its decoder in the request, anything else goes the
`createImageBitmap` way as before. Frames are merged under 33 ms and
timed as on a desktop; how often it plays is the track's
`repetitionCount` + 1 (Infinity: for ever). New calls through
`web/shell.c`: `kind` (0 still, 1 WebP, 2 GIF), `shown`, `next` and
`close`; `poll` says 2 when an animation has no more frames, and `take`
keeps an animation's handle. `ui_images_worker_web.odin` keeps the
handles by picture (`Decode_Worker.anims`, with the generation) and
turns Next_Frame and Drop into `next` and `close`. A focus, blur or
visibility change on the page wakes the client, so animations stop and
carry on with the focus.

Checked in headless Chromium (focus emulated): both pictures came with
badges and still; on hover the WebP and the GIF each played (and
stopped when the pointer left); the viewer played. With `ImageDecoder`
deleted before the page loads, both were still, without badges, and
didn't play on hover. Not tried: pausing on blur, Safari or Firefox
themselves, and a server switch while one plays.

## 5. Animated pastes kept as they are

Today every pasted picture goes through `clipboard.read_image`, which
decodes it to pixels, and `image_prepare` (`ui_paste.odin`), which
makes a still WebP of them. (Picked and dropped files are attached as
they are already.)

`clipboard` gains a way to hand back the clipboard's bytes as they are
when it offers `image/webp` or `image/gif`. If those bytes are an
animation (`WebPGetFeatures`, or a GIF with more than one frame) and no
bigger than the file limit, they're attached unchanged, named
`pasted-image-….webp` / `.gif`; anything else goes the way it goes now.
A browser's "copy image" usually puts a PNG of the first frame on the
clipboard, which stays a still: nothing to be done about that. On web,
`paste.js` does the same with the `ClipboardItem`'s blob.

*As built:* as planned, with the limit taken from the server: an
animation that's bigger than the server takes is compressed to a still
WebP as before, rather than refused.

- `clipboard.MIME_TYPES` puts GIF and WebP before PNG (Linux, X11 and
  Wayland, and OpenBSD go by it); macOS asks for `com.compuserve.gif`
  and `org.webmproject.webp` first. Windows has no standard formats for
  them beside "PNG" and the DIBs, so nothing changed there.
- `clipboard.read_encoded` hands back the bytes as they are;
  `paste_work` keeps them when `animation_ext` says they're an
  animated WebP or a GIF of more than one frame and they fit
  `max_size` (`view.max_attachment`, taken in `paste_start`), and
  decodes and compresses them otherwise. The file is named
  `pasted-image-….gif` / `.webp`.
- Web: `paste.js` picks a GIF or WebP item first, and sends an animated
  one no bigger than `_web_max_attachment()` as it is, named
  `pasted-animation.<ext>`; `web_file_pasted` takes the extension from
  the name.
- Tests: `animation_ext` (both kinds, stills, junk). Checked: natively,
  an animated GIF put on the X clipboard as `image/gif` was attached as
  it was (2507 bytes, `.gif`) and played in its message, and a still
  GIF became a WebP; the chip's hover preview played (phase 3's untried
  case) and stayed still with the setting on never. On web, pasted
  animated WebP and GIF went as they were, still ones as WebPs.

## 6. The server's emoji animated

**Files:** `emoji/foo.webp` and `emoji/foo.gif` are read as well as
`foo.png` (the same name in two formats: the first in the order png,
webp, gif wins, with a warning). `EMOJI_MAX_FILE` stays 1 MB.

**libwebp on the server:** build.sh builds it as for the client (the
same tarball and libraries, decoder and encoder) and the server links a
shim of its own, `src/server/webp`, with the same calls as phase 1's
plus the still encoder; build.bat and the Dockerfile follow. GIFs are
read with `vendor:stb/image` (`stbi_load_gif_from_memory`), which the
client uses already.

**What's made of an animated emoji:**

- Its first frame goes into the sheet's cell as any PNG's does (the
  same scaling as `read_emoji`): old clients, the picker and a client
  that hasn't got the frames yet show it still.
- Every frame, scaled the same way, goes into a grid of 64 px cells with
  the sheet's pixel of gap, `ceil(sqrt(n))` to a row. At most 64
  frames: a longer animation drops frames evenly and the dropped
  frames' time goes to the ones kept, so it plays at the same speed.
  Durations are clamped as in 1.
- The grid is written as a still WebP (lossy with alpha, quality 90;
  about 520×520 for 64 frames, tens of KB), after a small header:

	  Emoji_Frames  [magic "YEMA"][count u8][columns u8][duration_ms u16]...[webp]

  and kept as a blob of a new kind, `Emoji_Frames = 5`. The same frames
  make the same blob, so clients keep their copy.

**Protocol:** `Emoji_Sheet` gains, after the names, a list of the
animated ones:

	Emoji_Sheet  [blob u64][size u32][cell u16][count u16][name str8]...[animated u16]([index u16][frames blob u64][size u32])...

A client that doesn't know the tail ignores it (`decode_emoji_sheet`
stops after the names), so this is an addition, not a break; the
`HELLO_VERSION` bump says the new client may expect it.

**Purging** keeps the frames' blobs as it keeps the sheet: their ids
go in the meta beside `EMOJI_SHEET_META` (a list), and
`retention.odin` keeps every id in it.

Tests (`emoji_test.odin`): a folder with a PNG, an animated WebP and an
animated GIF makes a sheet with three cells and two frame blobs; the
frame count and durations survive; 100 frames come down to 64 with the
total time kept; a still WebP is a plain emoji.

*As built:* as planned, with these differences:

- **No HELLO_VERSION bump.** A hello of another version is refused,
  which would have shut every older client out; the list of animated
  emoji only adds bytes after the names, which older clients don't
  read, and a sheet without it (an older server's) reads as none moving.
- **The bindings are shared rather than copied:** `src/client/webp`
  became `src/common/webp` (client and server import `common:webp`),
  built by `scripts/build-webp.sh`, which build.sh and the Dockerfile
  run (the Dockerfile also builds Odin's stb libraries when the release
  lacks them, as CI does, and installs cmake and make). The shim gained
  `yap_webp_encode` with alpha (`webp.encode_rgba`). The GIF block
  walker moved to `src/common/gif` (`gif.info`), for the server's
  budget check. CI caches libwebpdemux (it was missing since phase 1)
  and runs the webp and gif tests. On OpenBSD the server gets the stb
  libraries the client does.
- **Purging** keeps the frames by one meta row each,
  `emoji_frames_<id>` = id, replaced whenever the sheet is taken;
  `Blob_Scan` spares every blob a row like that names, the way it spares
  `server_icon`. `Blob_Get` serves an Emoji_Frames blob that's one of
  the current ones (`emoji_frames_known`).
- **Reading:** what a file is goes by its bytes, not its name. Frames
  are thinned into 64 runs as even as they go (`Thinning`), the first of
  each kept and shown for the run's time, each frame's time taken as
  clients do (≤ 10 ms is 100, at least 20). Limits: 2048 px a side, at
  most 2000 frames read, a GIF's frames at most 64 MB decoded; past
  those, or broken after the first frame, the emoji stays still. The
  grid is WebP quality 90, method 4; over `MAX_BLOB_SIZE` it stays
  still too.
- Tests: `proto` (the sheet with and without its tail, an index past
  the names, cut-off data; the frames blob both ways), `webp` (RGBA
  keeps its alpha), `gif` (moved), and the server: a folder with a GIF,
  a WebP, a still WebP, a 100-frame GIF and a name twice makes five
  cells and three frame blobs, with the times clients use, 64 of the
  100 frames at 2 s in all, the first frames in the sheet; a purge keeps
  the sheet and the frames and drops an unused blob; taking an
  animation out of the folder drops its meta row. Checked on a running
  server: a GIF, a WebP and a PNG make "3 emoji of our own, 2 of them
  moving", two Emoji_Frames blobs of 130×130 under 1 KB, and their meta
  rows. The Docker build wasn't run.

## 7. Drawing animated emoji

`conn/emoji.odin` keeps, per emoji, its frames blob (0 for a still
one), fetched as the sheet is: when the emoji is first drawn. The
client reads the header, decodes the WebP as any still picture (so the
web client needs no `ImageDecoder` for emoji), and keeps it as a
texture under its own key, trimmed like other pictures.

`custom_emoji_icon` then picks the cell by time:
`(now - start) mod total` against the durations, with `start` the
client's start time, so every copy of an emoji moves together. Until
the frames are here, and when animation is paused, it's the sheet's
cell, as now.

Emoji animate always, wherever they're drawn (messages, reactions, the
picker), not following the setting of 3: they're small, and an emoji
that moves is the point of an animated emoji. They stop with the rest
while the window is minimised or unfocused, and share 1's 30 a second
cap: all the animations on screen ask for one `ui_redraw_at`, the
earliest.

The picker draws a few dozen emoji at once; that's a texture each (no
more than the 96 kept), and draws as many quads as now.

*As built:* as planned, with these differences:

- The frames blobs are fetched (and kept on disk) as soon as the sheet
  is told of, like the sheet and people's pictures, not when first
  drawn: `blob_want` has no lazy path, and they're small (under 1 KB
  for a short animation, at most 1 MB).
- `custom_emoji_icon` tries `custom_emoji_frame` first: once the blob
  is here it's parsed (`Emoji_Timing`, kept in `UI_Images.emoji_frames`
  by texture key, cleared on a server switch) and its WebP decoded like
  any picture, under `EMOJI_FRAMES_KEY | blob`; then the frame is the
  one `(now - anim_epoch) mod total` falls in, and a frame is asked for
  when it ends, never sooner than `ANIM_MIN_SHOWN` (now in
  ui_images.odin, shared with the decoding thread). While the window
  hasn't the focus, and till the frames are here, it's the sheet's cell.
- Neither the sheet nor a frames grid gets mipmaps any more
  (`is_emoji_atlas`): they're atlases, whose smaller copies would mix
  neighbouring cells. The sheet had them before.
- Checked off-screen: a message with `:dance:` (GIF), `:wave:` (WebP)
  and `:yap:` (PNG): the two animated ones play in step (yellow, red,
  green at 700 ms), also in the picker; without the focus they show the
  first frame; the PNG stays as it was. CPU over 10 s about 140 ms
  either way at that rate. On web (headless Chromium) they play too.

## Redraw cost, measured (2026-10-10)

Off-screen (headless weston, the AMD GPU's own driver), 16 cores, CPU
time of the client over 10 s, with a frame counter in a throwaway build:

| On screen | Frames/s | CPU per 10 s |
| --- | --- | --- |
| nothing moving (no focus) | ~0 | 150 ms |
| two slow emoji (700 ms frames) | ~1.5 | 140 ms |
| a 30 fps emoji, and the two slow ones | 30 | 260 ms |
| that, and a 30 fps 320×200 preview, hovered | 50 → 30 | 550 → 430 ms |

The last row found two things, fixed in the commit after phase 7:
animations each kept to 30 a second but not together, so two out of
step drew up to 60 frames a second; and every next frame the decoding
thread finished woke the UI for a frame of its own before the one it
was due in. Now every animation's redraw goes on a shared 33 ms tick
from the client's start (`anim_redraw_at`), and a decoded next frame
doesn't wake the UI (native, and on web `next` doesn't): it's taken
when due, or looked for again a tick later. A frame costs ~0.4 ms of
the UI's time, nearly all of it laying out and drawing the whole window
(text widths, glyphs, formatting), which is the same for any redraw;
decoding a 320×200 WebP frame is about a quarter of the preview's
share, on the decoding thread.

## Open points

- **Redraw cost.** A visible animation means whole frames at its rate,
  which is what idle redraw saved. The cap and pausing when unfocused
  bound it; worth measuring with `loop-timing`'s turn timing once 1 and
  7 are in (a chat full of animated emoji is the worst case).
- **D3D11** `gpu_texture_update` is written blind (no Windows here), as
  build.bat's libwebp part was.

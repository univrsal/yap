# Client memory: measurements and what to save

Measured 2026-10-16 on `notifications` (2a8af43, with the sound fix), on
Linux (Arch, glibc, AMD RX 6700 XT / radeonsi). The findings are ranked by
what they would save, with a proposal each. Findings 1 to 4 are built on
this branch (see "As built" under each).

## How it was measured

- A local server with three accounts; two headless bots filled it: avatars,
  a lobby with 350 messages (text of every length, Unicode emoji and
  `:shortcodes:`, mentions) and 9 pictures, and a `pics` channel with 10
  pictures (4000x3000 JPEG photos of 2.8 MB, 1920x1080 PNG screenshots,
  2400x1600 WebP, an animated GIF and an animated WebP). Two more servers
  with 120 messages each for the multi-server case.
- The GUI client in a headless weston, with a fresh config each run, logged
  in through its device key:
  - **GPU runs**: a native Wayland client, rendering on the real GPU
    (radeonsi). Realistic totals, but no input can be sent.
  - **Clicked runs**: an X11 client on weston's Xwayland, which renders in
    software (llvmpipe); textures then live in the client's own memory. Used
    for the states that need clicks (the pictures, the viewer, the emoji
    picker) and for the client's own report (Settings > Memory > Write to
    log), which lists GPU textures apart.
- `/proc/<pid>/smaps` every few seconds: RSS, and **private memory** (USS,
  what a task manager shows as the app's memory; RSS also counts library
  code shared with every other process, here ~170 MB of Mesa/LLVM).
- heaptrack for every malloc in every thread (C libraries included), and
  glibc's tunables (`GLIBC_TUNABLES`) to try allocator changes without
  rebuilding.

## Results

Private memory (USS), GPU runs, 75 s each:

| Scenario | Private | RSS | Note |
| --- | --- | --- | --- |
| Join screen, not connected | 40.7 MB | 211 MB | flat |
| Connected, lobby | 46 MB, then 58 MB | 229 MB | +12 MB step after ~25 s (finding 2) |
| In voice, two others talking | 56 MB | 231 MB | voice itself costs ~nothing extra |
| Three servers | 63 MB | 234 MB | +5 MB for two more servers |
| Lobby, 10 min busy (600 messages, 20 pictures) | 75 → 87.5 MB in the first minute, then flat | 266 MB | **no leak**: +40 KB over 9 minutes |

Clicked runs (software rendering, so textures are in these numbers):

| Step | Private |
| --- | --- |
| Lobby | 86 MB |
| `pics` opened | 86 MB |
| scrolled through all 10 pictures | 121 MB |
| a photo open in the viewer, then closed | 121 MB |

The client's own report after that: 48 MB counted live, **390 MB of
textures (19)**, **121 MB freed but kept by malloc**, peak 358 MB resident.

## Findings, biggest first

### 1. Chat pictures are uploaded at full resolution

A preview of a 4000x3000 photo, drawn about 210x160, is a 48 MB texture.
After scrolling through 10 pictures there were 390 MB of textures. The cache
keeps up to `MAX_IMAGE_TEXTURES` (96) pictures by count, not by size, so a
channel of phone photos can hold several GB of video memory, which on
integrated graphics (most laptops) is the computer's RAM. Decoding at full
size also makes a 48 MB buffer per photo every time one scrolls into view.

**Proposal**: decode and upload previews scaled down to what they're drawn
at (the preview box times the display scale, say at most 1024 px on the
long side: 4 MB instead of 48). The viewer decodes the full picture only
while it is open, and lets go of it when closed. Give the texture cache a
byte budget (say 256 MB) as well as the count. Saves ~90% of picture
textures; 10 photos: ~40 MB instead of 390-480 MB.

*As built:* `PREVIEW_MAX_SIDE` (1024) in `ui_images.odin`: the decode job
carries a longest side, the desktop worker scales still pictures down with
stb's resize (`shrink`), the web page on its canvas (`web/decode.js`), and
the texture keeps the picture's own size for the layout and the viewer's
caption. Animations and the emoji sheets (grids of cells) aren't scaled.
Opening the viewer on a scaled picture decodes it at its own size under its
key with `VIEWER_KEY`; the viewer shows the preview until that is in, and
`trim_textures` drops it once the viewer shows something else or is closed.
`MAX_IMAGE_TEXTURE_BYTES` (256 MB) next to the count; what was drawn in the
last frame is never dropped. Measured with the same flow (software
rendering): textures after scrolling the 10 photos 390 MB -> 58 MB; the
viewer's full picture was there while it was open (sharp at 280%) and gone
after. Tried on the web client too (headless Chromium through the relay).

### 2. glibc keeps big freed buffers (12-26 MB, more after pictures)

glibc raises its mmap threshold after the first big buffer is freed, so
later big buffers (the decoded emoji sheet, 16.8 MB, decoded on the image
worker thread; every decoded picture) come from malloc's arenas and stay in
RAM when they are freed. That is the 12 MB step after ~25 s of every run,
and the "heap free: kept by malloc" figure of the report (121 MB after the
pictures).

With a fixed threshold (`GLIBC_TUNABLES=glibc.malloc.mmap_threshold=262144`,
no rebuild):

| | Before | After |
| --- | --- | --- |
| Lobby (GPU), private | 57.9 MB | 44.6 MB (-23%) |
| Pictures scrolled (software), private | 120.9 MB | 94.6 MB |
| Freed but kept by malloc | 121 MB | 16 MB |

**Proposal**: `mallopt(M_MMAP_THRESHOLD, 256 * 1024)` at start on Linux
(glibc; musl doesn't need it), before anything allocates. Big buffers then
always get their own mapping and go back to the system when freed. Capping
the arenas at two as well (`M_ARENA_MAX`) saved only another 0.7 MB.
Windows' heap behaves differently and would need its own look.

*As built:* `platform.malloc_tune` (`platform/malloc_linux.odin`), first
thing in `main`: `mallopt(M_MMAP_THRESHOLD, 256 KB)`. It measures the same
as the glibc setting did: "heap free" after the pictures 121 MB -> 16 MB,
and no step after start. Only the client; the server could take it too.

Both together, real GPU, a lobby with pictures on screen (the lobby by
then had 20 more pictures from the long run): private memory 93.6 MB ->
52.6 MB.

### 3. Pictures are kept compressed in memory, twice

The report's biggest live lines after the pictures: `conn/attachments.odin:951
attach_preview`, 15.8 MB, and `conn/blobs.odin:427 publish_blob`, 15.8 MB.
A preview downloads the whole original file into memory (2.8 MB a photo),
and every cached picture's bytes are copied once more into the View for the
UI. Both stay after the picture is decoded and on the GPU.

**Proposal**: hand the UI the network thread's bytes instead of a copy (a
reference, or a move), and drop them once the texture is made; the disk
image cache (`image_cache`) has them if the picture has to be decoded again.
With finding 1, the preview could also come from a small preview the server
keeps rather than the whole file, but that is a protocol change; the client
side alone saves the ~30 MB here, growing with every picture seen.

*As built:* the two report lines turned out to be one set of pictures held
twice, not two downloads: a preview is downloaded into memory (counted at
`attach_preview`) and then moved into the network thread's picture cache,
which holds at most `BLOB_CACHE_BYTES` (16 MB) of them; the copy was
`publish_blob`'s, for the View. Now the cache and the View share the bytes
(`Shared_Bytes` in `conn/blobs.odin`, reference counted, freed by whichever
lets go last), so the View's copy is gone. Measured with the pictures flow:
counted live 48.2 -> 32.4 MB, private memory after scrolling 94.6 -> 78.5
MB; real GPU, lobby: 52.6 -> 50.1 MB. Tested in `conn/blobs_test.odin`.
What is left is the cache itself (up to 16 MB of compressed pictures, plus
the ones that are kept: avatars and the server's emoji). Lowering
`BLOB_CACHE_BYTES` would trade it for fetching pictures again more often
when scrolling back; a small preview kept by the server would make it much
smaller, but needs the protocol.

### 4. GTK is loaded on Wayland for the window decorations (~10 MB)

On Wayland, GLFW draws the window's title bar through libdecor, whose GTK
plugin loads GTK 3: 7.6 MB of GTK's theme CSS on the heap (heaptrack),
GTK's own libraries, fontconfig's font list (1.1 MB) and the glycin image
loader threads. Not under X11.

**Proposal**: try GLFW 3.4's `GLFW_WAYLAND_LIBDECOR` init hint set to
`GLFW_WAYLAND_DISABLE_LIBDECOR`, so that GLFW uses the compositor's
decorations (xdg-decoration, KDE and most others) or its own simple ones.
Where the client merges the title bar into the window (`merge_title_bar`)
it doesn't need them at all. To be checked on GNOME, which has no
server-side decorations.

*As built:* tried first with libdecor always off. Under a headless Sway,
which draws title bars, the window looked the same (Sway drew its title bar
either way: libdecor lets the compositor draw it where it can, but loads
GTK all the same), with 4.5 MB less private memory (83.7 -> 79.2 MB), 20 MB
less RSS (GTK's libraries) and 5 threads fewer. Under Weston, which like
GNOME draws no title bars, GLFW's own decorations are a bare grey strip with
no title and no buttons, so libdecor can't simply go. Now the client asks
the compositor before GLFW starts (`wayland_server_decorations` in
`ui_wayland_decorations.odin`: libwayland-client loaded for a moment, a
connection of its own, a look at the registry for
`zxdg_decoration_manager_v1`) and turns libdecor off only where it is
offered. Checked: under Sway no GTK is loaded and the title bar is Sway's;
under Weston libdecor stays. X11 sessions and the merged title bar (which
uses XWayland) are as before.

### 5. Arenas of 4 MB per thread for scratch memory

Six 4 MB blocks were live at the end: the temp allocator's two on the UI
thread (the report's "temp allocator (arena blocks)", 8 MB) and core:os's
per-thread scratch arenas, made by the first `os.exists`, environment lookup
or time zone lookup on a thread. Only the touched part is in RAM, but a
frame that once used a lot keeps it.

**Proposal**: smaller first blocks for the temp allocator (it grows when it
must) and freeing the blocks past the first now and then (after the frame
in which they were needed). Modest: a few MB.

### 6. Smaller items

- `render/unifont.odin`: 3 MB for the fallback font (2 MB data + 1 MB
  pixels), loaded at start. Could load on the first glyph that needs it.
- The binary's own pages: 8 MB private resident (code, and the embedded
  emoji sheet, fonts and sounds read at start). Clean pages the system can
  drop; not worth changing.
- The emoji sheet's texture: 16.8 MB of video memory (2048x2048 RGBA).
  The higher-quality WebP doesn't change that. A texture format with
  compression, or a smaller sheet for small sizes, would; low priority.
- The sounds (2.2 MB), audio rings (0.9 MB), message caches and the View:
  small, nothing to do.

## What it would add up to

For a connected client in a lobby on the GPU: about 58 MB private today;
~45 MB with finding 2, ~35 MB with 4 and 5 as well. After looking at
pictures the gains are larger: findings 1-3 keep the client from growing by
tens of MB of RAM (and hundreds of MB of video memory) per channel of photos.

## Order proposed

1. Finding 2 (one call, measured).
2. Finding 1 (the biggest; client only).
3. Finding 3 (client only; easier after 1).
4. Finding 4 (needs trying on GNOME and KDE).
5. Findings 5 and 6, if wanted.

## Not covered

Windows and macOS (different allocators and drivers; the D3D11 issue found
there is separate), watching a screen share, the web client, and real-GPU
numbers for the clicked states (no input reaches a native Wayland client in
a headless weston).

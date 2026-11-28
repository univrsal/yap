# Thumbnails: plan

Today a client fetches a picture attachment whole to show its preview
(`preview_wanted`, `PREVIEW_MAX` 8 MB, `conn/attachments.odin`), decodes it,
and scales it down to at most 480×160 (`preview_side`, `ui_attachments.odin`).
A scrolled-through channel of phone photos is tens of megabytes of download,
decode time and a burst of memory for pictures drawn a few hundred pixels
wide. This plan has the server make a small copy of each picture and the
client fetch that for the preview, and the original only when asked (viewer,
Save). Nothing is built yet. Each phase is its own commit or series; what
turns out differently is written under its section ("*As built:*").

Sizes: S up to about 300 changed lines, M up to 1000, L up to 2500.

| # | Change | Size | Where | Depends on | Status |
| --- | --- | --- | --- | --- | --- |
| 1 | Server: make a thumbnail when an upload is stored | L | server | - | done (2026-11-28) |
| 2 | Protocol: `Attach_Get` can ask for the thumbnail, messages state it | M | protocol, server | 1 | done (2026-11-28) |
| 3 | Client: previews fetch thumbnails (native + web) | M | client | 2 | done (2026-11-28) |
| 4 | Backfill: thumbnails for files stored before this | M | server | 1 | done (2026-11-28) |
| 5 | Retention, quotas, purge, docs | S | server | 1 | done (2026-11-28) |
| 6 | Gateway: `?thumb=` on `GET /attachments/{id}` | S | gateway | 2 | done (2026-11-28) |

1 to 3 are the feature; 4 to 6 can follow in any order.

## What's there now

- An upload is stored as a blob of kind `File`, keyed by SHA-256, and a
  picture's width and height are read from its first 80 KB
  (`ATTACH_HEADER`, `common:imagekind`). The server never decodes it.
- The server does decode and encode pictures for the emoji sheet
  (`emoji.odin`): PNG (core), WebP (libwebp, `common:webp`), GIF
  (`common:gif`), on a thread of its own so the loop that carries voice isn't
  held up. It has **no JPEG decoder**, and JPEG is what phones send.
- `Attach_Get [blob]` answers `[size][download id]`, then chunks
  (`transfer.odin`), paced by `rate_kb`. A client may fetch a blob only if it
  may read a message carrying it (`attachment_visible`).
- Clients: the native client decodes with stb_image/libwebp on a worker
  (`ui_images_worker_native.odin`) and has the `preview_side` logic; the web
  client decodes with `createImageBitmap` (`web/decode.js`). Both keep
  decoded textures for the 96 most recent pictures. Avatars and emoji are
  cached on disk by blob id (`image_cache`); chat pictures are not.
- Animated WebP/GIF previews animate from the whole file
  (`animated.md`), so a thumbnail of an animation must stay one.

## Decisions to settle

Recommendations first; the first three decide the shape.

1. **Who makes the thumbnail: the server.** The alternative is the uploading
   client sending a small copy next to the file. That costs the uploader
   an upload per picture, trusts the client with what others see, and leaves
   out bots (the gateway), pasted images from the CLI client and
   Mattermost imports. The server already decodes pictures and owns the
   bytes. *Recommended: server.*
2. **When: when the upload completes, on a worker thread**, as the emoji
   sheet is built. The message can be posted before the thumbnail exists, so
   a client that asks too early gets the original (see 2 below). *Alternative
   lazily on first request:* no work for pictures nobody scrolls to, but the
   first viewer waits and the work happens on demand, which is the kind of
   thing that can be abused. Phase 4 needs the lazy path anyway for old
   files, so lazy-for-old plus eager-for-new.
3. **Format: WebP**, lossy q~65, longest side 512 px (twice the 160/480 box,
   so it is sharp at 2× scale without a second size). The client already
   decodes WebP everywhere (libwebp native, browser on web) and the server
   already links the encoder. One size only at first; the `size` byte in the
   protocol (phase 2) leaves room for more.
4. **Which pictures get one:** PNG, JPEG, WebP, GIF, BMP, whose original is
   over a threshold (say 64 KB) or whose sides exceed 512 px. Smaller and
   already-small originals are served as they are: no second blob, no
   second fetch. *Animated* WebP/GIF: the thumbnail is the first frame
   (static) and the client fetches the original when the user hovers, since
   that is when it animates (`animated.md`, setting "hover"). With "always"
   it keeps fetching the original. Keeps the server from re-encoding
   animations, which is the expensive part.
5. **JPEG decode on the server:** link stb_image (`vendor:stb/image`, counted
   by `stbtrack` like the client's) and resize with `stb_image_resize2` or an
   area-average of our own. Honour EXIF orientation: the thumbnail is
   written already rotated, so clients show it upright. The *original's*
   stated width/height must stay what clients draw it at; check what
   `imagekind.size` reports for a rotated JPEG and make both agree.
6. **Safety:** decoding untrusted pictures is the new attack surface.
   Refuse before decoding when `width × height` exceeds a cap (say 64 MP,
   ≈ 256 MB RGBA; stb allocates for it), decode in the worker only, one
   job at a time with a short queue (like `HASH_QUEUE_MOST`), and skip the
   thumbnail, not the upload, on any failure. The cap and queue are config
   (`[attachments]`).
7. **Storage:** the thumbnail is a blob of a new kind, `Thumbnail = 6`
   (`Blob_Kind`), so it dedupes, is stored and served like any blob, and
   retention's "no one refers to it" collection works with one change (it
   must count the link below). It counts against `daily_megabytes`? No: it
   is derived, so no, but it does need to respect `ATTACH_FREE_FLOOR`.
8. **Link between original and thumbnail:** a column on `blobs`,
   `thumb INTEGER REFERENCES blobs(id)` (schema step). The thumbnail's life
   follows the original's: collect it when the original goes.

## 1. Server: make a thumbnail when an upload is stored

`server/thumbnails.odin`. When `attachments.odin` finishes storing a blob of
a picture kind (the place that reads the header size), it submits a job
(blob id, path, kind). A single worker thread, started like the emoji
rebuild, decodes, scales to fit 512×512 (never enlarging), encodes WebP, and
hands the bytes back; the loop collects finished jobs each turn
(`thumb_poll`, like `hash_poll`) and stores the blob and sets
`blobs.thumb` on the loop, since the database belongs to it.

- Skips: not a picture, already small (decision 4), animated (decision 4),
  over the pixel cap, queue full, decode/encode error. A skip is recorded
  (`thumb = 0` and a `thumb_tried` flag, or `-1`) so the backfill (phase 4)
  doesn't retry forever.
- Tests with the repo's picture test data: JPEG with EXIF rotation, PNG with
  alpha, a huge-dimension decompression bomb header, a truncated file, an
  animated WebP, and duplicate uploads (two uploads of one file make one
  thumbnail).

*As built:* `server/thumbnails.odin`. One thread (own temp allocator, like
the emoji build) takes jobs from a queue of at most 16 under a mutex and a
semaphore; the loop collects results in `thumbnails_sync` (its own loop phase,
`Thumbnails`) and stores them, since the database is the loop's. A job is
queued from `upload_keep` right after `blob_adopt`. `blobs.thumb` (schema 35)
is 0 not looked at, -1 none, else the thumbnail's blob; `Blob_Scan` leaves a
blob alone while another names it, so the thumbnail dies with its picture on a
later collection. A file whose header isn't a picture is marked -1 at once,
without a job. Config: `thumbnails` (default true), `thumb_side`,
`thumb_quality`, `thumb_min_kb`, `thumb_megapixels`.

Differences and findings:

- BMP: `imagekind` has no BMP kind (only `is_bmp`), so BMPs are handled
  explicitly; stb_image reads them like PNG, JPEG and the first frame of a
  still GIF. GIFs with more than one frame, and animated WebP, get none.
- Scaling is `stb_image_resize2` (sRGB, alpha-aware) on RGBA; a picture with no
  transparency is encoded as RGB, otherwise RGBA. A thumbnail that isn't
  smaller than the file gets none.
- EXIF orientation is read by `imagekind.jpeg_orientation` and applied to the
  small image after scaling (cheap). **The thumbnail blob's width and height
  are its own** and for orientations 5 to 8 they are swapped from the
  picture's. The stated size of the *original* (`Attachment.width/height`) is
  the header's, unrotated, and the native client's stb_image doesn't rotate
  either, while a browser's `createImageBitmap` does. So phase 2 must state
  the thumbnail's size next to `thumb_size`, and phase 3 must size the preview
  from the thumbnail it has (not from the original's stated size) or an
  upright thumbnail is drawn squashed into a sideways box.
- Tests: `thumbnails_test.odin` (scaling, minimums, caps, cut-off file, JPEG,
  orientation turns, store + garbage collection) and
  `test_attachments_thumbnail` (an upload through the protocol). A JPEG with
  an EXIF orientation isn't covered end to end: there is none in the repo,
  only `test_jpeg_orientation` on hand-made headers and `test_orient` on the
  turn itself.
- `db_test.odin`'s two downgrade tests drop `blobs.thumb` as well.
- Not measured yet: the thumbnail thread's effect on the loop's turn time
  (see the open questions); do it with `yap-stress` before phase 3 ships.

## 2. Protocol

- `Attach_Get` becomes `[blob u64][variant u8]`, variant 0 original (today's
  meaning), 1 thumbnail. Old servers/clients: bump `HELLO_VERSION`; the new
  client only sends variant 1 to a server that says it supports it
  (`Server_Info` flag), else it behaves as now.
- Variant 1 on a blob with no thumbnail is answered with the original (same
  `[size][download]` shape; the client can tell from `size`, and the answer
  is the same whole-file transfer it has code for). That makes "not made
  yet", "too small to need one" and "skipped" all one case for the client,
  with no retry logic.
- Access: `attachment_visible` is checked against the *original's* blob id as
  now; the thumbnail is never named by clients, so it needs no entry of its
  own.
- `Attachment` (what a message states: blob, size, name, width, height) gains
  `thumb_size u32` (0 for none) so the client knows before asking whether
  there's a smaller thing to fetch, and can decide to show the preview
  without the 8 MB `PREVIEW_MAX` limit applying to the original. Schema: no
  new column needed if it's derived by a join on `blobs.thumb`; the message
  encoder reads it with the attachment rows.
- A thumbnail created *after* a message was sent isn't in the message. The
  client's variant-1 request still gets it (the server looks it up at
  request time), and the message just under-states; later loads of the
  message state it.

*As built:* `Attach_Get` is `[blob u64][variant u8]` (`proto.encode_attach_get`
/ `decode_attach_get`, `Attach_Variant` Original 0, Thumbnail 1). A request of
only the blob is still read as the original, so the gateway's `GET
/attachments/{id}` and anything else that sends `encode_attach_id` is
unchanged. An unknown variant is `Invalid`. `HELLO_VERSION` is 24.

Differences from the plan:

- **No `Server_Info` flag.** The hello version has to match exactly
  (`decode_hello`), so a client that sends variant 1 only ever talks to a
  server that knows it. A flag would never be false.
- **The message record states the thumbnail's size in pixels as well as
  bytes**: `[thumb_size u32][thumb_width u16][thumb_height u16]` after each
  attachment's `height` (8 more bytes per file, in `message_size` and
  `ATTACHMENTS_MAX_SIZE`). This is the finding from phase 1: a turned JPEG's
  thumbnail has other proportions than the original's stated size. No schema
  change: `Attach_Of_Msg` joins `blobs` twice (picture, then
  `blobs.thumb`). A thumbnail made after a message was read isn't in what that
  client holds; its next request for the variant still gets it, and the
  client's copy of the record is refreshed whenever the message is sent again.
- **Visibility is the original's.** The server looks the thumbnail up from
  the picture the client named and serves it only if the picture is visible to
  the account; a thumbnail's own blob id asked for as a picture is
  `Not_Found` (no message names it). A thumbnail whose file or row is gone
  falls back to the original.
- A client can tell what it got from the answer's size (and from
  `thumb_size` in the message); phase 3 must still bound the size of what it
  accepts when the answer is the original (`PREVIEW_MAX`).
- Gateway: it decodes the new record through `proto`, nothing else changed.
  Exposing the thumbnail in its JSON (`thumb` fields, `?thumb=`) is phase 6.
- Tests: `test_attach_ids_and_answers` (request codec), the message
  round trip with the thumbnail fields (and the maximum size), and
  `test_attachments_thumbnail` extended: the message states the thumbnail,
  a member fetches the WebP of the stated size and the original, a file
  without a thumbnail is answered with the original, a non-member and the
  thumbnail's own id are `Not_Found`, variant 7 is `Invalid`.


## 3. Client: previews fetch thumbnails

- `attach_preview` (conn/attachments.odin) requests variant 1. `preview_wanted`
  stops being limited by the *original's* size when a thumbnail is stated
  (a 20 MB photo now previews); the 8 MB cap applies only to the
  no-thumbnail fallback.
- The viewer (click) and Save fetch variant 0 as now. The viewer can show the
  thumbnail immediately, scaled up, and swap in the original when it
  arrives; cheap, makes it feel instant, optional.
- Animated originals: first frame from the thumbnail, original fetched on
  hover or immediately with "always" (decision 4).
- Memory: `preview_side` can stay; the decoded size it asks for is now at
  most the thumbnail's 512.
- Cache: store thumbnails in `image_cache` (native and the IndexedDB web
  store) by blob id. This was the open next step of `image-cache` ("chat
  images not done"): thumbnails are small and immutable (content-addressed),
  so they suit it, and scrolling back through history stops re-downloading.
  Originals stay uncached.
- Web: no change in decode (`createImageBitmap` takes WebP); web needs the
  same request variant. Headless and CLI client: use the thumbnail where they
  render pictures (`cli/pictures.odin`), since a terminal never needs more.
- Tests: conn flow tests for variant 1 with and without a thumbnail, an old
  server (no flag), and a thumbnail arriving after the message; an off-screen
  GUI run on both native and web that compares bytes transferred for a
  channel of large JPEGs before and after.

*As built:* `conn/attachments.odin`, `ui_attachments.odin`, `ui_images.odin`.

- **Which id a preview has.** A picture whose message states a thumbnail is
  previewed as that: `Attach_Get` variant Thumbnail, kept with the pictures
  that messages show under `thumb_blob_id(blob)` (the blob's id with bit 62
  set) so it can't be mistaken for the picture, which the viewer fetches under
  its own id. `Msg_File` has `thumb_size`, `thumb_width`, `thumb_height`. A
  picture without a stated thumbnail is fetched whole under its own id, as
  before, and only if it is within `PREVIEW_MAX` (8 MB). `file_previewed`
  (`thumb_size > 0` or `preview_wanted`) decides whether a file is drawn as a
  picture, so a 25 MB photo now previews. The preview's layout and decode size
  come from the thumbnail's own dimensions (`preview_dims`).
- **Fallback.** If the server answers a thumbnail request with the picture
  (the stated thumbnail is gone), it is taken when it is within `PREVIEW_MAX`
  and otherwise given up on. Not cached on disk then.
- **The viewer.** Clicking opens it at once with the thumbnail. The UI then asks
  for the picture itself (`Attach_Preview_Command.original`, up to `VIEWER_MAX`,
  32 MB), and when it has arrived the viewer decodes it at its own size and
  swaps it in. A larger picture stays at the thumbnail's resolution in the
  viewer (Save still gets the file). For a thumbnail preview, `image_fitted`
  no longer decodes its own "full" copy from the thumbnail's bytes, which
  would have taken the slot the picture needs (found in the GUI run).
- **Disk cache.** A thumbnail is read from the image cache before the server
  is asked (`Attach_Save.disk`, native: the first look, web: polled) and stored
  after it has arrived. Content-addressed and immutable, so it is never
  stale. Originals are not cached. This is the "chat images not done" item of
  the image cache.
- **Messages made before their thumbnail** (not in the plan, found in the
  GUI run): a photo takes a moment to scale and a message is usually posted
  the moment the upload is complete, so the record that is first sent often
  states no thumbnail, and the client only asks for stated thumbnails.
  `thumbnail_announce` therefore sends every message that carries the picture
  again (`Msg_Changed`, which retention uses the same way) as soon as its
  thumbnail is stored.
- **EXIF orientation** (also found in the run). Phase 1 made thumbnails upright,
  but the native client's decoder (stb_image) shows a JPEG as stored, so the
  viewer would have jumped to a sideways picture when the original arrived
  (a browser's `createImageBitmap` already turns it). `clipboard.decode` now
  turns a JPEG upright, with `imagekind.orient_rgba` (moved there from
  `thumbnails.odin`), so a turned photo is now also upright in previews
  without a thumbnail. The server states a turned JPEG's width and height the
  way it is shown (`picture_size`), for blobs uploaded from now on.
- **CLI and headless clients** still fetch the picture (`original = true`), as
  a terminal would only gain from thumbnails in bandwidth. The gateway is
  unchanged.
- **Animations** have no thumbnail (phase 1), so they are fetched whole as
  before and keep animating; the "hover" idea of the plan was not needed.
- **Tests:** `conn` (a thumbnail preview, the viewer's request, the answer being
  the picture, big and too-big pictures without a thumbnail, the disk cache
  round trip), `server` (the resend, the turned JPEG's stated size),
  `clipboard` and `imagekind` (a real JPEG with orientation 6). Run for real
  with a server and the GUI off-screen (see `ui-offscreen-testing` in the
  notes): four pictures (27 MB, 5 MB, a turned 2.4 MB, a 116 KB PNG) were
  previewed from about 42 KB of thumbnails instead of 35 MB; the viewer
  swapped to the 2000x3000 original, upright; and after a restart the
  thumbnails came from the disk cache with no request to the server. The
  web build compiles (`-target:wasi_wasm32`) but was not run in a browser.
- Not done: the CPU cost of the thumbnail thread on the loop (see the open
  questions), the web client in a browser, and thumbnails for DM pictures
  (they are attachments too, so they should work; not looked at).


## 4. Backfill

Files stored before this have no thumbnail. Two paths:

- **Lazy:** variant-1 request for a picture blob with no thumbnail and no
  skip mark queues a job (same worker, same caps) and answers with the
  original now; the next request finds the thumbnail. A channel scrolled
  once costs the old bandwidth once.
- **Sweep:** a server command (`yap-server thumbnails`, like `purge`) or a
  slow background pass that works through picture blobs newest first, a few
  per turn, paused while voice is busy. Optional; lazy alone is enough if
  disk cost isn't an issue.

*As built:* both paths, in `thumbnails.odin` and `attach_files`
(`attachments.odin`), with no setting of their own (they follow
`thumbnails`).

- **Lazy, on reading a message, not on request.** The plan had the variant-1
  request queue the job. But a client only asks for a thumbnail its message
  states (phase 3), so for an old picture that request never comes. The
  trigger is instead the server reading a message to send it
  (`attach_files`, which now also reads `blobs.thumb`): a picture with
  `thumb = 0` and a known size is queued, and `thumbnail_announce` (phase 3)
  sends the message again when it's made. So the pictures people look at come
  first, and a message with several old pictures gets all of them as each
  finishes announcing (the re-read queues the rest).
- **Sweep, in the background, automatically.** No command: after each start,
  every second, if no job is waiting, the next 4 pictures of
  `Blob_Unthumbed` (kind File, `thumb = 0`, size known, carried by an
  attachment row, newest first by blob id) are queued, until none are left.
  Pictures no message carries are skipped, since retention removes them. It logs
  once when it starts and once when it's done. A restart runs it again, which
  costs one query when everything is done. A picture that was queued and
  the server stopped before it was stored is found again the same way.
- **No double jobs.** `Thumbnails.inflight` holds the pictures that have a
  job, so reading a message twice, the sweep and the on-read path, or two
  uploads of one file never queue it twice.
- Tests: `test_thumbnails_sweep` (6 pictures, an orphan and a non-picture: only
  the six are done, newest first, and a second sweep finds nothing) and
  `test_attachments_thumbnail_when_read` (a message posted while thumbnails
  were off: reading it queues once, then it is sent again with the thumbnail).
  Run with a real server: nine pictures posted with `thumbnails` off, the
  server restarted with it on, and all were done in about 3 s (the 27 MB one
  in 1 s), and the GUI then fetched nine thumbnails and no pictures. The
  sweep's own count was 8 of the 9 because the on-read path had queued
  one first, which is the two paths working together.
- Not done: a server command to run it on demand, and pausing it while the loop is
  busy. It works on one picture at a time on its own thread, so it leaves
  the loop alone; if `yap-stress` shows otherwise (see the open questions),
  that is where to look.

## 5. Retention, quotas, purge, docs

- `retention.odin` collection: a thumbnail blob is referenced by its
  original; delete it with the original, and don't count it as an orphan
  while the original lives.
- Purge (`cli_purge`, `proto/purge.odin`) reports bytes; include thumbnails in
  the figure it gives.
- `docs/Server.md`: `[attachments]` keys (thumbnail on/off, side, quality,
  pixel cap, minimum original size); memory stats (`memtrack`) show the
  worker's peak.
- Update `docs/API.md` for the gateway and the wire doc comment in
  `proto/attachments.odin`.

*As built:* smaller than planned, since phases 1 to 4 already did most of it.

- **Collection** needed nothing new: `Blob_Scan` (phase 1) leaves a thumbnail
  alone while its picture's row names it, and takes it on the next scan
  after the picture's blob is gone, which every `Purge`, `file_days` and
  `blob_megabytes` removal ends with. `test_attachments_thumbnail_retention`
  checks it: nothing goes while a message carries the picture, and after a file
  purge the picture's row, the thumbnail's row and its file are all gone.
- **Quotas.** `daily_megabytes` counts what arrives (uploads), so thumbnails
  aren't in it. `blob_megabytes` sums blobs of kind File (`Stored_Bytes`), so
  they aren't in it either, and removing a picture frees them as well. They
  also respect `ATTACH_FREE_FLOOR` only through the uploads that come first; a
  thumbnail is about 0.2% of its picture, so it was not worth a check of its
  own.
- **Purge figures.** The "removed N stored file(s)" of a purge and of the
  hourly run (`proto.Purge_Answer.blobs`) counts pictures, not their
  thumbnails: `collect_chunk` skips kind Thumbnail when counting (`Blob_Scan`
  returns the kind). Bytes aren't reported, so there was nothing else to
  adjust.
- **Memory.** `decode_stb` no longer copies stb_image's pixels, which had
  doubled the peak for a big picture: it is now 4 bytes a pixel (256 MB at the
  default limit of 64 MP) plus the file.
- **Docs.** A Thumbnails section in `docs/Server.md` (what, the settings, the
  older pictures, disk, turned photos) and the settings in `config.odin`'s
  header. `docs/API.md` doesn't change until phase 6, and the wire format was
  documented in phase 2 (`proto/attachments.odin`, `proto/messages.odin`).
- **Loop timing** (the open question): see the numbers below.

*Loop timing, measured* (`yap-stress`, 25 bots in the voice room, 5 talking,
about one post, history page and 0.2 searches a second, 40 s; 60 photos of
about 3 MB stored beforehand). With thumbnails on, the sweep made all 60
thumbnails in 15 s during the first half of the run: no voice frame was
late (0 over 20 ms, 0 missing, 224,491 heard), the longest time through the
server was 3.4 ms, the 99th percentile 1.7 ms, and the server logged no turn
over 5 ms. The baseline (thumbnails off) had 1.4 ms and 0.4 ms, but only 16 of its
25 bots got in (the server's password-hashing limit on first logins hit that
run, not the second, which used the same bots' saved keys), so it carried less
load and the comparison is rough. The thumbnail work does cost a little (a
few ms on the loop when a result is stored and a message is sent again), far
under the 20 ms a client can wait. Not measured: a much larger backlog, or
uploads of many photos while voice is busy.

## 6. Gateway

`GET /attachments/{id}?thumb=1` (or `/thumbnail`) returns the thumbnail with
`image/webp`, or the original if there's none; same auth as the existing
download. Lets bots and integrations preview pictures cheaply. Skippable.

*As built:* the query form `?thumb=1` only (`1` or `true`, `0`, `false` or
empty for the file, anything else is a 400), in `gateway/files.odin`. It asks
`Attach_Get` for the Thumbnail variant, so a picture without a thumbnail is
answered with the file (phase 2). The content type of a thumbnail request is
found from the first bytes (`imagekind`), once they have arrived and before
the head is written, so a thumbnail is `image/webp`, a small PNG without one
is `image/png`, and anything else `application/octet-stream`; the file without
`thumb` stays `application/octet-stream`. Messages list the thumbnail:
`attachments[].thumbnail` is `{size, width, height}` or `null`
(`Thumbnail_JSON`), and the re-sent message of phase 3 reaches the event
stream as `MESSAGE_UPDATE`. `docs/API.md` has a Thumbnails section.
`test_gateway_thumbnails` runs it all through the HTTP gateway (upload, post,
the thumbnail being made, the listing, the thumbnail as a WebP of the stated
size, the file whole, a bad value, a file with none); the test loop
(`lt_turn`) now runs `thumbnails_sync`. Fetching the same blob twice in a
row on one connection can answer the second with an empty body (the server
still has the first download registered until its last ack): this is how
downloads already worked, a thumbnail and its picture are different blobs, and
the test avoids it rather than fixing it here.

## Open questions

- Is 512 px the right longest side? The preview box is 480×160, so a wide
  banner at 480 wide only needs 160 tall; but the box is a cap, and
  side-by-side thumbnails or a gallery view later would want more. 512
  covers current uses at 2× only for the *height* limit 160 (320 px). A
  second, bigger size (1024) for the viewer is the natural extension, and
  the protocol's `variant` byte allows it.
- Should thumbnails count toward `daily_megabytes`? Recommended not (see 7).
- Strip metadata (EXIF GPS) from thumbnails: yes, free with re-encoding.
  The *originals* still carry it; that's a separate privacy decision this
  plan doesn't make.
- Server-side CPU: a 12 MP JPEG decode + scale + WebP encode is on the order
  of 100 to 300 ms. At one worker that is a few uploads per second, which is
  enough for chat, but measure with the `loop-timing` tooling
  (`yap-stress`) that the loop's turn time doesn't move.

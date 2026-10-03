# Attachments: plan

Files uploaded to the server with a message, in channels and DMs, kept
there until the message is deleted. The DM file transfer (an offer, the
file going client to client through the server and never stored) stays
as it is, for sending something once without it taking up room.

Branch `attachments`, from `dev` at `bb652eb`.

## The workflow

1. Pick files: the paperclip button next to the composer opens the
   system's dialog with several files selectable (on the web, a file
   input with `multiple`). Dropping files onto the window does the same
   (phase 5).
2. The files show as chips in a strip above the composer, each with its
   name, size and a × to take it off. The text box works as usual; more
   files can be added, any removed.
3. Send (button or Enter) posts the text and the files together: even
   with no text, if there are files.
4. The message shows at once in the timeline as pending, with a progress
   bar per file and the whole, and a cancel button. The composer is free
   for the next message meanwhile.
5. When every file is on the server the message is posted, with the
   files listed under its text: icon, name, size and a Save button,
   which downloads with a progress bar.

## What's there to build on

| Need | What exists | Where |
|---|---|---|
| Moving big files | DM transfers: windowed, acked, resumable chunks with u32 indices (so no size limit to speak of), paced to a rate | `proto/files.odin`, `conn/files.odin` |
| Reading a file to send, writing one received | `File_Source` / `File_Sink`, for desktops (plain files, `.part` then rename) and browsers (`web/files.js`: block reads, Blob download) | `conn/files_io_native.odin`, `conn/files_io_web.odin` |
| Keeping files on the server | The blob store: by SHA-256, a row in `blobs` with a kind; files written aside and renamed in | `server/blobs.odin` |
| Dropping what nothing uses | Retention's *collect*: blobs no message or profile points at, older than an hour, every hour and after each purge | `server/retention.odin`, `db.odin` `.Blob_Scan` |
| Several files in a dialog | `td_open_files` (Windows, macOS, zenity/kdialog); only `td_open_file` is bound so far | `deps/thirdparty/tinydialogs`, `dialogs/dialogs.odin` |
| Posting in order, retrying after a reconnect | The outbox, with nonces | `conn/messages.odin` |

What doesn't fit: blobs (`Blob_Put`/`Get`) are for pictures — at most
1 MiB, held in memory whole, one per connection at a time at 256 KB/s.
Attachments don't go through them.

## Design

### Messages

A text message gets an optional list of attachments, marked by a new
flag, so no new message kind is needed and everything that handles text
messages (edits, threads, forwarding, search, reactions) keeps working:

	Msg_Flag.Has_Attachments            (bit 4 of the flags byte; 4 are used)
	if Has_Attachments: [count u8] per file: [blob u64][size u64][name str8]

- A message may be all attachments and no text.
- At most `MAX_ATTACHMENTS` (10) per message, names at most
  `MAX_FILE_NAME` (200 bytes), so a message grows by at most ~2.2 KB.
  History pages already hold "fewer if they wouldn't fit" in the
  stream's 64 KB message.
- `Msg_Post` gets the same section after the text: the blobs it
  attaches, which have to be uploads the poster made (below).
- Editing changes the text only. Deleting a message drops its
  attachments' rows; their blobs go at the next collect (within about
  two hours), as a deleted message's picture does now.
- Forwarding copies the list: the same blobs, no new upload.
- The server keeps them in a table of their own (schema step 15):

	  attachments (msg INTEGER, idx INTEGER, blob INTEGER, name TEXT, size INTEGER,
	               PRIMARY KEY (msg, idx))

  and `.Blob_Scan` (collect) and `blob_visible` learn about it.

### Uploads and downloads

The DM transfer's chunks and acks, with the server as the other end.
They get kinds of their own, so the server never confuses one with a
transfer it only relays. The layouts and the sending and receiving code
are the DM transfer's, made to work for either peer:

	Attach_Put   [size u64][name str8]  ->  [upload u64]          (request 0x0052)
	Attach_Done  [upload u64]           ->  [blob u64]            (request 0x0053)
	Attach_Get   [blob u64]             ->  [size u64][download u64]  (request 0x0054)

	Upload_Chunk / Upload_Ack      client -> server / server -> client  (datagrams 25, 26)
	Download_Chunk / Download_Ack  server -> client / client -> server  (datagrams 27, 28)
	Transfer_Cancel                either way                            (datagram 29)

- **Upload.** `Attach_Put` checks the size against the server's limit
  and the poster's permission, and answers a transfer id. The server
  writes the chunks to `blobs/tmp/<id>.part` as they come, in order of
  arrival at their offsets, and hashes the file once it's whole. Then:
  if the store has that content, the part file goes and it's the existing
  blob; else it's renamed into the store. `Attach_Done` answers the blob
  id, and the server notes that this account uploaded it (in memory, for
  an hour: what `Msg_Post` checks, so nobody can attach a blob of a
  conversation they can't see by guessing its id).
- **Download.** `Attach_Get` answers to whoever `blob_visible` says may
  see it (a member of a conversation with a message that has it). The
  server reads the file in blocks as the window moves, never all of it.
- The client hashes nothing: the server does, as the file arrives. A
  file uploaded twice is kept once.
- An upload or download that goes quiet for a minute is dropped, and a
  part file with it. A finished upload that's never posted is
  unreferenced and goes at a collect.
- **Pacing.** The server sends and takes at most `attachment_rate`
  (config, KB/s per connection, default 2048) and the client sends at
  most its upload limit (settings). It never sends more than the voice
  loop can spare: the same token bucket per connection as blob
  downloads, refilled at that rate. At most `MAX_TRANSFERS` (4) of
  each per connection.

### Limits and permission (server config)

	"attachments": { "max_megabytes": 100, "rate_kb": 2048 }

- `max_megabytes` per file; 0 turns attachments off (the paperclip goes
  away: Server_Info says the limit).
- A new permission `Attach_Files` (bit 9), which everyone's role has by
  default, so a server can take it away from a role or everybody.
- They count towards retention's `blob_megabytes` like pictures. A new
  `file_days` drops the attachments of messages older than that; the
  message stays and says the file is gone (like `image_days`).

### Client

- `conn`: the outbox's `Pending` gets a list of files (path or web
  handle, name, size, how far along). A message with files uploads them
  one after another, then posts. **It doesn't hold up what's written
  after it** (decision 4): text sent meanwhile goes first. A failed
  upload leaves the message pending with Retry/Discard.
- A `Save_Attachment_Command` (message, index) starts a download into
  the downloads folder (unique name, `.part` until whole) or, on the web,
  the browser's download. The `View` gets each transfer's progress, as
  for DM files.
- The headless client gets `/attach <file>...` (the next `/say` takes
  them along) and `/save <message> <n>`, which tests and scripts use.

### UI

- **Composer:** a paperclip icon button between the text box and the
  emoji button. The strip of chips above the text box is the
  composer's, so the main chat, a DM and each thread have their own.
  Chips are cut to fit and wrap to a second row; past
  `MAX_ATTACHMENTS` the button is off. A file over the server's limit
  is refused when picked, with a line saying why.
- **Pending message:** the text, then a row per file with its name and
  a progress bar, and one Cancel.
- **Posted message:** under the text, a row per file: an icon by type
  (archive, picture, video, audio, document, other), the name cut to
  fit, the size, and Save. While it downloads, a progress bar and
  Cancel; once it's done, "Saved" and Open folder (desktop only).
- **Phones (web, narrow layout):** the chip strip scrolls sideways, and
  rows keep Save visible by cutting the name.

## Phases

| # | What | Done when | Size |
|---|---|---|---|
| 1 | **Protocol and server.** Message section, Msg_Post with attachments, schema step 15, Attach_Put/Done/Get and the transfer datagrams, the server as upload receiver (part file, hash, store) and download sender (block reads), uploader notes, `Attach_Files`, config limits, `blob_visible`/collect/delete/forward/`file_days`. | Server tests: upload, dedupe, post, fetch, visibility refused, delete then collect, limits | L |
| 2 | **Client connection.** The DM transfer's sender and receiver made peer-neutral; outbox with files; saving; View state; headless `/attach` and `/save`. | Two headless clients: one attaches 3 files (one 50 MB) in a channel and a DM, the other saves them byte-identical; a reconnect in the middle resumes | L |
| 3 | **Desktop UI.** Multi-file dialog (`td_open_files`), chips, send, pending progress, attachment rows, Save/progress/Open folder. | Off-screen: pick, remove, add, send with text, watch progress, save | M |
| 4 | **Web.** `files.js` picks several files; uploads read from them; downloads through the sink; narrow layout. | Headless Chromium: same as phase 3 | M |
| 5 | **Extras.** Drag and drop onto the window (GLFW drop callback; the page's drop event), file names in search, a picture attachment shown small with Save. | Each on its own | S each |

Phases 1 and 2 are most of the work. Each phase is committed on its own,
with tests, and leaves `dev`-mergeable code: nothing in the UI before
the connection can carry it.

## Decisions for you

| # | Question | Recommendation |
|---|---|---|
| 1 | Which file types? | **Any.** The server only keeps bytes. The client never opens anything on its own: Save writes it to downloads, and an executable is saved with a note that it came from someone else. The DM transfer's allowlist stays as it is. |
| 2 | Largest file, and per message | **100 MB per file, 10 files per message**, the size in the server's config (0 turns attachments off). |
| 3 | Who may attach | **A permission, `Attach_Files`, that everyone has by default**, so a server can restrict it per role. |
| 4 | A message with files still uploading, and what's written after it | **Post each when it's ready**: text written meanwhile isn't held up, and so may come first. The alternative (strict order) makes a big upload block the chat. |
| 5 | Pictures among the files | **Shown as files** (with Save) in phases 1–4; a small preview in phase 5. Pasting a picture keeps posting it as a picture message, as now. |
| 6 | Retention | Attachments count towards `blob_megabytes`, and a new **`file_days`** (default 0: kept) drops old ones, leaving the message with "file removed". |
| 7 | Where a desktop saves | **The downloads folder**, a unique name if one's taken, with Open folder afterwards. (A "Save as…" dialog could come later.) |

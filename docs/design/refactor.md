# Refactoring review: duplication, cleanup, layout

Reviewed 2026-10-24 on `master` (0f33ee7), now that the client is feature
complete. About 137k lines of our own code (vendored libraries not counted):
client 33k + conn 21k, server 34k, proto 15k, gateway 5k, web 4.4k.

Nothing here is built yet. The findings come first, grouped by theme, with
`file:line` references from 0f33ee7. A proposed order of work is at the end.
Each item says roughly what it saves; "spot-checked" marks the ones that
were confirmed by hand on top of the review.

## Overall

The code is in better shape than a project this size usually is:

- Next to no dead code. Every `Stmt` in the server is used, only one of
  628 server procs has no caller, conn has no unused procs or constants,
  and the UI has no unreferenced top-level symbols.
- No TODO/FIXME/XXX anywhere in our code, no commented-out blocks, no
  traces of poke. "Picture" survives only in comments and one leftover
  outbox path (C2).
- Locking, View writes and error logging follow one pattern throughout.

So this is mostly about **duplicated layers that have started to drift
apart**, a few **big files and procs**, and **build/CI/layout tidying**.
None of it is urgent. A1, A2 and the bug in E1 are the ones that already
cost something.

---

## A. Cross-cutting duplication (biggest wins)

### A1. The link handshake state machine exists five times

The pending/current/previous session trio (drive, resend, timeout, cookie,
Resp, Finish, open, promote) is written out separately for:

- client main link: `src/client/conn/client.odin:291-520` (it already has
  `Link`, `link_open`, `link_promote`)
- client bulk link: `src/client/conn/bulk.odin:44-208`
- client media link: `src/client/conn/media.odin:57-281`
- lite client (gateway/stress): `src/common/lite/lite.odin:444-573`, with
  its own `link_open` and `promote_pending` (spot-checked)

The server side has a pair of its own: `src/server/media.odin:339-500`
re-implements `handle_init` / `handle_finish` / `handle_data` /
`drop_session` from `src/server/server.odin:402-800`.

The copies **have drifted**:

- `handle_finish` throttles re-Welcomes (`REWELCOME_EVERY`,
  server.odin:471), but `media_finish` sends one on every Finish
  (media.odin:397).
- `handle_data` follows a new source address only after login
  (server.odin:795), but `media_data` always does (media.odin:497).

**Proposal:**

- **Client side:** a `proto.Initiator_Link` (the trio plus timers) with
  `link_drive(l, now, send, start)` and `link_handle(l, packet) -> (event,
  pt)`. Each link adds only its send function, its `Link` kind for the
  hello, and refusal/timeout hooks.
- **Server side:** a `Session_Base` embedded with `using` in both session
  types, and shared `session_init` / `session_finish` procs.

Saves ~300-350 lines on the client side and ~100 on the server, and the
next rekey or reconnect fix is made once. **Risk:** high. It needs
reconnect, rekey and server-restart testing on all links, and a stress
run.

### A2. Token buckets are written out ~13 times

`tokens = min(tokens + elapsed*rate, burst)` and friends appear in:

| Area | Places |
| --- | --- |
| lite | `lite.odin:784` |
| proto | `transfer.odin:176` |
| gateway | `limits.odin:72`, `limits.odin:152`, `files.odin:559` |
| client | `stream.odin:96`, `messages.odin:1814`, `video.odin:1059` |
| server | `stream.odin:99`, `rpc.odin:46`, `files.odin:118`, `transfers.odin:286`, `attachments.odin:360`, `register.odin:80`, `addr_limit.odin:81` |

Keyed bucket maps that prune at 1024 entries are written three times:
twice inside `gateway/limits.odin` (44-100, 130-170) and once in
`server/addr_limit.odin`.

**Proposal:** `proto.Bucket {tokens, last}` with `bucket_refill` and
`bucket_take`, plus `Keyed_Buckets($K)`. Saves ~120 lines. Low risk.

### A3. Stream pacing is copied three times

`STREAM_RATE`, `STREAM_BURST` and `STREAM_QUEUE_MAX`, and the
ack-then-send-while-tokens loop, are in:

- `client/conn/stream.odin:18-115`
- `common/lite/lite.odin:48, 777-800`
- `server/stream.odin:19-115`

**Proposal:** move the constants and a `stream_pace` helper to
`proto/stream.odin`. Builds on A2.

### A4. Small helpers copied between packages

| Helper | Copies | Note |
| --- | --- | --- |
| `key_id` | `server/auth.odin:799` (`key_id_of`) = `common/keys.odin:74` | byte-identical (spot-checked) |
| `key_hex` | `client/settings/settings.odin:454`, `client/conn/known_servers.odin:143` | also hand-rolled in `gateway.odin:661`; hex parsing ×4 |
| `jpeg_size` | `common/gateway/files.odin:988`, `server/transfers.odin:308` | **drifted**: gateway treats `0xD8` as a length-less marker, server doesn't (spot-checked) |
| image sniffing | `gateway/files.odin:1028` re-inlines the WebP/GIF magic | a pure `common/imagekind` (magic bytes + `jpeg_size`) for gateway, server and `clipboard_decode.odin:22` |
| endpoint resolve | `gateway/main.odin:131`, `stress/stress.odin:226`, `client/conn/transport_native.odin:25` | |
| `format_bytes` | `client/conn/files.odin:604`, `client/ui_image_cache.odin:104` | slightly different output |
| `fit()` | `video/src/share.cpp:78`, `capture_mac.mm:197` | the comment says they must stay the same, so move it to `internal.h` |
| status lines | `gateway/serve.odin:307`, hard-coded in `server/relay.odin` | move to `common/http` |
| address classing | `gateway.address_private` (used by `server/relay.odin`), and a stricter one in `server/push.odin:330-380` | one `netaddr` package; also misses IPv4-mapped IPv6 |

---

## B. Proto (`src/common/proto`)

### B1. Codec primitives and two encoding styles

- About 220 encode/decode procs make up ~2,600 of the 8,800 non-test
  lines.
- The primitives are tucked away in the wrong places:
  - The Writer/Reader live at the bottom of `messages.odin:485-614`.
  - `written()` and `get_str8_opt()` are file-private in
    `accounts.odin:283-295`.
  - So `nil if w.overflow else out[:w.pos]` is inlined 20 times, and
    the trailing-field check 14 times.
- Writer/Reader and raw `endian.unchecked_*` offsets are mixed, sometimes
  in one file (`msgs.odin`).

**Proposal:**

- Add a `codec.odin` with `written`, `get_*_opt` and `has_more`.
- Use Writer/Reader everywhere except the hot datagrams (voice, video).
- Code generation or table-driven codecs are **not** worth it: per-field
  range checks, optional trailing fields and fixed-array outputs fit them
  badly.

### B2. Seven single-id bodies

`conv_id`, `room`, `account_id`, `call_id`, `msg_id`, `blob_id` and
`attach_id` each have their own encode/decode pair. They also validate
differently:

- `decode_msg_id` and `decode_blob_id` require the exact length and a
  non-zero id.
- `decode_conv_id` and `decode_room` accept trailing bytes and 0.

**Proposal:** a parapoly `encode_id($T)` / `decode_id($T)` with one rule
for all seven.

### B3. Retired message kinds

There are 20 retired `Message_Kind`s at `messages.odin:65-118`: `Join`,
`Set_Name`, `Chat*`, `Image*`, `DM*`, `Last_Seen*`.

- They are dead on the wire: `decode_hello` requires `payload[0] ==
  HELLO_VERSION` (14) exactly, so no old client gets that far
  (spot-checked).
- They still force no-op case arms in `messages.odin:233-293`,
  `server.odin:873-893` and tests.
- Removing them keeps the other values (explicitly numbered), and an
  unknown byte still gives `ok = false`.

### B4. Unused outside tests

- `encode/decode_file_chunk` and `encode/decode_file_ack`
  (`files.odin:115-152`); the client uses `encode_transfer_chunk`.
- `encode_video_down` (`video.odin:237`).
- `ATTACH_GET_SIZE` (`attachments.odin:44`).
- `decode_auth_login_response` (`accounts.odin:335`), used by server tests
  only.

### B5. Stale comments

- The `rpc.odin:30-33` Server_Info layout lacks `max_cameras`,
  `camera_kbit` and `demand`.
- The version history in `names.odin` cites the deleted `chat.odin`.

### B6. File names

| Now | Holds | Suggested |
| --- | --- | --- |
| `messages.odin` | datagram kinds, presence, codec primitives | `datagrams.odin` (+ `codec.odin` from B1) |
| `msgs.odin` | stored chat messages | `messages.odin`, once the above has moved |
| `names.odin` | sanitizers, and the hello/welcome/`Link` handshake with its version history | `sanitize.odin` + `hello.odin` |

---

## C. Client conn (`src/client/conn`)

### C1. Status texts and input checks

- Two mappers from `proto.Status` to text give different wording for the
  same status (`.Denied`, `.Not_Found`): `status_text` (`auth.odin:593`)
  and `manage_done` (`roles.odin:553`).
- There are 14 callbacks of the form `if status != .Ok {
  notify(c,false,status_text(status)) }`.
- The username and password length messages are written out 7 times:
  `auth.odin:344,352,644,813,824,861` and `bots.odin:39`.

**Proposal:** one mapper, a shared `notify_done` callback, and
`check_username` / `check_password`. Saves ~60 lines, and the wording is
the same everywhere.

### C2. The outbox still carries the picture upload path

`Pending` (`messages.odin:165-191`) serves text posts, DM file offers and
attachment posts, but also avatars and server icons.

- The `.Put` / `.Upload` states, `Upload`, `put_done`, `upload_step` and
  `upload_need` (`messages.odin:157-200` and `1667-1868`, ~200 lines) are
  left over from picture messages. They now serve only avatars and server
  icons, and the comments at `:159`, `:182`, `:193` and `:1630` still talk
  about pictures.
- Avatar setup and icon setup are copies of each other
  (`profiles.odin:221-243`, `server_info.odin:~135-163`).
- `pending_destroy; ordered_remove(&outbox,0); publish_outbox` appears 7
  times.

**Proposal:** a small blob-upload queue in `blobs.odin` for avatars and
icons, an `outbox_pop` helper, and an outbox for messages only.

### C3. File and attachment chunk loops

`send_chunks` (`files.odin:381`) and `send_upload` (`attachments.odin:378`)
are the same loop with a different source and chunk kind. Saves ~25 lines.

### C4. Video backend into its own package

- `video_native.odin` (1377 lines) and `video_web.odin` (571) never touch
  `Voice_Client`.
- Both define the same types: `Share_State`, `Video_Source_Kind`,
  `Video_Source` and `Video_Encoder`.

**Proposal:** a `client:video` package, with those types defined once.
`video.odin` (the protocol and pacing side) stays in conn.

### C5. Other self-contained parts of conn

These have no View or client references and could move out:

- `markdown.odin` and `mentions.odin` (~1050 lines) → `client:richtext`
- `address.odin` and `known_servers.odin`

### C6. File splits inside conn

| File | Split into |
| --- | --- |
| `messages.odin` (2400 lines) | timeline cache/history (≤1460), outbox (1464-1946), View publishing (1950-2400) |
| `video.odin` (1535) | presets/tiers/demand, send queue/pacing, watching, bitrate adaptation |
| `channels.odin` | `presence.odin` (`Channel_Client`) and `commands.odin` (the `Command` union and the 261-line `process_commands`) |
| `roles.odin:300-550` (channel administration) | `conv_admin.odin` |

### C7. Command cleanup is by hand

`command_destroy` (`channels.odin:464-575`) frees ~45 variants by hand,
so a new owned field is easy to forget.

**Proposal:** a `destroy` next to each command struct, or one
owned-strings convention.

### C8. Headless output inside protocol code

There are 26 `if c.view == nil { log... }` blocks, for example
`convs.odin:613`, `auth.odin:758` and `messages.odin:1612`.

**Proposal:** a small output sink, implemented by the View and by
`client_cli.odin`.

### C9. Naming

`Voice_Client` is the whole server connection, used in 443 places. A name
like `Server_Conn` would fit better. This is a big mechanical rename, so do
it last or not at all.

### C10. Small items

- `log_stats` (`client.odin:668-747`) builds its string every second even
  when debug logging is off, and resets counters nothing reads.
- `decode_ogg_opus` is in `notification_sounds.odin:185` but used by
  `sound_store.odin`.
- `cut` (`sound_store.odin:193`) is just `slice.clone`.
- `video_test.odin` has the same helper twice (`copy_slice`,
  `slice_clone`).

---

## D. Client UI (`src/client/*.odin`)

### D1. Seven copies of `command`

The same file-private 5-liner is at:

- `ui_account.odin:135`
- `ui_bots.odin:18`
- `ui_channel_settings.odin:83`
- `ui_channels.odin:66`
- `ui_memory.odin:156`
- `ui_manage.odin:54`
- `ui_roles.odin:188`

About 19 more places spell out `conn.push_command(&ui.session.client...)`
by hand. **Proposal:** one shared proc (spot-checked).

### D2. The composer row is written out three times

The copies are in `ui_chat.odin:423-450`, `ui_threads.odin:249-275` and
`ui_buddies.odin:530-571`.

- **Visible difference:** the channel's send hint says "Send"; DMs and
  threads say "Enter: Send / Ctrl+Enter: New line".
- `NOTICE_SHOW` is defined twice.
- The header status line (clipboard, editing, notice, typing) is built
  twice with different colours: `ui_buddies.odin:438-458` and
  `ui_chat.odin:460`.

**Proposal:** a `composer_bar` helper. Saves ~50 lines.

### D3. List/detail screens and notices

The narrow-versus-wide list/detail layout is written three times, each
with its own `LIST_WIDTH` / `EDITOR_MIN`:

- channels: `ui_channel_settings.odin:134`
- roles: `ui_roles.odin:214`
- accounts: `ui_account.odin:891`

The same three files also share:

- **Server notices,** shown by three near-identical procs:
  `notice_label`, `channel_admin_notice` and `roles_notice`. They
  mark notices seen in two ways (a reset flag, or a `-1` sentinel).
- **The two-step delete button,** written twice:
  `ui_channel_settings.odin:410` and `ui_roles.odin:433`.

**Proposal:** `list_detail`, a `Notice_Mark` type and `confirm_button`.
Saves ~100 lines.

### D4. Settings are saved three ways

- 29 direct `settings.settings_save(...)` calls, which leave
  `settings_dirty` set, so a second save follows.
- 8 calls to `save_settings(ui)`.
- 17 places that set `settings_dirty = true`.

The "apply when the slider is released" logic is also copied 3 times.

**Proposal:** one way to save, a `setting_checkbox` that marks the
settings dirty, and a `release_slider` helper.

### D5. Generic widgets live in feature files

| Widget | Lives in |
| --- | --- |
| `field_row`, `row_fits`, `wrap_text` | `ui_settings.odin` |
| `choice_button` | `ui_invites.odin` |
| `section_label` | `ui_buddies.odin` |
| `card_*` | `ui_account.odin` |
| `tab_button`, `header_line` | `ui_chat.odin` |
| `text_proc` | defined twice |
| `stable_button_hint` | a copy of `stable_button` |

`with_text_color(ctx, theme.dim, …)` is called 94 times, 57 of them right
after a `{-1}` row.

**Proposal:** move these into a `ui_widgets.odin`, together with
`dim_note` / `warn_note`.

### D6. Text buffers as buf/len pairs

There are ~35 `*_buf: [N]u8` + `*_len: int` field pairs (18 in
`ui_account.odin`).

**Proposal:** a parametric `Text_Field($N)` with `field_text` /
`field_set`.

### D7. File splits

- **`ui.odin` (2575 lines):**
  - `ui_frame.odin`: 395-860
  - `ui_window.odin`: 861-1100 and 2245-2575
  - `ui_sessions.odin`: 1103-1500
  - `ui_widgets.odin`: 1882-2245
- **`ui_account.odin` (1170 lines):**
  - the login screens stay
  - `Server_Category` (510-616) → `ui_settings.odin`
  - account admin (883-1170) → `ui_manage.odin`

### D8. Big procs and the UI struct

- **`read_commands`** (`channels_cli.odin:132`, 637 lines, 94 cases,
  `line[len("/x "):]` 47 times): use a table of `{name, usage, handler}`,
  which would also generate the help text.
- **`run_headless`** takes 13 positional parameters; give it an options
  struct.
- **`timeline`** (`ui_timeline.odin:285`) and **`text_area`** (280 lines
  each) can be split into measure, scroll target and draw.
- **`render.render`** (`render/render.odin:557`, nested 8 levels) scans
  `roots` linearly for every command.
- **`UI` struct** (~120 fields): group the connect form, redraw pacing,
  meter, voice, settings navigation, window and paste/pick fields into
  sub-structs, as is already done for `video` and `camera`.
- **Font/padding save and restore** is written out at 25 sites; a
  deferred `push_font` / `push_style` would tidy them.

### D9. Smaller items

- X11 loading is duplicated in `hotkeys/backend_linux.odin:340-375` and
  `backend_openbsd.odin:216-245`.
- Some globals lack the `g_` prefix: `thumbs`, `armed`, `last_press`,
  `glfw_proc`, `pending_open`, `last_seen`, `theme`.

---

## E. Server (`src/server`)

### E1. A latent bug found along the way (client side)

The conv browse tag in `client/conn/convs.odin:590` packs the offset into
31 bits, but `:607` reads it back with `tag & 0xffff`. A browse offset of
65536 or more would come back wrong (spot-checked). This is a one-line fix
and can go in any time.

**As built (phase 1):** narrower than it looked. The offset is a u16 on the
wire (`proto/convs.odin:328`, clamped to 65535), so `& 0xffff` matches the
protocol. The real fault: past 65535 the server was asked for 65535, but
the client remembered the offset wrapped (65536 → 0). `conv_browse` now
clamps the offset once, before the request and the tag.

### E2. DB statement boilerplate

- There are 122 `db_stmt` sites and 273 `db_bind_*` calls, almost all
  stmt → bind ×N → `db_run`.
- **Proposal:** a variadic `db_exec(db, .Stmt, ..any)` / `db_row(...)`
  that binds by type. Saves ~200-300 lines.
- The 15-column message SELECT is copied 8 times in `STMT_SQL` (db.odin
  ~245). A `MSG_COLS` constant would keep it in line with `msg_of_row`.
- `db_bind_*` ignores SQLite's return codes (db.odin:621-640).

### E3. Message handlers

`msg_post` and `msg_forward` share thread-root resolution, the
repeated-nonce answer and the fan-out after storing:

- thread-root resolution: `messages.odin:117-128` and `310-321`
- the repeated-nonce answer: `131-136` and `322-326`
- the fan-out after storing: `223-245` and `357-372`

`msg_of_member` (`msg_changes.odin:35`) is file-private and re-inlined 3
times. Saves ~50 lines.

### E4. Test harness

- **Where it lives:** the shared harness sits inside feature tests.
  - `Test_Server` / `ts_*` are in `auth_test.odin:38-216` (used by 32
    files).
  - `logged_in` is in `convs_test.odin:14` (used by 23 files).
  - Move them into a `harness_test.odin`.
- **Link helpers:** the bulk test link helpers (`bulk_test.odin:16-79`)
  duplicate the media ones (`media_test.odin:17-95`).
- **Request wrappers:** edit/delete/react exist twice, pin twice, and
  `DM_Open` three times (`dm_with`, `dm_open_as`, `open_dm`).
- **`to_lower`:** two copies.
- **Setup:** temp dir + blob store setup is repeated 33 times; a
  `ts_open_with_blobs` would replace it.

Saves ~150-200 lines.

### E5. CLI boilerplate

- "Config file not found" + `load_config` is repeated 5 times, and the
  wording has already drifted ("run the server once" vs "start").
- `db_open` + `accounts_load` is repeated 3 times.
- `main.odin:27-78` has 4 identical dispatch blocks.
- Rename `cli.odin` → `cli_account.odin`.
- Split `run_account_command` (223 lines) by subcommand and
  `check_config` (213 lines) by section.

### E6. Permission guard

`can(.Manage_Accounts)` → `account_live` → `Not_Found` → `outranks` is
repeated at:

- `auth.odin:399`
- `auth.odin:481`
- `auth.odin:662`
- `bots.odin:69`
- `roles.odin:464`

**Proposal:** a `may_manage(u, target)` helper.

### E7. Dead and stale code

- `db_col_null` (`db.odin:688`) has no callers. The `sqlite.column_type`,
  `sqlite.NULL` and `sqlite.libversion` bindings go with it.
- `age_blobs` (`retention_test.odin:33`) has no callers.
- The `messages.blob` column and the `messages_blob` index
  (`db_schema.odin:114,123`) are unused since step 22. **Decided:** schema
  step 29 drops them (`DROP INDEX messages_blob; ALTER TABLE messages DROP
  COLUMN blob`). Only the test server has data, so the migration is cheap.
- The comment at `msg_changes.odin:25-28` still talks about pictures and
  `blob_visible`.
- **The 28 migration steps:** squashing them would break upgrades of
  existing databases and `test_schema_upgrade`. With only one test server
  deployed, that cost is small, so squashing into one baseline schema is
  now possible (see the open question at the end).
- `attach_test_sent` is a thread-local test hook in production code
  (`attachments.odin:156`); it could become a field on `Server`.

### E8. Structure

The flat 95-file package is fine: `Server` is the hub, and splitting by
feature would export everything. Pull out only the leaf modules that never
touch `^Server`, `^Conn` or `^DB`:

- `email.odin` + `curl*.odin` (~1040 lines) → `server/mail`
- `push.odin` + `push_crypto.odin` (~780) → `webpush`
- `handshake_gate.odin` + `addr_limit.odin` (~316) → `gate`
- `media.odin`, after A1

---

## F. Common, gateway, stress, video

- **What `common/` holds:** `gateway`, `lite` and `http` are never used by
  the client. `common/` now mixes truly shared code (proto, wlog, store,
  memtrack, webp, gif) with server-side services. **Decided:** split them
  out.
  - **Where:** `src/lib/` as a new `lib:` collection, holding `http`,
    `gateway`, `lite` and the new `netaddr` (A4). `common/` keeps only
    what the client also uses. `stress` and the gateway binary import
    `lib:`.
  - **Build flags:** the collection is listed in 5 build places
    (`build.sh`, `build.bat`, `web/build.sh`, `build.yml` and the
    Dockerfile; see G2). Collect those into one place first, or in the
    same change.
  - Keep `common/gateway` (then `lib/gateway`) as a library: `yap-server` embeds it,
    and `src/gateway/main.odin` is the thin binary.
- **Standalone gateway accept loop** (`gateway/main.odin:110-125`):
  - It has no connection cap.
  - It leaks the socket when `thread.create_and_start` fails.
  - The relay's `accept_browsers` (`relay.odin:188-225`) handles both, so
    share one accept loop in `common/http`.
- **Key not wiped:** `common.generate_private_key` (`keys.odin:20`) doesn't
  zero `raw`, whereas `vapid_key_generate` does.
- **`src/video`** is well layered (an `Output` interface over GL, D3D11 and
  Metal). Only `fit()` is duplicated (A4).

---

## G. Build, CI, scripts, web

### G1. CI and Docker problems (fix first)

- **The push filter misses files.** `build.yml:13-20` lists `*.c *.h *.js
  *.odin *.yml *.bat *.sh` only. A master push touching only these does
  not build (spot-checked):
  - `src/video/**/*.cpp` and `CMakeLists.txt`
  - `scripts/*.version` and `yap.iss`
  - `web/index.html` and `manifest.webmanifest`
  - `*.py`
- **Odin versions differ.** CI uses `dev-2026-07` and the Dockerfile
  `dev-2026-09`. `emscripten/emsdk:latest` and certbot are unpinned.
- **`.dockerignore` is stale.** Its per-file lines 15-18 are moot, since
  `!scripts/` re-includes the folder. `!web/**` sends `web/out` and
  `web/deps` into the build context.
- **The Docker image's web client has no version** (no `YAP_VERSION` in
  the web stage).
- **`docker.yml`:**
  - It tests for `refs/heads/extended`, which is dead.
  - It builds the image twice.
  - It has no paths filter.
- **Linux CI compiles `src/video` twice**, uncached (`build.sh:126` plus
  `build-video.sh`). The emsdk download isn't cached either.
- **The "Set up MSVC" step is redundant:** the `.bat` files find vcvarsall
  themselves.

### G2. Duplicated build logic

- **Fetch scripts:** `fetch-opus.sh`, `fetch-sqlite.sh`, `fetch-webp.sh`
  and `fetch-ffmpeg.sh` are near copies. Use one `scripts/fetch.sh <name>`
  reading `<name>.version`.
- **`build.bat` and `build-video.bat`:** the same fetch block appears 4
  times; make it one `:fetch` subroutine.
- **The C archive step** (stale check, `cc -c`, `ar rcs`) appears:
  - 7 times in `build.sh`
  - in `build-webp.sh`
  - in the Dockerfile
  - 6 times in `build.bat`
  
  A `build_c_lib` function would cover them.
- **Opus CMake flags** are in 3 places and have drifted: Windows lacks
  `-DOPUS_HARDENING=OFF` (spot-checked). The libwebp flags are copied
  twice. **As built (phase 1):** the drift went the other way. `OFF` comes
  from the web build, where hardening means nothing on wasm, and was copied
  into the native macOS/OpenBSD build. Native builds now keep opus's
  default hardening, as Windows always did (checked: opus 1.6 builds with
  `-fstack-protector-strong -D_FORTIFY_SOURCE=2`).
- **The Dockerfile repeats the build scripts:** the SQLite build,
  version-defines and the stb fallback.
- **Repeated lists:** the web output list appears 3 times, and the
  collection flags 5 times.

### G3. Web JS and shell

- **Repeated JS helpers:**
  - the string-to-heap copy, 4 times (`paste.js:141`, `files.js:43`,
    `sounds.js:114`, `avatar.js:58`)
  - the hidden file picker, 3 times
  - the `toBlob` shrink loop, twice
  - opening IndexedDB, two ways
  
  These could go into one `web/util.js` as the first `--pre-js`.
- **`web/shell.c`:** 942 lines and 116 `EM_JS` shims. Split it by area
  (video, push, fields), or move them into `--js-library` files like
  `wasi.js`.
- **`web/build.bat:11`** hard-codes `E:\repos\emsdk-main`.
- **`web/README.md`** still says the desktop client can't watch shares.
- **Generated files:** `web/gen_foreign.py` output isn't checked. A CI step
  could regenerate it and run `git diff --exit-code`.

### G4. Repo housekeeping

- **`.gitignore:1` is a bare `yap`**, which ignores that name at any depth;
  anchor it as `/yap`. The `misc/hq-share/*/` entry is stale.
- **No build guide.** The top `README.md` has no build section; the
  options are only explained in script headers.
- **`scripts/demo.png`** is the README header picture, so it belongs in
  `docs/`.
- **`misc/keyframe-test/keytest.cpp`** is a one-off that nothing builds.

---

## H. Folder layout

Proposed, from the least to the most disruptive:

1. **`scripts/` split by job:**

   ```
   scripts/build/     fetch.sh, build-*.sh/.bat, *.version, version-defines.sh
   scripts/package/   package*.sh, yap.iss
   docker/            Dockerfile, docker-compose.yml, .env.example, nginx/
   tools/             emoji.py, call_sounds.py, gen_testdata.py, gen_foreign.py
   docs/demo.png
   ```

   - The compose file's `./nginx` mounts are relative, and
     `docs/Server.md:27-30` links to them, so move them together.
   - `.dockerignore` stays at the context root, or becomes a BuildKit
     `docker/Dockerfile.dockerignore`.

2. **`misc/` becomes design notes.**
   - The 12 plans (6,900 lines) are phase checklists for finished work.
     Four still say "Nothing here is built yet", and several point to
     `docs/extended`, `docs/next` and `docs/polish`, which no longer
     exist.
   - Code cites them, for example "D12 in misc/hq-share/README.md" in
     `build.yml`, `package-video.sh`, `build-video.sh`, `src/video` and
     `push*.odin`.
   - **Proposal:** `docs/design/<topic>.md`, each cut to its decisions plus
     "as built", with the references updated. Delete the phase checklists
     (git keeps them).

3. **New packages, only where the boundary is already clean:**

   | Package | Comes from |
   | --- | --- |
   | `client:video` | C4 |
   | `client:richtext` | C5 |
   | `client/headless` | `client_cli.odin` + `channels_cli.odin`, ~870 lines, need only conn/settings/proto and `avatar_load` |
   | `client/image` | `image.odin`, `ui_window_icon.odin`, `ui_wayland_decorations.odin` (no `UI` references) |
   | `server/mail`, `webpush`, `gate` | E8 |

   The ~100 `ui_*.odin` files should **stay one package**. In Odin a
   folder is a package, and they all take `^UI`, so a sub-folder would
   mean exporting nearly everything. Fewer, better-split files (D5, D7)
   is the better tidy-up there.

4. **Not recommended:**
   - Moving `web/` under `src/`: small gain, and it breaks the
     Dockerfile, CI, `web_dir` defaults and habit.
   - Instead, move build output (`web/out`, `web/deps`) to
     `.cache/web`.

---

## Proposed order

The phases are ordered by risk, smallest first. Each is its own branch off
master, so it can be tested and merged alone.

| # | Phase | Items | Risk | Est. lines |
| --- | --- | --- | --- | --- |
| 1 | Quick fixes | E1 browse-tag bug, G1 CI filter / Odin pin / `.dockerignore` / docker.yml, G2 opus flag drift, G3 `build.bat` path, G4 `.gitignore` | low | — |
| 2 | Dead code and stale text | B3 retired kinds, B4, B5, E7 incl. migrations squashed into a version-29 baseline, C10, the C2 picture comments, D1 | low | −250 |
| 3 | Renames | C9 `Voice_Client` → `Server_Conn`, B6 proto file renames, `cli.odin` → `cli_account.odin`, D9 `g_` prefixes | low (mechanical, big diff) | — |
| 4 | Small shared helpers | A4, A2 buckets, A3 stream pacing, C1 status texts | low-med | −300 |
| 5 | Proto codec | B1, B2 | med | −250 |
| 6 | Server dedup | E2 `db_exec`, E3, E4 harness, E5, E6 | med | −550 |
| 7 | UI dedup | D2, D3, D4, D5, D6, D7 splits | med (needs GUI runs) | −400 |
| 8 | conn restructuring | C2 outbox, C3, C4 `client:video`, C5 `client:richtext`, C6, C7, C8, H3 `client/headless` + `client/image` | med-high | −300, ~3k lines out of conn |
| 9 | Link state machine | A1, client and server | high (reconnect/rekey tests) | −450 |
| 10 | Packages and layout | G2 collections in one place, then F `common/` → `src/lib/`, E8 `server/mail` / `webpush` / `gate`, G2 fetch / `build_c_lib`, G3 `util.js` and shell split, H1 `scripts/` split, H2 `misc/` → `docs/design` | low code risk, many paths | −400 |
| 11 | Optional | D8 big procs and UI struct | varies | — |

**Order:**

- **Renames go early (phase 3).** No branches are waiting to merge, so the
  big mechanical diffs are cheapest now, and every later phase is written
  against the final names.
- **Run the phases one after another,** each branched off master once the
  previous one is merged. If they run in parallel, the renames and file
  splits conflict with everything else.
- Phases 1-4 are mechanical. 6 and 7 are where most of the lines go.
- 9 is the most valuable for future bug fixes but needs the most testing.
  Doing 5 before 9 helps, since the shared link code would use the new
  codec helpers.
- **H2 moves this plan too**, to `docs/design/refactor.md`, as the last step
  of phase 10. Until then it stays in `docs/design/refactor` so its references
  remain valid.

## Progress

| Phase | Branch | Commit | State |
| --- | --- | --- | --- |
| 1 | `refactor-quick-fixes` | 1d8dda0 | built: native build, conn tests and the Docker image (podman) checked; CI on Windows/macOS untested |
| 2 | `refactor-dead-code` (off `big-cleanup`) | c5ef282 | built: all test suites, native + web checks, GUI run (post, voice join/hang-up), schema SQL checked against the old 28 steps |
| 3 | `refactor-renames` (off `big-cleanup` 8879b3d) | 7a9e7d5 | built: Linux, web, Windows and macOS checks, all test suites, GUI start; `theme` kept without `g_` (385 uses, reads as the palette's namespace) |
| 4 | `refactor-helpers` (off `big-cleanup` a66040c) | 3e782ed..c4167c5 | built: all suites, all targets checked, video library rebuilt, GUI run (history, post, image cache, trusted servers) |
| 5 | `refactor-codec` (off `big-cleanup` b53aa3e) | 8c795c4 | built: all suites, all targets checked, headless connect/history/post against the new server |
| 6 | `refactor-server` (stacked on `refactor-codec` 8c795c4) | cb7b407, 3eb3aac | built: all suites, all targets checked, CLI commands run by hand, headless connect/history/post |
| 7 | `refactor-ui` (off `big-cleanup` 6f23d89) | 71e4f45, 21a3918, 57d7422, 68ae614 | built: all targets checked, client tests, GUI run (channel/thread/DM composers, server settings, Channels/Roles/Accounts wide and at 420 px, notices, two-press deletes, release sliders, text fields) |
| 8 | `refactor-conn` (off `big-cleanup` 41a2dea) | 0a7c317..7bc6a4b | built: all targets checked, conn/richtext/imaging/client tests, headless avatar set (known and fresh picture) and a headless command run diffed old against new; server-icon upload and a GUI run not done |
| 9 | `refactor-link` (off `big-cleanup` 2de967b) | af0752d, 53accd7 | built: all targets checked, proto/server/conn tests (+ link_step and session tests), headless client with a 6 s rekey across a server restart (main, bulk and media links all came back), stress run identical to before; browser client not run |
| 10 | `refactor-layout` (off `big-cleanup` a7bb33a) | 5689fde..HEAD | built: all targets checked, all test suites, `build.sh` run twice (second is a no-op), `fetch.sh` run, web build and node checks of the output, container build; Windows scripts and the web client in a browser not run |

Phases are collected on `big-cleanup`; each phase branches off it.

Notes from phase 2:

- **Schema:** the baseline needed a version-28 bridge rather than a plain
  `DROP COLUMN`, because SQLite can't drop a column that references another
  table. The bridge rebuilds `messages` (`UPGRADE_28` in `db_schema.odin`).
  It can go once the test server is at 29.
- **Line count:** net −153 lines, not −250, because the baseline keeps one
  comment per table.
- **For phase 6:** a `db_exec(db, sql)` already exists, so the variadic
  helper of E2 needs another name. `attach_test_sent` (E7) moves there too:
  it is restructuring, not dead code.
- **D1** found nine copies, not seven: `attach_command` and
  `invites_command` were the same proc.

Notes from phase 4:

- **Counts:**
  - There were 15 token buckets, not 13: the server's media budget and
    resend allowance are buckets too.
  - Net −104 lines, of which ~110 are new tests.
- **Address classing (A4):** these are not duplicates. `address_private`
  ("my network, where a proxy is") and `push_address_public` ("safe to
  connect to") answer different questions, so they stay apart. The
  `netaddr` package belongs to phase 10. The IPv4-mapped gap in
  `address_private` and `address_loopback` is fixed now.
- **Endpoint resolving (A4):** the client's copy is no copy, because its
  addresses always have a port. The gateway and stress copies are one now.
- **Status texts (C1):** a shared `notify_done` callback isn't worth it,
  since the callbacks differ in what they do on success. `status_text`
  gained a "what" argument instead, which also fixed account wording that
  showed up for invites.

Notes from phase 5:

- **Fixed-size bodies:** they keep their fixed offsets instead of moving
  to Writer/Reader. They are short and clear, and their decoders check the
  exact size; converting them would add lines. `codec.odin` now states
  the rule: fixed size → offsets, anything else → Writer/Reader.
- **One rule for single-id bodies:** it follows the documented protocol
  rule that a body may grow at its end. The message, blob and attachment
  ids used to refuse longer bodies, and now accept them. Zero stays valid
  for rooms and accounts (room 0 is no room, account 0 is the one asking),
  and message and blob ids still refuse it.
- **Line count:** net +66, of which ~55 are tests and the codec's own
  documentation.

Notes from phase 6:

- **Branch base:** phase 6 is stacked on `refactor-codec`, because
  `big-cleanup` didn't have phase 5 yet when it started.
- **E2:** the variadic helpers are `db_bind`, `db_query` and `db_write`.
  - 102 statement sites became one call, 43 of them a whole write.
  - The 27 binds left are conditional or in loops.
  - `db_bind_*`'s return codes are still not checked.
- **E6 skipped:** the permission guard is one case in a `switch`, mixed
  with request-specific checks whose order decides the answer. A
  `may_manage` would reorder answers or split the switches, to save two
  lines a site.
- **E5:** splitting `run_account_command` and `check_config` moves to
  phase 11, with the other big procs.
- **Line count:** net −295.

Notes from phase 7:

- **ui.odin:** 2593 lines → 800, plus `ui_frame`, `ui_window`,
  `ui_sessions` and `ui_widgets` (D5/D7).
- **Send hint (D2):** now the same everywhere: "Enter: Send/Reply/Save,
  Ctrl+Enter: New line".
- **Skipped, D2:** the channel and DM header status lines differ in
  substance, so they stay apart; only `NOTICE_SHOW` is shared.
- **Skipped, D4:** a setting_checkbox helper. The pairs often do more
  after saving.
- **Bug found by the GUI run:** a notice from one server category showed
  in another (Accounts after Channels). It was there before; fixed in
  68ae614.
- **Not changed:** at 420 px the Accounts form's error message sits beside
  the buttons and is cut off. That predates this phase.

## Decisions (2026-10-24)

1. **`misc/`:** move into `docs/design/` (H2, phase 10).
2. **`common/`:** split out the server-only services, to `src/lib/` (F,
   phase 10).
3. **Renames:** no branches are waiting to merge, so do them, early (phase
   3).
4. **Schema step 29:** add it to drop `messages.blob`. Only one test server
   is deployed (phase 2).
5. **Squash the migrations:** yes. The 28 steps plus step 29 become one
   baseline schema (version 29) in phase 2. The test server's database is
   reset (or upgraded once with the old binary first), and
   `test_schema_upgrade` starts from the baseline.

Notes from phase 8:

- **client:richtext** (markdown, mentions, their tests; runs in CI now). It
  owns `Role`; `conn.View_Role` is an alias. `custom_emoji_index` moved with it.
- **client:video**: `native.odin`, `web.odin` and `types.odin` (the types both
  backends defined, plus `Key`, `Share_Config`, `Camera_Device`, `STREAMS`).
  The `video_` prefix is dropped (`video.can_share()`). The Linux libraries
  `build.sh` makes are in `src/client/video/` now, so an existing checkout
  rebuilds the video library once (or copy the two `.a` files over).
- **client:imaging** (`image.odin` + tests), not `client:image`: that name
  clashes with `core:image`. `ui_window_icon` and `ui_wayland_decorations` stay
  in the UI, they are window code, not pictures.
- **client:headless**: `headless.run`, `commands.odin`.
- **C2:** avatars and server pictures have their own queue
  (`picture_upload.odin`, `View.uploading`). `Pending` lost ten fields and two
  states. `outbox_pop` / `outbox_fail` replace five copies.
- **C3:** one `send_chunks`. **C8:** 14 headless log blocks became `report_*`
  in `headless_log.odin`; the one-line ones stay. A full sink interface was not
  worth it.
- **C6:** messages.odin (outbox, message_actions, typing, messages_view),
  video.odin (presets, send, watch, adapt), channels.odin (presence, commands),
  roles.odin (conv_admin).
- **Skipped:** C7 (`command_destroy` only runs for commands still queued at
  shutdown, so a forgotten field leaks at exit at worst; per-command destroy
  procs would add lines), and moving `address` / `known_servers` (no
  package that fits, ~290 lines).

Notes from phase 9:

- **Client side:** `proto.Initiator_Link` (`initiator_link.odin`) holds the
  handshake and the pending/current/previous sessions, with `link_step`
  (start, rekey, resend, expire, stall), `link_cookie`, `link_resp`,
  `link_finish`, `link_open`, `link_promote`. The main, bulk and media links and
  the lite client use it; they keep their transport, hello kind, refusal and
  retry handling. A stalled handshake no longer restarts in the same step.
- **Server side:** `Session_Base` and `session_init` / `session_finish` /
  `session_receive` / `session_confirm` / `session_expired` / `session_release`
  (`server/session.odin`) under both `Client` and `Media_Session`.
- **Drift fixed:** the media port throttles re-Welcomes (it sent one per Finish)
  and follows a client's new address only while the connection is logged in.
  Dropping a media session also wipes its keys now.
- **Left alone:** `supersede` / `retire_superseded` (they differ: connection and
  link vs peer key) and the bulk binding.

Notes from phase 10:

- **`lib:` collection** (`src/lib`): `http`, `gateway`, `lite`. The flags are in
  `scripts/build/collections.sh`, which `build.sh`, `web/build.sh`, the Dockerfile
  and CI source; `build.bat` has its own line. `netaddr` (A4) was not needed:
  phase 4 put the shared address code in `common`.
- **Server packages** (imported by relative path, `import "gate"`): `gate`
  (handshake gate and address buckets; `Handshake_Gate` is `gate.Gate`), `curl`
  (the libcurl loader, `curl.Lib`), `mail` (`mail.Mailer`, `mail.parse`),
  `webpush` (`webpush.Pusher`, `webpush.encrypt`). Tests that need the server's
  harness (`gate_test`, `push_test`) stay in the server package. `media.odin`
  stays: it hangs on `Server` and `Peer` state.
- **Folders:** `scripts/build`, `scripts/package`, `docker`, `tools`,
  `docs/demo.png`; `misc/<topic>/README.md` is `docs/design/<topic>.md` (moved
  whole: cutting the old phase checklists down to decisions is editorial work I
  did not do), and `keytest.cpp` is in `tools/`. `docs/Building.md` is new.
- **G2:** one `scripts/build/fetch.sh <opus|sqlite|webp|ffmpeg>`, and
  `c_lib_stale` / `c_lib_build` in `build.sh` for the six small C libraries.
  Not done: `build.bat`'s `:fetch` subroutine and the Opus flags (no Windows to
  test on), the Dockerfile repeating build steps.
- **G3:** `web/util.js` has the heap-copy helper (`Module.yapWithBytes`,
  `yapWithString`), used in 5 places. Not done: the hidden file picker, the
  `toBlob` loop, IndexedDB opening, splitting `shell.c`, and the other items.
- **Docker:** the server stage makes an empty `src/client` because
  `collections.sh` names the `client:` collection.

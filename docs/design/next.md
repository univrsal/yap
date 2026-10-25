# Next: plan

The list of changes written after polish, attachments and markdown, for
the `extended` client and server (not master), in the order they're to
be done. Nothing here is built yet. Each item is its own commit or
series of commits; the item's section is the plan, and what turns out
differently is written under it when it's done ("*As built:*").

Sizes: S up to about 300 changed lines, M up to
1000, L up to 2500, XL more. "Client" means no protocol change;
"protocol" means new or changed requests or events; "schema" means a
database step.

| # | Change | Size | Where | Depends on | Status |
| --- | --- | --- | --- | --- | --- |
| 1 | The calls tests' 320-byte leak | XS | server tests | - | done (2026-10-05) |
| 2 | Away by itself from input anywhere on the computer | M | client | - | done (2026-10-05) |
| 3 | Deleting an account, its posts kept without its name | M | protocol, schema | - | done (2026-10-05) |
| 4 | The roles UI made over | M | client | - | done (2026-10-05) |
| 5 | Heavy traffic apart from light: voice unharmed by screen sharing | L | protocol, client, server | - | done (2026-10-05) |
| 6 | Email for the server: IMAP (and SMTP) | M | server | - | done (2026-10-06) |
| 7 | Registration, and invite codes | L | protocol, schema, client | 3 | done (2026-10-06) |
| 8 | Verifying an email by sending one to the server | M | protocol, schema, client | 6, 7 | done (2026-10-06) |
| 9 | Many servers: a server rail, joining from a dialog | XL | client | 7 | split into 9a–9c |
| 9a | Sessions as a list, the rail, switching | L | client | 7 | done (2026-10-06) |
| 9b | Joining from the + dialog, the joined list kept | M | client | 9a | done (2026-10-08) |
| 9c | Badges, notices and voice across servers; the icon's menu | M | client | 9b | built (2026-10-08), not yet tried in the UI |

Why this order:

- **1–4 first**: small, independent of everything else and of each
  other, and each shippable on its own. 1 is a one-liner; 2 finishes
  what polish 11 left for later; 3 is needed by 7 (unverified accounts
  that expire are deleted the same way); 4 is UI only.
- **5 next**: it's the one that fixes something people notice today,
  and it touches the transport underneath everything else, so it's
  better settled before 9 multiplies the connections.
- **6 → 7 → 8**: email is plumbing with nothing to show until 8 uses
  it; 7 doesn't need it (registration works without verification), so 7
  could go before 6 if wanted. 8 needs both.
- **9 last**: the biggest, client-only, and its "join a server" dialog
  ends in the login screen, which 7 gives a "register" path. Building 9
  before 7 works too, with the register button added later.

## 1. The calls tests' leak

`odin test src/server` reports, for `test_calls`:

	+++ leak  320B  [calls.odin:118:call_start()]

Line 118 is `s.calls.by_id[call.id] = call`: the leak is the map's
backing memory, not a `Call` (every call in the test ends and is freed
by `call_end`). The server itself frees it (`defer calls_destroy(&s)`
in `server.odin`), but the tests' teardown, `ts_close` in
`auth_test.odin`, never calls `calls_destroy`. So it's a leak of the
tests, not of the server.

Fix: `calls_destroy(s)` in `ts_close`, with the other `*_destroy`
calls. Then check every test for leaks once more: the whole of
`odin test src/server` should report none.

*As built:* as planned. With `calls_destroy(s)` in `ts_close`, all 73
server tests pass with `-vet -strict-style` and none reports a leak.

## 2. Away by itself, from anywhere

Polish 11 made "away" follow input in yap's own window only
(`ui_activity.odin`: no mouse, key, scroll or typing in the window for
10 minutes). Someone using another program for an hour shows as away;
someone who left with yap focused shows as away too, which is right,
but only by chance.

What changes:

- **Idle time from the system** where the platform has it, asked every
  15 seconds or so (not every frame: the client only draws when
  something changes, `fc5a835`, and asking mustn't make it draw):

  | Platform | Source |
  | --- | --- |
  | Windows | `GetLastInputInfo` |
  | macOS | `CGEventSourceSecondsSinceLastEventType` |
  | X11 | XScreenSaver extension (`XScreenSaverQueryInfo`), loaded with `dlopen` so it isn't a hard dependency |
  | Wayland | `ext-idle-notify-v1` (or the older KDE/`org_kde_kwin_idle`), on the `wl_display` glfw has; where the compositor has neither, the window's input as today |
  | Web | the Idle Detection API where the browser has it and the user allowed it; otherwise the page's input as today |

  Whichever is used, input in yap's window still counts (it's the
  fallback, and it's free).
- **Only while the choice is Online.** The server already ignores idle
  for any other choice (`activity_of`: Busy, Away and Invisible stay as
  chosen), so this is the client not asking at all, and not sending
  `Idle_Set`, unless the account's choice is Online. When the choice
  goes back to Online it starts again from "not idle".
- Nothing changes on the wire.

Steps: a `platform.idle_seconds() -> (seconds, ok)` per platform; the
UI's activity check uses it and the window's input, whichever says
less; the check runs on a timer rather than per frame.

Checked: each platform by hand (one person per platform, or a VM);
off-screen with `-define:YAP_IDLE_SECONDS=20` and `xdotool` moving the
pointer outside the window (X11).

*As built:* a package `client:idle` (`open`, `check`, `close`, and on the
web `can_ask`/`ask`), one file per platform: Windows and macOS in Odin,
Linux in a small C file (`yap_idle.c`, built by `build.sh` into
`libyap_idle.a`) that `dlopen`s libwayland-client or libXss, with the
protocol's two interfaces written out by hand (no wayland-scanner, no
headers). The UI's `activity_step` runs every turn of the loop, drawn or
not and with the window hidden in the tray too (before, the idle check
only ran when a frame was drawn); `activity_input` only notes the
window's input. Idle = no window input for `IDLE_AFTER` and the system
says idle (or can't say). The system is asked every
`min(15 s, IDLE_AFTER / 4)`.

Differences from the plan:

- Wayland asks for `get_idle_notification` (v1), which respects idle
  inhibitors: a video playing fullscreen elsewhere keeps us online.
  There's no KDE `org_kde_kwin_idle` fallback; Plasma has had
  ext-idle-notify since 5.27.
- Xwayland has no MIT-SCREEN-SAVER extension, so yap running under X11
  in a Wayland session goes by its window alone (GLFW picks Wayland
  there anyway).
- The BSDs go by the window alone: vendor:glfw has no `GetX11Display`
  there.
- Web: an "Away when not at this computer" button in the status window,
  shown while the browser's permission is still to be asked for
  ("prompt"); clicking it asks. Once granted (the browser remembers), the
  detector starts with every page load. Its threshold can't be under a
  minute.
- The server logs `<user> is idle` / `is back` at debug.

Checked off-screen with `-define:YAP_IDLE_SECONDS=20`: X11 (Xephyr inside
headless weston's Xwayland; source X11): idle 20 s after the start, back
within 5 s of `xdotool` moving the pointer outside yap's window; Busy:
no idle for 40 s without input; Online again: idle 20 s later, the dot
yellow. Wayland (headless sway, the window floating): idle after 20 s,
back 5 s after `swaymsg seat seat0 cursor set` outside the window. Web
(headless Chromium over CDP, the permission granted and
`Emulation.setIdleOverride`): the button shows while the permission is
"prompt" and goes once granted; idle 20 s after the last click, back
when the detector says active. Not checked: Windows and macOS (they
compile: `odin check -target:windows_amd64` / `darwin_arm64`).


## 3. Deleting an account

Today an account can only be disabled (`Account_Flags.Disabled`): it
can't log in, but keeps its name, picture and everything it wrote under
that name.

Deleting:

- **Who:** the account itself (from its settings, with its password
  typed again), or anyone with `Manage_Accounts` who is above it (the
  same "nobody manages what's above them" rule as roles). The owner
  can't be deleted. The CLI gets `yap-server account delete <name>`.
- **What stays:** the account's row, as a tombstone, so every message's
  author id still points somewhere: username freed (set to something
  that can't be typed, e.g. `\x00deleted-<id>`), display name "Deleted
  user", status, picture, roles, settings, buddies, devices, memberships
  and unread state gone. Messages, reactions and pins stay, shown under
  "Deleted user" with a plain grey disc. A new flag
  `Account_Flags.Deleted`; clients draw it differently and leave it out
  of members lists, mention completion and the buddy list.
- **DMs:** the conversation stays for the other side, read only, with
  the deleted side shown as "Deleted user" (see D3).
- **Their uploads:** their avatar blob is freed now; pictures and files
  in their messages stay with the messages (purging still applies).
- **Connections:** every one of its devices is dropped at once, with a
  refusal saying the account was deleted.
- **Wire:** `Account_Delete [id u32][password str8]` (password only when
  deleting oneself), and `Account_Changed` with the Deleted flag for
  everyone else.

Steps: schema step (flag column / reuse `flags`; nothing else changes
shape), server delete in one transaction, request and permission check,
client: settings button + confirmation, the account's manage menu,
drawing deleted authors.

Checked: server tests (delete self, delete other, can't delete above,
can't delete owner, messages kept with the author's id, username free
again for a new account, DM still readable by the other side).

*As built:* as planned, with these details and differences.

- **Protocol:** `Account_Delete` (0x0017) has `Account_Password_Set`'s
  body, `[account u32][password str8]`; `Account_Flag.Deleted`,
  `Logout_Reason.Deleted` (4), `proto.DELETED_NAME`. Owner: `Invalid`;
  without the permission or not above: `Denied`; wrong password:
  `Wrong_Password` (counted like a login's); gone already: `Not_Found`.
- **No schema step:** the flag goes in `accounts.flags`. The username
  becomes `deleted#<id>` (`#` is never in a username, so nobody can log
  in with it or type it), the password hash zeroes.
- **Server** (`account_delete.odin`): `account_erase_rows` does the
  database's part inside a savepoint (all or nothing): the account's
  row, devices, buddies (both ways), settings, waiting mentions,
  memberships (DMs too) and roles. `account_erase` then logs its
  connections out, removes it from everyone's buddy list (they're told)
  and from every conversation, and tells everyone. `account_live`
  (accounts.odin) is what may still be messaged, called, made a
  buddy, added to a channel, given roles, disabled or given a password;
  a mention of a deleted account doesn't pull it into a public channel.
  `dm_closed` refuses posts and forwards into a DM with one (`Denied`).
- **Picture:** not deleted at once: blobs are shared by content, so the
  same picture can be somebody else's. Retention's hourly collection
  removes it once nothing uses it.
- **CLI:** `yap-server account delete <name>` (not the owner);
  `account list` says "deleted". Headless client: `/deluser <name>`,
  `/deleteme <password>`.
- **Client:** "Delete this account" in the account's settings (not for
  the owner), with the password and a line saying what goes; a wrong
  password is said under it. In the accounts list each account gets
  "Delete...", which asks once more. Deleted accounts: a plain grey disc
  without a letter or a dot; left out of the accounts list, mention
  completion, the add-people list and forwarding; their menu says only
  that the account was deleted. A DM with one shows the history and,
  instead of the box to write in, "Their account was deleted: this
  conversation can be read, but not written to."; no call button. The
  login screen says "The account was deleted."

Checked: server test `test_account_delete` (who may, the password, the
owner, logged out with the reason, the device no longer known, what's
left, bob told and his buddy gone, messages kept with the author's id
in the channel and the DM, DM read only and not opened again, the name
free for a new account, someone else's by the owner, and all of it as
the database has it on loading again). Off-screen: bob deleted himself
headless (wrong password first); alice's GUI shows his messages under
"Deleted user" with the grey disc, and their DM read only; the owner
deleted carol from the accounts list; alice deleted her own account
(wrong password said, then deleted, and the login screen says so); the
CLI refuses the owner and deletes another.


## 4. The roles UI

Today (`ui_manage.odin`, `roles_settings`): the roles are a treenode in
the server settings tab, each role a row of permission checkboxes; an
account's roles are edited from its manage menu
(`account_roles_editor`).

The request says "refactor role UI" and no more, so what's wrong with
it is D4. A proposal to answer against:

- A **Roles window** (like the Channels window), opened from the server
  settings tab: the roles listed on the left in order, the selected one
  on the right.
- On the right: name, colour (if wanted, see D4), its permissions as a
  list of checkboxes with a line saying what each does, and **its
  members**, with "add people" (the same picker the members window
  uses) and a remove button each.
- Ordering by dragging, or up/down buttons, if the order matters for
  "above"; it does today, by position.
- Permissions we lack stay unchecked and greyed, with a hint saying why.

Steps decided once D4 is answered.

*As built:* a Roles window (`ui_roles.odin`), opened by "Roles..." in
the server's tab of the settings, where the treenode was. No protocol
change: it uses Role_Set, Role_Delete and Account_Roles_Set as before.

- Left: the roles, "(above you)" after one that allows more than we
  may; under them a box and "Make role".
- Right, for the role picked: its name (a box, unless it's everyone's
  or above us), what it allows as checkboxes, a permission we lack
  greyed with "(you don't have it yourself)"; Save (reads "Saved" while
  nothing has changed) and "Delete role...", which asks once more. A
  role above us says so in yellow and is all greyed.
- "Who has it": each account with the role, with "Take it"; "Give it
  to..." opens the accounts without it (not the owner, not deleted
  ones) with "Give". Giving or taking keeps the account's other roles.
  What the server refuses is said under the buttons.
- "Above" goes by what a role allows (a role whose permissions are all
  ours is below us), never by its place in the list. The accounts list
  keeps its per-account "Roles..." too.

Checked off-screen as alice, who has Manage_Roles through "managers",
with bob in "bosses" (Manage_Roles and Purge): bosses shows as above
her and read only; she ticked "Attach files" on managers and saved;
gave managers to bob (his bosses kept: the server logged 2 roles); made
"helpers" from the box and deleted it.

*Added after (the owner asked, 2026-10-05):* role colours, an order, and
a card in the user menu.

- **Protocol:** the role record grows `[color u32][position u16]`
  (colour `0xRRGGBB | ROLE_COLOR_SET`, 0 for none); a record without
  them (an older client's Role_Set) decodes as no colour. New request
  `Role_Order [count u8][role u32]...` (0x0074): every role but
  everyone's, top first, for whoever has Manage_Roles; the roles that
  moved are told with Role_Changed. Schema step 17 adds `roles.color`
  (`position` was there since step 10). Everyone's role takes no colour
  and is always listed last; a new role goes to the bottom.
- **Colour of a name:** the highest of the account's roles that has a
  colour (`name_color`, ui_roles.odin). The order is only for that.
  Shown in message headers (the timeline, pins, search; the whole header
  line, the time too), the members list (fainter when they aren't
  here), the Roles window's list and the user menu. Headless `/setrole`
  keeps a role's colour.
- **Roles window:** a row of twelve colours and None (the chosen one
  outlined, saved with Save), and "Move up" / "Move down", which apply
  at once.
- **User menu:** a card on top: the picture (44 px), the name in its
  colour, `@username, online|away|busy|offline`, the status, and the
  account's roles as chips (colour dot and name, in order, wrapped).
  The rest of the menu is as it was, minus the old username line.

Checked: proto test (colour and position, an older body, a colour
without its bit, the order request); server test `test_role_colors`
(colour told and kept, everyone's refused one, order permission and
validation, only moved roles told, positions and colour as the
database has them). Off-screen as the owner on the earlier test server
(migrated to step 17): bosses red, managers blue; with managers first
both alice and bob were blue, bob's card showed both chips; after
moving bosses up bob turned red in the chat and the members list.


## 5. Heavy traffic apart from light

Voice gets worse while somebody shares their screen. Everything goes
through one Noise session over one transport per client: voice, chat,
the reliable stream (requests, events, blobs, attachments, file
transfers) and video. What's known from the code:

- **The sharer's side** paces video already (`conn/video.odin`:
  `VIDEO_SEND_RATE` 3 Mbit/s, sent only while less than
  `VIDEO_BACKLOG_MAX` is waiting on the socket, after voice in
  `client_step`). Screen sharing is web only, and on the web the
  "socket" is a WebSocket, i.e. TCP: a voice packet sent after 16 KiB of
  video still waits behind it. TCP also retransmits and holds back
  everything after a lost segment.
- **The way out to viewers** has no priority at all: the relay
  (`relay.odin`, `server_to_browser`) writes everything from the server
  into the browser's one WebSocket in order, so a viewer's voice waits
  behind up to `VIDEO_MAX_RATE` (4 Mbit/s) of video per sharer.
- **The web client has one thread.** The network loop, the UI and the
  capture all run on the page's thread; when a turn is late the
  capture backlog over `MAX_CAPTURE_BACKLOG` (5 frames) is thrown away
  (`audio/voice.odin`), which is heard as dropouts.
- Native clients don't share or watch, but do download attachments and
  files over the same UDP socket, through the same reliable stream.

So the first step is finding which of these it is, before building the
split:

1. **Measure.** Two or three headless Chromium clients (CDP, as in the
   off-screen testing notes) and one native, one sharing; log per voice
   packet the time from capture to send, and on the receiving side the
   jitter and the packets the jitter buffer gave up on, with and
   without sharing. Separately: the sharer's own voice as heard by a
   native client, and a viewer's voice as heard by a native client.
   Write the numbers here.
2. **The split** (the request), most likely needed whatever 1 finds:
   - Each client gets a **second link** for bulk: on the web a second
     WebSocket, natively a second UDP socket. It does its own Noise
     handshake with the same device key, with a hello saying "bulk link
     for connection N" (and the session's id to prove it's the same
     client), so the server binds it to the existing `Conn`.
   - **Light** (stays on the main link): voice, pings, keepalives,
     requests and events of the reliable stream that aren't blob data,
     typing, watch leases, keyframe requests.
   - **Heavy** (bulk link): video fragments both ways, blob and
     attachment chunks, file transfer data, image downloads.
   - Note: We expect the bulk link to be there and work. There's no
     need for backwards compatibility.
   - The relay needs nothing new: it already relays any number of
     WebSockets, one UDP socket each.
   - The server's own sending already takes turns; with the split, it
     drains each connection's main link before its bulk link.
3. **If 1 shows the web's single thread is the cause** (or part of
   it), the capture and encode move off the page's thread: an
   AudioWorklet already captures; the Opus encode and the network loop
   move into a Worker. That's its own item, decided after 1 (D5).

Checked: the measurements of 1 again after 2, written here; voice with
a screen share going on must look like voice without one.

*As built:*

**Measuring (1).** Headless Chromium for the three web clients (sharer,
viewer, talker), each with a looped speech file as its microphone
(`--use-file-for-fake-audio-capture`; a pure tone is taken for noise by
RNNoise and held by the gate), and one native headless client
(`-tone`). The sharer's `getDisplayMedia` was swapped for a canvas of
moving noise at 1280x720, 15 fps, which the encoder can't compress
below its cap: ~375 kB/s (3 Mbit/s) went out, the most `VIDEO_SEND_RATE`
lets through. On localhost nothing showed (no link to fill), so the
runs were in network namespaces with netem (no root needed:
`unshare -r -n`): the server, relay, native client and talker in one,
the sharer and the viewer each behind a veth link of 15 ms each way and
0.5% loss, the sharer's uplink at 4 Mbit/s, the viewer's downlink at
4 Mbit/s. 40 s without sharing, then 60 s with the viewer watching.
The client logs per second (debug), per speaker, the latest a packet
came behind the line of the earliest ("late up to", `late_peak`), and
how much capture was thrown away for backlog (`skipped`); also the
ping's worst round trip and video kB in and out.

How late voice came, in ms (median / p95 / max), while sharing; without
sharing the p95 was 55-110 everywhere (the web clients' own 40 ms
device period makes most of it), max under 120 (`MAX_PREFILL`):

| Who hears whom | before | after the split |
| --- | --- | --- |
| viewer hears native | 60 / 172 / 362 | 60 / 100 / 128 |
| viewer hears sharer | 102 / 283 / 409 | 94 / 137 / 154 |
| viewer hears talker | 88 / 178 / 387 | 85 / 112 / 136 |
| native hears sharer | 79 / 183 / 282 | 68 / 106 / 136 |
| talker hears sharer | 75 / 193 / 284 | 73 / 110 / 126 |
| viewer's ping, worst | 384 | 105 |
| sharer's ping, worst | 252 | 99 |
| viewer's dropouts / min | 18 | 14, 7 (two runs) |

What it was: queueing behind video, on both TCP paths: in the
WebSocket's send buffer and TCP's retransmissions on the sharer's
uplink, and in the relay's one WebSocket to the viewer. **Not the web
client's single thread:** no capture was ever skipped, on any client,
sharing or not, so D5's Worker isn't needed for this. What's left
while sharing is the viewer's own 4 Mbit/s link, three quarters full of
video: both WebSockets go through the same queue in the router (netem
here), and nothing on our side reorders that.

**The split (2)** is as planned:

- `proto.Link` (Main, Bulk) in the hello, which is version 12:
  `[version][conn_id][link][password_len][password]`. A bulk hello
  binds to the device's connection with the same conn_id; with none
  (gone, or the main link not welcomed yet) it's refused with the new
  `Refusal.No_Connection`, and the client tries again a second later.
  The bulk link is welcomed like the main one, with the connection's
  instance, which the client checks.
- `proto.HEAVY_KINDS`: Video, Blob_Chunk, Upload_Chunk,
  Download_Chunk, File_Chunk. Acks, needs and cancels stay light.
- Server: `Client.bulk`; only main-link sessions count in
  `Conn.sessions` and keep a connection; superseding and retiring are
  per link; the last main session going drops the bulk ones
  (`drop_session`, which now leaves an already-dropped index be). The
  routing is in one place, `send_message`: a heavy message goes on the
  connection's newest bulk session (`bulk_session`) if it has one,
  else as before. Voice and video relaying skip bulk sessions as
  recipients. `DEFAULT_MAX_SESSIONS` went from 256 to 512 (two per
  client). "Drains the main link before the bulk link" turned out to
  be nothing to do: the server sends each packet as it's made, with no
  queue of its own, and the two links are separate sockets from there
  on (separate relay sockets and WebSockets for the web).
- Client: the main link's state moved into `Link` (`using link` in
  `Voice_Client`, so `c.current` etc. read as before); `bulk.odin` has
  `Bulk_Link`, opened once the main link is welcomed, with its own
  handshake, rekey and silence timeout, and `bulk_restart` on a Welcome
  for a new connection. It pings the server once a second, on its own
  timer: a sharer sends video all the time and gets nothing back, so a
  ping only when idle never went, and the link was taken for dead
  every 8 s (found by the measurement). `send_data` picks the link by
  kind; until the bulk link is up heavy messages go on the main link.
  Native: a second UDP socket, non-blocking; each turn takes one packet
  off the main link (waiting up to 2 ms as before) and then up to 16
  off the bulk link. Web: the `yap_ws_*` calls take a slot (0 main, 1
  bulk), each WebSocket with its own queue, which is now read from a
  head index instead of `shift()`. Video's backlog check looks at the
  bulk link's socket.
- Tests: `test_bulk_link` (server) does real handshakes over loopback
  UDP: refused before the main link and for another conn_id, welcomed
  with the same instance, heavy and light messages on their links,
  pings answered on the bulk link, the bulk link going alone and with
  its connection. The hello test covers the link byte.
- The measuring scripts (lab, CDP driving, analysis) were in the job's
  scratch directory, not kept; this section is what to rebuild them
  from.

## 6. Email for the server

The server gets an email account of its own, for 8, and later for
whatever else wants mail (D6).

- **Config:**

		"email": {
			"address": "yap@example.org",
			"imap": "imaps://mail.example.org:993",
			"smtp": "smtps://mail.example.org:465",
			"username": "yap@example.org",
			"password": "",
			"poll_seconds": 60,
			"trusted_auth_host": "mail.example.org"
		}

  Missing or empty: no email, and everything that needs it is off.
- **How:** libcurl (`vendor:curl`, in Odin's vendor directory), which
  does IMAP and SMTP over TLS. yap has no TLS of its own and shouldn't
  grow one for this. The server links libcurl dynamically; the Docker
  image installs it; the CI builds get it. On a server without libcurl
  the email feature is unavailable rather than the server failing to
  start (D6: or a build flag). When adding this we have to decide how
  to handle libcurl on windows. The windows build of odin ships .lib and
  .dll files for all vendor libraries, so the build step should copy the
  .dlls that libcurl uses into the same folder as the server executable.
- **IMAP:** on its own thread, every `poll_seconds`: `UID SEARCH
  UNSEEN`, fetch each one's headers (From, Subject, Date,
  Authentication-Results), hand them to the main loop through a queue
  (like the password hasher's), mark them seen, move or delete them
  once handled. Never blocks the main loop.
- **SMTP:** a `mail_send(to, subject, body)` on the same thread, used
  by nothing yet unless D6 says otherwise.
- **Accounts can have an email:** a column `email` (lower-cased,
  unique among non-deleted accounts), set at registration (7), shown
  and changeable in the account's settings (changing it unverifies it
  if verification is on, 8).
- A CLI check: `yap-server email test` logs in to both and says what
  worked.
- A compile time toggle to turn off email support would be useful to
  make the dependency on libcurl optional.

*As built:*

- **libcurl, by platform** (`curl.odin`): the ten procedures email uses
  are a table. On Linux and macOS it's filled at runtime with
  `core:dynlib` from the system's libcurl (`curl_system.odin`:
  libcurl.so.4, libcurl.4.dylib, ...), only when email is configured;
  without one the server logs that email is off and runs on. **On
  Windows there are no DLLs to copy:** Odin's vendor directory has only
  `vendor/curl/lib/libcurl.lib`, a static library (Schannel, `/MT`, like
  everything else build.bat builds), so it's linked in
  (`curl_windows.odin`) and email is always there; build.bat needs
  nothing new. Not tried on Windows: `odin check -target:windows_amd64`
  passes. `-define:YAP_EMAIL=false` builds a server without email
  (curl_load says so; on Windows the static lib is still linked, unused).
  The Docker image's runtime stage installs libcurl4t64 and
  ca-certificates (not built here). CI needs nothing: nothing links
  libcurl.
- **Config** as planned, plus: `username` defaults to the address; no
  `smtp` means nothing is sent; `poll_seconds` at least 10. URLs:
  imaps/smtps for TLS from the start, imap/smtp for STARTTLS, which is
  required (CURLUSESSL_ALL) unless the host is this machine.
- **The thread** (`email.odin`): one thread, two queues (mails in for
  the loop, jobs out: send or delete), woken by jobs or the poll timer.
  It keeps one IMAP handle, so libcurl keeps the connection between
  polls (search and every fetch on one login). Polling is `UID SEARCH
  UNSEEN`, then each mail's `BODY[HEADER]` (which marks it seen), at
  most 50 a poll, and none while 256 wait for the loop. Deleting is `UID
  STORE +FLAGS.SILENT (\Deleted)` and `EXPUNGE`. Failures are logged
  once when they start and once when it works again.
- **What the loop gets** (`Mail`): the UID, the From address (lower
  case, from the angle brackets), the subject with RFC 2047 encoded
  words decoded (B and Q, as UTF-8), the Date as written, and every
  Authentication-Results header unfolded. Nothing reads them yet:
  `email_sync` logs each at debug and leaves it in the mailbox, seen,
  until item 8 decides what to delete.
- **Sending**: `email_send(to, subject, body)` composes a plain text
  UTF-8 mail (Date, From, To, Subject encoded if not ASCII, Message-ID,
  CRLF) and refuses an address `email_clean` doesn't take or a subject
  with a line break (no header injection). libcurl does the dot
  stuffing.
- **`yap-server email test [address] [config]`**: searches the INBOX
  (marks nothing seen) and logs in to SMTP with a NOOP, or mails the
  address a test. Works while the server runs.
- **Accounts' email**: schema step 18, `accounts.email` ('' for none)
  with a unique index on non-empty ones; a deleted account's is
  cleared (Account_Erase), so a tombstone holds none. `Email_Set`
  (0x0018) sets one's own (`proto.email_clean`: trimmed, lower case,
  one @, a dot in the domain, nothing that needs quoting; Conflict if
  another account has it, Invalid if it isn't one); it's told to the
  account's own connections only, as a new last field of `Self`. The
  account settings have an Email row under Name, with the server's
  answer shown under them; the headless client has `/email [address]`.
- Tests: mail parsing, encoded words, SEARCH responses, composing and
  the Date header, `email_clean`, and `Email_Set` (set, told only to
  itself, conflict, invalid, kept, cleared on deletion). The IMAP and
  SMTP exchanges were tried against a small fake mail server (Python,
  in the job's scratch directory): login, search, fetch on one
  connection, delete, sending with an encoded subject, and the CLI.
  Not tried against a real mail server.

## 7. Registration, and invite codes

D5 of the extended plan (`docs/extended`, now only in git history) made
accounts admin-only. This makes registration an option of the server:

- **Config:**

		"registration": {
			"open": false,
			"require_email": false,
			"verify_email": false,
			"unverified_hours": 48,
			"require_invite": false
		}

  `require_email` and `verify_email` need email configured (6); the
  server refuses to start with them on and no email, saying why.
- **What the client learns:** the server's hello for login
  (`Login_Needed` or alongside it) says whether registration is open,
  whether an email is asked for, whether an invite code is, so the
  login screen shows only what applies.
- **Registering:** `Register [username str8][password str8][device
  str8][email str8][invite str8]`, answered like a login: the device is
  registered to the new account and logged in. Same name rules,
  password hashing and rate limits as logins; the username must be
  free (deleted accounts' are, 3).
- **The login screen** gets "Register" beside "Log in" when the server
  allows it, showing username, password, password again, and email /
  invite code when asked for. The line "Accounts are made by the
  server's admin" only shows when registration is closed.
- **Invite codes:**
  - A permission `Create_Invites` (D7: or reuse `Invite`, which today
    means adding people to a channel).
  - Created from the server settings tab: how many registrations it's
    good for (1, 5, 10, any), optionally until when. The code is random
    (e.g. 10 characters from an unambiguous alphabet), shown once with
    a copy button; listed afterwards with uses left, revocable by its
    creator or by `Manage_Accounts`.
  - Tables:

			invites (code TEXT PRIMARY KEY, creator INTEGER, created INTEGER,
			         max_uses INTEGER, uses INTEGER, expires INTEGER, revoked INTEGER)
			invite_uses (code TEXT, account INTEGER, used INTEGER)

    so who made an invite and who registered with it are both kept.
    Members window / account menu shows "invited by X" to those with
    `Manage_Accounts`.
- With `require_invite` off, codes still work (and are recorded) if
  given.

Steps: schema step; config; `Register` + checks; invites requests
(`Invite_Create`, `Invite_List`, `Invite_Revoke`); login screen; invites
UI. Server tests for each refusal (closed, name taken, bad/used-up/expired
code, missing email).

*As built:*

- **Config** as planned (`registration`, defaults all off, 48 h). The
  server refuses to start with `require_email` or `verify_email` and no
  email address configured; it warns when requirements are set but
  `open` isn't. `open` false means no registering at all, invite or not;
  an invite-only server is `open` + `require_invite`. `verify_email`
  only asks for an address for now (item 8 does the rest), and
  `unverified_hours` is read but unused.
- **What the client learns**: `Server_Info` got a last byte,
  `proto.Registration_Flags` (Open, Email, Invite), which the client
  asks before logging in anyway; nothing in Login_Needed.
- **`Register`** (0x0019, `proto/register.odin`, `server/register.odin`):
  allowed before login like Auth_Login, answered like it (the device is
  linked and logged in). A refusal carries a reason byte,
  `Register_Refusal` (Closed, Username, Username_Taken, Password,
  Email_Missing, Email, Email_Taken, Invite_Missing, Invite), with
  Denied / Invalid / Conflict as the status, so the client says exactly
  what's wrong. Everything is checked again after the hashing (the
  name, address or the invite's last use may have gone meanwhile). New
  accounts get the username as display name, no Must_Change, the home
  channel, and their email. Besides the hashing limits, registrations
  are limited server-wide: 10 at once, then one every 10 s.
- **Invites** (`server/invites.odin`): `Create_Invites` is permission 10
  (D7), given to nobody by default (owners have everything); it's in
  the Roles window. Codes are 10 characters of
  `ABCDEFGHJKMNPQRSTUVWXYZ23456789`, read in any case. Uses 0..1000
  (0 = any), optional expiry; at most 50 usable codes per account. The
  tables are as planned (schema step 19; `invites` keeps its rowid so
  lists are newest first even within a millisecond). Requests:
  `Invite_Create`, `Invite_List` (own; all with Manage_Accounts; newest
  500), `Invite_Revoke` (creator or Manage_Accounts), and `Invite_Of`
  (which code an account registered with, and whose, Manage_Accounts).
  A deleted account's codes are revoked (Invite_Erase).
- **Login screen**: "Register an account instead" / "Log in to an
  account instead" under the button when the server is open; register
  mode adds Password again, and Email / Invite code only when the
  server asks for them (a code given otherwise isn't asked for in the
  UI, though the server takes it). What can be checked locally is
  (username rules, password length and match, address, code alphabet)
  before asking. The admin line shows only when registration is
  closed.
- **Invites UI**: "Invite codes" in the server settings tab, for
  Create_Invites or Manage_Accounts: registrations 1 / 5 / 10 / Any,
  good for No end / A day / A week / A month (presets rather than a date
  field), Make invite code; the new code is shown with Copy and Done;
  then the list: code, uses, state (until a date, no end, used up,
  expired, revoked), by whom (if not us), Copy and Revoke while usable.
  The account menu's card shows "Invited by X (CODE)" to
  Manage_Accounts, asked when the card is first shown.
- Headless client: `/register <user> <password> [email] [invite]`,
  `/invite [uses] [days]`, `/invites`, `/uninvite <code>`; it logs
  whether a server takes registrations.
- Tests: proto codecs (register, refusal, invite list, code cleaning,
  usability, Server_Info's flags); server: every refusal (closed, bad
  name, short password, name taken in any case, bad address, address
  taken, missing address with require_email and verify_email, missing
  and bad code), a registration that logs in and can log in again, the
  rate limit, and invites (permission, limits, any-case codes, used up,
  expired, revoked, any number of uses, listing, Invite_Of, a deleted
  creator's codes revoked). Tried in browsers: registering with a bad,
  an unknown and a good (lower case) code, making and revoking codes,
  and the "Invited by" line.

## 8. Verifying an email by sending one

The inverse of the usual: the new user sends a mail **to** the server,
instead of the server sending one to them. Receiving is easy and safe
for the server; sending gets mail servers flagged, and many throwaway
mail services can't send at all.

- With `verify_email` on, a registered account starts **unverified**:
  it can log in, and the client shows only a page saying what to do
  (D8: or a limited client), nothing else.
- That page says: send an email from `<their address>` to `<server's
  address>`, with the subject `<code>`, where the code is shown with a
  copy button and a `mailto:` link that fills all three in.
- The IMAP poller (6) hands each new mail to the main loop; a mail
  verifies an account when:
  - its From is an unverified account's email, and
  - the subject contains that account's code (D8: whether to ask for
    it; without it, anyone who registers with someone else's address
    is verified the next time that person mails the server for any
    reason), and
  - the receiving server's `Authentication-Results` header (from
    `trusted_auth_host`, not any earlier one, which the sender could
    write) says DKIM or SPF passed for the From's domain. Without this
    check, anyone can write any From.
- Verified: the flag goes, the account is told (`Account_Changed`) and
  the client goes on to the usual UI.
- Unverified accounts older than `unverified_hours` are deleted by the
  retention loop, in its paced chunks; they have no messages, so it's
  a plain delete (or 3's, which then has nothing to anonymize).
- A mail that verifies nothing is moved to a folder (or deleted, D8) and
  logged at debug.

Checked: server tests feeding the poller's queue directly (the right
mail, wrong From, wrong code, no or failed Authentication-Results,
expiry); by hand once against a real mailbox.

*As built:*

- **Unverified** is account flag 16 (`proto.Account_Flag.Unverified`),
  with schema step 20's `verify_code` (8 characters of the invite
  alphabet) and `verify_expires` (ms, 0 for never). `server/verify.odin`
  has the rest; `proto/verify.odin` says what clients see.
- **Who is unverified**: a registration on a server with `verify_email`
  (and email working), until `unverified_hours`; and, as planned, an
  account that changes its address there (Email_Set gives it a new
  code), but with no deadline, so an existing account is never deleted
  for it, and never the owner's (the owner can't be locked out).
  Removing one's address is refused while the server asks for one.
  `yap-server account verify <user>` lets an account in by hand.
- **Unverified, server side** (D8: nothing but the waiting page): it
  logs in (by password or by its known device) but `conn_login` keeps
  its connection in `Server.waiting`, out of `conns`, so nobody sees
  it and it's in no presence, channel, call or broadcast; its sync is
  only Sync_Begin, Self, Sync_End. Requests other than Server_Info,
  Email_Set, Auth_Logout and Account_Delete are Denied; datagrams are
  limited as for a connection that isn't logged in. Others aren't told
  about a new account until it's verified. On verifying, `conn_seen`
  does the rest of a login (everything a login is told, and everyone
  sees it); on becoming unverified, `conn_unseen` takes it out of sight
  as if it had left.
- **What the client is told**: Self gained `[verify code str8][verify
  by u64]` after the email; Server_Info gained the server's address
  (only when verifying, which is when it's needed).
- **The check** (`verify_sync`, in place of item 6's `email_sync`):
  From is an Unverified account's address, the subject contains its
  code in any case (D8), and the **topmost** Authentication-Results
  header has `trusted_auth_host` as its authserv-id and says
  `dmarc=pass header.from=`, `dkim=pass header.d=` (or `header.i=`) or
  `spf=pass smtp.mailfrom=` for the From's domain or a parent of it
  (relaxed alignment). Comments are stripped first, so a "(dkim=pass)"
  comment proves nothing; lower headers and other hosts' are ignored.
  `verify_email` now needs `trusted_auth_host` set, or the server won't
  start. Afterwards (2026-10-06): the check is the email config's
  `check_auth_results`, true by default; false skips it (From and code
  still have to match) and the server warns that anyone can then verify
  an address that isn't theirs. It's for mail hosts that write no
  Authentication-Results: the user's mxrouting (Exim/DirectAdmin) writes
  `X-DKIM`, `DKIMCheck` and `X-DMARC-Status` instead, which say nothing of
  who wrote them and aren't added for mail its own users send, so they
  weren't trusted in its place. Options left for later: yap checking the
  DKIM signature itself (DNS TXT, RSA/Ed25519, canonicalization), which
  needs no header from the receiving server. When the check fails, the
  log shows the topmost Authentication-Results it found, or that there
  was none (the mail is deleted after).
- **Every mail read is deleted** once looked at, verifying or not (D8),
  logged at debug, or at info when only the Authentication-Results
  failed (the likeliest thing to need looking into). Without
  `verify_email`, mail is left alone as in item 6.
- **Expiry**: once a minute, up to 10 unverified registrations past
  their deadline are deleted with `account_erase` (item 3's, which has
  nothing to anonymize then).
- **Client**: the waiting page (`verify_screen`, after the must-change
  password screen in the same switch): From, To with Copy, Subject (the
  code) with Copy, "Write it in my mail program" (`platform.open_mailto`,
  which takes only address and code characters into the link), the
  deadline, "Not your address?" to change it, and Log out. It goes on by
  itself when the Self without the flag and the full sync come. The
  account settings' Email row says a new address needs verifying, where
  it does. Headless, the client logs what to mail where.
- Tests: Authentication-Results cases (each method, alignment, wrong
  host, forged lower header, comments, failures), code matching, and
  the flow on the test server with mail put in the queue: registering
  unverified (out of sight, Self with code and deadline, requests
  denied), five mails that don't verify (wrong From, no code, no
  header, DKIM fail, untrusted host), the right one in lower case, all
  deleted; changing the address (unverified, no deadline), the owner
  exempt, removing refused; expiry; mail left alone without
  verify_email. Tried in a browser against the fake mail server: the
  page, a forged mail refused, the real one verifying, the page going
  on. Not tried against a real mailbox.

## 9. Many servers

Today the client is connected to at most one server: `UI.session` is
one `Net_Session`, `UI.view` one `conn.View`, and the start is a
connect form with the recent servers (`settings.recent_servers`).

What it becomes, like Discord:

- **The main chat UI is the start screen.** On the far left, a narrow
  **server rail**: one round icon per server this client has joined
  (the server's picture if it has one, else its initials), the
  selected one marked, unread and mention badges on the others. A
  **+** at the end.
- **+** opens a dialog: address, server password (if it has one).
  "Connect":
  - the server knows this device's key: logged in, the server is added
    to the rail and selected;
  - it doesn't: the dialog becomes the login screen, with Register
    when the server allows it (7);
  - a new or changed server key: the trust prompt that exists today,
    inside the dialog.
- **With nothing joined yet** the chat area says so and points at +.
- A server's icon has a menu: leave (forget it here, and its key if
  wanted), log out of it, its settings.
- The joined servers are kept in the settings in place of
  `recent_servers` (which are turned into joined ones once), in rail
  order, reorderable by dragging.
- **Voice is in one server at a time.** Joining voice elsewhere leaves
  the current one; the voice panel says which server the voice is in
  and stays visible whichever server is shown.

The big decision is D1: whether every joined server is connected at
once (each its own `Net_Session` and `View`, unread and mentions live
on the rail, voice stays up while looking at another server), or only
the one shown (switching reconnects; quick, since the device is known,
but the rail can't show what's new elsewhere without a lighter check).

If all at once:

- `UI.view` becomes a pointer to the shown session's `View` (about 124
  uses of `ui.view` in the client, mechanical), `UI.session` the shown
  one, plus a list of all.
- Per-server UI state (open threads, scroll positions, timeline height
  cache, composer drafts, image caches) keyed by server.
- Sounds and desktop notices from the servers not shown still play
  (mentions, DMs, calls), with the server's name in the notice.
- A background server's network loop runs as today (each is its own
  thread natively; on the web they take turns in the one loop).

Steps (if all at once): (a) sessions as a list, the shown one a pointer,
nothing else visible; (b) the rail and switching; (c) the + dialog and
login/register inside it; (d) badges, notices from other servers; (e)
the joined list in the settings, its menu, reordering.

**Split (2026-10-06)**, after looking at what it touches: `ui.view` is
used 142 times and `ui.session` 140, in 31 files each, and most of the
UI's own state is the shown server's (channels, timeline, threads,
chat images and their textures, search, calls, pins, the login and
account forms...). Step (a) can't be seen working without (b), so they
go together; (c)-(e) regroup by what they're about:

- **9a. Sessions as a list, the rail, switching** (L). `UI.sessions`
  holds every connection, `UI.session` the shown one, `UI.view` a
  pointer to its View (each session owns one). The UI's per-server
  state moves into a `Server_UI` struct, embedded with `using` so it
  reads as before, and is swapped with the shown session's stash on
  switching (scroll positions, drafts, open threads come back as they
  were). Each session keeps its own playback stream (the OS mixes
  them, which is how sounds from servers not shown still play); the
  microphone only ever for the one in voice. On the web each session
  gets its own pair of WebSocket slots, and the frame's network turns
  go round all of them. What has to reach every session does: idle,
  mute and deafen. Voice is in one server at a time: joining it in one
  leaves it in the others. The rail: a narrow column at the far left,
  a round icon per session with its initials, the shown one marked,
  connecting/failed shown on the icon; clicking switches. **+** for now
  shows today's connect screen, which connects another server instead
  of replacing the one there is.
- **9b. Joining from the + dialog, the joined list kept** (M). The +
  dialog (address, password; then the trust prompt or the login /
  register screen inside it); the main UI as the start screen, saying
  what to do with nothing joined; `settings.joined_servers` in rail
  order in place of `recent_servers` (turned into joined ones once),
  all connected at start.
- **9c. Badges, notices and voice across servers; the icon's menu**
  (M). Unread and mention badges on the rail; sounds and desktop
  notices from servers not shown, with the server's name; the window
  title's count over all servers; the voice panel showing the voice's
  server whichever is shown; the icon's menu (leave, forgetting the key
  if wanted; log out; its settings); reordering by dragging.

Not in any of them: a server's own picture for its icon (servers have
none to give yet; initials until a later item adds one to Server_Info).

*9a as built:*

- `UI.sessions` (rail order), `UI.session` the shown one, `UI.view` a
  pointer to its `Net_Session.view` (each session owns its View; with
  none, `UI.no_view`, which says nothing is connected). `&ui.view` went
  to `ui.view` in 86 places; nothing else had to change for it.
- `Server_UI` (`ui_servers.odin`) holds the 30-odd fields that are a
  server's: the login/account forms, invites, channels, timeline,
  unread, chat (drafts), reactors, forward, search, the user menu,
  buddies, threads, profiles, manage, roles, calls, voice panel,
  completion, picker, pins, the message menu, gains, previews asked.
  `UI` embeds it with `using srv`, so the code reads as before; each
  hidden session keeps its own in `Net_Session.stash`, swapped on
  `show_session`. Freeing a stash swaps it in and runs the same
  destroys (`server_ui_destroy`). What isn't a server's stays on UI;
  the chat pictures' decoder can't move (its thread holds its address),
  so `ui_images_switch` drops its textures on switching, with a
  generation number so a decode finished for the old server is thrown
  away; pictures are decoded again from the session's own data.
- Sessions: `connect` appends and shows a new one, or replaces one for
  the same server in place (a failed one, or after trusting a new key),
  keeping what the UI had of it. `disconnect` takes the shown one off
  the rail and shows its neighbour; its goodbye sound drains from
  `UI.closing`. A failed session stays on the rail showing its error on
  the connect screen, which has "Remove from the rail" for it and is
  filled with its address and password. The `-channel` option applies
  to the first server only.
- Per session: its own playback stream (sounds from servers not shown
  play), its own network loop (a thread natively; on the web the
  frame's turns go round all of them, the shown one first), and on the
  web its own pair of WebSocket slots (`Voice_Client.slot`, even for the
  main link, the next for the bulk link).
- To every session (`command_all`): mute, deafen (the sound only from
  the session in voice, or the shown one), listen back, gate, quality,
  noise suppression, notification volume, transfer limits, app audio
  volume; idle (each session remembers what it was told); reopening
  devices.
- Voice in one server at a time: joining a channel's voice, calling or
  answering leaves voice (or hangs up) everywhere else first
  (`leave_voice_elsewhere`). The microphone opens only for the session
  in voice (and for the settings' test on that one or the shown one);
  which that is is worked out once a frame with no View locked
  (`UI.voice_at`), since mute can be pressed while the shown View is.
  Shared application audio goes into that session (and stops if it's
  freed); the web's screen share is only sent by it
  (`Video_Client.share_here`); a session that's hidden stops watching a
  screen (there's one picture to show it in).
- The rail: 56 px down the left, a disc per session in the server's own
  colour (hashed from its address, as people's are from their ids) with
  its initials (two words' first letters, or a word's first two), a bar
  beside the shown one; dimmed while connecting; grey with red letters
  when not connected. Hover shows its name, address and state; clicking
  switches after the frame (`switch_now`). **+** shows the connect
  screen (9b's dialog replaces it), which adds a server rather than
  replacing the one there. With no session there's no rail.
- Tried: in a browser (headless Chromium) on two servers with relays
  of their own: the rail, logging in on both, a message on each, voice
  moving from one to the other (the first server logs "left voice" as
  the second "joined"), a draft kept across switching, disconnecting the
  shown server (both its WebSockets close, the other is shown); and
  natively (weston off-screen) on the same two plus a third with a
  password: voice moving back the other way, rapid switching, a failed
  connection (grey, red letters, its error, then connected again in the
  same place). Not covered: the web client never reopens a WebSocket
  once it closes (its relay restarted, say), so a web session whose
  server restarts stays "connected" with grey bars until it's connected
  again by hand - as before 9a.

*9b as built:*

- The build first had to be mended: 9a met master's message bar and
  user menu, and `UI` still declared the fields that had moved into
  `Server_UI`. Two of 9a's own slips found on the way: the chat's
  timezone was in `Server_UI` (loaded before any session, then lost to
  the first one shown, so native timestamps were UTC), now
  `UI.chat_tz`; and the login form's remembered username went the same
  way, now put into each new session's stash. The message bar is reset
  on switching (its messages are the old server's).
- The dialog (`ui_join.odin`): address and password, Connect. Its
  session is in `UI.sessions` from the start, so network turns, slots,
  mute, idle and shutdown reach it like any other, but marked
  `joining`: the rail skips it, the main window shows the start screen
  behind the dialog, and it isn't saved. The dialog shows what the
  server says in place: connecting; the login screen (with Register
  where open) drawn inside it; the trust prompt for a changed key
  (trusting reconnects inside the dialog); a failure, the form again
  with the error. Once logged in (`login.state == .Done`) it's put on
  the rail, joined in the settings, the dialog closed; must-change and
  verify then show in the main window as for any server. Giving up
  (Cancel, the close button, the login screen's leave button, a click
  on the rail) ends it and shows what was shown before. An address
  already on the rail just shows that server.
- The start screen: with nothing joined it says so and has "Join a
  server"; the rail is always there now, for its +.
- `settings.joined_servers` (address, password, last channel) in rail
  order, all connected at start and the first shown; `server` and
  `recent_servers` are only read, turned into joined ones once (recent
  ones in their order, newest first) and dropped from the file. A
  server given on the command line (or `?server=`) is joined and shown,
  with `-channel`.
- Leaving: the header's leave button (was Disconnect), the connect
  screen's "Leave this server" (was "Remove from the rail") and the
  login/password/verify screens' leave buttons take it off the rail and
  out of the settings. The tray's Disconnect only takes it off the rail
  until the next start, so a tray click doesn't forget a server and its
  password.
- Tried: both builds type-check and build, settings tests (joining,
  leaving, the migration happening once). Not tried in the UI: the web
  build on this machine (emcc 6.0.11) fails at start with "ASM_CONSTS[code]
  is not a function", at 9a's commit too, so it's the toolchain; and
  the native client can't be pointed at other settings than the
  user's.

*9c as built:*

- `servers_frame` (`ui_servers.odin`), once a frame between frames:
  each rail server's unread count (channels and DMs not muted) and
  what's for us (mentions, a muted channel's too, plus unread DMs) on
  its `Net_Session`; their total in `UI.unread` (out of `Server_UI`)
  for the window's title and the tray.
- The rail: a short bar beside a server with something unread (not the
  shown one, which has the long bar), a red count at the bottom right
  of one with mentions or DMs; the hint says the counts.
- Notices from every server (`session_notices`, `ui_poke.odin`):
  pokes, mentions and a call coming in, "... on <server>" once there's
  more than one on the rail. The call's notice moved out of the voice
  panel (`UI_Calls` is gone, its `announced` per session), so it's
  told with the window hidden too, which it wasn't before. Sounds
  already played from every server (9a).
- The voice panel, on any server shown, has a part over the rest for
  voice or a call ringing in another server (`UI.voice_other`, worked
  out before the layout so the height and the drawing agree): what,
  "on <server>", where and how long; Show and Leave / Hang up /
  Cancel, or for a call ringing in, Accept (leaves voice anywhere else,
  and shows that server) and Decline.
- The icon's menu, right-click (a long press on a touch screen, which
  the web already turns into one): Settings (shows the server and its
  settings), Log out (when logged in), Leave the server, and Leave and
  forget its key; leaving asks first. `disconnect` takes the session,
  so a server not shown can be left.
- Dragging an icon (past 6 px) shows a line where it would go; let go,
  the rail and `settings.joined_servers` take the new order
  (`order_joined_servers`; servers off the rail till the next start go
  after those on it). A press still shows the server at once.
- Tried: both builds type-check and build, settings tests (with the
  reordering). Not tried in the UI yet.

## Decisions

Open until the owner answers. Recommended answers first.

| # | Question | Recommendation |
| --- | --- | --- |
| D1 (9) | Joined servers all connected at once, or only the one shown? | All at once: it's what makes the rail useful (badges, calls and DMs from anywhere, voice that survives switching). Cost is mostly the mechanical `ui.view` change. |
| D2 (2) | On Wayland compositors with no idle protocol, and browsers without Idle Detection: fall back to the window's input? | Yes, as today. |
| D3 (3) | A deleted account's DMs: kept for the other side (read only), or deleted with it? Who may delete: self and `Manage_Accounts` above them? | Kept, read only. Both may delete. |
| D4 (4) | What's wrong with the roles UI today, and is the proposal (a Roles window, members per role) the right direction? Role colours wanted? | The description in for item 4 with the separate window (roles on the left, role settings on the right) is a good improvement over the current roles UI |
| D5 (5) | If measuring shows the web's single thread is to blame too, move the network loop and Opus into a Worker as part of 5, or as its own item after? | Its own item after; 5 is the split. |
| D6 (6) | What is SMTP for? Only IMAP is needed for 8. Password reset by mail, mention digests, nothing yet? libcurl a hard dependency of the server, or a build option? | IMAP now, SMTP configured and testable. It will be used for password resets and email notifications for missed mentions. libcurl loaded at runtime, so a server without it runs without email. |
| D7 (7) | A new `Create_Invites` permission, or reuse `Invite`? Invite codes: also allowed to expire by time? | New permission (Invite means something else today). Both use counts and an optional expiry. |
| D8 (8) | Require the code in the subject? What can an unverified account do while waiting: nothing but the waiting page, or read only? Mails that verify nothing: moved to a folder or deleted? | Code required (otherwise an address can be claimed by someone else). Nothing but the waiting page. Mails that verify nothing should be deleted. |

## Working through an item

The item's section is the plan; what turns out differently is written
under it when the item is done, and its row in the table says done.
Work on `extended`, committed locally, not pushed. Build as in
`docs/Building.md`; server tests with
`. scripts/build/collections.sh; odin test src/server $collections`.

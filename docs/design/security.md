# Security review (2026-10-15)

A first look over the server and the client for security problems. It
was made by reading the code, with nothing run against a live server.
The threat model, in order of priority:

1. **Attackers without credentials.** No account, and maybe not the
   server password either. They can send any UDP packet, and connect to
   the relay/API port if it's enabled. Servers are mostly private with
   trusted users, so this matters most.
2. **Attackers with an ordinary account** (not an admin): a modified
   client that sends whatever it likes.
3. **The client against a hostile peer**: another user's content, or a
   compromised or impersonated server.

The first section lists what was fixed along with this review. The
second lists what is still open, roughly in the order it should be done.
The last lists what was checked and found sound, so it isn't checked
again for nothing.

Sizes: S up to about 300 changed lines, M up to
1000, L up to 2500.

## Fixed

| # | Problem | Who | Fix |
| --- | --- | --- | --- |
| F1 | Screen shares leaked to anyone through Nack | account | `media_nack` checks the room (`media_same_room`), as `media_relay` does |
| F2 | A message could grow past `MAX_CHAT_SIZE` when links and mentions were rewritten, and break history, pins and search for its conversation for good | account | post, edit and forward refuse it with Too_Large |
| F3 | The relay/API port took any number of connections and waited for a request head forever (slowloris) | none | 10 s for the head, 5 min idle on a relayed WebSocket, at most 256 connections; the standalone gateway also times out the head |
| F4 | `Content-Length` took signs, `_` and numbers that wrap; duplicate lengths were allowed | none | digits only, at most 15, duplicates must agree |
| F5 | Register answered "username/email taken" and "bad invite" before the rate limit, so a stranger could ask about any number of them | none | the limit (`register_take`) comes first |
| F6 | A session that hadn't logged in moved to the source address of any packet it sent, so whoever made the handshake could point the server's answers at a third party | none (with the server password) | no roaming before login |
| F7 | Every resent Handshake_Finish to a keyed session got three Welcomes, without limit | none | at most once per 500 ms per session |
| F8 | A connection that hadn't logged in could have 4 MiB of unacked answers queued | none | 128 KiB until `conn_login` (`STREAM_QUEUE_WAITING`) |
| F9 | A DM file offer of about 4.5 TiB made the receiver's chunk bitmap wrap to length 0, and the first chunk crashed the client | account | the bitmap is sized in `int`; offers over `MAX_FILE_SIZE` (256 GiB) are refused by the server and declined by the client |

Tests: `test_media` (F1), `test_forward` (F2), `test_transfer_max_size`
(F9). All server and proto tests pass.

## Open

### Without credentials

**1. A flood of spoofed Handshake_Inits locks everyone out.** (High, M,
protocol.) Each Init allocates a `Client` for `HANDSHAKE_TIMEOUT` (5 s),
and once `max_sessions` (512) are in use new Inits are dropped. About
100 spoofed packets a second (90 kbit/s) keep the table full. Nobody new
gets in, and since existing connections rekey every `REKEY_AFTER`, they
are all gone within `REJECT_AFTER` (3 min). The source address can't be
checked before state is kept, so per-IP limits alone don't help against
spoofing. Each Init also costs the main loop an X25519.

Fix: WireGuard's cookie reply. When the half-open count is over a
threshold (say a quarter of `max_sessions`), answer an Init with a small
Cookie packet: a MAC of the source address and port under a secret that
changes every two minutes. The client repeats the Init with the cookie
attached, and only then is state kept. Also keep the half-open sessions
in a budget of their own, so they can never take the room keyed
sessions need for rekeying.

*As built (2026-10-15):* `server/handshake_gate.odin`, used by the main
port and the media port.
- **When a cookie is asked for.** Over `max(max_sessions/16, 4)`
  handshakes in progress, an Init needs a cookie, and one without
  gets a 21-byte `Handshake_Cookie`. The Init is 105 bytes, so the
  reply doesn't amplify.
- **What the cookie is.** HMAC-SHA256 of the address and port, cut to
  16 bytes. Its secret is replaced every 2 minutes, and the one before
  it is still accepted.
- **Client side.** The client appends the cookie to the same Init and
  sends it again (`proto.initiator_read_cookie`). The main, bulk and
  media links do this, and so does `lite`, which the gateway and the
  stress bots use.
- **Budgets.**
  - At most half of `max_sessions` may be half open.
  - At most `HALF_OPEN_PER_ADDRESS` (8) handshakes may be in progress
    from one address. Loopback is exempt, because every browser behind
    the relay comes from there.
  - Turned-away Inits are logged at most every 10 s.
- **Compatibility.** The cookie isn't part of the Noise transcript, so
  the prologue stays the same. Old clients work as before, except that
  they can't get in while a server is asking for cookies.
- **Tests.** `test_handshake_cookie` (proto), `test_handshake_gate` and
  `test_handshake_gate_limits` (server).
- **Still open.** A flood from addresses that really answer (a botnet)
  still fills the half-open budget, but now with real addresses that
  per-address limits can catch.

**2. Server password guessing isn't throttled.** (Medium, S.) The
comparison is constant-time, but a wrong password is refused at once
with `Wrong_Password`, and nothing limits attempts: thousands a second,
one handshake each. A short shared password won't hold up. It also
gates most of what's left under this heading. Fix: count refusals per
source address (and in total) and drop Finishes from addresses over the
limit for a while. Recommend a long password in the README.

*As built (2026-10-15):* `gate_wrong_password` in
`server/handshake_gate.odin`, for the main port and the media port (which
also checks the password).
- **Limit.** A refusal costs the address (without the port) a token: 10
  at once, then one every 30 s (`PASSWORD_FAILURES`,
  `PASSWORD_FAILURE_EVERY`). Inits from an address without a token are
  ignored.
- **Who can be blocked.** ~~Only an address that has finished a handshake
  can have a password refused, so a forged address can't get somebody
  else blocked.~~ **Wrong** (second review, S2): the address counted was
  the source of the Handshake_Finish, which isn't authenticated. Fixed
  with S2.
- **Loopback.** It isn't exempt, so guessing through the relay or the
  API is slowed down too. The price is that the relay's browsers and the
  built-in API wait together while somebody guesses through them.
- **Tests.** `test_handshake_gate_password`. Tried live: 10 refusals,
  then the Inits went unanswered.

**3. The password hash queue is global.** (Medium, S.) 16 connections
that keep sending `Auth_Login` fill `HASH_QUEUE_MOST`, and everyone
else's login, registration and password change is Rate_Limited. Also,
the account lock is checked when a job is submitted but only applied
when it finishes, so up to 16 guesses at an account can be in flight
at once. Fix: count in-flight attempts against the account at submit
time; limit logins per source address; keep a slot for devices that
have logged in before.

*As built (2026-10-15):*
- **In-flight attempts.** `Account.checking` counts the logins being
  hashed. While one is in progress, another is refused once failures
  plus those in progress reach `AUTH_FREE_FAILURES`.
- **Per address.** Password logins and registrations are limited by the
  address of the connection's main session (`login_allowed` in
  `auth.odin`): 10 at once, then one every 6 s.
- **Devices that logged in before.** They log in by their key, which
  isn't hashed, so they don't need a slot of their own.
- **Loopback** counts as one address here too. That's every browser
  behind the relay and every bot using the built-in API, which is fine
  for password logins, which are rare.
- **Tests.** `test_login_in_flight` and `test_addr_buckets`. Tried live:
  12 logins from loopback, and the 11th and 12th were refused.

**4. Login lockout tells which usernames exist.** (Low, S.) A locked
account answers Rate_Limited at once; a name that doesn't exist is
never locked. Six wrong guesses tell them apart. Fix: also lock unknown
names (a small map with expiry), or answer like a wrong password while
locked.

**5. Registration can be starved and email addresses squatted.** (Low,
S.) The registration bucket is server-wide (10, then one per 10 s), so
one script takes all registrations (now including the refusals, after
F5). An unverified account holds its email address for
`unverified_hours`. Fix: per-address buckets; let an unverified account
lose its email address to a new registration.

**6. Relay/API: per-address limits, bucket keys and allocation before
the token check.** (Medium, S each.)
- F3 caps the total, so one address can still take all 256
  connections. Add a per-address cap. Behind a proxy, every
  connection comes from the proxy.
- The gateway keys its rate buckets by the token's public key, so each
  random well-formed token starts with a full bucket. It then uses a
  gateway connection slot and a server session until the server
  refuses it. `/login` has no bucket at all. Fix: a per-address bucket
  in front of `new_conn` and `/login`, plus a short negative cache for
  refused keys.
- `POST /api/v1/uploads` allocates a ~1.3 MB ring before the gateway
  has accepted the token (`gateway/files.odin`). Allocate it after.

*As built (2026-10-15):*
- **Relay connections.** At most 32 per address (`relay_count`).
  Loopback and private addresses are exempt, since behind a proxy they
  are all the proxy.
- **Gateway connections.** Each address may make the gateway open 10
  connections to the server at once, then one every 6 s (`opens_take`
  in `gateway/limits.odin`). That counts `/login` and every token that
  isn't connected yet; tokens that are connected aren't affected.
  Behind a trusted proxy, the address is the last one in
  `X-Forwarded-For`.
- **No negative cache.** The bucket makes it unnecessary.
- **Upload ring.** Its buffer is now allocated once the server has
  accepted the upload (`ring_allocate`).
- **Tests.** Gateway opens in `test_gateway_limits`, and tried live.
  The relay's per-address cap wasn't tried live, because every address
  on hand was private.

**7. The relay can't be bound to loopback.** (Medium, depends on the
setup, S.) It always listens on all interfaces (`relay.odin`). With
`behind_proxy`, `X-Forwarded-Proto` is believed from anyone, so going
around the proxy makes `/login` accept a password over plain HTTP. The
web client served over plain HTTP can be changed on the way to steal the
device key from `localStorage`. Fix: a `relay.bind` setting, loopback by
default with `behind_proxy`; only believe forwarded headers from
loopback. Say in the README that the web client needs TLS.

*As built (2026-10-15):*
- **`relay.bind`.** The address to listen on. Empty is still every
  interface, so existing setups (and Docker, where the proxy is on
  another network) keep working.
- **`api.trusted_proxy`.** With `behind_proxy`, `X-Forwarded-Proto` (and
  `X-Forwarded-For`, item 6) are only believed from the proxy. That's
  `trusted_proxy` if it's set, otherwise loopback and private addresses.
  A request straight from the internet no longer counts as HTTPS.
- **Gateway.** The standalone gateway has `-trusted-proxy`.
- **Docs.** `docs/API.md` and the README describe both.
- **Tests.** `test_gateway_login_rule`. `bind` was tried live.

**8. No security headers on the web client's origin.** (Low, S.) No
CSP, `X-Content-Type-Options`, `frame-ancestors` or `Referrer-Policy`.
The device key lives in that origin's `localStorage`. Nothing was found
that injects HTML (the UI is drawn on a canvas), so this is a second
line of defence. CSP needs testing with the wasm build
(`script-src 'self' 'wasm-unsafe-eval'`).

**9. No Origin check on `/yap/` and `/yap-media/`.** (Low, S.) There
are no cookies, so it isn't cross-site WebSocket hijacking. But any web
page can use a visitor's browser to reach a relay on that visitor's
intranet. Allow only the relay's own origin.

*As built (2026-10-15):* a WebSocket upgrade with `Sec-Fetch-Site:
cross-site` is refused with 403. Comparing `Origin` with `Host` would
break behind proxies that rewrite `Host`, which nginx does by default,
while browsers set `Sec-Fetch-Site` themselves and proxies pass it on.
Browsers that don't send it (anything older than about 2023) aren't
checked. Tried live: no header and `same-origin` connect, `cross-site`
gets 403.

### With an account

**10. No limit on incoming requests.** (Medium, M.) Only what the
server sends is rate limited. `handle_stream` handles everything ready
in one go, so 64 searches at up to 4 ms each (`SEARCH_BUDGET`) stall
the loop and with it everyone's voice. Posts, file offers, call rings
and mentions (which subscribe people) can be sent as fast as the link
allows. Fix: a token bucket per connection and per account, with
search, history, post and forward costing more, plus a cap on requests
handled per connection per loop iteration.

*As built (2026-10-15):* `request_take` in `rpc.odin`, per connection.
- **Limit.** 200 at once, then 40 a second.
- **Costs.** A search costs 10, the server icon 4, a post or forward 3,
  a history page 2, anything else 1. Over the limit, a request is
  answered with Rate_Limited without being handled.
- **What that bounds.** A search burst is now at most about 20 × 4 ms,
  and then 4 searches a second.
- **Left out.** No per-account bucket: every device logs in with a
  password, which batch 1 limits per address. No per-iteration cap: the
  stream window already caps one packet's worth at 64 messages, and the
  bucket covers the rest.
- **Tests.** They make requests far faster than any client, so they
  turn the limit off (`Server.requests_unlimited`), except
  `test_request_limit`. Tried live: 40 searches through the API, and 21
  were answered.

**11. Presence changes are amplified to everyone.** (Medium, S.) Each
change of Sound flags, voice room, idle or activity bumps the state
version, and the whole snapshot goes to every connection. A client
that toggles its Sound flags at packet rate multiplies its traffic by
the number of users. Fix: limit such changes per connection, and send
state at most every 50–100 ms.

*As built (2026-10-15):* a connection is sent a new snapshot at most
every `STATE_EVERY` (50 ms) (`sync_state`). A change only bumps a
counter, so that bounds the cost whatever the toggle rate, and no
per-connection limit was needed. The first change after a quiet period
still goes out at once, and the loop wakes at least every 100 ms, so a
change waits at most that long. Test: `test_state_coalesced`.

**12. Any user can fill the disk.** (Medium, S.) Everyone has
`Attach_Files`, there's no quota, `rate_kb` is only a hint to the
client, and finished uploads don't count against
`MAX_ATTACH_TRANSFERS`. A full disk also stops SQLite from writing.
Fix: bytes per account per day, a free-space floor below which uploads
are refused, and actually enforcing the rate.

*As built (2026-10-15):* only the free-space floor. Attach_Put is
answered with Closed when the upload would leave less than 512 MiB free
(`ATTACH_FREE_FLOOR`), counting what the uploads in progress will still
write. The client says "The server has no room for more files". It
uses `disk_free` (`statvfs`, or `GetDiskFreeSpaceExW` on Windows),
checked on Windows and macOS. Enforcing `rate_kb` is left for servers
with users who aren't trusted. *Update (2026-11-04):* a per-account
daily quota has since been added (`ATTACH_QUOTA_PERIOD`,
`attachments.odin`), and uploads are paced.

**13. Out-of-order upload chunks stall the loop.** (Low, S.) If chunk 0
comes last, up to 100 MB are read back and hashed in one iteration
(`attachments.odin`). Hash a bounded amount per iteration and go on in
`attachments_sync`.

*As built (2026-10-15):* simpler. Senders keep within `FILE_WINDOW` of
the first missing chunk (proto/files.odin), so the server now drops
upload chunks further ahead than that. Filling a gap then reads back at
most one window (about 1.2 MB). `test_attachments` sends each window
backwards and checks that a chunk past the window is dropped.

**14. Push endpoints: blind SSRF and one slow thread.** (Low, S.) Any
`https://` URL is taken, internal addresses included. Redirects aren't
followed and the answer isn't returned, so only blind. One push thread
with 20 s timeouts lets a tarpit endpoint delay everyone's
notifications. Fix: refuse loopback, private and link-local addresses
after resolving (`CURLOPT_OPENSOCKETFUNCTION`), and use shorter timeouts
or a few threads.

**15. Smaller ones.** (Low, XS each.)
- *Fixed (2026-10-15):* Blob_Put said "have" for a hash stored as any
  kind of blob, including DM attachments. That confirmed a known file
  was on the server, without giving access to it. Now it's only said
  for profile pictures; anything else has to be uploaded, which proves
  the uploader has it (`test_blob_transfer`).
- *Fixed (2026-10-15):* `attachment_visible` ignored `.Archived`, so
  members of an archived channel could still fetch its files by id
  (`test_attachments`).
- `account_password_set_finish` checks only `Manage_Accounts` again
  after hashing, not `outranks`.
- `handle_typing` doesn't check for archived conversations or closed
  DMs.
- The attacker-controlled path in the relay's log lines isn't escaped
  (no CR/LF, but terminal escapes).

### The client

**16. Received images aren't scaled down.** (Medium, S.) Previews are
fetched and decoded automatically up to `MAX_PIXELS` (7680×4320, about
133 MB RGBA) and uploaded full size with mipmaps. A message with ten
small solid-colour PNGs of that size costs every viewer about 1.7 GB.
Animated WebP canvases are allocated in libwebp before the size check.
Fix: scale down after decoding to what can be shown (say 2048 px),
check the WebP canvas size before `anim_open`, and keep a budget for
decoded bytes.

*As built (2026-10-15):*
- **Scaling.** After decoding, a picture bigger than `MAX_SHOWN_SIDE`
  (2560 px, enough for a 1440p screen) on its longer side is scaled
  down to fit. `clipboard.scale_down` uses a box filter weighted by
  alpha. The web build does the same in `web/decode.js`. Emoji sheets
  are left alone; they arrive as QOI, so they never go through
  `decode.js`.
- **Memory.** The full-size picture still exists briefly while it's
  decoded, but one at a time, on the decode thread. What's kept is at
  most about 26 MB.
- **Animated WebP.** Its canvas size is checked (`webp.size`) before
  `anim_open`.
- **Texture budget.** Textures are also kept under 512 MiB in total
  (`MAX_TEXTURE_BYTES`), not only 96 of them. Those drawn in the
  current frame are never dropped for it, so a full screen doesn't
  decode over and over.
- **Tests.** `test_scale_down`. The UI wasn't tried with a real
  oversized picture.

**17. "Open" on a saved attachment relies on a denylist.** (Low-medium,
S.) `platform.open_file` blocks 39 extensions and hands everything else
to the shell. Missing ones that run code include `.msc`, `.appref-ms`,
`.application`, `.settingcontent-ms`, `.library-ms`, `.chm`, `.scf`,
`.inf`, `.xll`, `.rdp`, `.appinstaller`, `.diagcab`, `.theme`,
`.vhd(x)`, `.img`, `.webloc`, `.mobileconfig`, `.deb` and
`.flatpakref`. Channel attachments have no type allowlist (DM offers
do). Fix: open only an allowlist (pictures, video, audio, PDF, text,
archives) and offer "Show in folder" for the rest.

*As built (2026-10-15):* `platform.file_openable` and an allowlist:
pictures, videos, audio, common archives, and pdf/txt/md/csv/log.
- **Left out on purpose.** `.iso`, `.img`, `.vhd` and `.cab`, because
  Windows mounts or unpacks them, which has been used to get past the
  Mark of the Web.
- **UI.** For anything else the attachment shows only Browse (show in
  folder).
- **Test.** `test_file_openable`.

**18. Trust on first use is silent.** (Low, M.) The first key a server
answers with is saved without asking. The server password and the
account password then go to it, so whoever sits on the path at a
device's first login gets both. A changed key is caught and shown, which
is good. Also:
- A failed read of `known_servers` counts as "new" and rewrites the
  file with only the new entry, losing every other pin. It should
  fail closed.
- Pins are keyed by the address as typed. `Example.com` and
  `example.com` are two servers. Lowercase the host.
- Fix: show the fingerprint on first use, and allow pinning a key in
  the address or an invite (`host:port#<hex>`).

*As built (2026-10-15), the cheap parts:*
- **Fail closed.** A `known_servers` that exists but can't be read is
  `Trust.Unreadable`. The connection is refused with a message saying
  so, and `remember_server_key` won't overwrite the file.
- **Case.** Addresses are compared without regard to case. That's
  instead of lowercasing them, so existing pins keep matching.
- **Tests.** `test_known_servers` and `test_known_servers_unreadable`.
- **Still open.** The fingerprint prompt, and pins in addresses or
  invites.

**19. Smaller ones.** (Low.)
- *Fixed (2026-10-15):* `sanitize_file_name` left Windows device names
  (`CON`, `NUL`, `COM1`, …) as they were. They get a `_` in front now,
  with or without an extension (`test_file_names`).
- Markdown links show their target only on hover and open on one
  click. IDN hosts aren't shown as punycode.
- Server passwords are stored in plain text in the settings (0600 on
  Unix, the user's `%APPDATA%` ACL on Windows). The web build keeps
  them, and the device key, in `localStorage`.

### Not reviewed

- The screen share decoder (`src/video`, ffmpeg) was read in the second
  review (below), but not fuzzed. It still deserves fuzzing, and
  decoding in a separate process (S21).
- Fuzzing in general: `markdown.odin`, the rich text index maths, and
  `proto` decoders were read, not fuzzed.

## Second review (2026-11-04)

Four read-only passes by reading the code, nothing run against a live
server: Lua scripting and bot slash commands (added after the first
review), the protocol and its parsers, the server's authorization and
deployment, and the client with the video decoder. The items already
decided to be skipped (4, 5, 8, 14 and the fingerprint prompt of 18)
weren't raised again.

*Verified* means the finding was checked in the code a second time.
Everything else is as the reviewer reported it, and a few estimates
(stack depth, timings, memory) are unmeasured.

Nothing was found in the Noise handshake, the key checks, the replay
window or the cookie. Nothing found in the server's authorization
checks needs more than a Medium.

### High

**S1. Completed sessions have no per-address cap.** (Protocol/server.)
The gate limits half-open handshakes per address
(`gate/gate.odin:109`). Once a handshake finishes the session counts
against nobody, and a session that never logs in can stay alive on
Ping and Stream until `REJECT_AFTER` (180 s), re-handshaking every two
minutes. One host with fresh random keys fills `max_sessions` (512).
That takes about 3 minutes, needs no credentials without a server
password (otherwise only the shared one), and locks out new clients and
every rekey. Existing connections die within 3 minutes. The cookie and
half-open budgets of item 1 don't help, because these sessions are
fully keyed. Fix: cap keyed sessions per address (8 to 16; loopback
exempt only for the relay), an idle limit of about 30 s for sessions
that haven't logged in, and room kept for known devices
(`auth_known_device`).

*Fixed (2026-11-04), differently from the suggestion:* a cap of 8 to 16 keyed sessions per address would lock out an office behind one NAT, so what is limited is sessions that have finished their handshake but whose connection hasn't logged in (`unlogged_room`, `server.odin`): `UNLOGGED_PER_ADDRESS` (16) per address, this machine exempt (the relay's browsers), and at most `max_sessions / 2` in all. Logged in connections and the sessions they make for rekeying or a bulk link aren't counted, so the table can't be filled with sessions that never log in, and rekeys have room. The Finish that would go over is dropped, and the client tries again. Not done: an idle limit for sessions that haven't logged in (a user may take a while to type a password), and room kept for known devices (they are in the table already, and their rekeys aren't counted). Test: `test_unlogged_room`. Still open: many addresses (a botnet) can fill the half of the table that unlogged sessions may take, but not more.

**S3. A script's `__gc` finalizer runs after its host state is freed.**
(Client, *verified*.) `destroy` (`script/script.odin:269`) frees the
timers, commands, requests, store and settings, and calls `state_close`
last. `lua_close` runs every pending `__gc`, and a finalizer can still
call `yap.timer`, `yap.store.set`, `yap.register_command` and, with
`net`, `yap.http_get` (which leaves a `Pending_Request` holding the
freed `Script` for the next `http_poll`). Needs a script that is turned
on, but no permissions. It runs when the script is switched off,
removed, replaced, reloaded, or the client exits. That is heap
corruption in the client. Fix: close the Lua state first, or set a
`closing` flag that makes `dispatch` fail, and cancel requests after
`state_close`. Also make the bootstrap's `setmetatable` refuse a
metatable with a `__gc` key (it has to be checked at `setmetatable`
time, whatever the value).

*Fixed (2026-11-04):* `destroy` sets `Script.closing` (every `yap.*` call then does nothing) and closes the Lua state before it frees anything else. The bootstrap's `setmetatable` refuses a metatable with a `__gc` key, which also closes the `__gc` loop of S4. Tests: `test_finalizers_are_refused`, `test_destroy_stops_the_api`. `yap_lua.lib` has to be rebuilt (delete it, `build.bat` and `build.sh` do the rest).

**S4. A script can hang the client, before it is approved and at every
start.** (Client.) The instruction hook can't fire inside one C call,
and Lua turns hooks off while a finalizer runs. Four stock primitives
are left unbounded:
- a `__gc` with a loop;
- `table.move({}, 1, 1<<60)`, which allocates nothing, so the 16 MiB
  cap doesn't catch it;
- backtracking patterns under the 200 byte limit
  (`("a?"):rep(35)..("b")`) and `.-` on a long subject;
- `collectgarbage()` on a nearly full heap.

*Fixed (2026-11-04), except reading info:* the `__gc` loop is refused with S3. `table.move` refuses a range of a million or more elements. Pattern matching has a budget of steps per call (`yap_pattern_step`): a million, and three for each byte of the subject up to four million, counted in `match` and `singlematch`; over it the call fails with "pattern too complex". That needed four marked lines in Lua's `lstrlib.c`, so a copy of the 5.4.8 file is in `deps/thirdparty/lua/` and `yap_lua.c` includes it instead (a new Lua version needs the same four lines, see the comment in that file). `collectgarbage()` in a loop is stopped by the instruction limit between calls. Test: `test_long_calls_are_bounded`. Still open: `read_info` still runs every script in the folder at start-up, each for up to 500 ms, so a hostile file costs half a second per launch (no longer a hang). `yap_lua.lib` has to be rebuilt.

`item_load` calls `read_info` on the UI thread for every script in the
folder, at start-up and when one is added, so the 500 ms limit doesn't
apply and an unapproved file hangs every launch until it's deleted by
hand. The same primitives stall the network thread from
`filter_incoming`. Fix: the `__gc` check of S3, a cap on
`table.move`'s range, a step budget in `match()` (patch `lstrlib.c`
before the include in `yap_lua.c`) or a cap on subject sizes, and only
reading a script's info when the user asks for it, or with smaller
limits.

### Medium

**S2. The source of a Handshake_Finish is trusted.** (Protocol,
*verified*.) `session_finish` (`session.odin:137`) counts a wrong
password against `from`, and `session_keyed` (`:147`) sets the
session's endpoint to it. The Init's source is the proven one, since
the Resp has to reach whoever finishes the handshake. The Finish's isn't.
- *Lock-out.* Make an Init from your own address, then send about 11
  Finishes with a wrong password and the victim's address as the
  source. The victim's Inits are ignored for about 5 minutes, and
  clients behind that address die at `REJECT_AFTER` unless they get a
  rekey through. Repeat every 5 minutes. This contradicts the claim
  under item 2.
- *Reflection.* With the victim as the Finish source, the session's
  endpoint is the victim, and spoofed Data from the victim's address
  passes the `from == endpoint` check. The server's answers
  (`Server_Icon`, downloads, Nack resends) go to the victim, limited by
  stream pacing (256 KiB/s) and `resend_budget`. Roaming after login
  has the same property for an account.

*Fixed (2026-11-04), the Finish part:* a Finish for an unkeyed session is ignored unless it comes from the address its Init came from (`session_finish_from_ok`, main and media port). Only whoever got the Resp can make a valid Finish, so failures are counted against, and the session is bound to, an address that took part. Test: `test_finish_source` (it failed without the change). Still open: *roaming after login.* `session_receive` follows an authenticated session to the source of its Data packets, so an account holder can have the server send paced answers (Server_Icon, downloads, Nack resends) to a forged address, limited by stream pacing and `resend_budget`. Fix: validate the new address before using it for more than a few packets (a challenge that has to come back from there), which needs a protocol change.

Fix: count failures against the Init source and keep it as the endpoint,
requiring `from == endpoint` on Finish. Validate a new address before
roaming: a challenge answered from there, and a tiny allowance until it
is.

**S5. One video fragment freezes a viewer's network thread.** (Client,
*verified*.) In `video_window_add` (`proto/video_window.odin:221`), a
fragment with `frame = next + 0x7FFFFFFF` is not "older" for
`serial_newer`, and the loop `for fr := w.next; fr != start; fr += 1`
runs about 2^31 times, while voice, video and everything else on that
thread wait. The server relays the frame number unchanged. Anyone whose
share is watched can do it, repeatedly. Fix: when the jump is
`>= VIDEO_WINDOW`, clear the 8 slots and set `next` and `newest`
directly, and add `min(jump, VIDEO_WINDOW)` to `given_up`.

*Fixed (2026-11-04):* the jump clears the window's slots and adds to `given_up` without walking the gap. Test: `test_window_far_jump`.

**S6. Search leaks which words are in conversations the asker can't
read.** (Server, *verified*.) The FTS query isn't limited to the asker's
conversations, and `searched_to` (`search.odin:219`) moves to every
examined row, readable or not, and goes back in the answer
(`encode_search_answer`). Searching for a word and seeing the cursor
move shows that it occurs somewhere (a DM, group or private channel).
Moving `before` walks the ids, and so the times, of every match.
Fix: advance `searched_to` only for readable rows, or join the FTS
results with the asker's conversations in SQL. When the time budget
cuts a search short, hand back a cursor that doesn't show unreadable
ids, and cap the unreadable rows skipped.

*Fixed (2026-11-04):* the three search statements take the asker's readable conversations as `?3` (a JSON array, `json_each`), so messages of other conversations are never visited. Test: in `test_search`. What remains: SQLite skips those rows inside one step, so the time a search takes still depends on them (coarsely), and a search that times out in a long run of skipped rows doesn't get any further.

**S7. Unverified accounts get live events.** (Server, partly
*verified*.) `conn_login` (`server.odin:567`) appends the connection to
`acc.conns` for an Unverified account, `account_join_defaults` has made
it a member of Home and the default channels, and `msg_deliver`
(`messages.odin:516`) only checks `conv_reader`. The reviewer says
`Msg_New`, `Msg_Changed`, reactions and typing then arrive, which
contradicts "told nothing except its own account details". The
`rpc.odin` list only restricts requests, not pushed events. I checked
the first two steps and haven't run the delivery. Fix: skip Unverified
accounts in the delivery loops, or join the defaults when the account is
verified. Related: an unverified account's name and id reach later
logins through `directory_sync`, and its membership shows in
`Conv_Members`.

*Fixed (2026-11-04):* `send_event` drops every event except Sync_Begin/End, Self, Server_Info and Logged_Out for a connection of an Unverified account; the rest arrives with the sync at verification (`conn_seen`). Test: in `test_verify` (it failed without the change). The directory leak noted above (name and id in `directory_sync`, membership in `Conv_Members`) is still open.

**S8. Deep JSON crashes the relay's thread before any login.**
(Protocol, stack size unconfirmed.) `core:encoding/json` has no depth
limit in `is_valid` (run first by `unmarshal`) or `parse_value`.
`lib/gateway/serve.odin:107` reads up to 512 KiB before the token or the
route is checked, and `routes.odin:80` (`POST /api/v1/login`) unmarshals
it. A body of tens to hundreds of KB of `[` probably overflows the
stack, and the gateway runs inside the server. `json.parse` in
`writing.odin:744` and `commands.odin:146` has the same trouble for any
bot token. Fix: count `[`/`{` depth before parsing (limit about 32), and
cut the login body to about 1 KiB.

*Fixed (2026-11-04):* `proto.json_nesting_ok` (limit `JSON_MAX_DEPTH`, 32) is checked before `json.unmarshal`/`json.parse` of anything from the API: `POST /login`, `PUT /commands` and `body_object` (every other route with a JSON body). `POST /login` also refuses bodies over `MAX_LOGIN_BODY` (4 KiB) with 413. Tests: `test_json_nesting_ok`, and two calls in `test_gateway_login`. The 512 KiB body is still read before the route is known. Not covered: the Mattermost importer (an admin's own file) and the client's own config and store files.

**S9. No rate limit on UDP Voice.** (Server.) `relay_voice`
(`server.odin:999`) checks the Speak right, then seals and sends one
copy to every session (it walks `s.sessions`, not the room's members).
An account sending maximum-size voice packets at line rate multiplies
its traffic by the number of sessions and starves the single main loop.
`request_take` only covers Stream requests, and the file routes
(`files.odin:107`) aren't limited per packet either. Fix: a per-
connection packet and size limit for Voice (about 300 B), a room index,
and a packet-rate cap in `handle_data`.

*Fixed (2026-11-04), the limit only:* a bucket per connection (`voice_take`): each packet costs 400 plus its length, at 60 000 a second with a burst of 30 000. A client (a packet of up to about 500 bytes every 20 ms) uses 45 000 a second at most. A packet over it is dropped. Test: `test_voice_limit`. Not done: indexing the sessions by room (`relay_voice` still walks all of them for each packet; with the limit that is bounded by about 150 packets a second per connection), and a limit on the file routes' chunks.

**S10. Quadratic message parsing.** (Client.) A message of up to
`MAX_CHAT_SIZE` (64 KB) can stall every viewer for seconds per frame
for as long as it's on screen, because `rich_make`
(`ui_rich_text.odin:66`) parses it every frame (only the height is
cached):
- `platform/links.odin:75`, `link_end`: `https://a` followed by about
  65,000 `)` or `]` calls `strings.count` over the whole link each
  time, about 4e9 comparisons per `find_links`;
- `richtext/markdown.odin:541`, `pair_delims`: `x* x* x* ...` scans
  back over every earlier token, and nested pairs make the `styles +=`
  loop at `:570` quadratic as well;
- `markdown.odin:217`: atoms to segments is O(atoms × segments), about
  1e8 for a message of `www.a ` links.

*Fixed (2026-11-04), except the cache:* `link_end` counts the brackets once; `pair_delims` keeps a stack of openers per character, marks what lies between a pair once, and adds up the styles from differences; the atoms are matched to their segments by binary search. Tests: `test_pair_delims_matches_the_reference` (the old version, kept in the test, on 20 000 random token lists), `test_markdown_long_input`, `test_find_links_long_input` (each of the 64 KB inputs above takes milliseconds). What remains is that `rich_make` still parses a message every time it is drawn, now in time proportional to its size. A cache per message id and width needs to know when names, roles and emoji change.

Fix: track the parenthesis balance incrementally, cap delimiters and
atoms per line and message and fall back to plain text, merge atoms and
segments in one sorted pass, and cache `Rich` per message id and width.

**S11. The video decoder has no frame size limit.** (Client.) Neither
`max_pixels` nor dav1d's frame size limit is set (`video/src/view.cpp:155`,
`open_decoder`), and the parameter sets are the sharer's. A frame of
about 16k × 16k is about 400 MB at 4:2:0 per frame, times the reference
frames, the `Nv12::convert` copies, `latest_y_` and the RGBA texture.
A hostile sharer can run the viewer out of memory or GPU memory. Fix:
set `dec->max_pixels` (about 8192 × 4608) before `avcodec_open2`, and
drop frames above a cap in `Output::submit`.

*Fixed (2026-11-04):* `max_pixels` is set to 8192 × 4608 before `avcodec_open2` (`kMaxPixels` in `view.cpp`, so libdav1d gets it as its frame size limit), and a decoded frame above it, or with no size, ends the view ("a frame is too large") before it reaches the output. The file compiles against the bundled FFmpeg 8.1 headers, but it wasn't run: no test covers the decoder, and watching a share with a forged size is still to be tried by hand.

**S12. Scripts can do more than the approval says.** (Client.)
- `on_incoming` and `on_send` (`runtime.odin:754`, `:827`) need no
  permission. A script with none can replace or hide incoming messages
  (swap a link or payment address, show a message "from" someone else),
  edit or cancel outgoing ones, DMs included, and read every
  conversation on its servers. The default scope is all servers
  (`items.odin:215`). The approval dialog and `docs/Scripting.md:104`
  say only that reading is free. Also `filter_incoming` fails open when
  the lock isn't taken within 5 ms. Fix: a permission for filters, a
  dialog that names what is given, new scripts on no servers until
  chosen, and a mark on filtered messages (like `HIDDEN_TEXT`).
- `net` reaches loopback, the LAN and link-local addresses
  (`script/http.odin:182` checks only the scheme), redirects and DNS
  rebinding included, and the answer goes back to the script, so this
  is full SSRF (accepted in design note D10, but the permission text
  doesn't say so). Fix: a separate local-network permission, refusing
  non-public peers with `CURLOPT_OPENSOCKETFUNCTION` for libcurl, and
  pinned addresses or manual redirect handling for WinHTTP and
  CFNetwork (or document the limit). Unverified: WinHTTP's default
  automatic logon may send the user's NTLM or Kerberos credentials to
  intranet hosts.
- Also: `runtime_commands` (`runtime.odin:601`) returns strings that a
  filter's `yap.unregister_command` frees on the network thread while
  the UI reads them (clone them, as `runtime_snapshot` does).

**S13. stb_image's whole format set is reachable.** (Client, exploit
unverified.) `clipboard/clipboard_decode.odin:26` uses `vendor:stb/image`
as it is, so the PSD, TGA, HDR, PIC and PNM loaders (the historically
weakest) decode bytes sent by a peer. Previews fetch by file name
(png, jpg, gif, bmp, webp), but `decode` sniffs the content. Fix: check
for a PNG, JPEG, GIF or BMP magic with `imagekind` first, or compile
with `STBI_ONLY_PNG|JPEG|BMP|GIF`.

*Fixed (2026-11-04):* `clipboard.decode` only hands data to stb_image if it starts like a PNG, JPEG, GIF or BMP (`imagekind.stbi_readable`). The other loaders can't be reached through those: each of them needs other first bytes, and TGA, which has no signature, needs the second byte to be 0 or 1. Tests: `test_stbi_readable`, `test_decode_other_formats_are_refused` (stb_image reads the PNM it uses there). Other `stbi` uses load files that are built into the client, or the user's own avatar (`common/avatar`).

**S14. Display names can impersonate with invisible characters.**
(Protocol/client.) `proto/sanitize.odin:117` (`invisible`) misses
U+061C, U+115F/1160/3164/FFA0 (Hangul fillers), U+2800, U+034F, U+180E,
U+17B4/17B5, U+2065, U+206A to 206F, U+FFF9 to FFFB, the tag characters
U+E0000 to E007F (which also carry hidden text to LLM bots), and
`sanitize_text` lets U+2028/2029 through. The client shows a member's
username next to the display name when two names are equal
(`client/conn/names.odin:35`, `equal_fold`), so "Alice" plus U+3164 isn't
equal and looks identical. Fix: remove every Default_Ignorable_Code_Point
and Cf, Zl and Zp character, and compare names after NFKC, stripping
and case folding. Related (server): `profile_set` doesn't make display
names unique, and personas are only checked against exact existing
names (`personas.odin:30`).

*Fixed (2026-11-04), except uniqueness:* `invisible()` now covers the fillers (U+115F, U+1160, U+3164, U+FFA0), U+2800, U+034F, U+061C, U+17B4/5, U+180B to 180F, U+2060 to 206F and the tag characters; U+2028/2029 become spaces in a name. (Tag characters are gone from messages too, which breaks the flags of England, Scotland and Wales.) `proto.name_skeleton` and `names_alike` fold case, full-width forms, variation selectors and look-alike Cyrillic and Greek letters (and 0, 1, l, |), and are used where the client decides to show the username (`display_name`) and for the names of personas (`persona_check`). Tests: `test_sanitize_name`, `test_names_alike`, `test_persona`. The skeleton table is small and by hand, not Unicode's confusables data. Display names are still not unique (a design choice: the username is shown next to a name that looks the same).

**S15. Groups aren't capped.** (Server.) `MAX_CHANNELS` caps channels,
nothing caps groups (`conv_requests.odin:145`, `group_open`), and every
set of 2 to 7 accounts is a new persistent group, at 40 a second per
connection. `convs_sorted` copies and sorts all conversations on every
login and every role or rights change, and `conv_by_name` and
`conv_browse` scan them, so every login gets slower. Chosen accounts
are also put into a group they never agreed to. Fix: a cap on groups
per `created_by`, delete groups that stay empty (about a day), and let
`convs_sorted` skip what it doesn't need.

*Fixed (2026-11-04), by limits only:* an account may have started at most `MAX_EMPTY_GROUPS` (16) groups that have no message, and `MAX_GROUPS_STARTED` (1000) in all (`groups_started`, `group_open`); opening a group that exists is always allowed. Test: `test_group_limits`. Not done: deleting groups that stay empty, and making `convs_sorted` skip what it doesn't need. A group is only shown to the others once it has a message.

**S16. Build and CI supply chain.** `docker/Dockerfile:9` pipes the
Odin release (a rolling `dev-` build) from GitHub into `tar` with no
checksum, and the image tags are mutable. In `.github/workflows` the
actions (`actions/checkout@v7`, `docker/*`, `laytan/setup-odin@v2`,
`mymindstorm/setup-emsdk@v16`, `hendrikmuhs/ccache-action@v1.2`) are
pinned by tag. `release.yml` has `contents: write`, and the docker
workflow `packages: write` for every run, pull requests included. Fix:
a SHA-256 for the Odin archive (as `fetch.sh` has for the libraries),
actions pinned by commit, `permissions:` per job.

### Low

**S17. Server.**
- A mention subscribes any account to a public channel without
  `Invite` or channel admin rights (`mentions.odin:106`, also from
  `msg_edit`), so anyone who can post can pull anyone in. Design item
  D19 allows it, but not for every poster.
- Calls: any account can ring any other repeatedly (a push with
  `ring = true` each time), keeps the callee busy, and every end writes a
  system message into the DM (`calls.odin`, `call_note`). Add a limit
  per pair and stop noting after a few missed calls.
- `email_set` (`profiles.odin:62`) answers Conflict for an address in
  use, so it tells which addresses belong to members, only limited by
  the general bucket.
- `Must_Change` is only enforced by the client (`accounts.odin:304`,
  `rpc.odin`). The `YAP_INITIAL_ADMIN_PASSWORD` account doesn't get it
  at all (`auth.odin:151`).
- The database isn't opened with a restrictive mode
  (`db.odin:438`, `config.odin:696`). Unverified: the file may be
  world-readable. Set umask 077 or chmod.
- The Mattermost importer follows symlinks in an unpacked export
  (`mattermost/scan.odin:206`, `import_files.odin:112`, `:55`,
  `import_accounts.odin:402`), so a link to a config file becomes an
  attachment. Use `lstat`. `lines_next` also reads unbounded lines.
- docker-compose: the proxy profile still publishes `:8080` on all
  interfaces (default `YAP_RELAY_HOST_IP` empty), so nginx and TLS can be
  gone around. No HSTS in the nginx config. The binary is writable by
  the runtime user (`COPY --chown`), and there is no `read_only`,
  `cap_drop` or `no-new-privileges`.
- Mail (unverified): `address_of` (`mail.odin:608`) takes the last
  `<...>` in From, so a header with two mailboxes could make it disagree
  with the MTA's DMARC evaluation. Refuse more than one address.
  `tls_wanted` treats any host starting with `127.` as local.
- The registration log line includes the invite code (`register.odin`).
- `device_revoke` and `account_roles_request` don't exclude the Owner
  like disable, delete and password-set do (only reachable with every
  permission).

**S18. Protocol.**
- The standalone gateway accepts any server key without `-server-key`
  (`gateway/main.odin:33`) and then sends the server password to it
  (`lite.odin`, `encode_hello`). Require the key or pin it. It also
  takes `-password` on the command line, which shows in the process
  list.
- Per-address limits are keyed by the full address
  (`common/endpoint_native.odin:32`), so an IPv6 /64 gets round the
  throttles. The UDP socket is IPv4 only, but the relay's listener may
  differ. Key by /64.
- The device identity is the raw peer key, and X25519 ignores bit 255
  (`proto/session.odin:339`), so a patched client can show the same key
  as a different device. Nothing in authorization uses it today, but
  anything keyed by `peer_key` can be got round. Reject a set top bit.
- `parse_request` trims header names, so `Header : v` is accepted, which
  is a smuggling surface behind a proxy that treats it differently.
  Chunked requests are refused, so no desync in practice.
- Unvalidated values from a hostile server that the UI uses later:
  `decode_blob_get_answer`, emoji `cell` and `size`, `Video_Codec(body[13])`.
- Windows (unverified): an oversized datagram may hit the generic
  `recv error` log branch, so unauthenticated packets can flood the log.

**S19. Client.**
- Desktop notifications (Linux) pass the peer's text unescaped to
  `org.freedesktop.Notifications.Notify` (`ui_tray.odin:403`,
  `traycon.h:2365`), and `sanitize_message` keeps `<` and `>`. Servers
  that advertise body markup show `<a href>` and `<img src=file://...>`.
  Escape `& < > "`.
- Saving a file: `os.rename` over a file created after the
  `os.exists` check (`files_io_native.odin:127`, use `link` and
  `unlink` or no-replace rename), the Mark of the Web is written after
  the rename and a failure is silently ignored (FAT, SMB; write it on
  the `.part`, and don't offer "Open" if it failed), and
  `sanitize_file_name` doesn't know `CONIN$`, `CONOUT$` or `COM¹`.
- `store_write` (`common/store_native.odin:35`) truncates and then
  writes. A crash loses `known_servers` pins, which then count as new,
  and an older file keeps its mode. Write a temp file, fsync, rename,
  chmod.
- A hostile viewer can report loss and drag a share's bitrate to
  `max_kbit/8` (`video_adapt.odin`): the worst viewer wins. Use a median.
- `v.received` and `v.lateness` grow without bound from a hostile
  server's speaker numbers (`audio/voice.odin:349`, `:651`), each with an
  Opus decoder and a ring. Accept only speakers in our room.
- Local sound files: `make([]f32, last_granule - pre_skip)` takes an
  unchecked granule position (`sound_store.odin:279`), and
  `ma_decode_memory` decodes the whole file before the 30 s trim
  (`yap_audio.c:249`).

**S20. Scripts and bots.**
- `yap.status` and `yap.notify` aren't attributed to a script, aren't
  sanitized, and `yap.status` has no rate limit (`api.odin:196`,
  `runtime.odin:459`), so a script can imitate the client ("Session
  expired", "Server key changed").
- The approval hash is FNV-64a (`catalog.odin:14`), `item_start`
  (`items.odin:396`) doesn't compare the bytes it starts with `it.hash`,
  and an entry without a `hash` in the config is unpinned. Use SHA-256
  over the exact bytes started.
- `runtime_add_source` keeps `servers` but not `scoped`, so replacing a
  script scoped to no servers makes it "all servers" (approval is still
  dropped).
- Coroutines aren't time-sliced: a loop in a coroutine runs for the
  full 200 ms on the UI thread each frame (about 5 fps, not a hang).
- `yap.log` and script errors reach the log with newlines and escapes.
- `script_name_ok` allows Windows device names and names that differ
  only in case.
- The WinHTTP backend parses URLs differently (`a:80@host`, `?` before
  the first `/`, a port cast to 16 bits), and libcurl allows an https to
  http redirect where WinHTTP doesn't. Reject userinfo and ports above
  65535 in `url_ok`, and keep any address filter on the same parse.
- Bots: `Bot_Commands_Set` can be sent at 40 a second, and each sends
  the full list (about 10 KB) to every connection
  (`server/bot_commands.odin:25`). The client sends any `/word` that
  isn't built in to a bot (`ui_message_menu.odin:373`, headless
  `commands.odin:938`), so a bot that registers `me` or `shrug` receives
  typed text. Show "sent to bot X", or require `bot:`.

**S21. Hardening.**
- Hardware decode (VA-API, D3D11VA, VideoToolbox) is preferred
  (`view.cpp:53`), so a hostile bitstream reaches the GPU driver.
  `YAP_VIDEO_SOFTWARE` is an opt-out; offer it as a setting. A separate
  sandboxed decoder process would be the stronger fix, since FFmpeg's
  H.264 and HEVC parsers are a recurring source of CVEs.
- Linux and macOS fall back to an unpinned system FFmpeg, including
  `/usr/local/lib` and `/opt/homebrew/lib` (`ffmpeg.cpp:61`), with no
  check for a patched release. The bundled build is pinned at 8.1.3-18.
- The web file sink (`web/files.js:137`) buffers a whole accepted file
  in browser memory.

### Order to fix

1. ~~S5, S3, S6, S7~~ (fixed 2026-11-04).
2. ~~S2 and S1~~ (fixed 2026-11-04; roaming after login is still open,
   see S2).
3. ~~S8, S11, S4, S9, S10~~ (fixed 2026-11-04, with what is left noted in each).
4. S12, S16 (S13, S14, S15 fixed 2026-11-04), then the Low items as they come.

## Checked and sound

Added by the second review:
- **Noise XX.** The server key is checked before the client's static key
  and password are sent. `ecdh` refuses an all-zero shared secret, so
  low-order points are covered. Send nonces are explicit, increment
  only after sealing, and stop at 2^60. msg1's padding is in the
  transcript. The cookie is HMAC-SHA256 cut to 16 bytes, compared in
  constant time, and doesn't amplify.
- **Decoders.** No `#no_bounds_check`. Every `unchecked_get` has a
  length check before it, and every allocation from a wire count is
  capped (roles, bot commands, emoji, bans, invites, history, search,
  group members). The stream window maths survives wrap-around.
- **Authorization.** All conversation handlers go through the member
  checks, and reaction, thread-root, forward and command-run ids are
  checked to belong to the conversation. `outranks` is enforced in the
  role, ban, mute, voice-move, password, disable, delete and bot-token
  handlers, and `account_password_set_finish` re-checks after hashing.
  Channel admins can only change name and topic. Personas are for bots
  only. Archived channels give no rights.
- **Media relay.** Sender ids are assigned by the server, and voice and
  video never cross rooms (`media_nack` re-checks the room).
- **Lua.** Only base, coroutine, table, string, math and utf8 are
  opened, with no `io`, `os`, `package`, `debug`, `dofile`,
  `string.dump` or `require`. The allocator caps at 16 MiB. Permissions
  are checked against the granted set in `dispatch`, and a changed hash
  clears them. A killed task survives neither `pcall` nor `resume`. The
  C bridge bounds depth and node count and passes strings with lengths.
- **Bot slash commands.** `invoker` is set by the server, the invoker
  needs write rights, the bot must be in the conversation, and two bots
  with the same name are never guessed between.
- **Web requests (scripts).** Only http and https, header injection
  checked, the 1 MiB cap is applied where bodies are appended, hard
  deadlines, and no TLS verification is turned off.
- **Build.** `fetch.sh`, `build.bat` and the macOS and Windows ffmpeg
  scripts check SHA-256 for opus, sqlite, webp, lua and ffmpeg. The
  macOS ffmpeg is built with `--disable-everything` and only the h264,
  hevc and av1 decoders. The client opens decoders by name. No
  `pull_request_target`, and `run:` steps don't use `${{ }}` with
  attacker text.
- **Web build.** No `innerHTML`, `eval` or `Function` on remote data,
  and the `postMessage` and service worker handlers only take digit-only
  ids.

From the first review:

- **Packet framing.** `packet_type` checks minimum lengths before every
  `unchecked_get`. Inits are padded to the size of the answer, so
  handshakes don't amplify. Unauthenticated garbage gets no answer.
- **The data path.** The AEAD is checked before the replay window is
  updated. The window maths stays in range. Counters at or over 2^60
  are refused.
- **What a connection may do before logging in.** In `handle_data`,
  only Ping, Leave, Stream and Stream_Ack. In `rpc_handle`, only
  Server_Info, Server_Icon, Auth_Login and Register. Unverified accounts
  get a short list. Connections that aren't logged in stay in
  `s.waiting`, out of everything that iterates `s.conns`, and the media
  thread only knows logged in ones.
- **Sessions.** Indexes are random. Bulk binding needs the same
  handshake-proven key and the conn_id. Supersede and "started over"
  act only on the same key.
- **Passwords.**
  - Argon2id (19 MiB, 2 passes) with a random salt.
  - Constant-time comparison.
  - Unknown usernames are hashed against nothing so they take the same
    time.
  - Passwords are wiped after use.
  - The first admin password is random and must be changed.
  - The server password is compared constant-time over SHA-256, and
    sent only after the client has checked the server's key.
- **Invite and verification codes.** From the CSPRNG with rejection
  sampling, about 49 bits. Email verification needs a trusted
  Authentication-Results header.
- **Permissions.** Every conversation handler goes through
  `conv_of_member` / `member_conv` / `msg_of_member` or checks
  membership. Search filters by membership. Edit is for the author
  only; delete is for the author or `Manage_Messages`. The `outranks`
  checks cover roles, disabling, passwords, deletion, devices and bot
  tokens. The Owner is protected.
- **SQL.** Every query is prepared with bound parameters. Full-text
  search input is quoted word by word.
- **Paths.** Blob paths are SHA-256 hex and upload files random hex.
  The relay serves an exact list of preloaded files, so no client
  string reaches the file system. On the client, downloaded names lose
  their directories, `.part` files are created exclusively, and the
  final rename never overwrites.
- **HTTP and WebSocket parsing.**
  - Request heads are capped at 8 KiB and bodies at 64 KiB.
  - Chunked bodies are refused.
  - WebSocket lengths are compared before the cast, unmasked frames and
    fragments are refused, and payloads go into fixed buffers.
  - Only constants and integers go into response headers.
  - Bot tokens are checked by the Noise handshake, not by comparing
    strings, and are never logged.
- **Image decoding on the server.** Only for the admin's emoji folder,
  never for uploads. Avatars are only parsed for their JPEG header.
- **Privacy.**
  - Email addresses go only to their own account.
  - Private rooms and calls are hidden in `sync_state`.
  - Browsing and member lists respect visibility.
  - Last seen is hidden unless both have posted in a shared DM.
- **Email.** Addresses and subjects can't carry CR/LF. IMAP uses only
  numeric UIDs. TLS is required except to localhost.
- **The client.**
  - Links open only for http/https without spaces or control
    characters, through argv or ShellExecute, never a shell.
  - Spoofed UDP is dropped by source and by Noise.
  - The client's identity and password are sent only after the key
    check.
  - libwebp is 1.6.0.
  - The service worker shows notifications as plain text.
  - Nothing in the web build uses `innerHTML` or `eval` on user content.

Left:
What I’d skip for now, given private servers with trusted users:

#4 (finding out which usernames exist): usernames aren’t secret among trusted users.
#5 (registration starvation): only matters if registration is open to the public.
#8 (CSP): needs careful testing with the wasm build for a second line of defence.
#14 (push SSRF): only blind, and only for people with an account.
The fingerprint prompt from #18.

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

Sizes as in `docs/extended`: S up to about 300 changed lines, M up to
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
- **Who can be blocked.** Only an address that has finished a handshake
  can have a password refused, so a forged address can't get somebody
  else blocked.
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
checked on Windows and macOS. A quota per account, and enforcing
`rate_kb`, are left for servers with users who aren't trusted.

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

- The screen share decoder (`src/video`, ffmpeg), which decodes video
  from other users. It deserves fuzzing.
- Fuzzing in general: `markdown.odin`, the rich text index maths, and
  `proto` decoders were read, not fuzzed.

## Checked and sound

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

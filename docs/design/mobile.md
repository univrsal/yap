# Mobile: feasibility, and Web Push first

The client runs in a phone's browser and fits a narrow screen, but it
isn't an app: it can't use the phone's push notifications, can't ring
for a call, and goes quiet once the browser puts the page away. This
looks at what a native port to Android and iOS would take, and plans the
first, cheapest step towards better phone support: Web Push for the web
client.

Part 2's decisions were settled as recommended (2026-10-15). When a
phase is done, what turned out differently is written under it ("*As
built:*").

## Part 1: how feasible is a native port?

In short: feasible. The client is in better shape for it than most,
thanks to the web build. iOS is possible too. The hard part isn't
drawing the client on a phone but the OS integration (push, incoming
calls), and that needs server work and a decision about who runs a push
gateway.

### The toolchain

Odin targets both. The compiler in use (`dev-2026-09`) has
`-subtarget:iphone`, `-subtarget:iphonesimulator` and
`-subtarget:android`. On iOS the client would be a static library,
linked into a small Xcode project with a Swift/ObjC host. Building needs
a Mac, and shipping an Apple developer account ($99 a year). Odin
compiles ahead of time, so Apple's ban on runtime code generation (JIT)
doesn't apply. Not yet tried: building the C dependencies (opus,
rnnoise, sqlite, libwebp, miniaudio) with the NDK and the iOS SDK.

### What the web build already did for us

The web build forced the client to split off its platform layer, and a
phone needs the same split:

- **Window and input**: `src/client/wglfw/` is a GLFW-shaped interface.
  The web half is about 240 lines, and a phone's would be about the same.
  The phone half would be written on **SDL3** (`vendor:sdl3`), which
  handles the iOS and Android app lifecycle, touch, the on-screen
  keyboard, and getting a Metal or GLES surface.
- **Drawing**: Android can use the GLES 3 shaders that WebGL 2 already
  uses (`render/gpu_gl.odin`, `#version 300 es`). iOS can use the Metal
  backend (`render/gpu_metal.odin`).
- **Touch**: gestures (a tap is a click, a long press a right click, a
  vertical drag scrolls, a sideways one drags) are already worked out in
  `web/touch.js` and `ui_touch_web.odin`. They'd be ported out of JS, but
  the design exists. So does the narrow layout.
- **Libraries**: miniaudio supports CoreAudio, AAudio and OpenSL. opus,
  rnnoise, sqlite, libwebp and stb are plain C. The UDP transport with
  noise is unchanged.
- **Left out at first**: hotkeys, tray, idle detection, the title bar,
  app-audio capture and screen sharing (`src/video`). Clipboard, the
  file and avatar pickers and opening links need small native bridges
  (UIPasteboard, UIDocumentPicker, and the Android equivalents).

### What's hard

1. **Text input.** The client draws its own text boxes, so it has to
   drive the on-screen keyboard itself. Typing letters is simple.
   Autocorrect, swipe typing, CJK composition, and keeping the cursor
   and selection in step with the keyboard are where the time goes.
   SDL3's text input helps but doesn't cover all of it. Screen readers
   (VoiceOver, TalkBack) would see nothing, as they do now.
2. **The background.** iOS suspends an app a few seconds after it leaves
   the screen, and the UDP connection goes with it. Voice may go on with
   the audio background mode while a call is running, but chat can't
   stay connected. On Android a foreground service (with its permanent
   notification) can keep the connection alive.
3. **Push notifications** need the server:
   - it has to keep device tokens (a new request) and send to APNs
     (HTTP/2, ES256 JWT) or FCM (HTTP v1, OAuth). The server already
     loads libcurl for email, and libcurl built with nghttp2 does HTTP/2.
   - **The catch:** APNs and FCM credentials belong to whoever publishes
     the app, so a self-hosted yap server can't push to the store's app
     itself. That takes a central push gateway, as Matrix (Sygnal) and
     Mastodon have: servers send "wake device X" to the gateway, which
     holds the Apple and Google keys. What goes through it should be
     minimal or encrypted; an iOS Notification Service Extension can
     decrypt on the phone.
   - On Android, UnifiedPush, or simply the foreground service, avoids
     Google altogether.
4. **Incoming calls.**
   - **iOS**: CallKit and PushKit. Since iOS 13 every VoIP push *must*
     report a call to CallKit at once, or iOS kills the app and in the
     end stops delivering its pushes. That suits DM calls (`calls.odin`)
     but not channel voice rooms, which shouldn't be passed off as phone
     calls.
   - **Android**: a self-managed `ConnectionService`, or more simply a
     high-priority push with a full-screen-intent notification and a
     `phoneCall` foreground service.
   - Both still need the gateway from 3.
5. **App Store review.** Apple's rules for user-generated content
   (guideline 1.2) ask for reporting content, blocking users and
   filtering. Accounts made by the server help, but reporting and
   blocking would have to be added. Android can be sideloaded; the Play
   Store mostly wants a privacy policy.

### Sizes and order

| Step | Size | What it gives |
| --- | --- | --- |
| Web Push for the web client (Part 2) | M | Notifications on both phones; self-hosting keeps working |
| Android app (SDL3 window layer, stubs, keyboard, foreground service) | L | A native app; a background connection without Google |
| iOS app (Xcode host, Metal, keyboard, audio session) | L, plus the Mac and Apple account | A native app, connected only while shown or in a call |
| Native push, CallKit / ConnectionService, a push gateway | XL, mostly server and infrastructure | Real pushes, and calls that ring |

Web Push first: it covers most of what notifications are wanted for, at
a fraction of the cost. Then Android, which is easy to hand out and
needs no gateway. iOS only once it's decided whether to run a central
push gateway: without one, a native iOS app gives little beyond the PWA
other than voice in the background.

## Part 2: Web Push

### Why it fits

The web client is already an installable PWA (`web/manifest.webmanifest`).
Web Push is supported by Chrome and Firefox on Android and on desktops,
and by Safari on iOS 16.4+ **once the PWA is added to the home screen**
(not in a Safari tab). Unlike APNs and FCM it needs no publisher
account: every server makes its own VAPID key pair, and the push
services (Google's, Mozilla's, Apple's) accept a message from whoever
holds the key the browser subscribed with. Self-hosting keeps working
with no gateway. Messages are encrypted for the browser (RFC 8291), so
the push service sees only the size and the time.

It also fixes something today: `yap_notify` in `web/shell.c` uses
`new Notification(...)`, which Chrome on Android refuses ("Illegal
constructor"). Phones need `ServiceWorkerRegistration.showNotification`,
so on Android the web client shows no notifications at all right now.

### How it works

1. The server makes a VAPID key pair (P-256) on its first run and keeps
   it in `config.json`, next to its noise key. Server_Info carries the
   public half, which also says that the server pushes.
2. The browser registers a service worker (`web/sw.js`, served by the
   relay from `web_dir` like the rest) and, when the user turns push on
   in settings (a tap: browsers only ask for permission during one),
   subscribes with the server's key. The subscription (an endpoint URL
   and two keys, `p256dh` and `auth`) is sent to the server with a new
   request and kept per account in a new table. One account may have
   many (a phone, a laptop).
3. When a message would notify someone (the same rules as the desktop
   notice and the email digest's "missed": everything in a conversation
   set to All, mentions in one set to Mentions, DMs counted as
   mentions) and they aren't there to see it, the server encrypts a
   small JSON payload for each of their subscriptions and POSTs it to
   the endpoint with libcurl, from the email thread's kind of worker so
   the loop never waits on the network.
4. The service worker gets a `push` event and shows the notification.
   Tapping it focuses an open client or opens one, at that conversation.
5. An endpoint that answers 404 or 410 is gone (the user cleared the
   site's data, or unsubscribed); its row is deleted.

### Pieces

**Crypto, all in `core:crypto`** (no OpenSSL): ECDSA P-256 for the
VAPID JWT (`ecdsa`), ECDH P-256 for the message key (`ecdh`), HKDF-SHA256
(`hkdf`), AES-128-GCM (`aead`/`aes`). RFC 8291 appendix A has a full
test vector, and RFC 8188 its content coding, so the encryption can be
unit-tested exactly before any browser is involved.

**More than one server.** A browser allows one push subscription per
service-worker registration, and each subscription is tied to one VAPID
key. With the server rail, one web client talks to many servers, each
with its own key. So the client registers the same `sw.js` once per
server, under its own scope (`./push/<server>/`); a worker at the root
may register narrower scopes beneath it. Each registration has its own
subscription. The notifications all go through the same worker code.

**Being there.** Push is for when the person isn't looking. The server
already knows who is connected and who is away (`activity.odin`). The
rule proposed: push when the account has no connection, or when every
connection it has is idle (the client reports idle; a phone's hidden
page counts as idle). See D1.

**Not too many.** One notification per conversation at a time: the
push's `Topic` header (the conversation) makes the push service replace
one still waiting, and the notification's `tag` makes the phone replace
the one shown, with a count ("3 new messages"). Urgency `high` for DMs,
mentions and calls, `normal` for the rest. TTL a day.

**What's sent**: `{server, conv, title, body, kind, count}` with the
body quoted as the digest quotes it (`digest_quote`), cut to fit a push
(about 3 KB at most after encryption). See D2.

### Phases

| # | Change | Size | Where | Depends on | Status |
| --- | --- | --- | --- | --- | --- |
| 1 | VAPID key, RFC 8291 encryption, sending with libcurl | M | server | - | done (2026-10-15) |
| 2 | Subscriptions: request, table, Server_Info key | S | protocol, schema | 1 | done (2026-10-15) |
| 3 | Deciding to push: the notify rules, presence, Topic and tags | M | server | 2 | done (2026-10-15) |
| 4 | Service worker, settings toggle, subscribing per server, opening a conversation from a tap | M | web client | 2 | done (2026-10-15) |
| 5 | Calls: a DM call pushes "X is calling", until answered or ended | S | server, web client | 3, 4 | done (2026-10-15) |

**1. Sending.** `server/push.odin`: the VAPID key read from or written
to `config.json` (`push.vapid_private`, plus `push.subject`, a `mailto:`
or `https:` contact the push services ask for; default from
`email.from` if set). `push_encrypt` (RFC 8291 / aes128gcm) with the
appendix A vector as its test. `push_send` on a worker thread with its
own libcurl handle (curl loaded as email loads it): POST with `TTL`,
`Urgency`, `Topic`, `Content-Encoding: aes128gcm` and `Authorization:
vapid t=<JWT>,k=<key>`; the JWT (aud = the endpoint's origin, exp 12
hours) cached per origin. Results come back to the loop as
gone/failed/sent. A headless `/push-test` to try it by hand.

*As built:* `push.odin` (config, thread, POST), `push_crypto.odin`
(RFC 8291, VAPID JWT, keys), `push_test.odin` (RFC 8291 appendix A
exactly; the JWT checked with `ecdsa.verify_raw`). Config is
`"push": {"enabled": true, "vapid_key": ..., "subject": ""}`: on by
default, the key made on the first run or written back into an older
config, the subject `mailto:` the email address, or the project's page
without one. The curl table gained `easy_getinfo` and the POST options;
`curl_load` takes what it's for, for its log lines. The loop has a
`Push` phase (`push_sync`), which in this phase only reads the results.
Instead of a headless command there's `yap-server push test [<endpoint>
<p256dh> <auth>] [config.json]`, which prints the VAPID public key and
sends one push. Tried end to end against Mozilla's real push service,
with a Python stand-in for the browser that subscribes over autopush's
WebSocket and decrypts what arrives: delivered and decrypted.

**2. Subscriptions.** `proto/push.odin`: `Push_Subscribe [endpoint
string][p256dh 65][auth 16]` and `Push_Unsubscribe [endpoint string]`;
endpoints must be `https://` and are kept as given. Table
`push_subscriptions (account, endpoint unique, p256dh, auth, created,
last_ok)`; schema step. Deleting an account deletes its rows. Server_Info
gains a trailing VAPID public key (empty: this server doesn't push).
Tests as for the other requests (`auth_test.odin`'s op list, the schema
upgrade test's table list).

*As built:* `proto/push.odin`, ops 0x0026 and 0x0027.
`Push_Unsubscribe` takes no body: a subscription is the device's (the
connection's key), one per device, so it forgets this device's. Schema
25: `push_subs (id, device REFERENCES devices(key) ON DELETE CASCADE,
account, endpoint UNIQUE, p256dh, auth, created)`, so logging out,
revoking a device, a password change that drops the others and deleting
the account all take the subscriptions with them, without code of their
own. Nothing is kept in memory: `push_subs_of` reads the table when
there's something to send. A server without push answers
`Push_Subscribe` with `Closed`. `push_sync` (in `push_subs.odin`)
deletes what the push service says is gone. Tested in
`test_push_subscriptions`.

**3. Deciding.** Hooked where a message is delivered: for each member
who would be told (the digest's rules, `Notify_Level`), with
subscriptions and not there (D1), queue a push per subscription.
Collapsing per conversation as above. Read elsewhere (the person reads
the conversation on their laptop): push a `close` for that tag, so the
phone takes the notification down (cheap, and what people expect from
chat apps). See D3.

*As built:* `push_notify.odin`, called from `msg_post` and
`msg_forward` after delivery. Two things differ from the plan:

- **Who is pushed what** follows the desktop's notices
  (`ui_notices.odin`), not the digest's "missed": a DM to the other
  one, a mention to each mentioned member, unless the conversation is
  set to None. Not every message of a channel set to All: that's what
  every channel starts as, the desktop doesn't notify them either, and
  a phone buzzing for each would soon have push turned off. A per-account
  choice like the digest's could add it later.
- **D3 isn't done with pushes.** A push that shows no notification is
  punished: Safari revokes the subscription after a few, Firefox expires
  it once a quota of them runs out, and Chrome may show a generic "this
  site has been updated in the background". So a `close` push would
  break the very subscriptions it's for. Instead, the service worker
  takes a conversation's notification down when it's read on that
  device, and all of them when the client is opened (phase 4).

Presence is `push_away`: no connection, or every one idle. The payload
is JSON (`Push_Payload`: kind, server name, conv, msg, title, body), the
body quoted by `digest_quote`, or empty for an account whose setting
`push/text` is `hidden` (D2; kept in `Account.push_hide` like the
digest's choice). Topic `c<conv>`, urgency high, TTL a day. Tested in
`test_push_messages`.

**4. The web client.** `web/sw.js`: `push` shows the notification
(`showNotification` with tag, icon, badge, `data`), `notificationclick`
focuses a client window and posts it the conversation, or opens
`./#<server>/<conv>`; the client reads that at start. `yap_notify` moves
to `registration.showNotification` so the in-page notices also work on
Android. Settings → Notifications gets "Push notifications on this
device" (web only; shown when the server has a key), which asks for
permission, subscribes and sends the subscription; turning it off
unsubscribes and tells the server. On iOS the row says to add the app
to the home screen first, when it's in a Safari tab
(`navigator.standalone` is false). The relay serves `sw.js` with
`Content-Type: text/javascript` and `Cache-Control: no-cache`, so new
builds take effect.

*As built:*

- `web/push.js` (pre-js): `Module.yapPush`, a small state machine per
  server (off, working, on, blocked, failed, unsupported, "add to home
  screen") that the client polls each frame; `web/sw.js` shows pushes,
  one notification per conversation (tag `c<conv>`) with a count, and
  on a tap focuses an open page and posts it `{yapOpen}`, or opens
  `./#open=<id>/<conv>/<msg>`. A server's scope is `push/<its address in
  hex>/`.
- `src/client/ui_push_web.odin` (stubs in `ui_push_other.odin`):
  `push_frame` asks the browser what it has for each server's key once
  logged in (a subscription made with an older key is replaced), hands
  new subscriptions and unsubscriptions to the server
  (`conn/push.odin`), goes to a tapped notification's message once its
  server is logged in, and takes a conversation's notification down
  when it's read here (D3, locally). The account settings get "Push
  notifications: Off / On this device" (web only, when the server has a
  key and the browser can) and "Pushes show: The message / Only who
  wrote" (`push/text`).
- **Out of sight** needed a protocol bit: idle also makes everyone see
  you as Away, and a hidden tab shouldn't. `Idle_Set`'s byte is now
  flags, bit 0 idle, bit 1 hidden; the server keeps `Conn.hidden`, which
  only push looks at. An older server takes bit 1 as idle.
- *Fixed after the user's first try on an iPhone:* the hidden bit was
  only worked out in the frame loop (`activity_step`), which a hidden
  page doesn't run, so the server never heard it and took the page to be
  looking until its session timed out (30 s after iOS suspended it). Now
  `web/background.js` calls `web_visibility` on `visibilitychange` and
  `pagehide`, which tells the servers at once, before the phone suspends
  the page; `web_tick` keeps it up too.
- *Added after the first phone test:* a number on the installed app's
  icon (the Badging API: iOS 16.4+ home-screen apps, macOS, Windows;
  not Android), unread DMs and mentions from every server, as the
  client counts them for its title (`ui.mentions`). The page sets it
  once a server has said what's unread; while the app is closed,
  `sw.js` adds one for each DM or mention pushed. Both keep it in the
  Cache storage (`yap-badge`, key `push/badge`), so the worker counts on
  from the page's number. Tried in headless Chromium: 4 unread with the
  app open, two pushes while closed made it 6, reopening counted 6.
- In-page notices (`yap_notify`) fall back to a service worker under
  `push/page/` where `new Notification` throws (Chrome on Android), and
  are skipped while the page is hidden and push is on, since the push
  says the same.
- `sw.js` is in the relay's file list, `web/build.sh`, `package.sh` and
  the CI artifact list.

Tried end to end in headless Chromium against a local server: logging
in, turning push on (a real FCM subscription, handed to the server),
closing the page, a DM from a headless client: the server's POST was
taken (201) and the service worker showed "bot2 messaged you" with the
text; opening the page from the notification's link went to that DM
and took the notification down. The settings rows switch push off and
on and keep `push/text`. Not tried: a real phone (Android Chrome, iOS
home-screen app), tapping a notification itself (only the link it
opens), Firefox. A test pitfall: CDP's permission grant ends with the
DevTools session, and Chrome then drops the subscription (the push
service answers 410).

**5. Calls.** A DM call (`calls.odin`) pushes "X is calling" with
`requireInteraction` and urgency high, tag per call; ending or answering
it pushes a `close`. It doesn't ring like a phone call (no web API does
that), but it shows up at once on the lock screen with a sound.

*As built:* no `close` (see phase 3); instead each push of a call
shares its tag (`call<id>`) and replaces the last: "X is calling you"
(urgency high, TTL 30 s, `ring`: stays up until dealt with), then
"Missed call from X", or quietly "Answered on another device." /
"Declined." to every device but the one that did it (subscriptions now
know their device). Two server changes were needed for a call to be
answerable from a push at all: a callee with no connection but with
push now rings (before, the call was a missed one at once), and a
connection that logs in while a call rings for it is told
(`calls_conn_seen`, after the login sync). The page's own call notice
is skipped while push covers it. Tested in `test_push_calls`, and in
headless Chromium: the ring shows about a second after the call starts
and turns into the missed call when the caller hangs up; a page opened
during the ring shows the incoming call with its buttons. Headless
Chromium reports `requireInteraction` as false, so whether the ring
stays up is for a real phone to show.

### Decisions

| # | Question | Recommended | Settled |
| --- | --- | --- | --- |
| D1 | When to push | No connection, or every connection idle (a hidden phone page counts as idle) | as recommended |
| D2 | What a push shows | The sender and the quoted text, as desktop notices do; a per-account "hide message text in pushes" setting for those who'd rather not | as recommended |
| D3 | Taking notifications down when read elsewhere | Yes (a `close` push per tag) | as recommended; built locally instead, see phase 3 |
| D4 | Push and email digests together | Independent: a digest still goes out after `digest_minutes`, covering what pushes already showed | as recommended |
| D5 | On by default once permission is given | Off until turned on per device in settings; the first-tap permission prompt in `yap_notify` stays for in-page notices only | as recommended |

### Testing

- Encryption against RFC 8291 appendix A, the JWT against `ecdsa.verify`.
- End to end without a phone: headless Chromium (as in the other web
  tests) subscribes against a local server. Chrome's endpoint is FCM,
  so the server needs internet; or use a local fake push service that
  decrypts with the subscription's private key to check the payload.
- Then a real Android phone in Chrome, and an iPhone with the PWA added
  to the home screen. Both need HTTPS in front of the relay.

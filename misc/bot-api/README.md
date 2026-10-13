# Bot API: plan

A way for programs to use a yap server: bots that answer commands,
post from a cron job, bridge to another chat, moderate. Nothing here is
built yet. As in `docs/next`, each phase is its own commit or series of
commits; what turns out differently is written under it when it's done
("*As built:*"), and the open questions are in the Decisions table at
the end.

Sizes as in `docs/extended`: S up to about 300 changed lines, M up to
1000, L up to 2500, XL more.

## What we start from

- **The protocol can't be the API.** A client talks Noise XX over UDP
  (`proto/wire.odin`, `session.odin`), with a reliable stream of its own
  on top (`proto/stream.odin`), binary requests and events on that
  (`proto/rpc.odin`), state snapshots that have to be acked
  (`proto/messages.odin`), rekeying every two minutes and a second
  "bulk" link. A bot author in Python or JavaScript would have to
  rebuild all of that before saying hello. The web client only gets
  around UDP through the relay (`server/relay.odin`), and still does
  the rest itself.
- **Logging in is already device based.** A device is a static key; it
  logs in once with username and password, and from then on its key is
  enough (`proto/accounts.odin`, `server/auth.odin`). Devices are listed
  and revoked per account (Device_List, Device_Revoke). That's most of
  what an API token needs to be.
- **Permissions are already per account, from roles** (`proto/roles.odin`,
  `can` in `server/accounts.odin`). A bot needs no permission model of
  its own: it's an account with roles like any other.
- **There's a headless client already**: `src/stress/bot.odin` (~480
  lines) does the handshake, the stream, acking snapshots and voice,
  without `client:audio`/`render`/`platform`, which `client/conn` can't
  do without.
- **The server speaks HTTP and WebSockets already, minimally**: the relay
  parses requests, serves the web build and frames WebSockets
  (`server/websocket.odin`). No TLS: that's left to a reverse proxy
  today.
- **The server has no rate limit on posting**; only on passwords and
  attachments.

## Goals and non-goals

From the notes:

- **Simple from any language with no setup.** HTTP and JSON: `curl`
  works, Python's `urllib`/`requests`, Node's built-in `fetch` and
  `WebSocket`, Go's standard library. No SDK needed, no crypto, no
  binary encoding. A client library may come later, but nothing should
  need one.
- **Controls an account.** A bot does what its account may do, through
  the same requests a client sends, checked by the same `can`. The API
  adds no powers.
- **Getting access is getting an account.** A bot account, made by an
  admin, given roles as anyone is.
- **Discord: borrow the shape, not the wire.** See below and D1.

Not in the first version: voice, calls and screen sharing (they need
Opus and real-time UDP; see "Later"), file offers in DMs (peer to peer,
`files.odin`), registering, invites, email, purging, server settings and
emoji uploads. All of those are reachable later through the same
mechanism, they're just not needed to write a useful bot.

## Discord compatibility

Being compatible enough that discord.py or discord.js run against yap
unchanged isn't realistic:

- The libraries hard-code a lot of Discord: the gateway's opcodes,
  heartbeats, intents, sharding, `READY` carrying guilds, `GUILD_CREATE`
  per guild, snowflakes whose bits are a timestamp, permission
  overwrites, embeds, interactions and components, rate limit buckets
  in headers. Faking enough of that not to crash them means inventing a
  guild yap doesn't have, and every library version can break it again.
- yap's concepts don't line up one to one: DMs aren't in a guild,
  channels have no categories but a voice room each, there's one
  server per address, a message can be a file offer, roles only grow
  permissions (no deny), threads hang off a message.
- Most of a Discord bot is commands, embeds and buttons, which yap
  doesn't have, so a "compatible" bot would mostly not work anyway.

What is cheap and does help someone moving a bot over:

- **The same model**: a REST API for doing things, and one WebSocket
  ("gateway") for being told things, with `Authorization: Bot <token>`.
  Anyone who has written a Discord bot knows where to look.
- **Discord's names where the thing is the same**: `content`, `author`,
  `timestamp`, `edited_timestamp`, `attachments`, `reactions`,
  `pinned`, `MESSAGE_CREATE`/`MESSAGE_UPDATE`/`MESSAGE_DELETE`,
  `MESSAGE_REACTION_ADD`, `TYPING_START`, `READY`. Ids as strings, as
  Discord has them (and because u64s don't survive JavaScript's
  numbers).
- A porting page (Discord concept → yap concept) isn't written for
  now (D1).

So: Discord-shaped, not Discord-compatible (D1).

## Architecture

### Where the API runs: a gateway that is a client

Recommended: the API is served by a **gateway**, a part of yap-server
that runs on threads of its own (as the relay does) and is, to the
server, nothing but more clients. For each bot token in use it keeps a
connection to the server over loopback, exactly as a client would
(handshake, stream, snapshots, rekeys), and turns HTTP requests into
protocol requests and protocol events into JSON.

	bot ──HTTP/WS, JSON──> gateway ──Noise/UDP, loopback──> server loop
	                       (threads)                        (unchanged)

Why this way:

- **The server's core doesn't change.** Auth, permissions, membership,
  every request handler and every event stay as they are and are
  exercised exactly as for a person's client: a bot can't do anything a
  client couldn't, by construction, and the API can't drift from the
  protocol in what it allows.
- The server loop stays single threaded on its UDP socket; HTTP's
  blocking sockets live on the gateway's threads, as the relay's do.
- **It could run anywhere.** Being just a client, the same gateway can
  be built as its own program (`yap-gateway --server chat.example:7777`)
  and run next to a bot, against a server that doesn't enable the API.
  That's free, so worth keeping possible (D5).


### Tokens are device keys

A token *is* a device's private key: `yap_` + base64url of 32 random
bytes. The gateway derives the public key from it and handshakes with
it; the server sees a device it knows, as it always does.

- The gateway stores nothing: no token table, no database. A request
  with a token it has no connection for opens one.
- The server stores only the public key, as for every device. Tokens
  show in the account's device list (agent "yap API"), and Device_Revoke
  takes one away, from the account itself or by an admin. Changing the
  password logs them out as it does other devices, unless they're a bot
  account's (which has no password).
- Getting a token for an ordinary account: `POST /api/v1/login` with
  username and password; the gateway makes a key, logs in with it
  (Auth_Login, as a client does) and answers with the token. That's the
  "login like a normal account" from the notes; whether ordinary
  accounts may do it is D3.
- Getting a token for a bot account: the admin's client makes the key,
  sends the server only its public half, and shows the token once
  (phase 1). The server never sees a bot's token.

### Connections the gateway keeps

One per token in use, made on the first request and kept while used:

- **While the bot has the event WebSocket open**: kept, for as long as
  it's open.
- **REST only** (a cron job posting once an hour): kept for a few
  minutes after the last request (GATEWAY_IDLE, say 5 minutes), then
  closed, so a token used once doesn't hold a connection for good.
  The next request opens it again, which costs a handshake and a login
  sync: well under a second on loopback.
- A request that arrives while the connection is still syncing waits
  for Sync_End.
- A bound on connections (api.max_connections), as `max_sessions`
  bounds the server's.

### What the gateway keeps for each connection

The protocol tells a client everything at login (Sync_Begin..Sync_End:
self, roles, accounts, conversations, emoji) and then only changes; it
has no "list the accounts" request. So the gateway keeps a small model
per connection, much like `client/conn`'s View but without UI: self,
server info, roles, accounts, conversations with read state, who's
online (from snapshots). GET requests for these are answered from it;
history, search, members, pins are asked of the server.

It also keeps where the event stream is (a sequence number per event)
and the last few hundred events, so a bot whose WebSocket dropped can
resume without missing anything (`RESUME`, as Discord does), as long as
the connection behind it is still there.

## The API

Versioned under `/api/v1/`. JSON in and out (`Content-Type:
application/json`), UTF-8, ids as strings, times as ISO 8601 UTC (as
Discord) or Unix milliseconds (as yap) - D4. Auth on every request but
`/login` and `/server`: `Authorization: Bot <token>`.

### Errors

The protocol's statuses (`proto.Status`) map to HTTP ones, with a JSON
body that names the status:

| Status | HTTP |
| --- | --- |
| Ok | 200 (201 for something made, 204 for nothing to say) |
| Invalid | 400 |
| Unauthenticated | 401 |
| Denied | 403 |
| Not_Found | 404 |
| Conflict | 409 |
| Too_Large | 413 |
| Rate_Limited | 429, with `Retry-After` |
| Wrong_Password | 401 |
| Closed | 410 |
| Internal, Reset | 500, 503 |

	{"error": "denied", "message": "You can't post in this channel."}

### Endpoints (v1)

| Method | Path | Protocol | Notes |
| --- | --- | --- | --- |
| POST | `/login` | Auth_Login | `{username, password, device}` → `{token}` (D3) |
| POST | `/logout` | Auth_Logout | the token stops working |
| GET | `/server` | Server_Info | no token needed |
| GET | `/me` | model (Self) | account, permissions, flags |
| PATCH | `/me` | Profile_Set | display name, status, avatar (upload id) |
| PUT | `/me/activity` | Activity_Set | online, away, busy, offline |
| GET | `/accounts`, `/accounts/{id}` | model | |
| GET | `/roles` | model | |
| GET | `/convs` | model | the conversations the account is in |
| GET | `/convs/browse?q=` | Conv_Browse | channels there are to join |
| PUT/DELETE | `/convs/{id}/subscription` | Conv_Subscribe | |
| GET | `/convs/{id}/members` | Conv_Members | |
| POST | `/dms` | DM_Open | `{account}` → the conversation |
| GET | `/convs/{id}/messages` | Msg_History | `before`/`after`/`around`, `limit`, `thread` |
| POST | `/convs/{id}/messages` | Msg_Post | `{content, thread, attachments, nonce}` |
| GET | `/convs/{id}/pins` | Pins_Get | |
| POST | `/convs/{id}/read` | Mark_Read | `{message}` |
| POST | `/convs/{id}/typing` | Typing (datagram) | |
| PATCH | `/messages/{id}` | Msg_Edit | |
| DELETE | `/messages/{id}` | Msg_Delete | |
| PUT/DELETE | `/messages/{id}/pin` | Msg_Pin | |
| PUT/DELETE | `/messages/{id}/reactions/{emoji}` | Msg_React | emoji URL-encoded, or `:name:` |
| GET | `/messages/{id}/reactions/{emoji}` | Reactors_Get | |
| POST | `/messages/{id}/forward` | Msg_Forward | |
| GET | `/search?q=` | Msg_Search | |
| POST | `/uploads?name=` | Attach_Put + chunks | raw body → `{id}` to post with |
| GET | `/attachments/{blob}` | Attach_Get + chunks | the file's bytes |
| GET | `/blobs/{blob}` | Blob_Get + chunks | avatars, emoji, the server icon |

The admin's requests (Conv_Create/Update/Delete, Conv_Member_Set,
Role_*, Account_Roles_Set, Account_Disable, Account_Create, Purge) are
phase 10: a moderation bot needs them, a first bot doesn't.

`nonce` on a post is optional: given, the gateway hashes it to the
protocol's u64 nonce, so a bot that retries a post after a timeout
doesn't post twice (Msg_Post already deduplicates by nonce). Not given,
the gateway picks one.

`content` is the text as a person would type it, markdown and all
(`docs/markdown`); mentions as `@username`, as typed, which the server
already resolves (`mentions.odin`).

### Messages as JSON

	{
	  "id": "48213",
	  "conv_id": "7",
	  "author": {"id": "12", "username": "weatherbot", "display": "Weather", "bot": true},
	  "timestamp": "2026-10-11T09:14:03.120Z",
	  "edited_timestamp": null,
	  "kind": "text",
	  "content": "Rain from 3pm.",
	  "thread": null,
	  "attachments": [{"id": "9911", "name": "radar.webp", "size": 48211}],
	  "reactions": [{"emoji": "👍", "count": 3, "me": false}],
	  "pinned": false,
	  "deleted": false,
	  "forwarded": null,
	  "replies": null
	}

Other records the same way, one per protocol record: account, role,
conversation, server. The field lists come straight from the decoders
in `proto/`, so the JSON writers sit next to them or in the gateway
(phase 3 decides).

### Events: the WebSocket

`GET /api/v1/events` upgrades to a WebSocket; the token in the
`Authorization` header, or as `?token=` for clients that can't set
headers (browsers). Text frames, one JSON object each:

	{"t": "MESSAGE_CREATE", "s": 118, "d": {...a message...}}

- First, `READY`: me, the server, roles, accounts, conversations,
  who's online: what the model has, so a bot needn't GET it all.
- Then events as they come, each with its sequence number `s`.
- The bot sends nothing but, optionally, `{"op": "resume", "s": 117}`
  as its first frame after reconnecting: the gateway replays what came
  after, or answers `INVALID_SESSION` if it can't (the connection
  behind it closed, or too much happened), and the bot starts from a
  new `READY`.
- WebSocket pings keep it open; no heartbeat of our own (Discord has
  one, but WebSocket pings do the job and every library answers them).

| Event | From |
| --- | --- |
| READY | Sync_Begin..Sync_End |
| MESSAGE_CREATE | Msg_New |
| MESSAGE_UPDATE | Msg_Changed (edited, pinned, unpinned) |
| MESSAGE_DELETE | Msg_Changed with the Deleted flag |
| MESSAGE_REACTION_ADD / _REMOVE | Reaction_Changed |
| MESSAGES_PURGED | Msgs_Purged |
| TYPING_START | Typing |
| CONV_UPDATE, CONV_DELETE | Conv_Changed, Conv_Removed |
| READ_UPDATE | Read_Changed |
| ACCOUNT_UPDATE | Account_Changed |
| ROLE_UPDATE, ROLE_DELETE | Role_Changed, Role_Removed |
| PRESENCE_UPDATE | a snapshot that differs from the last (online, voice room) |
| SERVER_UPDATE | Server_Info |
| SELF_UPDATE | Self (permissions changed) |
| LOGGED_OUT | Logged_Out: the token was revoked, the account disabled or deleted |

An event the gateway doesn't know the op of is dropped, as a client
drops one.

Only one event socket per token at a time; a second replaces the first
(it gets a close frame), so a bot restarted before its old process died
doesn't get everything twice.

## Bot accounts

An account flag, `Account_Flag.Bot` (bit 5; the flags are a u8 with
room for three more, stored in `accounts.flags` already, so no schema
step for the flag itself).

- **Made by an admin** (Manage_Accounts), in Manage → Accounts, "New
  bot": username, display name. The admin's client makes a device key
  and sends its public half; the server makes the account with the Bot
  flag and that device. The client shows the token once, to copy.
  "New token" on a bot adds another (the old ones stay until revoked;
  D6), and its device list is where tokens are revoked.
- **No password.** It can't log in with Auth_Login, isn't asked to
  change one (no Must_Change), and Password_Change refuses.
- **Roles like anyone.** What it may do is its roles' permissions; an
  admin gives it a role as they would a person. Nothing new in
  `can`. It may never be the owner.
- **Shown as a bot**: a small "BOT" tag by its name in chat, member
  lists and its profile card, in both clients, so nobody takes it for a
  person. Account records carry the flags already, so clients learn it
  for free.
- **Left out of what's for people**: email digests (it has no address
  anyway), idle and away, invite/registration counts, the "who's here"
  of voice rooms (it can't join one in v1: Voice_Join and Call_* answer
  Denied).
- **Deleted like any account** (Account_Delete), its messages kept.

Can a bot be DM'd? Yes: bots that answer in DMs are a normal thing,
and DMs already work between any two accounts.

## Limits

A token is as good as a logged-in client, and a loop in a bot can post
a thousand messages a second. The server has no limit on posting
today, so:

- **In the gateway**: requests per token per second (a token bucket,
  e.g. 10/s, burst 30), answered 429 with `Retry-After`. Cheap, and
  enough to stop accidents.
- **In the server**, later and for everyone: a post rate per account in
  `messages.odin` (Rate_Limited), which then also covers a person's
  runaway script with a native client. Its own small item (D7).
- The gateway caps request bodies (an upload streams; the rest at
  64 KiB), connections, and event sockets per token (one).

## Security

- **Plain HTTP**, like the relay; TLS from a reverse proxy in front
  (Caddy, nginx), as people serving the web client do already. The
  docs say so loudly, and the gateway refuses `/login` (a password!)
  from anywhere but loopback over plain HTTP unless the config says
  it's behind a proxy (`api.behind_proxy`, trusting
  `X-Forwarded-Proto`). Tokens are as sensitive, but there's no
  stopping a careless setup; passwords at least have a safer path.
- The token is the device key, so a stolen one is a stolen device:
  revoked the same way, from the device list.
- The gateway only connects to its own server (as the relay only
  relays to it), so it can't be pointed at other hosts.
- `/login` is slowed down as logging in is today: it goes through the
  same hashing queue and lockouts in `auth.odin`.

## Config

	"api": {
	    "enabled": false,
	    "behind_proxy": false,
	    "max_connections": 64,
	    "rate": 10, "burst": 30
	}

It's always on the relay's port, under `/api/` (D2): one HTTP port, one
proxy rule and one certificate for the web client and the API, and no
second HTTP parser. The relay's request handling (`relay.odin`) sends
`/api/` elsewhere and serves what it does now otherwise. Any account may
get a token with `/login`, with no setting to turn that off (D3).

## Phases

| # | Change | Size | Where | Depends on | Status |
| --- | --- | --- | --- | --- | --- |
| 1 | Bot accounts: the flag, making them, tokens, the BOT tag | M | protocol, server, client, web | - | done (2026-10-11) |
| 2 | A headless client package, from `stress/bot.odin` | M | common, stress | - | done (2026-10-12) |
| 3 | The gateway: HTTP, tokens, connections, `/login`, `/me`, `/server`, errors | L | server | 2 | done (2026-10-12) |
| 4 | The model, and reading: accounts, roles, convs, history, pins, search | M | server (gateway) | 3 | done (2026-10-12) |
| 5 | Writing: post, edit, delete, react, pin, read, typing, DMs, subscribe, profile | M | server (gateway) | 4 | done (2026-10-12) |
| 6 | Events: the WebSocket, READY, events, resume | M | server (gateway) | 4 | done (2026-10-12) |
| 7 | Files: uploads, attachments, blobs | M | server (gateway) | 5 | done (2026-10-12) |
| 8 | Limits and the config, hardening | S | server | 3 | done (2026-10-12) |
| 9 | Docs and examples: the reference in `API.md`, Python/Node/curl bots | M | docs | 5, 6 | done (2026-10-12) |
| 10 | Admin requests: channels, roles, members, disabling, purging | M | server (gateway) | 5 | later |

Why this order:

- **1 first and alone**: it's the only part that touches the protocol
  and the clients, it's useful as it is (bots can be made and get a
  token, and the gateway has something to test with), and it's small.
- **2 before 3**: the gateway's correctness rests on the headless
  client (rekeys, reconnects, snapshots acked, the stream's pacing).
  Pulling it out of `stress` gives it tests of its own and keeps one
  copy; `stress` then uses it too.
- **3–7** in the order a bot needs them: a token that works, then
  reading, then writing, then being told; files last as they're the
  most code for the least use.
- **8** can go any time after 3, but must be in before anyone runs it
  on a real server.
- **9** is part of the feature, not an afterthought: "simple from any
  language" is only true if there's a page that shows it, with a
  20-line bot in each language.

### 1. Bot accounts

- `proto.Account_Flag.Bot`; a request `Bot_Create [username str8]
  [display str8][key 32] -> [account u32]` and `Bot_Token_Add [account
  u32][key 32]` (Manage_Accounts), or Account_Create grown at its end
  with a flag and a key (D6). Device_List on another account, for
  admins, so a bot's tokens can be listed and revoked: today it only
  lists one's own.
- Server: Auth_Login and Password_Change refuse a bot; Voice_Join and
  Call_Start Denied; digests skip it.
- Client and web: "New bot" in the Manage window, the token dialog
  (copy, shown once, a warning), the BOT tag wherever a name with
  roles' colours is drawn, a bot's tokens under it.
- Tests: in `auth_test.odin` (bot can't log in with a password, a
  bot's key logs in by itself, revoking), `test_login`'s op list.

*As built:* new requests (D6), both naming the token's device:
`Bot_Create [username str8][display str8][key 32][device str8] ->
[account u32]` (0x1E) and `Bot_Token_Add [account u32][key 32][device
str8]` (0x1F), in `proto/bots.odin` with the token's format:
`bot_token_make` and `bot_token_parse` (`yap_` + 43 characters of
unpadded base64url), which the gateway will use. Device_List takes an
optional `[account u32]`: another account's devices for whoever has
Manage_Accounts and outranks it, Not_Found for one that isn't there.
Account_Flag.Bot is bit 5, with no schema step.

- Server (`server/bots.odin`): a bot is made with an all-zero
  password hash that login never checks against. A password login for
  it is refused as a wrong password, and logged as "tried a password
  for the bot". Password_Change and a bot deleting itself are Denied
  (an admin deletes it), Account_Password_Set on it is Invalid,
  Voice_Join (a room) and Call_Start (either end a bot) are Denied, and
  digests skip it. `yap-server account list` shows "bot",
  `account passwd` and `account owner` refuse one.
- Client (`conn/bots.odin`, `ui_bots.odin`): no separate window. In
  Settings > Server > Accounts, "Make bot" sits beside "Make account"
  and uses the username and name. A bot's row has "Tokens..." in place
  of "New password...", which opens its tokens: each one connected,
  last used or never used, with Revoke, and "New token". A token just
  made is shown under the list with a warning, Copy and Done (Done
  wipes it). The BOT tag is drawn after the name in chat headers, the
  members list and the user card. Calling a bot isn't offered.
  `--headless` has `/addbot`, `/bottoken <account>` and
  `/tokens <account>`, and logs the token once.
- Tested: `bots_test.odin` in the server (making, limits, tokens) and
  in proto (the token's format, the bodies); every server, proto,
  client and conn test passes but `test_digests`, which fails the same
  way on the commit before this one. End to end on a test server: an
  admin made a bot with the headless client, a client with only the
  bot's token as its key was logged in as the bot, posted, and was
  refused voice, and a password login for the bot was refused. In the
  GUI, off-screen: the tag, the tokens list, a new token, Copy, Done,
  revoking a connected token (the bot was logged out), and Make bot.

### 2. A headless client

`src/common/lite` (name to taste): one connection to a server without
UI, audio or rendering. What `stress/bot.odin` does, made into a
package with an API: open with a key and an address, send a request
with a callback or a channel for its answer, get events, ack snapshots,
rekey, start over when the server goes quiet, close. Its own tests
against a server in-process, as `auth_test.odin` runs one. `stress`
moves onto it.

*As built:* `src/common/lite` (`lite.odin`), one `lite.Client` per
connection, with no thread of its own: its owner calls `receive` and
`step` from one thread, which any number of clients can share, as the
gateway's connection thread will. `open` takes a device's private key
(a token, through `bot_token_parse`) and Options: the server's address,
the key it must have (zero for any; the gateway will pin its own
server's), the server's password, and a username and password to log
in with if the key isn't a device yet (what `/login` will do), with
the device's name and agent. `request` sends one with a `done` that
gets exactly one Answer (op, status, body, tag, how long it took): the
server's, or Reset if the connection started over, failed or was
closed first; it's false, and `done` never called, when there's no
connection to send it on. `send` is for datagrams (typing, voice), and
`restart` starts over under a new conn_id.

- What it hears goes to Handlers: the phase (Connecting, Logging_In,
  Syncing, Ready, Failed), every event (Sync_Begin..Sync_End after each
  login, so a model is rebuilt from them), each snapshot of who is
  here once Ready (acked first; the ones before are left unacked, as
  the client does), and every other datagram as it is.
- Failed is for good, with the reason: refused (and the Refusal), the
  wrong server key, a key that's no device with nothing to log in with,
  the login turned down (and its status), logged out (Logged_Out, and
  its reason), or nothing from the server for 30 s. It says Leave
  first, so the server lets the connection go at once. A login answered
  Rate_Limited or Internal is asked again, a second apart, as many
  times as Options.login_retries says (stress: 100; `/login` will want
  none).
- As the client: rekeys every two minutes, handshakes again when the
  server is quiet for SERVER_SILENT (it pings every second, so it
  hears it), starts over on a broken or backed-up stream, and on a new
  Welcome starts the stream over and answers what was waiting Reset.
  Only the main link: without a bulk link the server sends everything
  on it.
- `stress` runs on it: `bot.odin` keeps when a bot connects, its voice
  frames and the stats; the connection is a `lite.Client`. The report's
  "handshakes timed out" became "gave up" (bots that failed); logins
  aren't in the request stats any more.
- Tested: `server/lite_test.odin`, the server's packet handling and
  syncs on a loopback socket, turn about with the clients: a bot's
  token (synced, a snapshot acked, a post and its Msg_New, Leave), a
  password login making a device and the key alone after it, a wrong
  password, a key that's no device, the wrong server key, a server
  password missing and given, `restart` (Reset, synced again), and
  revoking the token (Logged_Out, gone). All server tests pass but
  `test_digests`, as before. Against `yap-server.exe` on loopback, from
  a scratch program: three bots logging in by password, posting twice
  a second for 50 s with rekeys every 12 s, and the server stopped and
  started again (posts in between answered Reset, then synced again by
  key). `stress` is checked for Linux (`-target:linux_amd64`) but
  wasn't run: it needs poll, and WSL couldn't reach a server on
  Windows.

### 3. The gateway

`src/server/gateway*.odin` (or `src/gateway`, D5): the listener (or
the relay's), a thread per HTTP connection as the relay has, request
parsing (method, path, headers, a body by Content-Length; keep-alive),
routing, JSON out (`core:encoding/json`, Odin's own), the token →
connection table with its lock, idle closing, `/login`, `/logout`,
`/me`, `/server`, the error mapping. The headless client's connections
run on a gateway thread of their own, which the HTTP threads hand
requests to.

*As built:* three packages in `src/common`, so that the gateway is the
same in yap-server and on its own (D5):

- `http`: the relay's HTTP reading (`read_head`, `parse_request`: the
  path apart from its query, headers, Content-Length, chunked or not,
  keep-alive) and `respond`, and its WebSocket framing, moved out of
  `server/websocket.odin` and `relay.odin`. The relay and the gateway
  share it: one parser (D2).
- `gateway`: `gateway.odin` has the gateway thread, which owns the token
  -> connection table (by the token's public key) and every `lite`
  connection, and a Job handed over from the HTTP threads under a lock;
  each Job gets exactly one reply, on a semaphore the HTTP thread waits
  on. A Job for a connection that isn't synced yet waits on it, and is
  run, or answered with why it failed, when it is. Connections go after
  `Config.idle` (5 minutes) with nothing waiting or asked; there's at
  most `max_connections` (64; phase 8 puts it in the config). A guest
  connection (`lite`'s new `guest`: connected, not logged in) answers
  `/server`. `model.odin` keeps Self and every account (Self comes
  after the accounts in a sync), and the JSON for an account, `/me` and
  the server. `serve.odin` routes (`{}` path segments become
  parameters), takes the token from `Authorization: Bot`, reads the
  body (64 KiB at most; chunked is refused, 411), maps statuses as the
  Errors table has them (Unknown_Op 501, Reset 503), and answers 405
  with Allow, 401 with WWW-Authenticate, 429 with Retry-After.
  `routes.odin`: `POST /login`, `POST /logout` (Auth_Logout, 204),
  `GET /server`, `GET /me` (the account, owner, and permissions by
  name).
- `/login` makes a token (`bot_token_make`), opens a connection that
  logs in with it as device `device` ("API" if not given), agent "yap
  API", and answers `{token}` once it's synced; `lite.forget_login`
  then wipes the password, so the key alone is what keeps it in. A
  wrong password is 401 `wrong_password`, a bot's too (it has none).
- A token that's no device, revoked or logged out is 401
  `unauthenticated`; a server that refuses the gateway or hasn't the
  pinned key is 502; one that doesn't answer for 30 s, 503.
- yap-server: `"api": {"enabled": true}` starts the gateway, to
  127.0.0.1 on the server's own port with the server's key pinned, and
  the relay's port sends `/api/` to it. With the relay disabled, the
  port still opens, for the API alone (404 for anything else).
- `src/gateway`: yap-gateway, the same on its own: `-server`,
  `-server-key` (without, any key is taken, with a warning),
  `-password`, `-listen` (127.0.0.1:8080 unless told otherwise), not
  in build.sh.

Not as planned or not yet: `/me` is answered from the model, so in the
moment between a token being revoked and the gateway hearing of it a
`/me` still answers (anything asked of the server is refused). The
gateway thread looks at its connections every millisecond, which on
Windows is Sleep's 15 ms or so; on Linux it's as asked. The `/login`
loopback rule and `behind_proxy` are phase 8's, as planned.

- Tested: `server/gateway_test.odin`, HTTP over loopback TCP to the
  gateway, its thread to the server's packet handling on a loopback
  socket, and back: a bot's token (`/me` twice on one kept-alive
  connection, `/server` without one, no token, not a token, nobody's
  token, 404s, 405 with Allow, `/logout` and the token gone after), a
  `/login` (wrong password, no password, not JSON, a bot, then the
  right one: a device named as asked, with the agent, and its token
  working), a revoked token (401 after), and an idle connection closed
  and opened again. While making them, the gateway wrote to a Job after
  replying to it, which crashed about one run in twelve; fixed, and 40
  runs of the server suite since were clean but `test_digests`, as
  before. Debug builds (`-debug`) of any test that handshakes crash in
  `core:crypto`'s AVX2 ChaCha20 on this machine, with or without the
  gateway: that's the toolchain's. With curl against yap-server with
  the API on and the relay off, and against yap-gateway with the right
  key and a wrong one.

### 4–7

As the endpoint table has them; each endpoint is a decoder from JSON,
a protocol request, and a writer to JSON, plus tests that go HTTP →
gateway → server → back in one process.

*As built (4):* the model (`gateway/model.odin`) keeps, per
connection, Self, the roles, the accounts and the conversations the
account is in, from the sync and the events after it (Role_Changed and
_Removed, Account_Changed, Conv_Changed and _Removed, Read_Changed), and
who is online from each snapshot. A conversation's newest message and
its unread count follow Msg_New as a client counts them (one's own post
reads everything up to it; thread replies count, as the server counts
them); its mentions only change with Read_Changed, as counting them
would take knowing who each is of.

The endpoints, in `gateway/reading.odin`:

- From the model: `GET /accounts` (by id), `/accounts/{id}`, `/roles`
  (top first, everyone's last; colour as "#rrggbb"), `/convs` (channels
  by position, then DMs, the most recent first) and `/convs/{id}`, which
  the table didn't have. An account says `online`: connected and not
  appearing offline. A conversation says `kind`, `home`, `private`, a
  DM's `recipient`, `last_message_id` and `_timestamp`, `last_read_id`,
  `unread`, `mentions`, `notify`.
- From the server: `/convs/{id}/messages` (`before`, `after` or
  `around`, `limit` 1 to 50, `thread`; oldest first, and a page may be
  short when it wouldn't fit one stream message, so there's no more
  only once one is empty), `/convs/{id}/pins` (the newest pin first),
  `/convs/{id}/members` (as accounts), `/convs/browse` (`q`, `offset`,
  `limit`: `{convs, more}`), `/search` (`q`, `conv`, `before`, `limit`:
  `{messages, searched_to, more}`, newest first) and
  `/messages/{id}/reactions/{emoji}` (`{total, accounts}`, the emoji
  URL-encoded or `:name:`).
- Messages as the plan has them, and `file` (a DM's file offer) and
  `system` (`what`, `arg`: a call's) for the kinds that aren't text.
  Path parameters are percent-decoded; `common/http` has `query_value`
  and `percent_decode`.
- Tested: `test_gateway_reading`, with three messages, a pin, a
  reaction, a role and a DM from someone else on the server: every
  endpoint above, pages before and after a message, a 404, two 400s,
  and the model following a message posted afterwards (newest, unread).
  The server suite is 110 tests, ten runs clean but `test_digests`. With
  curl against yap-server: history and its pages, members, a
  conversation, pins, search and a limit out of range.

*As built (5):* `gateway/writing.odin`. Bodies are JSON objects (a
field left out is left as it is; ids as strings or numbers):

- `POST /convs/{id}/messages {content, thread, nonce}` -> 201 the
  message as the server keeps it (mentions and links as it made them),
  asked for (Msg_History around it) once the post is answered; the
  same `nonce` (any string or number, hashed to the protocol's u64; at
  random without one) answers with the first post's message.
  `attachments` is 501 until phase 7. `POST /messages/{id}/forward
  {conv, thread, nonce}` -> 201 the copy, the same way.
- `PATCH /messages/{id} {content}`, `DELETE /messages/{id}`, `PUT` and
  `DELETE /messages/{id}/pin` and `.../reactions/{emoji}` -> 204, not
  the message as the plan's Discord would: Msg_Edit doesn't name the
  conversation, so the gateway can't ask for it, and an edit that
  changes nothing is told to nobody. The message as it is then is
  MESSAGE_UPDATE (phase 6).
- `POST /convs/{id}/read {message}` -> 204, everything there is without
  `message`; `POST /convs/{id}/typing {thread}` -> 204, a Typing
  datagram, to send again every few seconds as a client does.
- `POST /dms {account}` -> the DM; `PUT /convs/{id}/subscription` -> the
  channel, `DELETE` -> 204; `PATCH /me {display, status,
  status_until}` (ISO 8601; null or "" clears) and `PUT /me/activity
  {activity}` -> /me. `avatar` is 501 until phase 7. These answer from
  the model once it has the change: after the request, the gateway
  asks for Server_Info, whose answer comes after every event of the
  one before (`after_events`).
- The gateway thread now takes in what has come before it hands the
  Jobs waiting to their connections, so a GET after a change answers
  from a model that has it, as far as it had come.
- Tested: `test_gateway_writing`: a post and the same post again, three
  bodies that aren't one, files (501), an edit, a reaction on and off,
  a pin a member may not make in a channel (403), a DM, a post and a
  pin there, a forward, a delete, read and typing, subscribing and
  unsubscribing, the profile and the activity, each checked in the
  server or by reading it back. The server suite is 111 tests, ten runs
  clean but `test_digests`. With curl against yap-server: each of the
  above.

*As built (6):* `gateway/events.odin`, with `common/http` now also
the client's side of a WebSocket (masked frames out, unmasked in), for
the tests.

- `GET /api/v1/events`, the token in `Authorization: Bot` or
  `?token=`. Every frame is `{"t", "s", "d"}`; READY's `d` is `me`,
  `server`, `roles`, `accounts`, `convs` and `online` (account ids),
  and its `s` is the last event's, so the first after it is `s + 1`.
- Resuming is `?resume=<s>` in the URL rather than a first frame (as
  the plan had it): the gateway knows then and there whether to replay
  or send READY, with no first frame to wait for, or not. A token's
  connection numbers and keeps its last 500 events from its first
  socket on, and stays for `idle` (5 minutes) after a socket goes, which
  is how long a bot has to come back. Too far back, or a connection
  that's gone: INVALID_SESSION, then READY.
- One socket per token: a new one closes the one before with 4000.
  4001 after LOGGED_OUT (revoked, logged out, disabled, deleted), 4002
  when the server can't be reached, 1001 when the API stops. The gateway
  pings every 30 s and answers pings; what the bot sends is ignored.
- The events are the table's, with these shapes: MESSAGE_CREATE and
  MESSAGE_UPDATE a message; MESSAGE_DELETE `{id, conv_id}`;
  MESSAGE_REACTION_ADD/_REMOVE `{message_id, conv_id, emoji, count,
  account}`; MESSAGES_PURGED `{conv_id, before_id, what}`; TYPING_START
  `{conv_id, thread, account}` (not the bot's own); CONV_UPDATE a
  conversation, CONV_DELETE and ROLE_DELETE `{id}`; READ_UPDATE
  `{conv_id, last_read_id, unread, mentions}`; ACCOUNT_UPDATE an
  account; ROLE_UPDATE a role; PRESENCE_UPDATE `{account_id, online}`,
  one per account a snapshot changed; SERVER_UPDATE the server;
  SELF_UPDATE /me; LOGGED_OUT `{reason}`. The bot's own doings are
  told it as anyone's are (its posts, its reads).
- A connection that had to start over with the server (it restarted)
  is synced again, and says so with another READY in the stream, after
  which the bot has things as they are.
- READY's `online` is as the model has it when the socket comes, which
  on a connection just made is before the server's first snapshot:
  PRESENCE_UPDATEs for whoever is already here follow at once.
- Threads: the socket's HTTP thread reads it (pings, close); a writer
  thread of its own sends what the gateway thread puts in its Feed,
  and the Feed is freed by whichever of the connection and the socket
  lets go of it last.
- Tested: `test_gateway_events`, with a WebSocket client in the test on
  a thread of its own and alice on a `lite` client: no token (401),
  READY, alice coming online and typing, a message posted, reacted to,
  edited and deleted (each told, in that order, every `s` one after the
  last), the bot's own read, a resume after a post made while away (just
  that post), resuming from too far (INVALID_SESSION, READY) with the
  token in the URL, which closes the socket before it (4000), and
  revoking the token (LOGGED_OUT, 4001). The server suite is 112 tests,
  ten runs clean but `test_digests`. Against yap-server, from Node 24
  with nothing but its own `fetch` and `WebSocket`: READY, then a
  post, a reaction and an edit by another bot as they happened.

*As built (7):* `gateway/files.odin`.

- `POST /uploads?name=` with the file as the body (a Content-Length,
  not chunked) -> 201 `{id, name, size}` once the server has all of it;
  the id goes in a post's `attachments` (at most 10; `content` may then
  be empty), for an hour. `GET /attachments/{id}` (an attachment's id
  in a message) -> its bytes, `application/octet-stream`.
- Both stream: an upload's body goes from the HTTP thread into a Ring,
  a transfer's window (1024 chunks, 1.2 MB) big, which the gateway
  sends from as chunks (Upload_Chunk) as fast as the server's acks say
  it takes them, and frees as they're acked; a download's chunks go
  into one the HTTP thread writes out from, and are only acked as far
  as the bot has taken them, so the server sends no more than the Ring
  holds. So a transfer costs the gateway 1.2 MB whatever its size, and
  the server's `attachments.rate_kb` is what limits it. A download cut
  short closes the connection, its Content-Length unmet.
- `GET /blobs/{id}` -> a picture (an avatar, the emoji sheets, the
  server's icon), whole (a megabyte at most), with its type from its
  first bytes (JPEG, PNG, WebP, GIF).
- `PUT /me/avatar` with a JPEG as the body (64 KiB and 256 pixels a
  side at most, as a client makes them; its size read from its header)
  -> /me, and `DELETE /me/avatar` -> /me without one. Not
  `PATCH /me {avatar}` as the plan had it: there's no upload id for a
  picture, which goes as a blob (Blob_Put, Blob_Chunk, Blob_Need) as the
  client sends one.
- An upload turned down before its body is read (no name, no token)
  reads and drops a body of up to 64 KiB, so the connection stays open.
- A transfer the server says nothing of for 30 s, or whose connection
  starts over, fails with 503; one the server cancels with 502.
- Tested: `test_gateway_files`, against a server with its blob store
  and attachments open: a file three windows long uploaded, posted with
  an empty text and fetched back the same, byte for byte; an upload
  with no name (400, on a connection that goes on); an avatar set,
  fetched (image/jpeg, the same bytes) and taken away; one that isn't
  a JPEG (400); an attachment that isn't there (404). The server suite
  is 113 tests, ten runs clean but `test_digests`. With curl against
  yap-server: a 20 MB file up and down again, the same (about 2 MB/s
  each way, which is the server's rate), and an avatar from ImageMagick.

### 8. Limits

The token buckets, the body caps, the connection caps, `behind_proxy`
and the `/login` rule, `max_connections`, logging each token's
connection at info as the relay logs browsers.

*As built:* `gateway/limits.odin`, and the config as the Config
section has it: `"api": {"enabled", "behind_proxy", "max_connections",
"rate", "burst"}`, 64, 10 and 30 when left out (yap-gateway: `-rate`,
`-burst`, `-behind-proxy`, `-max-connections`).

- A bucket per token (by its public key), the HTTP threads', under a
  lock of its own: every request with a token takes a turn, event
  sockets and transfers too; an empty one is 429 `rate_limited` with
  Retry-After, the seconds until there's a turn again. A rate of 0 is
  no limit. Buckets unused for 10 minutes are let go once there are
  1024 of them.
- `/login` is taken over loopback, or with `behind_proxy` only when
  X-Forwarded-Proto says https (and then from anywhere, as the proxy's
  own address says nothing); else 403. A client can't say it came over
  HTTPS without a proxy to say it for it.
- Sockets: 60 s between requests (and between a body's bytes, and a
  download's writes, so a bot that stops reading one doesn't keep its
  thread), 75 s on an event socket, which a live client answers the
  gateway's 30 s pings on.
- Already in place from phases 3 to 7: `max_connections` (503), one
  event socket per token, 64 KiB bodies but for uploads, which stream,
  a transfer's 1.2 MB, and the log saying when a token's connection
  opens and closes; now its event socket too, and from where.
- `http.Conn` knows who's at its other end (`remote`), for the
  `/login` rule and the log.
- Not done: no limit on the HTTP connections themselves (a thread each,
  as the relay has; the idle timeouts bound how long they stay), and
  none on `/login` by address beyond the server's own lockouts.
- Tested: `test_gateway_limits`: a bucket of 2 filling at 0.5 a second
  (two answered, the third 429 with Retry-After, another token's
  answered), `max_connections` of 1 (a second token 503, the first still
  answered), and behind a proxy, /login without X-Forwarded-Proto and
  with `http` (403) and with `https`; `test_gateway_login_rule`, the rule
  on its own. The server suite is 115 tests, ten runs clean but
  `test_digests`. With curl against yap-server's defaults: 40 requests
  as fast as they go, 35 answered (the burst of 30, and 5 more refilled
  meanwhile) and 5 told 429, and a kept-alive connection that went
  quiet closed 60 s after its last request.

### 9. Docs and examples

`API.md` in the repository's root (D8): auth, errors, every endpoint
and event with an example, limits, the reverse proxy setup. Examples in
`examples/bots/`: an echo bot in Python (`requests` + `websockets`), in
Node with nothing but what Node has (fetch, WebSocket), a `curl`
one-liner that posts, a bot that answers `!roll` in a DM.

*As built:* `API.md` in the root: a quick start; setting it up (the
config, Caddy and nginx in front, yap-gateway); tokens (bot accounts from
the client and `-headless`, `/login`, revoking); conventions and every
error; every endpoint, grouped, with what it takes and gives and curl
for the ones worth one; the objects; the event socket (READY, every
event's `d`, resuming, close codes); the limits; and what isn't there.
Its examples are what yap-server answered. The README has a Bots section
and a line in the list, and `config.example.json` the `api` block.

`examples/bots/`: `echo.py` (requests and websockets; resumes after a
dropped socket, stops on 4000 and 4001, waits out 429), `echo.mjs` (the
same with Node's own fetch and WebSocket), `roll.py` (`!roll 2d6` in
DMs, typing first, then marked read), `post.sh` (curl alone, a file
too; the text escaped for JSON with sed), and a README. The token goes
in the event socket's URL, which every WebSocket can do (a browser's
can't set headers, and `websockets` changed how it takes them).

Tested against yap-server: both echo bots answered `!echo` in the home
channel, roll.py a `!roll 2d6` in a DM, and post.sh posted text with
quotes and a newline and a file, each read back from the history.

## Later

Not planned in detail; written down so v1 leaves room for them.

- **Commands**: a bot registers `/commands` (name, description,
  arguments); clients complete them in the message bar (the completion
  popup exists, `ui_completion.odin`), and the bot gets a
  `COMMAND` event rather than parsing text. Needs protocol and client
  work; the most Discord-like thing worth having.
- **Outgoing webhooks**: for a bot that can't hold a WebSocket open
  (serverless), the gateway POSTs events to a URL.
- **Incoming webhooks**: a URL with a secret in it that posts to one
  channel, no token or account needed (CI notifications). Could be a
  bot account with a narrow token, which v1 already allows.
- **Voice** for bots (music bots): Opus frames over the WebSocket, the
  gateway doing the UDP side. Big, and the gateway would need a jitter
  buffer.
- **A client library** per language, if people want one; v1 shouldn't
  need it.
- **Rich messages** (embeds, buttons): yap has none for people either.

## Decisions

| # | Question | Recommendation |
| --- | --- | --- |
| D1 | Mimic Discord's API so bots move over unchanged, or borrow its shape? | Borrow the shape (REST + event WebSocket, `Bot` tokens, Discord's names where the concept is the same, string ids). No porting docs for now. |
| D2 | API on the relay's port under `/api/`, or a port of its own? | Runs on the same port. No need for a setting to make it run somewhere else. |
| D3 | May ordinary accounts get a token with `/login` ("controls a user account"), or only bot accounts? | Yes allow it, no need for a setting to switch this. |
| D4 | Times as ISO 8601 strings (Discord) or Unix milliseconds (yap)? | ISO 8601: readable in a log, parsed by every language's standard library. |
| D5 | Gateway built into yap-server only, or also as a program of its own (`yap-gateway --server ...`)? | Built in, as a package that also builds as its own program, for nothing much extra. Built in is what admins enable; on its own it lets a bot author use any server. |
| D6 | Bot tokens: one at a time ("reset token" replaces it), or several (one per deployment, revoked one by one)? New requests (Bot_Create, Bot_Token_Add) or Account_Create grown? | Several, as devices already are. New requests: Account_Create's password handling doesn't fit a bot. |
| D7 | A post rate limit in the server for every account, or only in the gateway? | Gateway now (phase 8), server-wide later as its own item: it changes how people's clients behave too. |
| D8 | API reference as a Markdown file in the repo, or a page the gateway serves? | Just write it to API.md in the root. |
| D9 | Which of "Later" matter for v1's design? | We can leave out all of the later items for this first part of the API. |

# The yap bot API

HTTP and JSON for programs: bots that answer commands, a cron job that
posts, a bridge to another chat, a moderation helper. Anything that can
make an HTTP request can use it. `curl` works, as do Python's `requests`
and Node's built-in `fetch`, and Node, browsers and most languages can
open its WebSocket. You don't need an SDK, any crypto or a binary
format.

The API is roughly shaped after Discord's: a REST API for doing things,
one WebSocket for being told things, `Authorization: Bot <token>`, ids
as strings, and similar names where the thing is the same
(`MESSAGE_CREATE`, `content`, `author`, `timestamp`)..

A bot can do what its account may do and nothing more. The API is
served by a gateway that is, to the server, just more clients, so every
request goes through the same checks as a person's would.

Contents: [Quick start](#quick-start) · [Setting it up](#setting-it-up) ·
[Tokens](#tokens) · [Conventions](#conventions) ·
[Endpoints](#endpoints) · [Objects](#objects) ·
[Events](#events-the-websocket) · [Limits](#limits) ·
[Examples](examples/bots/)

## Quick start

Turn the API on in the server's `config.json` and restart it:

```json
"api": { "enabled": true }
```

It's served on the relay's port (8080 unless the config says otherwise)
under `/api/v1/`, whether or not the relay itself is enabled.

Make a bot: in the client, an admin goes to **Settings > Server >
Accounts**, fills in a username and presses **Make bot**. The client
shows the bot's token once, so copy it then. Then:

```sh
export YAP_URL=http://localhost:8080
export YAP_TOKEN=yap_...

# Who am I?
curl -H "Authorization: Bot $YAP_TOKEN" $YAP_URL/api/v1/me

# Say something in conversation 1 (the home channel, usually).
curl -H "Authorization: Bot $YAP_TOKEN" \
     -d '{"content": "Hello from a bot"}' \
     $YAP_URL/api/v1/convs/1/messages
```

To hear what happens, open `ws://localhost:8080/api/v1/events?token=...`.
The [examples](examples/bots/) are short bots in Python and Node.

## Setting it up

### The config

```json
"api": {
  "enabled": false,
  "behind_proxy": false,
  "trusted_proxy": "",
  "max_connections": 64,
  "rate": 10,
  "burst": 30
}
```

| Key | |
| --- | --- |
| `enabled` | Serve the API, on the relay's port (`relay.port`), under `/api/`. With the relay disabled, the port serves only the API. |
| `behind_proxy` | The API is behind a reverse proxy with TLS. `/login` is then only taken when the proxy's `X-Forwarded-Proto` says `https`, and only from the proxy (see `trusted_proxy`). Without it, `/login` is only taken from the server's own machine. |
| `trusted_proxy` | With `behind_proxy`: the proxy's IP address. Its `X-Forwarded-Proto` and `X-Forwarded-For` headers are believed, nobody else's. If empty, they are believed from the server's own machine and from private networks (10.x, 172.16–31.x, 192.168.x, fc00::/7), which is where a proxy in front of a container usually is. Set `relay.bind` to `127.0.0.1` if the proxy is on the same machine, so the port can't be reached around it. |
| `max_connections` | How many tokens may be in use at once. |
| `rate`, `burst` | How many requests per second a token may make, and how many at once. `rate` 0 means no limit. |

The keys you leave out keep the defaults above.

### yap-gateway: the API for any server

A server that doesn't enable the API can still be used through one,
run next to the bot:

```sh
odin build src/gateway -collection:common=src/common -collection:lib=src/lib -out:bin/yap-gateway
bin/yap-gateway -server:chat.example.org:7777 -server-key:<64 hex digits>
```

Key meaning the public key of the server, which can be optionally left out.
It listens on `127.0.0.1:8080` unless told otherwise with `-listen`, and has
`-password` (the server's, if it has one), `-rate`, `-burst`,
`-max-connections`, `-behind-proxy` and `-trusted-proxy`, as the config
does.

## Tokens

A token looks like `yap_` followed by 43 characters. It is a device's
private key: the server never sees it, only the public half, and lists
it with the account's devices. Revoking that device is what revokes the
token.

**A bot account** is made by an admin (Manage_Accounts):

- In the client: **Settings > Server > Accounts**, with a username (and
  a display name), **Make bot**. The token is shown once, with Copy.
  **Tokens...** on the bot's row lists its tokens (connected, last used),
  revokes them, and makes another (**New token**), say one per place the
  bot runs.
- In `yap -headless`: `/addbot <username> [name]` (the token goes to the
  log, once), `/bottoken <account id>` for another, `/tokens <account
  id>` to list them.

A bot has no password and can't log in with one. It can't join voice
rooms or calls, isn't sent email digests, and shows with a BOT tag
everywhere its name does. Otherwise it's an account like any other: it
can do what its roles allow, so give it a role as you would a person.

**An ordinary account** gets a token by logging in:

```sh
curl -d '{"username": "alice", "password": "...", "device": "weather cron"}' \
     $YAP_URL/api/v1/login
```
```json
{"token": "yap_..."}
```

`device` is what the token is called in the account's device list
("API" if left out). This only works over HTTPS behind a proxy, or from
the server's own machine (see `behind_proxy`).

`POST /logout` with a token makes the token stop working. So does
revoking it from the account's devices, changing the password (for
an ordinary account), or disabling or deleting the account.

## Conventions

- Every path is under `/api/v1/`.
- Every request but `/login` and `/server` needs `Authorization: Bot
  <token>`. The event socket also takes `?token=` instead, for clients
  that can't set headers.
- Bodies are JSON objects. A field left out of a `PATCH` is left as it
  is.
- Ids are strings (`"48213"`), because 64-bit numbers don't survive
  JavaScript. In a request, either a string or a number is fine.
- Times are ISO 8601 in UTC: `"2026-10-11T09:14:03.120Z"`.
- Something that isn't there is `null`, not left out.
- `content` is text as a person types it: markdown, `@username` to
  mention someone, `:name:` for the server's own emoji, and
  `<msg:CONV:ID>` to link a message.
- History is oldest first; search is newest first.

### Errors

Anything that isn't a success answers with an HTTP status and:

```json
{"error": "invalid", "message": "content is the message's text (which files may go without)."}
```

| HTTP | `error` | |
| --- | --- | --- |
| 400 | `invalid` | Something's wrong with the request. |
| 401 | `unauthenticated` | No token, not a token, or one that doesn't work (any more). |
| 401 | `wrong_password` | `/login` with a wrong username or password. |
| 403 | `denied` | The account may not do that. |
| 403 | `banned` | `/login` for an account that is banned from the server. |
| 404 | `not_found` | There's no such thing, or the account can't see it. |
| 405 | `method_not_allowed` | Not with that method; `Allow` lists the ones there are. |
| 409 | `conflict` | It's taken, or there already. |
| 410 | `closed` | It's closed, such as a call that has ended. |
| 411 | `invalid` | A body without a Content-Length. |
| 413 | `too_large` | Too big: a body over 64 KiB, or a file over what the server takes. |
| 429 | `rate_limited` | Too many requests; `Retry-After` says how many seconds to wait. This is also the answer when one address asks for too many new connections to the server at once: each `/login` and each token the gateway hasn't seen yet is one, and an address gets 10, then one every 6 seconds. |
| 500 | `internal` | Something went wrong in the server. |
| 501 | `unknown_op` | The server is too old for that. |
| 502 | `bad_gateway` | The server wouldn't have the gateway's connection (a wrong `-server-key` or `-password`). |
| 503 | `reset`, `unavailable` | The connection to the server started over before it answered (try again), or the server isn't answering. |
| 507 | `quota` | The account has uploaded as much in the last 24 hours as the server allows (`attachments.daily_megabytes`). |

## Endpoints

### The server, and yourself

| | |
| --- | --- |
| `GET /server` | What the server says about itself; no token needed. → [server](#server) |
| `GET /me` | Your account, and what it may do. → [me](#me) |
| `PATCH /me` | Change your profile. → [me](#me) |
| `PUT /me/activity` | Online, away, busy, or offline. → [me](#me) |
| `PUT /me/avatar` | Set your picture. → [me](#me) |
| `DELETE /me/avatar` | Remove it. → [me](#me) |
| `POST /login` | A token for an ordinary account (see [Tokens](#tokens)). |
| `POST /logout` | This token stops working. → 204 |

**`PATCH /me`** `{display, status, status_until}`: your display name,
your status line (`null` or `""` clears it), and when the status clears
itself (ISO 8601, or `null` for never).

```sh
curl -X PATCH -H "Authorization: Bot $YAP_TOKEN" \
     -d '{"status": "Forecasting", "status_until": "2026-10-12T18:00:00Z"}' \
     $YAP_URL/api/v1/me
```

**`PUT /me/activity`** `{activity}`: `online`, `away`, `busy`, or
`offline` (appear offline).

**`PUT /me/avatar`** with a JPEG as the body (not JSON): at most 64 KiB
and 256 pixels on its longer side, as the client makes them.

```sh
curl -X PUT -H "Authorization: Bot $YAP_TOKEN" --data-binary @avatar.jpg \
     $YAP_URL/api/v1/me/avatar
```

### Accounts and roles

| | |
| --- | --- |
| `GET /accounts` | Every account on the server, by id. → [account](#account)s |
| `GET /accounts/{id}` | One. → [account](#account) |
| `GET /roles` | Every role, top first, and everyone's last. → [role](#role)s |

### Moderation

For a bot whose roles hold the permission. It only works on accounts
the bot outranks (whose permissions it all has too), never the owner.
The bot needn't be in voice itself.

| | |
| --- | --- |
| `PUT /accounts/{id}/voice` `{conv}` | Move their voice to that channel's room (Move_Members; you need to be able to talk there). → 204 |
| `DELETE /accounts/{id}/voice` | Take them out of voice (Move_Members). → 204 |
| `PUT /accounts/{id}/mute` | Mute them for everyone on the server until it's lifted (Mute_Members); their account's `server_muted` says so. → 204 |
| `DELETE /accounts/{id}/mute` | Lift it. → 204 |
| `PUT /accounts/{id}/ban` `{reason, purge}` | Ban them (Ban_Members): they're logged out, can't log in, and are shown `reason`. `purge` (`none`, `hour`, `day`, `week` or `all`) also removes their messages in channels from that long ago on. → 204, or 409 while another purge is running (nothing is done then) |
| `DELETE /accounts/{id}/ban` | Lift the ban. → 204 |
| `GET /bans` | Who's banned, newest first (Ban_Members). → `[{account, by, time, reason}]`, `account` and `by` like a message's author |

### Conversations

A conversation is a channel, a DM, or a group (a DM of 3 to 8 people).

| | |
| --- | --- |
| `GET /convs` | The ones you're in: channels by position, then DMs and groups, the most recent first. → [conversation](#conversation)s |
| `GET /convs/{id}` | One of them. → [conversation](#conversation) |
| `GET /convs/browse?q=&offset=&limit=` | Channels there are to join, whose name or topic has `q` in it. → `{convs, more}` |
| `PUT /convs/{id}/subscription` | Join a channel. → [conversation](#conversation) |
| `DELETE /convs/{id}/subscription` | Leave it. → 204 |
| `GET /convs/{id}/members` | Who's in it. → [account](#account)s |
| `POST /dms` `{account}` | The DM with that account, made if need be. Your own account gives the DM with yourself, for notes only you see. → [conversation](#conversation) |
| `POST /groups` `{accounts}` | The group of you and those 2 to 7 accounts, made if need be. Bots can't be in groups, so a bot gets 403. → [conversation](#conversation) |
| `POST /convs/{id}/read` `{message}` | Mark it read up to and including `message`, or all of it without one. → 204 |
| `POST /convs/{id}/typing` `{thread}` | Show that you're typing for a few seconds. Send it again every few seconds while it lasts. → 204 |

`browse` gives `limit` (1–100, default 50) channels starting from
`offset`. `more` says there are more after them.

### Messages

| | |
| --- | --- |
| `GET /convs/{id}/messages?before=&after=&around=&limit=&thread=` | A page of history, oldest first. → [message](#message)s |
| `POST /convs/{id}/messages` `{content, thread, nonce, attachments, persona}` | Post. → 201 [message](#message) |
| `PATCH /messages/{id}` `{content}` | Edit one of yours. → 204 |
| `DELETE /messages/{id}` | Delete one of yours, or anyone's with Manage_Messages. → 204 |
| `PUT /messages/{id}/pin` | Pin it: anyone in a DM or a group, or Pin_Messages in a channel. → 204 |
| `DELETE /messages/{id}/pin` | Unpin it. → 204 |
| `PUT /messages/{id}/reactions/{emoji}` | React. → 204 |
| `DELETE /messages/{id}/reactions/{emoji}` | Take your reaction back. → 204 |
| `GET /messages/{id}/reactions/{emoji}` | Who reacted with it. → `{total, accounts}` |
| `POST /messages/{id}/forward` `{conv, thread, nonce}` | Copy it to another conversation. → 201 [message](#message) |
| `GET /convs/{id}/pins?offset=` | Its pinned messages, the most recently pinned first, a page at a time: the ones after the first `offset` (default 0). An empty page means there are no more. → [message](#message)s |
| `GET /search?q=&conv=&before=&limit=` | Search. → `{messages, searched_to, more}` |

**History.** Give at most one of `before`, `after` or `around` (a
message's id; `around` includes that message). Without one, you get the
newest messages. `limit` is 1–50 (default 50). `thread` is a thread's
first message, to get its replies. A page can be shorter than `limit`
when its messages are long, so keep going until a page comes back empty.

```sh
# The newest 20, then the 20 before the oldest of those.
curl -H "Authorization: Bot $YAP_TOKEN" "$YAP_URL/api/v1/convs/1/messages?limit=20"
curl -H "Authorization: Bot $YAP_TOKEN" "$YAP_URL/api/v1/convs/1/messages?limit=20&before=48190"
```

**Posting.** `content` is the text. `thread` is a thread's first
message, to reply in that thread. `nonce` is anything (a string or a
number): post again with the same one, say after a timeout, and you get
the first post's message back instead of a second post. `attachments`
lists up to 10 [upload](#files) ids, and `content` may then be empty.
The answer is the message as the server keeps it, with mentions and
links as it made them.

```sh
curl -H "Authorization: Bot $YAP_TOKEN" \
     -d '{"content": "Rain from 3pm.", "nonce": "weather-2026-10-12"}' \
     $YAP_URL/api/v1/convs/1/messages
```
```json
{"id": "273", "conv_id": "1",
 "author": {"id": "2", "username": "weather", "display": "Weather", "bot": true},
 "timestamp": "2026-10-12T09:07:56.201Z", "edited_timestamp": null,
 "kind": "text", "content": "Rain from 3pm.", "thread": null,
 "attachments": [], "reactions": [], "pinned": false, "deleted": false,
 "forwarded": null, "persona": null, "replies": null, "file": null, "system": null}
```

**Personas.** A bot may post a message under another name and picture,
as a bridge shows who it relays for or a CI bot the project that built.
`persona` is `{name, avatar}`: the name is at most 255 bytes, and
`avatar` (optional) is the `id` that `POST /avatars` returned. The
message is still the bot's: it is its `author`, replies and mentions go
to it, and it can edit and delete the message. Clients show the persona's
name and picture next to the bot's tag and "via" the bot's own name, so
that it can't pass for a person. Only bots may do this, and the name may
not be any account's username or display name (case ignored): 403. A
picture that no message uses is removed after an hour.

```sh
id=$(curl -s -H "Authorization: Bot $YAP_TOKEN" --data-binary @ci.jpg \
          $YAP_URL/api/v1/avatars | jq -r .id)
curl -H "Authorization: Bot $YAP_TOKEN" \
     -d "{\"content\": \"Build 7 failed\", \"persona\": {\"name\": \"Build Server\", \"avatar\": \"$id\"}}" \
     $YAP_URL/api/v1/convs/1/messages
```

Edits, deletes, pins and reactions answer 204, not with the message.
The message as it is afterwards comes as `MESSAGE_UPDATE` on the
[event socket](#events-the-websocket).

**Reactions.** `{emoji}` is either the character, URL-encoded (`👍` is
`%F0%9F%91%8D`), or `:name:` for one of the server's own emoji.
Reactors come back as `{"total": 3, "accounts": [...]}`, the earliest
first, at most 50 of the `total`.

**Search.** `q` is required. It matches whole words, ignoring case and
accents. `"a phrase"` in quotes matches the words in a row, and
`from:username` keeps only that account's messages. `conv` keeps it to
one conversation (otherwise it searches all of yours). `limit` is 1–50
(default 25). The answer is newest first. When `more` is true, ask
again with `before` set to `searched_to` to go on further back.

### Files

| | |
| --- | --- |
| `POST /uploads?name=` | Upload a file, the body being the file. → 201 `{id, name, size}` |
| `POST /avatars` | Upload a picture for a persona (see Posting): a JPEG of at most 256 pixels per side and 64 KB, the body being the file. → 201 `{id}` |
| `GET /attachments/{id}` | A file a message carries, by its attachment's `id`. → the bytes |
| `GET /blobs/{id}` | A picture: an avatar, the server's icon, its emoji. → the bytes, as `image/jpeg` (or png, webp, gif) |

An upload needs a Content-Length and is posted by naming its `id` in a
message's `attachments`, within an hour. It can be as big as the server
takes (`max_attachment` in [`/server`](#server)). Files stream both
ways, so their size doesn't matter to the gateway; the server's
`attachments.rate_kb` is what sets the speed, and
`attachments.daily_megabytes` how much an account may upload a day.

```sh
id=$(curl -s -H "Authorization: Bot $YAP_TOKEN" --data-binary @report.pdf \
          "$YAP_URL/api/v1/uploads?name=report.pdf" | jq -r .id)
curl -H "Authorization: Bot $YAP_TOKEN" \
     -d "{\"content\": \"This week's report\", \"attachments\": [\"$id\"]}" \
     $YAP_URL/api/v1/convs/1/messages
```

A download that's cut off closes the connection before its
Content-Length is reached.

## Objects

### account

```json
{"id": "3", "username": "alice", "display": "Alice", "bot": false, "deleted": false,
 "status": "On holiday", "status_until": "2026-10-20T00:00:00.000Z", "avatar": "17",
 "activity": "away", "online": true, "roles": ["4"], "server_muted": false}
```

`username` is unique, lower case and what someone logs in with;
`display` is what people see. `avatar` is a [blob](#files) id (`null`
for none). `activity` is how everyone sees the account (`online`,
`away`, `busy`, `offline`). `online` says it's connected now and isn't
appearing offline. `roles` lists its roles besides everyone's. A
`deleted` account is what's left of a deleted one, so that its messages
still have an author. `server_muted` means a moderator muted it for
everyone.

### me

An [account](#account) without `deleted` and `online`, plus `owner` and
`permissions`, the permissions beyond everyone's: `create_channels`,
`manage_channels`, `invite`, `manage_roles`, `manage_messages`,
`pin_messages`, `manage_accounts`, `mention_everyone`, `purge`,
`attach_files`, `create_invites`, `move_members`, `mute_members`,
`ban_members`.

### role

```json
{"id": "4", "name": "Helpers", "color": "#3366ff", "position": 0,
 "permissions": ["pin_messages"], "mentionable": true, "everyone": false}
```

### conversation

```json
{"id": "1", "kind": "channel", "name": "Lobby", "topic": "", "home": true, "private": false,
 "default": false, "text_only": false,
 "rights": ["see", "write", "react", "edit", "delete", "voice", "attach", "speak", "video"],
 "position": 0, "recipient": null, "members": null, "member": true,
 "last_message_id": "272", "last_message_timestamp": "2026-10-12T08:49:49.273Z",
 "last_read_id": "268", "unread": 3, "mentions": 0, "notify": "all"}
```

`kind` is `channel`, `dm` or `group`. A DM has `recipient` (the other
account, or yours in the DM with yourself) and no name. A group has `members` (the other accounts, which
never change) and no name. `home` is the channel everyone is in. New accounts are put
in a `default` channel, and a `text_only` one has no voice room.
`rights` are what your account may do there: `see`, `write` (post,
reply, forward to it), `react`, `edit` and `delete` (its own messages),
`voice` (join its voice room), `attach` (post or forward messages with
files), `speak` (be heard in its voice room) and `video` (camera or
screen there); bots can't use voice, so the last three are only
informative for them. Doing something
without the right answers 403 `denied`. A
channel's admins set these per role in the client. `last_read_id`,
`unread` and `mentions` are where your account stands. `unread` stops
counting at 100.

### message

| Field | |
| --- | --- |
| `id`, `conv_id` | |
| `author` | `{id, username, display, bot}` |
| `timestamp`, `edited_timestamp` | |
| `kind` | `text`, `file` (a file offered in a DM, peer to peer, which the API can't take), `system` (a call that was missed or ended, or something that happened in the channel or on the server) |
| `content` | The text. |
| `thread` | The thread's first message, if this is a reply in one. |
| `attachments` | `[{id, name, size}]`; `id` is `null` once the server has let the file go. |
| `reactions` | `[{emoji, count, me}]` |
| `pinned`, `deleted` | A deleted message keeps its place but loses its content. |
| `forwarded` | `{author_id, conv_id, timestamp}` of the original, for a copy. |
| `persona` | `{name, avatar}` for a bot's message under another name (`avatar` is a blob id, or `null`); `null` otherwise. A deleted message has none. |
| `replies` | `{count, last_id}` for a thread's first message. |
| `file` | `{name, size}` for `kind` `file`. |
| `system` | `{what, arg, text}` for `kind` `system`. A call: `what` is 1 missed, 2 declined, 3 ended (`arg` is how many seconds the call lasted). In a channel, done by `sender`: 16 joined, 17 left, 18 added `arg` (an account), 19 removed `arg`, 20 renamed, 21 changed the topic (`text` is the old value and the new one, a line each), 22 made it private, 23 public, 24 archived, 25 unarchived; in the home channel, 26 joined the server, 27 left it. Those from 16 on are never unread. |

### server

```json
{"name": "e2e", "version": "1.4.0", "description": "", "icon": null,
 "max_attachment": 104857600, "registration": {"open": false, "email": false, "invite": false}}
```

## Events: the WebSocket

```
GET /api/v1/events
Authorization: Bot <token>          (or ?token=<token>)
```

This upgrades to a WebSocket. Every frame the gateway sends is text,
one JSON object each:

```json
{"t": "MESSAGE_CREATE", "s": 118, "d": {...}}
```

`t` is what happened, `s` its number (one more than the event before),
and `d` the data. The bot sends nothing, and anything it does send is
ignored. The gateway pings every 30 seconds and closes a socket that
hasn't answered for 75. Every WebSocket library answers pings by
itself.

The first frame is **READY**, with everything you need to start:

```json
{"t": "READY", "s": 117, "d": {
  "me": {...}, "server": {...}, "roles": [...], "accounts": [...],
  "convs": [...], "online": ["2", "3"]}}
```

`online` lists the accounts online at that moment. On a connection
that's only just been made, `PRESENCE_UPDATE`s may follow straight away
for people who were already online. A READY can also come later in the
stream: the gateway's connection to the server had to start over (the
server restarted, say), and READY says how things are now.

Everything you do yourself comes back as events too: your posts, your
reads.

### Events

| `t` | `d` |
| --- | --- |
| `READY` | as above |
| `MESSAGE_CREATE` | a [message](#message) |
| `MESSAGE_UPDATE` | a [message](#message) as it is now: edited, pinned or unpinned |
| `MESSAGE_DELETE` | `{id, conv_id}` |
| `MESSAGE_REACTION_ADD`, `MESSAGE_REACTION_REMOVE` | `{message_id, conv_id, emoji, count, account}`: `count` is how many have it now, `account` who reacted or took it back |
| `MESSAGES_PURGED` | `{conv_id, before_id, what, author_id, from_id}`: messages (or, with `what` `files`, only their files) older than `before_id` are gone. Or, when `author_id` isn't `null`, that account's messages from `from_id` on are gone (pinned ones too), and `before_id` is `"0"`; a thread root of theirs that others replied to stays, deleted (a `MESSAGE_UPDATE` comes first) |
| `TYPING_START` | `{conv_id, thread, account}` (never your own) |
| `CONV_UPDATE` | a [conversation](#conversation), new to you or changed |
| `CONV_DELETE` | `{id}`: you aren't in it any more |
| `READ_UPDATE` | `{conv_id, last_read_id, unread, mentions}` |
| `ACCOUNT_UPDATE` | an [account](#account), new or changed |
| `ROLE_UPDATE` | a [role](#role) |
| `ROLE_DELETE` | `{id}` |
| `PRESENCE_UPDATE` | `{account_id, online}` |
| `SERVER_UPDATE` | the [server](#server) |
| `SELF_UPDATE` | [me](#me): your own permissions or flags changed |
| `LOGGED_OUT` | `{reason, ban_reason}`: `revoked`, `password_changed`, `disabled`, `deleted` or `banned` (then `ban_reason` is why, otherwise `null`). The socket closes after this. |
| `INVALID_SESSION` | `{}`: a resume couldn't be done; READY follows |

Events the gateway doesn't recognise are dropped, so a newer server
never confuses an older bot.

### Resuming

If the socket drops, come back with the last `s` you got:

```
GET /api/v1/events?resume=118
```

You're sent what you missed, starting from 119, and no READY. The
gateway keeps a token's last 500 events, and keeps its connection to the
server for 5 minutes after the socket goes, so that's how long a bot has
to come back. If it can't resume (too long, too much missed, or the
gateway restarted) you get `INVALID_SESSION` and then READY.

### Closing

One socket per token: a new one closes the old with **4000**. That's
usually a bot restarted before its old process died, which the old
process should take as "stop". Other codes:

| Code | |
| --- | --- |
| 4000 | Another socket with this token took over. |
| 4001 | The token doesn't work any more (after LOGGED_OUT). Don't reconnect. |
| 4002 | The server can't be reached. Reconnect after a while. |
| 1001 | The API is stopping. Reconnect after a while. |

## Limits

- **Requests:** each token may make `rate` requests a second (default
  10), with up to `burst` at once (default 30). Every request counts,
  including opening the event socket and transfers. Past that, you get
  429 with `Retry-After`. Wait that many seconds before trying again.
- **Tokens in use at once:** `max_connections` (default 64). Past that,
  503. A token stops counting 5 minutes after its last request, or 5
  minutes after its event socket closes.
- **Bodies:** at most 512 KiB, but for uploads.
- **Quiet connections** close after 60 seconds between requests.
- **The server's own limits** apply as for anyone: messages of 65535
  bytes at most, 10 files a message, 1000 pins in a conversation, 4
  uploads (and 4 downloads) at a time, and the attachment size and rate
  in its config.

## What the API does not support currently

Voice and calls (other than moving and muting people, above), files
offered peer to peer in DMs, registering and invites, server settings
and emoji, and the admin side (making channels, roles, members,
disabling accounts, purging other than with a ban).

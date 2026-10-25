# Moderation: moving, muting and disconnecting people in voice, and bans

The goal: roles that can keep order without being admins.

- **Move** someone from one voice room to another by dragging them in the
  channel list.
- **Disconnect** (kick) someone from a voice room, from the menu that a
  right-click on them in the channel list opens.
- **Mute** someone for everyone, from the same menu.
- **Ban** an account, optionally removing what it posted recently or
  ever.

Branch `moderation-plan`, off master (10f7192). Sizes as in `misc/next`.

| # | Change | Size | Status |
| --- | --- | --- | --- |
| 1 | Wire and database: permissions, Server_Muted, requests, bans table | M | |
| 2 | Server: move, disconnect, mute | M | |
| 3 | Client: menu items, mute shown, notices | M | |
| 4 | Client: dragging people between rooms | M | |
| 5 | Bans on the server, and in the client | L | |
| 6 | Purging one author's messages | M | |
| 7 | CLI client, server CLI, bot API, docs | S | |

Phases 1–4 are the voice part and stand on their own; 5–6 are bans. They
could be built and tested as two halves.

## Where things are today

- `proto.Permission` (accounts.odin) has 0–10; 11 on are free. Roles
  carry a `Permissions` bit set (u64), so new permissions need no
  migration. `can(acc, perm)` and `outranks(acc, perms)`
  (server/roles.odin) are the checks: someone can only manage accounts
  whose permissions are a subset of their own. The owner can't be
  touched.
- `proto.Account_Flag` (u8) uses 6 bits: Owner, Disabled, Must_Change,
  Deleted, Unverified, Bot. Account records, flags included, go to every
  client (`encode_account`, Account_Changed).
- `proto.User_Flag` in the snapshot is a full u8 (Muted, Deafened,
  Sharing, Decodes_HEVC, Decodes_AV1, In_Voice, In_Call, Camera), and
  says only what a user did to themselves (datagrams.odin).
- Voice rooms: `voice_join` (server/conv_requests.odin) checks the Voice
  right (channel-access). `conn_set_room` moves a connection and
  `Voice_Moved [room]` tells it it was moved — today used when another of
  its account's connections joins a room, by `room_check` when it loses
  Voice, and by calls. The client already handles being moved to another
  room or to none.
- `relay_voice` (server/server.odin) forwards a connection's voice to
  everyone else in its room.
- Client: clicking (left or right) a person under a channel opens
  `user_menu` (ui_users.odin) on the *press*: volume, mute for me,
  buddy, watch screen. `rail_drag` (ui_servers.odin) is the one drag in
  the UI: the server rail's order, with DRAG_START before it counts as a
  drag.
- Disabling an account (`Account_Disable`, Manage_Accounts) sets
  Disabled and logs out all its devices; it keeps everything else.
  Accounts > Disable in the settings (ui_manage.odin).
- Purging (proto/purge.odin, server/retention.odin): one conversation or
  all, everything *before* a time, messages or only files, in chunks on
  the retention step machine, one purge at a time. `Msgs_Purged [conv]
  [before][what]` tells clients. Pinned messages and thread roots with
  kept replies stay. `messages` has no index on `sender`.
- Registration (register.odin) may be open, by invite, with email
  verification. `accounts.email` is unique where not ''.

## Decisions

Each has a recommendation; change any you disagree with.

**D1 — Which permissions.** Recommended: three new server-wide
permissions,

	Move_Members = 11, // move people between voice rooms, and out of them
	Mute_Members = 12, // mute people for everyone
	Ban_Members  = 13, // ban and unban accounts (phase 5)

Disconnecting is moving to no room, so it goes with Move_Members (as in
Discord). Alternative: a separate Kick_Members = 14 if you want roles
that may kick but not move.

**D2 — Server-wide, not per channel.** Recommended: permissions, like
Manage_Messages, not new channel rights. A moderator moderates every room
they can see. Per-channel moderators would be a new Conv_Right later
(Conv_Rights has one bit left).

**D3 — Who can be acted on.** Recommended: the same rule as for managing
accounts: not the owner, not yourself, and only accounts that `outranks`
says you outrank. Bots can't be in voice, so they don't come up.

**D4 — Mute lasts until it is lifted.** Recommended: a server mute is a
flag on the account (`Account_Flag.Server_Muted`, bit 6), kept in the
database, so leaving and rejoining or reconnecting doesn't lift it. It
covers every room on this server. It only stops the voice: the server
drops the account's voice datagrams in `relay_voice`. Screen sharing and
the camera stay. Alternative: a mute that ends when they leave the room.

That takes the second-to-last free account flag. A server deafen would
take the last; it isn't in this plan (not asked for, and less useful).

**D5 — Moving rules.** Recommended: the person moved must be allowed in
the target room (Voice there, so not text only, not a private channel
they aren't in), and the mover must be able to see it. The mover needn't
be in either room. Only people in a room on this server can be moved;
someone in a DM call can't (calls are private).

**D6 — Disconnect.** Recommended: takes them out of the room, and they
may rejoin straight away. Keeping someone out is what a mute, the Voice
right or a ban is for. No cooldown.

**D7 — Telling the person.** Recommended: they see a short notice in the
voice panel: "Moved to #games by Alice", "Disconnected by Alice". For
that, Voice_Moved gets an optional trailing `[by u32]`. A server mute is
an account flag with no author, so it shows as "Muted by a moderator"
(the mic button shows it too and can't lift it); who did it is in the
server log.

**D8 — Dragging.** Recommended:

- Only for those with Move_Members, only with the mouse (not on touch
  screens, where a drag scrolls the list).
- A left press on a person no longer opens the menu at once: it opens on
  release if the pointer moved less than DRAG_START. A right press still
  opens it at once.
- While dragging, the person's name follows the pointer, and the channel
  row under it is highlighted if they may be moved there (D5; the client
  knows the rights of channels it has, and the server checks anyway).
  Dropping elsewhere does nothing.
- Dropping on a channel without a room (text only) does nothing.
- The menu also gets **Move to…** with a list of rooms, so moving works
  on a phone and without a mouse.

**D9 — What a ban is.** Recommended: a ban is a disable with a record.
`Ban_Set` sets Disabled and logs the account out (like Account_Disable),
and adds a row to a new `bans` table: the account, who banned it, when,
a reason (optional, up to 200 bytes), and the account's email address at
that time. While the row exists, registering with that email address is
refused (the same answer as "taken", so it doesn't reveal the ban).
Unbanning removes the row and clears Disabled. Enabling a banned account
through Account_Disable also removes the row, so the two can't disagree.

No IP or device bans: everyone on the web comes through the relay, many
people share addresses, and a new key costs nothing. No timed bans for
now (easy to add later with an `until` column).

**D10 — Ban without Manage_Accounts.** Recommended: Ban_Members alone
may ban and unban (subject to D3), and see the ban list. Manage_Accounts
keeps disabling and deleting.

**D11 — Purging on a ban.** Recommended: the ban dialog has a choice:
*don't remove messages* (default), *the last hour*, *the last 24 hours*,
*the last 7 days*, *all of them*. It removes their messages in
**channels only**; DMs are between two people and the other side keeps
them. Alternative: DMs too.

**D12 — What an author purge removes.** Recommended: all of the author's
messages in range, pinned ones too (it's their content being removed,
not old content being expired). A thread root of theirs that has replies
from others becomes a deleted message (the usual placeholder), so the
thread stays readable; other roots go entirely. Reactions they made stay
(they are counts on others' messages; removing them is a separate
question).

**D13 — Purging one author without banning.** Recommended: yes. The
purge request gets an author, so Settings > Purge (Permission.Purge) can
remove one person's messages, and the user menu gets **Remove messages…**
for those with Purge. The ban dialog's purge is allowed with Ban_Members
alone.

**D14 — Record.** Recommended: server log lines for every action (who,
whom, what, where), as for disabling today. A moderation log visible in
the client is out of scope.

## 1. Wire and database

*Protocol*, backwards compatible (no HELLO_VERSION bump):

- Permissions Move_Members = 11, Mute_Members = 12, Ban_Members = 13;
  their descriptions in the Roles page (`ui_roles.odin`).
- `Account_Flag.Server_Muted` (bit 6). Older clients ignore it.
- Requests (free ids next to Voice_Join 0x0039 and Account_Disable 0x0073):

		Voice_Move   [account u32][room u32]   room 0 disconnects
		Voice_Mute   [account u32][on u8]
		Ban_Set      [account u32][on u8][reason str8][purge u8]
		             purge: 0 none, 1 hour, 2 day, 3 week, 4 all (D11)
		Ban_List     ->  [count u16]([account u32][by u32][time u64]
		             [reason str8])...

- `Voice_Moved [room u32]` gets an optional `[by u32]` (0 or missing:
  not a person, as today).
- `Purge` gets an optional `[author u32][since u64]` (phase 6): with an
  author, everything of theirs posted at or after `since` (0: all) goes,
  and `before` is ignored. `Msgs_Purged` gets an optional
  `[author u32][from u64]`: messages of that author with id >= `from`
  are gone. An old client that doesn't read the trailing fields would
  drop *everyone's* messages below `before`, so the server sends
  `before = 0` with an author, which an old client takes as "nothing"
  (checked: `msgs_purged` in conn/messages.odin only drops ids below
  `before`). Old clients keep showing the removed messages until they
  load the conversation again.

*Database*: schema bump with a `bans` table

	CREATE TABLE bans (
		account INTEGER PRIMARY KEY REFERENCES accounts(id),
		by      INTEGER NOT NULL,
		time    INTEGER NOT NULL,
		reason  TEXT NOT NULL DEFAULT '',
		email   TEXT NOT NULL DEFAULT ''
	);
	CREATE INDEX bans_email ON bans(email) WHERE email != '';

and `CREATE INDEX messages_sender ON messages(sender, id)` for phase 6.
Server_Muted lives in `accounts.flags`, which needs no migration.

Tests: encode/decode round trips, old-length bodies still decode.

## 2. Server: move, disconnect, mute

- `voice_move`: checks D1/D3/D5, finds the target's connection that is
  in a room (one per account), `conn_set_room`, sends Voice_Moved with
  `by`, bumps the version. Room 0 is disconnect. Answers Not_Found if the
  target isn't in a room, Denied for rights, Invalid for self/owner.
- `voice_mute`: checks D1/D3, sets or clears Server_Muted with
  `account_set_flags`, `account_changed`.
- `relay_voice`: return early if the sender's account is Server_Muted.
  A cheap flag test on the hot path.
- Log lines (D14).
- Tests in `server/moderation_test.odin` on the harness: move between
  rooms, into a room without Voice (Denied), into a private room the
  target isn't in, disconnect, outranking, mute survives rejoin and
  reconnect, muted voice isn't relayed, unmute.

## 3. Client: menu items, mute shown, notices

- `conn/`: requests `voice_move`, `voice_mute`; `Voice_Moved` keeps `by`
  for the notice.
- `user_menu`: for someone in a room on this server, and only with the
  permission: **Mute for everyone** / **Unmute for everyone**
  (Mute_Members), **Move to…** (a list of rooms they may join) and
  **Disconnect** (Move_Members). Under the existing "for me" items,
  apart from them so the two mutes can't be confused.
- A server-muted person gets a distinct mark in the room list (the
  muted mic in the warning colour) and "Muted by a moderator" in the
  menu card.
- Our own server mute: the mic button shows it and can't unmute; the
  voice panel says so. We stop encoding and sending while it is on (it
  would be dropped anyway).
- Notices (D7) in the voice panel for a few seconds.
- Check: narrow (phone) layout of the menu, the web build.

## 4. Client: dragging people between rooms

As D8. A small `Voice_Drag` state on UI, like `ui.rail`: who (account,
num), where the press was, whether it became a drag. The user row starts
it on a left press when we have Move_Members and they are in a room on
this server; `channel_rows` highlights the row under the pointer when it
is a valid target and, on release, calls `voice_move`. The dragged name
is drawn last, over everything, at the pointer. Escape cancels.

The menu change (open on release, not press) must keep the
screen-mark/camera-mark clicks working, which check the press.

Check off-screen (headless weston + xdotool, see the testing notes):
drag to another room, to a text-only channel (nothing), cancel, a plain
click still opens the menu, right-click too.

## 5. Bans

Server:

- `ban_set` (D9/D10/D3): on → Disabled + bans row + logout + (phase 6)
  purge; off → remove row, clear Disabled. Account_Disable off also
  removes the row.
- `ban_list` for Ban_Members.
- Registration and `Account_Create` refuse an email address in `bans`.
  Email change (if an account can change its address) too.
- Tests: ban logs out every device, can't log in, re-register with the
  same email refused, unban restores login, outranking, enable via
  Account_Disable clears the ban.

Client:

- User menu (anywhere a person can be clicked: channel list, member
  list, chat): **Ban…** with Ban_Members. A dialog: reason, the purge
  choice (D11), Ban (red), Cancel.
- Settings: a **Bans** page (with Ban_Members): who, by whom, when,
  reason, Unban. The Accounts page shows "banned" instead of "disabled"
  for a banned account.

## 6. Purging one author's messages

- `retention_ask` with an author: a step kind that walks
  `messages_sender` instead of the id range, applies D12 (threads with
  others' replies → deleted placeholder), D11 (channels only for a ban)
  and otherwise reuses `purge_messages_chunk`'s removal of reactions,
  mentions, pins, files.
- `Msgs_Purged` per conversation touched, with author and `from`.
- Client: drop that author's messages from `from` on in the loaded
  views; threads and pins update.
- Settings > Purge: an optional person; the user menu's **Remove
  messages…** (Purge) with the same time choices as the ban dialog.
- Tests: author purge leaves others' messages, thread root placeholder,
  pins removed, DMs untouched for a ban purge, a purge running blocks a
  second one (Conflict) as today.

## 7. CLI client, server CLI, bot API, docs

- Headless client: `/move <name> <channel>`, `/disconnect <name>`,
  `/servermute <name>`, `/ban <name> [reason]`, `/unban <name>`,
  `/bans`.
- Server CLI: `account ban|unban <name>`, `bans`.
- Bot API: the same as endpoints, for bots whose roles hold the
  permissions. Moving others doesn't need the bot to be in voice, so all
  three work for bots.
- docs/API.md, docs/Server.md.

# Moderation: moving, muting and disconnecting people in voice, and bans

The goal: roles that can keep order without being admins.

- **Move** someone from one voice room to another by dragging them in the
  channel list.
- **Disconnect** (kick) someone from a voice room, from the menu that a
  right-click on them in the channel list opens.
- **Mute** someone for everyone, from the same menu.
- **Ban** an account, optionally removing what it posted recently or
  ever.

Branch `moderation-plan`, off master (10f7192). Sizes as in [next.md](next.md).

| # | Change | Size | Status |
| --- | --- | --- | --- |
| 1 | Wire and database: permissions, Server_Muted, requests, bans table | M | done |
| 2 | Server: move, disconnect, mute | M | done |
| 3 | Client: menu items, mute shown, notices | M | done |
| 4 | Client: dragging people between rooms | M | done |
| 5 | Bans on the server, and in the client | L | done |
| 6 | Purging one author's messages | M | done |
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

**D5 — Moving rules.** The mover must be able to see the target room and
enter it themselves (See and Voice there, so never a text-only channel).
The rights of the person being moved aren't checked, so a moderator can
bring someone into a room they couldn't join on their own. The mover
needn't be in either room. Only people in a room on this server can be moved;
someone in a DM call can't (calls are private).

A user that was moved into a channel they normally can't see or enter
should
- be able to see the channel name for the duration they are in the channel
- stay in the channel and not be kicked by the server when it re-checks the members
the user should only leave the channel either when they leave themselves
or are moved/kicked out of the channel.

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
  row under it is highlighted if we may move them there (D5: we have See
  and Voice there; the client knows its own rights in its channels, and
  the server checks anyway).
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

The banned person sees the reason: when they are banned, every device of
theirs that is online is logged out with a new Logout_Reason.Banned that
carries the reason, and the client shows "You were banned from <server>"
with it instead of the login screen. Later attempts get the same: a
known device that reconnects is told Logged_Out(Banned, reason) instead
of being silently left logged out, and a password login is answered
Banned with the reason. Who banned them isn't shown. An empty reason
shows as "No reason was given".

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

- `Logout_Reason.Banned = 5`; `Logged_Out [reason u8]` gets an optional
  `[text str8]`, the ban's reason. Older clients read only the first byte
  and show their generic logged-out text for an unknown reason.
- A new response status `Banned`, answering Auth_Login, with the body
  `[text str8]`. Older clients treat an unknown status as a failure.
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

*As built:* the codecs are in `proto/moderation.odin`, which also
documents the requests and rules; `rpc.odin` has Voice_Move 0x003D,
Voice_Mute 0x003E, Ban_Set 0x0075, Ban_List 0x0076 and Status.Banned 13
(body `[reason str8]`, `encode_banned`). `MAX_BAN_REASON` is 200 bytes,
Ban_List holds the newest bans that fit (MAX_BANS_LISTED 1000 for
decoding). Logged_Out goes through `encode_logged_out` /
`decode_logged_out` everywhere (server, client, `lite`); without a text
the body is the one byte it always was.

A Purge by author must have `before = 0` (`decode_purge` refuses a time
and an author together, and neither), so an older server answers it
Invalid rather than purging everyone's old messages. Until phase 6 the
server answers an author purge Invalid, and the client and the bot
gateway ignore a Msgs_Purged with an author.

The gateway maps Status.Banned to 403 `banned` (docs/API.md), and the
permissions show up there as `move_members`, `mute_members`,
`ban_members`. The Roles page already offers them, with no effect until
phases 2 and 5.

Schema 30 is the first step after the squashed baseline.
`test_db_upgrade_28` builds its version-28 database from a current one,
so it now drops what step 30 adds first; `test_db_bans_step` takes a
baseline database to 30.

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
  rooms, into a room the mover has no Voice or See in (Denied), into a
  room the target has no Voice in (allowed, D5), into a text-only
  channel (Not_Found), disconnect, outranking, mute survives rejoin and
  reconnect, muted voice isn't relayed, unmute.

*As built:* `server/moderation.odin` (`moderation_request`, reached from
`rpc_handle` after `role_request`). `moderation_target` is the shared
check: the permission (Denied), a live account (Not_Found), not oneself
or the owner (Invalid), outranked (Denied). It will serve Ban_Set too.

Differences from the text above:

- A target channel without Voice for the mover, text-only ones
  included, is Denied (as Voice_Join answers), not Not_Found.
- The mover must also be able to see the room the person is in now
  (`room_hidden`), otherwise Not_Found, so nobody learns who is in a
  private room by trying to move them out of it. Someone in a call is
  Not_Found too.
- Moving someone to the room they are in is Ok and tells them nothing.

*Guests (D5 as clarified, built with phase 3):* `Conn.guest_room` is
the room a moderator moved the connection into. `conn_set_room` clears
it whenever the connection goes anywhere else (and logging out does).
While it holds, `room_check` leaves the connection there whatever its
rights, unless the room itself goes (the channel is archived or made
text only), and `room_hidden` lets the account see who is in it.
Voice_Moved carries the channel's name (`[name str8]` after `by`), which
is how the moved person learns the name of a channel they don't have.
`test_voice_guest` covers it: moved into a private channel, sees itself
there while others outside don't, stays through a rights change, can't
come back on its own once it has left, and leaves with the room when
the channel is archived.

The mute is checked in `relay_voice` on the account flag, one test per
frame. Unmuting someone who isn't muted, or muting twice, is Ok and
sends nothing.

Tests (`server/moderation_test.odin`): `test_voice_move`,
`test_voice_mute` (including the flag in the database after a
reconnect), and `test_muted_voice_dropped`, which sends real voice
frames over loopback sessions as `bulk_test` does: frame 2, said while
muted, never arrives, frame 3 after the unmute does. Test accounts get
the permissions on top of everyone's (`+=`), since `outranks` compares
against the target's full set, which includes everyone's Attach_Files.

## 3. Client: menu items, mute shown, notices

- `conn/`: requests `voice_move`, `voice_mute`; `Voice_Moved` keeps `by`
  for the notice.
- `user_menu`: for someone in a room on this server, and only with the
  permission: **Mute for everyone** / **Unmute for everyone**
  (Mute_Members), **Move to…** (the rooms we may join, D5) and
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

*As built:* `conn/moderation.odin` has Voice_Move_Command and
Voice_Mute_Command (by id, or by name for the headless client),
`voice_moved` (the notices, and the guest room) and the mute helpers.

- The menu's "Moderation" part (`moderation_items` in ui_users.odin)
  comes after the "for me" controls, under a dim heading. **Mute for
  everyone** / **Unmute for everyone** is there for anyone we may mute,
  not only people in a room, since the mute is the account's. **Move
  to...** opens a list of the rooms we may talk in (our channels with
  Voice), and **Disconnect from voice** needs the clicked connection to
  be in a channel's room here. It is hidden for the owner and for bots;
  the server judges outranking, and a refusal comes back as a notice.
- Muted by a moderator: a crossed-out mic in `theme.warning` in front
  of the name (before deafened and self-muted), "Muted by a moderator"
  on their card. For ourselves the same icon on the mic button (whose
  click still switches our own mute, which is every server's), and the
  voice panel's first line says "Muted by a moderator" in that colour.
- Our voice isn't sent at all while our account is Server_Muted
  (`capture_loop`'s `sending`): a tone client went from 50 frames a
  second sent to 0 when muted.
- Notices use the existing `notify` line: "bot1 moved you to # games.",
  "bot1 disconnected you from voice.", "A moderator muted you on this
  server. Nobody here hears you.", "A moderator lifted your mute on this
  server." Voice_Moved without a mover keeps its old log line (another
  device), and room 0 without one now says the right lost.
- The guest room's name is kept in `Conv_Client.guest_room/guest_name`
  until a snapshot shows we left it (`guest_left`; Voice_Moved and the
  snapshot arrive separately), and reaches the panel as
  `View.guest_name` (`voice_room_name`) and the logs through
  `room_name`.

Checked off-screen (weston, test server on 17860): the menu as owner,
mute (icon, card, button label, the target's notice and send counter),
the room list, moving into a private channel the target isn't in, and
from the target's GUI the panel naming `# secret`, "Muted by a
moderator", the mute surviving a new login, unmute and disconnect
notices; the menu at 420 px wide. The web build type-checks but wasn't
run.

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

*As built:* `ui_voice_drag.odin`. `Voice_Drag` is on `Server_UI` (next to
the menu's state, so each server keeps its own): the connection pressed
on, its account and room, where the press was, whether it became a drag,
and the channel under the pointer this frame.

- `member_row` starts it on a left press when `can_drag`: we have
  Move_Members, no touch screen has been used (`ui.touched`), they are
  in a channel's room (not a call), and they aren't the owner or a bot
  (as in the menu). The screen and camera marks are checked first, on
  the press, as before. Anyone else, and a right press, still get the
  menu on the press.
- `channel_rows` passes each channel's block (its row and the rows of
  the people in its room) to `voice_drag_target`, which outlines it in
  the links' colour, as a file drop is, when the pointer is on it, it is
  on screen in the list, it isn't their room and we have Voice there.
  A text-only channel has no Voice, so it is never marked.
- `voice_drag_frame`, last in `layout`, starts the drag at DRAG_START
  (the rail's, now shared), draws the name in a small window just off
  the pointer (so the window doesn't take the hover), and on the release
  sends Voice_Move_Command to the marked channel, or opens the menu if it
  never became a drag. Escape, the person leaving or being moved by
  someone else meanwhile cancels it.

Checked off-screen as the owner: bot2 dragged from Lobby to games
(outlined while held, moved on release), onto the text-only `secret`
(not outlined, nothing sent), Escape while held over Lobby (outline and
name gone, nothing sent on release), a plain left click and a right
click both open the menu. The screen/camera marks weren't clicked (the
headless client can't share); their code is unchanged and runs before
the drag check.

## 5. Bans

Server:

- `ban_set` (D9/D10/D3): on → Disabled + bans row + logout + (phase 6)
  purge; off → remove row, clear Disabled. Account_Disable off also
  removes the row.
- `ban_list` for Ban_Members.
- The reason reaches the banned person (D9): Logged_Out(Banned, reason)
  to every online device when banned; the same to a known device of a
  banned account when it reconnects (`auth_known_device`); Auth_Login
  answers Banned with the reason (instead of Denied), but only once the
  password is right, so the reason isn't shown to whoever guesses a
  username.
- Registration and `Account_Create` refuse an email address in `bans`.
  Email change (if an account can change its address) too.
- Tests: ban logs out every device with the reason, a reconnecting
  device and a correct password login get the reason, a wrong password
  doesn't, can't log in, re-register with the
  same email refused, unban restores login, outranking, enable via
  Account_Disable clears the ban.

Client:

- User menu (anywhere a person can be clicked: channel list, member
  list, chat): **Ban…** with Ban_Members. A dialog: reason, the purge
  choice (D11), Ban (red), Cancel.
- Being banned: a screen in place of the login screen for that server,
  "You were banned from <server>" and the reason, with Remove server and
  Close. The web build shows it the same way.
- Settings: a **Bans** page (with Ban_Members): who, by whom, when,
  reason, Unban. The Accounts page shows "banned" instead of "disabled"
  for a banned account.

*As built:* server in `server/bans.odin`. The bans are held in memory on
`Accounts` (`bans`, loaded with the accounts) as well as in the table.
`ban_set` checks with `moderation_target` (as moving and muting do),
sanitizes the reason to one line, records the ban (replacing an earlier
one), disables the account and logs out every device with
Logged_Out(Banned, reason). Unbanning needs Ban_Members and outranking,
not `account_live`, so a deleted account can be unbanned too (which frees
its address). `auth_known_device` tells a banned account's device why on
every connection; `login_finish` answers Banned with the reason only
after the password matched (a wrong one is still Wrong_Password), and a
disabled account that isn't banned is still Denied. Registration answers
Email_Taken and the email change Conflict for a banned address.
Account_Disable(off) removes the ban. A Ban_Set with a purge is answered
Invalid until phase 6, so the client doesn't offer it yet.
`test_ban` covers all of it, including the record surviving a reload.

Client: `conn/moderation.odin` has Ban_Command and Bans_Command (the list
goes to `View.bans`), and `told_banned`, which keeps the reason in the
auth state (`banned`, `ban_reason`, and `ban_count`, which counts each
time the server said it) for the login screen. `ui_bans.odin`:

- The menu's Moderation part ends with **Ban...**, which opens "Reason
  (they will see it)", a text box, Cancel and a red Ban, inside the menu
  (as the rail's menu confirms leaving), or **Unban** for someone in the
  list. The menu asks for the list once so that it knows.
- The login card shows "You were banned from <server>." and the reason
  (or "No reason was given.") in place of the form, with Remove server
  (the rail's leave, keeping the key) and Close. Close shows the form
  until the server says it again (`UI_Bans.closed` against `ban_count`).
- Settings > Bans (Ban_Members): name, "by X, date", the reason, Unban.
  The Accounts page asks for the list too and shows "(banned)".
- Headless `/ban <name> [reason]`, `/unban <name>`, `/bans` (phase 7's,
  done early for testing).

Checked off-screen: as the owner, Ban... with a typed reason from bot2's
menu in the channel list (the headless bot2 logged out and told the
reason), the Bans page and "(banned)" on Accounts; as bot2 in the GUI,
the banned card on reconnecting, Close, a wrong password ("Wrong username
or password." only), the right one (the card again), and logging in
after a headless `/unban`. Remove server wasn't clicked (it is the rail's
own leave), and the web build type-checks but wasn't run.

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

*As built:* in `retention.odin` the Messages and Files steps take an
`author` (and `from`, and `channels` for a ban's): `retention_ask` sets
the step to go from the first message at or after `since` (cursor
`from - 1`) to the last message there was then (`below`), and the scan
uses `Purge_Author_Scan` / `Purge_Author_Files` over `messages_sender`,
filtered by conversation (`?5`) and to channels (`?6`). Every scan now
also reads `thread_root`. `purge_author_message` removes a message pinned
or not; a root with a reply by someone else (or a newer one of theirs,
`Purge_Reply_Other`) is made a deleted message with the same statements
as Msg_Delete instead, and a removed reply adds its root to the step's
roots for `thread_changed`. Files by author go from pinned messages too.
The author, `from` and `channels` are kept in the meta table like the
rest, so an interrupted author purge resumes.

`step_finished` sends the deleted roots' Msg_Changed first and then
Msgs_Purged with the author, `from` and `before` 0, so a client keeps a
root that is deleted and has a thread. Purge with an author is allowed
with Permission.Purge (Not_Found for an unknown account). `ban_set` with
a purge answers Conflict while another purge runs, before banning, and
otherwise queues a channels-only author purge after the ban (nobody
waits for its answer). Tests: `test_purge_author` (range, pinned, roots,
replies in others' threads, DMs included, the event, permissions) and
`test_ban_purge` (Conflict first, then only the last day's, in channels).

Client: `msgs_purged` (conn/messages.odin) removes, with an author, that
account's messages from `from` on anywhere in each window (`purged_by`),
keeping deleted thread roots, forgets their thread roots, and asks for
the pins again if they are shown; Files strips theirs. `test_author_purged`
covers it.

- The ban form in the menu has **Remove their messages: none / last hour
  / last 24 hours / last 7 days / all**, one button that picks the next
  on each click (a dropdown can't open inside the menu). They go from
  channels only (D11); the label doesn't say so for lack of room.
- **Remove messages...** (Permission.Purge) in the menu: "Theirs of: last
  hour" (picks the next), "In every conversation, for good", Cancel and a
  red Remove. It purges everywhere, DMs too, as Settings > Purge does.
- Settings > Purge history has **Whose** (a username, or empty for
  everyone's). With a name, "Older than" becomes "From the last ... days
  (0: all of them)", the note says their pinned messages go too, and the
  question names them.
- Headless `/banpurge <name> hour|day|week|all [reason]` and
  `/purgeuser <name> [days]`.

Checked off-screen as the owner: bot2's menu opened from the chat;
Remove messages (the choice cycled) took bot2's three messages out of
Lobby, their thread root with bot3's reply became "message deleted" with
the reply kept, and the unread count went from 5 to 2; Ban with "Remove
their messages: last hour" and a reason banned bot2 and removed the two
messages it had just posted; Settings > Purge with Whose "bot3" asked
"This removes for good bot3's messages in every conversation from
<date> on." and removed bot3's two.

## 7. CLI client, server CLI, bot API, docs

- *Done early, for testing phase 3:* `/voicemove <name> <channel>`,
  `/voicekick <name>`, `/servermute <name>`, `/serverunmute <name>`
  (`/move` and `/kick` were taken).
- Headless client: `/move <name> <channel>`, `/disconnect <name>`,
  `/servermute <name>`, `/ban <name> [reason]`, `/unban <name>`,
  `/bans`.
- Server CLI: `account ban|unban <name>`, `bans`.
- Bot API: the same as endpoints, for bots whose roles hold the
  permissions. Moving others doesn't need the bot to be in voice, so all
  three work for bots.
- docs/API.md, docs/Server.md.

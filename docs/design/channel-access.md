# Channels: default, text only, and who may do what in them

The goal: more control over a channel than public or private.

- **Default**: new accounts are subscribed to it, like the Lobby, but
  can leave it.
- **Text only**: the channel has no voice room.
- **Rights by role**: for each channel, which roles may
  - see it (find it in the join dialog, subscribe, read),
  - write in it,
  - react to messages,
  - edit their own messages,
  - delete their own messages,
  - talk in its voice room.

Branch `channel-access-plan`, off master (9c7e86a). Sizes as in `docs/design/next.md`.

| # | Change | Size | Status |
| --- | --- | --- | --- |
| 1 | Wire and database: new flags, channel rights, schema 27 | M | done |
| 2 | Default channels | S | done |
| 3 | Text-only channels | S | done |
| 4 | Rights on the server: see, write, react, edit, delete, voice | L | done |
| 5 | Rights in the client: the rights grid, composer, message menu, voice button | M | done |
| 6 | Role changes re-check every channel | S | done |
| 7 | CLI client and bot API | S | done |
| 8 | Attaching files as a right | S | done |

## Where things are today

- `proto.Conv_Flag` (u8): `Home`, `Private`, `Archived`. The `convs`
  table has a `flags` column, so new flags need no migration.
- `conv_visible` (server/convs.odin) is the one check for "may know it
  exists": member, or a channel that isn't private. Browse, subscribe,
  members, voice join, `room_hidden` and `room_check` all go through it.
- Reading, posting, reactions, edits, typing, mentions, search and
  attachments check `conv_is_member` (messages.odin `conv_of_member`,
  mentions.odin, msg_changes.odin, reactions.odin, search.odin,
  attachments.odin). Membership alone means "may read and write".
- `msg_edit` and `msg_delete` (msg_changes.odin): one's own messages,
  and anyone's with Manage_Messages (delete only).
- `voice_join` lets anyone who can see a channel into its room (bots
  excepted).
- New accounts join the home channel in three places:
  `account_create_finish` (auth.odin), register.odin and bots.odin.
- Client: `ui_channel_settings.odin` is the Channels category (list on the
  left, `channel_editor` on the right, the create form under the list);
  `ui_channels.odin` has the channel list with its phone icon and the
  join dialog (`Conv_Browse`); `ui_message_menu.odin` the message menu;
  `conn/convs.odin` the requests.
- Clients ignore events they don't know (conn/rpc.odin), and a single
  conversation record (`decode_conv`) ignores bytes after its fields;
  conversation *lists* (`decode_conv_list`, Conv_Browse pages) don't.
- The bot API's conversation object has `home` and `private`
  (docs/API.md).

## The rules

Each channel has a **rights map**: for each role, the rights that role
has there. The rights are

	Conv_Right :: enum u8 { See, Write, React, Edit, Delete, Voice }

An account's rights in a channel are the union of the rights of all its
roles there, `everyone` included (D1: a set of roles per right, which is
the same thing seen from the other side). Role order plays no part (D5).

A new channel's map is `everyone: all rights`, which is what every
channel has after the migration too, so nothing changes until someone
changes a map. Taking a right from `everyone` and giving it to some
roles is how a channel is limited. A right that no role has is held
only by those below.

The owner and anyone with Manage_Channels have every right in every
channel (D2). Manage_Messages still deletes anyone's messages in
channels its holder can see; the Delete right is about one's own.

**Dependencies**, applied after the union (D4):

- Nothing without See.
- Edit and Delete only with Write. So someone who loses Write can no
  longer edit or delete what they wrote before (a muted user can't
  clean up after themselves). That follows from D4; the alternative is
  to tie them to See only.
- Voice never in a Text_Only channel.

The client grid shows a dependent right greyed out when its role's row
lacks what it depends on, but the server works on the union, so a role
with Edit but not Write still gives Edit to someone whose other role
gives Write.

What each right covers:

| Right | Covers |
| --- | --- |
| See | In the join dialog, subscribing, the channel list, history, search, downloading its attachments, who is in its voice room, being notified (mentions, @everyone/@role, digests, push) |
| Write | Posting, replying in threads, forwarding into it, uploading attachments for it, typing notices |
| React | Adding and removing one's reactions |
| Edit | Editing one's own messages |
| Delete | Deleting one's own messages |
| Voice | Joining its voice room |

**Private** stays as it is and combines with the rights: a private
channel is for the members who were added *and* have See.

**Home** can have its rights limited (a read-only lobby for
announcements is a real use), except that `everyone` always keeps See
there, since everyone is in it. It can be text only.

**Default** is a flag. A new account is subscribed to every default
channel in which it has See at the moment it is created, the same way as
the home channel. It may leave it like any other channel. Private
channels can't be default (Invalid). Turning Default on doesn't subscribe
existing accounts (D3), and a default channel that an account can only
see later isn't subscribed then either (D8).

**Text only** is a flag. The channel has no voice room: Voice_Join is
refused, and turning it on moves everyone out of the room (as
`room_check` does today when someone leaves a private channel).

**Deleting a role** removes it from every channel's map (D6). If that
leaves a right with no role, only the owner and Manage_Channels have it
there: the channel closes rather than opens.

### Losing See keeps the subscription

When an account loses See (a role taken away, the map changed), its
membership row stays, with its read position and notify level (D7). It is
told `Conv_Removed`, taken out of the voice room, and to it the channel
is as good as a private one it isn't in. Getting See back shows the
channel again where it was left.

This means "member" no longer implies "may read". A new helper replaces
`conv_is_member` wherever it decides access (not where it means "is in
the members table", such as `conv_member_add`):

	// conv_rights returns what an account may do in a conversation:
	// membership where needed, Archived, Private, Text_Only, the rights
	// map and the dependencies. A DM gives both its accounts every right
	// but Voice.
	conv_rights :: proc(s: ^Server, conv: ^Conv, acc: ^Account) -> proto.Conv_Rights

`conv_visible` becomes "`.See in conv_rights`, or a public channel in
which the account would have See"; `conv_of_member`/`member_conv`
become "member and See".

## 1. Wire and database

*Protocol*, all backwards compatible (no HELLO_VERSION bump):

- `Conv_Flag` gains `Default = 3`, `Text_Only = 4`.
- `Conv_Rights :: bit_set[Conv_Right; u8]`.
- `Conv_Changed` gains one optional trailing byte, `[rights u8]`: the
  receiver's own rights there. A record without it (from an older
  server) means every right, except Voice when Text_Only. It is only
  added by `encode_conv` (single records), not by `put_conv`, so the
  layout of conversation lists (Conv_Browse pages) doesn't change and old
  clients keep decoding them. The join dialog doesn't need rights.
  Ordinary clients never learn the map, only what they may do.
- `Conv_Create  [name][topic][private u8][flags u8]`: the last byte is
  optional and takes `Default`, `Text_Only` (others are ignored). An old
  server ignores it.
- `Conv_Update` gains the mask bit `CONV_UPDATE_FLAGS`, followed by
  `[flags u8]` (Default, Text_Only; Private stays fixed after creation as
  today). An old server answers Invalid to an unknown mask bit.
- New requests, Manage_Channels only:
  - `Conv_Rights_Get  [conv u32]  ->  [count u8]([role u32][rights u8])...`
  - `Conv_Rights_Set  [conv u32][count u8]([role u32][rights u8])...`
    replaces the whole map. A role missing from it has no rights there.
    Every role must exist; on Home, `everyone` must have See (Invalid
    otherwise). At most MAX_ROLES entries.

*Server*: `Conv` gets `rights: map[proto.Role_Id]proto.Conv_Rights`
(owned; empty for a DM). Migration 27:

	CREATE TABLE conv_rights (
		conv   INTEGER NOT NULL REFERENCES convs(id),
		role   INTEGER NOT NULL REFERENCES roles(id),
		rights INTEGER NOT NULL,
		PRIMARY KEY (conv, role)
	);
	INSERT INTO conv_rights SELECT id, 1, 63 FROM convs WHERE kind = 0;

(63 = every right; 1 = EVERYONE_ROLE. `conv_add` inserts the same row for
a new channel. Schema 27 may clash with another unmerged branch that also
adds a step; whichever merges second renumbers.)

`conv_record` gives the receiver's rights; `send_conv` encodes them.
Tests in proto/convs_test.odin: Conv_Changed with and without the
rights byte, a browse page decoding as before, Conv_Create/Conv_Update
old and new bodies, Conv_Rights_Get/Set round trips and limits.

*As built:* proto/convs.odin has `Conv_Right`/`Conv_Rights`,
`CONV_RIGHTS_ALL`, `CONV_SETTABLE_FLAGS`, `conv_rights_settle` (the rules
between rights) and `conv_rights_default` (a record without the byte),
`Role_Rights` and the rights map encoders; Conv_Rights_Get 0x003B,
Conv_Rights_Set 0x003C. `decode_conv_create` now returns the flags
(Private among them) instead of a `private` bool; `encode_conv_create`
takes them as an optional last argument and leaves the byte out when
there's nothing to say. The server sets the rights in `send_conv` (the
accounts aren't reachable from `conv_record`). `conv_rights(conv, acc)`
lives in server/convs.odin, with `conv_rights_set` and
`conv_rights_role_gone` (already called by `role_delete`, D6). The
requests and a first `channel_access_changed` (re-sends Conv_Changed to a
channel's members) are at the end of conv_requests.odin. The client
keeps the rights in `Conv_Info.rights`. Tests: proto `test_conv_rights`
and the extended record/create/update tests; server
conv_rights_test.odin `test_conv_rights_map`.

## 2. Default channels

- Server: one proc, `account_join_defaults(s, acc)`, called where the
  home channel is joined today (auth.odin, register.odin). Bots get the
  home channel only, as now: a bot is added where it's wanted.
- `conv_update`/`conv_create` accept `Default`; Invalid together with
  Private or on Home (Home already is more than default).
- Client, channel settings: a **Default** checkbox in the create form
  and in the editor ("New members join it. They can leave."). The
  editor's description line says "Default: new members join it." The
  channel list in settings marks it (like 🔒 for private; e.g. ★).
- Tests (roles_test.odin): a new account is in default channels, can
  leave one, and isn't put in a default channel it has no See in.

*As built:* `account_join_defaults(c, acc)` (server/convs.odin) replaces
joining the home channel in `account_create_finish` and register.odin.
Accounts made with the offline `yap-server account` commands still only
get the home channel (at startup, as before): they don't go through it.
`channel_flags_ok` (conv_requests.odin) refuses Default with Private or
Home, for Conv_Create and Conv_Update. Client: `Create_Channel_Command`
and `Conv_Update_Command` carry `flags`; `View_Channel` has `flags` and
`rights`. The editor's Default/Text only checkboxes are edited state,
sent with name and topic by its one Save (mask NAME|TOPIC|FLAGS). The
settings list marks a default channel with ⭐. Tests in
conv_rights_test.odin (`test_default_channels`), not roles_test.odin.

## 3. Text-only channels

- Server: `voice_join` refuses (`Denied`) a Text_Only room;
  `CONV_UPDATE_FLAGS` turning it on runs `room_check`, which already
  moves people out with `Voice_Moved` to 0.
- Client: no phone icon on a channel row without Voice (covers text only
  and the right alike), no voice members drawn under a text-only one;
  hotkeys/commands that join voice skip it. Settings: a **Text only**
  checkbox in the form and the editor.
- Camera and screen share follow the room, so they need nothing.
- Tests: joining a text-only room is refused; turning it on empties the
  room.

*As built:* `voice_join` and `room_check` already go by the Voice right
(`conv_rights`), which covers text only and the voice part of phase 4.
`conv_update_request` runs `room_check` after every change. Client: the
conversation header leaves the phone button's place empty without Voice
(unless we're still in the room); `voice_command` refuses with a notice
("That channel has no voice room." / "You can't talk in that channel.")
and the rejoin after a reconnect skips such a room. The channel list
needed no change: a text-only room never has anyone in it.
`test_text_only_channels`.

## 4. Rights on the server

- `conv_rights` as above, in convs.odin; the union over roles in a small
  `role_rights(conv, acc)`.
- Call sites by right, each answering `Denied` (or `Not_Found` for See,
  as for private channels today):
  - **See**: `conv_visible`, browse (BROWSE_ALL still lists everything
    for managers), subscribe, members, `conv_shown` (the login sync),
    history, search, mentions (who is notified), digest.odin,
    push_notify.odin, attachment downloads, `room_hidden`.
  - **Write**: `msg_post`, `msg_forward` (the target), thread replies,
    attachment uploads for that conversation, `handle_typing`.
  - **React**: reactions.odin, adding and removing.
  - **Edit**: `msg_edit`.
  - **Delete**: `msg_delete` of one's own message (Manage_Messages
    deleting someone else's is unchanged).
  - **Voice**: `voice_join`.
- `Conv_Rights_Set` stores the map in one transaction (delete the
  channel's rows, insert the new ones), then
  `channel_access_changed(s, conv)` (6).
- `conv_member_set` (adding someone with Invite): refused (`Denied`) if
  the target has no See there, so nobody is added to a channel they'd
  never see.
- `role_delete` also deletes the role's `conv_rights` rows and drops it
  from every `Conv.rights` (D6).
- Tests: for each right, an account without it is refused and one that
  has it through any of its roles isn't; Edit/Delete refused without
  Write even when granted; Manage_Channels has everything; browse and the
  login sync leave out a channel without See; a mention doesn't reach an
  account without See; deleting a role that alone held a right closes
  it.

*As built:* `conv_visible(conv, acc)` now takes the account and is
`.See in conv_rights`; `conv_shown` takes the account; new
`conv_reader(conv, acc)` = member with See, used where membership used to
decide reading: `msg_of_member`, reactors, forward's source, attachment
downloads, search across conversations, and the fan-out loops
(`msg_deliver`, typing, reactions, role/@everyone mentions) so a member
who lost See isn't sent anything. A direct mention needs See before it
counts or subscribes; digest items from channels the account can't see
are skipped. `conv_role_rights` (the map without the private-membership
check) is what `conv_member_set` checks before adding someone.
`send_conv_to_account` skips accounts that can't see the channel.
Write: `msg_post`, `msg_forward` (target), `handle_typing`. React:
`msg_react`. Edit: `msg_edit`. Delete: `msg_delete` of one's own message;
Manage_Messages deletes any message regardless. Uploads aren't tied to a
conversation until posted, so Write on the post covers them.
`test_conv_rights_enforced`.

## 5. Rights in the client

- `conn`: the receiver's rights on each channel (`Conv_Info.rights`,
  from the trailing byte, defaulting as the wire says);
  `Conv_Rights_Command` (get, answer stored on the View like the members
  list) and `Conv_Rights_Set_Command`; `Conv_Update_Command` grows
  `flags`.
- Channel settings editor, under Name and Topic, the flags and then the
  rights as a grid, one row per role in Roles-list order with `everyone`
  last:

		Default      [x] New members join it
		Text only    [ ] No voice room

		             See  Write  React  Edit  Delete  Voice
		Moderator    [x]   [x]    [x]   [x]    [x]    [x]
		Member       [x]   [x]    [x]   [x]    [x]    [x]
		everyone     [x]   [ ]    [x]   [ ]    [ ]    [x]
		                                         [ Save ]

  The Voice column is hidden for a text-only channel; `everyone`'s See is
  fixed on Home; a dependent box is greyed when its row lacks what it
  depends on (it can still be ticked, see the rules). A line under the
  grid says what holds for those with only `everyone`, e.g. "Everyone
  else can read and react, but not write." One Save for flags and grid,
  as for name and topic today. In the narrow (phone-width) layout each
  role becomes a heading with its six checkboxes in two rows of three.
- Composer: without Write, the text area is replaced by one dim line,
  "You can't write in this channel.", and pasting or dropping files does
  nothing.
- Message menu and hover buttons: React, Edit and Delete are left out
  when the right is missing (Delete stays for others' messages with
  Manage_Messages). Clicking an existing reaction to join it does
  nothing without React.
- Join dialog: nothing to do, the server leaves out what you can't see.
- Run the GUI headless (see the off-screen testing notes) with two
  accounts and check: the composer line, the message menu, the missing
  phone icon, the join dialog, and that changing the grid updates an
  open client.

*As built:* conn/roles.odin: `Conv_Rights_Get_Command` /
`Conv_Rights_Set_Command`, `View.rights_map` (`View_Rights_Map`),
`rights_text`, `role_name`. The grid (`channel_rights` in
ui_channel_settings.odin) keeps its boxes in `UI_Channel_Admin.cells`
(a checkbox's id is its address) and has **its own Save** under it,
rather than sharing the flags' Save: the flags sit above Place/Delete and
the grid below, and a Save far from what it saves read badly. The
summary line reads "Those with no other role here: see, react. The owner
and those who manage channels may do everything." When narrow, each role
is a heading with labelled boxes, three to a row. `rights_here` /
`rights_in` (ui_channels.odin) give the viewed (or a thread's) channel's
rights. Without Write, the chat and a thread show `read_only_line`
instead of the composer (drops then have nowhere to land, since only a
drawn attach button takes them). The message bar leaves out React and
the recent reactions without React, Edit without Edit, Delete of one's
own without Delete; `send_reaction` refuses without React (covers the
picker and the timeline's chips); Up no longer starts an edit without
Edit; Forward only offers channels with Write. A refused post says "you
can't write there". **Not done:** the Roles page's delete confirmation
doesn't name the channels a role is in the map of (the client only
fetches the map of the channel being edited).

Checked off-screen against a test server: bot2 (everyone: see, react)
sees the read-only line and no phone button in a text-only channel, and
its reaction went through; bot1 (owner) sees the flags and the grid,
ticking a box turns the button into "Save rights", saving reaches the
server and comes back as "Saved"; unticking Text only shows the Voice
column; the 420 px layout shows the labelled boxes.

## 6. Role changes re-check the channels

Rights now depend on roles, so these can change what someone may do:
`account_roles_request`, `role_delete`, `role_set` (Manage_Channels given
to or taken from a role), `Conv_Rights_Set`, `CONV_UPDATE_FLAGS`, and an
account being created. Role_Order doesn't (D5).

One proc does it: `channel_access_changed(s, conv: ^Conv = nil)` (nil
for every channel). Channels and accounts are few and in memory, so it
goes over every channel × connected account and sends `Conv_Changed`
(new rights, or a channel that can be seen again) or `Conv_Removed` (no
longer See), then `room_check` and one `bump_version`. Clients already
handle a Conv_Removed for a channel they have and a Conv_Changed for one
they don't. If sending unchanged records turns out noisy, remember each
connection's last rights per channel and send only differences.

The Roles page's delete confirmation names the channels whose maps
mention the role.

Tests: giving a role shows a channel and its rights; taking it away
removes the channel and moves the account out of the room; a rights
change reaches a connected client.

*As built (with phase 4):* `channel_access_changed` sends Conv_Changed
to members who can see, Conv_Removed to those who can't, runs
`room_check` per channel and one `bump_version` (room lists depend on
See). Called after Conv_Rights_Set, every Conv_Update, and in roles.odin
after `account_roles_request`, `role_delete` and `roles_changed`. It
always sends to every member; no diffing yet. The Roles page's delete
confirmation doesn't name the channels yet (phase 5's client side).
Covered by `test_conv_rights_enforced`.

## 7. CLI client and bot API

- CLI (`channels_cli.odin`), next to `/create`, `/private`, `/rename`
  and `/topic`, acting on the channel being viewed: `/default on|off`,
  `/textonly on|off`, `/rights` (print the map) and
  `/rights <role> see,write,react,edit,delete,voice` (or `none`). They
  are what the server tests and headless checks drive.
- Bot API: the conversation object gains `"default"`, `"text_only"` and
  `"rights": ["see", "write", ...]`; docs/API.md updated. An action
  without the right answers 403.

*As built:* CLI in channels_cli.odin (with the client in phase 5):
`/default on|off` and `/textonly on|off` (`Conv_Flag_Command`, which
keeps the other flag), `/rights` (prints the map) and
`/rights role=right,... ...` (`Conv_Rights_Text_Command`, parsed by
`conv_rights_parse`; replaces the whole map, a role may be a name or a
number, `none` for none). Gateway: `Conv_JSON` has `default`,
`text_only` and `rights`; Denied already was 403 `denied`. The gateway
test checks a channel's six rights and a DM's five.

## 8. Attaching files as a right

Asked for after testing (2026-10-22): attaching files is a right of its
own, like writing.

*As built:* `Conv_Right.Attach` (bit 6, after Voice so stored values
keep their meaning), in `CONV_RIGHTS_ALL`; it needs Write like Edit and
Delete, and still also the server-wide Attach_Files permission. Schema
28 gives Attach to every role that has Write in a channel, which is what
they could do before (checked on a copy of a schema-27 test database:
63→127, 7→71, 31→95). The server refuses (`Denied`) a post with
attachments, or a forward of a message with files, into a channel
without Attach; uploads themselves aren't tied to a conversation, so
they aren't checked. Client: `attach_allowed` (ui_attachments.odin) is
checked by `attach_button` (no paperclip, so drops don't land either)
and by `attach_add`, which every way of attaching goes through (dialog,
paste, drop, web), with the notice "You can't attach files here." The
grid has an Attach column after Write. CLI and API take and show
`attach`. Tests: proto `test_conv_rights`, server
`test_conv_rights_attach`, the gateway test's counts.

## Decisions

| # | Question | Decision |
| --- | --- | --- |
| D1 | "Minimum role": a role and everything above it in the Roles list, or a set of roles? | A set of roles so we have flexibility. Stored as a role → rights map per channel. |
| D2 | Who passes every gate? | The owner and Manage_Channels (they can change the gate anyway). |
| D3 | Turning Default on: subscribe existing accounts too? | No. Possibly later a "Add everyone now" button in the editor. |
| D4 | Write gate: reactions and edits? | Reacting to messages, editing your own message and deleting your own message should all be separate permissions. Delete and edit depend on the write permission. |
| D5 | Role_Order once order means access | Order should not matter, we will use a set of roles. |
| D6 | Deleting a role used as a gate | It gets removed from any set it is used in. |
| D7 | Losing see access: keep or drop the subscription? | Keep it, hidden (see "Losing See keeps the subscription"). |
| D8 | Default channel that a new account can't see yet, but later can (gets a role) | Not subscribed then either; Default is about account creation only. Doing it later needs a per-account "already offered" record so leaving it sticks. |

### Accepted as recommended

The plan was approved with these open (2026-10-22), so they were built as
recommended.

| # | Question | Recommendation |
| --- | --- | --- |
| D9 | Edit and Delete need Write, so losing Write also stops someone deleting their old messages. Intended? | Keep as decided (it's the simpler rule); tie Delete to See only if muted users should still be able to remove what they wrote. |
| D10 | Do Edit/Delete apply per role row (greyed boxes can't be ticked) or after the union (as written)? | After the union: a role that only adds Edit is useful on top of one that gives Write. |

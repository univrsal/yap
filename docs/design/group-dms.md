# Group DMs

A conversation between three to eight people that isn't a channel: like a
DM, but for a few. Step 1 of mattermost-import.md, where Mattermost's
group messages need somewhere to go, and useful on its own ("the three of
us who are planning the release").

Branch `mattermost-import`. Sizes as in `docs/design/next.md`. Built
and covered by the server's and the protocol's tests; the UI has not been
tried by hand yet.

| # | Change | Size | Status |
| --- | --- | --- | --- |
| 1 | Wire and database: the Group kind, members in the record, Group_Open, version 16 | M | built (2026-10-28) |
| 2 | Server: opening, visibility, posting, rights, push, digest, links | M | built (2026-10-28) |
| 3 | Client: the list, titles, avatars, notifications | M | built (2026-10-28) |
| 4 | Client: starting a group (the picker) | M | built (2026-10-28) |
| 5 | Bot API and the headless client | S | built (2026-10-28) |

## Where things are today

- `proto.Conv_Kind` is `Channel` or `DM`. A DM's two accounts are `a` and
  `b` (a < b) on the conversation, in the database (`convs.a`, `convs.b`)
  and on the wire (the conversation record). Both are members
  (`members`) and stay members; there is no leaving a DM.
- `DM_Open [account]` finds or creates the DM (`dm_find`, `dm_add`,
  keyed by the pair in `Convs.dms`) and tells the opener at once. The
  other account is told when the first message is posted
  (`msg_posted_reply`, messages.odin), so an opened, empty DM doesn't
  show up on their side (`conv_shown`).
- Rights in a DM are everything but voice
  (`proto.conv_rights_default(.DM)`), for its two members only
  (`conv_rights`).
- What else treats DMs specially on the server:
  - pins: anyone in a DM may pin (`may_pin`, msg_changes.odin);
  - file offers (direct transfers, files.odin) are only possible in a
    DM, to `dm_other`;
  - push: every message in a DM is pushed to the other account, in a
    channel only mentions are (`push_message`);
  - the email digest counts DM messages as `Direct` (digest.odin);
  - links to a DM's messages are made plain text anywhere else
    (`links_restrict`, messages.odin), since nobody else could follow
    them;
  - a DM with a deleted account can be read but not written to
    (`dm_closed`, account_delete.odin);
  - last seen is shown only to those one has exchanged DMs with
    (`messages_exchanged`, buddies.odin);
  - calls (calls.odin) are between two accounts, not in a conversation;
    they leave their system message in the DM of the two.
- The server only accepts a hello with exactly its own `HELLO_VERSION`
  (15), so a client and a server always agree on the wire format.

## The design

### What a group is

- A third `Conv_Kind`, **`Group`**. Its members are 3 to
  `MAX_GROUP_MEMBERS` (8, as in Mattermost) accounts, the opener among
  them. They are its members in `members`; `a` and `b` are 0.
- **The members are fixed** (D1). Nobody joins or leaves a group, and
  nobody is added: a different set of people is a different group, as
  in Mattermost. There is one group for each set of accounts.
- **No name and no topic** (D2): the client shows the other members'
  names. (A name may come later; nothing here prevents it.)
- **Rights as in a DM**: every right but voice, for members only, nobody
  else anything. Not even those with `Manage_Channels` can see a group
  they aren't in, as with DMs.
- **No calls** (D3). Calls are between two accounts; a group call would
  be a voice room for the group, which is its own feature.
- **No file offers** (direct transfers); attachments work as in any
  conversation.

### Opening a group

`Group_Open [count u8][account u32]...  ->  [conv u32]` names the
*other* members (2 to 7, the opener is implied). The server sorts them,
adds the opener, and finds the group for exactly that set (`group_find`,
keyed by the sorted set in `Convs.groups`) or creates it (`group_add`).
Like `DM_Open`:

- The opener is told about it at once (`Conv_Changed`), the others when
  the first message is posted. A group that was opened and left empty
  doesn't show up on their side.
- Answers: `Invalid` for fewer than 2 or more than 7 others, the opener
  among them or someone twice; `Not_Found` for an account that isn't
  live, and `Denied` for a bot (D4).

Two people are a DM, not a group: a client asks `DM_Open` for one other
person and `Group_Open` for more.

### On the wire (version 16)

The conversation record carries the members of a group. `a` and `b`
become a list:

	conversation  [id u32][kind u8][flags u8][name str8][topic str8]
	              [count u8][account u32]...   <- was [a u32][b u32]
	              [last message u64][member u8] ...

For a channel the list is empty, for a DM it has the two accounts
(lower id first, as `a` and `b` were), for a group its members in
ascending order. `proto.Conv` gets `members: [MAX_GROUP_MEMBERS]Account_Id`
and `member_count` in place of `a, b`, and `CONV_MAX_SIZE` grows by 24
bytes. That changes every record, hence a new `HELLO_VERSION`; all
clients and servers update together, as with every version before.

(D5: the alternative is to keep `a` and `b` and append the list after
`rights`, which an old client ignores; it would then show groups as
whatever it makes of an unknown kind. Not worth it with the exact
version check.)

### In the database

`convs.kind = 2`, `a` and `b` NULL, the members in `members` as for every
conversation. No schema step is needed: kind is an integer and members
are rows already. `Conv_Add_Group` inserts the conversation; the members
are added with `conv_member_add` as `dm_add` does.

`Convs.groups: map[Group_Key]^Conv`, where `Group_Key` is the sorted
member ids padded with 0 (`[MAX_GROUP_MEMBERS]Account_Id`), is built when
loading, after the members.

### What the server does differently

Each place that treats a DM specially, and what a group does there:

| Where | DM today | Group |
| --- | --- | --- |
| `conv_rights` | members: all but voice | the same |
| `conv_shown` | after the first message, or for the opener | the same |
| first message (`msg_posted_reply`) | tells the other account | tells every other member |
| `may_pin` | anyone | anyone |
| file offers | to `dm_other` | refused (`Invalid`) |
| `push_message` | every message to the other | every message to each other member, as `"group"`; mentions as in a DM |
| digest | `Direct` | `Direct` |
| `links_restrict` | links into a DM become text elsewhere | the same for groups (only its members could follow them) |
| `dm_closed` | deleted account: read only | a group stays writable while two of its members are live (D6) |
| `messages_exchanged` | from the DM | unchanged: groups don't count |
| calls | between two accounts | none |
| debug log of a post | "a DM with account N" | "a group of N, M, ..." |
| `cli_purge` | "the DM <name>" | "the group <names>" |

`notify` defaults to All for groups as for DMs: every message is for
everyone in it.

### Account deletion

A deleted account stays a member of its groups, shown under the
tombstone's name: deleting an account removes its memberships of channels
and DMs (account_delete.odin), but not of groups, because a group's
members are what it is (its key in `Convs.groups`, and the list its
record carries). Its groups stay readable; with fewer than two live
members left a group is closed like a DM with a deleted account (D6). A
new group of the remaining people is a different group.

## The client

The client's DMs are built around one other person, more than the
server's are. The inbox (the Direct messages page, `Page.Buddies`) is a
list of *people*: `Buddy_Entry` has one `account`, the selection is
`ui.buddies.selected: Account_Id`, opening from another server is
`ui.inbox_open: Account_Id`, and `open_conversation(ui, account)` is what
"Write to them", the palette's "Message <name>" and notification clicks
call. A DM that doesn't exist yet is opened lazily: the composer's
`dm_to` goes into the outbox, which sends `DM_Open` on the first post
(conn/outbox.odin). `dm_other` and `dm_with` (conn/buddies.odin) are the
two places that turn a DM into its other person.

### Data

- `Conv_Info` gets the record's member list in place of `a, b`.
  `dm_other` stays for DMs; `dm_with` skips groups.
- `View_DM` becomes the view of both kinds: `with` stays for a DM, and a
  group has `members` (the others, in the server's order) and, unlike a
  DM, `mentions`. `publish_channels` puts groups into `v.dms`, so unread
  totals, `may_pin_here`, `go_to_message` and search find them without
  changes of their own.
- `rights_in` (ui_channels.odin) already gives anything that isn't a
  channel DM rights, which is right for groups.

### The inbox

The inbox becomes a list of *conversations that may be people*: an entry
is a person (a buddy, or a DM with someone) or a group. `Buddy_Entry`
gets a `group` with its members; the selection, `inbox_open` and the
composer's target become an entry key, `{account}` or `{conv}`, instead
of an account. People keep working exactly as now, including a person
with no DM yet.

A group's row:

- **Name**: the other members' display names, in that order, joined with
  ", " and cut with "..." to fit ("Alice, Bob, Carol").
- **Avatar**: the first two others' avatars, overlapping, smaller (as
  Mattermost and most messengers do); a number disc for the rest isn't
  needed at that size.
- No status line, presence dimming or phone icon (whose?). The status
  line shows the member count instead ("4 people").
- Sorted with the others by `last_time`, after the buddies, like a DM
  with someone who isn't a buddy; it goes under "Other conversations".
- Hiding works as for DMs (keyed by conv already).
- Right click does nothing: there is no one person to have a menu for.

The conversation header: the names as the title, "Members" (the list,
each with the usual person menu, so one can open a DM or call from
there), pins and search as for a DM. No call or file buttons. "typing..."
uses `typing_text` as channels do, so it names whoever types.

### Starting a group (step 4)

There is no picker today. Two ways in:

- **"New group..." in the inbox**, a button over the list: a window
  (ui_groups.odin) with the people picked so far and a search field over
  the server's accounts (`people_finder`, as a channel's settings have),
  up to seven people, and "Start". Start sends `Group_Open` at once,
  and the inbox opens the group as soon as the server has told us about
  it (`group_wanted_check`): the existing group if there is one. Opening
  it doesn't show it to the others, so there is no need to wait for the
  first post the way a DM does. Bots can't be picked (D4).
- **"Add people..." in a DM's header**, which opens the same window with
  the other person ticked. It starts (or finds) a group; the DM stays as
  it was. That is how Mattermost does it too, and it avoids the question
  of what earlier messages the newcomers see.

The outbox needs nothing new: a group exists by the time anything is
written in it, so its posts go to its conversation like a channel's.

### Notifications

A message in a group notifies like a message in a DM (D7): desktop
notification and the Direct_Message sound for every message, counted in
the inbox badge and the window title, unless the group's notify is set
lower. Its place in the notification is the group's name ("Alice in
Alice, Bob, Carol"), from `room_name`, which gets a group branch used by
the headless log as well.

### Things that stay one-to-one

- **Calls**: the call buttons need one person, and a group has none.
  Calling someone from a group is done from its members list.
- **File offers**: `dm_file_button` doesn't show in a group, and a `.File`
  message in a group (which the server refuses anyway) is ignored rather
  than offered.
- **Last seen**: only in a DM, as now.

### Deleted members

A member whose account was deleted shows under the tombstone's name.
The group stays writable while at least two of its members are live; with
fewer, it is read only as a DM with a deleted account is (D6).

## Bot API and the headless client (step 5)

- The conversation object's `kind` gets `group` (it comes from the enum's
  name already). A group has `members`, the ids of the *other* members,
  and no `recipient`; a DM keeps `recipient`. `GET /convs` puts groups
  with the DMs, ordered by their last message.
- `POST /groups {accounts}`: the group of the bot and those accounts,
  made if need be, like `POST /dms`. → conversation.
- `GET /convs/{id}/members` works for groups as it is.
- The headless client: `/group <name>,<name>,... <text>` like `/dm`, and
  `/buddies` lists groups with their names.
- docs/API.md and docs/examples/roll.py, which only looks for `dm`.

## Decisions

- **D1** Fixed members, one group per set of people, as in Mattermost.
  Adding someone makes (or finds) another group; nobody leaves.
- **D2** No name or topic: the client shows the members' names.
- **D3** No calls in groups. Calling someone is done from the members
  list.
- **D4** Bots can't be in groups: the picker leaves them out and
  `Group_Open` refuses them (`Denied`), and a bot can't open one.
- **D5** A new protocol version (16), with the members in the
  conversation record in place of `a` and `b`.
- **D6** A group is read only once fewer than two of its members are
  live.
- **D7** Every message notifies, like a DM; each member can lower it per
  group.

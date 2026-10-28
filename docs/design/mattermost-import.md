# Importing a Mattermost server

The goal: yap replaces a Mattermost server, keeping its people, channels,
history and files. An admin runs one command against a Mattermost export
and gets a yap database that people log in to with their old names (and,
if we can manage it, their old passwords), and where the old conversations
read the way they did.

Not a plan yet: this note lists what Mattermost has that yap can't hold
today, what maps onto something yap already has, and the decisions to make
before building. Nothing here has been tried against a real export.

| # | Change | Size | Where | Depends on | Status |
| --- | --- | --- | --- | --- | --- |
| 1 | Group DMs | L | protocol, schema, server, client | - | open |
| 2 | Raising the size limits (message text above all) | M | protocol, schema, client | - | open |
| 3 | bcrypt passwords, re-hashed on first login | S | server | - | open |
| 4 | System messages for joins, leaves and channel changes | M | protocol, server, client | - | open |
| 5 | The importer: accounts, channels, members, messages, threads, reactions, pins | XL | server (CLI) | 1–3 | open |
| 6 | Files and custom emoji | M | server (CLI) | 5 | open |
| 7 | Mentions and channel links rewritten | S | server (CLI) | 5 | open |
| 8 | Bot and webhook posts | S | server (CLI) | 5 | open |
| 9 | Saved messages | M | protocol, schema, client | - | open, optional |

Sizes as in `docs/design/next.md`.

## Where things are today

- Conversations (`convs`, proto/convs.odin) are channels or DMs
  (`Conv_Kind`). A DM is two accounts in the `a` and `b` columns; there is
  nothing for three or more. `dm_open` refuses a DM with oneself.
- One server is one community: channels have no team or workspace above
  them, and channel names are unique on the server.
- Passwords are Argon2id (hash_worker.odin); `accounts.pw_params` says
  which parameter set a row was hashed with.
- Limits (proto/*): message text `MAX_CHAT_SIZE` 2000 bytes, channel name
  `MAX_CHANNEL_NAME_SIZE` 32, topic `MAX_TOPIC_SIZE` 128, username 2–32 of
  `a-z 0-9 _ . -`, status 80, avatar 256 px and 64 KB, custom emoji names
  32 and `MAX_CUSTOM_EMOJI` 512, `MAX_PINS` 50 per conversation,
  `MAX_REACTIONS` 20 per message, `MAX_ATTACHMENTS` 10 per message. The
  largest attachment is the server's `max_attachment` (Server_Info).
- Mentions are tokens in the text (proto/mentions.odin): `<@id>`,
  `<@&role>`, `<@everyone>`. Plain `@name` is just text.
- Threads: `messages.thread_root`, with `reply_count` and `last_reply` on
  the root. Edits keep only the new text and `edited`. A deleted message
  stays with the `Deleted` flag.
- System messages (`Msg_Kind.System`) exist only for calls in DMs
  (`Call_System`: missed, declined, ended).
- Members (`members`) have `read_id` (a message id, not a time) and
  `notify` (`Notify_Level`: all, mentions, none).
- Custom emoji are pictures in the `emoji/` folder of the data directory
  (emoji.odin), picked up without a restart.
- History is read in id order (`messages_conv` on `(conv, id)`), so ids
  have to follow time.
- Bots are accounts with the `Bot` flag (bot-api.md). Incoming and
  outgoing webhooks and slash commands are listed there as later work.

## What Mattermost has

The parts of Mattermost's data an import touches, and where each goes.
"Gap" means yap can't hold it today.

### Teams (gap, decision D1)

A Mattermost server has one or more teams, each with its own channels;
channel names are unique per team. Most servers we'd replace have one
team. Options: one team per yap server (the importer takes `--team`), or
all teams merged with a prefix on names that clash.

### Accounts

| Mattermost | yap |
| --- | --- |
| `Username` (3–22 of `a-z 0-9 . - _`) | `username`, as is |
| `Nickname`, else `FirstName LastName`, else username | `display` |
| `Email`, `EmailVerified` | `email`, `Unverified` if not verified |
| `Password` (bcrypt) | see D2 |
| `AuthService` (SAML, LDAP, GitLab, ...) | no password: D2 |
| `DeleteAt` (deactivated) | `Disabled` |
| `Roles` containing `system_admin` | the admin role |
| `system_guest` | a role with few rights (D6) |
| bots (`Bots` table) | `Bot` flag, the owner kept as `created_by` if wanted |
| profile picture | avatar blob, scaled to 256 px and re-encoded under 64 KB |
| `Props.customStatus` (emoji, text, expiry) | `status`, `status_until`; the emoji goes into the text |
| `CreateAt` | `created` |
| `Timezone`, `Locale`, `Position` | dropped |

An account that was deleted for good but still has posts becomes a
`Deleted` tombstone, so its messages keep a sender.

### Passwords (gap, decision D2)

Mattermost stores bcrypt. A new `pw_params` value could mean "bcrypt":
login checks with bcrypt and, if it matches, re-hashes with Argon2id and
stores that. Core Odin has no bcrypt (check `core:crypto` first); it is
small enough to write or vendor.

Without it, every imported account gets `Must_Change` and a password the
admin hands out, or a reset by email (verify.odin already sends mail).
Accounts that logged in through SSO/LDAP need that path anyway.

I believe Mattermost's bulk export (`mmctl export create`) leaves password
hashes out, which decides D3 if we want to keep passwords.

### Channels

| Mattermost | yap |
| --- | --- |
| `Type` `O` (open) / `P` (private) | `Private` or not |
| `Type` `D` (DM) | DM |
| `Type` `G` (group message) | **gap**: group DMs (step 1) |
| `Name` (64), `DisplayName` (64) | `name`; DisplayName is what people know, so it wins; 32 bytes today (D4) |
| `Header` (1024), `Purpose` (250) | `topic`, 128 bytes today (D4) |
| `DeleteAt` | `Archived` |
| `town-square` | `Home` |
| `off-topic` and the team's default channels | `Default` |
| channel moderation (who may post, react, ...) | `conv_rights` on the `everyone` role |
| read-only channels | `everyone` without Write |

Every imported channel is probably `Text_Only` (D7): Mattermost channels
have no voice room, and turning one on is a click.

Mattermost allows a DM with oneself (a notes channel). yap refuses one;
the importer can skip them or turn them into a private channel with one
member (D8).

### Members

| Mattermost (`ChannelMembers`) | yap (`members`) |
| --- | --- |
| membership | a row |
| `LastViewedAt` | `read_id`: the last message in the channel at or before that time |
| `NotifyProps.desktop` / `mark_unread` | `notify`: `all`, `mention` → Mentions, `none` or muted → None |
| `SchemeAdmin` | nothing per channel; dropped, or a role (D6) |
| `CreateAt` (when they joined) | `joined` |

Sidebar categories and favourites (`SidebarCategories`) are per person;
yap has one `position` per channel for everyone. Dropped (D9).

### Messages

| Mattermost (`Posts`) | yap (`messages`) |
| --- | --- |
| `Message` | `text`, after the rewrites below; up to 16383 characters (D4) |
| `CreateAt` | `time`; rows inserted in `CreateAt` order across all channels so ids follow time |
| `RootId` | `thread_root`; `reply_count` and `last_reply` computed afterwards |
| `EditAt` | `edited` |
| `OriginalId` (an old version of an edited post) | skipped |
| `DeleteAt` | skipped, or `Deleted` (D10) |
| `IsPinned` | `pins` and `Pinned`; more than 50 per channel doesn't fit (D4) |
| `FileIds` | attachments (step 6) |
| `Type` `system_*` | see system messages |
| `Props.attachments` (message attachments, cards) | see bot posts |
| `Props.override_username`, `override_icon_url`, `from_webhook` | see bot posts |
| `Reactions` | `reactions`; emoji names mapped to yap's (proto/emoji_table.odin), custom ones to `:name:` |
| `Hashtags`, `Metadata` (link previews) | dropped |
| `Props.priority`, acknowledgements, reminders | dropped |

Collapsed reply threads: Mattermost remembers which threads each person
follows and how far they read (`ThreadMemberships`). yap has nothing like
it; dropped.

### System messages (gap, step 4)

Mattermost posts `system_join_channel`, `system_leave_channel`,
`system_add_to_channel`, `system_remove_from_channel`,
`system_header_change`, `system_purpose_change`,
`system_displayname_change`, `system_channel_deleted` and more. yap's
system messages are for calls only. Either new `System` kinds (the
`system` byte and `system_arg` have room: an account, or the new text in
`text`), or the importer drops them (D11). Joins and leaves are most of
them and the least missed.

### Text: mentions, channel links, Markdown (step 7)

- `@username` → `<@id>` for accounts that exist. Not inside code.
- `@channel` and `@all` → `<@everyone>`. `@here` has no equivalent;
  `<@everyone>` or plain text (D12).
- `@groupname` (custom user groups, `UserGroups`) → `<@&role>` if groups
  become roles (D6), else plain text.
- `~channel-name` → a channel link, if yap has one; else the channel's
  name as text.
- Markdown: Mattermost's is CommonMark with tables, headings, task lists,
  LaTeX and inline images. Check each against
  `client/richtext/markdown.odin`; what isn't rendered stays readable as
  text, so this only needs a look, not code.

The `mentions` rows for imported messages are written by the importer,
the same as posting would.

### Bot and webhook posts (step 8)

Integrations often post with empty `Message` and the content in
`Props.attachments` (title, text, fields, colour), and webhooks post under
a name and picture of their choosing (`override_username`). Turned into
Markdown text by the importer: the card's title in bold, its text, its
fields as a list. The name the webhook used goes at the start of the text,
or each webhook becomes a bot account of its own (D13).

The webhooks and slash commands themselves are not imported; their URLs
point at the Mattermost server. bot-api.md has them as later work.

### Files and emoji (step 6)

- `FileInfo` points into Mattermost's file store (a folder or S3). The
  importer reads each file and stores it as a File blob, with an
  `attachments` row; width and height from the picture's header as posting
  does. Thumbnails and previews are not copied. A file over
  `max_attachment` is skipped with a warning, or the limit is raised for
  the import.
- Files not attached to any post (uploads that were never sent) are
  skipped.
- Custom emoji (`Emoji` table and their pictures) are written into
  `emoji/`. Names longer than 32 or with characters yap doesn't allow
  are renamed and the reactions and texts using them follow. More than
  512 doesn't fit (D4).

### Saved messages (gap, step 9, optional)

Mattermost's "saved" posts (`Preferences`, category `flagged_post`) are a
personal list people rely on. yap has no such thing. Without it they are
lost; with it, it is a table of `(account, message)` and a list in the
client.

### Not imported

Plugins' data (Boards, Playbooks, Calls recordings), shared channels,
data retention policies, OAuth apps, sessions and access tokens,
preferences besides saved posts, and audit logs.

## Group DMs (step 1)

The one gap the import can't go without: group messages are common, and
there is nowhere to put them. A sketch, to be settled in its own note:

- A third `Conv_Kind`, `Group`, with its members in `members` and no `a`
  or `b`. Like a DM: private, no rights map, no voice room unless calls
  for groups come later, no name of its own (the client shows the
  members' names) unless someone gives it one.
- Mattermost doesn't let members be added to a group message (adding
  someone makes a new one), so yap doesn't have to either at first.
  Finding the existing group for the same set of people is what
  `dm_find` does for two.
- Mattermost allows up to 8 people in a group message; yap's limit can
  be the same.

## Decisions

- **D1** Teams: one team per yap server (`--team`), or all merged with
  prefixes on clashing names?
- **D2** Passwords: bcrypt kept and re-hashed on login, or everyone resets?
  SSO/LDAP accounts reset either way.
- **D3** Source: Mattermost's bulk export (JSONL and a zip of files), or
  its Postgres/MySQL database directly? The export is a stable format
  that includes group messages, replies, reactions and emoji, and is
  what Mattermost itself imports. It probably lacks password hashes and
  per-person read state, and the file store may need to be read
  separately. Reading the database gets everything but ties us to
  Mattermost's schema, which changes between versions.
- **D4** Limits: which to raise rather than truncate. Message text
  matters most (2000 bytes against 16383 characters, which can be four
  times as many bytes); cutting messages loses history. Channel names and
  topics next. Pins and reactions per message can probably be raised
  without much thought; check what they cost in the wire format first.
- **D5** Running it: a `yap-server import mattermost <export>` command
  against a new, empty database only, or into an existing server too?
  Empty only is much simpler (ids, names and the home channel don't
  clash).
- **D6** Roles: what Mattermost's guest, team admin, channel admin and
  custom user groups become.
- **D7** Imported channels `Text_Only`?
- **D8** DMs with oneself: skipped, or a private channel?
- **D9** Sidebar categories and favourites: dropped?
- **D10** Deleted posts: skipped, or kept as `Deleted`?
- **D11** Mattermost's system messages: new kinds, or dropped?
- **D12** `@here`: `<@everyone>` or text?
- **D13** Webhook posts: one bot account per webhook name, or the name in
  the text?

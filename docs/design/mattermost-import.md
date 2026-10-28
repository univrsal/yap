# Importing a Mattermost server

The goal: yap replaces a Mattermost server, keeping its people, channels,
history and files. An admin runs one command against a Mattermost export
and gets a yap database that people log in to with their old names, and
where the old conversations read the way they did.

Not a plan yet. Before the importer, two things: decide what yap gains so
that Mattermost's data fits (decided, see Decisions), and
look at a real export from a test instance (step 6), because the export's
documentation and its code don't say everything we need. What this note
says about the export comes from reading Mattermost's source (master,
2026-10) and from exports of a test instance (step 6, `tools/mattermost`).

| # | Change | Size | Where | Depends on | Status |
| --- | --- | --- | --- | --- | --- |
| 1 | Group DMs | L | protocol, schema, server, client | - | built (2026-10-28), see group-dms.md |
| 2 | DMs with oneself | S | protocol, server, client | - | built (2026-10-28) |
| 3 | Size limits raised to Mattermost's | M | protocol, schema, client | - | built (2026-10-28) |
| 4 | System messages for joins, leaves and channel changes | M | protocol, server, client | - | built (2026-10-28) |
| 5 | `@here` | S | protocol, server, client | - | built (2026-10-28) |
| 6 | A test Mattermost instance and a sample export | S | tooling | - | built (2026-10-28), tools/mattermost |
| 7 | The importer: accounts, roles, channels, members, messages, threads, reactions, pins, bookmarks | XL | server (CLI) | 1–6, 11, 13 | planned: 7a–7g, see The importer |
| 8 | Files and custom emoji | M | server (CLI) | 7 | open |
| 9 | Mentions and channel links rewritten | S | server (CLI) | 5, 7 | open |
| 10 | Bot and webhook posts | S | server (CLI) | 7, 12 | open |
| 11 | Bookmarks: one's own list of saved messages | M | protocol, schema, client | - | built (2026-10-28) |
| 12 | Personas: a bot posting under another name and picture | M | protocol, schema, client, bot API | - | built (2026-10-28) |
| 13 | Channel admins | M | protocol, schema, server, client | - | built (2026-10-28) |

Sizes as in `docs/design/next.md`. 1–5 and 11–13 are yap features that stand on
their own; 6 can happen alongside them and may change what 7–10 do.
The importer works only on a new, empty database (D5).

## Where things are today

- Conversations (`convs`, proto/convs.odin) are channels or DMs
  (`Conv_Kind`). A DM is two accounts in the `a` and `b` columns; there is
  nothing for three or more. `dm_open` refuses a DM with oneself.
  (Both have since been added: steps 1 and 2.)
- One server is one community: channels have no team or workspace above
  them, and channel names are unique on the server.
- Passwords are Argon2id (hash_worker.odin); `accounts.pw_params` says
  which parameter set a row was hashed with. `Must_Change` makes someone
  pick a new password at their next login.
- Limits (proto/*): message text `MAX_CHAT_SIZE` 2000 bytes, channel name
  `MAX_CHANNEL_NAME_SIZE` 32, topic `MAX_TOPIC_SIZE` 128, username 2–32 of
  `a-z 0-9 _ . -`, status 80, avatar 256 px and 64 KB, custom emoji names
  32 and `MAX_CUSTOM_EMOJI` 512, `MAX_PINS` 50 per conversation,
  `MAX_REACTIONS` 20 per message, `MAX_ATTACHMENTS` 10 per message. The
  largest attachment is the server's `max_attachment` (Server_Info).
  (Most of these were raised in step 3, see Limits.)
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

## The export

`mmctl export create` runs an export job on the Mattermost server;
`mmctl export download` fetches the result, a zip with `import.jsonl` and
a `data/` folder of files. It is the same format Mattermost imports
(`mmctl import`), and the format is versioned (the first line), so it is
the stable thing to read. Flags of `export create`:

| Flag | Default | Note |
| --- | --- | --- |
| `--no-attachments` | off | files are included unless this is given |
| `--include-archived-channels` | off | **needed**: archived channels and their posts are left out otherwise |
| `--include-profile-pictures` | off | **needed** for avatars |
| `--no-roles-and-schemes` | off | schemes and custom roles are included unless this is given |
| `--team-name`, `--team-id` | all | **don't use**: a team-scoped export has no DMs or group messages at all |
| `--channel-name`, `--channel-id` | all | |
| `--include-custom-emoji` | - | not in 10.12.4; custom emoji are missing from its exports anyway (below) |

So the export to ask an admin for is the whole instance with
`--include-archived-channels --include-profile-pictures`, and the importer
picks the team (D1). With it, the admin runs `tools/mattermost/extras.py`
against the server, for what the export misses (below).

### Lines

One JSON object per line, `{"type": "<kind>", "<kind>": {...}}`, in this
order: `version`, `role`/`scheme`, `team`, `channel`, `user`, `bot`,
`post`, `emoji`, `direct_channel`, `direct_post`. Then the files. Names,
not ids, join them: a post names its team, channel and user; a direct
post names the usernames of its channel's members.

What each line carries that we care about (from
`server/channels/app/imports/import_types.go` and `export_converters.go`):

- **user**: `username`, `email`, `auth_service` and `auth_data` (SSO),
  `nickname`, `first_name`, `last_name`, `roles` (`system_user`,
  `system_admin`, `system_guest`), `delete_at` (deactivated),
  `profile_image` (a path under `data/`), `notify_props`, display
  preferences. **No password**: the export never writes one. Deactivated
  users are exported. `custom_status` is in the format but the export
  doesn't fill it.
  - `teams[]`: team `name`, `roles` (`team_user`, `team_admin`), and
    `channels[]`: channel `name`, `roles` (`channel_user`,
    `channel_admin`), `notify_props` (`desktop`, `mobile`, `mark_unread`),
    `favorite`, `last_viewed_at`, `msg_count`, `mention_count`.
- **bot**: `username`, `owner`, `display_name`, `description`,
  `delete_at`, `profile_image`.
- **team**: `name`, `display_name`, `type`, `description`, `scheme`.
- **channel**: `team`, `name`, `display_name`, `type` (`O`, `P`),
  `header`, `purpose`, `scheme`, `deleted_at` (archived).
- **post**: `team`, `channel`, `user`, `type` (empty for a normal post,
  `system_*` for others), `message`, `props`, `create_at`, `edit_at`,
  `is_pinned`, `flagged_by` (who saved it), `reactions[]` (`user`,
  `emoji_name`, `create_at`), `attachments[]` (`path` under `data/`),
  `thread_followers[]` (`user`, `last_viewed`, `unread_mentions`) and
  `replies[]`, which have the same fields but no thread followers.
- **direct_channel**: `participants[]` (`username`, `notify_props`,
  `last_viewed_at`, counts), `favorited_by`, `shown_by`, `header`. Two
  participants are a DM, three to eight a group message. A DM with
  oneself has the same username twice.
- **direct_post**: `channel_members` (usernames), then like a post.
- **emoji**: `name`, `image` (`data/emoji/<id>/image`).
- **scheme** and **role**: permission names per role; for channel
  moderation (D6).

### What the export leaves out

- Passwords (see D2, which doesn't need them).
- Deleted posts. Deleting a root post deletes its replies too, so none
  of a deleted thread is exported; a deleted reply is missing from its
  thread. So D10 ("kept as deleted") has nothing to keep.
- By mistake (10.12.4, `server/channels/app/export.go`): **custom emoji**,
  which are only written when the export isn't a zip, and `mmctl` always
  makes one; and **reactions to the first post of a DM or group
  message**, which are only exported for replies. `extras.py` fetches
  both through the REST API into `extras.jsonl` in the export's own
  format: `emoji` lines, and `direct_post_reactions` lines that name the
  post as a `direct_post` would (`channel_members`, `user`, `create_at`).
- Edit history: only `edit_at` and the current text.
- Custom user groups (`@groupname`), sidebar categories, webhooks, slash
  commands, link preview metadata, the custom status.
- Group messages whose name doesn't match their members, and "direct
  channels with only one active member". Neither showed up on the test
  instance: DMs and group messages with a deactivated user, a DM with
  oneself and a DM with someone in another team are all exported.

### The test instance and the sample (step 6)

`tools/mattermost/` (built 2026-10-28):

- `docker-compose.yml`: Mattermost Team Edition 10.12.4 (our version)
  with Postgres, on 127.0.0.1:8068, with local mode, webhooks, overrides,
  custom emoji, bots and collapsed threads on.
- `seed.py`: fills an empty instance through mmctl and the REST API with
  one of each thing listed in its header: two teams, open, private,
  archived and restored channels, every channel change, DMs (with
  oneself, with a deactivated user, across teams), group messages,
  threads, deleted roots and replies, edits, pins, saved posts,
  reactions with custom emoji, files and a picture, `/me`, a bot with
  and without an overridden name, a webhook card, mentions and channel
  links, Markdown, Unicode and a 16 KB post, and per-channel read state
  and notification settings.
- `export.py`: runs the export as an admin would and unpacks it.
- `extras.py`: what the export misses (above).
- Under podman (rootless), `docker compose` doesn't work here: the bridge
  network fails with "create veth pair: Operation not supported". The
  header of `docker-compose.yml` says how to run the same two containers
  in a pod with pasta networking, and `CONTAINER_ENGINE=podman` makes
  `seed.py` and `export.py` use podman. Run that way (2026-10-28), the
  seed and export gave the same 147 lines as the sample.
- `sample/`: the result, made up from start to end, as the importer's
  test data. `import.jsonl` has 147 lines (85 posts, 9 direct posts, 8
  users, 3 bots); with `data/` and `extras.jsonl`, 111 KB.

What the sample answers:

- **System posts** are exported with `type` and `props`, see System
  messages (step 4). Removing someone names who did it only as the post's
  `user`. Each member's join to the team makes `system_join_team` in
  town-square and `system_join_channel` in off-topic.
- **Deleted posts** aren't exported, nor anything of a deleted thread
  (above).
- **DMs**: all exported, including with a deactivated user and with
  oneself (the same username twice). Making a bot leaves its owner a DM
  with an `add_bot_teams_channels` post from the bot.
- **Text** is as typed: `@bob`, `@here`, `@channel`, `@all`, `~secret`
  (the channel's name, not its display name), `:partyparrot:`,
  `:thumbsup_tone3:`. Posts that link a channel of their own team carry
  `props.channel_mentions` with its display name; nothing else is
  resolved. `/me waves` is `type: "me"` with the text `*waves*`.
- **Paths**: a post's `attachments[].path` and a user's or bot's
  `profile_image` are relative to `data/`, and the files are there.
  Only uploaded profile pictures are exported, plus the plugins' bots'
  (`calls`, `playbooks`).
- **Read state**: a member's `last_viewed_at` is when they last opened
  the channel; 0 or missing if they never did, even when they posted in
  it (a reply in a thread doesn't count as opening it). Threads keep
  their own: `thread_followers[].last_viewed`. See Members.
- **Membership**: whoever creates a channel is its member and channel
  admin. Leaving a team drops one's channels; joining again only gives
  back town-square and off-topic.
- **Edits** leave only `edit_at` and the text. Reactions keep `+1` and
  `thumbsup` apart, as typed.
- **Replies** inside a post's `replies[]` aren't in time order either.
- **Guests** need a license: on our unlicensed 10.12.4 there can't be
  any, so `system_guest` won't appear.
- **Size and time**: the sample exports in about 10 s, most of it the
  job starting. A real server's is for the admin to try; the export is
  a background job, so it doesn't stop the server.

### Seen on the test instance so far

**Our server's version, 10.12.4, exports without a license.** Both the
Team Edition and the Enterprise Edition with no license (what "the free
version" can mean) ran `mmctl --local export create
--include-archived-channels --include-profile-pictures` (2026-10-28, in
Docker), and the two exports were the same apart from the version line
(`enterprise: false` / `true`). They have every field the 12.0.1 export
has, and showed:

- archived channels with `deleted_at`, deactivated users with
  `delete_at`;
- a deleted post is not in the export at all;
- replies inside their post, `edit_at`, `is_pinned`, `flagged_by`,
  reactions, `last_viewed_at` and counts per channel and per DM member;
- a group message as a `direct_channel` and `direct_post`s with three
  `channel_members`;
- an attached file under `data/<date>/teams/.../<name>`, and uploaded
  profile pictures under `data/users/<id>/profile.png`;
- a webhook post with `from_webhook`, `override_username` and
  `webhook_display_name`, as in 12.0.1.

`mmctl --local` needs a shell on the Mattermost server (it talks to the
local socket); from elsewhere, `mmctl auth login` as a system admin does
the same. Custom emoji, followed threads and bots' posts: see the sample
below.

A first run (2026-10-28, Mattermost Team Edition 12.0.1 with Postgres 16
in Docker, one team, webhooks only):

- **Posts are not in time order** in `import.jsonl`, not even within a
  channel. The importer has to sort them by `create_at` before inserting
  (see Messages).
- **System posts are exported**, with their `type` and `props`:
  `system_join_channel` and `system_join_team` (`props.username`),
  `system_add_to_channel` (`addedUsername`, `addedUserId`, `username`,
  `userId`), and bot greetings such as `add_bot_teams_channels` in DMs.
- **Bots are exported**, including Mattermost's own (`calls`,
  `system-bot`), whose `owner` is a plugin id or `admin`.
- **Profile pictures**: only uploaded ones are in `data/`; accounts with
  the generated default picture have no `profile_image`.
- **Channel admins**: any number of members can be one
  (`roles: "channel_user channel_admin"` on the membership).

## Mapping

The parts of Mattermost's data an import touches, and where each goes.

### Teams

One team per yap server (D1). The importer takes `--team` and imports
its channels, the users who are members of it, and the DMs and group
messages whose members are all imported users. Other users and other
teams' channels are left out.

### Accounts

| Mattermost (`user`) | yap |
| --- | --- |
| `username` (3–22 of `a-z 0-9 . - _`) | `username`, as is |
| `nickname`, else `first_name last_name`, else username | `display` |
| `email` | `email` |
| password, `auth_service` | a generated password and `Must_Change` (D2) |
| `delete_at` (deactivated) | `Disabled` |
| `roles` containing `system_admin`, or `team_admin` in the team | the Admin role (D6) |
| `roles` containing `system_guest` | the guest role (D6); needs a Mattermost license, so not on ours |
| `bot` lines | `Bot` flag |
| `profile_image` | avatar blob, scaled to 256 px and re-encoded under 64 KB |
| `locale`, `position`, preferences | dropped |

An author that isn't in the export (a deleted account) becomes a
`Deleted` tombstone, so its messages keep a sender.

### Passwords

Every imported account gets a generated password and `Must_Change`, so
it picks its own at first login (D2). The export has no passwords anyway,
and SSO accounts never had one. The importer writes the generated
passwords to a CSV file, `username,password` with one line per account
(bots excepted), for the admin to hand out. The file holds every
account's password until they change it, so the importer creates it
readable only by its owner and says so.

### Channels

| Mattermost (`channel`) | yap |
| --- | --- |
| `type` `O` / `P` | `Private` or not |
| `direct_channel`, two members | DM |
| `direct_channel`, the same member twice | a DM with oneself (step 2) |
| `direct_channel`, 3–8 members | group DM (step 1) |
| `name` (64), `display_name` (64) | `name`; display_name is what people know, so it wins |
| `header` (1024), `purpose` (250) | `topic` (step 3); header, or purpose if there is no header |
| `deleted_at` | `Archived` |
| `town-square` | `Home` |
| `off-topic` | `Default` |
| channel scheme (who may post, react, ...) | `conv_rights` on the `everyone` role |
| `header` of a direct channel | dropped |

Every imported channel is `Text_Only` (D7).

### Members

| Mattermost (`teams[].channels[]`, `participants[]`) | yap (`members`) |
| --- | --- |
| membership | a row |
| `last_viewed_at` | `read_id`: the last message in the channel at or before that time, or the member's own last message if that is later (0 means never opened) |
| `notify_props.desktop` / `mark_unread` | `notify`: `all`, `mention` → Mentions, `none` → None; `default` → All |
| `roles` with `channel_admin` | channel admin (step 13, D6) |
| `favorite`, `favorited_by`, `shown_by` | dropped (D9) |

There is no join time in the export; `joined` is the first post's time in
the channel or the import's.

### Messages

| Mattermost (`post`, `direct_post`, `replies[]`) | yap (`messages`) |
| --- | --- |
| `message` | `text`, after the rewrites below (limits from step 3) |
| `create_at` | `time`; rows inserted in `create_at` order across all channels so ids follow time |
| reply | `thread_root`; `reply_count` and `last_reply` computed afterwards |
| `edit_at` | `edited` |
| deleted posts | `Deleted` where the export has them (D10) |
| `is_pinned` | `pins` and `Pinned` |
| `attachments` | attachments (step 8) |
| `type` `system_*` | a system message (step 4, D11) |
| `props.attachments`, `props.from_webhook`, `override_username` | step 10 |
| `reactions` | `reactions`; emoji names mapped to yap's (proto/emoji_table.odin), custom ones to `:name:` |
| `flagged_by` | bookmarks of those accounts (step 11) |
| `thread_followers` | dropped |

### System messages (step 4)

Mattermost's system posts become `proto.Conv_System` kinds (D11, D19): the
`system` byte says which, `sender` is who did it, `system_arg` an account
it was done to, and the message's text the old and the new value, a line
each. Seen in a 10.12.4 export (all are exported, with these `props`):

| Mattermost `type` | `props` | yap |
| --- | --- | --- |
| `system_join_channel`, `system_guest_join_channel` | `username` | `Joined` |
| `system_leave_channel` | `username` | `Left` |
| `system_add_to_channel`, `system_add_guest_to_chan` | `addedUserId`, `addedUsername`, `userId` (who) | `Added` |
| `system_remove_from_channel` | `removedUserId`, `removedUsername`; the post's user removed them | `Removed` |
| `system_displayname_change` | `old_displayname`, `new_displayname` | `Renamed` |
| `system_header_change` | `old_header`, `new_header` | `Topic_Changed` |
| `system_purpose_change` | `old_purpose`, `new_purpose` | `Topic_Changed` if the channel has no header (its topic is the purpose then), else dropped |
| `system_change_chan_privacy` | only the message text says which way | `Made_Private` / `Made_Public` |
| `system_channel_deleted`, `system_channel_restored` | `username` | `Archived`, `Unarchived` |
| `system_join_team`, `system_add_to_team` | `username` | `Joined_Server`, in the home channel (D20) |
| `system_leave_team`, `system_remove_from_team` | `username` | `Left_Server`, in the home channel |
| `system_join_leave`, `system_add_remove` | combined in the UI, not stored | - |
| `system_generic`, `system_ephemeral`, `system_auto_responder`, `system_wrangler`, `system_move_channel`, `system_gm_to_channel`, `add_bot_teams_channels`, `reminder` | | dropped, or plain text: step 7 decides |
| `me` (`/me`) | | text (step 9) |

Built (2026-10-28), protocol version 18:

- A system message's record has its text (`[what u8][arg u32][text
  str16]`); the server stores the kind as the number the text column
  starts with, followed by the text on the next line.
- Kinds from 16 on (`CONV_SYSTEM_FIRST`) are never unread or mentions,
  in `Msg_Unread`, the digest and the client, and notify nobody. Calls'
  (1 to 3) count as before.
- yap posts them live: joining and leaving a channel (not the home
  channel), adding and removing members (also an account added by being
  mentioned), renaming, changing the topic, archiving, and in the home
  channel an account being made (once verified, if it has to be) or
  deleted. Not for bots. The note about someone joining or being added
  comes just before they are a member, so it counts as read for them.
- Made private or public and unarchived only come from imports: yap
  channels can't change those.
- The client words them as "Alice renamed the channel from #a to #b"
  ("You" for one's own), dimmed like a call's line; the gateway gives
  `system.text` too.

### @here (step 5)

Built (2026-10-28), protocol version 19: the token `<@here>` mentions the
members whose activity is Online (connected, not idle, not set to away,
busy or offline) when the message is posted. It needs Mention_Everyone,
like `<@everyone>`, and without it is kept as the plain text `@here`.
Typing `@here` writes the token, the composer offers it, and it shows
highlighted like `@everyone`. A client counts a new `<@here>` as its
mention if it is online itself; the server's count (the `mentions` rows)
is what holds after that.

### Text: mentions, channel links, Markdown (step 9)

- `@username` → `<@id>` for accounts that exist. Not inside code.
- `@channel` and `@all` → `<@everyone>`. `@here` → `<@here>` (step 5,
  D12): everyone in the conversation who is online. Who was online when an
  imported message was posted isn't known, so an imported `<@here>`
  mentions nobody (no `mentions` rows), while it still reads as `@here`.
- `@groupname`: user groups aren't in the export, so plain text.
- `~channel-name` → a channel link, if yap has one; else the channel's
  name as text.
- Markdown: Mattermost's is CommonMark with tables, headings, task lists,
  LaTeX and inline images. Check each against
  `client/richtext/markdown.odin`; what isn't rendered stays readable as
  text, so this only needs a look, not code.

The `mentions` rows for imported messages are written by the importer,
the same as posting would.

### Bot and webhook posts (step 10)

Integrations often post with empty `message` and the content in
`props.attachments` (title, text, fields, colour), and webhooks post under
a name and picture of their choosing (`override_username`). Turned into
Markdown text by the importer: the card's title in bold, its text, its
fields as a list. Who it shows as is D13.

The webhooks and slash commands themselves are not in the export.

### Webhooks

How Mattermost does it, as seen on the test instance:

- An **incoming webhook** is a secret URL made by a user (or for a bot,
  by an admin) for one channel. It has its own default `username` and
  `icon_url`, and may be locked to its channel; unlocked, a post can name
  another channel or `@someone`.
- An **outgoing webhook** or **slash command** calls a URL; what the URL
  answers is posted the same way as an incoming webhook's post.
- **The author is the webhook's creator**: a real person's account (alice
  in the tests), or the bot's when a bot owns it. A webhook post to
  `@bob` lands in the DM between its creator and bob.
- **The name shown is per post.** With `EnablePostUsernameOverride` and
  `EnablePostIconOverride` on (both are server settings, off by default),
  the post's `username` and `icon_url`, else the hook's defaults, are
  stored as `props.override_username` and `props.override_icon_url`. The
  name is free text (`Build Server #123`), and nothing stops it from
  being a real person's username (`bob`): Mattermost's client marks such
  posts with a BOT tag, and that is all. With no name anywhere it is the
  literal `webhook`. The icon is a URL that every client fetches.
- With the overrides off, nothing is stored and the post shows as its
  creator.
- Every webhook post has `props.from_webhook = "true"` and
  **`props.webhook_display_name`**, the hook's name ("Jenkins hook").
  There is no webhook id.
- Props sent by the caller are kept (`props.card` and others).
- **Overriding is for webhooks and bots.** A person's post through the
  REST API with `override_username`, `override_icon_url` or
  `from_webhook` in its props has them removed. A bot's keeps
  `override_username` (10.12.4, seen in the sample) and has
  `from_bot`. (Server plugins can set them; not tried.)
- Posts with only a card have `type: "slack_attachment"` and an empty
  `message`.
- Everything above is in the export as stored. The webhooks themselves
  are not.

So for the import, `webhook_display_name` names the webhook, and
`override_username` names who it posed as in that one post. D13 below.

### Overridden names in yap's bot API (D14)

Mattermost's overrides, like Discord's webhooks (`username` and
`avatar_url` per call), let one integration post under many names. It is
what CI (one hook, many projects), alerting (Grafana, Alertmanager) and
bridges (a relay showing the remote person's name) want. In yap a bot has
one name and one avatar, so today each needs a bot account per name.

A bot may post as a **persona** (step 12, protocol 22, schema 34):

- A message gets an optional persona: a display name (at most 255
  bytes), and an avatar as a blob id (uploaded through the bot API with
  `POST /avatars`, not a URL that every client fetches, which would tell
  a stranger's server who is reading). It is the `Persona` flag, the
  columns `persona_name` and `persona_avatar`, a persona in `Msg_Post`
  and the message record, and a `persona` field in the bot API's
  `POST /convs/{id}/messages` and its message object. The avatar blob
  stays as long as a message uses it; anyone may fetch it then. Deleting
  the message removes the persona. A forwarded copy has none.
- The client shows the persona's name and picture, always with the bot
  badge and the bot's own name after it ("GitLab [BOT]  - via CI Bot"),
  so that it can't pass for a person. A bot's message under a different
  persona starts a new block, and the name is not coloured by the bot's
  role. The lists of pins, bookmarks and search results show the bot.
- Only bot accounts may use it. The server refuses (`Denied`) a persona
  whose name is an account's username or display name, case ignored,
  unlike Mattermost; a name that is empty once cleaned up is `Invalid`.
- Mentions, DMs and replies go to the bot, not the persona.

The importer would use it the same way: webhook posts become posts by one
bot per webhook, each with the post's `override_username` as its persona.
Avatars from `override_icon_url` are fetched once per URL by the importer
if they still load, else none.

Without personas, the import still works (D13), just with more bots or
less faithful names, and yap's own webhooks later are one bot per
webhook, which is what bot-api.md already suggests.

### Files and emoji (step 8)

- Attachments are in the zip under `data/`, named by each `path`. The
  importer stores each as a File blob with an `attachments` row; width
  and height from the picture's header as posting does. A file over
  `max_attachment` is skipped with a warning, or the limit is raised for
  the import.
- Custom emoji are `emoji` lines in `extras.jsonl` (the export misses
  them), their pictures at `data/emoji/<id>/image`, written into `emoji/`
  as `<name>.<ext>`. Names with characters yap doesn't allow are renamed
  and the reactions and texts using them follow. Beyond 512 (D18), the
  most used 512 are kept and the rest become plain `:name:` text.

### Saved messages

Mattermost's saved posts are in the export (`flagged_by`) and are a
personal list people rely on. They become bookmarks (step 11): each
username in a post's `flagged_by` bookmarks that message, at the post's
own time (the export doesn't say when it was saved).

### Not imported

Plugins' data (Boards, Playbooks, Calls recordings), shared channels,
data retention policies, OAuth apps, sessions and access tokens,
preferences besides saved posts, thread following, and everything the
export leaves out.

## The importer (step 7)

The plan, written 2026-10-28 after steps 1–6, 11, 12 and 13 were built.

### Shape

```
yap-server import mattermost <export folder> --team <name> [--owner <username>]
    [--extras <file>] [--passwords <file.csv>] [--dry-run] [--yes] [config.json]
```

Like the other `yap-server` commands (`account`, `purge`) it works on the
database of a server that isn't running, through the same `Accounts`,
`Convs` and `DB` the server uses (`cli_open` in cli_account.odin), so a
message goes in by the code that posting uses and what the server checks
when it loads is what the importer wrote.

- **Input is the unpacked export folder** (`import.jsonl`, `data/`, and
  `extras.jsonl` if it is there; `export.py` unpacks like that). Odin's
  standard library has no zip reader, so reading the zip itself is a later
  convenience (a central directory and `core:compress/zlib`'s inflate,
  about 150 lines), not a part of 7a to 7g.
- **All or nothing.** One SQLite transaction holds the whole import. If
  anything fails it rolls back, the database is still the empty one that
  D5 demands, and the command can be run again. The blob files already
  written (avatars, later attachments) aren't in the transaction; the
  importer removes the ones it wrote when it fails, and `purge` would
  collect any that are left.
- **An owner.** A server with no accounts makes `admin` when it first
  starts, which an import prevents by making accounts first, so the
  importer makes the owner: `--owner <username>` (default: the first
  `system_admin` in the export) gets `Owner` and, like every imported
  account, a generated password (D2).
- **Two passes over the posts.** Posts aren't in time order in the export
  and ids must follow time. Pass 1 reads every line once and keeps a small
  index per post (its `create_at`, its channel, where its line is in the
  file, and for a reply which of the line's `replies` it is): about 32
  bytes a post, so a million posts take 32 MB. Pass 2 sorts the index and
  reads the lines back in time order, so memory doesn't grow with the size
  of the export.
- **The report.** `--dry-run` does pass 1 and the mapping and stops,
  printing what would be made and, as warnings, everything that would be
  changed or dropped: names that had to be changed, text cut to a limit,
  authors that no longer exist, files over `max_attachment`, more than 512
  emoji, system posts of a kind that isn't mapped. The real run prints the
  same and writes it to `import-report.txt`. Nothing is changed or dropped
  without being in it.
- **No post ids.** The export doesn't say what a post's Mattermost id was,
  so permalinks (`/team/pl/<id>`) stay plain text, and everything that
  belongs to a post (reactions, pins, `flagged_by`) is read from the post's
  own line.

### Where the code goes

- `src/server/mattermost/`, a package that only reads: the line types
  (`import_types.go` as Odin structs), a line reader that checks the
  version and tolerates fields it doesn't know, the index of pass 1, and
  the pure mapping functions of 7b. It knows nothing about the database, so
  its tests run on the sample and on made-up lines.
- `src/server/cli_import.odin`: the command, the report, and the writing
  (7c onwards), in the server package because it uses the stores.
- `msg_store` (messages.odin) is split in two: the part that inserts the
  row and its attachments, and the part that sets the conversation's last
  message and a DM's `posted` flags, which the importer does once per
  conversation at the end instead of once per message.

### Sub-steps

Each ends with its tests and a commit, and each leaves a working
`--dry-run`, so the importer grows in pieces that can be tried on the test
instance.

| # | What | Size | Tests |
| --- | --- | --- | --- |
| 7a | **Reader and report.** The package's types and line reader; the checks that every post names a channel and user that exist; `--dry-run` printing counts, the chosen team's channels and users, what is left out (other teams) and the warnings so far | M | the sample; a truncated line; an unknown version; an unknown line type (skipped with a warning); a post naming a missing channel |
| 7b | **Mapping rules**, pure: usernames and display names, emails, channel names (display name wins, at most `MAX_CHANNEL_NAME_SIZE`, made unique), topic (header, else purpose), notification settings, the system post table (step 4), reaction emoji names (a map built once: `emoji_by_shortcode` scans the whole emoji table), every limit of step 3 as a clamp that adds a warning | M | one table-driven test per rule, from the sample's own values (`secret`, `old-stuff`, `partyparrot`, the 16 KB post) |
| 7c | **Accounts.** Accounts, flags (`Disabled`, `Bot`, `Owner`), the Admin role (D6), tombstones for authors who are gone, generated passwords and the CSV (mode 0600), avatars | L | accounts and flags as the table says; the CSV's mode; a second run refused (D5) |
| 7d | **Channels and members.** Channels (`Private`, `Archived`, `Home`, `Default`, `Text_Only`), DMs, DMs with oneself, groups, memberships with notify and channel admin, the `everyone` rights of a channel with a scheme | M | the sample's channels and direct channels; a group of eight; a member of two teams |
| 7e | **Messages and threads.** Pass 2: the sorted insert, `thread_root`, `edited`, system posts, the counts of replies and last replies at the end, each conversation's `last_msg`, text as it is (step 9 does the rewrites) | L | ids follow `create_at` across channels; a reply listed before its root; a thread's counts; the 16 KB post; a system post of every mapped kind |
| 7f | **Reactions, pins, bookmarks.** From each post's own line; reactions of deactivated users; `extras.jsonl`'s `direct_post_reactions`; at most 50 reactions and 1000 pins | S | counts against the sample; a reaction by a user who is gone |
| 7g | **Read state and the finish.** `read_id` from `last_viewed_at` (see Members), the unread counts, a record in `meta` of what was imported and when, `import-report.txt`, a final check by loading the result the way the server does | M | read positions at, before and after a post's time; the sample imported into a database that a test server serves: history of a channel, a DM, a thread, pins, bookmarks |

Then step 8 (files and emoji, which write blobs and an emoji folder), 9
(text rewrites, which the messages' text passes through) and 10 (bot and
webhook posts, with personas) follow on this base, as the table says.

### Testing against a real server

- The unit tests run on `tools/mattermost/sample`, which is committed. The
  test instance (step 6) makes a fresh export whenever the format of
  something needs to be looked at again.
- **A big synthetic export.** The sample has 94 posts. Speed and memory
  need an export of a size people have: `tools/mattermost/synth.py` writes
  an `import.jsonl` of any size straight to disk, without a Mattermost (N
  users, M channels, P posts in random order, threads, reactions), so 1,000
  users and a million posts can be tried. The aims: pass 1 at the speed of
  reading the file, the whole import in minutes, memory under 200 MB.
- **Looking at the result.** After 7g, import the live instance's export,
  start `yap-server` on it and look at it in the client (off-screen, as the
  other features were).

### Risks and what isn't known yet

- **Avatars need an image library on the server.** A profile picture is
  scaled to 256 px and re-encoded as a JPEG under 64 KB. The client does
  that with `vendor:stb/image` (`avatar_prepare`, client/imaging); the
  server only has the headers' reader (`imagekind`). Probably the scaling
  moves to `common` so both use it, or the server links stb as well.
  Looked at when 7c starts; if it is more than a day's work, avatars
  become their own small step after 7g.
- **Hashing takes time.** Argon2id at the server's parameters (19 MiB, two
  passes) takes tens of milliseconds a password on one thread, so a
  thousand accounts take about a minute and ten thousand ten (not
  measured). 7c hashes on several threads (the server's hash worker is one
  thread, for the server's own reasons) and the report says how many
  accounts are left.
- **Channel schemes.** What a channel scheme or a custom role allows (D6,
  `conv_rights`) hasn't been seen in an export: the test instance's are all
  defaults (`channel_schemes_exported: 0`). 7d maps the default rights and
  warns about any scheme it finds, until a real one has been looked at.
- **Names.** A username Mattermost allows but yap's `username_clean`
  refuses (a reserved name) must be renamed and the new name reported, and
  so must the texts that mention it (step 9). `account_delete.odin` shows
  how a tombstone is made.

### To decide

1. Input as a folder first, the zip later (as above)?
2. All or nothing in one transaction, with no resuming (as above)? A very
   large export's transaction is large, though SQLite handles that; the
   alternative, committing per conversation, can leave a half import that
   has to be thrown away by hand.
3. `--owner` defaulting to the first system admin?

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
- Mattermost allows 3 to 8 people in a group message; yap's limit can be
  the same.

## DMs with oneself (step 2)

A place for one's own notes, one per account on each server. A DM whose
`a` and `b` are the same account; `dm_open` stops refusing it, and the
client lists it with the other DMs under one's own name. Nobody else can
see it, mentions in it notify nobody, and calls in it make no sense.

Built (2026-10-28):

- The server: `DM_Open` with one's own id opens it. Its record names the
  account twice, and the account is its only member. Files can't be
  offered there (an offer goes to someone else's device); attachments
  work. Nothing else needed changing: one's own posts are never unread,
  and pushes and mentions already skip the poster.
- The client: "Notes to self" at the top of each server's channel list,
  so it is clear which server the notes are on (the inbox mixes all
  servers). Clicking it opens the DM the first time. The chat shows it
  like a channel, with pins, files and search but no members or voice.
  The inbox leaves it out.
- The group picker got a server dropdown (with more than one server):
  picking a server switches to it without leaving the inbox, so the
  search goes through that server's people.
- The gateway: `POST /dms` with one's own account; the DM's `recipient`
  is then oneself.
- The protocol version stays 16, which nothing has been released with.

## Limits (step 3)

Mattermost counts characters where yap counts bytes, so yap's limits are
Mattermost's at 4 bytes a character (D16). From Mattermost 10.12.4's
source (`model/post.go`, `channel.go`, `user.go`, `emoji.go`,
`custom_status.go`, `config.go`):

| What | yap before | Mattermost | yap now |
| --- | --- | --- | --- |
| message text | 2000 B | 16383 characters, 65535 B | 65535 B (`MAX_CHAT_SIZE`) |
| channel name | 32 B | display name 64 characters | 256 B |
| topic | 128 B | header 1024 characters | 4096 B |
| display name | 32 B | nickname, or first and last name, 64 characters each | 516 B |
| username | 2–32 | 1–64 | 1–64, the same characters |
| status | 80 B | 100 characters | 400 B |
| emoji name | 32 | 64 | 64 |
| custom emoji | 512 | no limit | 512 (D18) |
| reactions per message | 20 | 50 by default (at most 500) | 50 |
| pins per conversation | 50 | no limit | 1000, in pages (D17) |
| channels | 1000 | 2000 per team by default | 2000 |
| files per message | 10 | 10 | 10 |
| group members | 8 | 8 | 8 (step 1) |

Built (2026-10-28), protocol version 17:

- Names, topics, statuses and Voice_Moved's channel name have 2-byte
  lengths. A stream message can be 128 KiB (was 64 KiB), so a message
  at its longest fits in an event or a history page.
- Pins_Get takes an offset and answers a page (at most `PINS_PAGE`, 50,
  or what fits) with whether there are more; the client fetches the
  pages one after another. The gateway's `GET /convs/{id}/pins` takes
  `?offset=`, and its request bodies can be 512 KiB.
- The largest buffers (a message's text, a post, an edit, an encoded
  message) are in the temp allocator instead of on the stack, and so is
  the Server_UI that stash_destroy keeps aside (now 400 KB).
- Avatars are still 256 px and 64 KB: the importer scales Mattermost's
  pictures down. File names stay at 200 B and are cut on import.
- Tried in the app: a 64,000-byte message and a 39 KB one in a DM, and
  62 pins read in pages.

## Channel admins (step 13)

Today everything about a channel beyond posting in it is
`Manage_Channels`, a permission for the whole server
(conv_requests.odin): renaming it, changing its topic and position,
archiving it, removing members from a private channel and changing its
rights map. Adding someone takes `Invite` and being a member.

A channel admin is a member who manages that one channel. Like in
Mattermost, a channel can have any number of them. A channel admin may:

- add members (which matters mostly for private channels; public ones
  can be joined anyway) and remove them,
- make other members channel admins, and stop being one,
- change the channel's name and topic.

Not: archiving it, its position in the lists or its rights map; those
stay with `Manage_Channels`, as does everything a channel admin may do.
Whoever creates a channel becomes its first admin.

A flag on the membership (`members` has no flags column yet, so a schema
step), sent with the member list so that clients can show who the admins
are and offer the menu entries. In DMs and group DMs it doesn't exist.
Mattermost's `channel_admin` role has more (bookmarks, banners,
auto-translation), none of which yap has.

Built (2026-10-28), protocol version 21 (proto/convs.odin):

- `members.admin` (schema step 33, which also makes the creator of each
  existing channel its admin if they are still in it). The conversation
  record's `member` byte has 2 added for an admin, and Conv_Members
  answers with the admins after the members.
- `Conv_Admin_Set [conv][account][on]` (the same body as
  Conv_Member_Set). An admin may make any member an admin and stop being
  one; making another admin no longer one takes `Manage_Channels`. The
  member is sent the channel again. There is no system message for it,
  as in Mattermost.
- An admin may add members without `Invite`, remove them from a private
  channel (still not anyone with more permissions than themselves), and
  Conv_Update with only the name and topic in its mask.
- In the client, the members window says "admin" next to them and offers
  admins "Add people...". A member's menu has "Make channel admin" (or,
  with `Manage_Channels`, "No longer its admin") and, in a private
  channel, "Remove from the channel". The channel's menu has "Name and
  topic...", a small window of its own, for admins without
  `Manage_Channels` (who have the settings), and "Stop being its admin".
- The importer sets the flag for every membership with `channel_admin`.

## Bookmarks (step 11)

Mattermost's saved messages, in yap's terms: a person marks messages to
come back to, and finds them again in one list.

- **Bookmarking**: the message menu (ui_message_menu.odin) gets
  "Bookmark", or "Remove bookmark" on one that is bookmarked. It works on
  any message one can read, in channels, DMs, group DMs and threads. A
  bookmarked message shows a small marker, only to its bookmarker.
- **The list**: one per account on each server, which nobody else sees.
  It is shown like a conversation: an entry at the top of the channel
  list (ui_channels.odin), "Bookmarks", which opens a view in the place
  of the messages. It lists the bookmarked messages, newest bookmark
  first, each with where it is (channel, DM or thread), its author, time
  and content, and a button that jumps to it in its conversation (as a
  search result does). Each also has "Remove bookmark". It is not a
  conversation in the protocol: nobody posts in it.
- **What it holds** is a reference, not a copy: an edited message shows
  its new text, a deleted one shows as deleted until its bookmark is
  removed. A message in a conversation one can no longer read (left a
  private channel, removed from it) is hidden from the list but its
  bookmark is kept, so it comes back if one is added again. A message
  that is purged takes its bookmarks with it.
- **Server**: a table `bookmarks (account, message, time)`, primary key
  `(account, message)`; requests to add and remove a bookmark and to
  list them (paged by bookmark time, like history); an event to one's
  other connections when one is added or removed, so every device
  agrees. Whether a message is bookmarked travels with the message only
  to its bookmarker, or the client knows it from the list it has loaded
  (to be settled when building).
- **Bot API**: not needed at first.
- A limit per account (say 1000) keeps the list cheap to load; Mattermost
  has none, so the importer may have to drop the oldest past it.

Built (2026-10-28), protocol version 20 (proto/bookmarks.odin):

- `Bookmark_Set [id][on]`, `Bookmarks_Get [before_time][before]` (a page
  of 50, newest bookmark first, continuing after the last one's time and
  id), the event `Bookmark_Changed [id][time][on]` to every connection of
  the account, and `Bookmarks`, every bookmarked id, in the login sync.
  So the client knows from that set which messages to mark; nothing
  about bookmarks travels with the messages themselves.
- At most 1000 per account (`MAX_BOOKMARKS`). A deleted message can't be
  bookmarked; removing a bookmark always works. Schema step 32 adds the
  table, and a trigger removes a purged message's bookmarks.
- The list is a floating window (like the pins and the search), not a
  view in the place of the messages: it stays open while Go to jumps from
  one message to the next. The "Bookmarks" row under "Notes to self"
  opens and closes it.
- Bookmarking is in the message's menu (right-click), next to Copy link;
  a bookmarked message's header says "bookmarked", and it isn't merged
  into the message above it, so that the header is there to say so.

## Decisions

- **D1** Teams: only one team is imported, chosen with `--team`. The
  export must still be of the whole instance, because a team-scoped
  export has no DMs.
- **D2** Passwords: every imported account gets a generated password and
  is asked to set a new one at first login. The importer writes the
  generated passwords to a CSV file (`username,password`) for the admin
  to hand out.
- **D3** Source: Mattermost's bulk export, not its database. It has more
  than its documentation says (read state, pins, edits, saved posts,
  group messages, webhook props), and what it lacks (passwords, deleted
  posts) D2 and D10 don't need.
- **D4** Limits: all of yap's limits are raised to fit Mattermost's.
- **D5** The importer only imports into a new, empty database. It
  refuses one that has anything in it beyond what a new database starts
  with (the home channel and the `everyone` role), so ids, names and the
  home channel never clash with what's there.
- **D6** Roles: the importer creates a guest role that can't see any
  channel and has no other rights, and a role named Admin with all
  rights, for system and team admins. Channel admins become yap's own
  channel admins (step 13): any number per channel, who may add and
  remove members, make others channel admins, and change the channel's
  name and topic.
- **D7** Imported channels are `Text_Only`.
- **D8** DMs with oneself are supported (step 2), one per account on each
  server.
- **D9** Sidebar categories and favourites are dropped.
- **D10** Deleted posts are kept as `Deleted`, as far as the export has
  them.
- **D11** Mattermost's system messages become new system message kinds.
- **D12** yap gets `@here`.
- **D13** Webhook posts: **one bot per webhook**, with each post's
  override as its persona (D14). The importer makes a bot for each
  distinct `webhook_display_name` and posts as it; `override_username`
  and `override_icon_url` become the post's persona. Posts without
  `webhook_display_name` (older Mattermost versions may not have set it;
  not checked) get a bot named after the override name, else they stay
  with their creator.
- **D14** Personas: a bot may post under another name and picture (step
  12, see Overridden names in yap's bot API). Bots only; always shown
  with the bot badge and the bot's own name; a persona can't use an
  account's username or display name; the picture is an uploaded blob,
  not a URL. Step 12 comes before step 10.
- **D15** Saved messages become **bookmarks** (step 11): one's own list
  on each server, opened from the top of the channel list (as a window
  of its own, see Bookmarks), each entry with a button that jumps to the
  message; bookmarking is in the message menu.
- **D16** Byte limits are Mattermost's character limits at 4 bytes a
  character, so every Mattermost value fits (step 3).
- **D17** Pins are read in pages, up to 1000 per conversation.
- **D18** Custom emoji stay at 512 per server, with names up to 64
  characters; an import with more keeps the most used 512.
- **D19** yap posts these system messages itself as things happen, so
  imported and new history look the same. They are never unread and
  never notify. Joins and leaves of the home channel aren't posted.
- **D20** Mattermost's team events become "joined/left the server" in the
  home channel; yap posts "joined" when an account is made and "left"
  when it is deleted.


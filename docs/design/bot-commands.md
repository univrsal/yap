# Bot slash commands: plan

Scripts can add `/commands` to one client (`yap.register_command`, see
`scripting.md`). Bots should be able to add them for everyone on the
server: a bot registers `/weather`, every client offers it while typing,
and running it makes the bot answer. Nothing here is built yet. As in
`bot-api.md`, each phase is its own commit or series of commits; what turns
out differently is written under it when it's done ("*As built:*"), and the
open questions are in the Decisions table at the end.

Sizes: S up to about 300 changed lines, M up to 1000, L up to 2500.

## What we start from

- **Script commands are client side and per client.** `runtime_commands`
  lists them for completion (`ui_completion.odin`, `command_items`) and the
  palette (`ui_palette.odin`); `scripts_command` (`ui_scripts.odin`) runs
  one from the composer, and nothing is posted. Headless tries a `/word`
  none of its own commands know. Built-in commands win over a script's.
- **Bots are accounts** with `Account_Flag.Bot`, made by an admin, with
  roles like anyone (`proto/bots.odin`, `bot-api.md`). They talk to the
  server through the gateway (`/api/v1/`, JSON, an event WebSocket) or any
  headless client.
- **The gateway is just a client** (`bot-api.md`): a new feature has to be
  a protocol request or event first, and the HTTP API is a thin JSON
  skin over it.
- **Two earlier notes point here.** `scripting.md` D7 ("share names with bot
  slash commands: intended, not done") and `bot-api.md` "Later → Commands"
  (name, description, arguments; a `COMMAND` event instead of parsing
  text).
- **Bots today parse text** (`!echo`, `!roll 2d6` in `docs/examples`). That
  keeps working; commands are an addition.

## Goals and non-goals

- A bot registers its commands once; clients complete them, show the help
  line, and a run reaches the bot as a structured event, not as a message
  to parse.
- Script commands and bot commands look the same to the person typing
  (one list, one palette, one way to run them).
- The server decides who may run what, and who a command came from. A
  bot can't invent an invocation, and a command can't be run where the
  bot couldn't answer.
- Old clients and old servers keep working (unknown ops are ignored, see
  `proto/rpc.odin`); an old client just doesn't offer the commands, and
  `/weather` is posted as text, as today.

Not in the first version: typed options with choices and per-option
completion (Discord's), buttons and embeds in the answer (yap has none),
ephemeral answers, context menu commands, per-command permissions beyond
the channel's, and commands for things that aren't accounts (webhooks).

## Design

### The registry lives on the server, in memory

Recommended (D1): the server keeps each connected bot's commands in
memory and sends the list to clients. There is no table.

- A bot sets **its whole set at once** (`Bot_Commands_Set`: the old set
  is replaced, as Discord's bulk overwrite is), so a bot that dropped a
  command doesn't have to remember to delete it.
- The set belongs to the bot's connection. When its last connection
  closes (or the account is disabled or deleted) the set is gone and
  clients are told (`Commands_Changed` with an empty set). A bot
  registers at startup, so nothing is lost; a command in the list always
  has a bot that can answer it.
- A bot with several connections (several tokens) has the set of the
  one that set it last; a closed connection takes its own set only.
- Only an account with the Bot flag may set commands (`Denied`
  otherwise). No new permission: an admin who doesn't want a bot's
  commands removes the bot's roles or the bot.

Limits (constants in `proto/bot_commands.odin`): 50 commands per bot; name 1-32
of lower-case letters, digits, `-` and `_` (the same rule as a script's,
`docs/Scripting.md`); description up to 100 bytes; usage hint up to 64
bytes ("<city> [days]"); all text through `proto/sanitize.odin`, since a
bot's description is shown to everyone.

### The protocol

New ops, next to `Bot_Create` and `Bot_Token_Add` in `proto/rpc.odin`,
described in `proto/bot_commands.odin`:

| Op | Direction | Body |
| --- | --- | --- |
| `Bot_Commands_Set` (0x0029) | request, a bot | `[n u8]`, then per command `[name str8][description str8][usage str8]`; answer: nothing |
| `Commands_Changed` (event 0x0014) | event, everyone | `[account u32]` and that account's new set as in `Bot_Commands_Set` (empty if gone), so clients patch their list |
| `Command_Run` (0x002A) | request, anyone | `[conv u32][thread root u64][account u32][name str8][args str16]`; answer: Ok, or why not |
| `Command_Invoked` (event 0x0015) | event, to that bot only | `[id u64][conv u32][thread root u64][invoker u32][name str8][args str16]` |

The login sync (Sync_Begin..Sync_End) sends one `Commands_Changed` per
connected bot that has commands, so the first completion needs no request
and there is no "get" op. A client of a server that doesn't know the ops
simply has no bot commands.

`Command_Run` carries the **account** so that two bots with a `/roll`
don't collide (see "Names"). The server checks, in this order (as built):

1. A rate limit per connection (10 at once, then 2 a second):
   `Rate_Limited`, so one person can't flood a bot.
2. The invoker may post in the conversation, as for `Msg_Post`: it can see
   it (`Not_Found` if not), is a member and may write there (`Denied`). A
   person who can't speak in a read-only channel can't make a bot speak
   there either. The check comes first so that no answer says anything
   about a conversation the invoker can't see.
3. The thread, if any, is a thread of that conversation: `Invalid`.
4. The bot has that command: `Not_Found`. With the registry in memory
   this also covers a bot that has left since the client last heard, so
   there is no separate "closed" answer; the client says the command is
   no longer available.
5. The bot is a member of the conversation, may see it and write there:
   `Denied`, and the client says the bot isn't in this channel. Without
   this a command could be run into a place the bot can't answer.

The event goes to the one connection of the bot whose commands count, so
two processes of a bot don't both answer.

The `invoker` in the event is filled in by the server, never taken from
the request. `args` is the text after the name, trimmed, up to 2000
bytes. The invocation is **not posted as a message**, as with script
commands. The bot answers with an ordinary `Msg_Post` in the same
conversation and thread, taken from the event. `id` is a server-made
number the bot may quote later for features that link the two (D6); v1
doesn't use it.

### Names

Three sources can have the same name. Resolution, first match wins:

1. **A built-in client command** (`/call`, `/search`, ...) always wins, as
   scripts' commands already lose to them.
2. **A script's command** (client side, the person's own).
3. **A bot's command** from the list.

Two bots with the same name is the real question (D2). Recommended: it
works as long as there's a way to say which, and nobody is surprised:

- Completion offers **both**, each with its bot's name in the label
  (`/roll   Roll dice          weatherbot`), and inserts the chosen one.
- A typed `/roll 2d6` that matches several bots' commands is **not
  guessed**: the composer shows "Several bots have /roll: use
  /weatherbot:roll" and runs nothing. If exactly one bot has it, plain
  `/roll` runs it.
- `/botusername:name args` always names the bot, and is what completion
  inserts when the name is ambiguous.

A script and a bot with the same name: the script wins (it's the person's
own setting), and the completion list shows both so it's not mysterious.

### Which bots are offered where

Completion only offers commands that could work here (D9): in a DM, that
bot's; in a group DM, those of the bots in it; in a channel, those of bots
that can see it. The client answers this from what it knows (members and
rights), and the server's check in step 3 is the authority.

### The gateway and the HTTP API

- `PUT /api/v1/commands` (bot token): body `[{"name", "description",
  "usage"}]`, replaces the set (`Bot_Commands_Set`). `GET /api/v1/commands`
  lists the server's commands, from the gateway's model (built from
  `Commands_Changed`). Errors as everywhere.
- Event `COMMAND` on the WebSocket (the name `bot-api.md` already
  reserved), from `Command_Invoked`:

		{"t": "COMMAND", "s": 120, "d": {"id": "9031", "conv_id": "7",
		  "thread": null, "name": "roll", "args": "2d6",
		  "user": {"id": "4", "username": "uni", "display": "uni", "bot": false}}}

- Resume replays it like other events.
- *As built:* the model keeps the commands, so `READY` has a `commands` list
  (`{bot, commands}` per bot) and a `COMMANDS_UPDATE` event, in the same
  shape, follows each `Commands_Changed`. `PUT` answers with the set the
  server now has. The code is in `lib/gateway/commands.odin`.
- A headless client without the gateway (`src/stress/bot.odin` and what
  `bot-api.md` phase 2 made of it) gets the ops directly.
- The server sends `Command_Invoked` only to the account the command
  belongs to, so a bot never sees another's.
- A bot registers **at startup** (`PUT` after `READY`), and again after
  every reconnect, since its set goes away with its connection. A
  gateway connection kept for a few minutes after the last REST request
  (`bot-api.md`) keeps the set meanwhile.

### The client

- `conn`: a new file `conn/bot_commands.odin` (not `commands.odin`, which
  is the UI's command queue) with the list in `View`, kept up by the sync
  and `Commands_Changed`, and a queue entry that sends `Command_Run`.
- `script.Command_Info` gets a `source` (script or bot) and the bot's
  account; one function in the UI merges both lists, sorted by name, so
  completion (`command_items`) and the palette ("Run /name") need little
  more than the extra label. Completion currently asks only `ui.scripts`
  and returns early without it; it must work with scripts switched off.
- `composer_send`: order of checks is built-ins, script
  (`scripts_command`), bot command; only if none matches is it text. The
  run is queued like any command, and the result (`Denied`, `Not_Found`)
  comes back as a line in the status area.
- Headless: the same fallback for a `/word` none of its own commands
  know (`headless/commands.odin`), with log lines for denied/unavailable.
- The web build uses the same code; nothing separate.

*As built (phase 5):* `conn/bot_commands.odin` keeps the list (sorted by
name, then bot) and gives the UI a copy in `View.bot_commands`. Running one
is a queued `Bot_Run_Command` carrying the typed line; the network thread
works out which bot it means and sends `Command_Run`, so the headless
client shares the path (a `/word` that no script has is tried as a bot's
command; a `/word` nobody has still gets the help). The UI decides whether
a line is a bot's command with the same lookup (`ui_scripts.odin`,
`bot_slash`), so that it isn't posted as text; with several bots the text
stays in the box and a notice says to use `/bot:command`. Which bots are
offered where is known for DMs (the one bot) and groups (their members);
for a channel the client can't tell who is in it, so every bot's commands
are offered and the server's answer (`Denied`) says if the bot isn't there.
The pure parts (lookup, scope, ambiguity) are tested in
`conn/bot_commands_test.odin`; the UI pieces are not, since they need a
session.

### Scripts

`yap.register_command` stays as it is. A possible small addition later
(D8): `yap.commands()` listing the server's bot commands. A script can't
register a command for others; that is what a bot is for.

## Security

- The invoker is server-supplied, so a bot can trust `user`. The bot's
  own `Msg_Post` is checked by the usual rules; a command gives it
  nothing extra.
- A bot's text (names, descriptions) goes to every client: sanitized on
  the way in and clipped when drawn. Built-ins win on the client, so a
  bot can't hijack `/call` or `/logout`; it can take a name nothing else
  has, which is the point.
- A bot that lists 50 commands fills everyone's completion. Bounded by 50
  per bot and the list's own cap (`COMPLETION_MAX`); an admin deals with
  a noisy bot by removing its roles or the bot.
- Args are plain text, up to 2000 bytes, like a message. The server
  doesn't log them.
- A person can't run a bot's command in a channel they can't speak in
  (step 2), or where the bot can't answer (step 3).

## Phases

| # | Change | Size | Where | Depends on | Status |
| --- | --- | --- | --- | --- | --- |
| 1 | Protocol: the four ops, the codec and its tests; limits and sanitizing | S | `common/proto` | - | done (2026-11-01) |
| 2 | Server: the in-memory registry, `Bot_Commands_Set`, `Commands_Changed` (also in the sync, and when a bot's last connection closes) | M | `server` | 1 | done (2026-11-01) |
| 3 | Server: `Command_Run` with the checks and the rate limit, `Command_Invoked` to the bot; a test per refusal (denied, bot not in channel, bot gone, thread) | M | `server` | 2 | done (2026-11-01) |
| 4 | Gateway: `PUT/GET /commands`, the `COMMAND` event and resume; tests in `gateway_test.odin` | S | `server` | 3 | done (2026-11-01) |
| 5 | Client: the list in `View`, the run entry, the merged list in completion and palette, names and ambiguity, composer order, headless | M | `client/conn`, `client` | 3 | done (2026-11-01) |
| 6 | Docs and an example: `API.md` (commands, the event), `Scripting.md` (script and bot commands are listed together), `scripting.md` D7 updated, `docs/examples/slash.py` | S | docs | 4, 5 | planned |

Why this order:

- **1-3 before anything with a UI**: the checks are the part that can go
  wrong in a way people can see (a command run where it shouldn't), and
  they can be tested through the server harness (`harness_test.odin`)
  without a client.
- **4 before 5**: the gateway is the way to get a real bot to try the
  client against; `slash.py` can be written as soon as 4 is in.
- 5 is the biggest piece and mostly UI plumbing; it's one phase because
  the completion, palette and composer changes only make sense together.

Testing in general: codec round trips and limits (1); server tests for
the registry (set replaces, bots only, gone when the bot disconnects, in the sync) and
every refusal in `Command_Run`, and that the event reaches only the bot
(2-3); gateway JSON in and out (4); completion tests for merge, prefix,
an ambiguous name and a bot that left (5, next to the existing completion tests);
then one run against a live server with the Python example, as
`bot-api.md` did for its phase 9.

## Decisions

| # | Question | Recommendation |
| --- | --- | --- |
| D1 | Registry on the server (persisted), or only while the bot is connected | Only while the bot is connected (decided): in memory, no table; a command in the list always has a bot that can answer |
| D2 | Two bots with the same command name | Allowed. Completion shows both; the bare name runs nothing when several match, and says so; `/bot:name` always works |
| D3 | Script vs. bot with the same name | Script wins; built-ins win over both |
| D4 | Arguments: typed options (Discord) or a text string with a usage hint | Text and a hint in v1. Typed options need per-option completion and validation in every client; they can be added later as extra fields at the end of the same body, which old decoders ignore |
| D5 | Does the invocation appear in the channel ("uni used /roll") | No in v1, same as script commands |
| D6 | Linking the bot's answer to the invocation, and a "bot didn't answer" notice | Later. The event carries an `id` now so it needs no protocol change |
| D7 | A permission to *register* commands | No: the Bot flag is the gate; admins control a bot by its roles |
| D8 | `yap.commands()` for scripts | Not now |
| D9 | Which bots' commands are offered in which conversation | See "Which bots are offered where"; the server's check is the authority |

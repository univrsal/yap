# A terminal client (`yap-cli`)

Planned 2026-11-06 on `master` (1308c92). Nothing here is built yet.

The goal is a full chat client for the terminal, in the style of irssi or
WeeChat, made for yap: every text feature the GUI has, voice for those who
want it, and keyboard-only. It shares as much code with the GUI client as
can sensibly be shared. Where logic is stuck inside the GUI's `package
client`, it is **moved out into packages both clients import**, in small
commits that do not change what the GUI does.

## What the code already gives us

- **`client:conn` is the whole protocol client with no UI** (62 files, plus
  tests: handshake, auth, channels, messages, DMs, groups, reactions,
  threads, pins, bookmarks, search, files, roles, bans, invites, calls,
  presence, voice, ...). It imports no window, GLFW or microui code (the
  imports of `conn` and `headless` are only `proto`, `wlog`, `audio`,
  `video`, `settings`, `richtext`, `platform`, `script`, `imaging`,
  `memtrack`).
- **It has two kinds of front end already.** `Server_Conn.view` is either a
  `^View` (the GUI: one mutex-guarded snapshot of everything, and a `wake`
  callback; `conn/view.odin`) or `nil` (`-headless`: every `publish_*` does
  nothing and `conn/headless_log.odin` logs what happened). Front ends talk
  back only through `conn.push_command`.
- **Scripts hear about a connection through `Server_Conn.events`**
  (`conn/events.odin`), which any front end can set.
- **The layers below the UI are importable:** `settings`, `richtext`
  (markdown, mentions), `audio`, `script` (Lua), `platform`, `imaging`,
  `clipboard`.
- `src/client/headless` is a line-based CLI (`yap -headless`, about 1,300
  lines, 100+ `/commands`). It is part of `yap`, reads stdin and logs. It is
  the model for the command set, but it is not a screen that can be redrawn.

What is not importable is `package client` itself (about 35k lines: Odin
cannot import a `main` package). Most of it is drawing, but some is logic a
terminal client needs too. A first read of it found:

| Logic | Where | State |
| --- | --- | --- |
| Buddy, DM and group list: entries, ordering, unread | `buddies.odin` | Takes only `Settings` and `View` (`buddy_list(s, v)`); only `inbox_list` and `unhide_stale` touch `UI` / `Net_Session` |
| Text of system messages (calls, joins, ...) | `ui_timeline.odin` `system_line` | Needs only the `View` |
| Undo history of a text field | `ui_text_history.odin` | No UI dependency at all |
| Completion: which `/command`, `@name`, `:emoji:` fits the text before the cursor | `ui_completion.odin` (`command_items`, `role_items`, `emoji_items`, `word_char`) | Matching is mixed with the popup window; takes `^UI` for the `View` |
| Which messages get a day line, are merged under the previous author, or show a reply line | `ui_timeline.odin` `message_flags`, `thread_head` | Pure decisions, interleaved with pixel layout |
| Unread of the conversation being viewed | `ui_timeline.odin` `viewed_unread` | Needs only the `View` |
| When to raise a notice (mention, DM not being read, call) | `ui_notices.odin` `session_notices`, `dm_open` | Decision mixed with the tray call |
| Connection lifecycle: open, step loop on a thread, stop, reconnect | `ui.odin` `Net_Session`, `net_native.odin`, `ui_sessions.odin` | GUI state (`stash`, web slots, push) mixed in |
| The `/command` parser | `headless/commands.odin` | `handle_line` is `@(private)` and bound to a stdin reader and the log |
| Composer text editing, cursor, selection | `ui_text_area.odin` | Tied to microui. **Not moved**: a terminal edits differently (see below) |

## Decisions

| | Decision | Why |
| --- | --- | --- |
| D1 | New package `src/cli` (`package main`), binary `bin/yap-cli`, in the existing `client:` / `common:` / `lib:` collections. | Separate from the GUI; no build-flag changes. |
| D2 | **Extract before copy.** When the CLI needs logic that lives in `package client`, it is moved to a shared package first and the GUI is switched to the shared one. Copying is only for what is truly presentation. | One copy of the rules; fixes land in both clients. |
| D3 | Extraction commits are move-only: no behavior change, GUI tests (`src/client`, `src/client/conn`) green before and after, each commit one move. | Keeps the GUI risk small and reviewable on its own. |
| D4 | Use the **View**, not the log mode. | The View is what the GUI draws from (timelines, unread, members, typing, voice state). A terminal UI is a second reader of it. |
| D5 | The terminal layer is our own, small (`src/cli/tui`): raw mode, input decoding, cell grid, diff redraw. No ncurses. | Keeps "single binary, minimal runtime dependencies". Needs `core:sys/posix`. |
| D6 | Linux and macOS first; Windows later. | Keeps D5 small. |
| D7 | Build with `build-cli.sh` (runs `build.sh` first if the C libraries are missing, then `odin build src/cli`). `build.sh`, `build.bat` and CI are only touched when `yap-cli` ships. | Do not slow down or risk the normal build while it is being built. |
| D8 | Text first, voice optional (`-no-audio`). | Most of a terminal client's use is text, and audio devices over SSH are not a given. |

## How it looks and works (irssi-style)

```
 #general  Welcome to yap                                   (topic bar)
 12:01 <anna> morning                           ┌─ members ────┐ (optional,
 12:02 <ben>  @anna did you see this? ↩ #a41f   │ @anna  online│  toggle)
 12:02 ── reply to anna: "morning" ──────────   │  ben   away  │
 12:03 <you>  yes                                │  ...         │
 [12:04] [you(+online)] [yap.example: #general] [Act: 2,4,dm:ben] (status line)
 [#general] _                                                   (input line)
```

- **One window per conversation**: a channel, a DM, a group, plus a status
  window per server (log lines, server notices). This is irssi's model and
  maps directly onto `View.channels`, the DM list and `Timeline_Key`.
- **Switching:** `Alt+1..9`, `Alt+←/→`, `Ctrl+P/N`, `/win 3`, `/join #x`,
  `/query ben`, `/close`, a fuzzy `Ctrl+K` jump (what `ui_palette.odin` does
  for the GUI). Many servers: `/server` and `Alt+Shift+N`.
- **Activity bar** in the status line with irssi's levels: traffic, messages,
  highlights (mentions of you, built on `richtext/mentions`), DMs. Unread
  counts and the "read up to" marker come from the View as in the GUI.
- **Scrollback:** `PgUp/PgDn`; at the top it asks the server for older
  messages (`conn/messages.odin`'s windows), `/jump <id>`, `/unread`.
- **Messages:** timestamps, per-author colours, markdown as ANSI
  (bold/italic/underline/code), threads shown inline with a `↩` marker or
  opened in their own window, reactions as `👍2`, edit and delete marks,
  system lines, file attachments as `[file name.zip 3.1 MB #id.1]`.
- **Input line:** emacs keys, history (`Up/Down`), word and `/command` tab
  completion, `Ctrl+W/U/K`, bracketed paste, multi-line with `Alt+Enter`,
  `Up` on an empty line edits the last message, `/me`. Terminals have no
  mouse-and-selection editing, so this is a plain line editor with the
  GUI's completion and history behind it, and `ui_text_area.odin` stays GUI
  only.
- **Everything else is a `/command`** with the headless client's names
  (`/react`, `/pin`, `/search`, `/ban`, `/invite`, `/roles`, ...) so
  documentation and habits carry over. Output goes to the current window,
  not a log.
- **Notices:** terminal bell, OSC 9/777 desktop notification, window/tab
  title with the unread count.
- **Scripts:** the same Lua runtime and script folder as the GUI.
- **Config:** the GUI's `settings.json` (joined servers, devices, quality)
  plus a small `cli.json` for keys and colours (new, CLI only).
- **Out, because they don't mean anything in a terminal:** screen sharing,
  cameras, tray, titlebar, themes, hotkeys, Web Push. Profile pictures and
  chat images are out until an optional late phase (kitty graphics/sixel).

## Layout

```
src/client/<new shared packages>     see "Extractions" (imported by yap and yap-cli)
src/cli/
  main.odin         flags, logging, config paths (client:platform), start
  app.odin          event loop: key input, wake pipe, redraw
  windows.odin      the window list, activity levels, switching
  session.odin      the joined servers (uses the shared Session, below)
  tui/              raw mode, input decoding, cell buffer, diff flush, resize
  screens/          timeline, status line, topic bar, member list, overlays
  input.odin        the line editor; completion and history come from shared packages
  commands.odin     /command handling: the shared parser, plus how results are shown
  notify.odin       bell, OSC notices, title
  *_test.odin
build-cli.sh
```

Threads follow the GUI's: a network thread per server runs
`client_open` / `client_step`; the main thread reads input and redraws when
`view.wake` (a `proc "c" ()`, so it only writes a byte to a self-pipe the
input loop polls) fires.

## Extractions

Done as needed, in this order, each its own commit (D2, D3). New package
names are proposals; they live under `src/client/` and are imported as
`client:<name>`. The GUI files named are changed to call the new package and
nothing else.

| # | Move | To | Needed by | Size |
| --- | --- | --- | --- | --- |
| E1 | `ui_text_history.odin` | `client:compose` (history) | input line | XS |
| E2 | Connection lifecycle from `net_native.odin` / `ui_sessions.odin`: a `Session` that owns `Server_Conn`, `View`, thread and stop flag, with `open`, `step_loop`, `close`, `reconnect`. The GUI's `Net_Session` embeds it and keeps `stash`, web slots, push. | `client:conn` (or `client:session`) | phase 0 | M. The web build keeps its own stepping (`net_web.odin`) |
| E3 | `system_line`, `viewed_unread`, the pure part of `message_flags` / `thread_head` (day lines, merging, reply lines) as `timeline_layout(msgs, tz) -> []Row_Info` | `client:conn` (view helpers) | timeline | M. The risky one: GUI row heights are computed from these flags, so the GUI tests for the timeline (`ui_timeline_test.odin`) must pass unchanged |
| E4 | `buddies.odin` (`buddy_list`, `buddy_entry`, `group_entry`, `dm_name`, `dm_closed`, `dm_unread`, ordering); `inbox_list` and `unhide_stale` stay in the GUI as they use `Net_Session` | `client:conn` (`inbox`) | DMs, groups | S. `buddies_test.odin` moves with it |
| E5 | The matching half of `ui_completion.odin` (`command_items`, `role_items`, `emoji_items`, `role_word_start`, `word_char`) as `complete(view, text, cursor) -> []Item`; popup stays in the GUI | `client:compose` | tab completion | M |
| E6 | `headless/commands.odin`: `handle_line` becomes `parse_line(line) -> (conn.Command, Reply)` returning what to queue and what to tell the user, instead of queuing and logging. `-headless` and `yap-cli` both call it. | `client:cmdline` (`headless` keeps the stdin reader and printing) | every `/command` | L. Its tests (`commands_test.odin`) move with it and must pass unchanged for headless |
| E7 | The decision half of `session_notices` / `dm_open` as `pending_notices(view, state) -> []Notice`; the tray call stays | `client:conn` | notices | S |

Each extraction is only done when its phase starts, and is dropped if the
terminal version turns out to need something different enough that sharing
would bend the GUI's code for it (then copy, with the source file named in a
comment).

## Phases

Each ends with something runnable.

**Phase 0: scaffolding (S).** E2. `src/cli` with `main.odin`, `build-cli.sh`,
a `Session` with a `View`, no screen: connects, prints the channel list,
exits on `Ctrl+C`. Settles the open question about `View` (below) and the
binary size.

**Phase 1: one server, text (L).** `tui`, windows, status line, E3, E1,
timeline, input line, send/edit/delete/reply, history paging, unread, E6
(the first `/commands`: `/join`, `/msg`, `/me`, `/win`, `/quit`, `/help`).
First usable client; chat with a GUI user in both directions.

**Phase 2: all of text chat (L).** E4, E5, E7. DMs and groups, buddies,
reactions, threads, pins, bookmarks, search, attachments (`/attach`,
`/save`), typing and presence, notices, member list, tab completion, several
servers, scripts.

**Phase 3: voice, calls and administration (M).** Join/leave voice, mute,
deafen, who is talking, devices from `settings`, calls, the admin `/commands`
(roles, bans, invites, channel settings, purge), `cli.json`, the `Ctrl+K`
jump. The headless client's `-tone` / `-input-file` stay available for
tests.

**Phase 4: optional.** Image preview (kitty/sixel) with `client:imaging`;
Windows; packaging and CI (`scripts/package/`, `release.yml`, adding
`src/cli` to `scripts/run-tests.sh`).

## Testing

- **Extractions:** the GUI's existing tests are the safety net (D3). Run
  `scripts/run-tests.sh` before and after each move; a moved test file keeps
  its assertions.
- **Session and screens:** `conn` has a loopback harness
  (`harness_test.odin`, `*_flow_test.odin`) that runs a real server in
  process. The CLI tests use the same kind with a `View`, and assert on the
  **cell buffer** the screens draw into (the `tui` layer draws to a plain
  `[]Cell`, so no terminal is needed).
- **`tui` input decoding** (escape sequences, UTF-8, bracketed paste) and
  the line editor have unit tests.
- **A pty smoke test** (`script`/`expect`) for resize, and that the terminal
  is restored on exit and on a crash.

## Risks and open questions

- **Does `View` serve a second reader?** It is designed for one reader that
  holds the mutex while drawing a frame, and some fields are consumed by the
  UI (`mentioned` is drained, unread counters are reset by the UI, a
  `View_Timeline` window follows what the reader shows). Phase 0 and 1 must
  confirm the CLI can do what the GUI does to them. If a hook only exists in
  `package client`, it becomes another extraction.
- **Linking.** `conn` imports `client:video`, which on Linux links
  `libyap_video.a` and a static `libstdc++`. `yap-cli` inherits that.
  Phase 0 measures it; the fix would be a build tag in `video`.
- **The web build.** Extractions touch files the web client compiles
  (`net_web.odin`, anything under `conn`). E2 and E3 must still build with
  `web/build.sh`; CI's web job is the check.
- **E3 is the risky extraction**, since pixel layout depends on it. If it
  proves invasive, the CLI computes its own day lines and merging (a few
  dozen lines once heights are gone) and the plan notes the copy.
- **Terminal differences.** Wide characters and emoji widths, terminals
  that don't do bracketed paste or OSC 9. D5 means these are ours to get
  right; the `tui` tests carry a table of widths.
- **Windows** (D6) needs its own console input and output code.
- **Name.** `yap-cli` is a placeholder.

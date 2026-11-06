# A terminal client (`yap-cli`)

Planned 2026-11-06 on `master` (1308c92). Nothing here is built yet.

The goal is a second client for the terminal that reuses as much of the GUI
client as can be reused, **without changing any file in `src/client`**. The
GUI stays exactly as it is; the new client lives beside it and only imports
from it.

## What the code already gives us

The client is already split the way this needs:

- **`client:conn` is the whole protocol client with no UI** (62 files, plus tests:
  handshake, auth, channels, messages, DMs, groups, reactions, threads, pins,
  bookmarks, search, files, roles, bans, invites, calls, presence, voice,
  ...). It imports no window, GLFW or microui code (checked: the imports of
  `conn` and `headless` are only `proto`, `wlog`, `audio`, `video`,
  `settings`, `richtext`, `platform`, `script`, `imaging`, `memtrack`).
- **It already has two kinds of front end.** `Server_Conn.view` is either a
  `^View` (the GUI: one mutex-guarded snapshot of everything, plus a `wake`
  callback called when it changes; `conn/view.odin`) or `nil` (`-headless`:
  every `publish_*` does nothing, and `conn/headless_log.odin` logs what
  happened instead). The UI talks back only through
  `conn.push_command(&c.commands, ...)`.
- **Scripts hear about a connection through `Server_Conn.events`**
  (`conn/events.odin`), which any front end can set.
- **Everything below the UI is importable:** `settings` (settings.json,
  joined servers), `richtext` (markdown and mention parsing), `audio`
  (voice, Opus, RNNoise, sound packs), `script` (Lua), `platform`
  (config/download paths, links), `imaging`, `clipboard`.
- `src/client/headless` is a finished line-based CLI (`yap -headless`, about
  1,300 lines, 100+ `/commands`). It is part of the `yap` binary, reads
  stdin, and **logs** instead of showing a screen.

What cannot be reused: everything in `package client` itself (`main.odin`,
`ui_*.odin`, `buddies.odin`, `theme.odin`, about 35k lines). Odin cannot
import a `main` package, and the file is not meant to be a library. This
includes some logic that is not drawing: `Net_Session` and the multi-server
list (`ui.odin`, `ui_servers.odin`, `ui_sessions.odin`), the buddy list
(`buddies.odin`), timeline layout and grouping (`ui_timeline.odin`),
completion (`ui_completion.odin`), the command palette (`ui_palette.odin`),
notices (`ui_notices.odin`) and the composer's text editing
(`ui_text_area.odin`). Likewise `headless.handle_line` is `@(private)`.

So "porting" here means **a new front end on `conn`**, with the logic that
lives in `package client` rewritten (or copied and trimmed) rather than
shared. That is the price of not touching the GUI; section "Duplication"
says how to keep it small and what to propose later.

## Decisions

| | Decision | Why |
| --- | --- | --- |
| D1 | New package `src/cli` (`package main`), binary `bin/yap-cli`. | Separate from `src/client`; imports with the existing `client:`, `common:`, `lib:` collections, so no collection or build-flag changes. |
| D2 | Not a mode of `yap`. `src/client/main.odin` is not touched, and `yap -headless` stays as it is. | The brief. |
| D3 | Use the **View**, not the log mode. | The View is the same data the GUI draws (timelines, unread counts, members, typing, voice state). A TUI is a second reader of it. The log mode only prints events, which cannot be redrawn. |
| D4 | The terminal UI is **our own small TUI layer** (raw mode, ANSI, a cell grid, diff redraw) in `src/cli/tui`, no ncurses. | Keeps the "single binary, minimal runtime dependencies" goal. Needs only `core:sys/posix` (and the Win32 console API on Windows, later). |
| D5 | Linux and macOS first. Windows and the web are out of scope. | Matches how the headless client is used and keeps D4 small. |
| D6 | Build with a new `build-cli.sh`; `build.sh`, `build.bat`, `scripts/run-tests.sh` and CI are not edited. | Same reason as D2. The C libraries (miniaudio, RNNoise, Lua, ...) are already built by `./build.sh`; the new script runs it first if they are missing, then `odin build src/cli`. |
| D7 | Voice is optional. `-no-audio` builds a connection without a `Voice` (as `headless` does with the fake audio); the first milestones are text only. | Text covers most of what people want a terminal client for, and audio devices over SSH are not a given. |

## Layout

```
src/cli/
  main.odin            flags (reuses client:platform paths), sets up logging, runs the app
  app.odin             the event loop: one thread reads keys, one runs conn.client_step
  session.odin         joined servers: a list of {Server_Conn, View, thread}  (replaces Net_Session)
  state.odin           what the CLI keeps besides the View: focus, scroll, composer, open overlays
  tui/                 terminal layer: raw mode, input decoding, cell buffer, diff flush, resize
  view/                screens (see below), each a proc that draws a View into a cell region
  compose.odin         the message box: editing, history, @mention / :emoji: / /command completion
  commands.odin        `/commands` -> conn.Command  (see "Duplication")
  notify.odin          bell and OSC 9/777 desktop notices
  *_test.odin          tests (see "Testing")
```

Threads follow the GUI's: a network thread per server runs
`client_open` / `client_step` (as in `net_native.odin`), and the main thread
reads input and redraws when `view.wake` fires. `wake` is `proc "c" ()`, so
it can only write a byte to a self-pipe that the input loop polls.

## What gets ported, by GUI feature

"Source" is the GUI file that holds the behavior to copy. The CLI draws it
as text.

| Feature | Source | CLI form | Phase |
| --- | --- | --- | --- |
| Connect, login, trust a new server key, register | `ui_join.odin`, `ui_account.odin`, `ui_gate.odin` | Prompts before the TUI starts; later a line in the status bar | 1 |
| Channel list with unread and mention badges | `ui_channels.odin` | Left pane | 1 |
| Timeline: messages, day lines, replies, system lines, edit marks | `ui_timeline.odin` (1,490) | Scroll region; plain-text layout (no pixel measuring, so far simpler) | 1 |
| Markdown, mentions, links, emoji | `client:richtext` (reused as is), `ui_rich_text.odin` | ANSI bold/italic/underline/code; emoji as characters or `:name:` | 1 |
| Composer, send, edit, delete, reply | `ui_message_bar.odin`, `ui_text_area.odin` | Bottom line(s); `Up` edits the last message | 1 |
| Older / newer history, jump to unread | `conn/messages.odin` windows | `PgUp` at the top asks for older | 1 |
| Typing indicator, presence | `ui_users.odin` | Status line, member pane | 2 |
| Unread, mentions, notices | `ui_notices.odin` | Bell + OSC desktop notice; the window title | 2 |
| Reactions | `ui_timeline.odin`, `ui_message_menu.odin` | Message cursor + `r`; chips shown as `👍 2` | 2 |
| Threads, pins, bookmarks, search | `ui_threads`, `ui_pins`, `ui_bookmarks`, `ui_search` | Overlays; `headless/commands.odin` already shows which `Command`s to send | 2 |
| DMs, groups, buddies | `buddies.odin`, `ui_buddies.odin`, `ui_groups.odin` | Pane section; **`buddy_list` is rewritten** (it takes `^Net_Session`) | 2 |
| Several servers | `ui_servers.odin`, `ui_sessions.odin` | A session list; `Alt+1..9` | 2 |
| Attachments | `ui_attachments.odin`, `conn/attachments.odin` | `/attach path`, `/save id n`; no inline pictures | 2 |
| Command palette, tab navigation | `ui_palette.odin`, `ui_nav.odin` | `Ctrl+K` fuzzy switcher | 3 |
| Voice: join, mute, deafen, who is talking | `ui_voice_panel.odin`, `client:audio` | Keys and a status line; devices from `settings` | 3 |
| Calls | `ui_calls.odin`, `conn/calls.odin` | Incoming-call prompt, `/answer`, `/hangup` | 3 |
| Settings (the ones that matter in a terminal) | `ui_settings.odin` | Edits `settings.json` through `client:settings`; same file as the GUI | 3 |
| Scripts | `ui_scripts.odin`, `client:script` | Same Lua runtime and folder; `headless/scripts.odin` is the model | 3 |
| Moderation and admin: roles, bans, invites, channel settings | `ui_manage`, `ui_roles`, `ui_bans`, `ui_invites`, `ui_channel_settings` | Command line only (`/roles`, `/ban`, ...) | 3 |
| Profiles, avatars, server pictures, images in chat | `ui_profiles`, `ui_avatars`, `ui_images` | Out, except an optional kitty/sixel preview, behind a later phase | 4 |
| Screen sharing, cameras, video | `ui_video`, `ui_camera`, `client:video` | **Out.** Not meaningful in a terminal. The connection just never asks for video | - |
| Tray, titlebar, hotkeys, themes, window icon, Web Push, install | `ui_tray`, `ui_titlebar*`, `theme.odin`, `hotkeys` | **Out** (a 16/256-colour palette follows the terminal) | - |

## Phases

Each phase ends with something runnable and has its own commits.

**Phase 0: scaffolding (S).** `src/cli` with `main.odin`, flags, and
`build-cli.sh`. Connects with `View` set, logs `view.status`, and exits on
`Ctrl+C`. Proves the build and that `conn` works with a `View` and no window.
Exit: `bin/yap-cli host:7777` connects and prints the channel list once.

**Phase 1: read and write text in one server (L).** `tui` layer, the
channel pane, the timeline, the composer, send/edit/delete/reply, history
paging, unread. This is the first usable client. Exit: chat with a GUI user
on a dev server, both directions, with markdown rendering and a resize.

**Phase 2: the rest of text chat (L).** Reactions, threads, pins,
bookmarks, search, DMs and groups, attachments, typing and presence, notices,
several servers.

**Phase 3: voice and administration (M).** Voice with the real audio device
(the `-tone` / `-input-file` fakes from headless stay available for
testing), calls, settings, scripts, admin commands, command palette.

**Phase 4: optional.** Inline picture preview (kitty graphics, sixel) using
`client:imaging`; Windows support; maybe a `--plain` output mode for
pipes. Each is its own decision.

## Duplication, and how to keep it small

Two kinds of copy come out of the "don't touch the GUI" rule:

1. **Logic in `package client`** (buddy list ordering, completion, mention
   detection for notices, timeline grouping, read-position handling).
   Copy the pure part, drop the microui and pixel parts, and put a comment
   with the source file at the top of the copy so drift is findable. Each
   is small once layout is gone (the 1,490-line timeline is mostly pixel
   heights).
2. **The `/command` parser** (`headless/commands.odin`, 991 lines). Its
   `handle_line` is `@(private)` and tied to a stdin reader. The CLI
   reimplements the parse in `commands.odin`; its tests are the same lines
   `headless/commands_test.odin` uses, so the two are held to the same
   behavior.

**Proposal for later, not part of this work:** the clean fix is to move
those pure pieces into packages under `src/client` that both front ends
import (as `richtext` and `conn` already are). It needs edits to
`src/client`, so it is a separate decision for after the CLI works and it is
clear which copies hurt.

## Testing

- `conn` has a loopback harness (`conn/harness_test.odin`, the `*_flow_test`
  files) that runs a real server in process. The CLI's session code is
  tested against the same kind of harness (an in-process server and a
  `Server_Conn` with a `View`), asserting on the **cell buffer** the screens
  draw into. The `tui` layer takes a plain `[]Cell` target, so no terminal
  is needed for these.
- `tui` input decoding (escape sequences, UTF-8, bracketed paste) and the
  composer have unit tests, like `ui_text_area_test.odin`.
- A pty smoke test (`script`/`expect`-style) in `scripts/` for resize,
  raw-mode restore on exit and on a crash.
- Tests are run with `odin test src/cli ...` (D6: not added to
  `scripts/run-tests.sh`).

## Risks and open questions

- **Drift.** The CLI copies logic that will change in the GUI. Mitigation:
  source comments, and the shared-package proposal above once it hurts.
- **Does `View` do what a second reader needs?** It is designed for one
  reader that holds the mutex while drawing a frame, and some fields are
  "taken" by the UI (`mentioned` is drained, `unread` counters are reset by
  the UI, `View_Timeline` windows need the reader to say what it shows). We
  need to confirm in phase 0/1 that the CLI can do the same things the GUI
  does to them, using only `conn` procs and not by editing `conn`. If some
  hook only exists inside `package client`, that goes on the list for the
  shared-package proposal and the CLI works around it meanwhile.
- **Linking.** `conn` imports `client:video`, which on Linux links
  `libyap_video.a` and a static `libstdc++` (`video/native.odin`). `yap-cli`
  inherits that, so the binary is larger than needed and `build.sh` must
  have run. Phase 0 checks the size. If it is a problem, the fix is a
  build tag in `video`, i.e. an edit outside the CLI, so it is raised then.
- **Which kind of "CLI"?** This plan makes a full-screen terminal UI. If
  what is wanted is a smaller thing (a pipe-friendly `yap-cli send` /
  `yap-cli tail` for scripts), that is a short phase of its own on the same
  session code and could come first.
- **Windows.** The console API differs enough that D5 postpones it.
- **Name and packaging.** `yap-cli` is a placeholder; it also would need a
  line in `scripts/package/` and the release workflow, both outside
  `src/client` and left for when it ships.

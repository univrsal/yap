# A terminal client (`yap-cli`)

Planned 2026-11-06 on `master` (1308c92). Nothing here is built yet.

The goal is a full chat client for the terminal, for yap, with a channel list,
clickable messages and menus, and mouse support, as well as the keyboard:
every text feature the GUI has, and voice for those who want it. It shares as much code with the GUI client as
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
| D5 | The terminal layer is our own (`src/cli/tui`): raw mode, SGR mouse and key decoding, cell grid, diff redraw, plus the widgets (list, scroll view, menu, dialog, text field). No ncurses. | See "Do we need ncurses?". Keeps "single binary, minimal runtime dependencies". Uses `core:sys/posix`. |
| D6 | Linux and macOS first; Windows later (it takes the same escape sequences in VT mode). | Keeps D5 small. |
| D7 | Build with `build-cli.sh` (runs `build.sh` first if the C libraries are missing, then `odin build src/cli`). `build.sh`, `build.bat` and CI are only touched when `yap-cli` ships. | Do not slow down or risk the normal build while it is being built. |
| D8 | Text first, voice optional (`-no-audio`). | Most of a terminal client's use is text, and audio devices over SSH are not a given. |

## Do we need ncurses?

No. What the brief asks for (a channel list, clicking, scrolling with the
wheel) is done by the terminal, not by a library:

- **Mouse:** the terminal reports clicks, drags and wheel turns as escape
  sequences once asked (`CSI ?1002h` for button and drag events, `?1006h`
  for the SGR format that has no coordinate limit). Every current terminal
  does this: xterm, kitty, iTerm2, WezTerm, Alacritty, GNOME Terminal,
  Windows Terminal, tmux. Decoding it is about 100 lines.
- **Colours, styles, links:** ANSI/SGR, including 24-bit colour, and OSC 8
  for clickable links.
- **Clipboard:** OSC 52 writes to the system clipboard, also over SSH.
- **Raw mode and size:** `termios` and `ioctl(TIOCGWINSZ)` from
  `core:sys/posix`, a resize signal, and `?2004h` for bracketed paste.
- **Windows 10+** takes the same escape sequences once virtual-terminal
  mode is on, so a later Windows port is not a rewrite either.

ncurses would add a runtime library the project's goals avoid ("minimal
runtime dependencies", one static binary), needs our own binding, and is
weak where this client needs strength: wide characters and emoji, 24-bit
colour and mouse need the wide build (`ncursesw`) and care. It also only
draws a screen; the list, scroll view, menu, dialog and text field widgets
have to be written either way. A vendored single-header C library
(`termbox2`, in the style of `deps/thirdparty`) is a middle road, but it
replaces only the ~500 lines of raw mode, decoding and diffing, and brings
its own limits (width tables, no OSC 8/52). **Decision (D5): our own `tui`
layer, no dependency**; if it proves a time sink, termbox2 can be swapped
in underneath it, since the widgets only see cells and events.

What the terminal does *not* give for free:

- **Text selection.** While mouse reporting is on, the terminal's own
  selection stops working (Shift+drag still does in most). `tui` therefore
  implements selecting message text itself (drag, double-click a word) and
  copies with OSC 52. `/mouse off` or a key turns reporting off for people
  who prefer the terminal's selection.
- **Discoverability.** Keyboard shortcuts are shown in menus, tooltips-as-
  status-line hints and `F1`, since nobody reads a manual first.
- **Pictures** (avatars, attachments): kitty graphics or sixel, in a later
  phase and only where the terminal supports them.

## How it looks and works

Modelled on the GUI's session screen (channels left, chat in the middle,
members right), so someone who knows the GUI finds their way; **everything
can be done with the mouse or the keyboard.**

```
┌ yap.example ▾ ─────────────────────────────────────────────────────────┐
│ ▾ Channels        │ # general   Welcome to yap                  ⚙ ✉ 🔔 │
│  # general     2  ├────────────────────────────────────────────┬───────┤
│  # dev         @1 │ anna  12:01  morning                        │ ● anna│
│  🔊 Lounge        │ ben   12:02  @anna did you see this?        │ ● ben │
│     ● anna ◔ ben  │         ↩ anna: morning                     │ ○ cy  │
│ ▾ Direct messages │ you   12:03  yes   👍 2  ❤ 1               │       │
│  ● ben         1  │ ── new messages ──                          │       │
│ ▸ Groups          │                                              │       │
│ ▸ Servers   (+)   ├────────────────────────────────────────────┴───────┤
│                   │ ben is typing…                                      │
│ 🎙 muted  🎧      │ > message #general_                       📎 😀 ⏎  │
└───────────────────┴──────────────────────────────────────────────────────┘
```

- **Channel list** (left): sections for channels, voice rooms with who is in
  them, DMs, groups and the joined servers, collapsible, with unread and
  mention badges (the View already has both). Click to open, wheel to
  scroll, drag the border to resize, right-click for a menu (mark read,
  notifications, leave, channel settings). Reorder-by-drag only where the
  GUI allows it.
- **Timeline** (centre): scrolls with the wheel, `PgUp/PgDn`, `Home/End`;
  asks the server for older messages at the top. Markdown as ANSI,
  per-author colours, day lines, a "new messages" rule, reply lines,
  threads in a side panel, reactions as chips you can click to toggle,
  links (OSC 8) you can click, file attachments with `[save]`.
- **Message actions:** hover highlights a message; clicking it, or
  `Enter` on the keyboard cursor, opens the same menu the GUI has: reply,
  react (an emoji picker), edit, delete, pin, bookmark, forward, copy,
  jump to thread.
- **Composer:** a multi-line box, `Enter` sends, `Alt+Enter` newline, `Up`
  edits your last message, tab completion for `@names`, `:emoji:` and
  `/commands` in a popup you can click, bracketed paste, undo, `📎` to
  attach (a path prompt; drag-and-drop from the terminal also pastes a
  path), `😀` for the picker.
- **Dialogs and forms** for what the GUI has as pages: join a server,
  log in or register, trust a new server key, settings (audio devices,
  quality, notifications, scripts), profile, members and roles, bans,
  invites, channel settings. Fields, checkboxes, dropdowns, buttons, `Tab`
  to move, `Esc` to close. This is where most of the new code is.
- **Voice and calls:** click a voice room to join; mute, deafen and the
  level meter in the lower left; an incoming-call dialog.
- **Command palette** (`Ctrl+K`): jump to any channel, DM or action by
  typing, as `ui_palette.odin` does. For people who prefer typing, the
  headless client's `/commands` all work too, in the composer.
- **Notices:** bell, OSC 9/777 desktop notification, window title with the
  unread count. **Scripts:** the same Lua runtime and folder as the GUI.
- **Config:** the GUI's `settings.json` (shared: joined servers, devices,
  quality) plus a small `cli.json` for colours and keys.
- **Out, because they don't mean anything in a terminal:** screen sharing,
  cameras, tray, titlebar, hotkeys, Web Push.
- **Narrow terminals:** under about 80 columns the member list hides, and
  under 50 the channel list becomes an overlay opened with `Ctrl+B`.

## Layout

```
src/client/<new shared packages>     see "Extractions" (imported by yap and yap-cli)
src/cli/
  main.odin         flags, logging, config paths (client:platform), start
  app.odin          event loop: keys, mouse, wake pipe, resize, redraw
  state.odin        what the CLI keeps besides the View: selection, focus, open dialogs
  session.odin      the joined servers (uses the shared Session, below)
  tui/              terminal layer: raw mode, key/mouse decoding, cell buffer,
                    diff flush, OSC 8/52, widths; no knowledge of yap
  widgets/          list, scroll view, menu, dialog, form fields, text field,
                    emoji picker (on top of tui; hit-testing and focus live here)
  screens/          channel list, timeline, members, composer, voice bar, and
                    the dialogs/forms (join, login, settings, roles, ...)
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
| E1 | `ui_text_history.odin` (undo history of a text field) | `client:compose` | input line | XS. **Not done**: the terminal's line editor (`tui/editor.odin`) has a history of sent messages but no undo yet. Do this when the editor gets undo |
| E2 | The network loop and a front end's session: `net_run` (open, go to the conversation, step until stopped, close) and `Session` (client, View, thread, stop). The GUI's network thread now calls `net_run`. The GUI keeps its own `Net_Session` and `session_new`, which are mostly audio, scripts and rail state, and the web build, which has no threads. | `client:conn` (`session_native.odin`) | phase 0 | **Done (phase 0).** Narrower than first planned: sharing the whole `Net_Session` would have needed a `using` embed across about 40 GUI files and the web build for little gain |
| E3 | `system_line`, `viewed_channel`, `viewed_unread` | `client:conn` (`view_helpers.odin`) | timeline | **Done (phase 1), narrower than planned.** `message_flags` (days, merging, reply lines) turned out to depend on `UI_Timeline`, `local_day`, the bookmarks and pixel heights, so moving it would have meant rewriting the GUI's layout cache. The CLI has its own rules in `timeline.odin`, with a comment saying where they come from |
| E4 | `buddies.odin` (`buddy_list`, `buddy_entry`, `group_entry`, `dm_name`, `dm_closed`, `dm_unread`, ordering); `inbox_list` and `unhide_stale` stay in the GUI as they use `Net_Session` | `client:conn` (`inbox`) | DMs, groups | S. `buddies_test.odin` moves with it |
| E5 | The matching half of `ui_completion.odin` (`command_items`, `role_items`, `emoji_items`, `role_word_start`, `word_char`) as `complete(view, text, cursor) -> []Item`; popup stays in the GUI | `client:compose` | tab completion | M |
| E6 | `headless/commands.odin`: `handle_line` becomes `parse_line(line) -> (conn.Command, Reply)` returning what to queue and what to tell the user, instead of queuing and logging. `-headless` and `yap-cli` both call it. | `client:cmdline` (`headless` keeps the stdin reader and printing) | every `/command` | L. Its tests (`commands_test.odin`) move with it and must pass unchanged for headless. **Deferred to phase 2**: phase 1 has only `/join`, `/quit` and `/help`, in `slash.odin`; the shared parser pays off when most of the 100 commands are needed |
| E7 | The decision half of `session_notices` / `dm_open` as `pending_notices(view, state) -> []Notice`; the tray call stays | `client:conn` | notices | S |

Each extraction is only done when its phase starts, and is dropped if the
terminal version turns out to need something different enough that sharing
would bend the GUI's code for it (then copy, with the source file named in a
comment).

## Phases

Each ends with something runnable.

**Phase 0: scaffolding (S), done.** E2. `src/cli` with `main.odin`, `build-cli.sh`,
a `Session` with a `View`, no screen: connects, prints the channel list,
exits on `Ctrl+C`. Settles the open question about `View` (below) and the
binary size.

**Phase 1: one server, text (L).** `tui` and the first widgets (list,
scroll view, text field, menu), mouse and keys, the channel list, E3, E1,
timeline with clickable messages and a message menu, composer, the
join/login/trust-key dialogs, send/edit/delete/reply, history paging,
unread, E6 (a few `/commands`: `/join`, `/me`, `/quit`, `/help`). First
usable client; chat with a GUI user in both directions, mouse only if
wanted.

**Phase 2: all of text chat (L).** E4, E5, E7. DMs, groups and buddies in
the list, reactions (clickable chips and a picker), threads, pins,
bookmarks, search, attachments, typing and presence, the member list,
completion popups, notices, several servers, text selection and copy, the
rest of the `/commands`, scripts.

**Phase 3: voice, calls, settings and administration (M).** Voice rooms
(join by click, mute/deafen, who is talking, devices from `settings`),
calls, the settings dialogs, the admin forms (roles, bans, invites, channel
settings, purge), `cli.json`, the `Ctrl+K` palette, narrow-terminal layout.
The headless client's `-tone` / `-input-file` stay available for tests.

**Phase 4: optional.** Pictures (kitty/sixel) with `client:imaging`;
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
- **Mouse in a terminal is coarser than in a window.** Cell-sized hit
  targets, no hover on some terminals (hover highlight only where the
  terminal sends motion events; everything must also work from the
  keyboard), and no native selection while reporting is on (see above).
  tmux and screen need `set -g mouse on` to pass mouse events through.
- **The widget set is the bulk of the work**, more than the protocol side,
  which `conn` already does. Phase 1 builds the minimum and each later phase
  adds only what it needs.
- **Terminal differences.** Wide characters and emoji widths, terminals
  that don't do bracketed paste or OSC 9. D5 means these are ours to get
  right; the `tui` tests carry a table of widths.
- **Windows** (D6) needs its own console input and output code.
- **Name.** `yap-cli` is a placeholder.

## Progress

**Phase 0 (2026-11-06).** E2 and `src/cli` (`main.odin`, `snapshot.odin`,
`interrupt.odin`), `build-cli.sh`, 4 tests. `bin/yap-cli host:port -user
.. -user-password ..` connects with a View and no window, trusts the key
the way the GUI does, logs in, prints the channels with unread counts as they
change, and leaves on Ctrl+C with exit status 0 and no leaks reported.
Tried against a local `yap-server`. The `src/client`, `conn` and `headless`
tests pass (391), and `yap` still builds.

What phase 0 showed for the open questions:

- **Voice:** `Server_Conn` needs a `Voice` to exist (`Session` calls
  `voice_init`, but opens no audio device), as the headless client does.
- **View as a second reader:** connecting, login state, status and
  channels read fine under `view.mutex`. The consumed fields (`mentioned`,
  unread counters, timeline windows) are still to be tried in phase 1.
- **Binary size:** `bin/yap-cli` is 5.2 MB and, on this machine, links no
  library beyond libc/libm/libgcc, but it prints
  `yap_video: no FFmpeg ... so no screen sharing` at start (a warning from
  `client:video`, which `conn` imports). It is harmless, but a terminal client
  has no use for it, so silencing it needs a change in `video` (phase 1).

**Phase 1 (2026-11-06).** The first usable client: `bin/yap-cli host:port`
opens a terminal screen with the channel list, the title bar, the messages,
the info line, the message box and the status bar.

What is in it:

- `tui` (44 tests): width of wide and combining runes, a cell buffer, a
  renderer that writes only what changed (tested by playing its output on a
  fake terminal and comparing screens), a decoder for keys, SGR mouse and
  bracketed paste, word wrapping, a line editor with history, and the POSIX
  raw-mode glue.
- The app (66 tests, on a View filled in by hand, reading the screen back as
  text): channel list with unread and mention badges; timeline with day lines,
  merged messages, a "new messages" line, replies, reactions, threads' reply
  counts, files, edits, pins, mentions and markdown; wheel and `PgUp`/`PgDn`
  scrolling that keeps its place when messages arrive; older messages asked
  for at the top and read marks sent as the conversation is read; the
  message box with multiple lines, paste, history and typing notices;
  reply, edit (`Up` on an empty box), delete (asks first) and copy, from a
  clickable menu or keys; `Alt+Up/Down/1..9` to switch channel; a draggable
  border; the login dialog, the changed-server-key dialog and `F1` help;
  `/join`, `/quit`, `/help`.
- `scripts/cli-smoke.py`: starts a throw-away `yap-server`, runs `yap-cli`
  in a pty with a small terminal emulator, and checks the login dialog, the
  channel list, sending a message and seeing it come back, the mouse menu, a
  resize, Ctrl+C and SIGTERM leaving the terminal as it was, and that no log
  line reaches the screen. It needs `./build.sh` and `./build-cli.sh`, and is
  not in CI yet.
- `scripts/run-tests.sh` and CI (for the platforms that have a terminal) run
  the `src/cli` tests.

What phase 1 changed in `src/client`: `viewed_channel`, `viewed_unread` and
`system_line` moved into `conn` (E3), and the network loop (E2, phase 0). The
GUI's behavior is unchanged; its tests pass.

Deviations from the plan: E1 not done and E6 deferred (see the table); E3 is
narrower. DMs, groups and the member list are still phase 2, as planned.

Found on the way:

- **stderr.** `client:video` prints its "no FFmpeg" warning to stderr from
  C, past the log. On a raw terminal that wrote into the screen, so
  `yap-cli` sends stderr to the log file (by default `cli.log` in the config
  folder) while the screen is up. The warning itself is still printed once
  per start; silencing it for good is a change in `video`.
- **Memory.** A layout kept its rows in the arena that it empties for each
  layout; the tests found it (a segfault). The rows' own array is now
  allocated before the arena is switched to.
- **Terminals that don't send motion.** The wheel and clicks need nothing
  more than button reporting, which is what is enabled (`?1002`), so
  hover highlighting is left out for now.

Not done yet: joining more servers, DMs and groups, search, pins, bookmarks,
reactions (adding), threads (opening), attachments, a member list, completion,
selecting text with the mouse, Windows.

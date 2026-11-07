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
| E4 | `dm_name` and `dm_closed` (the DM and group names, and whether one can still be written to) | `client:conn` (`view_helpers.odin`) | DMs, groups | **Done (phase 2), narrower than planned.** `buddy_list` and the rest of `buddies.odin` lean on `status_line` (`ui_avatars.odin`), `talking_of` (`ui_profiles.odin`), `Group_Members` (`ui_groups.odin`) and `Net_Session`, so they stay; the CLI lists the DMs and groups that have had something said in them itself (`pane_channels.odin`) |
| E5 | The matching half of `ui_completion.odin` | `client:compose` | tab completion | **Not extracted (phase 2).** The GUI's matching writes into its widget state (`UI_Completion`, `Composer`), so the CLI has its own in `completion.odin`, with a comment pointing at the original. Emoji `:name:` completion is missing in both places that the CLI could share: the shortcode table is in `render` |
| E6 | `headless/commands.odin`: `handle_line` and `Reader` made public, so `yap-cli` runs every line it doesn't handle itself through them. What they log (usage errors, the command list) is caught with a logger of its own and shown in the info line or a dialog. | `client:headless` | every `/command` | **Done (phase 2), in a smaller form than planned.** Not a parser that returns commands: the 991 lines stay as they are, with two words changed (`@(private)` removed). The commands that only print a list through `report_*` (e.g. `/roles`, `/bans`) show nothing yet, because with a View those reports are skipped; they get screens in phase 3 |
| E7 | The headline of a mention's notice (`mention_title`) | `client:conn` | notices | **Done (phase 2), small.** The rest of `session_notices` (which mentions to announce) differs: the GUI asks if the window has the focus and goes through the tray |

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

**Phase 2 (2026-11-06).** Most of text chat. 124 tests in `src/cli` (45 in
`tui`), the pty smoke test, and the GUI, `conn`, `headless` and `richtext`
suites all pass; `yap` still builds.

Built:

- **DMs and groups** under the channels (online marks, unread, newest first),
  written to like channels; `/dm` and `/group` come from the headless commands.
- **Member list** on screens 100 columns wide or more (`F2` toggles it): who is
  here first, away/busy colours, admins marked; a click opens a DM.
- **Reactions**: the chips are clickable (toggle ours), and "Add reaction" in
  the message menu (or `a` with a message picked) opens an emoji picker.
- **Threads**: "N replies" opens the thread in a pane in place of the member
  list, or over the messages on narrow screens. The message box writes into
  the open thread; older replies are asked for when scrolling up.
- **Pins, bookmarks and search** (`/pins`, `/bookmarks`, `/search [all] ...`) as
  a list dialog that follows the View, asks for the next page at the end,
  and goes to the message, switching conversation and fetching the page around
  it if needed. The menu pins and bookmarks.
- **Completion** of `@names`, roles, `@everyone`/`@here` (with the permission)
  and `/commands` (ours, the headless client's, and the bots'), in a popup.
- **Notices**: bell, a desktop notice (OSC 777, or OSC 9 on iTerm2, WezTerm,
  Windows Terminal and ghostty), the window title with the unread count, and
  an incoming call on the info line.
- **Files**: `/attach` then a message sends them (also in a thread);
  "Save file" in the menu; progress of uploads and saves in the timeline;
  `-download-dir`.
- **Text selection**: a drag over messages selects and copies them with the
  clipboard escape; a click that doesn't move still opens the menu.
- **Every headless `/command`** that queues something (about 100) works from
  the message box.

Changes to `src/client`: `dm_name` and `dm_closed` (E4) and `mention_title`
(E7) moved into `conn`; `headless.Reader` and `handle_line` made public (E6).
No behavior change in the GUI.

Found on the way:

- A message that ends in a mention that is fully typed (`hi @anna`) kept
  the completion open, so Enter chose it instead of sending. A word that is
  already the only thing it could become no longer opens the list.
- `conn.view_take_mentions` takes the View's lock itself, so it has to be
  called before the frame takes it.
- The logger's text is gone when the logging call returns, so what a command
  logs is copied into a builder, not kept by reference.

Left for a phase 2b (done, see below): **several servers** (the app is written
around one View; a session list needs the per-conversation state of `App`
split out), **Lua scripts**, and screens for the commands that only print
lists (`/roles`, `/bans`, `/invites`, `/devices`, ...). Also still missing:
emoji completion, completion of `/command` arguments, hover highlighting.

**Phase 2b (2026-11-06).** The three things phase 2 left out.

- **Several servers.** The app's per-server state (scroll, conversation, open
  thread, draft, reply or edit, files to send) is one struct, `Server_UI`;
  showing another server swaps it in and out, so the code that works on "the"
  server did not change. The servers are listed above the channels (unread
  and mention badges for the others, an open mark for one that is down), and
  switched to with a click, `Ctrl+N`/`Ctrl+P` (which also work from inside a
  dialog, since one server's login should not trap you), or
  `/server <n|name>`. `/servers` lists them, `/connect host[:port] [password]`
  adds one and `/disconnect [n|name]` drops one. Mentions and calls on the
  servers that are not shown are announced with the server's name, and the
  window title counts all of them. The loop owns the connections, so these
  are requests (`Server_Request`) it carries out, which also covers
  connecting again after trusting a new key.
- **Which servers.** `yap-cli host` connects to that one. With no argument it
  connects to the servers joined in the window client, read from its
  `settings.json`. **It never writes that file** (a smoke test checks), so it
  cannot clobber the window client's settings; joining and leaving here lasts
  for the run. Saving them is a decision for later.
- **Lua scripts.** The runtime starts before the connections and is attached
  to each, with the window client's script folder and approvals. Their
  `/commands` run before the headless ones (and are completed), `on_send` may
  change or stop a message (the text stays in the box if stopped), and
  `yap.notify` becomes a notice. `/script` lists and switches them, through the
  headless command. The loop wakes every 100 ms while scripts run.
- **Lists.** `/roles`, `/bans`, `/invites` and `/devices` open a dialog that
  asks for the list and fills in from the View when it arrives.

Tests: 149 in `src/cli` (45 in `tui`); the smoke test now also starts a second
server (`/connect`, the rail, `Ctrl+N`/`P`), reads the joined servers from a
settings file, and runs a real Lua script. 663 tests across the suites pass,
and `yap` builds.

Found on the way:

- The smoke test found the login dialog of the second server trapping the keys
  (nothing could leave it), and that the scripts runtime was started after the
  connections, so it was attached to none. Neither could be seen by the unit
  tests, which do not run the loop; `run.odin` is only covered by the pty test.
- A script's message merges under the sender's previous one like any other,
  so a check for its name on the line would never match.

Still missing: emoji completion, argument completion, hover highlighting, a
screen for the rest of the list commands (`/server-memory`, `/seen`, ...),
saving joined servers. Next in the plan: voice, calls, settings and the admin
screens (phase 3).

**Phase 3 (2026-11-06).** Voice, calls, settings, the admin forms, the palette
and the narrow layout. 175 tests in `src/cli`; 712 across the suites; the pty
smoke test now also joins a voice room, mutes, opens the settings and watches
the microphone level move. No change to `src/client`.

- **Voice.** Channels with a voice room get a `♪` door (a click of its own,
  apart from the channel's), and the people in a room are listed under the
  channel, the ones talking in bold green, muted or deaf ones marked. `F7` (or
  `/voice [channel]`, `/novoice`) joins or leaves, `F5` mutes, `F6` deafens
  (muting too, and giving mute back as it was), the way the window client does;
  these are the user's, so they apply to every server, and joining a room leaves
  the one on another server. The status bar shows the room or call, muted or
  deafened, and a level meter.
- **Devices.** They belong to the loop, not the screen: opened while a
  connection is in a room or a call, closed after, so a chat-only session never
  touches the sound system. With no sound system everything else still works and
  the settings say why. `-tone <hz>` makes a sine tone the microphone, for
  testing without a card (the headless client's `-tone`).
- **Calls.** An incoming call opens a dialog (`A`/`D`); an outgoing or active one
  is in the status bar; `F8` ends it; `/call name` is the headless command.
- **Settings** (`F9`, `/settings`): microphone, speakers, quality, noise
  suppression, voice gate and its thresholds, applied at once. They come from the
  window client's `settings.json` (read only) until one is changed here, and are
  then kept in this client's own `cli.json`; a test checks the window client's
  file is not touched.
- **Palette** (`Ctrl+K`): conversations, servers, and the things that have a
  command or a form, matched by letters in order.
- **Forms** for a new channel, a channel's settings (only what changed is sent),
  a ban (with removing their recent messages) and an invite code, from the
  palette. They send what the matching commands would, so the server decides who
  may.
- **Narrow screens**: under 60 columns the channel list is a window over the
  messages on `Ctrl+B` (a click on a channel, outside it, or `Esc` closes it).

Found on the way: `Alt+D` and `Ctrl+K` are emacs keys in the message box, so the
voice keys are function keys, and `Ctrl+K` is the palette (the box still has
`Ctrl+U` and `Ctrl+W`). `store_read` logs an error for a file that does not
exist, so the settings check first.

Not done: colours and key bindings in `cli.json` (only the voice settings are
there), a picture preview, Windows, screen sharing and cameras (out of scope),
a screen for roles beyond reading them (`/mkrole`, `/setrole` work as commands),
and testing the real sound devices on a machine that has them: the code that
opens them is the window client's, but it was only run here without a card.

**Phase 4 (2026-11-06).** The optional part, in the order of how much it helps.

- **Packaging and CI (done).** The Linux and macOS jobs build `yap-cli` after
  `build.sh` (stripped in a release), `package.sh` puts it in the platform zip
  when it exists, the release workflow makes it executable, and the Linux job runs
  `scripts/cli-smoke.py`, which starts a server of its own and drives the built
  client in a pseudo-terminal. I could not run GitHub Actions here, so the changes
  were checked by parsing the workflows and running `package.sh` with a stand-in
  web build; the first CI run is the real test. The macOS disk image and the
  Windows installer are the window client's and are unchanged.
- **User guide (done).** `docs/Terminal.md`, linked from the README and
  `docs/Building.md`.
- **Pictures (done, in cells).** Not the kitty or sixel protocols, which could
  not be tried here: pictures are scaled to a grid of half-block characters
  (`▀`, the upper pixel as the foreground colour and the lower as the background)
  and so are ordinary cells for the renderer, which keeps scrolling, resizing and
  copying as they were. They are asked for as previews when a message with one is
  laid out (the newest four at a time, again after ten seconds), decoded one
  per turn of the loop with the window client's decoders (stb, libwebp), and
  need 24-bit colour. A real protocol would give full resolution on the terminals
  that have one (kitty, WezTerm, iTerm2, foot) and could be added beside this as
  an option, with this as the fallback.
- **Windows (not done).** It needs a console layer beside `terminal_posix.odin`:
  virtual-terminal output and input modes (`SetConsoleMode`, which make the
  escape sequences and the SGR mouse reports work as on Unix, so `input.odin`,
  `flush.odin` and everything above are reused), the size from
  `GetConsoleScreenBufferInfo`, and a wait on the console handle and an event
  instead of `poll` and a pipe. Then `build.bat`, the CI job, the installer and the
  smoke test (which needs a ConPTY) follow. It is a day's work that cannot be
  tested from here, so it is left until someone can.

Tests: 185 in `src/cli` (6 on pictures). The smoke test also sends a picture
and sees it come back as cells.

**After trying it (2026-11-06).** Three things from the first real use.

- **Calling was there but hidden** (`/call name`). It is now in the member
  menu (click someone: *Message* or *Call*), a *Call* button in the title bar of
  a DM, the `Ctrl+K` palette (`call` and a name), and the names after `/call`,
  `/dm`, `/ban` and the like are completed. `/call` alone says how.
- **The emoji picker** had 24 emoji and no search. It now uses the window client's
  table (`common/proto`, every emoji with all its shortcodes): a box finds by any
  part of a name (exact names first, then those that start with it, then those that
  contain it), `Tab` goes through the kinds, the server's own emoji are a kind of
  their own and written as `:name:`, and the same picker (`F3`, `/emoji`) puts an
  emoji in the message.
- **Messages in an open thread** could only be reached with the mouse. `Tab` now
  goes message box -> messages -> thread -> message box, and the thread has the
  same keys (menu, reply, react, edit, delete, copy), the pane it is in showing the
  cursor.

Tests: 201 in `src/cli`. The help dialog's width is now checked line by line, which
found two of my own help lines being cut.

**Two more from using it (2026-11-06).**

- **A reaction on a thread's root did not show in the thread pane** until
  something else changed there. The View keeps its own copy of a thread's root and
  replaces it when the root changes (a reaction, an edit) without touching the
  thread's window (which holds the replies only), and the thread layout's cache key
  only counted the roots. The key now has a signature of their contents (and of the
  accounts' names, which had the same flaw for renames). A test makes the change the
  connection makes and expects the chip in both panes.
- **Leaving a server.** `/disconnect` existed but lasted for the run, so a server
  from the window client came back, and nothing pointed to it. cli.json now also
  holds the servers added with `/connect` and the window client's servers that were
  hidden here (`merge_servers` joins them; "example.org" and "example.org:7777" are
  the same server), so a server is really gone from this client's list without
  editing the window client's settings. A right-click menu on a server (show,
  connect again, disconnect and forget), the palette and the title bar (which says
  `/disconnect` removes a server that failed) point to it. The smoke test now
  keeps the client's config in its temporary folder, since it now writes it.

**Hints for the slash commands (2026-11-07).**

- `command_help.odin` has a table (`COMMAND_DOCS`): each command's name, its
  arguments (`<must>`, `[may]`, `a|b`), a sentence and sometimes an example. It
  feeds the completion list (usage and sentence per entry, in place of the bare
  names), a hint line in the row above the message box while the arguments are
  typed (the argument at the cursor in bold), `/help <command>` and `/help
  commands`, and a "Usage: ..." answer when a command with required arguments is
  used without them (checked after the scripts, before the headless client, so
  nothing is sent). The Output dialog scrolls for the long list.
- The table has to be kept in step with the commands by hand; a test only checks
  that each name is there once and has a sentence.

**Notifications and jumping (2026-11-07).** `/notify` is the terminal's own now: with just a level it applies to the conversation being looked at (DMs too), with nothing it says the current level, and `Ctrl+K` lists the three levels for here. Going to a message (from pins, bookmarks or search) puts the focus on the messages, so Up/Down move from the message reached.

**Emoji and tmux (2026-11-07).** Terminals (and tmux between them and us) disagree on the width of some emoji and symbols, and after a character we judge two cells wide but the terminal one, the rest of the row shifts. `render_diff` now places the cell after any rune from U+2000 up on its own (an explicit cursor move), and auto-wrap is off (`?7l`, restored on leaving), so a disagreement spoils one cell at most and cannot wrap or scroll the screen.

**Emoji and tmux, again (2026-11-07).** Placing every cell after an emoji did not cure it; the search for "bre" also finds the umbrellas, and U+2602 / U+1F3D6 are emoji that are one cell wide by default, which terminals draw wide or narrow as they like while tmux counts one. In tmux or screen (or with `YAP_CLI_EMOJI=text`) `render_diff` follows such runes (`proto.emoji_index` and width 1) with U+FE0E via the `tui.text_presentation` hook. Unverified in a real tmux: none here.

**Emoji and tmux, third time (2026-11-07).** Reproduced with tmux 3.5a (taken from the Debian package, unpacked, not installed) in a pty with three panes: a script ran the client in the bottom right pane and read what tmux sends the outer terminal. For a narrow-by-table emoji such as U+1F3D6 / U+2602 tmux sends the glyph and a space and counts one cell, then skips ahead with `CUF`; a terminal that draws it wide (Konsole) is one cell further on, and the rest of the row is off by one per such glyph. The text-style selector (U+FE0E) only made tmux back up and reprint. Now these symbols are two cells wide in the layout (`tui.wide_symbols`, rune_width) and sent with U+FE0F: tmux treats the cluster as wide and moves the cursor absolutely after it, so the row cannot drift whatever the terminal makes of the bare glyph. Default in tmux/screen, `YAP_CLI_EMOJI=wide|text|emoji` to choose. Not checked against Konsole itself.

**Emoji and tmux, fourth time (2026-11-07).** `scripts/term-widths.py` run by the user showed Konsole and tmux 3.8 agree with the width table on all but six symbols (☝ ✌ ✍ ⛹ 🏋 🕴: tmux counts two cells, Konsole and the table one; probably because they take skin tones). The "wide" mode of the third attempt was wrong for the rest (Konsole draws them one cell) and made tmux back up with `\b` and reprint, so one glyph per row sat a cell off. Now inside tmux/screen the client probes tmux at start (`tui.terminal_probe_widths`: print the rune in column 1, ask `ESC[6n`, in batches of 64) and `tui.stand_in` draws a mark (▫, plus a blank for a wide cell) for each emoji it counts differently from `rune_width`. The buffer keeps the real emoji. The "wide" and "text" modes stay under `YAP_CLI_EMOJI`.

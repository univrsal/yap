# The terminal client

`yap-cli` is a chat client for the terminal: the same server, the same account
and the same text chat as the window client, with the mouse and the keyboard.
It runs on Linux, macOS and the BSDs, also over ssh.

```
yap-cli host[:port]          connect to a server
yap-cli                      connect to the servers joined in the window client
yap-cli -print host          only list the channels and what is unread
```

The first time, the server may ask for a login, and for trusting its key, in a
dialog. The key and the list of trusted servers are the window client's: logging
in on one logs in on the other (they are the same device).

Options: `-user`, `-user-password` and `-device` log in from the command line,
`-password` is the server's password, `-channel` a channel to join,
`-download-dir` where saved files go, `-no-images` to not draw pictures, `-log-file` where the log goes (by default
`cli.log` in the config folder; the screen has no room for it) and `-tone <hz>`
uses a sine tone as the microphone, for trying voice without a sound card.

## The screen

Channels, DMs and groups on the left (with unread counts and `@` for mentions),
the messages in the middle, the members on the right when the terminal is wide.
Everything can be clicked, and everything can be done with the keys.

| Key | Does |
| --- | --- |
| `Enter` / `Alt+Enter` | Send the message / start a new line |
| `Up` in an empty box | Change your last message |
| `Esc` | Cancel a reply or edit, close a thread, go back to the newest message |
| `PgUp`, `PgDn`, the wheel | Scroll (older messages are fetched at the top) |
| `Tab` | Pick a message with the keys: `Up`/`Down`, `Enter` for its menu, `r` reply, `e` edit, `d` delete, `a` react, `t` thread, `y` copy. With a thread open, `Tab` again picks in the thread; `Tab` once more goes back to the message box |
| `Alt+Up`, `Alt+Down`, `Alt+1`…`9` | Another channel or DM |
| `Ctrl+K` | Go anywhere or do anything: conversations, servers, settings, forms for new channels, bans and invites |
| `Ctrl+N`, `Ctrl+P` | The next or previous server |
| `Ctrl+B` | The channel list, on a narrow terminal |
| `F2` | Show or hide the member list |
| `F5` `F6` `F7` `F8` | Mute, deafen, join or leave voice, hang up |
| `F3` | Pick an emoji for the message (`a` on a message picked: for a reaction) |
| `F9` | Settings |
| `F1` | Help |
| `Ctrl+C` | Leave |

Click a message for its menu (reply, react, open its thread, copy, bookmark,
save its files, edit and delete yours). Click a reaction to add or take back
yours, a `N replies` line to open the thread, a member to write to them, the
`♪` after a channel to join its voice room. Drag over messages to copy their
text (while the program has the mouse, the terminal's own selection does not
work; the copy goes to the clipboard through the terminal, which most terminals
allow, also over ssh).

Type `@` to complete a name, `/` to complete a command (and the name after
`/call`, `/dm`, `/ban` and the like).

**Emoji.** The picker (`F3`, `/emoji`, or *Add reaction* in a message's menu)
has a box to find them in: type any part of a name, `tada`, `thumb`, `party`.
`Tab` and `Shift+Tab` go through the kinds (common, the server's own, smileys,
people, …), the arrows pick, `Enter` chooses.

**Calling.** Click someone in the member list and choose *Call*, or press
*📞 Call* in the title bar of a DM, or use `Ctrl+K` and type `call` and a name,
or `/call name`. An incoming call opens a dialog (`A` answers, `D` declines);
`F8` hangs up.

## Commands

`/help` lists the keys. Typing `/` lists the commands that match, each with its
arguments and what it does, and once a command is typed the line above the message
box shows how it is used, with the argument you are writing in bold. A command
used without what it needs says how it is meant to be used instead of being sent.
`/notify mentions` changes how much the channel you are looking at may interrupt
(`all`, `mentions` or `none`; alone it tells the current level; `/notify dev none`
names another channel; `Ctrl+K` offers the three as well). `/help <command>` explains one command (with an example), and `/help commands`
lists all of them (Up/Down/PgUp/PgDn scroll). Besides `/join`, `/pins`, `/bookmarks`, `/search [all]`,
`/servers`, `/server`, `/connect`, `/disconnect`, `/mute`, `/deafen`, `/voice`,
`/settings`, `/roles`, `/bans`, `/invites`, `/devices` and `/quit`, every command
of the headless client works (`/dm`, `/react`, `/pin`, `/attach`, `/call`,
`/ban`, ...; see `src/client/headless/commands.odin`), and so do the `/commands`
of the Lua scripts and of bots.

## Notifications

A mention, a DM that is not being read or a call rings the terminal bell and,
where the terminal supports it, shows a desktop notification (OSC 777, or OSC 9
in iTerm2, WezTerm, Windows Terminal and ghostty). The window title shows the
unread count. Under tmux, `set -g allow-passthrough on` lets the notification
through, and `set -g mouse on` the mouse.

## Servers, scripts and settings

With several servers the list at the top of the left column switches between
them; mentions and calls on the others are announced with the server's name.
`yap-cli` reads the servers joined in the window client (`settings.json`) and
never changes that file. `/connect host [password]` adds a server and
remembers it (in `cli.json`, with the voice settings), so it is there at the next
start. `/disconnect [number or name]`, or *Disconnect and forget* in the menu you
get by right-clicking a server in the list (or in `Ctrl+K`), leaves a server and
forgets it: one you added is removed, one the window client has is hidden from
`yap-cli` (it stays in the window client). A server that is down or refuses
you, for example because it is too old, is dealt with the same way. A server
given on the command line is not remembered.

Lua scripts in the same folder as the window client's run here too, with the
same approvals (`/script` lists them and switches them on). See
[Scripting.md](Scripting.md).

The voice settings (`F9`: microphone, speakers, quality, noise suppression, the
gate) start as the window client's and, once changed here, are kept in `cli.json`
in the config folder.

## Pictures

Pictures attached to messages (png, jpg, gif, bmp, webp, up to 8 MB) are fetched
and drawn in the message with half-block characters, two pixels to a cell, so
they need a terminal with 24-bit colour (nearly all of them; the macOS
Terminal.app does not, and gets none). They are small, to fit among the text:
**Save file** in the message's menu saves the original. `-no-images` turns it off.

## What is not there

Screen sharing and cameras, the tray, themes and avatars. Windows is not supported
yet. The
design notes, with what was built when, are in
[design/cli-client.md](design/cli-client.md).

## Emoji that shift a line (tmux)

Some symbols are emoji too but one cell wide by default (an umbrella, a sun, a
heart, a beach). Terminals disagree on how wide they are drawn (Konsole draws them
wide), and tmux counts one cell, so a row with them could end up shifted. In tmux
or screen `yap-cli` therefore sends those symbols as wide emoji (followed by
U+FE0F) and counts them as two cells, which tmux, and the terminals behind it,
keep to. `YAP_CLI_EMOJI=wide` does that everywhere, `YAP_CLI_EMOJI=text` sends them
in text style (U+FE0E) instead and `YAP_CLI_EMOJI=emoji` changes nothing.

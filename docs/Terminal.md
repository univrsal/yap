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
`-download-dir` where saved files go, `-log-file` where the log goes (by default
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
| `Tab` | Pick a message with the keys: `Up`/`Down`, `Enter` for its menu, `r` reply, `e` edit, `d` delete, `a` react, `t` thread, `y` copy |
| `Alt+Up`, `Alt+Down`, `Alt+1`…`9` | Another channel or DM |
| `Ctrl+K` | Go anywhere or do anything: conversations, servers, settings, forms for new channels, bans and invites |
| `Ctrl+N`, `Ctrl+P` | The next or previous server |
| `Ctrl+B` | The channel list, on a narrow terminal |
| `F2` | Show or hide the member list |
| `F5` `F6` `F7` `F8` | Mute, deafen, join or leave voice, hang up |
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

Type `@` to complete a name, `/` to complete a command.

## Commands

`/help` lists the keys. Besides `/join`, `/pins`, `/bookmarks`, `/search [all]`,
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
never changes that file: servers connected to here last for the run.

Lua scripts in the same folder as the window client's run here too, with the
same approvals (`/script` lists them and switches them on). See
[Scripting.md](Scripting.md).

The voice settings (`F9`: microphone, speakers, quality, noise suppression, the
gate) start as the window client's and, once changed here, are kept in `cli.json`
in the config folder.

## What is not there

Screen sharing and cameras, the tray, themes, avatars and pictures in messages
(files can be saved from the message's menu). Windows is not supported yet. The
design notes, with what was built when, are in
[design/cli-client.md](design/cli-client.md).

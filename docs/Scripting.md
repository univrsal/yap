# Scripting

The client can run scripts written in [Lua](https://www.lua.org/) 5.4. A script
can react to what happens on a server (messages, people coming and going), add
`/commands`, change what you see of other people's messages or what you send,
show notifications, keep time, and make web requests.

Scripts run in the client, on your side. They see what your client sees, they act
as you, and they do not exist for anybody else: the server and the other users
are not told that a script is running. Because a script acts as you, you decide
for each one whether it runs, what it may do and for which servers.

- [Quick start](#quick-start)
- [Where scripts are, and switching them on](#where-scripts-are-and-switching-them-on)
- [What a script looks like](#what-a-script-looks-like)
- [Events](#events)
- [Functions](#functions)
- [Describing a script and its settings: `get_info`](#describing-a-script-and-its-settings-get_info)
- [Commands](#commands)
- [Changing what is shown and what is sent](#changing-what-is-shown-and-what-is-sent)
- [Web requests](#web-requests)
- [What a script may not do](#what-a-script-may-not-do)
- [The command-line client](#the-command-line-client)
- [The web client](#the-web-client)
- [When something doesn't work](#when-something-doesnt-work)
- [Examples](#examples)
- [Not available (yet)](#not-available-yet)

## Quick start

1. Make a file `hello.lua` in the client's scripts folder (Settings > Scripts says
   where it is) with this in it:

   ```lua
   function get_info()
     return {
       name = "Hello",
       description = "Answers !ping in the channel it was said in.",
       permissions = { "send" },
     }
   end

   function on_message(ev)
     if ev.text == "!ping" and not ev.mine then
       yap.send(ev.channel, "pong")
     end
   end
   ```

2. Open **Settings > Scripts** and press **Reload**. "Hello" is listed, switched off.
3. Open it and press **Switch on...**. It shows what the script asks to be allowed
   (here: send messages as you). Press **Allow and switch on**.
4. When someone writes `!ping` in a channel, the script answers `pong`.

To change what it does, edit the file and press **Reload**. The page says the
script "needs a look" then, and asks again before it runs: an approval is for the
text of the script that was approved.

## Where scripts are, and switching them on

**A desktop client** keeps scripts in the `scripts` folder of its configuration
folder, next to its `settings.json` (usually `~/.config/yap/scripts` on Linux,
`~/Library/Application Support/yap/scripts` on macOS and `%AppData%\yap\scripts` on
Windows; the Scripts page shows the exact place). Every file in it that ends in
`.lua` is a script. There can be at most 64, each at most 60 KiB, and a name is
letters, digits, `_`, `-` and `.`.

Scripts are read when the client starts and when you press **Reload**; changes to
a file are not noticed before that.

**A browser** has no folder. **Settings > Scripts > Add a script** takes a name and
pasted text and keeps the script in the browser's storage, for this site.

### The Scripts page

Each script is listed with what it says about itself (name, description, version,
author), and has:

- **Switch on... / Switch off.** Switching on shows what the script asks to be
  allowed, in plain words, and only **Allow and switch on** starts it. Nothing runs
  without this, and a script can never allow itself anything.
- **Runs for all servers**, or only the servers you tick. A script that runs for a
  server hears about that server's messages and people and acts there; for the
  others it does not exist. Untick it with nothing ticked and the script runs for no
  server.
- **Its settings**, if it has any (see [`get_info`](#describing-a-script-and-its-settings-get_info)).
- **Delete script**, which deletes the file (and what it stored).
- **Reload** at the top reads every script again.

The page also says whether scripts can [make web requests](#web-requests) on this
computer.

### Permissions

A script asks for the following in its `get_info`; they are shown when you switch
it on, and a function that needs one raises an error without it.

| Permission | Allows |
| --- | --- |
| `send` | `yap.send`: posting messages as you |
| `notify` | `yap.notify` and `yap.status`: desktop notifications, and text in the status area |
| `net` | `yap.http_get` and `yap.http_post`: web requests |

Everything else needs no permission, including reading the messages and people of
the servers the script runs for. That is why the page asks you to switch on only
scripts you trust. A script that has no `get_info` is listed by its file name and
asks for nothing, so it can read and react, but not post, notify or use the
web.

### What is kept, and where

Your choices are in `scripts/config.json` (for the web client: the same name in the
browser's storage):

```json
{
  "scripts": {
    "hello.lua": {
      "enabled": true,
      "permissions": ["send"],
      "servers": ["chat.example.com:7777"],
      "scoped": true,
      "hash": "b43b358b3fea5498"
    }
  }
}
```

`servers` are addresses as the client has them, or server keys (64 hex digits). With
`"scoped": true` and no `servers`, the script runs for no server; with neither it
runs for all. `hash` is the fingerprint of the text you approved: the script only
runs if the file still has it. You can write the file by hand; an entry without a
`hash` is not tied to one text (so a script you edit keeps running, which is
convenient while you write it).

Next to it, `data/<script>.json` holds what the script stored with `yap.store`, and
`data/<script>.settings.json` its settings. Neither is encrypted: a setting marked
`secret` is hidden on the page, but is in the file as it was typed.

## What a script looks like

A script is a Lua file. When it is switched on, its **top-level code** runs once,
and then the client calls **handlers**: global functions with fixed names, such as
`on_message`, with a table that describes what happened.

```lua
local greeted = {}                       -- top level: runs once, when switched on

function on_message(ev)                  -- a handler: runs for each message
  if ev.mine or greeted[ev.author_id] then return end
  greeted[ev.author_id] = true
  yap.notify("New voice", ev.author .. " is talking in " .. ev.channel)
end
```

- Each script has a Lua state of its own: its globals and `local`s are its own, and
  stay as long as it runs. They are not saved; use [`yap.store`](#functions) for that.
- A handler that does not exist is simply not called, so a script defines only what
  it cares about.
- A handler that raises an error is logged (`script: on_message: hello.lua:7: ...`)
  and the script goes on.
- Handlers never run at the same time and are never interrupted by the client's
  other work, but they are time-limited; see [the limits](#what-a-script-may-not-do).
- `yap.log(...)` writes to the client's log (Settings > Log, or the terminal); it takes
  any values and joins them with spaces. `print` does not exist.
- Ids (messages, accounts) are strings in Lua, so that they stay exact. Times are
  milliseconds since 1970 as integers.

### The server

Everything a script hears about belongs to a server, and the event says which:
`ev.server` is `{ key = "<64 hex digits>", address = "chat.example.com:7777" }`.

A script that runs for several servers sees them all in the same Lua state; it tells
them apart by `ev.server.key`. What a script *does* in reply goes to the server of
the event it is handling: `yap.send` in `on_message` posts on the server the message
came from. A timer remembers the server it was set for. Code that is not handling an
event (the top level, `on_load`, `on_setting`) has no server, so `yap.send` needs one
named: `yap.send("general", "hi", "chat.example.com:7777")`, and the server has to be
one the script runs for.

## Events

Handlers get one table, `ev`. Every event that happens on a server has `ev.server`.

| Handler | When | Fields besides `server` |
| --- | --- | --- |
| `on_load` | the script has just started | `settings`: a table of its settings' values. No server. |
| `on_connect` | the client is connected to a server and logged in (again after a reconnect) | |
| `on_disconnect` | the connection to a server was lost (it is tried again by itself) | `why` |
| `on_message` | a message arrived | `id`, `channel`, `kind`, `type`, `author`, `username`, `author_id`, `text`, `thread`, `time`, `mine`, `mentions_me` |
| `on_presence` | somebody else's online state changed | `user`, `username`, `account`, `state`, `was` |
| `on_timer` | a timer set with `yap.timer` is due | `name` (no `server` field; the handler runs for the server the timer was set for) |
| `on_setting` | you changed one of its settings | `key`, `value`. No server. |
| `on_incoming` | a message is about to be shown | as `on_message`; see [filters](#changing-what-is-shown-and-what-is-sent) |
| `on_send` | you are about to send a message | `channel`, `text`; see [filters](#changing-what-is-shown-and-what-is-sent) |

The fields of a message:

| Field | Is |
| --- | --- |
| `id` | the message's id (a string) |
| `channel` | the channel's name; for a direct message or a group, who it is with, like `DMs with Ann` |
| `kind` | `"channel"`, `"dm"` or `"group"` |
| `type` | `"text"`, `"file"` or `"system"` |
| `author`, `username`, `author_id` | the sender's display name, username and account id |
| `text` | the text as shown, with mentions as `@name`; a file's name for a file |
| `thread` | the id of the message it replies to, or `nil` |
| `time` | when it was sent |
| `mine` | it is one of yours (messages you send arrive here too) |
| `mentions_me` | it mentions you (by name, by role, or `@everyone`) |

For `on_presence`, `state` and `was` are `"online"`, `"away"`, `"busy"` or
`"offline"`; `user` is the display name.

## Functions

All functions are in the table `yap`.

| Function | Does |
| --- | --- |
| `yap.log(...)` | writes the values, joined by spaces, to the log |
| `yap.send(channel, text [, server])` | posts `text` to the channel of that name as you. Needs `send`. At most 20 messages in 10 seconds. `@username` in the text is a mention. The channel has to be one you are in; it does not change the channel you are looking at. |
| `yap.notify(title [, text])` | shows a **desktop notification**, the way the client does for a mention, a direct message or a call: through the tray icon, or the browser's notifications in a web client (or, if the desktop can't show one, the window asks for attention). With several servers connected the title says which server it was for. Clicking it brings the window up. Needs `notify`. At most 10 in 10 seconds. In the terminal client: a line in the log. |
| `yap.status(text)` | shows `text` in the **status area**, the line at the top right of the chat window, where the client itself says things like "Password changed." It stays for five seconds and the next one replaces it, so it is for answers to what you just did (a command's result, a usage hint), not for alerts. Needs `notify`. In the terminal client: a line in the log. |
| `yap.timer(name, seconds [, repeat])` | calls `on_timer{name = name}` after `seconds` (a shorter time is made 0.05), and again each time if `repeat` is true. A timer of the same name is replaced. At most 64. |
| `yap.cancel(name)` | cancels a timer |
| `yap.store.get(key)` | what was stored under `key`, or `nil` |
| `yap.store.set(key, value)` | stores a boolean, number or string (`nil` removes it). Kept between runs (saved every few seconds and when the client closes). Keys up to 128 bytes; 256 KiB in all. |
| `yap.store.delete(key)` | removes a key |
| `yap.setting(key)` | the current value of one of the script's [settings](#describing-a-script-and-its-settings-get_info), or `nil` |
| `yap.register_command(name, [help,] fn)` | adds a [`/command`](#commands) |
| `yap.unregister_command(name)` | removes it |
| `yap.http_get(url, fn [, options])`, `yap.http_post(url, body, fn [, options])` | a [web request](#web-requests). Need `net`. |
| `yap.http_available()` | whether web requests can be made here |

Arguments are checked, and a wrong one raises an error that names the function (`yap.send: argument #2 must be a string`). Text arguments are limited (titles and channel names to 64 bytes, other text to 16 KiB).

Calling any of these when the script is only being read for its description (see
`get_info`) does nothing.

## Describing a script and its settings: `get_info`

A script can define the global function `get_info()`, which returns a table the
client uses to list it and to build a form for its settings:

```lua
function get_info()
  return {
    name = "Keywords",                       -- up to 64 bytes
    description = "Tells you about words.",  -- up to 300
    version = "1.2",                         -- up to 32
    author = "me",                           -- up to 64
    permissions = { "notify" },              -- "send", "notify", "net"
    settings = {
      { key = "words", label = "Keywords", type = "string", default = "yap" },
      { key = "volume", type = "number", default = 0.5, min = 0, max = 1 },
      { key = "where", type = "choice", default = "all", choices = { "all", "dms" } },
    },
  }
end
```

The client reads this **without running the script's actions**: the file is loaded in
a copy where every `yap.*` function does nothing, so a script that registers its
commands at the top level is fine. `get_info` should therefore only return a table; it
can't use the settings' values (use `yap.setting` in a handler).

Everything in the table is checked. What is too long is cut, and what is wrong is
left out and listed under the script on the page (`get_info: ...`), without stopping
the script. A script whose `get_info` fails or runs too long is shown with the error
and can't be switched on.

### Settings

Up to 32 per script. Each is a table with:

| Field | Meaning |
| --- | --- |
| `key` | the name for `yap.setting(key)`: 1 to 48 letters, digits, `_`, `-`, `.`; unique |
| `label` | what the page shows (default: the key) |
| `description` | a note under it |
| `type` | `"bool"`, `"int"`, `"number"`, `"string"` or `"choice"` |
| `default` | the starting value; one that doesn't fit the type is replaced and reported |
| `min`, `max` | for `int` and `number`; values are clamped to them |
| `max_length` | for `string`: at most this many bytes (default 256, at most 1024) |
| `secret` | for `string`: shown as dots on the page |
| `choices` | for `choice`: up to 32 strings of up to 48 bytes; the value is one of them |

The page draws a checkbox for `bool`, a slider for an `int` or `number` that has both
`min` and `max`, a text box for the other numbers and for `string` (applied with Enter
or when you click elsewhere), and a dropdown for `choice`.

A value is checked whenever it is set, whoever sets it: an `int` is whole, a `number`
is within range, a `choice` is one of the choices. The script reads them with
`yap.setting(key)`, is given them all in `on_load{settings = ...}`, and is told of a
change in `on_setting{key, value}`.

## Commands

```lua
yap.register_command("roll", "Roll dice, like /roll 2d6", function(ev)
  -- ev.name = "roll", ev.args = "2d6", ev.argv = {"2d6"}, ev.channel, ev.server
  local n, sides = ev.args:match("^(%d+)d(%d+)$")
  if not n then yap.status("/roll: say how many dice, like 2d6") return end
  local total = 0
  for i = 1, tonumber(n) do total = total + math.random(tonumber(sides)) end
  yap.send(ev.channel, ev.args .. " = " .. total)
end)
```

When the first word of what you type in the message box is `/name` and a script that
runs for this server has registered `name`, the command runs and **nothing is posted**.
Any other text, including `/something` that no script knows, is posted as a message as
usual.

- Names are lower-case letters, digits, `-` and `_` (up to 32); what you type is
  matched ignoring case. Registering a name again replaces the command. A script can
  have 32.
- `ev.args` is everything after the name, trimmed; `ev.argv` is it split at spaces.
  `ev.channel` is the channel you typed it in (empty in a direct message, where
  `yap.send` can't reach).
- While you type the first word, matching commands are offered with their help line
  (Tab or Enter completes it; when the whole name is typed, Enter runs it). They are
  also in the command palette (Ctrl+K) as "Run /name".
- The function runs like an event handler: it is time-limited, an error in it is
  logged, and its `yap.send` goes to the server you typed it in.

## Changing what is shown and what is sent

Two handlers can change things on their way, and answer the question
"what should happen to this message?" by what they return:

| Return | Meaning |
| --- | --- |
| nothing, or `true` | leave it as it is |
| `false` | stop it |
| a string | use this text instead |

```lua
function on_incoming(ev)                   -- what others send, before you see it
  if ev.text:find("buy pills", 1, true) then return false end
  return (ev.text:gsub("darn", "****"))     -- note the parentheses: gsub returns two values
end

function on_send(ev)                        -- what you send, before it goes
  if ev.text:find("secret", 1, true) then return false end
end
```

**`on_incoming`** changes only what *this client* shows: the server and everybody
else still have the original, and `on_message` still gets the original text. It is
offered messages from other people that are text (not files, system messages or
deleted ones), whether they arrive now, come with the history you scroll back to, or
are edited later. Several scripts apply one after another, each seeing the previous
one's text. A message that is stopped is **shown as `[hidden by a script]`**, not
removed (the list of messages has to stay complete), makes no sound and no
notification, and still counts as unread. A replacement is shown as plain text.
Search results, pins and bookmarks show messages as they are.

**`on_send`** gets `channel` and `text` as typed. Stopping a message leaves the text in
the box and shows a notice naming the script; a string is sent in its place. It is not
used for edits, for `/commands`, or for what a script sends with `yap.send`.

Filters can't wait: they must return quickly. A filter is stopped after **2
milliseconds**, and a script whose filters fail (an error, too slow, or `coroutine.yield`)
three times in a row has its filters switched off until it is reloaded; one good call
clears the count. A message whose filter was stopped is shown as it is. If the client
can't get to the script within about 5 ms (it is in the middle of running its handlers),
`on_incoming` is skipped for that message and it is shown as it is.

## Web requests

```lua
yap.http_get("https://example.com/api", function(answer)
  if not answer.ok then
    yap.log("failed: " .. answer.error)           -- there was no answer
  elseif answer.status == 200 then
    yap.log(answer.body:sub(1, 100))
  end
end, { timeout = 5, headers = { Accept = "application/json" } })

yap.http_post("https://example.com/hook", '{"text":"hi"}', function(answer) end,
  { content_type = "application/json" })
```

The request is made while the script goes on; `fn` is called later, in a handler of its
own (and for the server the request was made for). It gets:

| Field | Is |
| --- | --- |
| `ok` | `true` if the server answered, **whatever its status**; `false` if no answer came |
| `status` | the HTTP status, when one came (absent if none did) |
| `body` | the answer as a Lua string (only if `ok`) |
| `headers` | a table of the answer's headers, names in lower case; a header that came twice is joined with `, ` |
| `error` | why there was no answer: `timed out`, `the answer is too large (more than 1024 KiB)`, `Could not connect to server`, `requests can't be made here`, ... |

So a `404` is `ok = true, status = 404`; check `status` for what you care about.

`options` is a table: `headers` (names and values), `content_type` (the same as a
`Content-Type` header) and `timeout` in seconds (default 10, at most 30).

Rules, all of which raise an error in the script when broken:

- The address is `http://` or `https://`; nothing else (a redirect to another kind of
  address is refused too, and with libcurl at most 5 redirects are followed). Local and
  private addresses are allowed.
- Header names are letters, digits and `-` and the like, values have no line breaks,
  at most 16 headers, and `Host`, `Content-Length`, `Transfer-Encoding`, `Connection`,
  `Upgrade`, `TE` and `Expect` are not yours to set.
- The address is at most 2048 bytes, a body 256 KiB. An answer over **1 MiB** is
  stopped.
- At most 4 requests out at once and 30 a minute for a script. Requests that are still
  out when a script is switched off or reloaded are dropped, and `fn` is not called.

On **Linux** the client uses `libcurl`, which it looks for when it starts. If it isn't
installed the client says so in its log (`script: libcurl was not found, so scripts
can't make web requests`) and on the Scripts page, `yap.http_available()` is `false`,
and a request is answered at once with `ok = false`. Install your distribution's
`libcurl4` (or `libcurl`) package. Windows and macOS use the system's own HTTP
libraries. A **browser** makes the requests itself with `fetch`, so only servers that
allow requests from a web page (CORS) can be asked, no cookies are sent, and a page
served over https can't ask for plain http.

## What a script may not do

Scripts run in a restricted copy of Lua. They can use the language and the libraries
`string`, `table`, `math`, `utf8` and `coroutine`. They have **no** `io`, `os`,
`package` (so no `require`), `debug`, `dofile`, `loadfile`, `print`, or `string.dump`;
`load` takes only text; `collectgarbage` only `"count"` and `"collect"`. A script can't
touch your files, run programs or reach the network except through `yap.http_*`.

The sandbox is there to stop mistakes and limit what a script can reach; it is not a
reason to run scripts you don't trust, since a script you allow can still read the
messages of its servers and, with the permissions, post and use the web as you.

Limits, so that a script that goes wrong doesn't hold the client up:

| Limit | Value |
| --- | --- |
| time for one handler run (all its slices together) | 200 ms of running time, then it is stopped |
| time slice | the client runs scripts for about 2 ms of each frame, in turns of 0.5 ms; a handler that takes longer than a turn is paused and goes on in the next |
| a filter | 2 ms, no pausing |
| memory for a script | 16 MiB |
| the script's own top-level code | the same 200 ms, once, when it starts |
| `string.rep` | a result over 1 MiB is an error |
| a pattern in `string.find`, `match`, `gmatch`, `gsub` | at most 200 characters |
| scripts | 64, each at most 60 KiB |

A handler that runs over its time is stopped and logged (`script: on_message ran for
too long`). A script may use `coroutine`; a handler can pause itself with
`coroutine.yield()` to go on in the next frame.

Two things the limits can't catch: a pattern that backtracks a lot
(`("a"):rep(30):find(("a*"):rep(10) .. "b")`) is one call that can't be interrupted, and
a loop inside a coroutine that the script made runs until the 200 ms are over before it
is stopped. Both only freeze the client for a moment, then the handler is stopped.

## The command-line client

`yap -headless` runs the scripts in the same folder, and has commands to manage them:

| Command | Does |
| --- | --- |
| `/script` | lists the scripts, what they ask for, whether web requests are available |
| `/script on <file>` | switches a script on, allowing what it asks for (it says what) |
| `/script off <file>` | switches it off |
| `/script reload` | reads the scripts again |
| `/script settings <file>` | lists its settings and their values |
| `/script set <file> <key> <value>` | sets one (the value is checked) |
| `/script servers <file> all` or `<address> ...` | chooses the servers it runs for |

A `/word` that none of the client's own commands know is tried as a script's command.
`yap.notify` and `yap.status` write a line to the log. The channel in a command's `ev.channel` is the
one you are looking at (`/view`).

## The web client

A browser can run scripts too, with these differences: they are kept in the browser's
storage (added on the Scripts page, at most 60 KiB each), there is no file to edit, and
web requests are made by the page (see above). `yap.notify` uses the browser's
notifications, which the page has to be allowed to show (the client asks, as it does for
its own); `yap.status` is the same status area.

## When something doesn't work

- **The script isn't listed.** The file has to end in `.lua` and be in the scripts folder;
  press **Reload**. The name may only have letters, digits, `_`, `-` and `.`.
- **"can't run" / a red line under it.** That is the error from loading it, with the
  file and line (`hello.lua:12: ...`). Fix it and press Reload.
- **"needs a look" / "changed since you approved it".** The file is not the text you
  approved. Look at it, and switch it on again.
- **It is on but does nothing.** Is it switched on for this server (the **Runs for all
  servers** box)? Look at the log for `script:` lines. Remember `yap.send` needs the
  `send` permission, and the channel has to exist and be yours; `yap.send` to a direct
  message does not work.
- **`script: on_message ran for too long`.** Something in the handler loops or does too
  much work; the handler was stopped. Do less per message.
- **`yap.send: no server: name one ...`.** The code that called it isn't handling an
  event, so there is no server. Pass the server as the third argument, or do it in a
  handler.
- **`libcurl was not found`.** On Linux, install the `libcurl` package.
- **A filter stopped working.** Three failures in a row switch a script's filters off;
  the log says why. Reload to start again.

## Examples

In [`docs/examples/scripts`](examples/scripts) (copy one to the scripts folder, or paste it
into **Add a script**):

| Script | Shows |
| --- | --- |
| [`showcase.lua`](examples/scripts/showcase.lua) | every kind of setting, commands, both filters, notifications and status text, a timer |
| [`keywords.lua`](examples/scripts/keywords.lua) | a notification when a message contains a word of yours |
| [`presence.lua`](examples/scripts/presence.lua) | a notification when somebody comes online |
| [`away.lua`](examples/scripts/away.lua) | answering a mention while you're away, once per person |
| [`webget.lua`](examples/scripts/webget.lua) | web requests: `/get` and `/post`, answered in the status area |
| [`webhook.lua`](examples/scripts/webhook.lua) | sending the messages that mention you to a web address |

## Not available (yet)

- Replying to or reacting to a message, listing channels or people, and sending to a
  direct message or a group (`yap.send` posts to channels by name).
- Drawing anything of their own, voice, audio and screen sharing.
- Several Lua states per script (one per server), and sharing data between scripts.
- Noticing that a file changed: press **Reload**.

How it works inside, and why it is the way it is, is in
[design/scripting.md](design/scripting.md).

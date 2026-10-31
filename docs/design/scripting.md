# Client scripting: plan

Lua scripts that run inside the client: filter or rewrite messages,
react to people coming and going, add `/commands`, call out to the
network. Nothing here is built yet. As in `bot-api.md`, each phase is its
own commit or series of commits, what turns out differently is written
under it when done ("*As built:*"), and the open questions are in the
Decisions table at the end.

Sizes: S up to about 300 changed lines, M up to 1000, L up to 2500.

## What we start from

- **The client already has a seam for this.** `conn` (the network side,
  `client_step`) never touches the UI; the UI never touches the
  `Server_Conn` except through its command queue (`conn/commands.odin`).
  State goes to the UI through the `View` behind one mutex
  (`conn/view.odin`). Scripts are a third consumer of the same two
  directions: events out of `conn`, commands into it.
- **Incoming things pass through a few procs**: `message_arrived`,
  `message_changed`, `reaction_changed`, `msgs_purged`
  (`conn/messages.odin`), and presence in `conn/presence.odin`. Those are
  the hook points; no new plumbing in the protocol.
- **Threads differ by target.** Natively `client_step` runs on a network
  thread (`net_native.odin`); on the web and when headless it is driven
  from the main loop. A design that only works with threads would not
  compile into the web build.
- **There is a headless client** (`src/client/headless`) with its own
  `/command` line. Scripts should work there too, which makes them a
  second way to write a bot, one that needs no token or gateway.
- **Lua is not free on every target.** `vendor:lua/5.4` only has prebuilt
  libraries for Linux amd64 and Windows (`linux/liblua54.a`,
  `windows/lua54dll.lib`) and falls back to `system:lua5.4` elsewhere.
  macOS and wasm have nothing. So we can't just `import "vendor:lua/5.4"`
  and be done.

## Goals and non-goals

- **Small, safe, boring.** A script is one `.lua` file in the config
  folder. It can't do anything the user couldn't do by hand, unless the
  user has granted it more.
- **The same on every target**, native, headless and web.
- **One surface for scripts and bots.** The event names and the action
  vocabulary should be what bot slash commands (next feature) use too,
  so there is one thing to design and document.
- Not in the first version: voice and audio hooks, UI drawing (custom
  panels), scripts sharing state across servers, a script marketplace.

## Architecture

### Building Lua

Vendor the Lua 5.4 source (fetched and checked like opus, via
`scripts/build/fetch.sh` and a `lua.version` file) and compile
`onelua.c` with the existing `c_lib_build` pattern in `build.sh` /
`build.bat`, into `src/client/script/liblua.a`. The same file builds with
`emcc` in `web/build.sh`. Reasons over using `vendor:lua`:

- Works on macOS and wasm, with one version everywhere.
- Static, so no `liblua5.4.so` to ship.
- We control `luaconf.h` flags, in particular `LUA_NOCVTN2S`-style
  tightening and removing `io`/`os`/`package`/`debug` (below).

We still use `vendor:lua/5.4`'s Odin *bindings* (the procedure
declarations), with the foreign import swapped for ours. If that
isn't clean, we copy the ~300 lines of bindings we use into
`src/client/script/lua.odin`.

### Where scripts run

A new package `client:script`, owning one `lua.State` per script and an
event queue.

	conn (net thread) ──events──> script queue ──> Lua handlers
	                                                  │
	conn command queue <──────── actions ─────────────┘

- Events are copied into plain structs (strings owned) and pushed onto a
  queue, like commands go the other way. The net thread never calls into
  Lua, so a slow script can't hold up voice or the network.
- Actions are *commands* pushed to the existing queue, with the same
  permission checks the UI's actions get. A script has no power the
  command set doesn't.

### Not stalling the app: scripts are time-sliced everywhere

The web build has no threads, so a script that loops forever (or just does
too much) would freeze the page. Rather than treat that as a web-only
problem, scripts are **cooperatively scheduled the same way on every
target**:

- Every handler call runs inside its own Lua coroutine.
- A `LUA_MASKCOUNT` hook fires every ~1000 VM instructions and checks the
  wall clock. When the slice is used up (the frame budget, about 1-2 ms,
  shared among all scripts) the hook calls `lua_yield` (allowed from a
  count hook in Lua 5.4), and the host returns to the frame.
- `script.step()` runs once per frame (and per `client_step` headless)
  and resumes suspended handlers round-robin until the slice is gone.
  Whatever is left continues next frame.
- A handler also has a **total** budget (for example 200 ms of CPU or N
  slices). Past that it is killed with an error ("script x: handler
  on_message ran too long"), logged and shown on the Settings page; after
  a few kills in a row the script is disabled until reloaded.
- So `while true do end` costs about one slice per frame until the total
  budget kills it, and the UI stays responsive meanwhile. The same holds
  for a script doing real but heavy work on thousands of messages.
- Native could instead use a thread, but with this in place it isn't
  needed. The first version uses no thread natively either (D9), which
  removes locking between scripts and `conn`: events arrive on the queue,
  actions leave on the command queue, and Lua state is only touched from
  one place.

Things that can't be yielded are the limit of the scheme: a single C call
that takes long (a huge `string.rep`, a pathological `string.find`
pattern, `table.sort` on a million entries) doesn't reach the hook.
Mitigations: remove or wrap the worst offenders (cap `string.rep` size,
pattern-match step limits are not in stock Lua, so wrap `string.find` /
`match` / `gmatch` / `gsub` to reject patterns over a length), and the
memory cap bounds the rest.

### Slow things are asynchronous, never blocking

Anything that waits on the outside world takes a callback and returns at
once. The script is not suspended or polled, the callback is delivered as
an event later:

- `yap.http_get/post`: see "HTTP" below. Native requests are driven by
  polling from `script.step()`, so there is no request thread either.
- `yap.timer`: the host's clock, delivered as `on_timer`.
- Nothing in the API blocks: no `sleep`, no synchronous request. A
  script that needs to wait uses a timer or `yap.http_get` with a
  callback (and optionally a coroutine helper, `yap.await`, built on
  those in a later step).
- Requests are bounded: timeout (10 s default), body size (1 MiB, see
  the note under HTTP), concurrent requests per script (4), and requests
  per minute.

### HTTP

Native builds use `deps/thirdparty/tinyrequests` (a single header; WinHTTP
on Windows, CFNetwork on macOS, and a runtime-loaded libcurl on Linux and
the BSDs). It is poll-driven and creates no threads, which fits the
scheme above: `yap.http_*` calls `tr_request_begin`, and `script.step()`
calls `tr_client_poll` / `tr_async_poll` once per frame and delivers
finished responses as callbacks (a `LUA_MASKCOUNT`-sliced handler, like
any other). One `tr_client` for the whole script runtime.

- **Built like the other C libraries**: `yap_requests.c` defines
  `TINYREQUESTS_IMPLEMENTATION` and is compiled by `c_lib_build` into
  `libyap_requests.a`. Link `winhttp` on Windows, `CoreFoundation` and
  `CFNetwork` on macOS, and `dl` on Linux. Not compiled for the web.
- **Linux without libcurl.** `tr_client_create` returns `NULL` when no
  libcurl can be loaded. The script runtime calls it once at startup and
  logs the outcome either way (`script: http via libcurl` / `script: libcurl
  not found, yap.http_* disabled`; the backend name comes from
  `tr_client_backend_name`). If there is no client, `yap.http_available()`
  returns false and `yap.http_get/post` call their callback at once with
  `{ ok = false, error = "http unavailable" }`, rather than raising, so a
  script can degrade. The Settings page shows the same state beside
  the `net` permission, so the user can tell why a script that needs it
  does nothing.
- **Web**: tinyrequests has no wasm backend, so there the same `yap.http_*`
  goes through `fetch` in a small `web/http.js`, with results handed back
  through an exported function as `web/files.js` does. The Lua side is
  identical. CORS applies (D5).
- **Callback shape**: `cb({ ok, status, body, headers, error })`, body as
  a Lua string.
- **Things the library doesn't do, which we must** (it is `as-is`, 2.1k
  lines, and appends the whole response to memory):
  - **A size cap.** Neither the curl write callback nor the other backends
    stop at a limit, so a hostile or mistaken URL could stream gigabytes
    into memory. Add a `max_body_size` to `tr_request` in our copy (the
    license allows altered copies if marked) and stop the transfer past
    it. Until then a script's own memory cap doesn't help, since the body
    is allocated by C before it reaches Lua. (Check each backend: this is a
    change in three places.)
  - **Only `http:` and `https:`**, checked in Odin before the request
    begins. FOLLOWLOCATION is always on in the curl backend.
  - **Loopback and private addresses** (a script talking to `localhost`,
    `192.168.x.x`, the cloud metadata address): decide in D10. Blocking by
    URL host is easy to get wrong (DNS), so the recommendation is a
    clear `net` permission wording and, optionally, a per-script host
    allow-list in the script's info (below).
  - Check how certificates are verified on each backend before shipping.

### Filters that change a message

`on_message` can return `drop` or a modified text, which means the script
must run *before* the message is shown. That conflicts with "the net
thread never waits for Lua". The decision (D3) is to do it in two tiers:

1. **Observers** (async, time-sliced as above): `on_message`,
   `on_presence`, ... Their return values are ignored.
2. **Filters** (sync, bounded): `on_incoming` (may `drop`, hide or
   rewrite for display) and `on_send` (may rewrite or cancel). They can't
   be suspended, since the answer is needed now, so they run inline with a
   hard limit of about 2 ms and no yielding; on overrun the filter is
   aborted, that message passes through unchanged, and the script gets a
   warning (and is disabled after repeated overruns). Filtering only changes what *this* client shows or
   sends, never what is stored on the server.

### Sandbox

- Load only `base` (minus `dofile`, `loadfile`, `load` with binary
  chunks, `collectgarbage` options), `string`, `table`, `math`, `utf8`,
  `coroutine`. No `io`, `os`, `package`, `debug`.
- **Time and instruction budget** per handler call, as described under
  time-slicing: the slice yields, the total budget kills.
- **Memory limit** per script through the allocator passed to
  `lua_newstate` (a cap, e.g. 16 MiB).
- **Permissions**, declared in the script's `get_info` (below) and shown to
  the user before the script is enabled: `net` (HTTP), `files` (read/write inside
  `scripts/data/<script>/` only), `notify`, `send` (post as the user).
  Without `send` a script can only read and notify. Granted permissions
  are stored per script file hash, so editing a script asks again.
- Errors never crash the client: each handler runs under `lua_pcall`,
  is logged, and a script that fails N times in a row is disabled until
  reloaded.

### The API

Events (all take one table argument; ids are strings in Lua):

| Event | Fields |
| --- | --- |
| `on_connect`, `on_disconnect` | `server` (every event has one: `key`, `address`, `name`) |
| `on_message` | `id`, `channel`, `author`, `text`, `mentions_me`, `dm`, `thread` |
| `on_incoming` (filter) | same; may return `false` or a replacement `text` |
| `on_send` (filter) | `channel`, `text`; may return `false` or a replacement `text` |
| `on_edit`, `on_delete`, `on_reaction` | the message and who/what |
| `on_presence` | `user`, `state` (`online`/`offline`/`idle`/`status`), `status` |
| `on_voice` | `user`, `channel`, `joined`/`left`, `muted` |
| `on_load`, `on_unload` | `settings` (current values) |
| `on_setting` | `key`, `value`, after the user changes one |
| `on_timer` | `name` |
| `on_command` | `name`, `args`, `channel`, for commands the script registered |

Actions (a `yap` global table):

| Action | Needs |
| --- | --- |
| `yap.send(channel, text)`, `yap.reply(id, text)`, `yap.react(id, emoji)` | `send` |
| `yap.notify(title, text)`, `yap.sound(name)`, `yap.set_status(text, minutes)` | `notify` |
| `yap.register_command(name, help, fn)` | none |
| `yap.timer(name, seconds, repeat)` / `yap.cancel(name)` | none |
| `yap.http_get(url, cb)`, `yap.http_post(url, body, cb)`, `yap.http_available()` | `net` (the last needs nothing) |
| `yap.setting(key)` | none |
| `yap.store.get/set/delete(key)` (per script, persisted) | none |
| `yap.channels()`, `yap.users()`, `yap.me()`, `yap.log(...)` | none |

HTTP is asynchronous with a callback; see "HTTP" above.

### Which servers a script runs for

The client can be connected to several servers, each its own
`Server_Conn` with its own channels and users. A script is **enabled for a
set of servers**, chosen by the user, not by the script:

- **Scope**: `All servers` (the default) or `Only these`, a list. It is
  part of the script's saved configuration (`scripts/config.json`:
  enabled, granted permissions, server scope), next to the settings. The
  script can't widen it.
- **Identity is the server's public key**, not the address. The client
  already keeps it (`Server_Conn.server_key`, and the trust-on-first-use
  file in `conn/known_servers.odin` that maps the address as typed to
  that key). So a server that is reached through two names, or moves to a
  new address, is still the same server. The config also stores the
  address and name last seen, for display and for servers that aren't
  connected at the moment. An entry whose key no longer matches
  (the known-servers file reports a mismatch) is never run.
- **Filtering happens in the host, before the queue.** An event from a
  server outside the scope is dropped where it is created, so the script
  never sees it, and costs nothing. `on_connect` / `on_disconnect` fire
  once per in-scope server; leaving the scope (the user unticks a server)
  gives that server an `on_disconnect`.
- **Every event carries `server`** (a short table: `key`, `address`,
  `name`), so a script can tell servers apart when it runs for several.
- **Actions have an implicit server.** `yap.send("general", ...)` is
  ambiguous when two servers both have `#general`. So inside a handler
  the action goes to the server of the event being handled; a timer or an
  HTTP callback remembers the server it was started from; and any
  action accepts an explicit `server = key`, which must be in scope or it
  is refused. `yap.servers()` lists only in-scope servers, and
  `yap.channels()` / `yap.users()` / `yap.me()` take the same optional
  `server`.
- **The GUI**: the script's page has a "Servers" section: a choice of "All
  servers" or "Only these" and a tick box per known server (from the
  known-servers file, so servers that aren't connected can be picked
  ahead of time). Under "Only these", a server added later is *not*
  ticked. The enable dialog shows the permissions and the server choice
  together, because permissions such as `send` mean different things
  depending on where they apply. Headless gets `/script servers <name>
  all|<address>...`.
- **A hint, not a rule**: `get_info` may include `servers = { "chat.example.com:7777" }`
  to say what the script was written for. The enable dialog pre-selects
  "Only these" with those servers if they're known, and the user can
  change it. (Optional; see D14.)
- **State**: one Lua state per script serves all its servers (D4), so
  globals are shared between them, and `yap.store` and settings are per
  script, not per server. A script that keeps per-server data keys it by
  `ev.server.key`. This is what v1 ships.
- **Later: a per-server instance mode.** A script could opt in with
  `per_server = true` in `get_info`, and the host would then create one Lua
  state per (script, server): every instance sees only its own server and
  has its own globals, and `yap.store` is split per server, so a script
  written with one server in mind runs unchanged on several. Not in v1
  (D15). Nothing in v1 should rule it out: keep the state (Lua state,
  queue, store, time-slice bookkeeping) in one `Script_Instance` struct that
  the runtime owns a list of, so going from one instance per script to one
  per (script, server) is a change in how instances are created and how
  events are routed to them.

### Script metadata and settings

A script describes itself so the GUI can list it and let the user
configure it, without the user reading the source. It does so with a
global function `get_info()` that returns a table:

	function get_info()
	  return {
	    name        = "Keyword highlight",
	    description = "Notifies you when one of your keywords is mentioned.",
	    version     = "1.2",
	    author      = "someone",
	    permissions = { "notify" },          -- shown, and asked for, before enabling
	    settings = {
	      { key = "words",  label = "Keywords", type = "string", default = "yap, lua",
	        description = "Comma separated" },
	      { key = "sound",  label = "Play a sound", type = "bool", default = true },
	      { key = "volume", label = "Volume", type = "number", default = 0.5, min = 0, max = 1 },
	      { key = "where",  label = "Where", type = "choice", default = "all",
	        choices = { "all", "dms", "channels" } },
	      { key = "token",  label = "API token", type = "string", secret = true, default = "" },
	    },
	  }
	end

- **Loading in two stages.** The file is first run in a *metadata
  sandbox* in which `yap.*` actions are stubs that raise ("not available
  while loading"), then `get_info()` is called under the usual time slice.
  That gives the GUI name, description and settings, and the permission
  prompt, without the script having been able to send, notify or request
  anything. Only when the user enables the script is it run for real and
  `on_load{settings = ...}` called. A script without `get_info` still
  loads; it is listed by its file name with no description or settings and
  is shown as "no metadata".
- **Validation by the host, not the script.** The table is read into
  Odin structs and checked: strings length-capped, at most N settings,
  `type` one of `bool`, `int`, `number`, `string`, `choice` (maybe `color`
  and `multiline` later), defaults and `min`/`max`/`choices` consistent. A
  malformed entry is dropped and reported on the Settings page; it doesn't
  stop the script.
- **The GUI** draws a form from the schema with the existing widgets
  (checkbox, slider/number field, text box, `ui_dropdown.odin`), `secret`
  strings as a masked box, `description` as the hint. Edits go through the
  same host-side validation (clamped to `min`/`max`, only a listed
  `choice`), are saved, and delivered to the script as `on_setting{key,
  value}`. Scripts read the current value with `yap.setting(key)`, which is
  never stale and never needs a global.
- **Stored** apart from `yap.store` (which is the script's own private data)
  in `scripts/data/<name>/settings.json` (browser storage on the web), so
  they can be shown, reset to defaults and cleared without the script's
  say. `secret` values are only masked on screen; they sit in plain text on
  disk like the rest of the client's settings, and the docs say so.
- **Headless** gets `/script settings <name>` to list and
  `/script set <name> <key> <value>` to change them, through the same
  validation.
- `get_info` may be called again (after a setting change or reload), so it
  must not depend on state; the host does not call anything else on a
  script that is disabled.

### Files and loading

- Scripts live in `<config>/scripts/*.lua` (settings already has a config
  folder). On the web they are kept in the browser's storage and added
  through a settings panel (paste or pick a file); there is no
  filesystem.
- Per-script state: `scripts/data/<name>/store.json` (and `settings.json`)
  natively, storage on the web.
- A Settings page lists scripts (name, description, version, author from
  `get_info`) with enable/disable, reload, permissions, the form of their
  settings, whether HTTP is available, and the last error. Headless gets `/script list|reload|enable|disable`.
- `/reload` and an optional file watcher reload on change.

## Phases

1. **Build and bind Lua (M).** Vendor source, `c_lib_build` on native,
   `emcc` in `web/build.sh` (install emscripten in the dev VM first), bindings, a `script` package that creates a
   sandboxed state and runs a handler as a time-sliced coroutine. Tests: the sandbox
   (no `os`, an infinite loop yields every slice and is killed at the total
   budget, memory cap trips, a runaway `string.rep` is refused) and that
   the web build still links.
   *As built:* `src/client/script`. The release tarball has no `onelua.c`,
   so `yap_lua.c` is our own single translation unit of the core, the
   auxiliary library and `base`, `coroutine`, `math`, `string`, `table` and
   `utf8`, with Lua's internal symbols made static (`scripts/build/lua.version`,
   `fetch.sh lua`; Lua 5.4.8). Differences from the plan above:
   - The Lua API is only used from C. Everything that can `longjmp` (errors,
     yields, the kill) happens in `yap_lua.c`, and Odin sees status codes
     (`yap_lua_spawn_*`, `yap_lua_resume`). So no Odin frame is ever
     unwound, which is what keeps emscripten's longjmp emulation safe. The
     bindings are therefore tiny (`lua.odin`, `lua_foreign.odin`, and the web
     copy generated by `tools/gen_foreign.py`), and `vendor:lua` isn't used.
   - The hook runs every 1000 instructions and asks Odin (`hook_check`) what
     to do: carry on, suspend the task, or kill it. After a kill the hook runs
     after every instruction, so a script that catches the error with
     `pcall` is stopped again at once (tested).
   - **Loading a script is a task too**, since its top-level code can loop.
   - A task is a coroutine that is also given a turn of at most 500 us
     (`TASK_SLICE`) so one busy handler doesn't starve the others. A
     script's own `coroutine.yield()` at the top of a handler simply means
     "go on next frame".
   - Only the task itself is suspended. A coroutine the script makes
     can't be (it would yield to the script, which didn't ask), so one that
     loops forever runs until the total limit and is then killed; that costs
     one stall of up to `limits.total` (200 ms by default). Tested.
   - Memory use is counted in the allocator (`lua_alloc`), so a script
     that fills its limit gets "not enough memory" in its handler and
     the rest keeps working; making a coroutine can run out of memory too,
     and is a protected call, so it is an error value and not a crash.
   - `string.rep` results over 1 MiB and patterns over 200 characters are
     refused. **Not solved:** a pattern that backtracks a lot
     (`("a"):rep(30):find(("a*"):rep(10) .. "b")`) is one C call that the
     hook can't interrupt. It needs a step counter in Lua's matcher
     (`lstrlib.c`), which means patching the fetched source; left for when it
     matters (a script has to be written to do it on purpose).
   - Not wired into the client yet: nothing imports `client:script` until
     phase 2. The unit tests (`odin test src/client/script`, in CI) cover
     the sandbox, the loop kill, `pcall` evasion, coroutines, memory limits and
     leaks; the same scenarios ran under emscripten (node) as a check on the
     wasm build, and the page is linked with `yap_lua.c` by `web/build.sh`.
2. **Observer events and basic actions (M).** The server scope and the
   implicit-server rule for actions go in here, not later, since every
   event and action depends on them. Event queue, hooks in
   `conn`, `on_connect`, `on_message`, `on_presence`, `on_timer`;
   `yap.send`, `yap.notify`, `yap.log`, `yap.timer`, `yap.store`.
   Loading from the scripts folder; headless runs scripts. Example:
   an away auto-responder.
   *As built:* what the plan lists, with these differences and details:
   - **conn side** (`conn/events.odin`): `Server_Conn.events` is an optional
     `Event_Sink`; `event_message`, `event_presence`, `event_connected` (when
     the login is done, `set_state`) and `event_disconnected` are called where
     the UI is told (`message_arrived`, the account update in `auth.odin`,
     `publish_status`). The events are copies the net thread queues under a
     mutex (at most 1000, the oldest dropped), and the runtime drains them on
     its own thread. `Chat_Command` got a `channel` (by name) so that a script
     can post somewhere other than the channel being looked at.
   - **The yap API** (`api.odin`): one C trampoline (`api_call` in `yap_lua.c`)
     for every function, which converts nil/boolean/number/string arguments,
     calls `Hook.host` and pushes the result, so an Odin frame is still never
     unwound by a Lua error. Events reach handlers as value trees
     (`Value`; maps and lists are pushed as Lua tables by C). Table arguments
     were added with phase 6 (see there).
   - `yap.log(...)`, `yap.send(channel, text[, server])` (permission `send`,
     at most 20 messages per 10 s), `yap.notify(title, text)` (permission
     `notify`; a notice in the UI's notice line, or the log when headless),
     `yap.timer(name, seconds[, repeat])` / `yap.cancel(name)` (`on_timer`,
     64 per script, at least 50 ms), `yap.store.get/set/delete` (scalars, 256
     KiB, kept in `<dir>/data/<script>.json` every 5 s and on exit, also on the
     web through `common.store_*`).
   - **Events**: `on_connect`, `on_disconnect`, `on_message`, `on_presence`,
     `on_timer`. Every event has `server = {key, address}`; ids are strings. A
     handler's actions are for the server of its event, or the one that set the
     timer, or one named by key or address.
   - **Which scripts run** (until phase 5 has its page): `<config>/yap/scripts/config.json`
     lists them, and nothing else runs:

         { "scripts": { "away.lua": { "enabled": true,
                                      "permissions": ["send", "notify"],
                                      "servers": ["chat.example.com:7777"] } } }

     `servers` (addresses as typed, or 64-digit server keys) is the scope; left
     out it is every server. A script's own code runs to the end first (at most
     a second) so that its handlers exist when the first event arrives.
   - **Wiring**: `ui_scripts.odin` (started with the UI, stepped every frame
     with 2 ms, the loop sleeps at most 0.1 s while scripts are running),
     `ui_sessions.odin` (attach on `session_new`, detach before the connection
     is freed) and the headless loop.
   - Checked against a live server with two headless clients: `on_connect`,
     a timer, the store across restarts, `on_presence`, a reply with
     `yap.send`, an error in a handler (logged) and an endless loop (killed
     after 200 ms, the client carries on).
   - Not done: scripts are only read when the client starts (reload comes with
     phase 5); a server's *name* isn't in `server` yet (reading it from the
     net thread's data needs the event to carry it); `yap.reply`, `yap.react`,
     `yap.channels/users/me` and DMs.
3. **Local `/commands` (S).** `yap.register_command` hooked into the
   composer and the command palette (`ui_palette.odin`), with autocomplete
   from the registered help text. This is also the step that defines the
   command registration shape the bot slash commands will reuse.
   *As built (phase 3):* `yap.register_command(name, [help,] fn)` and
   `yap.unregister_command(name)`.
   - Names are lower case letters, digits, `-` and `_` (up to 32), what is
     typed is matched ignoring case, registering a name again replaces it,
     32 per script. `fn(ev)` gets `ev = {name, args (the rest of the line),
     argv (split at spaces), channel, server}` and runs like an event handler
     (time-sliced, killed when it runs too long), for the server it was typed in.
   - Functions can now be passed to the host: the C trampoline keeps a registry
     reference (`YAP_FUNC`) that the host owns if it takes it (`Hook.host` sets
     the argument's type to nil) and that is released otherwise, also when the
     call fails. A command's reference is released when it is replaced or removed.
   - Which commands exist is per server like everything else
     (`runtime_commands`), and a command is only run for a server its script
     runs for (`runtime_run_command`).
   - **Composer** (`composer_send`): a line that starts with `/` and names a
     registered command runs it instead of being posted; any other line, an
     unknown `/word` included, is a message as before. **Completion**: while
     the first word of a composer is being typed, the commands that start with
     it are listed with their help (Tab or Enter completes; once the whole name
     is typed Enter runs it). **Palette**: each command is "Run /name", with its
     help beside it.
   - **Headless**: a `/word` that none of its built-in commands knows goes to the
     scripts. The command is read on the stdin thread and queued
     (`runtime_queue_command`) for the thread that steps the runtime, which also
     fills in `channel` from the channel being looked at; a line nobody knows is
     logged. Built-in commands win over a script's of the same name.
   - Not done: in a DM `channel` is `""`, since `yap.send` has no way to address a
     DM yet; the UI itself is only checked by compiling (native and wasm) and by
     the runtime tests, there is no display here to try the composer, the
     completion list and the palette on.
4. **Filters (M).** `on_incoming` / `on_send` with the time budget and the
   "applied locally only" rule. The part that touches the display path, so
   it comes after the rest is stable.
   *As built (phase 4):* `on_incoming(ev)` and `on_send(ev)`; each returns
   nothing or `true` (leave it), `false`, or a string (replace the text).
   - **`filter`** (`script.odin`) is a synchronous call: it spawns the handler's
     coroutine and resumes it to the end now (`yap_lua_resume` can hand back the
     first returned value: nil, a boolean or a string), with no yielding and a
     hard limit of 2 ms (`FILTER_LIMIT`). A filter that errors, runs too long or
     yields is a strike; three in a row switch that script's filters off, and a
     good call clears the count. A script with no such function costs one failed
     lookup.
   - **`on_incoming`** runs on the *network thread*, where the messages become
     what the UI shows (`conn/filter.odin`: `filter_message`, called for a
     message arriving, a page of history, a thread's root and an edit). Since the
     Lua state belongs to one thread at a time, `Runtime.mutex` is held by
     `runtime_step`, the UI calls and the filters; the network thread waits at
     most 5 ms for it (`FILTER_WAIT`) and shows the message as it is if it
     can't have it. Scripts run for a server see each other's changes in turn.
     `ev` is the same as `on_message`'s. Not offered: our own messages, files,
     system messages, deleted ones.
   - **Deviation: hide shows a placeholder.** `false` makes the message appear as
     `[hidden by a script]` (and makes no sound and no notification), instead of
     removing it: the timeline is a window of messages by id, kept in step with
     the server's pages and unread counts, and a missing message would be a hole
     in all of that. Unread counts still include hidden messages. Search results,
     pins and bookmarks show messages as they are. A replacement is plain text
     (mentions in it stay as typed, without their highlight); `on_message` still
     gets the original.
   - **`on_send`** runs on the UI thread in `composer_send`, after the check for
     a script's /command (a command is not a message) and before mentions and
     emoji are encoded, with `ev = {server, channel, text}`: `false` keeps the
     text in the composer and shows a notice ("send.lua stopped this message."),
     a string is sent instead. Edits are not filtered. In headless mode the
     stdin thread queues `/say` for the stepping thread (`runtime_queue_say`)
     which filters it and posts it; a `/say` with files isn't filtered.
   - Checked: the filter and hook behaviour in unit tests (rewrite, hide, a
     second script seeing the first's change, scoping, own messages, a
     lock that can't be had, a looping filter being cut off and then switched
     off, a filter between the steps of a suspended handler), and live against a
     server for `on_send` (a message with "secret" stopped, `!shout` sent as
     `[auto] shout`) and for the hook being called in the real message path.
     A live rewrite and hide could not be shown: in this VM a client often
     doesn't get live messages at all, with or without scripts and also with the
     previous commit's build, so that is not something the filters cause.
5. **Metadata, settings and the Settings page (M).** `get_info` with the
   metadata sandbox, schema validation (tests: malformed entries, clamping,
   unknown choice), the form, `yap.setting`, `on_setting`, the permission
   prompt, web storage and loading.
   *As built (phase 5):* metadata, settings, approval, reload and the page.
   - **`get_info()`** is read by `read_info` (`catalog.odin`) in a state of its own
     where every `yap.*` function does nothing (`Script.meta`). Deviation from the
     plan: they **do nothing** rather than raise, because scripts register their
     commands at the top level and would not load otherwise. The returned table
     comes back through `yap_lua_resume` as a value tree (nil, booleans, numbers,
     strings, lists and maps, at most 8 deep and 4096 values; a table with holes
     or mixed keys is nil). `parse_info` (`info.odin`) checks all of it: limits on
     every length, at most 32 settings, unique keys, a type that exists, a default
     that fits, choices for a choice; what is no good is left out and listed in
     `problems`, and a script with no `get_info` is simply listed by its file name.
   - **Setting types**: `bool`, `int`, `number`, `string`, `choice`, with `min` and
     `max` (clamped), `max_length` (cut at a character boundary), `secret` (masked
     on the page) and `description`. `setting_value` is the one place a value is
     checked, whoever sets it. A script reads them with `yap.setting(key)` and is
     told with `on_load{settings}` and `on_setting{key, value}`. Kept in
     `<dir>/data/<file>.settings.json`.
   - **Approval** is for the text: `config.json` has a `hash` (FNV-64) with the
     permissions the user approved. A script whose text has changed does not run
     and says so ("changed since you approved it") until it is switched on again,
     which approves the new text. A script written into the config by hand, with
     no hash, is not tied to a text (as before).
   - **The runtime knows every script** (`items.odin`), running or not: found in
     the scripts folder (a desktop; `runtime_native.odin`) or in the browser's
     storage under an index (`runtime_web.odin`), at most 64, 60 KiB each. It
     offers `runtime_set_enabled`, `runtime_set_scope`, `runtime_set_value`,
     `runtime_reload`, `runtime_add_source`, `runtime_remove_source` and a
     `runtime_snapshot` (a deep copy for the page), all under the runtime's mutex.
   - **The Scripts page** (`ui_script_settings.odin`, a client category): each
     script is a node with its description, what it asks for, a "Switch on..." that
     shows what it will be able to do before it is approved, the servers it runs
     for (all, or a tick box per joined server), its settings drawn from the
     descriptions (checkbox, dropdown, slider for a range, text box otherwise;
     applied on Enter or when the box loses the focus), a delete button, and at the
     top Reload and an "Add a script" form (a name and pasted text) for browsers,
     which have no folder. The page always exists now, whether or not scripts run.
   - **Headless** has `/script`, `/script on|off <file>`, `/script reload`,
     `/script settings <file>`, `/script set <file> <key> <value>` and
     `/script servers <file> all|<address>...`.
   - A fix to phase 4, found by linking the web build (a type-check had not shown
     it): `lock_for` slept while waiting for the lock, and a page has no
     `time.sleep` (WASI's `poll_oneoff` is undefined there). A page has one thread,
     so the lock can't be held by another and it is taken or not at once.
   - Found by trying the page: microui knows a checkbox by the *address of its
     bool*, and the page's checkboxes use locals, which are all at one address, so
     they shared an identity (ticking one ticked others). Each setting and each
     server in the scope list now has an id of its own (`mu.push_id`). Also, "all
     servers" unticked with nothing picked came back as "all", since an empty list
     means all in a hand-written config; `config.json` now has `"scoped": true` for
     "only these, even if none", and unticking starts from every joined server.
   - A fix on the way: `yap.setting(k)` and `yap.store.get(k)` returned *no value*
     for a missing key, so `tostring(yap.setting("x"))` failed; every `yap.*`
     function now returns at least nil.
   - Checked: unit tests for the table results, `parse_info` and its limits, value
     checking, discovery, approval and the changed-text rule, settings and their
     events, scope, adding, removing and reloading; and live in headless mode:
     found, approved, `on_load` with the settings, a value clamped, a bad one
     refused, `on_setting`, kept across a restart, and a script that was edited
     afterwards not running until switched on again. The page itself is only
     compiled (native and wasm): there is no display here, so the layout, the
     approval step and the text boxes need a look on a real screen.
6. **HTTP (M).** tinyrequests built into `libyap_requests.a`, the size cap
   patch, scheme check, the libcurl-found log line and `http_available`,
   `web/http.js` for the web, permission `net`.
   *As built (phase 6):* `yap.http_get(url, fn[, options])`,
   `yap.http_post(url, body, fn[, options])`, `yap.http_available()`, and the
   `net` permission (in `get_info`'s `permissions`, the config, the page, and
   `/script`).
   - **The answer** comes to `fn(answer)` later, in a handler of its own (time-sliced
     like the others, for the server the request was made for): `{ok, status, body,
     headers}` when there was an answer (a 404 is one: `ok` is about whether the
     server answered, `status` is its), `{ok = false, error}` when not (it timed
     out, it couldn't connect, the answer was too large, there is no way to make
     requests here). Header names are in lower case, a repeated one joined with
     ", ". The function is kept as a registry reference until then
     (`Hook.host` keeps an argument by `Script.keep_arg`), so that a call that fails
     to start doesn't leak it.
   - **options**: `{headers = {Name = "value"}, content_type = "...", timeout = seconds}`
     (default 10, at most 30). Headers are checked: names are tokens, values have no
     line breaks (so no header can be injected), at most 16, and not `Host`,
     `Content-Length`, `Transfer-Encoding`, `Connection`, `Upgrade`, `TE`, `Expect`.
   - **Limits** (`http.odin`): addresses are `http:` or `https:` (anything else is an
     error in the script), up to 2048 bytes; a body up to 256 KiB; an answer up to
     1 MiB, after which the transfer is stopped; four requests out at once per
     script, 30 per minute. A script's requests are cancelled when it is switched
     off, reloaded or the client ends. Local and private addresses are allowed (D10).
   - **To get the table arguments** (`options`, and later more) the C trampoline now
     reads a Lua table the way a result is read (`count_value`/`fill_value`, at most
     8 deep and 4096 values, only names or only 1..n as keys).
   - **Native** (`yap_requests.c`, `http_native.odin`): tinyrequests, built by
     `build.sh`/`build.bat` into `libyap_requests.a`/`yap_requests.lib` (WinHTTP,
     CFNetwork, or a libcurl found at run time). The library is **altered** (marked
     in its header, as its license asks): `tr_config.max_response_size` makes it
     stop collecting an answer that is too large, and the libcurl backend allows
     only http and https, also after a redirect, and at most 5 redirects (the
     other two backends, WinHTTP and CFNetwork, only speak those two). It is polled from
     `runtime_step`; no thread is made and nothing waits. Whether it is there is
     decided when the runtime is made: on Linux, `tr_client_create` fails without a
     libcurl, and the client logs `script: web requests go through libcurl` or
     `script: libcurl was not found, so scripts can't make web requests`; the
     Scripts page and `/script` say the same, and `yap.http_available()` is false,
     and a request is still answered, at once, with `ok = false`.
   - **Web** (`web/http.js`, `http_web.odin`, `EM_JS` in `shell.c`): the page's
     `fetch`, with no cookies, no referrer, redirects followed, a timeout, and the
     size cap counted while the answer is read. An answer comes back through
     `web_http_done` and is given to the script by the next step. As a page, only
     servers that allow it (CORS) can be asked, and an https page can't ask for http.
   - Checked: unit tests with a fake transport (the shape of the answer, every
     argument error, header injection, the limits, requests that can't be made); a
     test that makes real requests through libcurl to a server of its own (a normal
     answer, a 404, a redirect, a POST with headers, an answer that is too large, a
     redirect to `file://`, a refused connection, a timeout) and runs the
     `webget.lua` example against it; the no-libcurl path; the library on its own;
     `node tools/test_web_http.mjs` for the page's side (in CI); and live, in the
     headless client with `webget.lua`. WinHTTP and CFNetwork are only compiled by
     their own CI runners: they have not been run, and the size cap in them rests on
     the one function all backends share (`tr__append_bytes`). A browser itself has
     not been used (node's `fetch` stands in, without CORS).
7. **Docs (S).** `docs/Scripting.md` with the API and the examples; a
   `docs/examples/scripts/` folder (highlight keywords, `/roll`, `/remind`,
   notify when a friend comes online, forward mentions to a webhook).

## Decisions

| | Question | Recommendation |
| --- | --- | --- |
| D1 | Vendor Lua source or use `vendor:lua/5.4` | Vendor the source: macOS and wasm have no prebuilt library |
| D2 | Lua version | 5.4: integers, `utf8`, what `vendor:lua` has newest |
| D3 | Can scripts block/alter messages | Yes, as hard-limited sync filters (no yielding); everything else is time-sliced observers |
| D9 | Thread for scripts natively | No: time-slicing on the main/`client_step` loop everywhere; one code path, no locks |
| D4 | One state per script or one shared | One per script: isolation, per-script limits, reload one at a time |
| D5 | `net` on the web (CORS) | Allow, always async with timeout and size caps; document that only CORS-enabled endpoints work in a browser |
| D6 | Scripts for headless | Yes, same package, driven from its loop |
| D7 | Share the event and action names with bot slash commands | Yes, one vocabulary |
| D10 | Local/private addresses for `yap.http_*` | Allowed with the `net` permission and a clear prompt wording; optional per-script host allow-list in `get_info` |
| D11 | HTTP backend | tinyrequests natively (leaner than bundling curl; unavailable on Linux without libcurl, logged and reported to scripts), `fetch` on the web |
| D12 | Script metadata | `get_info()` returning a table, read in a stubbed sandbox before the script is enabled; settings schema validated and stored by the host |
| D13 | Who decides which servers a script runs for | The user, per script, by server key; default All servers; the script can only hint |
| D14 | Script hint of intended servers | Yes, optional `servers` in `get_info`, only to pre-select |
| D15 | One Lua state across servers or one per server | Shared in v1; a per-server instance mode (`per_server = true` in `get_info`) is a possible later addition |
| D8 | Trust model for downloaded scripts | Permissions shown on first load and re-asked when the file changes; no signing |

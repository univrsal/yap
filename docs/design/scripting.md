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
     (`Value`; maps and lists are pushed as Lua tables by C). Table
     *arguments* from scripts are not supported yet (nothing needs them until
     `register_command` and `http_*`).
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
4. **Filters (M).** `on_incoming` / `on_send` with the time budget and the
   "applied locally only" rule. The part that touches the display path, so
   it comes after the rest is stable.
5. **Metadata, settings and the Settings page (M).** `get_info` with the
   metadata sandbox, schema validation (tests: malformed entries, clamping,
   unknown choice), the form, `yap.setting`, `on_setting`, the permission
   prompt, web storage and loading.
6. **HTTP (M).** tinyrequests built into `libyap_requests.a`, the size cap
   patch, scheme check, the libcurl-found log line and `http_available`,
   `web/http.js` for the web, permission `net`.
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
